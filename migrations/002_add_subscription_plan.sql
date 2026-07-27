-- ============================================================================
--  Migration 002 — subscription plan on auth.users
--  ---------------------------------------------------------------------------
--  Backs the freemium model from the proposal: a Free tier capped at a set
--  number of recordings a month, and Cleveft Pro with the cap lifted.
--
--  The plan lives on auth.users because the auth service owns identity and is
--  the only service that may write it. The transcription service, which has to
--  enforce the cap, reads the plan over HTTP rather than reaching across the
--  schema boundary — same rule every other cross-service read follows.
--
--  Existing accounts land on FREE, which is the correct default: nobody has
--  paid, and a NULL plan would force every consumer to handle a third state.
--
--  Safe to run more than once, and safe on a fresh database that already got
--  the column from init.sql.
--
--  Run with:
--    docker exec -i cleveft-postgres psql -U cleveft_user -d cleveft \
--      < cleveft-infra/migrations/002_add_subscription_plan.sql
-- ============================================================================

BEGIN;

ALTER TABLE auth.users
    ADD COLUMN IF NOT EXISTS plan VARCHAR(32) NOT NULL DEFAULT 'FREE';

-- When the current period ends. NULL on FREE, and NULL on PRO means it does
-- not expire — the app treats a past date as lapsed and falls back to FREE.
ALTER TABLE auth.users
    ADD COLUMN IF NOT EXISTS plan_renews_at TIMESTAMP WITH TIME ZONE;

-- Rejects typos at the database rather than trusting every writer to be
-- careful; the set is small and changes about once a year.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chk_users_plan'
    ) THEN
        ALTER TABLE auth.users
            ADD CONSTRAINT chk_users_plan CHECK (plan IN ('FREE', 'PRO'));
    END IF;
END $$;

UPDATE auth.users SET plan = 'FREE' WHERE plan IS NULL;

COMMIT;
