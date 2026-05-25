CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS agent_memory_events (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    space TEXT NOT NULL,
    agent TEXT NOT NULL,
    session_id TEXT,
    event_type TEXT NOT NULL,
    memory_kind TEXT NOT NULL DEFAULT 'event',
    role TEXT NOT NULL DEFAULT 'system',
    source TEXT NOT NULL DEFAULT 'manual',
    content TEXT NOT NULL,
    summary TEXT,
    tags TEXT[] NOT NULL DEFAULT '{}',
    metadata JSONB NOT NULL DEFAULT '{}',
    embedding VECTOR(64),
    search_vector TSVECTOR GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(summary, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(content, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(array_to_string(tags, ' '), '')), 'C')
    ) STORED
);

CREATE TABLE IF NOT EXISTS agent_memory_relations (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    space TEXT NOT NULL,
    source_text TEXT NOT NULL,
    relation TEXT NOT NULL,
    target_text TEXT NOT NULL,
    description TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_agent_memory_events_space_created
    ON agent_memory_events(space, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_memory_events_kind
    ON agent_memory_events(memory_kind);
CREATE INDEX IF NOT EXISTS idx_agent_memory_events_search
    ON agent_memory_events USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_agent_memory_events_content_trgm
    ON agent_memory_events USING GIN(content gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_agent_memory_events_embedding
    ON agent_memory_events USING ivfflat (embedding vector_cosine_ops) WITH (lists = 32);
