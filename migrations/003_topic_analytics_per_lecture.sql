-- ============================================================================
--  Migration 003 — topic analytics become per-lecture
--  ---------------------------------------------------------------------------
--  exam_prep.topic_analytics was keyed UNIQUE (user_id, topic_tag), so a
--  student had exactly one mastery row per topic no matter how many lectures
--  covered it. Its lecture_id was therefore not "the lecture this mastery
--  belongs to" but "the first lecture that ever produced this tag". Two things
--  broke as a result:
--
--    * Per-lecture readiness. Quiz lecture 2 on a topic first seen in lecture
--      1 and the mastery still counted toward lecture 1, so lecture 2 looked
--      untouched and lecture 1 carried a score it had not earned.
--    * Cross-course contamination. Two courses sharing a topic name —
--      "integration", "normalisation" — shared ONE row, so performance in one
--      course silently moved the other course's readiness.
--
--  The key becomes (user_id, lecture_id, topic_tag). Rows whose lecture_id is
--  NULL are query-only signals ("I keep looking this up") that belong to no
--  single lecture, and stay unique per (user_id, topic_tag).
--
--  Existing rows are not merely re-labelled — they are rebuilt from
--  exam_prep.quiz_attempts, which records the true lecture for every answer.
--  Re-labelling would preserve the wrong attribution this migration exists to
--  fix. query_count and last_queried are not rebuilt because they come from
--  the query service; the exam-prep service re-syncs them on the next
--  readiness request.
--
--  Safe to run more than once.
--
--  Run with:
--    docker exec -i cleveft-postgres psql -U cleveft_user -d cleveft \
--      < cleveft-infra/migrations/003_topic_analytics_per_lecture.sql
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
--  1. Rebuild quiz-derived mastery with the correct lecture on each row.
-- ---------------------------------------------------------------------------

-- One row per (user, lecture, topic) with the real counts, taken from the
-- graded answers stored on every attempt.
CREATE TEMP TABLE rebuilt_analytics ON COMMIT DROP AS
SELECT
    a.user_id,
    a.lecture_id,
    answer ->> 'topicTag'                                   AS topic_tag,
    COUNT(*)                                                AS attempt_count,
    COUNT(*) FILTER (WHERE (answer ->> 'correct')::boolean) AS correct_count
FROM exam_prep.quiz_attempts a
CROSS JOIN LATERAL jsonb_array_elements(a.answers) AS answer
WHERE a.lecture_id IS NOT NULL
  AND answer ->> 'topicTag' IS NOT NULL
  AND btrim(answer ->> 'topicTag') <> ''
GROUP BY a.user_id, a.lecture_id, answer ->> 'topicTag';

-- Drop the rows that were quiz-derived. Query-only rows (no attempts) carry
-- signal that cannot be reconstructed from attempts, so they are left alone.
DELETE FROM exam_prep.topic_analytics WHERE attempt_count > 0;

-- ---------------------------------------------------------------------------
--  2. Swap the uniqueness rule.
-- ---------------------------------------------------------------------------

ALTER TABLE exam_prep.topic_analytics DROP CONSTRAINT IF EXISTS uq_topic_per_user;

-- Two partial indexes rather than one constraint: Postgres treats NULLs as
-- distinct in a UNIQUE, so a plain UNIQUE (user_id, lecture_id, topic_tag)
-- would happily allow a hundred lecture-less rows for the same topic.
CREATE UNIQUE INDEX IF NOT EXISTS uq_topic_user_lecture
    ON exam_prep.topic_analytics (user_id, lecture_id, topic_tag)
    WHERE lecture_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_topic_user_no_lecture
    ON exam_prep.topic_analytics (user_id, topic_tag)
    WHERE lecture_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_topic_analytics_user_lecture
    ON exam_prep.topic_analytics (user_id, lecture_id);

-- ---------------------------------------------------------------------------
--  3. Insert the rebuilt rows.
--
--  mastery_score mirrors TopicAnalytics.recomputeMastery(): accuracy damped by
--  a lookup penalty. query_count is 0 on every rebuilt row, so the penalty is
--  0 here and the score is plain accuracy; the next readiness request re-syncs
--  query counts and recomputes properly.
-- ---------------------------------------------------------------------------

INSERT INTO exam_prep.topic_analytics
    (user_id, lecture_id, topic_tag, query_count, correct_count, attempt_count, mastery_score, updated_at)
SELECT
    user_id,
    lecture_id,
    topic_tag,
    0,
    correct_count,
    attempt_count,
    GREATEST(0.0, LEAST(1.0, correct_count::double precision / attempt_count)),
    NOW()
FROM rebuilt_analytics
ON CONFLICT DO NOTHING;

COMMIT;
