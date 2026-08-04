-- The courses a student is taking this semester.
--
-- Until now a course existed only as a code typed onto a lecture, which means
-- Cleveft could not answer "who else is taking CSM 266?" — the one question
-- that makes a study app social. A phone book cannot answer it either: your
-- coursemate may not be in your contacts, and half your contacts are in another
-- faculty.
--
-- Stored as a JSONB array of normalised codes rather than a join table. A
-- student takes six or eight courses, they are edited as a set, and nothing
-- ever queries one course's students except by containment — a table would be
-- three joins to answer a question one operator already answers.
--
-- Safe to run more than once.
--
-- No BEGIN/COMMIT here: the runner applies every file with psql's
-- --single-transaction, so one is already open. A file that opens its own gets
-- "there is already a transaction in progress", and — worse — its COMMIT ends
-- the runner's transaction early, so anything after it would run unprotected.

ALTER TABLE auth.users
    ADD COLUMN IF NOT EXISTS courses JSONB NOT NULL DEFAULT '[]'::jsonb;

-- Containment is the only way this column is ever read: "which students have
-- this code in their list". A GIN index is what makes that an index lookup
-- rather than a scan of every user in the system.
CREATE INDEX IF NOT EXISTS idx_users_courses
    ON auth.users USING GIN (courses jsonb_path_ops);
