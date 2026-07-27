# cleveft-infra

Database schema, Docker orchestration and shared infrastructure config for the
Cleveft platform.

## What lives here

| File                 | Purpose                                                            |
| -------------------- | ------------------------------------------------------------------ |
| `init.sql`           | **Canonical** database schema. Single source of truth for all services. |
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

`init.sql` runs **only when the postgres volume is first created**. Editing it
does nothing to an existing database. To apply changes locally:

```bash
docker compose down -v        # destroys the volume and all local data
docker compose up -d
```

Every service runs with `ddl-auto=none`, so Hibernate will never silently
create or alter a table behind your back. If an entity and this file disagree,
the service fails loudly at first query — that is intentional.

## Secrets

`JWT_SECRET` must be **identical** across the gateway and the auth service; the
gateway validates the tokens the auth service signs. Anything shorter than 32
bytes is rejected by the HS256 signer at startup.

Generate one with:

```bash
openssl rand -base64 48
```
