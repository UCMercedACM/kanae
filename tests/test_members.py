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
    assert response.json() == {"message": "okie dokie"}

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
