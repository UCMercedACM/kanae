# ruff: noqa: S101

import datetime
import uuid

import hiro
import pytest
from conftest import FakeOryClient, KanaeTestClient

from core import Kanae
from utils.checks import Role

pytestmark = pytest.mark.asyncio(loop_scope="session")


async def _seed_member(kanae: Kanae, member_id: str) -> None:
    await kanae.pool.execute(
        "INSERT INTO members (id, name, display_name, email) "
        "VALUES ($1, 'sudo-test', 'sudo-test', $2) "
        "ON CONFLICT (id) DO NOTHING",
        member_id,
        f"{member_id}@test.local",
    )


# ──────────────────────────────────────────────────────────────────
# GET /sudo — admin-only status
# ──────────────────────────────────────────────────────────────────


async def test_status_requires_session(client: KanaeTestClient) -> None:
    assert (await client.client.get("/sudo")).status_code == 401


async def test_status_rejects_non_admin(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(aal="aal2")
    assert (await client.client.get("/sudo")).status_code == 403


async def test_status_inactive_when_not_elevated(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN, aal="aal2")
    response = await client.client.get("/sudo")
    assert response.status_code == 200
    assert response.json() == {"active": False, "expires_at": None}


# ──────────────────────────────────────────────────────────────────
# POST /sudo/elevate — admin + fresh AAL2, reason mandatory
# ──────────────────────────────────────────────────────────────────


async def test_elevate_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post("/sudo/elevate", json={"reason": "x"})
    assert response.status_code == 401


async def test_elevate_rejects_non_admin(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(aal="aal2")
    response = await client.client.post("/sudo/elevate", json={"reason": "x"})
    assert response.status_code == 403


async def test_elevate_without_2fa_rejected_with_stepup(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN, aal="aal1")
    response = await client.client.post("/sudo/elevate", json={"reason": "x"})
    assert response.status_code == 403
    assert "aal2" in response.headers["X-Elevation-Flow"]


async def test_elevate_with_stale_2fa_rejected(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    stale = datetime.datetime.now(datetime.UTC) - datetime.timedelta(minutes=20)
    fake_ory.login_as(Role.ADMIN, aal="aal2", authenticated_at=stale)
    response = await client.client.post("/sudo/elevate", json={"reason": "x"})
    assert response.status_code == 403
    assert "X-Elevation-Flow" in response.headers


async def test_elevate_fresh_2fa_succeeds(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    admin_id = fake_ory.login_as(Role.ADMIN, aal="aal2")
    await _seed_member(kanae, admin_id)

    response = await client.client.post(
        "/sudo/elevate", json={"reason": "incident #42"}
    )
    assert response.status_code == 200
    body = response.json()
    assert body["active"] is True
    assert body["expires_at"] is not None

    row = await kanae.pool.fetchrow(
        "SELECT reason, expires_at > now() AS active "
        "FROM sudo_grants WHERE member_id = $1",
        admin_id,
    )
    assert row is not None
    assert row["reason"] == "incident #42"
    assert row["active"] is True


async def test_elevate_requires_reason(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN, aal="aal2")
    response = await client.client.post("/sudo/elevate", json={})
    assert response.status_code == 422


async def test_elevate_rejects_empty_reason(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN, aal="aal2")
    response = await client.client.post("/sudo/elevate", json={"reason": ""})
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# DELETE /sudo/revoke + full lifecycle
# ──────────────────────────────────────────────────────────────────


async def test_revoke_requires_session(client: KanaeTestClient) -> None:
    assert (await client.client.delete("/sudo/revoke")).status_code == 401


async def test_revoke_rejects_non_admin(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(aal="aal2")
    assert (await client.client.delete("/sudo/revoke")).status_code == 403


async def test_revoke_idempotent_when_no_grant(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN, aal="aal2")
    assert (await client.client.delete("/sudo/revoke")).status_code == 200


async def test_sudo_lifecycle_elevate_status_revoke(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    admin_id = fake_ory.login_as(Role.ADMIN, aal="aal2")
    await _seed_member(kanae, admin_id)

    assert (
        await client.client.post("/sudo/elevate", json={"reason": "break glass"})
    ).status_code == 200
    assert (await client.client.get("/sudo")).json()["active"] is True

    assert (await client.client.delete("/sudo/revoke")).status_code == 200
    assert (await client.client.get("/sudo")).json()["active"] is False

    remaining = await kanae.pool.fetchval(
        "SELECT count(*) FROM sudo_grants WHERE member_id = $1", admin_id
    )
    assert remaining == 0


# ──────────────────────────────────────────────────────────────────
# GET /sudo/active — root-only oversight of who is currently elevated
# ──────────────────────────────────────────────────────────────────


async def test_active_grants_requires_session(client: KanaeTestClient) -> None:
    assert (await client.client.get("/sudo/active")).status_code == 401


async def test_active_grants_rejects_non_root(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN, aal="aal2")
    assert (await client.client.get("/sudo/active")).status_code == 403


async def test_active_grants_lists_for_root(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    member_id = str(uuid.uuid4())
    await _seed_member(kanae, member_id)
    await kanae.sudo.grant(member_id, reason="break glass")

    fake_ory.login_as(Role.ROOT)
    response = await client.client.get("/sudo/active")
    assert response.status_code == 200

    body = response.json()
    assert any(row["member_id"] == member_id for row in body)
    assert any(row["reason"] == "break glass" for row in body)


# ──────────────────────────────────────────────────────────────────
# SudoClient directly — TTL / expiry / idempotency semantics
# ──────────────────────────────────────────────────────────────────


async def test_sudoclient_grant_then_active(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    member_id = str(uuid.uuid4())
    await _seed_member(kanae, member_id)

    expires_at = await kanae.sudo.grant(member_id, reason="direct")
    assert expires_at is not None
    assert await kanae.sudo.is_active(member_id) is True
    assert await kanae.sudo.get_expiry(member_id) is not None


async def test_sudoclient_revoke_clears(client: KanaeTestClient, kanae: Kanae) -> None:
    member_id = str(uuid.uuid4())
    await _seed_member(kanae, member_id)

    await kanae.sudo.grant(member_id, reason="direct")
    await kanae.sudo.revoke(member_id)
    assert await kanae.sudo.is_active(member_id) is False
    assert await kanae.sudo.get_expiry(member_id) is None


async def test_sudoclient_expired_grant_is_inactive(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    member_id = str(uuid.uuid4())
    await _seed_member(kanae, member_id)
    await kanae.pool.execute(
        "INSERT INTO sudo_grants (member_id, expires_at, reason) "
        "VALUES ($1, now() - interval '1 minute', 'expired')",
        member_id,
    )
    assert await kanae.sudo.is_active(member_id) is False
    assert await kanae.sudo.get_expiry(member_id) is None


# ──────────────────────────────────────────────────────────────────
# Rate limit — POST /sudo/elevate is 5/minute
# ──────────────────────────────────────────────────────────────────


async def test_elevate_enforces_5_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    admin_id = fake_ory.login_as(Role.ADMIN, aal="aal2")
    await _seed_member(kanae, admin_id)
    with hiro.Timeline().freeze():
        for i in range(5):
            response = await client.client.post(
                "/sudo/elevate", json={"reason": f"r{i}"}
            )
            assert response.status_code == 200

        blocked = await client.client.post("/sudo/elevate", json={"reason": "blocked"})
        assert blocked.status_code == 429


# ──────────────────────────────────────────────────────────────────
# Audit trail — grant appends an immutable sudo_audit row
# ──────────────────────────────────────────────────────────────────


async def test_grant_writes_audit_row(client: KanaeTestClient, kanae: Kanae) -> None:
    member_id = str(uuid.uuid4())
    await _seed_member(kanae, member_id)
    await kanae.sudo.grant(member_id, reason="incident-99")

    row = await kanae.pool.fetchrow(
        "SELECT reason, granted_at, expires_at FROM sudo_audit WHERE member_id = $1",
        member_id,
    )
    assert row is not None
    assert row["reason"] == "incident-99"
    assert row["expires_at"] > row["granted_at"]


async def test_reelevate_appends_audit_keeps_one_live_grant(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    member_id = str(uuid.uuid4())
    await _seed_member(kanae, member_id)
    await kanae.sudo.grant(member_id, reason="first")
    await kanae.sudo.grant(member_id, reason="second")

    grant_rows = await kanae.pool.fetch(
        "SELECT reason FROM sudo_grants WHERE member_id = $1", member_id
    )
    assert len(grant_rows) == 1
    assert grant_rows[0]["reason"] == "second"

    reasons = [
        r["reason"]
        for r in await kanae.pool.fetch(
            "SELECT reason FROM sudo_audit WHERE member_id = $1 ORDER BY id", member_id
        )
    ]
    assert reasons == ["first", "second"]


# ──────────────────────────────────────────────────────────────────
# GET /sudo/audit — root-only elevation history
# ──────────────────────────────────────────────────────────────────


async def test_audit_requires_session(client: KanaeTestClient) -> None:
    assert (await client.client.get("/sudo/audit")).status_code == 401


async def test_audit_rejects_non_root(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN, aal="aal2")
    assert (await client.client.get("/sudo/audit")).status_code == 403


async def test_audit_empty_for_root(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ROOT)
    response = await client.client.get("/sudo/audit")
    assert response.status_code == 200
    assert response.json() == []


async def test_audit_lists_history_for_root(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    member_id = str(uuid.uuid4())
    await _seed_member(kanae, member_id)
    await kanae.sudo.grant(member_id, reason="first")
    await kanae.sudo.grant(member_id, reason="second")

    fake_ory.login_as(Role.ROOT)
    response = await client.client.get("/sudo/audit")
    assert response.status_code == 200

    mine = [row for row in response.json() if row["member_id"] == member_id]
    assert len(mine) == 2
    assert {row["reason"] for row in mine} == {"first", "second"}
