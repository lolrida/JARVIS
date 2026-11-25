import json

import pytest
from fastapi.testclient import TestClient

from jarvis.app import create_app
from jarvis.backend import BackendError
from jarvis.config import Settings


class FakeEngine:
    """Stands in for Ollama. Echoes the model's system prompt so tests can see which version answered."""

    def __init__(self):
        self.models = {"llama3.2:3b": {"system": "", "examples": []}}
        self.blobs = set()
        self.created = []

    async def health(self):
        return True

    async def list_models(self):
        return [{"name": n, "size": 1, "modified_at": None, "details": {}} for n in self.models]

    async def pull(self, model):
        yield {"status": "pulling"}
        self.models[model] = {"system": "", "examples": []}
        yield {"status": "success"}

    async def delete(self, model):
        if model not in self.models:
            raise BackendError("not found", 404)
        del self.models[model]

    async def create(self, tag, *, base, gguf_digest, system, parameters, examples):
        if gguf_digest:
            if gguf_digest not in self.blobs:
                raise BackendError("blob not found")
        elif base not in self.models:
            raise BackendError(f"model '{base}' not found", 404)
        self.models[tag] = {"system": system, "examples": examples, "parameters": parameters, "gguf": gguf_digest}
        self.created.append(tag)

    async def push_blob(self, digest, chunks):
        async for _ in chunks:
            pass
        self.blobs.add(digest)

    async def chat(self, model, messages, options):
        if model not in self.models:
            raise BackendError(f"model '{model}' not found", 404)
        reply = f"[{model}|{self.models[model]['system']}] {messages[-1]['content']}"
        for word in reply.split(" "):
            yield {"message": {"role": "assistant", "content": word + " "}, "done": False}
        yield {"message": {"role": "assistant", "content": ""}, "done": True, "done_reason": "stop",
               "prompt_eval_count": 7, "eval_count": 5}

    async def embed(self, model, inputs):
        return {"embeddings": [[0.1, 0.2] for _ in inputs], "prompt_eval_count": 3}

    async def aclose(self):
        pass


ADMIN = "jv-test-admin-key"


@pytest.fixture
def ctx(tmp_path):
    engine = FakeEngine()
    app = create_app(Settings(data_dir=str(tmp_path), admin_key=ADMIN), backend=engine)
    with TestClient(app) as c:
        c.headers["Authorization"] = f"Bearer {ADMIN}"
        yield c, engine


def chat(c, model, text="hi", **kw):
    return c.post("/v1/chat/completions", json={"model": model, "messages": [{"role": "user", "content": text}], **kw})


def test_auth_required(ctx):
    c, _ = ctx
    assert c.get("/health").json()["engine"] is True
    assert c.get("/v1/models", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert c.get("/api/models", headers={"Authorization": ""}).status_code == 401


def test_bootstrap_key_written_when_no_env_key(tmp_path):
    app = create_app(Settings(data_dir=str(tmp_path)), backend=FakeEngine())
    with TestClient(app) as c:
        key = (tmp_path / "admin_key.txt").read_text().strip()
        assert key.startswith("jv-")
        assert c.get("/api/whoami", headers={"Authorization": f"Bearer {key}"}).json()["is_admin"]


def test_model_lifecycle_iterate_and_rollback(ctx):
    c, engine = ctx
    r = c.post("/api/models", json={"name": "jarvis", "base": "llama3.2:3b", "system": "You are J1.",
                                    "parameters": {"temperature": 0.3}})
    assert r.status_code == 201, r.text
    assert r.json()["active_version"] == 1
    assert "J1" in chat(c, "jarvis").json()["choices"][0]["message"]["content"]

    # Iterate: only change the system prompt, parameters are inherited.
    r = c.post("/api/models/jarvis/versions", json={"system": "You are J2.", "notes": "friendlier"})
    assert r.status_code == 201 and r.json()["version"] == 2
    assert r.json()["parameters"] == {"temperature": 0.3}
    assert "J2" in chat(c, "jarvis").json()["choices"][0]["message"]["content"]
    assert "J1" in chat(c, "jarvis@v1").json()["choices"][0]["message"]["content"]

    # Roll back.
    c.post("/api/models/jarvis/activate", json={"version": 1})
    assert "J1" in chat(c, "jarvis").json()["choices"][0]["message"]["content"]

    # Can't delete active; can delete the other.
    assert c.delete("/api/models/jarvis/versions/1").status_code == 409
    assert c.delete("/api/models/jarvis/versions/2").status_code == 200
    assert "jarvis/jarvis:v2" not in engine.models

    ids = [m["id"] for m in c.get("/v1/models").json()["data"]]
    assert "jarvis" in ids and "jarvis@v1" in ids and "llama3.2:3b" in ids

    assert c.delete("/api/models/jarvis").status_code == 200
    assert not [t for t in engine.models if t.startswith("jarvis/")]


def test_bad_inputs(ctx):
    c, _ = ctx
    assert c.post("/api/models", json={"name": "Bad Name", "base": "llama3.2:3b"}).status_code == 400
    assert c.post("/api/models", json={"name": "x", "base": "missing:1b"}).status_code == 404
    assert c.get("/api/models").json()["custom"] == []  # failed create left nothing behind
    assert chat(c, "nonexistent:7b").status_code == 404
    assert chat(c, "ghost@v1").status_code == 404


def test_streaming_matches_openai_format(ctx):
    c, _ = ctx
    with c.stream("POST", "/v1/chat/completions",
                  json={"model": "llama3.2:3b", "stream": True, "messages": [{"role": "user", "content": "yo"}]}) as r:
        assert r.status_code == 200
        lines = [ln[6:] for ln in r.iter_lines() if ln.startswith("data: ")]
    assert lines[-1] == "[DONE]"
    events = [json.loads(x) for x in lines[:-1]]
    text = "".join(e["choices"][0]["delta"].get("content", "") for e in events)
    assert "yo" in text
    assert events[-1]["choices"][0]["finish_reason"] == "stop"
    assert events[-1]["usage"]["total_tokens"] == 12


def test_usage_and_keys(ctx):
    c, _ = ctx
    r = c.post("/api/keys", json={"name": "my-app"})
    user_key = r.json()["key"]
    h = {"Authorization": f"Bearer {user_key}"}
    assert c.post("/v1/chat/completions", headers=h,
                  json={"model": "llama3.2:3b", "messages": [{"role": "user", "content": "a"}]}).status_code == 200
    assert c.get("/api/models", headers=h).status_code == 403  # not admin
    usage = c.get("/api/usage").json()
    assert usage[0]["model"] == "llama3.2:3b" and usage[0]["completion_tokens"] == 5
    c.delete(f"/api/keys/{r.json()['id']}")
    assert c.get("/v1/models", headers=h).status_code == 401


def test_export_import_trade(ctx):
    c, engine = ctx
    c.post("/api/models", json={"name": "coder", "base": "llama3.2:3b", "system": "Write code."})
    c.post("/api/models/coder/versions", json={"system": "Write great code.",
                                               "examples": [{"role": "user", "content": "q"},
                                                            {"role": "assistant", "content": "a"}]})
    bundle = c.get("/api/models/coder/export").json()
    assert bundle["format"] == "jarvis-model/1" and len(bundle["versions"]) == 2

    # Simulate a friend's fresh instance that hasn't downloaded the base model yet.
    del engine.models["llama3.2:3b"]
    r = c.post("/api/models/import", json={"bundle": bundle, "as_name": "friends-coder"})
    assert r.status_code == 201, r.text
    m = r.json()
    assert m["active_version"] == 2 and len(m["versions"]) == 2
    assert m["versions"][1]["examples"][1]["content"] == "a"
    assert "llama3.2:3b" in engine.models  # base was pulled automatically


def test_feedback_dataset_and_promote_examples(ctx):
    c, engine = ctx
    c.post("/api/models", json={"name": "bot", "base": "llama3.2:3b"})
    convo = [{"role": "user", "content": "2+2?"}, {"role": "assistant", "content": "4"}]
    c.post("/api/feedback", json={"model": "bot@v1", "messages": convo, "rating": 1})
    c.post("/api/feedback", json={"model": "bot", "messages": [{"role": "user", "content": "x"}], "rating": -1})
    lines = c.get("/api/models/bot/dataset").text.strip().splitlines()
    assert [json.loads(x) for x in lines] == [{"messages": convo}]

    v = c.post("/api/models/bot/versions", json={"examples_from_feedback": 10}).json()
    assert v["examples"] == convo
    assert engine.models["jarvis/bot:v2"]["examples"] == convo


def test_gguf_upload(ctx):
    c, engine = ctx
    assert c.put("/api/models/mine/gguf", content=b"not gguf").status_code == 400
    r = c.put("/api/models/mine/gguf?system=hello", content=b"GGUF" + b"\0" * 100)
    assert r.status_code == 201, r.text
    v = r.json()
    assert v["gguf_digest"].startswith("sha256:") and v["gguf_digest"] in engine.blobs
    assert "hello" in chat(c, "mine").json()["choices"][0]["message"]["content"]
    # New version from the same weights, different prompt.
    v2 = c.post("/api/models/mine/versions", json={"system": "bye"}).json()
    assert v2["gguf_digest"] == v["gguf_digest"]


def test_embeddings(ctx):
    c, _ = ctx
    r = c.post("/v1/embeddings", json={"model": "llama3.2:3b", "input": ["a", "b"]})
    assert r.status_code == 200 and len(r.json()["data"]) == 2
