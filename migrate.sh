#!/bin/sh
# ============================================================================
#  Applies every migration in ./migrations, once, in filename order.
#  ---------------------------------------------------------------------------
#  Run automatically by the `migrator` service in docker-compose.yml, before any
#  application service is allowed to start.
#
#  Why this exists
#  ---------------
#  `init.sql` is mounted into /docker-entrypoint-initdb.d, which Postgres only
#  reads when it initialises an *empty* data directory. Cleveft's volume is
#  external and long-lived, so that hook has not fired since the day the
#  database was created and cannot fire again. Every schema change since then
#  has been applied by hand, which means a fresh clone comes up with a database
#  that does not match the code, and an existing one drifts silently whenever
#  someone forgets a step.
#
#  Design notes
#  ------------
#  * Each file runs inside one transaction (`--single-transaction`), so a
#    migration that fails halfway leaves nothing behind. Migration files must
#    therefore NOT contain their own BEGIN/COMMIT — a nested BEGIN is merely
#    noisy, but the matching COMMIT closes the runner's transaction early, so
#    any statement after it would run unprotected. 001-004 predate this rule
#    and still carry theirs; they are already applied everywhere that matters,
#    and on a fresh database they emit warnings rather than misbehaving.
#  * `ON_ERROR_STOP=1` is essential. Without it psql prints errors and still
#    exits 0 — the "green build, broken service" trap this repo has hit before.
#  * Applied filenames are recorded in `public.schema_migrations`. The
#    migrations are written to be idempotent as well, but the ledger is what
#    makes it safe to add a *destructive* migration later.
# ============================================================================
set -eu

PSQL="psql --username=${POSTGRES_USER} --dbname=${POSTGRES_DB} --no-psqlrc --quiet -v ON_ERROR_STOP=1"

echo "migrator: waiting for postgres…"
until psql --username="${POSTGRES_USER}" --dbname="${POSTGRES_DB}" -c 'SELECT 1' >/dev/null 2>&1; do
  sleep 1
done

ledger_existed=$($PSQL --tuples-only --no-align -c "SELECT to_regclass('public.schema_migrations') IS NOT NULL")

$PSQL <<'SQL'
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    filename    TEXT PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

# ---------------------------------------------------------------------------
#  Baselining an existing database
# ---------------------------------------------------------------------------
#  This runner was added long after the project's database was created, and
#  migrations 001-004 were applied to it by hand. Replaying them would not be
#  harmless: 003 rebuilds topic_analytics from quiz_attempts, so re-running it
#  against live data would discard mastery history.
#
#  So on the *first* run against a database that already has tables, everything
#  up to and including MIGRATIONS_BASELINE is recorded as applied without being
#  executed. A genuinely empty database has no baseline to establish and runs
#  every migration normally — which is what a fresh clone needs.
#
#  When the last hand-applied migration has aged out of relevance this whole
#  block can go; until then, deleting it would break exactly one machine, in a
#  way that is tedious to notice and unpleasant to undo.
# ---------------------------------------------------------------------------
BASELINE="${MIGRATIONS_BASELINE:-}"

if [ "$ledger_existed" = "f" ] && [ -n "$BASELINE" ]; then
  schema_present=$($PSQL --tuples-only --no-align \
    -c "SELECT to_regclass('transcription.lectures') IS NOT NULL")

  if [ "$schema_present" = "t" ]; then
    echo "migrator: existing database detected — baselining through ${BASELINE}"
    for file in $(find /migrations -name '*.sql' | sort); do
      name=$(basename "$file")
      $PSQL -c "INSERT INTO public.schema_migrations (filename) VALUES ('${name}')
                ON CONFLICT DO NOTHING"
      echo "migrator: baseline ${name} (assumed already applied)"
      [ "$name" = "$BASELINE" ] && break
    done
  else
    echo "migrator: empty database — running every migration from the start"
  fi
fi

applied=0
skipped=0

# `sort` matters: filenames are zero-padded (001…) precisely so that lexical
# order and intended order are the same thing.
for file in $(find /migrations -name '*.sql' | sort); do
  name=$(basename "$file")

  already=$($PSQL --tuples-only --no-align \
    -c "SELECT 1 FROM public.schema_migrations WHERE filename = '${name}'")

  if [ "$already" = "1" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  echo "migrator: apply   ${name}"
  $PSQL --single-transaction --file "$file"
  $PSQL -c "INSERT INTO public.schema_migrations (filename) VALUES ('${name}')"
  applied=$((applied + 1))
done

echo "migrator: done — ${applied} applied, ${skipped} already present"
