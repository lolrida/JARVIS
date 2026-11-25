"""JARVIS: a self-hosted platform for building, versioning, trading and serving your own LLMs."""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, StreamingResponse

from .backend import Backend, BackendError, OllamaBackend
from .config import Settings
from .db import Store

log = logging.getLogger("jarvis")

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")
TAG_NS = "jarvis"
BUNDLE_FORMAT = "jarvis-model/1"
STATIC_DIR = Path(__file__).parent / "static"

# OpenAI request field -> Ollama option
OPTION_MAP = {
    "temperature": "temperature",
    "top_p": "top_p",
    "max_tokens": "num_predict",
    "max_completion_tokens": "num_predict",
    "stop": "stop",
    "seed": "seed",
    "presence_penalty": "presence_penalty",
    "frequency_penalty": "frequency_penalty",
}


def backend_tag(name: str, version: int) -> str:
    return f"{TAG_NS}/{name}:v{version}"


def create_app(settings: Settings | None = None, backend: Backend | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    os.makedirs(settings.data_dir, exist_ok=True)
    store = Store(settings.db_path)
    engine: Backend = backend or OllamaBackend(settings.ollama_url, settings.request_timeout)
    model_lock = asyncio.Lock()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        bootstrap_keys(store, settings)
        yield
        await engine.aclose()

    app = FastAPI(title="JARVIS", version="0.1.0", lifespan=lifespan)
    app.state.store = store
    app.state.engine = engine

    @app.exception_handler(BackendError)
    async def _backend_error(_: Request, e: BackendError):
        return JSONResponse({"error": {"message": str(e), "type": "backend_error"}}, status_code=e.status)

    # ---- auth --------------------------------------------------------------
    def require_key(request: Request) -> dict:
        auth = request.headers.get("authorization", "")
        key = auth[7:].strip() if auth.lower().startswith("bearer ") else request.headers.get("x-api-key", "")
        rec = store.lookup_key(key) if key else None
        if not rec:
            raise HTTPException(401, "missing or invalid API key")
        return rec

    def require_admin(rec: dict = Depends(require_key)) -> dict:
        if not rec["is_admin"]:
            raise HTTPException(403, "admin key required")
        return rec

    # ---- helpers -----------------------------------------------------------
    def resolve(model: str) -> str:
        """Map a public model name to the engine tag.

        `name` -> active version of a custom model, `name@v3` -> that version,
        anything else (e.g. `llama3.2:3b`) is passed through to the engine as a base model.
        """
        name, _, ver = model.partition("@")
        m = store.get_model(name)
        if not m:
            if ver:
                raise HTTPException(404, f"custom model '{name}' not found")
            return model
        if ver:
            try:
                v = int(ver.lstrip("v"))
            except ValueError:
                raise HTTPException(400, f"bad version '{ver}', use name@v<number>")
        else:
            v = m["active_version"]
        if v is None or not store.get_version(name, v):
            raise HTTPException(404, f"version {ver or v} of '{name}' not found")
        return backend_tag(name, v)

    async def create_version(name: str, spec: dict) -> dict:
        """Build a new engine model for `name` and record it. Caller holds model_lock."""
        version = store.next_version(name)
        tag = backend_tag(name, version)
        base, gguf = spec.get("base"), spec.get("gguf_digest")
        if not base and not gguf:
            raise HTTPException(400, "a version needs a 'base' model or uploaded GGUF weights")
        engine_base = resolve(base) if base and not gguf else None
        await engine.create(
            tag,
            base=engine_base,
            gguf_digest=gguf,
            system=spec.get("system") or "",
            parameters=spec.get("parameters") or {},
            examples=spec.get("examples") or [],
        )
        return store.add_version(name, {**spec, "version": version, "backend_tag": tag})

    def get_model_or_404(name: str) -> dict:
        m = store.get_model(name)
        if not m:
            raise HTTPException(404, f"custom model '{name}' not found")
        return m

    # ---- public ------------------------------------------------------------
    @app.get("/", include_in_schema=False)
    async def index():
        return FileResponse(STATIC_DIR / "index.html")

    @app.get("/health")
    async def health():
        return {"status": "ok", "engine": await engine.health()}

    # ---- OpenAI-compatible API --------------------------------------------
    @app.get("/v1/models")
    async def v1_models(_: dict = Depends(require_key)):
        data = []
        for m in store.list_models():
            data.append({"id": m["name"], "object": "model", "created": int(m["created_at"]), "owned_by": "you"})
            for v in m["versions"]:
                data.append({"id": f"{m['name']}@v{v['version']}", "object": "model",
                             "created": int(v["created_at"]), "owned_by": "you"})
        try:
            for b in await engine.list_models():
                if not b["name"].startswith(TAG_NS + "/"):
                    data.append({"id": b["name"], "object": "model", "created": 0, "owned_by": "base"})
        except BackendError:
            pass
        return {"object": "list", "data": data}

    @app.post("/v1/chat/completions")
    async def chat_completions(request: Request, key: dict = Depends(require_key)):
        body = await request.json()
        model, messages = body.get("model"), body.get("messages")
        if not model or not isinstance(messages, list) or not messages:
            raise HTTPException(400, "'model' and a non-empty 'messages' list are required")
        tag = resolve(model)
        options = {OPTION_MAP[k]: v for k, v in body.items() if k in OPTION_MAP and v is not None}
        if isinstance(options.get("stop"), str):
            options["stop"] = [options["stop"]]
        msgs = [_to_engine_message(m) for m in messages]

        cid = "chatcmpl-" + uuid.uuid4().hex[:24]
        created = int(time.time())
        started = time.monotonic()
        stream = engine.chat(tag, msgs, options).__aiter__()
        # Read the first chunk before responding so engine errors become proper HTTP errors.
        first = await stream.__anext__()

        async def chunks() -> AsyncIterator[dict]:
            yield first
            async for c in stream:
                yield c

        def record(final: dict) -> dict:
            usage = {
                "prompt_tokens": final.get("prompt_eval_count", 0) or 0,
                "completion_tokens": final.get("eval_count", 0) or 0,
            }
            usage["total_tokens"] = usage["prompt_tokens"] + usage["completion_tokens"]
            store.log_usage(key["id"], model, usage["prompt_tokens"], usage["completion_tokens"],
                            int((time.monotonic() - started) * 1000))
            return usage

        if not body.get("stream"):
            text, final = [], {}
            async for c in chunks():
                text.append(c.get("message", {}).get("content", ""))
                if c.get("done"):
                    final = c
            return {
                "id": cid, "object": "chat.completion", "created": created, "model": model,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "".join(text)},
                             "finish_reason": _finish(final)}],
                "usage": record(final),
            }

        def sse(delta: dict, finish: str | None, usage: dict | None = None) -> str:
            payload: dict[str, Any] = {
                "id": cid, "object": "chat.completion.chunk", "created": created, "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            if usage:
                payload["usage"] = usage
            return f"data: {json.dumps(payload)}\n\n"

        async def events():
            yield sse({"role": "assistant", "content": ""}, None)
            try:
                async for c in chunks():
                    content = c.get("message", {}).get("content", "")
                    if content:
                        yield sse({"content": content}, None)
                    if c.get("done"):
                        yield sse({}, _finish(c), record(c))
            except BackendError as e:
                yield f"data: {json.dumps({'error': {'message': str(e)}})}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(events(), media_type="text/event-stream")

    @app.post("/v1/embeddings")
    async def embeddings(request: Request, key: dict = Depends(require_key)):
        body = await request.json()
        model, inp = body.get("model"), body.get("input")
        if not model or inp is None:
            raise HTTPException(400, "'model' and 'input' are required")
        inputs = [inp] if isinstance(inp, str) else list(inp)
        out = await engine.embed(resolve(model), inputs)
        tokens = out.get("prompt_eval_count", 0) or 0
        store.log_usage(key["id"], model, tokens, 0, 0)
        return {
            "object": "list", "model": model,
            "data": [{"object": "embedding", "index": i, "embedding": e} for i, e in enumerate(out["embeddings"])],
            "usage": {"prompt_tokens": tokens, "total_tokens": tokens},
        }

    # ---- custom models (admin) ---------------------------------------------
    @app.get("/api/models")
    async def list_models(_: dict = Depends(require_admin)):
        try:
            base = [b for b in await engine.list_models() if not b["name"].startswith(TAG_NS + "/")]
            engine_ok = True
        except BackendError:
            base, engine_ok = [], False
        return {"custom": store.list_models(), "base": base, "engine": engine_ok}

    @app.post("/api/models", status_code=201)
    async def create_model(request: Request, _: dict = Depends(require_admin)):
        body = await request.json()
        name = (body.get("name") or "").strip()
        if not NAME_RE.match(name):
            raise HTTPException(400, "name must be lowercase letters, digits, '-' or '_' (max 63 chars)")
        if not body.get("base"):
            raise HTTPException(400, "'base' is required (e.g. 'llama3.2:3b'); or create then upload GGUF weights")
        async with model_lock:
            if store.get_model(name):
                raise HTTPException(409, f"model '{name}' already exists; add a version instead")
            store.create_model(name, body.get("description", ""))
            try:
                v = await create_version(name, _version_spec(body))
            except Exception:
                store.delete_model(name)
                raise
            store.set_active(name, v["version"])
        return store.get_model(name)

    @app.patch("/api/models/{name}")
    async def update_model(name: str, request: Request, _: dict = Depends(require_admin)):
        get_model_or_404(name)
        body = await request.json()
        if "description" in body:
            store.update_model(name, body["description"] or "")
        return store.get_model(name)

    @app.post("/api/models/{name}/versions", status_code=201)
    async def new_version(name: str, request: Request, _: dict = Depends(require_admin)):
        """Iterate: new version inherits anything you don't change from the active version."""
        body = await request.json()
        async with model_lock:
            m = get_model_or_404(name)
            current = store.get_version(name, m["active_version"]) if m["active_version"] else {}
            spec = {k: current.get(k) for k in ("base", "gguf_digest", "system", "parameters", "examples")}
            spec.update(_version_spec(body))
            if body.get("base"):
                spec["gguf_digest"] = None
            n = int(body.get("examples_from_feedback") or 0)
            if n > 0:
                spec["examples"] = list(spec.get("examples") or []) + _feedback_examples(store, name, n)
            v = await create_version(name, spec)
            if body.get("activate", True):
                store.set_active(name, v["version"])
        return v

    @app.post("/api/models/{name}/activate")
    async def activate(name: str, request: Request, _: dict = Depends(require_admin)):
        """Deploy or roll back: point `name` at a specific version."""
        body = await request.json()
        get_model_or_404(name)
        version = int(body.get("version", 0))
        if not store.get_version(name, version):
            raise HTTPException(404, f"version {version} not found")
        store.set_active(name, version)
        return store.get_model(name)

    @app.delete("/api/models/{name}/versions/{version}")
    async def delete_version(name: str, version: int, _: dict = Depends(require_admin)):
        async with model_lock:
            m = get_model_or_404(name)
            v = store.get_version(name, version)
            if not v:
                raise HTTPException(404, f"version {version} not found")
            if m["active_version"] == version:
                raise HTTPException(409, "can't delete the active version; activate another first")
            await _engine_delete(engine, v["backend_tag"])
            store.delete_version(name, version)
        return {"deleted": f"{name}@v{version}"}

    @app.delete("/api/models/{name}")
    async def delete_model(name: str, _: dict = Depends(require_admin)):
        async with model_lock:
            m = get_model_or_404(name)
            for v in m["versions"]:
                await _engine_delete(engine, v["backend_tag"])
            store.delete_model(name)
        return {"deleted": name}

    @app.put("/api/models/{name}/gguf", status_code=201)
    async def upload_gguf(name: str, request: Request, _: dict = Depends(require_admin)):
        """Upload your own weights (e.g. a fine-tune exported to GGUF) as a new version.

        Send the raw file as the request body. Optional query params: system, notes, description.
        Creates the model if it doesn't exist yet.
        """
        if not NAME_RE.match(name):
            raise HTTPException(400, "invalid model name")
        upload_dir = Path(settings.data_dir) / "uploads"
        upload_dir.mkdir(parents=True, exist_ok=True)
        tmp = upload_dir / f"{uuid.uuid4().hex}.gguf"
        sha = hashlib.sha256()
        size = 0
        try:
            with open(tmp, "wb") as f:
                async for chunk in request.stream():
                    sha.update(chunk)
                    size += len(chunk)
                    f.write(chunk)
            if size < 4:
                raise HTTPException(400, "empty upload")
            with open(tmp, "rb") as f:
                if f.read(4) != b"GGUF":
                    raise HTTPException(400, "file is not GGUF (convert with llama.cpp's convert_hf_to_gguf.py)")
            digest = "sha256:" + sha.hexdigest()
            await engine.push_blob(digest, _file_chunks(tmp))
        finally:
            tmp.unlink(missing_ok=True)

        q = request.query_params
        spec = {"gguf_digest": digest, "system": q.get("system", ""), "notes": q.get("notes", "")}
        async with model_lock:
            created = False
            if not store.get_model(name):
                store.create_model(name, q.get("description", ""))
                created = True
            else:
                active = store.get_model(name)["active_version"]
                cur = store.get_version(name, active) if active else None
                if cur and not spec["system"]:
                    spec["system"] = cur["system"]
                if cur:
                    spec["parameters"] = cur["parameters"]
            try:
                v = await create_version(name, spec)
            except Exception:
                if created:
                    store.delete_model(name)
                raise
            store.set_active(name, v["version"])
        return v

    # ---- trading: export / import -------------------------------------------
    @app.get("/api/models/{name}/export")
    async def export_model(name: str, _: dict = Depends(require_admin)):
        m = get_model_or_404(name)
        bundle = {
            "format": BUNDLE_FORMAT,
            "name": m["name"],
            "description": m["description"],
            "active_version": m["active_version"],
            "exported_at": int(time.time()),
            "versions": [
                {k: v[k] for k in ("version", "base", "gguf_digest", "system", "parameters", "examples", "notes")}
                for v in m["versions"]
            ],
        }
        return JSONResponse(bundle, headers={"Content-Disposition": f'attachment; filename="{name}.jarvis.json"'})

    @app.post("/api/models/import", status_code=201)
    async def import_model(request: Request, _: dict = Depends(require_admin)):
        body = await request.json()
        bundle = body.get("bundle", body)
        if bundle.get("format") != BUNDLE_FORMAT:
            raise HTTPException(400, f"not a {BUNDLE_FORMAT} bundle")
        name = body.get("as_name") or bundle.get("name", "")
        if not NAME_RE.match(name):
            raise HTTPException(400, "invalid model name in bundle; pass 'as_name'")
        versions = sorted(bundle.get("versions") or [], key=lambda v: v.get("version", 0))
        if not versions:
            raise HTTPException(400, "bundle has no versions")
        if body.get("pull_bases", True):
            for base in {v["base"] for v in versions if v.get("base") and not v.get("gguf_digest")}:
                if not store.get_model(base.partition("@")[0]):
                    async for _ in engine.pull(base):
                        pass
        async with model_lock:
            created = not store.get_model(name)
            if created:
                store.create_model(name, bundle.get("description", ""))
            mapping, made = {}, []
            try:
                for v in versions:
                    new = await create_version(name, _version_spec(v) | {"gguf_digest": v.get("gguf_digest")})
                    mapping[v.get("version")] = new["version"]
                    made.append(new)
            except Exception:
                for new in made:
                    await _engine_delete(engine, new["backend_tag"])
                    store.delete_version(name, new["version"])
                if created:
                    store.delete_model(name)
                raise
            store.set_active(name, mapping.get(bundle.get("active_version"), made[-1]["version"]))
        return store.get_model(name)

    # ---- base models (admin) -----------------------------------------------
    @app.post("/api/base-models/pull")
    async def pull_base(request: Request, _: dict = Depends(require_admin)):
        """Download an open-weight model from the Ollama library. Streams NDJSON progress."""
        model = (await request.json()).get("model")
        if not model:
            raise HTTPException(400, "'model' is required, e.g. 'llama3.2:3b'")

        async def progress():
            try:
                async for p in engine.pull(model):
                    yield json.dumps(p) + "\n"
            except BackendError as e:
                yield json.dumps({"error": str(e)}) + "\n"

        return StreamingResponse(progress(), media_type="application/x-ndjson")

    @app.delete("/api/base-models/{model:path}")
    async def delete_base(model: str, _: dict = Depends(require_admin)):
        if model.startswith(TAG_NS + "/"):
            raise HTTPException(400, "delete custom models via /api/models")
        await engine.delete(model)
        return {"deleted": model}

    # ---- feedback -> datasets (continuous iteration) -------------------------
    @app.post("/api/feedback", status_code=201)
    async def feedback(request: Request, _: dict = Depends(require_key)):
        body = await request.json()
        model, messages, rating = body.get("model"), body.get("messages"), body.get("rating")
        if not model or not isinstance(messages, list) or rating not in (-1, 1):
            raise HTTPException(400, "'model', 'messages' (incl. the assistant reply) and 'rating' (1 or -1) required")
        return {"id": store.add_feedback(model.partition("@")[0], messages, rating)}

    @app.get("/api/models/{name}/dataset")
    async def dataset(name: str, min_rating: int = 1, _: dict = Depends(require_admin)):
        """Export rated conversations as chat JSONL, the format most fine-tuning tools accept."""
        rows = store.list_feedback(name, min_rating)
        text = "".join(json.dumps({"messages": r["messages"]}) + "\n" for r in rows)
        return PlainTextResponse(text, media_type="application/x-ndjson",
                                 headers={"Content-Disposition": f'attachment; filename="{name}.jsonl"'})

    # ---- keys & usage (admin) -------------------------------------------------
    @app.get("/api/keys")
    async def list_keys(_: dict = Depends(require_admin)):
        return store.list_keys()

    @app.post("/api/keys", status_code=201)
    async def create_key(request: Request, _: dict = Depends(require_admin)):
        body = await request.json()
        key, rec = store.create_key(body.get("name") or "unnamed", bool(body.get("is_admin")))
        return {**rec, "key": key, "note": "store this key now; it is not shown again"}

    @app.delete("/api/keys/{kid}")
    async def revoke_key(kid: int, me: dict = Depends(require_admin)):
        if kid == me["id"]:
            raise HTTPException(409, "refusing to revoke the key you're using")
        if not store.revoke_key(kid):
            raise HTTPException(404, "key not found")
        return {"revoked": kid}

    @app.get("/api/usage")
    async def usage(days: float = 30, _: dict = Depends(require_admin)):
        return store.usage_summary(time.time() - days * 86400)

    @app.get("/api/whoami")
    async def whoami(key: dict = Depends(require_key)):
        return key

    return app


# ---- module-level helpers ------------------------------------------------------
def bootstrap_keys(store: Store, settings: Settings) -> None:
    if settings.admin_key:
        store.ensure_key(settings.admin_key, "admin (env)", True)
        return
    if store.count_keys() == 0:
        key, _ = store.create_key("admin (bootstrap)", True)
        path = Path(settings.data_dir) / "admin_key.txt"
        path.write_text(key + "\n")
        os.chmod(path, 0o600)
        log.warning("Created admin API key, saved to %s", path)
        print(f"\n  JARVIS admin key: {key}\n  (also saved to {path})\n", flush=True)


def _version_spec(body: dict) -> dict:
    spec = {k: body[k] for k in ("base", "system", "parameters", "examples", "notes") if body.get(k) is not None}
    if "parameters" in spec and not isinstance(spec["parameters"], dict):
        raise HTTPException(400, "'parameters' must be an object, e.g. {\"temperature\": 0.7}")
    if "examples" in spec:
        ex = spec["examples"]
        if not isinstance(ex, list) or any(
            not isinstance(m, dict) or m.get("role") not in ("user", "assistant") or not isinstance(m.get("content"), str)
            for m in ex
        ):
            raise HTTPException(400, "'examples' must be a list of {role: user|assistant, content: str}")
    return spec


def _feedback_examples(store: Store, name: str, n: int) -> list[dict]:
    out: list[dict] = []
    for row in store.list_feedback(name, min_rating=1)[-n:]:
        out += [{"role": m["role"], "content": _text(m.get("content"))}
                for m in row["messages"] if m.get("role") in ("user", "assistant")]
    return out


def _text(content: Any) -> str:
    if isinstance(content, list):
        return "".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    return content or ""


def _to_engine_message(m: dict) -> dict:
    if not isinstance(m, dict) or "role" not in m:
        raise HTTPException(400, "each message needs a 'role'")
    out = {"role": m["role"], "content": _text(m.get("content"))}
    images = [
        p["image_url"]["url"].split(",", 1)[-1]
        for p in (m.get("content") if isinstance(m.get("content"), list) else [])
        if isinstance(p, dict) and p.get("type") == "image_url" and str(p.get("image_url", {}).get("url", "")).startswith("data:")
    ]
    if images:
        out["images"] = images
    return out


def _finish(final: dict) -> str:
    return "length" if final.get("done_reason") == "length" else "stop"


async def _engine_delete(engine: Backend, tag: str) -> None:
    try:
        await engine.delete(tag)
    except BackendError as e:
        if e.status != 404:
            raise


async def _file_chunks(path: Path, size: int = 1 << 20) -> AsyncIterator[bytes]:
    with open(path, "rb") as f:
        while chunk := f.read(size):
            yield chunk
