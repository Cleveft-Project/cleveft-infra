-- One-time codes, for password reset and email verification.
--
-- Both features are the same machinery: issue a random code, email it, store it
-- hashed, and check what the student types against it. Only what happens on a
-- successful check differs, so they share this table rather than having one
-- each.
--
-- Codes are stored hashed for the same reason passwords are. A leaked database
-- with plaintext codes in it would let an attacker reset any account whose code
-- had not yet expired.
--
-- Safe to run more than once.
--
-- No BEGIN/COMMIT here: the runner applies every file with psql's
-- --single-transaction, so one is already open. A file that opens its own gets
-- "there is already a transaction in progress", and — worse — its COMMIT ends
-- the runner's transaction early, so anything after it would run unprotected.

CREATE TABLE IF NOT EXISTS auth.verification_codes (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Held by email rather than user_id: a sign-up code is issued before any
    -- user row exists, and a reset must not reveal whether an address is
    -- registered.
    email        VARCHAR(255) NOT NULL,

    purpose      VARCHAR(32)  NOT NULL,
    code_hash    VARCHAR(255) NOT NULL,

    expires_at   TIMESTAMP WITH TIME ZONE NOT NULL,

    -- Set the moment a code is accepted. A used code is kept rather than deleted
    -- so that a replayed one can be told apart from one that never existed.
    consumed_at  TIMESTAMP WITH TIME ZONE,

    -- Guesses so far. Six digits is a million combinations, but a code that can
    -- be tried without limit is a code that will eventually be guessed.
    attempts     SMALLINT     NOT NULL DEFAULT 0,

    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_verification_purpose
        CHECK (purpose IN ('PASSWORD_RESET', 'EMAIL_VERIFICATION'))
);

-- Every lookup asks the same question: the newest live code for this address and
-- purpose.
CREATE INDEX IF NOT EXISTS idx_verification_lookup
    ON auth.verification_codes (email, purpose, created_at DESC);

-- Expired and consumed rows are swept periodically; this keeps that cheap.
CREATE INDEX IF NOT EXISTS idx_verification_expiry
    ON auth.verification_codes (expires_at);

-- Whether the address has been proved to belong to whoever signed up.
--
-- Defaults to TRUE, and existing rows are backfilled to TRUE: everyone who
-- registered before verification existed got in without it, and locking them
-- out retroactively would be a bug, not a security improvement.
ALTER TABLE auth.users
    ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT TRUE;
