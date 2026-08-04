-- ============================================================================
--  Cleveft — canonical database schema
--  ---------------------------------------------------------------------------
--  This file is the SINGLE SOURCE OF TRUTH for the Cleveft data model.
--  Every microservice runs with spring.jpa.hibernate.ddl-auto=none and maps its
--  entities onto the tables defined here. If you change a column, change it here
--  first, then update the owning service's entity.
--
--  Schema ownership (one schema per microservice, no cross-schema writes):
--    auth          -> Cleveft-auth-service          (8084)
--    transcription -> cleveft-transcription-service (8082)   [owns the vectors]
--    query         -> cleveft-query-service         (8081)
--    exam_prep     -> cleveft-examprep-service      (8085)
--    collab        -> cleveft-collab-service        (8086)
--
--  Services never SELECT across another service's schema. Retrieval that needs
--  lecture chunks goes over HTTP to the transcription service.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS transcription;
CREATE SCHEMA IF NOT EXISTS query;
CREATE SCHEMA IF NOT EXISTS exam_prep;
CREATE SCHEMA IF NOT EXISTS collab;

-- ============================================================================
--  AUTH
-- ============================================================================

-- `plan` drives the freemium model: FREE is capped at a set number of
-- recordings a month, PRO lifts the cap. Only the auth service writes it;
-- the transcription service reads it over HTTP to enforce the quota.
CREATE TABLE IF NOT EXISTS auth.users (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name      VARCHAR(255) NOT NULL,
    email          VARCHAR(255) UNIQUE NOT NULL,
    password_hash  VARCHAR(255) NOT NULL,
    role           VARCHAR(32)  NOT NULL DEFAULT 'STUDENT',
    plan           VARCHAR(32)  NOT NULL DEFAULT 'FREE',
    -- NULL on FREE; on PRO, NULL means it does not expire.
    plan_renews_at TIMESTAMP WITH TIME ZONE,
    university     VARCHAR(255),
    programme      VARCHAR(255),
    -- Normalised course codes, so Cleveft can answer "who else takes CSM 266?"
    -- Read only by containment, which is why it is an array and not a table.
    courses        JSONB        NOT NULL DEFAULT '[]'::jsonb,
    -- Whether the address has been proved to belong to whoever signed up.
    -- Defaults TRUE so nobody who registered before verification existed is
    -- locked out retroactively.
    email_verified BOOLEAN      NOT NULL DEFAULT TRUE,
    -- Which pushes this student wants. Always read and written whole and only
    -- by its owner, which is why it is a column rather than five joins.
    -- Defaults and their reasoning are documented in migration 010.
    notification_prefs JSONB    NOT NULL DEFAULT '{
        "lectureReady": true,
        "pathAdopted": true,
        "peerRequest": true,
        "dailyReminder": true,
        "dailyReminderAt": "19:00",
        "circleActivity": false,
        "weeklySummary": true,
        "quietHoursFrom": "22:00",
        "quietHoursTo": "07:00"
    }'::jsonb,
    -- IANA name from the device. "19:00" is not a time without it.
    timezone       VARCHAR(64)  NOT NULL DEFAULT 'Africa/Accra',
    created_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_users_plan CHECK (plan IN ('FREE', 'PRO'))
);

CREATE INDEX IF NOT EXISTS idx_users_email ON auth.users (email);
CREATE INDEX IF NOT EXISTS idx_users_courses ON auth.users USING GIN (courses jsonb_path_ops);

-- One-time codes for password reset and email verification. Both features are
-- the same machinery, so they share one table; only what happens on a
-- successful check differs. Codes are hashed for the same reason passwords are.
CREATE TABLE IF NOT EXISTS auth.verification_codes (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- By email, not user_id: a sign-up code exists before any user row does.
    email        VARCHAR(255) NOT NULL,
    purpose      VARCHAR(32)  NOT NULL,
    code_hash    VARCHAR(255) NOT NULL,
    expires_at   TIMESTAMP WITH TIME ZONE NOT NULL,
    -- Kept rather than deleted once used, so a replay is distinguishable from a
    -- code that never existed.
    consumed_at  TIMESTAMP WITH TIME ZONE,
    attempts     SMALLINT     NOT NULL DEFAULT 0,
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_verification_purpose
        CHECK (purpose IN ('PASSWORD_RESET', 'EMAIL_VERIFICATION'))
);

CREATE INDEX IF NOT EXISTS idx_verification_lookup
    ON auth.verification_codes (email, purpose, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_verification_expiry
    ON auth.verification_codes (expires_at);

-- Refresh tokens are persisted so that logout / rotation can revoke them.
CREATE TABLE IF NOT EXISTS auth.refresh_tokens (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    token_hash  VARCHAR(255) UNIQUE NOT NULL,
    expires_at  TIMESTAMP WITH TIME ZONE NOT NULL,
    revoked     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON auth.refresh_tokens (user_id);

-- Where a push goes. The token identifies a phone rather than an account, so it
-- is unique across the table and not per user: signing in on a borrowed handset
-- moves the token instead of leaving the previous student subscribed to it.
CREATE TABLE IF NOT EXISTS auth.device_tokens (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    token        VARCHAR(255) UNIQUE NOT NULL,
    platform     VARCHAR(16)  NOT NULL,
    last_seen_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_device_platform CHECK (platform IN ('ios', 'android', 'web'))
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON auth.device_tokens (user_id);

-- ============================================================================
--  TRANSCRIPTION  (owns lecture audio, transcripts and the vector index)
-- ============================================================================

CREATE TABLE IF NOT EXISTS transcription.lectures (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          UUID NOT NULL,
    title            VARCHAR(500) NOT NULL,
    course_code      VARCHAR(255),
    source_url       VARCHAR(1000),
    audio_path       VARCHAR(1000),
    language         VARCHAR(16) DEFAULT 'en',
    duration_seconds INTEGER,
    status           VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    status_detail    TEXT,
    -- Where the words came from. Only affects how the transcript was obtained;
    -- everything downstream treats all three identically.
    source           VARCHAR(20) NOT NULL DEFAULT 'RECORDING',
    -- Supporting material points at the lecture it explains. Null means the item
    -- stands on its own. Only rows with a NULL here count towards exam
    -- readiness: a video explains what you were taught, it does not decide what
    -- you will be examined on.
    related_lecture_id UUID REFERENCES transcription.lectures (id) ON DELETE SET NULL,
    full_transcript  TEXT,
    structured_notes JSONB,
    key_concepts     JSONB,
    created_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_lecture_status
        CHECK (status IN ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED')),
    CONSTRAINT lectures_source_check
        CHECK (source IN ('RECORDING', 'PDF', 'YOUTUBE'))
);

CREATE INDEX IF NOT EXISTS idx_lectures_user    ON transcription.lectures (user_id);
CREATE INDEX IF NOT EXISTS idx_lectures_created ON transcription.lectures (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_lectures_related ON transcription.lectures (related_lecture_id)
    WHERE related_lecture_id IS NOT NULL;

-- The one and only vector table in the system. The query, exam-prep and collab
-- services reach these rows through the transcription service's HTTP API.
CREATE TABLE IF NOT EXISTS transcription.chunks (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lecture_id  UUID NOT NULL REFERENCES transcription.lectures (id) ON DELETE CASCADE,
    user_id     UUID NOT NULL,
    chunk_index INTEGER NOT NULL,
    content     TEXT NOT NULL,
    start_time  DOUBLE PRECISION,
    end_time    DOUBLE PRECISION,
    topic_tag   VARCHAR(255),
    -- 768 dimensions maps natively onto Gemini text-embedding-004 output.
    embedding   VECTOR(768),
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_chunk_position UNIQUE (lecture_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS idx_chunks_lecture ON transcription.chunks (lecture_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_chunks_user    ON transcription.chunks (user_id);

-- HNSW index tuned for fast cosine-distance retrieval at scale.
CREATE INDEX IF NOT EXISTS idx_chunks_embedding_hnsw
    ON transcription.chunks USING hnsw (embedding vector_cosine_ops);

-- ============================================================================
--  QUERY  (RAG conversations — retrieval itself is delegated over HTTP)
-- ============================================================================

CREATE TABLE IF NOT EXISTS query.conversations (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    lecture_id UUID,                       -- NULL = course-wide conversation
    title      VARCHAR(500),
    -- Held above the date groups in history, for the few threads a student
    -- returns to all semester rather than works through once.
    pinned     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_conversations_user ON query.conversations (user_id, updated_at DESC);
-- Matches the order history is always read in, so the drawer is an index scan.
CREATE INDEX IF NOT EXISTS idx_conversations_user_pinned
    ON query.conversations (user_id, pinned DESC, updated_at DESC);

CREATE TABLE IF NOT EXISTS query.messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES query.conversations (id) ON DELETE CASCADE,
    role            VARCHAR(20) NOT NULL,
    content         TEXT NOT NULL,
    -- [{lectureId, lectureTitle, chunkId, chunkIndex, startTime, endTime, snippet, score}]
    citations       JSONB,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_message_role CHECK (role IN ('user', 'assistant'))
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation
    ON query.messages (conversation_id, created_at);

-- Every question a student asks is logged here so the exam-prep service can
-- mine it for "topics this student keeps struggling with".
CREATE TABLE IF NOT EXISTS query.query_log (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    lecture_id UUID,
    question   TEXT NOT NULL,
    topic_tag  VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_query_log_user ON query.query_log (user_id, created_at DESC);

-- ============================================================================
--  EXAM PREP
-- ============================================================================

CREATE TABLE IF NOT EXISTS exam_prep.quizzes (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL,
    -- Exactly one of these is set: a quiz covers one lecture, or one course.
    lecture_id   UUID,
    course_code  VARCHAR(64),
    title        VARCHAR(500),
    difficulty   VARCHAR(20) NOT NULL DEFAULT 'MEDIUM',
    -- [{id, prompt, options:[...], correctIndex, explanation, topicTag, lectureId}]
    questions    JSONB NOT NULL,
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_quiz_difficulty CHECK (difficulty IN ('EASY', 'MEDIUM', 'HARD')),
    CONSTRAINT chk_quiz_scope
        CHECK ((lecture_id IS NOT NULL) <> (course_code IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_quizzes_user ON exam_prep.quizzes (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_quizzes_user_course
    ON exam_prep.quizzes (user_id, course_code)
    WHERE course_code IS NOT NULL;

CREATE TABLE IF NOT EXISTS exam_prep.quiz_attempts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quiz_id         UUID NOT NULL REFERENCES exam_prep.quizzes (id) ON DELETE CASCADE,
    user_id         UUID NOT NULL,
    -- Mirrors the quiz it belongs to: lecture-scoped or course-scoped, never both.
    lecture_id      UUID,
    course_code     VARCHAR(64),
    -- [{questionId, selectedIndex, correct, topicTag, lectureId}]
    answers         JSONB NOT NULL,
    score           INTEGER NOT NULL,
    total_questions INTEGER NOT NULL,
    started_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMP WITH TIME ZONE,
    CONSTRAINT chk_attempt_scope
        CHECK ((lecture_id IS NOT NULL) <> (course_code IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_attempts_user ON exam_prep.quiz_attempts (user_id, completed_at DESC);

-- Rolling per-topic mastery signal. Updated on every quiz attempt and every
-- RAG query the student runs against that topic.
-- Mastery is tracked per (user, lecture, topic), not per (user, topic): a
-- topic taught in three lectures needs three scores, or quizzing one lecture
-- credits another, and two courses sharing a topic name contaminate each
-- other's readiness. lecture_id IS NULL means a query-only signal ("I keep
-- looking this up") that belongs to no single lecture.
CREATE TABLE IF NOT EXISTS exam_prep.topic_analytics (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID NOT NULL,
    lecture_id     UUID,
    topic_tag      VARCHAR(255) NOT NULL,
    query_count    INTEGER NOT NULL DEFAULT 0,
    correct_count  INTEGER NOT NULL DEFAULT 0,
    attempt_count  INTEGER NOT NULL DEFAULT 0,
    mastery_score  DOUBLE PRECISION NOT NULL DEFAULT 0.0,
    last_queried   TIMESTAMP WITH TIME ZONE,
    updated_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Partial indexes rather than one UNIQUE constraint: Postgres treats NULLs as
-- distinct, so UNIQUE (user_id, lecture_id, topic_tag) would allow unlimited
-- duplicate lecture-less rows for the same topic.
CREATE UNIQUE INDEX IF NOT EXISTS uq_topic_user_lecture
    ON exam_prep.topic_analytics (user_id, lecture_id, topic_tag)
    WHERE lecture_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_topic_user_no_lecture
    ON exam_prep.topic_analytics (user_id, topic_tag)
    WHERE lecture_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_topic_analytics_user ON exam_prep.topic_analytics (user_id);
CREATE INDEX IF NOT EXISTS idx_topic_analytics_user_lecture
    ON exam_prep.topic_analytics (user_id, lecture_id);

CREATE TABLE IF NOT EXISTS exam_prep.summaries (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lecture_id     UUID NOT NULL,
    user_id        UUID NOT NULL,
    summary_text   TEXT,
    key_concepts   JSONB,
    likely_exam_topics JSONB,
    created_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_summary_per_lecture UNIQUE (user_id, lecture_id)
);

-- ============================================================================
--  COLLAB
-- ============================================================================

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

-- A learning path is the ordered sequence of questions that produced mastery.
CREATE TABLE IF NOT EXISTS collab.learning_paths (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id      UUID NOT NULL,
    owner_name    VARCHAR(255),
    title         VARCHAR(500) NOT NULL,
    description   TEXT,
    course_code   VARCHAR(255),
    visibility    VARCHAR(20) NOT NULL DEFAULT 'PEERS',
    adopt_count   INTEGER NOT NULL DEFAULT 0,
    created_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
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

-- A single question + AI answer a student chose to share with their peers.
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
