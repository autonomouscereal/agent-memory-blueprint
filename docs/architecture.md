# Architecture

One PostgreSQL database holds everything. There is no second vector store, no
SQLite side cache and no ORM. All database access is raw, parameterized SQL
through `asyncpg`. `agent_memory.py init` creates and migrates the schema;
`schema/agent_memory_schema.sql` is a `pg_dump --schema-only` of a fresh
`init`, kept for reading.

## Tables

| Table | What it holds |
|---|---|
| `agent_memory_events` | One compact, searchable row per prompt, tool call, lifecycle event, note or document chunk. Has `space`, `agent`, `event_type`, `memory_kind`, `session_id`, `tags`, JSONB `metadata`, a 384-dim `embedding`, and a generated `tsvector`. |
| `agent_memory_payload_archives` | The full redacted hook payload behind each event, zlib-compressed into `BYTEA`, keyed by event id, event UID and SHA-256. Search never reads this table. |
| `agent_memory_spaces` | The project/topic namespaces, with optional parent space and description. |
| `agent_memory_entities`, `_entity_mentions`, `_entity_edges` | A small entity graph. Explicit notes and document chunks populate it; high-volume hook events deliberately do not. |
| `agent_memory_event_links` | Explicit links between events. |
| `agent_memory_search_state`, `agent_memory_search_cache` | Revision counters maintained by triggers, plus cached result sets for repeated queries. |

Indexes: HNSW on `embedding` (cosine), GIN on `search_vector`, GIN trigram on
`content`, GIN on `tags`, B-tree on `(space, created_at)` and friends, and a
partial GIN on `metadata->'identity'` for model/harness filters.

## Write path (hooks)

`agent_memory_hook.py` is what a harness runs on every prompt, tool call and
lifecycle event. It reads the hook JSON from stdin.

1. **Redact.** Structured secret keys (`password`, `api_key`, `authorization`,
   `*_token`, `*_secret`, cookies, ...) are replaced, and free text is scrubbed
   for credential URLs, auth/cookie headers, PEM private keys, JWTs and common
   provider token formats (`ghp_`, `github_pat_`, `sk-`, `xox?-`). Benign names
   like `token_count` are left alone. The redaction version is stamped on each
   archive.
2. **Compact.** Very long strings and `data:*;base64` blobs are replaced in the
   searchable row with a marker carrying the original length and SHA-256. That
   keeps rows under PostgreSQL's 1 MB `tsvector` limit while the full value
   still lives in the archive.
3. **Pick a space.** `--space`, else `AGENT_MEMORY_SPACE`, else a rule from
   `AGENT_MEMORY_WORKSPACE_SPACES`, else `workspace/<last directory of cwd>`.
4. **Attach identity.** Model ID, provider, harness and version, session and
   thread IDs, parent thread, sub-agent ID/path, turn ID, reasoning effort and
   GPU, when the payload or the harness's own transcript reports them. Each
   field records where it came from (`reported`, `configured`, `observed`,
   `unknown`). Model names are never guessed from prompt text.
5. **Commit once.** The compact event and its archive go in one transaction on
   one connection. The event UID is a hash of agent, source, event type,
   session and payload, so a retried hook is a no-op, not a duplicate.
6. **Never block.** Connect, statement, lock and idle-transaction timeouts are
   all bounded (defaults: 2 connect attempts, 4 s each, 15 s per statement,
   3 s per lock). On any failure the complete redacted record is written
   atomically to `logs/pending/` as a zlib file and the hook exits 0 with no
   output. The next successful hook replays one pending record;
   `agent_memory_hook.py --replay-pending` drains the rest.

## Read path (search)

`search` runs in two stages so it stays fast at a million-plus rows:

1. **Candidates.** A bounded pool (default 400) from the HNSW nearest-neighbour
   index plus a bounded pool from full-text search, filtered by space, agent,
   event type, kind and tags. Filtered HNSW uses pgvector's iterative scan when
   available.
2. **Rerank.** `0.68 x vector similarity + 0.22 x ts_rank_cd + 0.10 x trigram
   similarity`, plus a fixed bonus when every query term matches, so long
   documents are not buried by normalized ranks. Results under 0.18 are dropped,
   and identifier-like queries need lexical or trigram evidence, so a random
   vector neighbour can't pose as a match.

Embeddings are computed once at write time and stored; search never re-embeds
the corpus. Repeated queries hit `agent_memory_search_cache`. Triggers bump an
append revision on insert and a mutation revision on update/delete. If only new
rows arrived, the cache scores just the new ID range and merges it in.
Anything else forces a full indexed refresh.

`grep` is the audit tool: indexed full-text or trigram substring search, with
no vector scoring. Use it for exact error strings, IDs and paths.

`trace --event-id N` hydrates the full archived payload for a search hit and
verifies its SHA-256, character count and byte count on the way out.

## The embedder

The built-in embedder is a deterministic feature hash (tokens, character
trigrams and bigrams into 384 dimensions). It needs no GPU, no model server and
no network, and it is fast enough to run inline in every hook. It is lexical,
not neural: it will not match synonyms that share no words. With the full-text
and trigram signals blended in, that has been the right trade for agent work,
where queries are usually error strings, file names, tool names and project
words. A neural embedder can replace `cpu_embedding()` later; that means
re-embedding existing rows, and changing the dimension means altering the
column.

## Documents and media

`ingest-file` / `ingest-path` put files in the same tables as hook events. Each
file gets a `document_asset` event, a `document_chunk` event per chunk (3,500
chars with 350 overlap by default) and a full `document_extraction` archive,
all in one transaction. Supported: text, Markdown, JSON/YAML/XML/HTML, CSV/TSV,
PDF (Poppler, falling back to `pypdf`), DOCX, PPTX, XLSX (`openpyxl`), images
(Pillow metadata), and audio/video (ffprobe metadata). Same-stem sidecars such
as `.txt`, `.md`, `.srt`, `.vtt` and `.json` are indexed with the asset, which
is how transcripts and captions become searchable. Document archives are the
source text and are marked `redacted=false`.

## Identity backfill and recovery

- `backfill-identities` fills in missing model/harness identity on older events
  from the harness transcripts. It previews unless you pass `--apply`, only
  writes missing fields, and never changes content or timestamps.
- `ingest-codex-transcript <file> --apply` recovers prompts, replies and tool
  calls from one Codex session JSONL if its hooks were skipped. Event UIDs are
  stable, so re-running it is safe.
- `ingest-error-log` turns the hook error log into grouped, searchable
  summaries so failures show up in memory too.
