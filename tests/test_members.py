# ruff: noqa: S101

import datetime
import uuid
from typing import Any

import asyncpg
import hiro
import pytest
from blake3 import blake3
from conftest import FakeOryClient, KanaeTestClient

from core import Kanae
from routes.members import ModifyRoleAction
from utils.checks import Role

pytestmark = pytest.mark.asyncio(loop_scope="session")


_SETTINGS_CONTEXT = b"kratos.settings.v1"
_REGISTRATION_CONTEXT = b"kratos.registration.v1"

_VALID_HASH = "a" * 64  # 64 hex chars to match the event thumbnail _HASH_REGEX


def _hook_token(*, master_key: str, context: bytes) -> str:
    return blake3(context, key=bytes.fromhex(master_key)).hexdigest()


async def _insert_member(
    pool: asyncpg.Pool,
    *,
    member_id: uuid.UUID | str,
    name: str = "Test Member",
    display_name: str = "Tester",
    email: str = "test@test.local",
) -> None:
    await pool.execute(
        """
        INSERT INTO members (id, name, display_name, email)
        VALUES ($1, $2, $3, $4)
        """,
        member_id,
        name,
        display_name,
        email,
    )


async def _insert_project(
    pool: asyncpg.Pool,
    *,
    name: str = "Test Project",
    description: str = "desc",
    link: str = "https://example.test",
    project_type: str = "independent",
    active: bool = True,
) -> uuid.UUID:
    return await pool.fetchval(
        """
        INSERT INTO projects (name, description, link, type, active)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id
        """,
        name,
        description,
        link,
        project_type,
        active,
    )


async def _link_member_to_project(
    pool: asyncpg.Pool,
    *,
    member_id: uuid.UUID | str,
    project_id: uuid.UUID,
    role: str = "member",
    joined_at: datetime.datetime | None = None,
) -> None:
    if joined_at is None:
        await pool.execute(
            """
            INSERT INTO project_members (project_id, member_id, role)
            VALUES ($1, $2, $3)
            """,
            project_id,
            member_id,
            role,
        )
    else:
        await pool.execute(
            """
            INSERT INTO project_members (project_id, member_id, role, joined_at)
            VALUES ($1, $2, $3, $4)
            """,
            project_id,
            member_id,
            role,
            joined_at,
        )


async def _insert_event(
    pool: asyncpg.Pool,
    *,
    name: str = "Test Event",
    description: str = "desc",
    location: str = "online",
    event_type: str = "general",
    creator_id: uuid.UUID | str | None = None,
) -> uuid.UUID:
    return await pool.fetchval(
        """
        INSERT INTO events (name, description, location, type, creator_id)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id
        """,
        name,
        description,
        location,
        event_type,
        creator_id,
    )


async def _link_member_to_event(
    pool: asyncpg.Pool,
    *,
    member_id: uuid.UUID | str,
    event_id: uuid.UUID,
    planned: bool | None = None,
    attended: bool = False,
) -> None:
    await pool.execute(
        """
        INSERT INTO events_members (event_id, member_id, planned, attended)
        VALUES ($1, $2, $3, $4)
        """,
        event_id,
        member_id,
        planned,
        attended,
    )


# ──────────────────────────────────────────────────────────────────
# Logged-member lookup, auth required
# ──────────────────────────────────────────────────────────────────


async def test_me_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.get("/members/me")
    assert response.status_code == 401


async def test_me_returns_404_when_member_row_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()  # session created, but no row in members table
    response = await client.client.get("/members/me")
    assert response.status_code == 404


async def test_me_returns_member_with_empty_relations(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id), name="Noelle")

    response = await client.client.get("/members/me")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["id"] == identity_id
    assert body["name"] == "Noelle"
    assert body["projects"] == []
    assert body["events"] == []


async def test_me_returns_member_with_projects_and_events(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)

    project_id = await _insert_project(kanae.pool, name="alpha")
    await _link_member_to_project(
        kanae.pool, member_id=member_uuid, project_id=project_id
    )

    event_id = await _insert_event(kanae.pool, name="kickoff", creator_id=member_uuid)
    await _link_member_to_event(kanae.pool, member_id=member_uuid, event_id=event_id)

    response = await client.client.get("/members/me")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert {p["name"] for p in body["projects"]} == {"alpha"}
    assert {e["name"] for e in body["events"]} == {"kickoff"}


# ──────────────────────────────────────────────────────────────────
# Member by id, unauthenticated
# ──────────────────────────────────────────────────────────────────


async def test_get_member_by_id_returns_404_when_missing(
    client: KanaeTestClient,
) -> None:
    response = await client.client.get(f"/members/{uuid.uuid4()}")
    assert response.status_code == 404


async def test_get_member_by_id_returns_member(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    member_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=member_id, name="By-id member")
    response = await client.client.get(f"/members/{member_id}")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["id"] == str(member_id)
    assert body["name"] == "By-id member"
    assert set(body) == {"id", "name", "created_at", "projects", "events"}
    # the public `Member` shape never leaks the private fields that only
    # `ClientMember` (GET /members/me) exposes
    assert "email" not in body
    assert "roles" not in body
    assert "session" not in body


async def test_get_member_by_id_rejects_non_uuid(client: KanaeTestClient) -> None:
    response = await client.client.get("/members/not-a-uuid")
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Logged member's projects
# ──────────────────────────────────────────────────────────────────


async def test_me_projects_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.get("/members/me/projects")
    assert response.status_code == 401


async def test_me_projects_empty_when_no_membership(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.get("/members/me/projects")
    assert response.status_code == 200
    assert response.json() == []


async def test_me_projects_returns_projects(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)

    project_id = await _insert_project(kanae.pool, name="primary")
    await _link_member_to_project(
        kanae.pool, member_id=member_uuid, project_id=project_id
    )

    response = await client.client.get("/members/me/projects")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert [p["name"] for p in body] == ["primary"]


async def test_me_projects_since_filter_excludes_older(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)

    old_project = await _insert_project(kanae.pool, name="ancient")
    new_project = await _insert_project(kanae.pool, name="recent")

    old_join = datetime.datetime(2020, 1, 1, tzinfo=datetime.UTC)
    new_join = datetime.datetime(2030, 1, 1, tzinfo=datetime.UTC)
    await _link_member_to_project(
        kanae.pool,
        member_id=member_uuid,
        project_id=old_project,
        joined_at=old_join,
    )
    await _link_member_to_project(
        kanae.pool,
        member_id=member_uuid,
        project_id=new_project,
        joined_at=new_join,
    )

    # ISO-8601 strings contain `+` for the timezone offset; embedding them
    # raw in the URL would have FastAPI parse the `+` as a space. Pass via
    # `params=` so httpx percent-encodes correctly.
    boundary = datetime.datetime(2025, 1, 1, tzinfo=datetime.UTC)
    response = await client.client.get(
        "/members/me/projects",
        params={"since": boundary.isoformat()},
    )
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert {p["name"] for p in body} == {"recent"}


# ──────────────────────────────────────────────────────────────────
# Logged member's events
# ──────────────────────────────────────────────────────────────────


async def test_me_events_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.get("/members/me/events")
    assert response.status_code == 401


async def test_me_events_empty_when_no_membership(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.get("/members/me/events")
    assert response.status_code == 200
    assert response.json() == []


async def test_me_events_returns_events(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(kanae.pool, name="hackathon", creator_id=member_uuid)
    await _link_member_to_event(
        kanae.pool, member_id=member_uuid, event_id=event_id, attended=True
    )

    response = await client.client.get("/members/me/events")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert [e["name"] for e in body] == ["hackathon"]
    assert body[0]["thumbnail"] is None


async def test_me_events_surfaces_thumbnail(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(kanae.pool, name="gala", creator_id=member_uuid)
    await _link_member_to_event(
        kanae.pool, member_id=member_uuid, event_id=event_id, attended=True
    )
    await kanae.pool.execute(
        "UPDATE events SET thumbnail_hash = $2 WHERE id = $1", event_id, _VALID_HASH
    )

    response = await client.client.get("/members/me/events")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    thumbnail = body[0]["thumbnail"]
    assert thumbnail["hash"] == _VALID_HASH
    assert thumbnail["url"].endswith(f"/thumbnails/{_VALID_HASH}.webp")


async def test_me_events_planned_filter(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)

    planned_event = await _insert_event(
        kanae.pool, name="planned", creator_id=member_uuid
    )
    unplanned_event = await _insert_event(
        kanae.pool, name="unplanned", creator_id=member_uuid
    )
    await _link_member_to_event(
        kanae.pool,
        member_id=member_uuid,
        event_id=planned_event,
        planned=True,
    )
    await _link_member_to_event(
        kanae.pool,
        member_id=member_uuid,
        event_id=unplanned_event,
        planned=False,
    )

    response = await client.client.get("/members/me/events?planned=true")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert {e["name"] for e in body} == {"planned"}


async def test_me_events_attended_filter(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)

    attended_event = await _insert_event(
        kanae.pool, name="attended", creator_id=member_uuid
    )
    skipped_event = await _insert_event(
        kanae.pool, name="skipped", creator_id=member_uuid
    )
    await _link_member_to_event(
        kanae.pool,
        member_id=member_uuid,
        event_id=attended_event,
        attended=True,
    )
    await _link_member_to_event(
        kanae.pool,
        member_id=member_uuid,
        event_id=skipped_event,
        attended=False,
    )

    response = await client.client.get("/members/me/events?attended=true")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert {e["name"] for e in body} == {"attended"}


async def _insert_timed_event(
    pool: asyncpg.Pool,
    *,
    name: str,
    start_at: datetime.datetime,
    end_at: datetime.datetime,
    creator_id: uuid.UUID | str,
) -> uuid.UUID:
    return await pool.fetchval(
        """
        INSERT INTO events (name, description, location, type, start_at, end_at, creator_id)
        VALUES ($1, 'desc', 'online', 'general', $2, $3, $4)
        RETURNING id
        """,
        name,
        start_at,
        end_at,
        creator_id,
    )


async def _seed_future_and_past_events(
    pool: asyncpg.Pool, *, member_id: uuid.UUID
) -> None:
    now = datetime.datetime.now(datetime.UTC)
    future_event = await _insert_timed_event(
        pool,
        name="future",
        start_at=now + datetime.timedelta(days=1),
        end_at=now + datetime.timedelta(days=2),
        creator_id=member_id,
    )
    past_event = await _insert_timed_event(
        pool,
        name="past",
        start_at=now - datetime.timedelta(days=2),
        end_at=now - datetime.timedelta(days=1),
        creator_id=member_id,
    )
    await _link_member_to_event(pool, member_id=member_id, event_id=future_event)
    await _link_member_to_event(pool, member_id=member_id, event_id=past_event)


async def test_me_events_upcoming_filter(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    await _seed_future_and_past_events(kanae.pool, member_id=member_uuid)

    response = await client.client.get("/members/me/events?upcoming=true")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert {e["name"] for e in body} == {"future"}


async def test_me_events_past_filter(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    await _seed_future_and_past_events(kanae.pool, member_id=member_uuid)

    response = await client.client.get("/members/me/events?past=true")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert {e["name"] for e in body} == {"past"}


async def test_me_events_rejects_both_upcoming_and_past(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.get("/members/me/events?upcoming=true&past=true")
    assert response.status_code == 400


async def test_me_events_surfaces_tags(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(kanae.pool, name="tagged", creator_id=member_uuid)
    await _link_member_to_event(kanae.pool, member_id=member_uuid, event_id=event_id)

    tag_id = await kanae.pool.fetchval(
        "INSERT INTO tags (title, description) VALUES ($1, $2) RETURNING id",
        "python",
        "desc",
    )
    await kanae.pool.execute(
        "INSERT INTO event_tags (event_id, tag_id) VALUES ($1, $2)", event_id, tag_id
    )

    response = await client.client.get("/members/me/events")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert body[0]["tags"] == ["python"]


# ──────────────────────────────────────────────────────────────────
# Logout
# ──────────────────────────────────────────────────────────────────


async def test_logout_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post("/members/logout")
    assert response.status_code == 401


async def test_logout_revokes_session(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    session_id = fake_ory.session.id if fake_ory.session else None
    assert session_id is not None

    response = await client.client.post("/members/logout")
    assert response.status_code == 200
    assert response.json() == {"message": "ok"}

    assert fake_ory.revoked_sessions == [str(session_id)]


# ──────────────────────────────────────────────────────────────────
# Settings webhook
# ──────────────────────────────────────────────────────────────────


def _build_hook_payload(
    *,
    identity_id: uuid.UUID,
    email: str = "hook@test.local",
    name: str = "Hooked",
    display_name: str | None = "Display Hook",
) -> dict[str, Any]:
    return {
        "flow_id": str(uuid.uuid4()),
        "identity": {
            "id": str(identity_id),
            "schema_id": "default",
            "traits": {
                "email": email,
                "name": name,
                "display_name": display_name,
            },
        },
    }


async def test_settings_webhook_rejects_missing_header(
    client: KanaeTestClient,
) -> None:
    payload = _build_hook_payload(identity_id=uuid.uuid4())
    response = await client.client.post("/member/webhooks/settings", json=payload)
    assert response.status_code == 422


async def test_settings_webhook_rejects_invalid_token(
    client: KanaeTestClient,
) -> None:
    payload = _build_hook_payload(identity_id=uuid.uuid4())
    response = await client.client.post(
        "/member/webhooks/settings",
        json=payload,
        headers={"X-Webhook-Token": "deadbeef"},
    )
    assert response.status_code == 401


async def test_settings_webhook_upserts_member(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    identity_id = uuid.uuid4()
    payload = _build_hook_payload(
        identity_id=identity_id, email="new@test.local", name="Fresh"
    )
    token = _hook_token(
        master_key=kanae.config.ory.kratos_webhook_master_key,
        context=_SETTINGS_CONTEXT,
    )
    response = await client.client.post(
        "/member/webhooks/settings",
        json=payload,
        headers={"X-Webhook-Token": token},
    )
    assert response.status_code == 204

    row = await kanae.pool.fetchrow(
        "SELECT name, email FROM members WHERE id = $1", identity_id
    )
    assert row is not None
    assert row["name"] == "Fresh"
    assert row["email"] == "new@test.local"


async def test_settings_webhook_updates_existing_member(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    identity_id = uuid.uuid4()
    await _insert_member(
        kanae.pool, member_id=identity_id, name="Original", email="orig@test.local"
    )
    payload = _build_hook_payload(
        identity_id=identity_id, email="updated@test.local", name="Updated"
    )
    token = _hook_token(
        master_key=kanae.config.ory.kratos_webhook_master_key,
        context=_SETTINGS_CONTEXT,
    )

    response = await client.client.post(
        "/member/webhooks/settings",
        json=payload,
        headers={"X-Webhook-Token": token},
    )
    assert response.status_code == 204

    row = await kanae.pool.fetchrow(
        "SELECT name, email FROM members WHERE id = $1", identity_id
    )
    assert row is not None
    assert row["name"] == "Updated"
    assert row["email"] == "updated@test.local"


async def test_settings_webhook_rejects_extra_traits(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    identity_id = uuid.uuid4()
    payload = _build_hook_payload(identity_id=identity_id)
    payload["identity"]["traits"]["spy_field"] = "leak"
    token = _hook_token(
        master_key=kanae.config.ory.kratos_webhook_master_key,
        context=_SETTINGS_CONTEXT,
    )

    response = await client.client.post(
        "/member/webhooks/settings",
        json=payload,
        headers={"X-Webhook-Token": token},
    )
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Registration webhook
# ──────────────────────────────────────────────────────────────────


async def test_registration_webhook_rejects_invalid_token(
    client: KanaeTestClient,
) -> None:
    payload = _build_hook_payload(identity_id=uuid.uuid4())
    response = await client.client.post(
        "/member/webhooks/registration",
        json=payload,
        headers={"X-Webhook-Token": "deadbeef"},
    )
    assert response.status_code == 401


async def test_registration_webhook_rejects_settings_token(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    payload = _build_hook_payload(identity_id=uuid.uuid4())
    settings_token = _hook_token(
        master_key=kanae.config.ory.kratos_webhook_master_key,
        context=_SETTINGS_CONTEXT,
    )

    response = await client.client.post(
        "/member/webhooks/registration",
        json=payload,
        headers={"X-Webhook-Token": settings_token},
    )
    assert response.status_code == 401


async def test_registration_webhook_inserts_member(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    identity_id = uuid.uuid4()
    payload = _build_hook_payload(
        identity_id=identity_id, email="reg@test.local", name="Registered"
    )
    token = _hook_token(
        master_key=kanae.config.ory.kratos_webhook_master_key,
        context=_REGISTRATION_CONTEXT,
    )

    response = await client.client.post(
        "/member/webhooks/registration",
        json=payload,
        headers={"X-Webhook-Token": token},
    )
    assert response.status_code == 204

    row = await kanae.pool.fetchrow(
        "SELECT name, email FROM members WHERE id = $1", identity_id
    )
    assert row is not None
    assert row["name"] == "Registered"
    assert row["email"] == "reg@test.local"


# ──────────────────────────────────────────────────────────────────
# Rate limits
# ──────────────────────────────────────────────────────────────────


async def test_me_enforces_10_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    with hiro.Timeline().freeze():
        for _ in range(10):
            response = await client.client.get("/members/me")
            assert response.status_code == 200

        blocked = await client.client.get("/members/me")
        assert blocked.status_code == 429


async def test_logout_enforces_3_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    with hiro.Timeline().freeze():
        for _ in range(3):
            response = await client.client.post("/members/logout")
            assert response.status_code == 200

        blocked = await client.client.post("/members/logout")
        assert blocked.status_code == 429


# ──────────────────────────────────────────────────────────────────
# PUT /members/{member_id}/role — sudo-gated global role management
# ──────────────────────────────────────────────────────────────────


async def test_modify_role_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.put(
        f"/members/{uuid.uuid4()}/role",
        json={"role": "manager", "action": ModifyRoleAction.GRANT.value},
    )
    assert response.status_code == 401


async def test_modify_role_rejects_unprivileged(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()  # authenticated, but neither root nor sudo-elevated
    response = await client.client.put(
        f"/members/{uuid.uuid4()}/role",
        json={"role": "manager", "action": ModifyRoleAction.GRANT.value},
    )
    assert response.status_code == 403


async def test_modify_role_grant_succeeds_for_root(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ROOT)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)

    response = await client.client.put(
        f"/members/{target}/role",
        json={"role": "manager", "action": ModifyRoleAction.GRANT.value},
    )
    assert response.status_code == 200
    assert await fake_ory.check_permission("Role", "manager", "member", str(target))


async def test_modify_role_revoke_succeeds_for_root(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ROOT)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    await fake_ory.grant("Role", "leads", "member", subject_id=str(target))

    response = await client.client.put(
        f"/members/{target}/role",
        json={"role": "leads", "action": ModifyRoleAction.REVOKE.value},
    )
    assert response.status_code == 200
    assert not await fake_ory.check_permission("Role", "leads", "member", str(target))


async def test_modify_role_grant_succeeds_via_sudo(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    admin_id = fake_ory.login_as(Role.ADMIN, aal="aal2")
    await _insert_member(kanae.pool, member_id=uuid.UUID(admin_id))
    await kanae.sudo.grant(admin_id, reason="manage roles")

    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target, email="target@test.local")

    response = await client.client.put(
        f"/members/{target}/role",
        json={"role": "admin", "action": ModifyRoleAction.GRANT.value},
    )
    assert response.status_code == 200
    assert await fake_ory.check_permission("Role", "admin", "member", str(target))


async def test_modify_role_404_when_member_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ROOT)
    response = await client.client.put(
        f"/members/{uuid.uuid4()}/role",
        json={"role": "manager", "action": ModifyRoleAction.GRANT.value},
    )
    assert response.status_code == 404


async def test_modify_role_refuses_self(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as(Role.ROOT)
    response = await client.client.put(
        f"/members/{identity_id}/role",
        json={"role": "manager", "action": ModifyRoleAction.GRANT.value},
    )
    assert response.status_code == 409


async def test_modify_role_rejects_unassignable_role(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ROOT)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    response = await client.client.put(
        f"/members/{target}/role",
        json={"role": "root", "action": ModifyRoleAction.GRANT.value},
    )
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# DELETE /members/me — self-service account deletion (auth-only)
# ──────────────────────────────────────────────────────────────────


async def test_delete_me_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.delete("/members/me")
    assert response.status_code == 401


async def test_delete_me_tears_down_and_removes_row(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    response = await client.client.delete("/members/me")
    assert response.status_code == 200

    remaining = await kanae.pool.fetchval(
        "SELECT 1 FROM members WHERE id = $1", uuid.UUID(identity_id)
    )
    assert remaining is None
    assert fake_ory.revoked_all_sessions == [identity_id]
    assert fake_ory.purged_subjects == [identity_id]
    assert fake_ory.deleted_identities == [identity_id]


# ──────────────────────────────────────────────────────────────────
# DELETE /members/{member_id} — sudo-gated administrative hard delete
# ──────────────────────────────────────────────────────────────────


async def test_delete_member_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.delete(f"/members/{uuid.uuid4()}")
    assert response.status_code == 401


async def test_delete_member_rejects_unprivileged(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.delete(f"/members/{uuid.uuid4()}")
    assert response.status_code == 403


async def test_delete_member_succeeds_for_root(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ROOT)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)

    response = await client.client.delete(f"/members/{target}")
    assert response.status_code == 200

    remaining = await kanae.pool.fetchval("SELECT 1 FROM members WHERE id = $1", target)
    assert remaining is None
    assert fake_ory.revoked_all_sessions == [str(target)]
    assert fake_ory.purged_subjects == [str(target)]
    assert fake_ory.deleted_identities == [str(target)]


async def test_delete_member_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ROOT)
    response = await client.client.delete(f"/members/{uuid.uuid4()}")
    assert response.status_code == 404


async def test_delete_member_refuses_self(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as(Role.ROOT)
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    response = await client.client.delete(f"/members/{identity_id}")
    assert response.status_code == 409

    # the self-guard runs before any teardown
    assert fake_ory.purged_subjects == []
    still_here = await kanae.pool.fetchval(
        "SELECT 1 FROM members WHERE id = $1", uuid.UUID(identity_id)
    )
    assert still_here == 1


# ──────────────────────────────────────────────────────────────────
# Rate limits — role write 5/min, member delete 1/min
# ──────────────────────────────────────────────────────────────────


async def test_modify_role_enforces_5_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ROOT)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    body = {"role": "manager", "action": ModifyRoleAction.GRANT.value}

    with hiro.Timeline().freeze():
        for _ in range(5):
            response = await client.client.put(f"/members/{target}/role", json=body)
            assert response.status_code == 200

        blocked = await client.client.put(f"/members/{target}/role", json=body)
        assert blocked.status_code == 429


async def test_delete_member_enforces_1_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ROOT)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)

    with hiro.Timeline().freeze():
        first = await client.client.delete(f"/members/{target}")
        assert first.status_code == 200

        # the limiter buckets per-URL, so the second hit must reuse the same path
        # to land in the same bucket; it is blocked before the handler runs.
        blocked = await client.client.delete(f"/members/{target}")
        assert blocked.status_code == 429


# ──────────────────────────────────────────────────────────────────
# GET /members/me — roles, own private traits, and embedded session
# ──────────────────────────────────────────────────────────────────


async def test_me_includes_roles_and_private_traits(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as(Role.ADMIN, email="me@test.local")
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id), name="Self")

    response = await client.client.get("/members/me")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["email"] == "me@test.local"
    # login_as seeds display_name from the email
    assert body["display_name"] == "me@test.local"
    assert body["roles"] == [Role.ADMIN.value]


async def test_me_roles_empty_when_none_granted(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    response = await client.client.get("/members/me")
    assert response.status_code == 200
    assert response.json()["roles"] == []


async def test_me_embeds_session_view(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as(aal="aal2")
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    response = await client.client.get("/members/me")
    assert response.status_code == 200
    session: dict[str, Any] = response.json()["session"]
    assert session["aal"] == "aal2"
    assert session["active"] is True
    assert session["authenticated_at"] is not None
    assert session["issued_at"] is not None
    assert session["expires_at"] is not None


# ──────────────────────────────────────────────────────────────────
# GET /members — admin member directory (search + pagination)
# ──────────────────────────────────────────────────────────────────


async def test_list_members_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.get("/members")
    assert response.status_code == 401


async def test_list_members_rejects_unprivileged(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()  # authenticated, but not an admin
    response = await client.client.get("/members")
    assert response.status_code == 403


async def test_list_members_returns_all_for_admin(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ADMIN)
    await _insert_member(
        kanae.pool, member_id=uuid.uuid4(), name="Ada", email="ada@test.local"
    )
    await _insert_member(
        kanae.pool, member_id=uuid.uuid4(), name="Grace", email="grace@test.local"
    )

    response = await client.client.get("/members")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["total"] == 2
    assert {row["name"] for row in body["data"]} == {"Ada", "Grace"}


async def test_list_members_rejects_short_query(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    response = await client.client.get("/members?query=ab")
    assert response.status_code == 422


async def test_list_members_name_trigram_search(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ADMIN)
    await _insert_member(
        kanae.pool, member_id=uuid.uuid4(), name="Zachary", email="z@test.local"
    )
    await _insert_member(
        kanae.pool, member_id=uuid.uuid4(), name="Quinlan", email="q@test.local"
    )

    response = await client.client.get("/members", params={"query": "Zachary"})
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert {row["name"] for row in body["data"]} == {"Zachary"}


async def test_list_members_email_substring_search(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ADMIN)
    await _insert_member(
        kanae.pool, member_id=uuid.uuid4(), name="Bob", email="findme@test.local"
    )
    await _insert_member(
        kanae.pool, member_id=uuid.uuid4(), name="Carol", email="elsewhere@test.local"
    )

    # the query shares no trigrams with either name, so only the email match lands
    response = await client.client.get("/members", params={"query": "findme"})
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert {row["email"] for row in body["data"]} == {"findme@test.local"}


async def test_list_members_pagination(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ADMIN)
    for index in range(3):
        await _insert_member(
            kanae.pool,
            member_id=uuid.uuid4(),
            name=f"member-{index}",
            email=f"m{index}@test.local",
        )

    response = await client.client.get("/members?page=1&size=2")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["total"] == 3
    assert len(body["data"]) == 2


# ──────────────────────────────────────────────────────────────────
# GET /members/{member_id}/roles — role read (self or admin)
# ──────────────────────────────────────────────────────────────────


async def test_member_roles_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.get(f"/members/{uuid.uuid4()}/roles")
    assert response.status_code == 401


async def test_member_roles_self_reads_own(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))
    await fake_ory.grant("Role", "leads", "member", subject_id=identity_id)

    response = await client.client.get(f"/members/{identity_id}/roles")
    assert response.status_code == 200
    assert response.json() == {"roles": ["leads"]}


async def test_member_roles_admin_reads_other(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ADMIN)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    await fake_ory.grant("Role", "manager", "member", subject_id=str(target))

    response = await client.client.get(f"/members/{target}/roles")
    assert response.status_code == 200
    assert response.json() == {"roles": ["manager"]}


async def test_member_roles_rejects_unprivileged_other(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()  # authenticated, not an admin, not the target
    response = await client.client.get(f"/members/{uuid.uuid4()}/roles")
    assert response.status_code == 403


async def test_member_roles_404_when_member_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    response = await client.client.get(f"/members/{uuid.uuid4()}/roles")
    assert response.status_code == 404


async def test_member_roles_empty_when_none_granted(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    response = await client.client.get(f"/members/{identity_id}/roles")
    assert response.status_code == 200
    assert response.json() == {"roles": []}


# ──────────────────────────────────────────────────────────────────
# GET /members/me/projects/invites — caller's handshake inbox, 10/min
# ──────────────────────────────────────────────────────────────────


async def _insert_invite(
    pool: asyncpg.Pool,
    *,
    project_id: uuid.UUID,
    member_id: uuid.UUID | str,
    kind: str,
    invited_by: uuid.UUID | str | None = None,
    status: str = "pending",
    expires_at: datetime.datetime | None = None,
) -> uuid.UUID:
    return await pool.fetchval(
        """
        INSERT INTO project_invites
            (project_id, member_id, invited_by, kind, status, expires_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id
        """,
        project_id,
        member_id,
        invited_by,
        kind,
        status,
        expires_at,
    )


async def test_my_invites_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.get("/members/me/projects/invites")
    assert response.status_code == 401


async def test_my_invites_empty_when_none(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.get("/members/me/projects/invites")
    assert response.status_code == 200
    assert response.json() == []


async def test_my_invites_returns_own_handshakes(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    # one pending handshake per (project, member), so use two projects to hold
    # both an inbound invite and an outbound request at once
    project_a = await _insert_project(kanae.pool, name="inbox-a")
    project_b = await _insert_project(kanae.pool, name="inbox-b")
    invite_in = await _insert_invite(
        kanae.pool, project_id=project_a, member_id=member_uuid, kind="invite"
    )
    request_out = await _insert_invite(
        kanae.pool,
        project_id=project_b,
        member_id=member_uuid,
        invited_by=member_uuid,
        kind="request",
    )

    response = await client.client.get("/members/me/projects/invites")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert {row["id"] for row in body} == {str(invite_in), str(request_out)}


async def test_my_invites_excludes_other_members(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    other = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=other, email="other@test.local")
    project_id = await _insert_project(kanae.pool, name="inbox-isolation")
    await _insert_invite(
        kanae.pool, project_id=project_id, member_id=other, kind="invite"
    )

    response = await client.client.get("/members/me/projects/invites")
    assert response.status_code == 200
    assert response.json() == []


async def test_my_invites_filters_by_status(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="inbox-status")
    pending = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=member_uuid, kind="invite"
    )
    await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=member_uuid,
        invited_by=member_uuid,
        kind="request",
        status="accepted",
    )

    response = await client.client.get(
        "/members/me/projects/invites", params={"status": "pending"}
    )
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert [row["id"] for row in body] == [str(pending)]


async def test_my_invites_filters_by_kind(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_a = await _insert_project(kanae.pool, name="inbox-kind-a")
    project_b = await _insert_project(kanae.pool, name="inbox-kind-b")
    await _insert_invite(
        kanae.pool, project_id=project_a, member_id=member_uuid, kind="invite"
    )
    request_out = await _insert_invite(
        kanae.pool,
        project_id=project_b,
        member_id=member_uuid,
        invited_by=member_uuid,
        kind="request",
    )

    response = await client.client.get(
        "/members/me/projects/invites", params={"kind": "request"}
    )
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert [row["id"] for row in body] == [str(request_out)]


async def test_my_invites_lazily_marks_expired(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="inbox-expire")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=member_uuid,
        kind="invite",
        expires_at=datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=1),
    )

    response = await client.client.get("/members/me/projects/invites")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    row = next(r for r in body if r["id"] == str(invite_id))
    assert row["status"] == "expired"


async def test_my_invites_enforces_10_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    with hiro.Timeline().freeze():
        for _ in range(10):
            response = await client.client.get("/members/me/projects/invites")
            assert response.status_code == 200

        blocked = await client.client.get("/members/me/projects/invites")
        assert blocked.status_code == 429
