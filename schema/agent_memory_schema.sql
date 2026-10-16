-- Reference copy of the schema that `python agent_memory.py init` creates.
-- Do not apply this by hand; run init, which also migrates older databases.
-- Regenerate: pg_dump --schema-only --no-owner --no-privileges against a fresh init.

--
-- PostgreSQL database dump
--


-- Dumped from database version 16.13 (Debian 16.13-1.pgdg12+1)
-- Dumped by pg_dump version 16.13 (Debian 16.13-1.pgdg12+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: agent_memory_bump_search_mutation_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.agent_memory_bump_search_mutation_revision() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE agent_memory_search_state
                SET mutation_revision = mutation_revision + 1, updated_at = NOW()
                WHERE singleton = TRUE;
                RETURN NULL;
            END;
            $$;


--
-- Name: agent_memory_bump_search_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.agent_memory_bump_search_revision() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE agent_memory_search_state
                SET revision = revision + 1, updated_at = NOW()
                WHERE singleton = TRUE;
                RETURN NULL;
            END;
            $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agent_memory_entities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memory_entities (
    id bigint NOT NULL,
    space text DEFAULT 'global'::text NOT NULL,
    name text NOT NULL,
    kind text DEFAULT 'concept'::text NOT NULL,
    summary text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_memory_entities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_memory_entities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_memory_entities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_memory_entities_id_seq OWNED BY public.agent_memory_entities.id;


--
-- Name: agent_memory_entity_edges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memory_entity_edges (
    id bigint NOT NULL,
    space text DEFAULT 'global'::text NOT NULL,
    source_entity_id bigint NOT NULL,
    target_entity_id bigint NOT NULL,
    relation text DEFAULT 'related_to'::text NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_memory_entity_edges_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_memory_entity_edges_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_memory_entity_edges_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_memory_entity_edges_id_seq OWNED BY public.agent_memory_entity_edges.id;


--
-- Name: agent_memory_entity_mentions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memory_entity_mentions (
    event_id bigint NOT NULL,
    entity_id bigint NOT NULL,
    weight real DEFAULT 1.0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_memory_event_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memory_event_links (
    id bigint NOT NULL,
    source_event_id bigint NOT NULL,
    target_event_id bigint NOT NULL,
    link_type text DEFAULT 'related_to'::text NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_memory_event_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_memory_event_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_memory_event_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_memory_event_links_id_seq OWNED BY public.agent_memory_event_links.id;


--
-- Name: agent_memory_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memory_events (
    id bigint NOT NULL,
    event_uid text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    space text DEFAULT 'global'::text NOT NULL,
    session_id text,
    agent text NOT NULL,
    event_type text NOT NULL,
    memory_kind text DEFAULT 'event'::text NOT NULL,
    role text,
    source text,
    content text NOT NULL,
    summary text,
    tags text[] DEFAULT ARRAY[]::text[] NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    embedding public.vector(384),
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((COALESCE(content, ''::text) || ' '::text) || COALESCE(summary, ''::text)))) STORED
);


--
-- Name: agent_memory_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_memory_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_memory_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_memory_events_id_seq OWNED BY public.agent_memory_events.id;


--
-- Name: agent_memory_payload_archives; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memory_payload_archives (
    id bigint NOT NULL,
    event_id bigint,
    event_uid text NOT NULL,
    payload_sha256 text NOT NULL,
    payload_kind text DEFAULT 'hook_payload'::text NOT NULL,
    payload_format text DEFAULT 'json'::text NOT NULL,
    compression text DEFAULT 'zlib'::text NOT NULL,
    raw_chars bigint NOT NULL,
    compressed_bytes bigint NOT NULL,
    redacted boolean DEFAULT true NOT NULL,
    space text DEFAULT 'global'::text NOT NULL,
    session_id text,
    agent text NOT NULL,
    event_type text NOT NULL,
    source text,
    payload bytea NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_memory_payload_archives_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_memory_payload_archives_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_memory_payload_archives_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_memory_payload_archives_id_seq OWNED BY public.agent_memory_payload_archives.id;


--
-- Name: agent_memory_search_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memory_search_cache (
    cache_key text NOT NULL,
    revision bigint NOT NULL,
    mutation_revision bigint DEFAULT 0 NOT NULL,
    max_event_id bigint DEFAULT 0 NOT NULL,
    results jsonb NOT NULL,
    result_count integer NOT NULL,
    hit_count bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    refreshed_at timestamp with time zone DEFAULT now() NOT NULL,
    last_accessed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_memory_search_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memory_search_state (
    singleton boolean DEFAULT true NOT NULL,
    revision bigint DEFAULT 0 NOT NULL,
    mutation_revision bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT agent_memory_search_state_singleton_check CHECK (singleton)
);


--
-- Name: agent_memory_spaces; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_memory_spaces (
    space text NOT NULL,
    description text,
    parent_space text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_memory_entities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_entities ALTER COLUMN id SET DEFAULT nextval('public.agent_memory_entities_id_seq'::regclass);


--
-- Name: agent_memory_entity_edges id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_entity_edges ALTER COLUMN id SET DEFAULT nextval('public.agent_memory_entity_edges_id_seq'::regclass);


--
-- Name: agent_memory_event_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_event_links ALTER COLUMN id SET DEFAULT nextval('public.agent_memory_event_links_id_seq'::regclass);


--
-- Name: agent_memory_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_events ALTER COLUMN id SET DEFAULT nextval('public.agent_memory_events_id_seq'::regclass);


--
-- Name: agent_memory_payload_archives id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_payload_archives ALTER COLUMN id SET DEFAULT nextval('public.agent_memory_payload_archives_id_seq'::regclass);


--
-- Name: agent_memory_entities agent_memory_entities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_entities
    ADD CONSTRAINT agent_memory_entities_pkey PRIMARY KEY (id);


--
-- Name: agent_memory_entity_edges agent_memory_entity_edges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_entity_edges
    ADD CONSTRAINT agent_memory_entity_edges_pkey PRIMARY KEY (id);


--
-- Name: agent_memory_entity_mentions agent_memory_entity_mentions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_entity_mentions
    ADD CONSTRAINT agent_memory_entity_mentions_pkey PRIMARY KEY (event_id, entity_id);


--
-- Name: agent_memory_event_links agent_memory_event_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_event_links
    ADD CONSTRAINT agent_memory_event_links_pkey PRIMARY KEY (id);


--
-- Name: agent_memory_events agent_memory_events_event_uid_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_events
    ADD CONSTRAINT agent_memory_events_event_uid_key UNIQUE (event_uid);


--
-- Name: agent_memory_events agent_memory_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_events
    ADD CONSTRAINT agent_memory_events_pkey PRIMARY KEY (id);


--
-- Name: agent_memory_payload_archives agent_memory_payload_archives_event_uid_payload_kind_payloa_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_payload_archives
    ADD CONSTRAINT agent_memory_payload_archives_event_uid_payload_kind_payloa_key UNIQUE (event_uid, payload_kind, payload_sha256);


--
-- Name: agent_memory_payload_archives agent_memory_payload_archives_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_payload_archives
    ADD CONSTRAINT agent_memory_payload_archives_pkey PRIMARY KEY (id);


--
-- Name: agent_memory_search_cache agent_memory_search_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_search_cache
    ADD CONSTRAINT agent_memory_search_cache_pkey PRIMARY KEY (cache_key);


--
-- Name: agent_memory_search_state agent_memory_search_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_search_state
    ADD CONSTRAINT agent_memory_search_state_pkey PRIMARY KEY (singleton);


--
-- Name: agent_memory_spaces agent_memory_spaces_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_spaces
    ADD CONSTRAINT agent_memory_spaces_pkey PRIMARY KEY (space);


--
-- Name: agent_memory_entities_name_trgm_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_entities_name_trgm_idx ON public.agent_memory_entities USING gin (name public.gin_trgm_ops);


--
-- Name: agent_memory_entities_space_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_entities_space_idx ON public.agent_memory_entities USING btree (space, kind, updated_at DESC);


--
-- Name: agent_memory_entities_space_name_kind_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_memory_entities_space_name_kind_uidx ON public.agent_memory_entities USING btree (space, lower(name), kind);


--
-- Name: agent_memory_entity_edges_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_entity_edges_source_idx ON public.agent_memory_entity_edges USING btree (source_entity_id, relation);


--
-- Name: agent_memory_entity_edges_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX agent_memory_entity_edges_uidx ON public.agent_memory_entity_edges USING btree (space, source_entity_id, target_entity_id, relation);


--
-- Name: agent_memory_event_links_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_event_links_source_idx ON public.agent_memory_event_links USING btree (source_event_id, link_type);


--
-- Name: agent_memory_events_agent_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_events_agent_type_idx ON public.agent_memory_events USING btree (agent, event_type, created_at DESC);


--
-- Name: agent_memory_events_content_trgm_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_events_content_trgm_idx ON public.agent_memory_events USING gin (content public.gin_trgm_ops);


--
-- Name: agent_memory_events_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_events_created_idx ON public.agent_memory_events USING btree (created_at DESC);


--
-- Name: agent_memory_events_embedding_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_events_embedding_idx ON public.agent_memory_events USING hnsw (embedding public.vector_cosine_ops) WITH (m='16', ef_construction='100');


--
-- Name: agent_memory_events_identity_gin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_events_identity_gin_idx ON public.agent_memory_events USING gin (((metadata -> 'identity'::text))) WHERE (metadata ? 'identity'::text);


--
-- Name: agent_memory_events_search_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_events_search_idx ON public.agent_memory_events USING gin (search_vector);


--
-- Name: agent_memory_events_space_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_events_space_created_idx ON public.agent_memory_events USING btree (space, created_at DESC);


--
-- Name: agent_memory_events_space_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_events_space_kind_idx ON public.agent_memory_events USING btree (space, memory_kind, created_at DESC);


--
-- Name: agent_memory_events_tags_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_events_tags_idx ON public.agent_memory_events USING gin (tags);


--
-- Name: agent_memory_payload_archives_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_payload_archives_event_idx ON public.agent_memory_payload_archives USING btree (event_id, payload_kind, created_at DESC);


--
-- Name: agent_memory_payload_archives_hash_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_payload_archives_hash_idx ON public.agent_memory_payload_archives USING btree (payload_sha256);


--
-- Name: agent_memory_payload_archives_session_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_payload_archives_session_idx ON public.agent_memory_payload_archives USING btree (session_id, created_at DESC);


--
-- Name: agent_memory_payload_archives_space_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_payload_archives_space_idx ON public.agent_memory_payload_archives USING btree (space, created_at DESC);


--
-- Name: agent_memory_search_cache_accessed_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_memory_search_cache_accessed_idx ON public.agent_memory_search_cache USING btree (last_accessed_at DESC);


--
-- Name: agent_memory_events agent_memory_events_search_mutation_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agent_memory_events_search_mutation_trg AFTER DELETE OR UPDATE ON public.agent_memory_events FOR EACH ROW EXECUTE FUNCTION public.agent_memory_bump_search_mutation_revision();


--
-- Name: agent_memory_events agent_memory_events_search_revision_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER agent_memory_events_search_revision_trg AFTER INSERT OR DELETE OR UPDATE ON public.agent_memory_events FOR EACH STATEMENT EXECUTE FUNCTION public.agent_memory_bump_search_revision();


--
-- Name: agent_memory_entity_edges agent_memory_entity_edges_source_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_entity_edges
    ADD CONSTRAINT agent_memory_entity_edges_source_entity_id_fkey FOREIGN KEY (source_entity_id) REFERENCES public.agent_memory_entities(id) ON DELETE CASCADE;


--
-- Name: agent_memory_entity_edges agent_memory_entity_edges_target_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_entity_edges
    ADD CONSTRAINT agent_memory_entity_edges_target_entity_id_fkey FOREIGN KEY (target_entity_id) REFERENCES public.agent_memory_entities(id) ON DELETE CASCADE;


--
-- Name: agent_memory_entity_mentions agent_memory_entity_mentions_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_entity_mentions
    ADD CONSTRAINT agent_memory_entity_mentions_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.agent_memory_entities(id) ON DELETE CASCADE;


--
-- Name: agent_memory_entity_mentions agent_memory_entity_mentions_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_entity_mentions
    ADD CONSTRAINT agent_memory_entity_mentions_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.agent_memory_events(id) ON DELETE CASCADE;


--
-- Name: agent_memory_event_links agent_memory_event_links_source_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_event_links
    ADD CONSTRAINT agent_memory_event_links_source_event_id_fkey FOREIGN KEY (source_event_id) REFERENCES public.agent_memory_events(id) ON DELETE CASCADE;


--
-- Name: agent_memory_event_links agent_memory_event_links_target_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_event_links
    ADD CONSTRAINT agent_memory_event_links_target_event_id_fkey FOREIGN KEY (target_event_id) REFERENCES public.agent_memory_events(id) ON DELETE CASCADE;


--
-- Name: agent_memory_payload_archives agent_memory_payload_archives_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_payload_archives
    ADD CONSTRAINT agent_memory_payload_archives_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.agent_memory_events(id) ON DELETE CASCADE;


--
-- Name: agent_memory_spaces agent_memory_spaces_parent_space_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_memory_spaces
    ADD CONSTRAINT agent_memory_spaces_parent_space_fkey FOREIGN KEY (parent_space) REFERENCES public.agent_memory_spaces(space) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--


