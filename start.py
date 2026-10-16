#!/usr/bin/env python3
"""Initialize and report the current PostgreSQL-only agent-memory backend."""

from __future__ import annotations

import asyncio
import json

from agent_memory import init_db_async, json_default, status_async


async def run() -> int:
    initialized = await init_db_async()
    status = await status_async()
    print(
        json.dumps(
            {"ok": bool(initialized.get("ok") and status.get("ok")), "initialized": initialized, "status": status},
            indent=2,
            ensure_ascii=False,
            default=json_default,
        )
    )
    return 0 if initialized.get("ok") and status.get("ok") else 2


def main() -> int:
    return asyncio.run(run())


if __name__ == "__main__":
    raise SystemExit(main())
