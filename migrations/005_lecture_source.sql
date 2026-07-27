-- Where a lecture's words came from.
--
-- Cleveft can now build a lecture from an imported PDF as well as from a
-- recording, and will shortly add YouTube. Everything downstream of the
-- transcript — notes, chunks, embeddings, quizzes, RAG citations — is identical
-- across all three, so this column exists for two narrow reasons: the student
-- needs to see at a glance that a "lecture" is really a handout they imported,
-- and retry has to re-run the pipeline the lecture originally came through.
--
-- Safe to run more than once.
--
-- No BEGIN/COMMIT here: the runner applies every file with psql's
-- --single-transaction, so one is already open. A file that opens its own gets
-- "there is already a transaction in progress", and — worse — its COMMIT ends
-- the runner's transaction early, so anything after it would run unprotected.

ALTER TABLE transcription.lectures
    ADD COLUMN IF NOT EXISTS source VARCHAR(20);

-- Every lecture that existed before this column was a recording, by definition:
-- it is the only way one could be created. Backfilled explicitly rather than
-- leaning on the DEFAULT below, which only applies to rows inserted afterwards.
UPDATE transcription.lectures
SET source = 'RECORDING'
WHERE source IS NULL;

ALTER TABLE transcription.lectures
    ALTER COLUMN source SET DEFAULT 'RECORDING';

ALTER TABLE transcription.lectures
    ALTER COLUMN source SET NOT NULL;

-- Named so it can be dropped and recreated when YOUTUBE joins the set, rather
-- than being an anonymous constraint nobody can find later.
ALTER TABLE transcription.lectures
    DROP CONSTRAINT IF EXISTS lectures_source_check;

ALTER TABLE transcription.lectures
    ADD CONSTRAINT lectures_source_check
        CHECK (source IN ('RECORDING', 'PDF', 'YOUTUBE'));
