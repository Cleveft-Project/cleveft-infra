-- ============================================================================
--  Migration 001 — align an existing dev database with init.sql
--  ---------------------------------------------------------------------------
--  Only needed for databases created BEFORE the schema was made canonical. A
--  fresh `docker compose down -v && up` runs init.sql and does not need this.
--
--  What it repairs:
--    * auth.users was created by Hibernate's ddl-auto=update, not init.sql, so
--      it has a bigint id and username/password columns. Every other service
--      stores user_id as a UUID, so those ids could never have matched.
--    * transcription.* drifted from init.sql (missing user_id, topic_tag,
--      status_detail, structured_notes, key_concepts).
--    * query.document_chunks is dead — retrieval now goes through the
--      transcription service, which owns the only vector table.
--    * collab.* and the exam_prep/query tables were never created.
--
--  Existing user accounts are preserved: email and bcrypt hash carry over, and
--  each row is assigned a UUID. Passwords keep working.
--
--  Run with:
--    docker exec -i cleveft-postgres psql -U cleveft_user -d cleveft \
--      < cleveft-infra/migrations/001_align_to_canonical_schema.sql
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS transcription;
CREATE SCHEMA IF NOT EXISTS query;
CREATE SCHEMA IF NOT EXISTS exam_prep;
CREATE SCHEMA IF NOT EXISTS collab;

-- ---------------------------------------------------------------- auth ------
-- Rebuild auth.users with a UUID primary key, carrying existing accounts over.

DO $$
DECLARE
    id_type TEXT;
BEGIN
    SELECT data_type INTO id_type
    FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'id';

    IF id_type IS NULL THEN
        -- No table at all: create the canonical one.
        CREATE TABLE auth.users (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            full_name     VARCHAR(255) NOT NULL,
            email         VARCHAR(255) UNIQUE NOT NULL,
            password_hash VARCHAR(255) NOT NULL,
            role          VARCHAR(32)  NOT NULL DEFAULT 'STUDENT',
            university    VARCHAR(255),
            programme     VARCHAR(255),
            created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
            updated_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
        );

    ELSIF id_type <> 'uuid' THEN
        -- Hibernate's bigint version. Copy the accounts into a UUID table.
        CREATE TABLE auth.users_migrated (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            full_name     VARCHAR(255) NOT NULL,
            email         VARCHAR(255) UNIQUE NOT NULL,
            password_hash VARCHAR(255) NOT NULL,
            role          VARCHAR(32)  NOT NULL DEFAULT 'STUDENT',
            university    VARCHAR(255),
            programme     VARCHAR(255),
            created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
            updated_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
        );

        -- The old table had no name field, so the username stands in until the
        -- student edits their profile. The bcrypt hash moves across untouched.
        INSERT INTO auth.users_migrated (full_name, email, password_hash, role)
        SELECT
            COALESCE(NULLIF(u.username, ''), split_part(u.email, '@', 1)),
            lower(u.email),
            u.password,
            'STUDENT'
        FROM auth.users u;

        DROP TABLE auth.users;
        ALTER TABLE auth.users_migrated RENAME TO users;
    END IF;
END $$;

-- Columns the auth service now maps, for a database that already had the
-- UUID-keyed init.sql table.
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS role       VARCHAR(32) NOT NULL DEFAULT 'STUDENT';
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS university VARCHAR(255);
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS programme  VARCHAR(255);

CREATE INDEX IF NOT EXISTS idx_users_email ON auth.users (email);

CREATE TABLE IF NOT EXISTS auth.refresh_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    token_hash  VARCHAR(255) UNIQUE NOT NULL,
    expires_at  TIMESTAMP WITH TIME ZONE NOT NULL,
    revoked     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON auth.refresh_tokens (user_id);

-- ------------------------------------------------------- transcription ------

ALTER TABLE transcription.lectures ADD COLUMN IF NOT EXISTS audio_path       VARCHAR(1000);
ALTER TABLE transcription.lectures ADD COLUMN IF NOT EXISTS status_detail    TEXT;
ALTER TABLE transcription.lectures ADD COLUMN IF NOT EXISTS structured_notes JSONB;
ALTER TABLE transcription.lectures ADD COLUMN IF NOT EXISTS key_concepts     JSONB;

-- Widen the columns Hibernate created too small for real values.
ALTER TABLE transcription.lectures ALTER COLUMN title      TYPE VARCHAR(500);
ALTER TABLE transcription.lectures ALTER COLUMN source_url TYPE VARCHAR(1000);
ALTER TABLE transcription.lectures ALTER COLUMN language   TYPE VARCHAR(16);

-- Timestamps must be timezone-aware to match the entities.
ALTER TABLE transcription.lectures
    ALTER COLUMN created_at TYPE TIMESTAMP WITH TIME ZONE,
    ALTER COLUMN updated_at TYPE TIMESTAMP WITH TIME ZONE;

ALTER TABLE transcription.lectures ALTER COLUMN updated_at SET DEFAULT NOW();
UPDATE transcription.lectures SET updated_at = NOW() WHERE updated_at IS NULL;
ALTER TABLE transcription.lectures ALTER COLUMN updated_at SET NOT NULL;

-- chunks.user_id lets retrieval filter by owner without joining lectures.
ALTER TABLE transcription.chunks ADD COLUMN IF NOT EXISTS user_id   UUID;
ALTER TABLE transcription.chunks ADD COLUMN IF NOT EXISTS topic_tag VARCHAR(255);

UPDATE transcription.chunks c
SET user_id = l.user_id
FROM transcription.lectures l
WHERE c.lecture_id = l.id AND c.user_id IS NULL;

-- Only enforce NOT NULL once every row has a value; a half-migrated table
-- would otherwise fail the constraint and abort the whole migration.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM transcription.chunks WHERE user_id IS NULL) THEN
        ALTER TABLE transcription.chunks ALTER COLUMN user_id SET NOT NULL;
    END IF;
END $$;

ALTER TABLE transcription.chunks
    ALTER COLUMN created_at TYPE TIMESTAMP WITH TIME ZONE;

ALTER TABLE transcription.chunks
    DROP CONSTRAINT IF EXISTS uq_chunk_position;
ALTER TABLE transcription.chunks
    ADD CONSTRAINT uq_chunk_position UNIQUE (lecture_id, chunk_index);

CREATE INDEX IF NOT EXISTS idx_chunks_lecture ON transcription.chunks (lecture_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_chunks_user    ON transcription.chunks (user_id);
CREATE INDEX IF NOT EXISTS idx_chunks_embedding_hnsw
    ON transcription.chunks USING hnsw (embedding vector_cosine_ops);

-- --------------------------------------------------------------- query ------
-- Nothing ever wrote to this table; retrieval now lives behind the
-- transcription service's API.
DROP TABLE IF EXISTS query.document_chunks;

CREATE TABLE IF NOT EXISTS query.conversations (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    lecture_id UUID,
    title      VARCHAR(500),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_conversations_user ON query.conversations (user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS query.messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES query.conversations (id) ON DELETE CASCADE,
    role            VARCHAR(20) NOT NULL,
    content         TEXT NOT NULL,
    citations       JSONB,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_message_role CHECK (role IN ('user', 'assistant'))
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation
    ON query.messages (conversation_id, created_at);

CREATE TABLE IF NOT EXISTS query.query_log (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    lecture_id UUID,
    question   TEXT NOT NULL,
    topic_tag  VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_query_log_user ON query.query_log (user_id, created_at DESC);

-- ----------------------------------------------------------- exam_prep ------

DROP TABLE IF EXISTS exam_prep.quiz_attempts;
DROP TABLE IF EXISTS exam_prep.quizzes;
DROP TABLE IF EXISTS exam_prep.topic_analytics;
DROP TABLE IF EXISTS exam_prep.summaries;

CREATE TABLE exam_prep.quizzes (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    lecture_id UUID NOT NULL,
    title      VARCHAR(500),
    difficulty VARCHAR(20) NOT NULL DEFAULT 'MEDIUM',
    questions  JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_quiz_difficulty CHECK (difficulty IN ('EASY', 'MEDIUM', 'HARD'))
);

CREATE INDEX idx_quizzes_user ON exam_prep.quizzes (user_id, created_at DESC);

CREATE TABLE exam_prep.quiz_attempts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quiz_id         UUID NOT NULL REFERENCES exam_prep.quizzes (id) ON DELETE CASCADE,
    user_id         UUID NOT NULL,
    lecture_id      UUID NOT NULL,
    answers         JSONB NOT NULL,
    score           INTEGER NOT NULL,
    total_questions INTEGER NOT NULL,
    started_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMP WITH TIME ZONE
);

CREATE INDEX idx_attempts_user ON exam_prep.quiz_attempts (user_id, completed_at DESC);

CREATE TABLE exam_prep.topic_analytics (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL,
    lecture_id    UUID,
    topic_tag     VARCHAR(255) NOT NULL,
    query_count   INTEGER NOT NULL DEFAULT 0,
    correct_count INTEGER NOT NULL DEFAULT 0,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    mastery_score DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    last_queried  TIMESTAMP WITH TIME ZONE,
    updated_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_topic_per_user UNIQUE (user_id, topic_tag)
);

CREATE INDEX idx_topic_analytics_user ON exam_prep.topic_analytics (user_id);

CREATE TABLE exam_prep.summaries (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lecture_id         UUID NOT NULL,
    user_id            UUID NOT NULL,
    summary_text       TEXT,
    key_concepts       JSONB,
    likely_exam_topics JSONB,
    created_at         TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_summary_per_lecture UNIQUE (user_id, lecture_id)
);

-- -------------------------------------------------------------- collab ------

CREATE TABLE IF NOT EXISTS collab.peer_links (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id UUID NOT NULL,
    addressee_id UUID NOT NULL,
    status       VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_peer_status CHECK (status IN ('PENDING', 'ACCEPTED', 'DECLINED', 'BLOCKED')),
    CONSTRAINT chk_no_self_link CHECK (requester_id <> addressee_id),
    CONSTRAINT uq_peer_pair UNIQUE (requester_id, addressee_id)
);

CREATE INDEX IF NOT EXISTS idx_peer_links_addressee ON collab.peer_links (addressee_id, status);
CREATE INDEX IF NOT EXISTS idx_peer_links_requester ON collab.peer_links (requester_id, status);

CREATE TABLE IF NOT EXISTS collab.learning_paths (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id    UUID NOT NULL,
    owner_name  VARCHAR(255),
    title       VARCHAR(500) NOT NULL,
    description TEXT,
    course_code VARCHAR(255),
    visibility  VARCHAR(20) NOT NULL DEFAULT 'PEERS',
    adopt_count INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_path_visibility CHECK (visibility IN ('PRIVATE', 'PEERS', 'PUBLIC'))
);

CREATE INDEX IF NOT EXISTS idx_paths_owner  ON collab.learning_paths (owner_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_paths_course ON collab.learning_paths (course_code, visibility);

CREATE TABLE IF NOT EXISTS collab.learning_path_steps (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    path_id       UUID NOT NULL REFERENCES collab.learning_paths (id) ON DELETE CASCADE,
    step_index    INTEGER NOT NULL,
    question      TEXT NOT NULL,
    answer_digest TEXT,
    lecture_id    UUID,
    note          TEXT,
    created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_step_position UNIQUE (path_id, step_index)
);

CREATE INDEX IF NOT EXISTS idx_steps_path ON collab.learning_path_steps (path_id, step_index);

CREATE TABLE IF NOT EXISTS collab.path_adoptions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    path_id       UUID NOT NULL REFERENCES collab.learning_paths (id) ON DELETE CASCADE,
    adopter_id    UUID NOT NULL,
    progress_step INTEGER NOT NULL DEFAULT 0,
    adopted_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_adoption UNIQUE (path_id, adopter_id)
);

CREATE INDEX IF NOT EXISTS idx_adoptions_adopter ON collab.path_adoptions (adopter_id);

CREATE TABLE IF NOT EXISTS collab.shared_threads (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id      UUID NOT NULL,
    owner_name    VARCHAR(255),
    lecture_id    UUID,
    lecture_title VARCHAR(500),
    question      TEXT NOT NULL,
    answer        TEXT NOT NULL,
    citations     JSONB,
    visibility    VARCHAR(20) NOT NULL DEFAULT 'PEERS',
    created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_thread_visibility CHECK (visibility IN ('PRIVATE', 'PEERS', 'PUBLIC'))
);

CREATE INDEX IF NOT EXISTS idx_threads_owner   ON collab.shared_threads (owner_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_threads_created ON collab.shared_threads (created_at DESC);

COMMIT;
