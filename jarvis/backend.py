"""Inference backend. JARVIS drives Ollama, which runs open-weight models locally."""

from __future__ import annotations

import json
from typing import Any, AsyncIterator, Protocol

import httpx


class BackendError(Exception):
    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


class Backend(Protocol):
    async def health(self) -> bool: ...
    async def list_models(self) -> list[dict]: ...
    def pull(self, model: str) -> AsyncIterator[dict]: ...
    async def delete(self, model: str) -> None: ...
    async def create(self, tag: str, *, base: str | None, gguf_digest: str | None, system: str,
                     parameters: dict, examples: list) -> None: ...
    async def push_blob(self, digest: str, chunks: AsyncIterator[bytes]) -> None: ...
    def chat(self, model: str, messages: list, options: dict) -> AsyncIterator[dict]: ...
    async def embed(self, model: str, inputs: list[str]) -> dict: ...
    async def aclose(self) -> None: ...


class OllamaBackend:
    def __init__(self, base_url: str, timeout: float = 600.0, transport: httpx.AsyncBaseTransport | None = None):
        self._client = httpx.AsyncClient(
            base_url=base_url, timeout=httpx.Timeout(timeout, connect=10.0), transport=transport
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _json(self, method: str, path: str, **kw) -> Any:
        try:
            r = await self._client.request(method, path, **kw)
        except httpx.HTTPError as e:
            raise BackendError(f"inference engine unreachable: {e}") from e
        if r.status_code >= 400:
            raise BackendError(_err_text(r.text), 404 if r.status_code == 404 else 502)
        return r.json() if r.content else None

    async def _stream(self, path: str, body: dict) -> AsyncIterator[dict]:
        try:
            async with self._client.stream("POST", path, json=body) as r:
                if r.status_code >= 400:
                    text = (await r.aread()).decode(errors="replace")
                    raise BackendError(_err_text(text), 404 if r.status_code == 404 else 502)
                async for line in r.aiter_lines():
                    if not line.strip():
                        continue
                    msg = json.loads(line)
                    if "error" in msg:
                        raise BackendError(msg["error"])
                    yield msg
        except httpx.HTTPError as e:
            raise BackendError(f"inference engine unreachable: {e}") from e

    async def health(self) -> bool:
        try:
            await self._json("GET", "/api/version")
            return True
        except BackendError:
            return False

    async def list_models(self) -> list[dict]:
        data = await self._json("GET", "/api/tags")
        return [
            {"name": m["name"], "size": m.get("size", 0), "modified_at": m.get("modified_at"),
             "details": m.get("details", {})}
            for m in data.get("models", [])
        ]

    def pull(self, model: str) -> AsyncIterator[dict]:
        return self._stream("/api/pull", {"model": model, "stream": True})

    async def delete(self, model: str) -> None:
        await self._json("DELETE", "/api/delete", json={"model": model})

    async def create(self, tag, *, base, gguf_digest, system, parameters, examples) -> None:
        body: dict[str, Any] = {"model": tag, "stream": False}
        if gguf_digest:
            body["files"] = {"model.gguf": gguf_digest}
        else:
            body["from"] = base
        if system:
            body["system"] = system
        if parameters:
            body["parameters"] = parameters
        if examples:
            body["messages"] = examples
        await self._json("POST", "/api/create", json=body)

    async def push_blob(self, digest: str, chunks: AsyncIterator[bytes]) -> None:
        await self._json("POST", f"/api/blobs/{digest}", content=chunks)

    def chat(self, model: str, messages: list, options: dict) -> AsyncIterator[dict]:
        body = {"model": model, "messages": messages, "stream": True}
        if options:
            body["options"] = options
        return self._stream("/api/chat", body)

    async def embed(self, model: str, inputs: list[str]) -> dict:
        return await self._json("POST", "/api/embed", json={"model": model, "input": inputs})


def _err_text(text: str) -> str:
    try:
        return json.loads(text).get("error", text)
    except (ValueError, AttributeError):
        return text
