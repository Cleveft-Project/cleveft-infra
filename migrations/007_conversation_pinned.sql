-- Threads a student keeps coming back to.
--
-- History is ordered by when a conversation was last used, which is right for
-- the ones being worked through and wrong for the two or three that matter all
-- semester — those sink the moment anything else is asked. Pinning holds them
-- above the date groups.
--
-- Safe to run more than once.
--
-- No BEGIN/COMMIT here: the runner applies every file with psql's
-- --single-transaction, so one is already open. A file that opens its own gets
-- "there is already a transaction in progress", and — worse — its COMMIT ends
-- the runner's transaction early, so anything after it would run unprotected.

ALTER TABLE query.conversations
    ADD COLUMN IF NOT EXISTS pinned BOOLEAN NOT NULL DEFAULT FALSE;

-- History is read on every open of the drawer and always in the same order:
-- pinned first, then most recently used. Matching the index to that ordering is
-- what keeps it an index scan rather than a sort of the student's whole history.
CREATE INDEX IF NOT EXISTS idx_conversations_user_pinned
    ON query.conversations (user_id, pinned DESC, updated_at DESC);
