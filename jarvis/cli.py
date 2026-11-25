"""Command line: `jarvis serve`, `jarvis create-key`, `jarvis list-keys`, `jarvis revoke-key`."""

from __future__ import annotations

import argparse
import logging

from .config import Settings
from .db import Store


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="jarvis", description="Self-hosted LLM platform")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("serve", help="run the API server and web UI")
    s.add_argument("--host", default="0.0.0.0")
    s.add_argument("--port", type=int, default=8000)

    k = sub.add_parser("create-key", help="create an API key")
    k.add_argument("--name", required=True)
    k.add_argument("--admin", action="store_true", help="allow managing models and keys")

    sub.add_parser("list-keys", help="list API keys")
    r = sub.add_parser("revoke-key", help="revoke an API key by id")
    r.add_argument("id", type=int)

    args = p.parse_args(argv)
    settings = Settings.from_env()

    if args.cmd == "serve":
        import uvicorn

        from .app import create_app

        logging.basicConfig(level=logging.INFO)
        uvicorn.run(create_app(settings), host=args.host, port=args.port)
        return

    store = Store(settings.db_path)
    if args.cmd == "create-key":
        key, rec = store.create_key(args.name, args.admin)
        print(f"id={rec['id']} admin={rec['is_admin']}\n{key}")
    elif args.cmd == "list-keys":
        for rec in store.list_keys():
            state = "revoked" if rec["revoked"] else "active"
            print(f"{rec['id']:>4}  {rec['prefix']}…  {'admin' if rec['is_admin'] else 'user ':5}  {state:7}  {rec['name']}")
    elif args.cmd == "revoke-key":
        print("revoked" if store.revoke_key(args.id) else "not found")


if __name__ == "__main__":
    main()
