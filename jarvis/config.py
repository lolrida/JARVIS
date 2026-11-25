"""Runtime settings, read from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass
class Settings:
    # Where the inference engine (Ollama) listens.
    ollama_url: str = "http://localhost:11434"
    # Where JARVIS keeps its database, bootstrap key and uploads.
    data_dir: str = "./data"
    # Optional fixed admin key. If unset, one is generated on first start.
    admin_key: str | None = None
    # Seconds to wait for a single backend call (generation can be slow on CPU).
    request_timeout: float = 600.0

    @property
    def db_path(self) -> str:
        return os.path.join(self.data_dir, "jarvis.db")

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            ollama_url=os.environ.get("OLLAMA_URL", cls.ollama_url).rstrip("/"),
            data_dir=os.environ.get("JARVIS_DATA_DIR", cls.data_dir),
            admin_key=os.environ.get("JARVIS_ADMIN_KEY") or None,
            request_timeout=float(os.environ.get("JARVIS_REQUEST_TIMEOUT", cls.request_timeout)),
        )
