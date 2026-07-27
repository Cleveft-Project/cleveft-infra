# cleveft-infra

Database schema, Docker orchestration and shared infrastructure config for the
Cleveft platform.

## What lives here

| File                 | Purpose                                                            |
| -------------------- | ------------------------------------------------------------------ |
| `init.sql`           | **Canonical** database schema. Single source of truth for all services. |
| `migrations/`        | Numbered schema changes, applied in order to an existing database. |
| `migrate.sh`         | The runner. Executed by the `migrator` service, not by hand.       |
| `docker-compose.yml` | PostgreSQL + pgvector, plus an optional profile for every service.  |
| `.env.example`       | Template for local secrets. Copy to `.env`.                        |

## Quick start

```bash
cp .env.example .env          # then fill in GOOGLE_API_KEY and JWT_SECRET
docker compose up -d          # postgres only, on localhost:5433
```

Bring up the whole backend in containers:

```bash
docker compose --profile services up -d --build
```

The gateway is then the only port you need: <http://localhost:8080>.

## Schema ownership

One schema per microservice. **No service reads another service's schema** —
cross-service data is fetched over HTTP.

| Schema          | Owner                             | Port |
| --------------- | --------------------------------- | ---- |
| `auth`          | `Cleveft-auth-service`            | 8084 |
| `transcription` | `cleveft-transcription-service`   | 8082 |
| `query`         | `cleveft-query-service`           | 8081 |
| `exam_prep`     | `cleveft-examprep-service`        | 8085 |
| `collab`        | `cleveft-collab-service`          | 8086 |

`transcription.chunks` is the only vector table in the system. The query and
exam-prep services retrieve lecture context by calling the transcription
service's `/api/v1/transcriptions/search` endpoint, never by querying pgvector
directly.

## Changing the schema

`init.sql` runs **only when the postgres volume is first created**, and this
volume is external and long-lived — so editing that file alone does nothing to
a database that already exists.

Schema changes therefore go in `migrations/` as a new numbered file:

```
migrations/
  001_align_to_canonical_schema.sql
  002_add_subscription_plan.sql
  003_topic_analytics_per_lecture.sql
  004_course_wide_quizzes.sql
  005_lecture_source.sql
```

The `migrator` service applies them in filename order on the next
`docker compose up`, before any service that reads the tables is allowed to
start, so the schema can never be older than the code reading it. Applied
filenames are recorded in `public.schema_migrations`.

Also update `init.sql`, which remains the readable description of the current
model and is what a brand-new volume is built from.

Two rules for a migration file:

- **No `BEGIN`/`COMMIT`.** Each file already runs inside one transaction via
  `--single-transaction`; a stray `COMMIT` closes the runner's transaction early
  and leaves everything after it unprotected. Files 001–004 predate this rule
  and still carry theirs.
- **Make it idempotent.** The ledger prevents re-runs, but idempotence is what
  makes a partially-migrated database recoverable.

> **Do not run `docker compose down -v`.** The postgres volume holds every
> lecture, transcript and quiz on this machine, and `-v` destroys it. No schema
> change requires it — that advice belongs to the era before this migration
> runner existed.

Every service runs with `ddl-auto=none`, so Hibernate will never silently
create or alter a table behind your back. If an entity and the schema disagree,
the service fails loudly at first query — that is intentional.

## Secrets

`JWT_SECRET` must be **identical** across the gateway and the auth service; the
gateway validates the tokens the auth service signs. Anything shorter than 32
bytes is rejected by the HS256 signer at startup.

Generate one with:

```bash
openssl rand -base64 48
```
