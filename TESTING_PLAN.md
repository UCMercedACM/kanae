# Comprehensive Route Tests for Kanae

## Context

The repo currently has pytest infrastructure (`tests/conftest.py`, `tests/test_limiter.py`) that exercises the rate limiter against Valkey and brings up Postgres + Valkey via testcontainers — but the 56 HTTP routes across 5 routers (`src/routes/{index,members,projects,events,tags}.py`) have no coverage. You want comprehensive route tests (happy path + validation + permission matrix) seeded the same way the app is in production.

## Recommendation: two layers — pytest+httpx for breadth, Hurl for end-to-end fidelity

**Why two layers, not one:**

- pytest + httpx + dependency-overridden `use_session` gives ~500 fast, isolated tests covering every route × role × validation case. Stubs auth, hits a real Postgres via testcontainers. This is the per-commit gate.
- Hurl drives the **real** `docker/docker-compose.yml` stack (Kratos, Keto, Atlas, Valkey, kanae) end-to-end as a thin scenario suite (~5–10 files). This catches what stubbing hides: cookie handling, Kratos session validation, Keto rules, the registration webhook into `/members`, schema drift, real rate limiting. Slow, so not on every PR.

Hurl alone is the wrong shape for the comprehensive layer — the role × payload matrix is verbose in Hurl, and per-test DB isolation is hard with a shared running stack. pytest alone leaves the wiring untested. Together they're complementary.

## Plan

### 1. Seed Postgres via a custom image with `schema.sql` at the entrypoint

The official `postgres` image executes any `.sql` / `.sh` file mounted at `/docker-entrypoint-initdb.d/` once during initial DB creation. Build a tiny image (or use `with_volume_mapping` on `PostgresContainer`) so the testcontainer comes up with the schema already applied — no Atlas invocation in the test path, no extra runtime dependency on the CI image.

Options (pick whichever you prefer, both work):

- **Custom image (preferred for portability):** add `tests/postgres.Dockerfile`:
  ```dockerfile
  FROM postgres:18
  COPY src/schema.sql /docker-entrypoint-initdb.d/01_schema.sql
  ```
  Build once in CI (or rely on the testcontainers build helper). Point `PostgresContainer("kanae-test-postgres:latest")` at it in `conftest.py`.
- **Volume mount (no image build):** keep stock `PostgresContainer()` and call `.with_volume_mapping(str(SCHEMA_SQL), "/docker-entrypoint-initdb.d/01_schema.sql", "ro")` in the `setup` fixture.

Either way, by the time `wait_for_logs(postgres, "ready", ...)` returns, the schema is applied. No Atlas required for tests; production keeps using Atlas via `docker/docker-compose.yml`.

### 2. Override `use_session` to inject a fake Kratos user

This is the unlock that makes comprehensive route testing fast and readable. FastAPI's `app.dependency_overrides` lets us swap `use_session` for a fixture-controlled fake without touching production code.

- Add a `make_session` fixture in `conftest.py` returning a callable like `make_session(role="member", user_id=...)` that registers an override producing a `KratosUser` with the requested role/identity.
- Default `app` fixture wires no override (so unauth tests get real 401s). Tests that need an authed call do `make_session(role="lead")` in arrange.
- Parametrize over roles for permission-matrix tests:
  ```python
  @pytest.mark.parametrize("role,expected", [
      ("member", 403), ("lead", 200), ("admin", 200),
  ])
  ```
- Where individual route tests don't need real DB rows, also mock `request.app.ory` and any downstream service calls. Hit the route, assert the response and any DB side-effect via a direct asyncpg query — no factory layer in between.

### 3. Per-test DB isolation

Session-scoped container with schema applied once at init (via #1). Per-test cleanup wraps each test in a transaction rolled back at teardown — or `TRUNCATE ... RESTART IDENTITY CASCADE` between tests if transaction wrapping fights the app's own connection acquisition.

### 4. Flat layout: one `test_<route>.py` per router, directly under `tests/`

No subfolders, no factories. Mirror the router names:

```
tests/
  conftest.py
  test_limiter.py      (existing)
  test_index.py
  test_members.py
  test_projects.py
  test_events.py
  test_tags.py
```

Inside each file, group by route via class or by section comment — your call. Build state by hitting the proper routes (e.g. create a project via `POST /projects` rather than a `make_project` builder) where the route under test depends on prior state. For state the route can't easily produce, write a small fixture in `conftest.py` that inserts via raw SQL; reuse across tests. Otherwise, mock.

For each route, cover:
- **Happy path** with valid payload + correct role → 2xx, assert response shape and DB side-effect
- **Auth** — no session override → 401
- **Authorization** — wrong role / non-owner → 403 (parametrized across roles)
- **Validation** — Pydantic 422 cases (missing required, wrong types, out-of-range)
- **Conflict / not-found** — 409 on duplicate, 404 on missing resource
- **Rate limiting** — sample test per router using `hiro` to advance time (already in deps)

Target ~8–10 tests per route on average → ~400–500 tests total.

### 5. Order of attack

Start with `test_index.py` (1 route) to validate the new conftest plumbing, then `test_tags.py` (10 routes, simplest entity) to shake out patterns. Move on to `members`, `events`, `projects` in any order.

### 6. Hurl integration layer — real stack, real Kratos

The pytest layer above gives broad coverage but stubs out auth. To catch the things that stub hides — cookie domain mismatches, Kratos `whoami` parsing, Keto permission rules, Atlas vs. ORM schema drift, the registration webhook into `/members` — add a small Hurl suite that drives the **real** `docker/docker-compose.yml` stack with real registration/login flows.

**Stack:** reuse `docker/docker-compose.yml` as-is. It already wires kanae + Postgres + Valkey + Kratos + Keto + Atlas migrator. No test-specific compose file; `make integration` brings the stack up, runs Hurl, tears it down.

**Auth model — hybrid admin-API + public login.** `src/utils/auth.py:25` only reads the `ory_kratos_session` cookie (not `X-Session-Token`), so the cookie has to be real — it's signed/encrypted with `SECRETS_COOKIE` and can't be fabricated externally. But you don't need to *register* every test user through self-service either. The fastest deterministic path:

1. **Bootstrap users via the Kratos admin API** (`POST :4434/admin/identities`) with known emails/passwords and a credential block so login works immediately. No flow-ID dance, no email verification, no flakiness from the post-registration webhook firing asynchronously.
2. **Promote roles directly in `members`** via the same bootstrap SQL — because step 1 skips the registration webhook that normally populates `members`, you have to insert the membership row yourself (and that's fine — you wanted deterministic roles anyway).
3. **Log in via the public self-service login flow** to get a real cookie. Hurl persists it in the file's jar for the rest of the scenario.
4. **Keep ONE scenario (`01_register_login_me.hurl`) that exercises full self-service registration** so the registration → webhook → `members` insert path stays under test. Everything else uses the admin-bootstrapped path.

```hurl
# tests/hurl/scenarios/02_project_lifecycle.hurl
# Lead identity was pre-created in bootstrap.sh against :4434/admin/identities

GET http://localhost:4433/self-service/login/api
HTTP 200
[Captures]
flow_id: jsonpath "$.id"

POST http://localhost:4433/self-service/login?flow={{flow_id}}
{ "method": "password", "identifier": "lead@test.local", "password": "{{lead_password}}" }
HTTP 200
# ory_kratos_session cookie now in jar.

POST http://localhost:8000/projects
{ "name": "Integration", "description": "scenario test" }
HTTP 201
[Captures]
project_id: jsonpath "$.id"
```

**Bootstrap script** (`tests/hurl/bootstrap.sh`): one-shot, idempotent, runs after `docker compose up --wait`:

```bash
# Create identities via admin API. Body uses traits + credentials so the user can log in directly.
for role in member lead admin; do
  curl -fsS -X POST http://localhost:4434/admin/identities -H 'Content-Type: application/json' -d "{
    \"schema_id\": \"default\",
    \"traits\": { \"email\": \"${role}@test.local\", \"name\": { \"first\": \"${role^}\", \"last\": \"Test\" } },
    \"credentials\": { \"password\": { \"config\": { \"password\": \"${HURL_TEST_PASSWORD}\" } } },
    \"verifiable_addresses\": [{ \"value\": \"${role}@test.local\", \"verified\": true, \"via\": \"email\", \"status\": \"completed\" }]
  }"
done

# Then promote roles in members via psql (bootstrap.sql handles the INSERTs / role updates).
docker compose -f docker/docker-compose.yml exec -T database \
    psql -U "$DB_USERNAME" -d "$DB_DATABASE_NAME" < tests/hurl/bootstrap.sql
```

**Why not force the cookie directly?** Two reasons:
- The cookie value is encrypted/signed with Kratos's `SECRETS_COOKIE`. Outside the Kratos process you can't mint a valid one.
- The admin endpoint `POST /admin/identities/{id}/sessions` returns a session **token**, usable via `X-Session-Token`. kanae's `use_session` doesn't read that header. Patching `use_session` to accept it for tests defeats the whole point of the integration layer (testing the real auth path).

The admin-API + login hybrid is the sweet spot: deterministic, ~100ms per user, exercises the real cookie path that production uses.

**Scope — 5–10 scenarios, not 500.** Each `.hurl` file is one user journey:

```
tests/hurl/
  scenarios/
    01_register_login_me.hurl         # register → /users/@me reflects the new identity
    02_project_lifecycle.hurl         # lead: create project → update → archive
    03_member_invite_flow.hurl        # lead invites, member accepts, leaves
    04_event_rsvp.hurl                # create event → RSVP → cancel RSVP
    05_tag_attach_detach.hurl         # tags lifecycle bound to a project
    06_permission_denied.hurl         # member tries lead-only route → 403 from real Keto
    07_rate_limit_real_valkey.hurl    # hammer a limited route → 429 from real Valkey
  bootstrap.sh                        # admin-API identity creation + bootstrap.sql role promotion
  bootstrap.sql                       # role promotions for known test identities
```

**Runner:**

```makefile
integration:
	docker compose -f docker/docker-compose.yml up -d --wait
	bash tests/hurl/bootstrap.sh
	hurl --test --variables-file tests/hurl/vars.env tests/hurl/scenarios/*.hurl
	docker compose -f docker/docker-compose.yml down -v
```

Run locally with `make integration`; in CI add a job that does the same on push to main (don't run on every PR — it's slow). Keep the pytest suite as the per-commit gate.

**Why this complements rather than duplicates pytest:** the pytest layer answers "does each route behave correctly?" Hurl answers "do the pieces wire together?" — Kratos sessions, Keto policies, the Atlas-applied schema, the real registration webhook hitting `/members`, real Valkey rate limiting. A regression in any of those would pass pytest and fail Hurl.

### 7. Property-based fuzz layer — Schemathesis over OpenAPI + Hypothesis for media

Two narrow uses of property-based testing, both inside the existing pytest run. Not a replacement for the parametrized layer — a complement that catches what enumeration misses.

**7a. Schemathesis over the live OpenAPI spec.** FastAPI exposes `/openapi.json`. Schemathesis reads it and generates inputs for every route, asserting:
- no 5xx responses on any generated input (Pydantic should always return 422, never crash),
- responses conform to their declared schemas (catches drift between route code and response models),
- stateful: chained operations (create → read → delete) maintain invariants.

One file does the whole spec:

```python
# tests/test_fuzz_schemathesis.py
import schemathesis
from schemathesis import DataGenerationMethod

schema = schemathesis.from_asgi("/openapi.json", app)

@schema.parametrize()
@pytest.mark.hypothesis(max_examples=30)  # keep CI under a budget
def test_no_5xx(case, make_session):
    make_session(role="admin")  # admin so authz doesn't mask validation bugs
    case.call_and_validate()
```

Notes:
- Hook into the same `make_session` dependency-override so auth doesn't dominate the failure surface.
- Tune `max_examples` per-route via `@schema.hooks` if some routes are too expensive.
- Add a small `hypothesis` profile (`profile("ci", max_examples=30)`, `profile("dev", max_examples=200)`) so devs can crank it locally.

**7b. Hypothesis for media-upload validation.** Test the *pure validator function* (not the HTTP route) with property strategies — fast, no DB/HTTP roundtrip, shrinking actually shrinks:

```python
# tests/test_media_validation.py
@given(st.binary(min_size=0, max_size=10 * 1024 * 1024))
def test_validator_never_crashes(blob):
    # Property: validator always returns a Result, never raises.
    result = validate_upload(blob, filename="x.png", declared_mime="image/png")
    assert result is not None

@given(
    declared=st.sampled_from(["image/png", "image/jpeg", "application/pdf"]),
    magic=st.binary(min_size=8, max_size=8),
)
def test_magic_mime_mismatch_rejected(declared, magic):
    # Property: when magic bytes disagree with declared MIME, validator rejects.
    if not magic_matches(magic, declared):
        assert validate_upload(magic + b"\x00" * 100, "x", declared).rejected

@given(st.text(min_size=1, max_size=512))
def test_filename_sanitization(name):
    # Property: sanitized filename never contains "..", null bytes, or path separators.
    out = sanitize_filename(name)
    assert ".." not in out and "\x00" not in out and "/" not in out and "\\" not in out
```

**Boundary tests stay explicit, not Hypothesis-driven.** File-size limits are `0`, `limit-1`, `limit`, `limit+1`, `limit*2` — five parametrized cases, not a random search.

**Where Hypothesis is *not* used and why:**
- Per-route happy/sad path tests — Pydantic already validates the schema; random valid bodies just rediscover that.
- Role/permission matrix — `parametrize` is more readable, faster, and the cases are finite.
- E2E user journeys — Hurl owns that.

**Dependencies to add** (`pyproject.toml` dev group): `hypothesis`, `schemathesis`.

## Critical files

- `tests/conftest.py` — extend `setup` fixture to seed schema at container init; add `FakeOry` + `fake_ory` fixture; add per-test DB cleanup fixture
- `tests/postgres.Dockerfile` (new, optional) — custom Postgres image baking in `src/schema.sql`; OR equivalent `with_volume_mapping` call in `setup`
- `tests/test_index.py`, `tests/test_members.py`, `tests/test_projects.py`, `tests/test_events.py`, `tests/test_tags.py` (new) — one per router, flat under `tests/`
- `src/utils/auth.py:use_session` — the dependency to override (no code change there, just reference)
- `tests/hurl/scenarios/*.hurl` (new) — 5–10 end-to-end user journeys against the real stack
- `tests/hurl/bootstrap.sh` (new) — creates identities via Kratos admin API (`:4434/admin/identities`) with pre-verified credentials so login works immediately
- `tests/hurl/bootstrap.sql` (new) — promotes those identities to `lead`/`admin` in the `members` table (since admin-create skips the registration webhook)
- `Makefile` or `scripts/integration.sh` (new) — `integration` target: `docker compose up --wait` → `bootstrap.sh` → `hurl --test` → `down -v`
- `tests/test_fuzz_schemathesis.py` (new) — single Schemathesis suite that fuzzes every route from `/openapi.json`; asserts no 5xx + response-schema conformance
- `tests/test_media_validation.py` (new) — Hypothesis property tests on the upload validator (pure function); explicit boundary tests for size limits
- `pyproject.toml` — add `hypothesis` and `schemathesis` to dev deps
- `.github/workflows/test.yml` — if you go custom-image route, add a build step; if volume-mapping, no change needed. Add a separate `integration` job (push-to-main only) that runs `make integration`.

## Reuse, don't rebuild

- `KanaeTestClient` (`conftest.py:138`) — keep as-is for the route tests
- `KanaeServices` / `setup` fixture (`conftest.py:133, 169`) — extend, don't duplicate
- `LifespanManager` + ASGI transport — already wired in the `app` fixture
- `hiro` for time-mocking rate-limit tests — already a dep

## Example tests

These are concrete, paste-ready sketches so the executing agent knows exactly what shape each test takes. They reference real symbols: `tags` schema/routes (`src/routes/tags.py`), `Role` (`src/utils/checks.py:35`), `OryClient.check_permission` and `whoami` (`src/utils/ory.py`).

### Conftest extensions — `FakeOry` covers both auth *and* authz

Both `use_session` (via `app.ory.whoami`) and every role/permission check (via `app.ory.check_permission`) go through `app.ory`. One fake covers both — no `dependency_overrides` gymnastics needed.

```python
# tests/conftest.py  (added below existing fixtures)

import uuid
from dataclasses import dataclass, field

from utils.checks import Role


@dataclass
class FakeIdentity:
    id: str
    traits: dict = field(default_factory=lambda: {"email": "test@test.local"})


@dataclass
class FakeSession:
    identity: FakeIdentity
    active: bool = True


class FakeOry:
    """Drop-in replacement for OryClient that the tests drive directly.

    - whoami(cookie) → returns the current FakeSession (or None for 401)
    - check_permission(ns, obj, rel, subj) → consults `self.permissions`
    """

    def __init__(self) -> None:
        self.session: FakeSession | None = None
        # set of (namespace, object, relation, subject_id) tuples that pass
        self.permissions: set[tuple[str, str, str, str]] = set()

    async def whoami(self, cookie: str | None):
        return self.session

    async def check_permission(self, namespace, resource, relation, subject_id):
        return (str(namespace), str(resource), str(relation), str(subject_id)) in self.permissions

    # ergonomic helpers used by tests
    def login_as(self, *, role: Role | None = None, identity_id: str | None = None) -> str:
        identity_id = identity_id or str(uuid.uuid4())
        self.session = FakeSession(FakeIdentity(id=identity_id))
        if role is not None:
            self.permissions.add(("Role", role.value, "member", identity_id))
        return identity_id

    def grant(self, namespace: str, obj: str, relation: str, subject_id: str) -> None:
        self.permissions.add((namespace, obj, relation, subject_id))


@pytest_asyncio.fixture(scope="function")
async def fake_ory(get_app: Kanae) -> FakeOry:
    fake = FakeOry()
    get_app.ory = fake  # type: ignore[assignment]
    return fake


@pytest_asyncio.fixture(scope="function", autouse=True)
async def db_cleanup(app: KanaeTestClient, setup: KanaeServices):
    # truncate mutable tables between tests; ordering matters for FKs
    yield
    pool = app._transport.app.pool  # type: ignore[attr-defined]
    await pool.execute(
        "TRUNCATE tags, events, projects, members RESTART IDENTITY CASCADE"
    )
```

The `setup` fixture also needs to seed `src/schema.sql` at container init — either via a custom image or `PostgresContainer(...).with_volume_mapping(str(SCHEMA_SQL_PATH), "/docker-entrypoint-initdb.d/01_schema.sql", "ro")`.

### `tests/test_tags.py` — full router, the canonical example

```python
import pytest

from utils.checks import Role


# ---------- GET /tags ----------

async def test_list_tags_empty(app):
    r = await app.client.get("/tags")
    assert r.status_code == 200
    assert r.json() == []


async def test_list_tags_returns_seeded_rows(app):
    pool = app._transport.app.pool
    await pool.execute(
        "INSERT INTO tags (title, description) VALUES ($1, $2), ($3, $4)",
        "python", "the lang", "rust", "also a lang",
    )
    r = await app.client.get("/tags")
    assert r.status_code == 200
    titles = {row["title"] for row in r.json()}
    assert titles == {"python", "rust"}


async def test_list_tags_filter_by_title_min_length(app):
    # `title` has Query(min_length=3) — two chars should 422
    r = await app.client.get("/tags?title=py")
    assert r.status_code == 422


# ---------- GET /tags/{id} ----------

async def test_get_tag_by_id_found(app):
    pool = app._transport.app.pool
    tag_id = await pool.fetchval(
        "INSERT INTO tags (title, description) VALUES ($1, $2) RETURNING id",
        "go", "a lang",
    )
    r = await app.client.get(f"/tags/{tag_id}")
    assert r.status_code == 200
    assert r.json() == {"id": tag_id, "title": "go", "description": "a lang"}


async def test_get_tag_by_id_not_found(app):
    r = await app.client.get("/tags/999999")
    assert r.status_code == 404


# ---------- POST /tags/create (admin only) ----------

async def test_create_tag_requires_auth(app):
    r = await app.client.post("/tags/create", json={"title": "x", "description": "y"})
    assert r.status_code == 401


@pytest.mark.parametrize("role,expected", [
    (Role.LEADS, 403),
    (Role.MANAGER, 403),
    (Role.ADMIN, 200),
])
async def test_create_tag_role_matrix(app, fake_ory, role, expected):
    fake_ory.login_as(role=role)
    r = await app.client.post("/tags/create", json={"title": "t", "description": "d"})
    assert r.status_code == expected
    if expected == 200:
        body = r.json()
        assert body["title"] == "t" and body["description"] == "d"


async def test_create_tag_validation_error(app, fake_ory):
    fake_ory.login_as(role=Role.ADMIN)
    r = await app.client.post("/tags/create", json={"title": "t"})  # missing description
    assert r.status_code == 422


# ---------- POST /tags/create rate limit ----------

async def test_create_tag_rate_limited(app, fake_ory):
    # decorator on edit_tag/create_tag/delete_tag is "5/minute"
    fake_ory.login_as(role=Role.ADMIN)
    for i in range(5):
        r = await app.client.post(
            "/tags/create", json={"title": f"t{i}", "description": "d"}
        )
        assert r.status_code == 200
    r = await app.client.post("/tags/create", json={"title": "boom", "description": "d"})
    assert r.status_code == 429


# ---------- PUT /tags/{id} ----------

async def test_edit_tag_not_found(app, fake_ory):
    fake_ory.login_as(role=Role.ADMIN)
    r = await app.client.put("/tags/999999", json={"title": "x", "description": "y"})
    assert r.status_code == 404


async def test_edit_tag_persists(app, fake_ory):
    fake_ory.login_as(role=Role.ADMIN)
    pool = app._transport.app.pool
    tag_id = await pool.fetchval(
        "INSERT INTO tags (title, description) VALUES ($1, $2) RETURNING id",
        "old", "old desc",
    )
    r = await app.client.put(
        f"/tags/{tag_id}", json={"title": "new", "description": "new desc"}
    )
    assert r.status_code == 200
    after = await pool.fetchrow("SELECT title, description FROM tags WHERE id = $1", tag_id)
    assert dict(after) == {"title": "new", "description": "new desc"}


# ---------- DELETE /tags/{id} ----------

async def test_delete_tag_removes_row(app, fake_ory):
    fake_ory.login_as(role=Role.ADMIN)
    pool = app._transport.app.pool
    tag_id = await pool.fetchval(
        "INSERT INTO tags (title, description) VALUES ($1, $2) RETURNING id", "x", "y"
    )
    r = await app.client.delete(f"/tags/{tag_id}")
    assert r.status_code == 200
    remaining = await pool.fetchval("SELECT count(*) FROM tags WHERE id = $1", tag_id)
    assert remaining == 0


# ---------- POST /tags/bulk-create ----------

async def test_bulk_create_tags(app, fake_ory):
    fake_ory.login_as(role=Role.ADMIN)
    payload = [
        {"title": "a", "description": "1"},
        {"title": "b", "description": "2"},
    ]
    r = await app.client.post("/tags/bulk-create", json=payload)
    assert r.status_code == 200
    assert {row["title"] for row in r.json()} == {"a", "b"}
```

### Per-resource permission test — projects with Keto check

`has_permission(Project.edit)` calls `ory.check_permission("Project", project_id, "edit", identity_id)`. `FakeOry.grant(...)` populates the allow-list directly:

```python
# tests/test_projects.py

async def test_edit_project_requires_edit_permission(app, fake_ory):
    identity_id = fake_ory.login_as(role=Role.LEADS)
    pool = app._transport.app.pool
    project_id = await pool.fetchval(
        "INSERT INTO projects (name, description) VALUES ($1, $2) RETURNING id",
        "p", "d",
    )

    # No grant yet → 403
    r = await app.client.put(f"/projects/{project_id}", json={"name": "n", "description": "d"})
    assert r.status_code == 403

    # Grant edit on this project to this identity → 200
    fake_ory.grant("Project", str(project_id), "edit", identity_id)
    r = await app.client.put(f"/projects/{project_id}", json={"name": "n", "description": "d"})
    assert r.status_code == 200
```

### Rate-limit test with `hiro` — fast-forward instead of sleeping

```python
import hiro

async def test_create_tag_window_resets_after_a_minute(app, fake_ory):
    fake_ory.login_as(role=Role.ADMIN)
    with hiro.Timeline().freeze() as timeline:
        for i in range(5):
            assert (await app.client.post(
                "/tags/create", json={"title": f"t{i}", "description": "d"}
            )).status_code == 200

        assert (await app.client.post(
            "/tags/create", json={"title": "blocked", "description": "d"}
        )).status_code == 429

        timeline.forward(61)  # cross the 60s window
        assert (await app.client.post(
            "/tags/create", json={"title": "now-ok", "description": "d"}
        )).status_code == 200
```

### Hypothesis property test — media validator (sketch)

```python
# tests/test_media_validation.py
from hypothesis import given, strategies as st

# Adjust import path to match the real validator location
from utils.media import sanitize_filename, validate_upload, magic_matches


@given(st.text(min_size=1, max_size=512))
def test_sanitize_filename_never_returns_traversal(name):
    out = sanitize_filename(name)
    assert ".." not in out
    assert "\x00" not in out
    assert "/" not in out and "\\" not in out


@given(st.binary(min_size=0, max_size=2 * 1024 * 1024))
def test_validate_upload_never_raises(blob):
    # Property: validator returns a result; never raises on arbitrary bytes.
    validate_upload(blob, filename="x.png", declared_mime="image/png")
```

### Schemathesis fuzz — one file, whole spec

```python
# tests/test_fuzz_schemathesis.py
import pytest
import schemathesis
from hypothesis import settings

from utils.checks import Role

schema = schemathesis.from_asgi("/openapi.json", app=None)  # bound in fixture below


@pytest.fixture(autouse=True)
def _admin_session(fake_ory):
    fake_ory.login_as(role=Role.ADMIN)


@schema.parametrize()
@settings(max_examples=30, deadline=None)
def test_no_5xx_and_schema_conformant(case):
    response = case.call_asgi()
    case.validate_response(response)  # asserts no 5xx and response matches declared schema
```

### Hurl integration scenario — full file

```hurl
# tests/hurl/scenarios/02_project_lifecycle.hurl
# Lead identity pre-created via tests/hurl/bootstrap.sh against :4434/admin/identities,
# then promoted to `leads` in members via bootstrap.sql.

GET http://localhost:4433/self-service/login/api
HTTP 200
[Captures]
flow_id: jsonpath "$.id"

POST http://localhost:4433/self-service/login?flow={{flow_id}}
{ "method": "password", "identifier": "lead@test.local", "password": "{{lead_password}}" }
HTTP 200

POST http://localhost:8000/projects
{ "name": "Integration Project", "description": "scenario" }
HTTP 201
[Captures]
project_id: jsonpath "$.id"

PUT http://localhost:8000/projects/{{project_id}}
{ "name": "Renamed", "description": "scenario" }
HTTP 200
[Asserts]
jsonpath "$.name" == "Renamed"

DELETE http://localhost:8000/projects/{{project_id}}
HTTP 200

GET http://localhost:8000/projects/{{project_id}}
HTTP 404
```

## Verification

### Unit/route layer (pytest)
1. `uv run pytest tests/test_tags.py -v` — confirm the first full router passes locally
2. `uv run pytest tests/ -v` — full suite green, including existing `test_limiter.py`
3. `uv run pytest tests/ --cov=src/routes --cov-report=term-missing` — coverage on `src/routes/` should be >90% lines
4. Push to a branch; confirm `.github/workflows/test.yml` runs the new tests across Python 3.12–3.14
5. Spot-check by intentionally breaking a route (e.g. return wrong status) and confirming the right test fails with a clear message

### Integration layer (Hurl + real stack)
6. `make integration` locally — stack comes up, bootstrap creates Kratos identities via admin API and promotes roles in `members`, all `.hurl` scenarios pass, stack tears down clean
7. Spot-check by misconfiguring a Keto policy and confirming `06_permission_denied.hurl` fails (proves the real stack is actually under test, not stubbed)
8. Confirm the CI integration job runs on push to main and is skipped on PR (per-commit time budget stays low)

### Fuzz layer (Schemathesis + Hypothesis)
9. `uv run pytest tests/test_fuzz_schemathesis.py -v` — no 5xx, no schema violations across the whole spec at `max_examples=30`
10. `uv run pytest tests/test_media_validation.py -v --hypothesis-show-statistics` — properties hold; check stats output to confirm Hypothesis is generating diverse inputs (not just shrinking to the same minimal case)
11. Spot-check by introducing a known bug (e.g. validator that crashes on empty bytes) and confirming Hypothesis shrinks to a minimal failing example
