#!/usr/bin/env python3
"""Small PostgreSQL/pgvector memory CLI for agent harness hooks.

Raw psycopg2 only. No ORM, no SQLAlchemy, no Pydantic.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
from pathlib import Path
from typing import Any

import psycopg2
import psycopg2.extras


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schema" / "001_init.sql"
SECRET_KEYS = {"password", "token", "secret", "api_key", "apikey", "authorization", "cookie"}


def db_params() -> dict[str, Any]:
    return {
        "host": os.getenv("MEMORY_DB_HOST", "127.0.0.1"),
        "port": int(os.getenv("MEMORY_DB_PORT", "25490")),
        "dbname": os.getenv("MEMORY_DB_NAME", "agent_memory"),
        "user": os.getenv("MEMORY_DB_USER", "agent_memory"),
        "password": os.getenv("MEMORY_DB_PASSWORD") or os.getenv("PGPASSWORD"),
    }


def connect():
    params = db_params()
    if not params.get("password"):
        raise RuntimeError("Set MEMORY_DB_PASSWORD or PGPASSWORD before connecting.")
    return psycopg2.connect(**params)


def embed(text: str, dims: int = 64) -> list[float]:
    vec = [0.0] * dims
    for raw in text.lower().split():
        token = "".join(ch for ch in raw if ch.isalnum() or ch in "_-")
        if not token:
            continue
        digest = hashlib.blake2b(token.encode("utf-8"), digest_size=16).digest()
        bucket = int.from_bytes(digest[:4], "big") % dims
        sign = 1.0 if digest[4] % 2 == 0 else -1.0
        vec[bucket] += sign
    norm = math.sqrt(sum(value * value for value in vec)) or 1.0
    return [round(value / norm, 6) for value in vec]


def vector_literal(values: list[float]) -> str:
    return "[" + ",".join(str(value) for value in values) + "]"


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        clean = {}
        for key, item in value.items():
            if str(key).lower() in SECRET_KEYS or any(marker in str(key).lower() for marker in SECRET_KEYS):
                clean[key] = "<redacted>"
            else:
                clean[key] = redact(item)
        return clean
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def add_event(args: argparse.Namespace) -> int:
    metadata = json.loads(args.metadata or "{}")
    tags = [tag.strip() for tag in (args.tags or "").split(",") if tag.strip()]
    summary = args.summary or args.content[:240]
    emb = vector_literal(embed(" ".join([summary, args.content, " ".join(tags)])))
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO agent_memory_events (
                space, agent, session_id, event_type, memory_kind, role,
                source, content, summary, tags, metadata, embedding
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, %s::vector)
            RETURNING id
            """,
            (
                args.space,
                args.agent,
                args.session_id,
                args.event_type,
                args.memory_kind,
                args.role,
                args.source,
                args.content,
                summary,
                tags,
                json.dumps(redact(metadata)),
                emb,
            ),
        )
        return int(cur.fetchone()[0])


def cmd_init(_: argparse.Namespace) -> None:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(SCHEMA.read_text(encoding="utf-8"))
    print("initialized")


def cmd_status(_: argparse.Namespace) -> None:
    with connect() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT COUNT(*) AS events, COUNT(DISTINCT space) AS spaces FROM agent_memory_events")
        print(json.dumps(cur.fetchone(), indent=2, default=str))


def cmd_add(args: argparse.Namespace) -> None:
    print(json.dumps({"id": add_event(args), "space": args.space}, indent=2))


def cmd_search(args: argparse.Namespace) -> None:
    emb = vector_literal(embed(args.query))
    params: list[Any] = [args.query, emb]
    where = ""
    if args.space and not args.all_spaces:
        where = "WHERE space = %s"
        params.append(args.space)
    params.append(args.limit)
    with connect() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            f"""
            SELECT id, created_at, space, agent, event_type, memory_kind, role,
                   summary, left(content, 800) AS content,
                   ts_rank_cd(search_vector, websearch_to_tsquery('english', %s)) AS text_rank,
                   embedding <=> %s::vector AS vector_distance
            FROM agent_memory_events
            {where}
            ORDER BY
              CASE WHEN search_vector @@ websearch_to_tsquery('english', %s) THEN 0 ELSE 1 END,
              vector_distance ASC,
              created_at DESC
            LIMIT %s
            """,
            [args.query, emb] + ([args.space] if where else []) + [args.query, args.limit],
        )
        print(json.dumps(list(cur.fetchall()), indent=2, default=str))


def cmd_hook(args: argparse.Namespace) -> None:
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        content = (
            payload.get("prompt")
            or payload.get("result")
            or payload.get("output")
            or payload.get("transcript")
            or json.dumps(payload, sort_keys=True)
        )
        hook_args = argparse.Namespace(
            space=args.space,
            agent=args.agent,
            session_id=payload.get("session_id") or args.session_id,
            event_type=args.event_type,
            memory_kind=args.memory_kind,
            role=args.role,
            source=args.source,
            content=str(content),
            summary=args.summary or str(content)[:240],
            tags=args.tags,
            metadata=json.dumps({"raw_payload": redact(payload)}),
        )
        add_event(hook_args)
    except Exception as exc:
        print(f"memory hook failed: {exc}", file=sys.stderr)
    return None


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init").set_defaults(func=cmd_init)
    sub.add_parser("status").set_defaults(func=cmd_status)
    add = sub.add_parser("add")
    add.add_argument("--space", default=os.getenv("AGENT_MEMORY_SPACE", "default"))
    add.add_argument("--agent", default=os.getenv("AGENT_MEMORY_AGENT", "agent"))
    add.add_argument("--session-id")
    add.add_argument("--event-type", default="note")
    add.add_argument("--memory-kind", default="event")
    add.add_argument("--role", default="assistant")
    add.add_argument("--source", default="manual")
    add.add_argument("--tags", default="")
    add.add_argument("--summary")
    add.add_argument("--metadata")
    add.add_argument("--content", required=True)
    add.set_defaults(func=cmd_add)
    search = sub.add_parser("search")
    search.add_argument("query")
    search.add_argument("--space", default=os.getenv("AGENT_MEMORY_SPACE", "default"))
    search.add_argument("--all-spaces", action="store_true")
    search.add_argument("--limit", type=int, default=8)
    search.set_defaults(func=cmd_search)
    hook = sub.add_parser("hook")
    hook.add_argument("--space", default=os.getenv("AGENT_MEMORY_SPACE", "default"))
    hook.add_argument("--agent", default=os.getenv("AGENT_MEMORY_AGENT", "agent"))
    hook.add_argument("--session-id")
    hook.add_argument("--event-type", required=True)
    hook.add_argument("--memory-kind", default="hook_event")
    hook.add_argument("--role", default="system")
    hook.add_argument("--source", default="harness_hook")
    hook.add_argument("--tags", default="hook")
    hook.add_argument("--summary")
    hook.set_defaults(func=cmd_hook)
    return p


def main() -> None:
    args = parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
