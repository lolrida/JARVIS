"""Checks the Ollama client speaks Ollama's HTTP API correctly, using a mock transport."""

import asyncio
import json

import httpx
import pytest

from jarvis.backend import BackendError, OllamaBackend


def make(handler):
    return OllamaBackend("http://ollama", transport=httpx.MockTransport(handler))


def run(coro):
    return asyncio.run(coro)


async def collect(aiter):
    return [x async for x in aiter]


def test_create_from_base_sends_expected_body():
    seen = {}

    def h(req):
        seen["path"], seen["body"] = req.url.path, json.loads(req.content)
        return httpx.Response(200, json={"status": "success"})

    run(make(h).create("jarvis/a:v1", base="llama3.2:3b", gguf_digest=None, system="hi",
                       parameters={"temperature": 0.2}, examples=[{"role": "user", "content": "x"}]))
    assert seen["path"] == "/api/create"
    assert seen["body"] == {"model": "jarvis/a:v1", "stream": False, "from": "llama3.2:3b", "system": "hi",
                            "parameters": {"temperature": 0.2}, "messages": [{"role": "user", "content": "x"}]}


def test_create_from_gguf_uses_files():
    def h(req):
        body = json.loads(req.content)
        assert body["files"] == {"model.gguf": "sha256:abc"} and "from" not in body
        return httpx.Response(200, json={"status": "success"})

    run(make(h).create("jarvis/a:v1", base=None, gguf_digest="sha256:abc", system="", parameters={}, examples=[]))


def test_chat_streams_ndjson():
    lines = [{"message": {"content": "Hel"}, "done": False}, {"message": {"content": "lo"}, "done": False},
             {"message": {"content": ""}, "done": True, "eval_count": 2}]

    def h(req):
        assert req.url.path == "/api/chat" and json.loads(req.content)["options"] == {"temperature": 0}
        return httpx.Response(200, content="\n".join(json.dumps(x) for x in lines) + "\n")

    out = run(collect(make(h).chat("m", [{"role": "user", "content": "hi"}], {"temperature": 0})))
    assert "".join(c["message"]["content"] for c in out) == "Hello" and out[-1]["done"]


def test_errors_are_mapped():
    def h(req):
        return httpx.Response(404, json={"error": "model 'nope' not found"})

    with pytest.raises(BackendError) as e:
        run(collect(make(h).chat("nope", [], {})))
    assert e.value.status == 404 and "not found" in str(e.value)

    def down(req):
        raise httpx.ConnectError("refused")

    b = make(down)
    assert run(b.health()) is False
    with pytest.raises(BackendError, match="unreachable"):
        run(b.list_models())


def test_mid_stream_error_raises():
    def h(req):
        return httpx.Response(200, content='{"status":"pulling"}\n{"error":"disk full"}\n')

    with pytest.raises(BackendError, match="disk full"):
        run(collect(make(h).pull("big")))


def test_blob_and_list():
    def h(req):
        if req.url.path == "/api/tags":
            return httpx.Response(200, json={"models": [{"name": "qwen2.5:7b", "size": 5, "details": {}}]})
        assert req.url.path == "/api/blobs/sha256:abc" and req.content == b"GGUFdata"
        return httpx.Response(201)

    async def chunks():
        yield b"GGUF"
        yield b"data"

    b = make(h)
    run(b.push_blob("sha256:abc", chunks()))
    assert run(b.list_models())[0]["name"] == "qwen2.5:7b"
