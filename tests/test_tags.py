# ruff: noqa: S101

from typing import Any

import hiro
import pytest
from conftest import FakeOryClient, KanaeTestClient

from core import Kanae
from utils.checks import Role

pytestmark = pytest.mark.asyncio(loop_scope="session")


# ──────────────────────────────────────────────────────────────────
# Listing tags, unauthenticated
# ──────────────────────────────────────────────────────────────────


async def test_list_tags_returns_empty_when_no_rows(client: KanaeTestClient) -> None:
    response = await client.client.get("/tags")
    assert response.status_code == 200
    assert response.json() == []


async def test_list_tags_returns_seeded_rows(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    await kanae.pool.execute(
        "INSERT INTO tags (title, description) VALUES ($1, $2), ($3, $4)",
        "python",
        "the lang",
        "rust",
        "also a lang",
    )
    response = await client.client.get("/tags")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert {row["title"] for row in body} == {"python", "rust"}


async def test_list_tags_rejects_short_title_filter(client: KanaeTestClient) -> None:
    # `title` has Query(min_length=3) — two chars must 422
    response = await client.client.get("/tags?title=py")
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Fetch tag by id, unauthenticated
# ──────────────────────────────────────────────────────────────────


async def test_get_tag_by_id_returns_row(client: KanaeTestClient, kanae: Kanae) -> None:
    tag_id: int = await kanae.pool.fetchval(
        "INSERT INTO tags (title, description) VALUES ($1, $2) RETURNING id",
        "go",
        "a lang",
    )
    response = await client.client.get(f"/tags/{tag_id}")
    assert response.status_code == 200
    assert response.json() == {"id": tag_id, "title": "go", "description": "a lang"}


async def test_get_tag_by_id_returns_404_when_missing(client: KanaeTestClient) -> None:
    response = await client.client.get("/tags/999999")
    assert response.status_code == 404


async def test_get_tag_by_id_rejects_non_integer_id(client: KanaeTestClient) -> None:
    response = await client.client.get("/tags/not-an-int")
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Create tag, admin only, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_create_tag_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        "/tags/create", json={"title": "x", "description": "y"}
    )
    assert response.status_code == 401


async def test_create_tag_rejects_non_admin(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()  # authenticated, no roles granted
    response = await client.client.post(
        "/tags/create", json={"title": "x", "description": "y"}
    )
    assert response.status_code == 403


async def test_create_tag_admin_inserts_row(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ADMIN)
    response = await client.client.post(
        "/tags/create", json={"title": "kanae", "description": "the api"}
    )
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["title"] == "kanae"
    assert body["description"] == "the api"

    row = await kanae.pool.fetchrow(
        "SELECT title, description FROM tags WHERE id = $1", body["id"]
    )
    assert row is not None
    assert row["title"] == "kanae"
    assert row["description"] == "the api"


async def test_create_tag_rejects_missing_description(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    response = await client.client.post("/tags/create", json={"title": "no-desc"})
    assert response.status_code == 422


async def test_create_tag_rejects_wrong_type(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    response = await client.client.post(
        "/tags/create", json={"title": 42, "description": ["not", "a", "string"]}
    )
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# PUT /tags/{tag_id}  — admin only, 5/minute
# ──────────────────────────────────────────────────────────────────


async def test_edit_tag_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.put(
        "/tags/1", json={"title": "x", "description": "y"}
    )
    assert response.status_code == 401


async def test_edit_tag_rejects_non_admin(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.put(
        "/tags/1", json={"title": "x", "description": "y"}
    )
    assert response.status_code == 403


async def test_edit_tag_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    response = await client.client.put(
        "/tags/999999", json={"title": "x", "description": "y"}
    )
    assert response.status_code == 404


async def test_edit_tag_persists_changes(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ADMIN)
    tag_id: int = await kanae.pool.fetchval(
        "INSERT INTO tags (title, description) VALUES ($1, $2) RETURNING id",
        "old-title",
        "old-desc",
    )
    response = await client.client.put(
        f"/tags/{tag_id}",
        json={"title": "new-title", "description": "new-desc"},
    )
    assert response.status_code == 200
    after = await kanae.pool.fetchrow(
        "SELECT title, description FROM tags WHERE id = $1", tag_id
    )
    assert after is not None
    assert after["title"] == "new-title"
    assert after["description"] == "new-desc"


async def test_edit_tag_rejects_invalid_payload(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    response = await client.client.put("/tags/1", json={"title": "only-title"})
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# DELETE /tags/{tag_id}  — admin only, 5/minute
# ──────────────────────────────────────────────────────────────────


async def test_delete_tag_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.delete("/tags/1")
    assert response.status_code == 401


async def test_delete_tag_rejects_non_admin(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.delete("/tags/1")
    assert response.status_code == 403


async def test_delete_tag_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    response = await client.client.delete("/tags/999999")
    assert response.status_code == 404


async def test_delete_tag_removes_row(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ADMIN)
    tag_id: int = await kanae.pool.fetchval(
        "INSERT INTO tags (title, description) VALUES ($1, $2) RETURNING id",
        "trash",
        "to-be-deleted",
    )
    response = await client.client.delete(f"/tags/{tag_id}")
    assert response.status_code == 200

    remaining: int = await kanae.pool.fetchval(
        "SELECT count(*) FROM tags WHERE id = $1", tag_id
    )
    assert remaining == 0


# ──────────────────────────────────────────────────────────────────
# POST /tags/bulk-create  — admin only, 1/minute
# ──────────────────────────────────────────────────────────────────


async def test_bulk_create_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        "/tags/bulk-create",
        json=[{"title": "a", "description": "1"}],
    )
    assert response.status_code == 401


async def test_bulk_create_rejects_non_admin(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(
        "/tags/bulk-create",
        json=[{"title": "a", "description": "1"}],
    )
    assert response.status_code == 403


async def test_bulk_create_inserts_multiple_rows(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.ADMIN)
    payload = [
        {"title": "alpha", "description": "first"},
        {"title": "beta", "description": "second"},
    ]
    response = await client.client.post("/tags/bulk-create", json=payload)
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert {row["title"] for row in body} == {"alpha", "beta"}

    titles = {row["title"] for row in await kanae.pool.fetch("SELECT title FROM tags")}
    assert {"alpha", "beta"}.issubset(titles)


async def test_bulk_create_rejects_non_list_payload(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    response = await client.client.post(
        "/tags/bulk-create",
        json={"title": "a", "description": "1"},
    )
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Rate limits
# ──────────────────────────────────────────────────────────────────


async def test_create_tag_enforces_5_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    with hiro.Timeline().freeze():
        for i in range(5):
            response = await client.client.post(
                "/tags/create",
                json={"title": f"t{i}", "description": "d"},
            )
            assert response.status_code == 200

        blocked = await client.client.post(
            "/tags/create",
            json={"title": "blocked", "description": "d"},
        )
        assert blocked.status_code == 429


async def test_bulk_create_enforces_1_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.ADMIN)
    with hiro.Timeline().freeze():
        first = await client.client.post(
            "/tags/bulk-create",
            json=[{"title": "first", "description": "d"}],
        )
        assert first.status_code == 200

        second = await client.client.post(
            "/tags/bulk-create",
            json=[{"title": "second", "description": "d"}],
        )
        assert second.status_code == 429
