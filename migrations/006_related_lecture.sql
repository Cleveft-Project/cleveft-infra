-- Supporting material, attached to the lecture it explains.
--
-- A student mostly reaches for a YouTube video because something in a specific
-- class did not land. Recording which lecture a video was imported against is
-- what lets Cleveft answer "what else do I have on functional dependencies?",
-- and — more importantly — what keeps supporting material out of the exam
-- readiness calculation. Readiness is a claim about an exam, and the exam comes
-- from the lecturer, so only recordings and imported handouts may move it.
--
-- Null means the item stands on its own, which stays perfectly valid.
--
-- Safe to run more than once.
--
-- No BEGIN/COMMIT here: the runner applies every file with psql's
-- --single-transaction, so one is already open. A file that opens its own gets
-- "there is already a transaction in progress", and — worse — its COMMIT ends
-- the runner's transaction early, so anything after it would run unprotected.

ALTER TABLE transcription.lectures
    ADD COLUMN IF NOT EXISTS related_lecture_id UUID;

-- Deleting a lecture must not delete the videos a student gathered around it,
-- and must not leave them pointing at a row that is gone. ON DELETE SET NULL
-- turns them back into standalone library items, which is what they would have
-- been had the student imported them from the Record tab.
ALTER TABLE transcription.lectures
    DROP CONSTRAINT IF EXISTS lectures_related_lecture_fk;

ALTER TABLE transcription.lectures
    ADD CONSTRAINT lectures_related_lecture_fk
        FOREIGN KEY (related_lecture_id)
        REFERENCES transcription.lectures (id)
        ON DELETE SET NULL;

-- Every read of this column asks the same question: "which videos hang off this
-- lecture?" Without the index that is a sequential scan of the student's whole
-- library on every lecture screen open.
CREATE INDEX IF NOT EXISTS idx_lectures_related_lecture
    ON transcription.lectures (related_lecture_id)
    WHERE related_lecture_id IS NOT NULL;
