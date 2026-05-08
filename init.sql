-- Enable the pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Create schemas for each microservice
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS transcription;
CREATE SCHEMA IF NOT EXISTS query;
CREATE SCHEMA IF NOT EXISTS exam_prep;

-- AUTH SCHEMA TABLES
CREATE TABLE auth.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- TRANSCRIPTION SCHEMA TABLES
CREATE TABLE transcription.lectures (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    title VARCHAR(500),
    course_name VARCHAR(255),
    raw_transcript TEXT,
    structured_notes JSONB,
    status VARCHAR(50) DEFAULT 'processing',
    duration_seconds INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE transcription.chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lecture_id UUID REFERENCES transcription.lectures(id) ON DELETE CASCADE,
    chunk_text TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    embedding vector(1536),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- QUERY SCHEMA TABLES
CREATE TABLE query.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    lecture_id UUID NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE query.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES query.conversations(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL CHECK (role IN ('user', 'assistant')),
    content TEXT NOT NULL,
    source_chunks JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- EXAM PREP SCHEMA TABLES
CREATE TABLE exam_prep.summaries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lecture_id UUID NOT NULL,
    user_id UUID NOT NULL,
    summary_text TEXT,
    exam_questions JSONB,
    key_concepts JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE exam_prep.quiz_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    lecture_id UUID NOT NULL,
    questions JSONB NOT NULL,
    answers JSONB,
    score INTEGER,
    completed_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE exam_prep.topic_analytics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    lecture_id UUID NOT NULL,
    topic_tag VARCHAR(255),
    query_count INTEGER DEFAULT 1,
    last_queried TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);