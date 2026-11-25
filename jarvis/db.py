"""SQLite storage: API keys, custom models and their versions, usage, feedback."""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import threading
import time
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS api_keys (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    prefix      TEXT NOT NULL,
    key_hash    TEXT NOT NULL UNIQUE,
    is_admin    INTEGER NOT NULL DEFAULT 0,
    revoked     INTEGER NOT NULL DEFAULT 0,
    created_at  REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS models (
    name            TEXT PRIMARY KEY,
    description     TEXT NOT NULL DEFAULT '',
    active_version  INTEGER,
    created_at      REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS versions (
    model_name   TEXT NOT NULL REFERENCES models(name) ON DELETE CASCADE,
    version      INTEGER NOT NULL,
    base         TEXT,
    gguf_digest  TEXT,
    system       TEXT NOT NULL DEFAULT '',
    parameters   TEXT NOT NULL DEFAULT '{}',
    examples     TEXT NOT NULL DEFAULT '[]',
    notes        TEXT NOT NULL DEFAULT '',
    backend_tag  TEXT NOT NULL,
    created_at   REAL NOT NULL,
    PRIMARY KEY (model_name, version)
);
CREATE TABLE IF NOT EXISTS usage (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    ts                 REAL NOT NULL,
    key_id             INTEGER,
    model              TEXT NOT NULL,
    prompt_tokens      INTEGER NOT NULL DEFAULT 0,
    completion_tokens  INTEGER NOT NULL DEFAULT 0,
    latency_ms         INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS feedback (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    model       TEXT NOT NULL,
    messages    TEXT NOT NULL,
    rating      INTEGER NOT NULL,
    created_at  REAL NOT NULL
);
"""

KEY_PREFIX = "jv-"


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


def new_key() -> str:
    return KEY_PREFIX + secrets.token_urlsafe(32)


class Store:
    def __init__(self, path: str):
        if path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.execute("PRAGMA journal_mode = WAL")
        self._conn.executescript(SCHEMA)
        self._lock = threading.Lock()

    def _q(self, sql: str, args: tuple = ()) -> list[sqlite3.Row]:
        with self._lock:
            cur = self._conn.execute(sql, args)
            rows = cur.fetchall()
            self._conn.commit()
            return rows

    def _exec(self, sql: str, args: tuple = ()) -> int:
        with self._lock:
            cur = self._conn.execute(sql, args)
            self._conn.commit()
            return cur.lastrowid

    # ---- API keys -------------------------------------------------------
    def count_keys(self) -> int:
        return self._q("SELECT COUNT(*) AS n FROM api_keys WHERE revoked = 0")[0]["n"]

    def create_key(self, name: str, is_admin: bool, key: str | None = None) -> tuple[str, dict]:
        key = key or new_key()
        kid = self._exec(
            "INSERT INTO api_keys (name, prefix, key_hash, is_admin, created_at) VALUES (?,?,?,?,?)",
            (name, key[:8], hash_key(key), int(is_admin), time.time()),
        )
        return key, self.get_key(kid)

    def ensure_key(self, key: str, name: str, is_admin: bool) -> None:
        if not self._q("SELECT id FROM api_keys WHERE key_hash = ?", (hash_key(key),)):
            self.create_key(name, is_admin, key)

    def get_key(self, kid: int) -> dict | None:
        rows = self._q("SELECT * FROM api_keys WHERE id = ?", (kid,))
        return _key_dict(rows[0]) if rows else None

    def lookup_key(self, key: str) -> dict | None:
        rows = self._q("SELECT * FROM api_keys WHERE key_hash = ? AND revoked = 0", (hash_key(key),))
        return _key_dict(rows[0]) if rows else None

    def list_keys(self) -> list[dict]:
        return [_key_dict(r) for r in self._q("SELECT * FROM api_keys ORDER BY id")]

    def revoke_key(self, kid: int) -> bool:
        with self._lock:
            cur = self._conn.execute("UPDATE api_keys SET revoked = 1 WHERE id = ?", (kid,))
            self._conn.commit()
            return cur.rowcount > 0

    # ---- custom models ---------------------------------------------------
    def get_model(self, name: str) -> dict | None:
        rows = self._q("SELECT * FROM models WHERE name = ?", (name,))
        if not rows:
            return None
        m = dict(rows[0])
        m["versions"] = self.list_versions(name)
        return m

    def list_models(self) -> list[dict]:
        return [self.get_model(r["name"]) for r in self._q("SELECT name FROM models ORDER BY name")]

    def create_model(self, name: str, description: str) -> None:
        self._exec(
            "INSERT INTO models (name, description, created_at) VALUES (?,?,?)",
            (name, description, time.time()),
        )

    def update_model(self, name: str, description: str) -> None:
        self._exec("UPDATE models SET description = ? WHERE name = ?", (description, name))

    def delete_model(self, name: str) -> None:
        self._exec("DELETE FROM models WHERE name = ?", (name,))

    def set_active(self, name: str, version: int | None) -> None:
        self._exec("UPDATE models SET active_version = ? WHERE name = ?", (version, name))

    def next_version(self, name: str) -> int:
        row = self._q("SELECT MAX(version) AS v FROM versions WHERE model_name = ?", (name,))[0]
        return (row["v"] or 0) + 1

    def add_version(self, name: str, v: dict[str, Any]) -> dict:
        self._exec(
            "INSERT INTO versions (model_name, version, base, gguf_digest, system, parameters,"
            " examples, notes, backend_tag, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (
                name,
                v["version"],
                v.get("base"),
                v.get("gguf_digest"),
                v.get("system") or "",
                json.dumps(v.get("parameters") or {}),
                json.dumps(v.get("examples") or []),
                v.get("notes") or "",
                v["backend_tag"],
                time.time(),
            ),
        )
        return self.get_version(name, v["version"])

    def get_version(self, name: str, version: int) -> dict | None:
        rows = self._q("SELECT * FROM versions WHERE model_name = ? AND version = ?", (name, version))
        return _version_dict(rows[0]) if rows else None

    def list_versions(self, name: str) -> list[dict]:
        rows = self._q("SELECT * FROM versions WHERE model_name = ? ORDER BY version", (name,))
        return [_version_dict(r) for r in rows]

    def delete_version(self, name: str, version: int) -> None:
        self._exec("DELETE FROM versions WHERE model_name = ? AND version = ?", (name, version))

    # ---- usage -----------------------------------------------------------
    def log_usage(self, key_id: int | None, model: str, prompt: int, completion: int, latency_ms: int) -> None:
        self._exec(
            "INSERT INTO usage (ts, key_id, model, prompt_tokens, completion_tokens, latency_ms)"
            " VALUES (?,?,?,?,?,?)",
            (time.time(), key_id, model, prompt or 0, completion or 0, latency_ms),
        )

    def usage_summary(self, since: float = 0) -> list[dict]:
        rows = self._q(
            "SELECT model, COUNT(*) AS requests, SUM(prompt_tokens) AS prompt_tokens,"
            " SUM(completion_tokens) AS completion_tokens, CAST(AVG(latency_ms) AS INTEGER) AS avg_latency_ms"
            " FROM usage WHERE ts >= ? GROUP BY model ORDER BY requests DESC",
            (since,),
        )
        return [dict(r) for r in rows]

    # ---- feedback / datasets --------------------------------------------
    def add_feedback(self, model: str, messages: list, rating: int) -> int:
        return self._exec(
            "INSERT INTO feedback (model, messages, rating, created_at) VALUES (?,?,?,?)",
            (model, json.dumps(messages), rating, time.time()),
        )

    def list_feedback(self, model: str, min_rating: int | None = None) -> list[dict]:
        sql, args = "SELECT * FROM feedback WHERE model = ?", [model]
        if min_rating is not None:
            sql += " AND rating >= ?"
            args.append(min_rating)
        rows = self._q(sql + " ORDER BY id", tuple(args))
        return [{**dict(r), "messages": json.loads(r["messages"])} for r in rows]


def _key_dict(r: sqlite3.Row) -> dict:
    return {
        "id": r["id"],
        "name": r["name"],
        "prefix": r["prefix"],
        "is_admin": bool(r["is_admin"]),
        "revoked": bool(r["revoked"]),
        "created_at": r["created_at"],
    }


def _version_dict(r: sqlite3.Row) -> dict:
    d = dict(r)
    d["parameters"] = json.loads(d["parameters"])
    d["examples"] = json.loads(d["examples"])
    return d
