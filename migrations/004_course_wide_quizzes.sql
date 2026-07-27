-- ============================================================================
--  Migration 004 — quizzes may span a whole course
--  ---------------------------------------------------------------------------
--  A quiz was tied to exactly one lecture (lecture_id NOT NULL). A student
--  revising CSM 254 wants to be tested across all six of its recordings, and
--  that quiz has no single lecture to belong to.
--
--  Two changes:
--
--    * lecture_id becomes nullable, and course_code is added. Exactly one of
--      the pair is set: a lecture quiz has a lecture, a course quiz has a
--      course. Neither table can express "both" or "neither" meaningfully, so
--      a CHECK enforces it rather than trusting every future writer.
--
--    * Each question inside the questions JSONB gains its own lectureId. This
--      is the load-bearing part. Mastery is recorded per (user, lecture,
--      topic) as of migration 003, so a course quiz has to know which lecture
--      each individual question came from — otherwise all six lectures' worth
--      of answers would land on one of them, re-creating precisely the
--      mis-attribution 003 just repaired.
--
--  Existing rows are unaffected: they keep their lecture_id, course_code stays
--  NULL, and their questions are backfilled with the quiz's own lecture id.
--
--  Safe to run more than once.
--
--  Run with:
--    docker exec -i cleveft-postgres psql -U cleveft_user -d cleveft \
--      < cleveft-infra/migrations/004_course_wide_quizzes.sql
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
--  1. Quizzes
-- ---------------------------------------------------------------------------

ALTER TABLE exam_prep.quizzes ALTER COLUMN lecture_id DROP NOT NULL;
ALTER TABLE exam_prep.quizzes ADD COLUMN IF NOT EXISTS course_code VARCHAR(64);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_quiz_scope') THEN
        ALTER TABLE exam_prep.quizzes
            ADD CONSTRAINT chk_quiz_scope
            CHECK ((lecture_id IS NOT NULL) <> (course_code IS NOT NULL));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_quizzes_user_course
    ON exam_prep.quizzes (user_id, course_code)
    WHERE course_code IS NOT NULL;

-- ---------------------------------------------------------------------------
--  2. Attempts
-- ---------------------------------------------------------------------------

ALTER TABLE exam_prep.quiz_attempts ALTER COLUMN lecture_id DROP NOT NULL;
ALTER TABLE exam_prep.quiz_attempts ADD COLUMN IF NOT EXISTS course_code VARCHAR(64);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_attempt_scope') THEN
        ALTER TABLE exam_prep.quiz_attempts
            ADD CONSTRAINT chk_attempt_scope
            CHECK ((lecture_id IS NOT NULL) <> (course_code IS NOT NULL));
    END IF;
END $$;

-- ---------------------------------------------------------------------------
--  3. Backfill per-question lecture ids.
--
--  Every existing quiz belongs to one lecture, so each of its questions came
--  from that lecture. Stamping them now means the grading path can read the
--  lecture off the question unconditionally, with no "old quiz" special case.
-- ---------------------------------------------------------------------------

UPDATE exam_prep.quizzes q
SET questions = (
    SELECT jsonb_agg(question || jsonb_build_object('lectureId', q.lecture_id))
    FROM jsonb_array_elements(q.questions) AS question
)
WHERE q.lecture_id IS NOT NULL
  AND jsonb_typeof(q.questions) = 'array'
  AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(q.questions) AS question
      WHERE NOT (question ? 'lectureId')
  );

-- Same for the graded answers already stored on past attempts, so historic
-- results can be re-attributed if analytics are ever rebuilt again.
UPDATE exam_prep.quiz_attempts a
SET answers = (
    SELECT jsonb_agg(answer || jsonb_build_object('lectureId', a.lecture_id))
    FROM jsonb_array_elements(a.answers) AS answer
)
WHERE a.lecture_id IS NOT NULL
  AND jsonb_typeof(a.answers) = 'array'
  AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(a.answers) AS answer
      WHERE NOT (answer ? 'lectureId')
  );

COMMIT;
