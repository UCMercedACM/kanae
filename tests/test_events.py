# ruff: noqa: S101

import datetime
import uuid
from typing import Any

import asyncpg
import hiro
import pytest
from conftest import FakeOryClient, KanaeTestClient

from core import Kanae
from utils.checks import Role

pytestmark = pytest.mark.asyncio(loop_scope="session")

_VALID_HASH = "a" * 64  # 64 hex chars to match the route's _HASH_REGEX


async def _insert_member(
    pool: asyncpg.Pool,
    *,
    member_id: uuid.UUID | str,
    name: str = "Member",
    email: str = "member@test.local",
) -> uuid.UUID:
    return await pool.fetchval(
        """
        INSERT INTO members (id, name, display_name, email)
        VALUES ($1, $2, $3, $4)
        RETURNING id
        """,
        member_id,
        name,
        name,
        email,
    )


async def _insert_event(
    pool: asyncpg.Pool,
    *,
    name: str = "Event",
    description: str = "desc",
    location: str = "online",
    event_type: str = "general",
    creator_id: uuid.UUID | str | None = None,
    start_at: datetime.datetime | None = None,
    end_at: datetime.datetime | None = None,
    timezone: str = "UTC",
) -> uuid.UUID:
    now = datetime.datetime.now(datetime.UTC)
    return await pool.fetchval(
        """
        INSERT INTO events
            (name, description, start_at, end_at, location, type, creator_id, timezone)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        RETURNING id
        """,
        name,
        description,
        start_at or now - datetime.timedelta(minutes=30),
        end_at or now + datetime.timedelta(hours=1),
        location,
        event_type,
        creator_id,
        timezone,
    )


def _valid_event_payload(
    *,
    creator_id: uuid.UUID | str | None = None,
    name: str = "Created Event",
    description: str = "from-test",
    location: str = "online",
    event_type: str = "general",
    start_offset: datetime.timedelta = datetime.timedelta(minutes=-30),
    end_offset: datetime.timedelta = datetime.timedelta(hours=1),
) -> dict[str, Any]:
    now = datetime.datetime.now(datetime.UTC)
    return {
        "id": str(uuid.uuid4()),
        "name": name,
        "description": description,
        "start_at": (now + start_offset).isoformat(),
        "end_at": (now + end_offset).isoformat(),
        "location": location,
        "type": event_type,
        "timezone": "UTC",
        "creator_id": str(creator_id) if creator_id else str(uuid.uuid4()),
    }


# ──────────────────────────────────────────────────────────────────
# Listing events, unauthenticated
# ──────────────────────────────────────────────────────────────────


async def test_list_events_returns_empty_page(client: KanaeTestClient) -> None:
    response = await client.client.get("/events")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["data"] == []
    assert body["total"] == 0


async def test_list_events_returns_seeded_rows(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    creator_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=creator_id)
    await _insert_event(kanae.pool, name="alpha", creator_id=creator_id)
    await _insert_event(kanae.pool, name="beta", creator_id=creator_id)

    response = await client.client.get("/events")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["total"] == 2
    assert {row["name"] for row in body["data"]} == {"alpha", "beta"}


async def test_list_events_rejects_short_name_filter(client: KanaeTestClient) -> None:
    response = await client.client.get("/events?name=hi")
    assert response.status_code == 422


async def test_list_events_pagination(client: KanaeTestClient, kanae: Kanae) -> None:
    creator_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=creator_id)
    for index in range(3):
        await _insert_event(kanae.pool, name=f"page-{index}", creator_id=creator_id)

    response = await client.client.get("/events?page=1&size=2")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["total"] == 3
    assert len(body["data"]) == 2


# ──────────────────────────────────────────────────────────────────
# Fetch event by id, unauthenticated
# ──────────────────────────────────────────────────────────────────


async def test_get_event_returns_404_when_missing(client: KanaeTestClient) -> None:
    response = await client.client.get(f"/events/{uuid.uuid4()}")
    assert response.status_code == 404


async def test_get_event_returns_row(client: KanaeTestClient, kanae: Kanae) -> None:
    creator_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=creator_id)
    event_id = await _insert_event(kanae.pool, name="exists", creator_id=creator_id)

    response = await client.client.get(f"/events/{event_id}")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["id"] == str(event_id)
    assert body["name"] == "exists"
    assert body["timezone"] == "UTC"


async def test_get_event_rejects_non_uuid_id(client: KanaeTestClient) -> None:
    response = await client.client.get("/events/not-a-uuid")
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Edit event, requires Event.edit, 10 per minute
# ──────────────────────────────────────────────────────────────────


async def test_edit_event_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.put(
        f"/events/{uuid.uuid4()}",
        json={"name": "x", "description": "y", "location": "z"},
    )
    assert response.status_code == 401


async def test_edit_event_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.put(
        f"/events/{uuid.uuid4()}",
        json={"name": "x", "description": "y", "location": "z"},
    )
    assert response.status_code == 403


async def test_edit_event_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing_id = uuid.uuid4()
    fake_ory.grant("Event", str(missing_id), "edit", identity_id)

    response = await client.client.put(
        f"/events/{missing_id}",
        json={"name": "x", "description": "y", "location": "z"},
    )
    assert response.status_code == 404


async def test_edit_event_persists_changes(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(kanae.pool, name="old", creator_id=member_uuid)
    fake_ory.grant("Event", str(event_id), "edit", identity_id)

    response = await client.client.put(
        f"/events/{event_id}",
        json={"name": "new", "description": "new-desc", "location": "new-loc"},
    )
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["name"] == "new"
    assert body["description"] == "new-desc"
    assert body["location"] == "new-loc"


async def test_edit_event_with_datetime_payload_updates_time_fields(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(
        kanae.pool, name="time-update", creator_id=member_uuid
    )
    fake_ory.grant("Event", str(event_id), "edit", identity_id)

    new_start = datetime.datetime(2030, 5, 1, 12, 0, tzinfo=datetime.UTC)
    new_end = new_start + datetime.timedelta(hours=2)
    response = await client.client.put(
        f"/events/{event_id}",
        json={
            "name": "still-time-update",
            "description": "moved",
            "location": "online",
            "start_at": new_start.isoformat(),
            "end_at": new_end.isoformat(),
            "timezone": "America/Los_Angeles",
        },
    )
    assert response.status_code == 200
    row = await kanae.pool.fetchrow(
        "SELECT start_at, end_at, timezone FROM events WHERE id = $1", event_id
    )
    assert row is not None
    assert row["start_at"] == new_start
    assert row["end_at"] == new_end
    assert row["timezone"] == "America/Los_Angeles"


# ──────────────────────────────────────────────────────────────────
# Delete event, requires Event.own, 10 per minute
# ──────────────────────────────────────────────────────────────────


async def test_delete_event_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.delete(f"/events/{uuid.uuid4()}")
    assert response.status_code == 401


async def test_delete_event_rejects_without_own_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.delete(f"/events/{uuid.uuid4()}")
    assert response.status_code == 403


async def test_delete_event_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing_id = uuid.uuid4()
    fake_ory.grant("Event", str(missing_id), "own", identity_id)

    response = await client.client.delete(f"/events/{missing_id}")
    assert response.status_code == 404


async def test_delete_event_removes_row(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(kanae.pool, name="doomed", creator_id=member_uuid)
    fake_ory.grant("Event", str(event_id), "own", identity_id)

    response = await client.client.delete(f"/events/{event_id}")
    assert response.status_code == 200

    remaining: int = await kanae.pool.fetchval(
        "SELECT count(*) FROM events WHERE id = $1", event_id
    )
    assert remaining == 0


# ──────────────────────────────────────────────────────────────────
# Create event, admin or leads only, 15 per minute
# ──────────────────────────────────────────────────────────────────


async def test_create_event_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post("/events/create", json=_valid_event_payload())
    assert response.status_code == 401


async def test_create_event_rejects_non_role(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post("/events/create", json=_valid_event_payload())
    assert response.status_code == 403


@pytest.mark.parametrize("role", [Role.ADMIN, Role.LEADS])
async def test_create_event_allowed_roles_succeed(
    client: KanaeTestClient,
    fake_ory: FakeOryClient,
    kanae: Kanae,
    role: Role,
) -> None:
    identity_id = fake_ory.login_as(role)
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)

    payload = _valid_event_payload(creator_id=member_uuid, name=f"created-{role.value}")
    response = await client.client.post("/events/create", json=payload)
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["name"] == payload["name"]
    assert body["creator_id"] == str(member_uuid)

    attendance = await kanae.pool.fetchrow(
        "SELECT attendance_hash, attendance_code FROM event_attendance_codes "
        "WHERE event_id = $1",
        uuid.UUID(body["id"]),
    )
    assert attendance is not None
    assert attendance["attendance_hash"]
    assert attendance["attendance_code"]


async def test_create_event_rejects_missing_required_field(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    payload = _valid_event_payload()
    del payload["name"]
    response = await client.client.post("/events/create", json=payload)
    assert response.status_code == 422


async def test_create_event_rejects_invalid_type_enum(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    payload = _valid_event_payload()
    payload["type"] = "not-a-real-type"
    response = await client.client.post("/events/create", json=payload)
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Join event, requires session, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_join_event_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(f"/events/{uuid.uuid4()}/join")
    assert response.status_code == 401


async def test_join_event_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(f"/events/{uuid.uuid4()}/join")
    assert response.status_code == 404


async def test_join_event_rejects_ended_event(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)

    past = datetime.datetime(2000, 1, 1, tzinfo=datetime.UTC)
    event_id = await _insert_event(
        kanae.pool,
        name="ancient",
        creator_id=member_uuid,
        start_at=past,
        end_at=past + datetime.timedelta(hours=1),
    )

    response = await client.client.post(f"/events/{event_id}/join")
    assert response.status_code == 403


async def test_join_event_inserts_membership(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(kanae.pool, name="open", creator_id=member_uuid)

    response = await client.client.post(f"/events/{event_id}/join")
    assert response.status_code == 200

    row = await kanae.pool.fetchrow(
        "SELECT planned, attended FROM events_members "
        "WHERE event_id = $1 AND member_id = $2",
        event_id,
        member_uuid,
    )
    assert row is not None
    assert row["planned"] is True
    assert row["attended"] is False


async def test_join_event_returns_409_on_duplicate(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(kanae.pool, name="popular", creator_id=member_uuid)

    first = await client.client.post(f"/events/{event_id}/join")
    assert first.status_code == 200
    second = await client.client.post(f"/events/{event_id}/join")
    assert second.status_code == 409


# ──────────────────────────────────────────────────────────────────
# Attendance verification, requires session, 5 per second
# ──────────────────────────────────────────────────────────────────


async def test_verify_attendance_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        f"/events/{uuid.uuid4()}/verify", json={"code": "abcdefgh"}
    )
    assert response.status_code == 401


async def test_verify_attendance_rejects_long_code(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    """A `code` longer than 8 characters must 422 with a clean body.

    Previously this test was a `pytest.raises` sentinel for a serialization
    bug: `VerifyRequest`'s `model_validator(mode="before")` raised a
    `ValueError`, and the validation-error handler embedded that exception
    in the response payload, where `ORJSONResponse.render` crashed inside
    `orjson.dumps` with `TypeError: Type is not JSON serializable:
    ValueError`. The fix in `core.py:request_validation_error_handler`
    calls `exc.errors(include_context=False, include_url=False)` so the
    raw exception never reaches orjson, and `ORJSONResponse.render` also
    falls back to `default=str` for any other un-encodable values.
    """
    fake_ory.login_as()
    response = await client.client.post(
        f"/events/{uuid.uuid4()}/verify",
        json={"code": "way-too-long-code"},
    )
    assert response.status_code == 422
    body: dict[str, Any] = response.json()
    assert body["result"] == "error"
    assert any(
        "Must be 8 characters or less" in error.get("msg", "")
        for error in body["errors"]
    )


async def test_verify_attendance_returns_404_for_unknown_code(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(
        f"/events/{uuid.uuid4()}/verify", json={"code": "zzzzzzzz"}
    )
    assert response.status_code == 404


async def test_verify_attendance_marks_member_attended(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # Create the event via the real route so attendance_hash + attendance_code
    # are populated by the same code path production uses.
    identity_id = fake_ory.login_as(Role.ADMIN)
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)

    create_resp = await client.client.post(
        "/events/create",
        json=_valid_event_payload(
            creator_id=member_uuid,
            name="verify-me",
            start_offset=datetime.timedelta(minutes=-30),
            end_offset=datetime.timedelta(hours=1),
        ),
    )
    assert create_resp.status_code == 200
    event_id = uuid.UUID(create_resp.json()["id"])

    attendance_code: str = await kanae.pool.fetchval(
        "SELECT attendance_code FROM event_attendance_codes WHERE event_id = $1",
        event_id,
    )
    assert attendance_code

    verify_resp = await client.client.post(
        f"/events/{event_id}/verify", json={"code": attendance_code[:8]}
    )
    assert verify_resp.status_code == 200
    assert verify_resp.json() == {"message": "Successfully verified attendance!"}

    row = await kanae.pool.fetchrow(
        "SELECT attended FROM events_members WHERE event_id = $1 AND member_id = $2",
        event_id,
        member_uuid,
    )
    assert row is not None
    assert row["attended"] is True


# ──────────────────────────────────────────────────────────────────
# Thumbnail object surfacing in reads (no S3 needed, seeded directly)
# ──────────────────────────────────────────────────────────────────


async def test_get_event_thumbnail_null_by_default(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    creator_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=creator_id)
    event_id = await _insert_event(kanae.pool, name="no-thumb", creator_id=creator_id)

    response = await client.client.get(f"/events/{event_id}")
    assert response.status_code == 200
    assert response.json()["thumbnail"] is None


async def test_get_event_surfaces_thumbnail_object(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    creator_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=creator_id)
    event_id = await _insert_event(kanae.pool, name="has-thumb", creator_id=creator_id)
    await kanae.pool.execute(
        "UPDATE events SET thumbnail_hash = $2 WHERE id = $1", event_id, _VALID_HASH
    )

    response = await client.client.get(f"/events/{event_id}")
    assert response.status_code == 200
    thumbnail = response.json()["thumbnail"]
    assert thumbnail["hash"] == _VALID_HASH
    assert thumbnail["url"].endswith(f"/thumbnails/{_VALID_HASH}.webp")


async def test_list_events_surfaces_thumbnail_object(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    creator_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=creator_id)
    event_id = await _insert_event(
        kanae.pool, name="listed-thumb", creator_id=creator_id
    )
    await kanae.pool.execute(
        "UPDATE events SET thumbnail_hash = $2 WHERE id = $1", event_id, _VALID_HASH
    )

    response = await client.client.get("/events")
    assert response.status_code == 200
    row = next(r for r in response.json()["data"] if r["id"] == str(event_id))
    assert row["thumbnail"]["hash"] == _VALID_HASH
    assert row["thumbnail"]["url"].endswith(f"/thumbnails/{_VALID_HASH}.webp")


# ──────────────────────────────────────────────────────────────────
# Set thumbnail, requires Event.edit, 3 per minute
# ──────────────────────────────────────────────────────────────────


async def test_set_event_thumbnail_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        f"/events/{uuid.uuid4()}/thumbnail",
        json={"hash": _VALID_HASH, "content_type": "image/png"},
    )
    assert response.status_code == 401


async def test_set_event_thumbnail_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(
        f"/events/{uuid.uuid4()}/thumbnail",
        json={"hash": _VALID_HASH, "content_type": "image/png"},
    )
    assert response.status_code == 403


async def test_set_event_thumbnail_rejects_non_image(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    event_id = uuid.uuid4()
    fake_ory.grant("Event", str(event_id), "edit", identity_id)
    response = await client.client.post(
        f"/events/{event_id}/thumbnail",
        json={"hash": _VALID_HASH, "content_type": "video/mp4"},
    )
    assert response.status_code == 400


async def test_set_event_thumbnail_rejects_bad_hash(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    event_id = uuid.uuid4()
    fake_ory.grant("Event", str(event_id), "edit", identity_id)
    response = await client.client.post(
        f"/events/{event_id}/thumbnail",
        json={"hash": "not-a-valid-hash", "content_type": "image/png"},
    )
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Remove thumbnail, requires Event.edit, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_remove_event_thumbnail_requires_session(
    client: KanaeTestClient,
) -> None:
    response = await client.client.delete(f"/events/{uuid.uuid4()}/thumbnail")
    assert response.status_code == 401


async def test_remove_event_thumbnail_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.delete(f"/events/{uuid.uuid4()}/thumbnail")
    assert response.status_code == 403


async def test_remove_event_thumbnail_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing = uuid.uuid4()
    fake_ory.grant("Event", str(missing), "edit", identity_id)

    response = await client.client.delete(f"/events/{missing}/thumbnail")
    assert response.status_code == 404


async def test_remove_event_thumbnail_succeeds_when_unset(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(
        kanae.pool, name="clear-thumb", creator_id=member_uuid
    )
    fake_ory.grant("Event", str(event_id), "edit", identity_id)

    response = await client.client.delete(f"/events/{event_id}/thumbnail")
    assert response.status_code == 200

    remaining = await kanae.pool.fetchval(
        "SELECT thumbnail_hash FROM events WHERE id = $1", event_id
    )
    assert remaining is None


# ──────────────────────────────────────────────────────────────────
# Rate limits
# ──────────────────────────────────────────────────────────────────


async def test_join_event_enforces_5_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # The limiter is keyed on the request URL by default (`key_style="url"`),
    # so distinct event IDs would bucket separately and never trip the limit.
    # Hammer the same path: first call joins, the next four 409 (already
    # joined) but the limiter still increments, so the 6th call hits 429.
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    event_id = await _insert_event(
        kanae.pool, name="rate-target", creator_id=member_uuid
    )

    with hiro.Timeline().freeze():
        for _ in range(5):
            response = await client.client.post(f"/events/{event_id}/join")
            assert response.status_code in {200, 409}

        blocked = await client.client.post(f"/events/{event_id}/join")
        assert blocked.status_code == 429
