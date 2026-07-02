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


async def _insert_member(
    pool: asyncpg.Pool,
    *,
    member_id: uuid.UUID | str,
    name: str = "Member",
    email: str = "member@test.local",
) -> None:
    await pool.execute(
        """
        INSERT INTO members (id, name, display_name, email)
        VALUES ($1, $2, $3, $4)
        """,
        member_id,
        name,
        name,
        email,
    )


async def _insert_project(
    pool: asyncpg.Pool,
    *,
    name: str = "Project",
    description: str = "desc",
    link: str = "https://example.test",
    project_type: str = "independent",
    active: bool = True,
    founded_at: datetime.datetime | None = None,
) -> uuid.UUID:
    if founded_at is None:
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
    return await pool.fetchval(
        """
        INSERT INTO projects (name, description, link, type, active, founded_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id
        """,
        name,
        description,
        link,
        project_type,
        active,
        founded_at,
    )


async def _link_project_member(
    pool: asyncpg.Pool,
    *,
    project_id: uuid.UUID,
    member_id: uuid.UUID | str,
    role: str = "member",
) -> None:
    await pool.execute(
        """
        INSERT INTO project_members (project_id, member_id, role)
        VALUES ($1, $2, $3)
        """,
        project_id,
        member_id,
        role,
    )


async def _insert_tag(
    pool: asyncpg.Pool,
    *,
    title: str,
    description: str = "desc",
) -> int:
    return await pool.fetchval(
        "INSERT INTO tags (title, description) VALUES ($1, $2) RETURNING id",
        title,
        description,
    )


async def _link_project_tag(
    pool: asyncpg.Pool,
    *,
    project_id: uuid.UUID,
    tag_id: int,
) -> None:
    await pool.execute(
        "INSERT INTO project_tags (project_id, tag_id) VALUES ($1, $2)",
        project_id,
        tag_id,
    )


async def _project_tag_titles(pool: asyncpg.Pool, project_id: uuid.UUID) -> set[str]:
    rows = await pool.fetch(
        """
        SELECT tags.title
        FROM project_tags
        JOIN tags ON tags.id = project_tags.tag_id
        WHERE project_tags.project_id = $1
        """,
        project_id,
    )
    return {row["title"] for row in rows}


def _create_payload(
    *,
    name: str = "New Project",
    description: str = "from-test",
    link: str = "https://example.test",
    project_type: str = "independent",
    tags: list[str] | None = None,
    active: bool = True,
) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "link": link,
        "type": project_type,
        "tags": tags,
        "active": active,
        "founded_at": datetime.datetime(2025, 1, 1, tzinfo=datetime.UTC).isoformat(),
    }


# ──────────────────────────────────────────────────────────────────
# Listing projects, unauthenticated
# ──────────────────────────────────────────────────────────────────


async def test_list_projects_returns_empty_page(client: KanaeTestClient) -> None:
    response = await client.client.get("/projects")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["data"] == []
    assert body["total"] == 0


async def test_list_projects_returns_seeded_rows(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    member_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=member_id)
    project_a = await _insert_project(kanae.pool, name="alpha")
    project_b = await _insert_project(kanae.pool, name="beta")
    await _link_project_member(
        kanae.pool, project_id=project_a, member_id=member_id, role="lead"
    )
    await _link_project_member(
        kanae.pool, project_id=project_b, member_id=member_id, role="member"
    )

    response = await client.client.get("/projects")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["total"] == 2
    assert {row["name"] for row in body["data"]} == {"alpha", "beta"}


async def test_list_projects_rejects_short_name_filter(client: KanaeTestClient) -> None:
    response = await client.client.get("/projects?name=hi")
    assert response.status_code == 422


async def test_list_projects_rejects_both_since_and_until(
    client: KanaeTestClient,
) -> None:
    since = datetime.datetime(2024, 1, 1, tzinfo=datetime.UTC).isoformat()
    until = datetime.datetime(2026, 1, 1, tzinfo=datetime.UTC).isoformat()
    response = await client.client.get(
        "/projects",
        params={"since": since, "until": until},
    )
    assert response.status_code == 400


async def test_list_projects_filters_by_active(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    member_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=member_id)
    active_project = await _insert_project(kanae.pool, name="active-one", active=True)
    archived_project = await _insert_project(
        kanae.pool, name="archived-one", active=False
    )
    await _link_project_member(
        kanae.pool, project_id=active_project, member_id=member_id, role="lead"
    )
    await _link_project_member(
        kanae.pool, project_id=archived_project, member_id=member_id, role="lead"
    )

    response = await client.client.get("/projects?active=false")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert {row["name"] for row in body["data"]} == {"archived-one"}


# ──────────────────────────────────────────────────────────────────
# Fetch project by id, unauthenticated
# ──────────────────────────────────────────────────────────────────


async def test_get_project_returns_404_when_missing(client: KanaeTestClient) -> None:
    response = await client.client.get(f"/projects/{uuid.uuid4()}")
    assert response.status_code == 404


async def test_get_project_returns_row(client: KanaeTestClient, kanae: Kanae) -> None:
    member_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=member_id)
    project_id = await _insert_project(kanae.pool, name="solo")
    await _link_project_member(
        kanae.pool, project_id=project_id, member_id=member_id, role="lead"
    )

    response = await client.client.get(f"/projects/{project_id}")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["id"] == str(project_id)
    assert body["name"] == "solo"
    assert {m["id"] for m in body["members"]} == {str(member_id)}


async def test_get_project_rejects_non_uuid(client: KanaeTestClient) -> None:
    response = await client.client.get("/projects/not-a-uuid")
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Edit project, requires Project.edit, 3 per minute
# ──────────────────────────────────────────────────────────────────


async def test_edit_project_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.put(
        f"/projects/{uuid.uuid4()}",
        json={"name": "x", "description": "y", "link": "https://x.test"},
    )
    assert response.status_code == 401


async def test_edit_project_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.put(
        f"/projects/{uuid.uuid4()}",
        json={"name": "x", "description": "y", "link": "https://x.test"},
    )
    assert response.status_code == 403


async def test_edit_project_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing = uuid.uuid4()
    await fake_ory.grant("Project", str(missing), "edit", identity_id)
    response = await client.client.put(
        f"/projects/{missing}",
        json={"name": "x", "description": "y", "link": "https://x.test"},
    )
    assert response.status_code == 404


async def test_edit_project_persists_changes(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="old-name")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.put(
        f"/projects/{project_id}",
        json={
            "name": "new-name",
            "description": "new-desc",
            "link": "https://new.test",
        },
    )
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["name"] == "new-name"
    assert body["description"] == "new-desc"
    assert body["link"] == "https://new.test"


# ──────────────────────────────────────────────────────────────────
# Delete project, requires Project.own, 3 per minute
# ──────────────────────────────────────────────────────────────────


async def test_delete_project_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.delete(f"/projects/{uuid.uuid4()}")
    assert response.status_code == 401


async def test_delete_project_rejects_without_own_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.delete(f"/projects/{uuid.uuid4()}")
    assert response.status_code == 403


async def test_delete_project_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing = uuid.uuid4()
    await fake_ory.grant("Project", str(missing), "own", identity_id)
    response = await client.client.delete(f"/projects/{missing}")
    assert response.status_code == 404


async def test_delete_project_removes_row(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="doomed")
    await fake_ory.grant("Project", str(project_id), "own", identity_id)

    response = await client.client.delete(f"/projects/{project_id}")
    assert response.status_code == 200

    remaining: int = await kanae.pool.fetchval(
        "SELECT count(*) FROM projects WHERE id = $1", project_id
    )
    assert remaining == 0


# ──────────────────────────────────────────────────────────────────
# Archive project, requires Project.own, 3 per minute
# ──────────────────────────────────────────────────────────────────


async def test_archive_project_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.put(
        f"/projects/{uuid.uuid4()}/archive", json={"active": False}
    )
    assert response.status_code == 401


async def test_archive_project_rejects_without_own_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.put(
        f"/projects/{uuid.uuid4()}/archive", json={"active": False}
    )
    assert response.status_code == 403


async def test_archive_project_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing = uuid.uuid4()
    await fake_ory.grant("Project", str(missing), "own", identity_id)
    response = await client.client.put(
        f"/projects/{missing}/archive", json={"active": False}
    )
    assert response.status_code == 404


async def test_archive_project_toggles_active_flag(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="toggle-me", active=True)
    await fake_ory.grant("Project", str(project_id), "own", identity_id)

    archived = await client.client.put(
        f"/projects/{project_id}/archive", json={"active": False}
    )
    assert archived.status_code == 200
    assert archived.json()["active"] is False
    assert (
        await kanae.pool.fetchval(
            "SELECT active FROM projects WHERE id = $1", project_id
        )
        is False
    )

    restored = await client.client.put(
        f"/projects/{project_id}/archive", json={"active": True}
    )
    assert restored.status_code == 200
    assert restored.json()["active"] is True


async def test_archive_project_rejects_invalid_payload(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    project_id = uuid.uuid4()
    await fake_ory.grant("Project", str(project_id), "own", identity_id)
    response = await client.client.put(
        f"/projects/{project_id}/archive", json={"active": "not-a-bool"}
    )
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Tag surfacing on reads
# ──────────────────────────────────────────────────────────────────


async def test_get_project_surfaces_tags(client: KanaeTestClient, kanae: Kanae) -> None:
    member_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=member_id)
    project_id = await _insert_project(kanae.pool, name="with-tags")
    await _link_project_member(
        kanae.pool, project_id=project_id, member_id=member_id, role="lead"
    )
    for title in ("rust", "python"):
        tag_id = await _insert_tag(kanae.pool, title=title)
        await _link_project_tag(kanae.pool, project_id=project_id, tag_id=tag_id)

    response = await client.client.get(f"/projects/{project_id}")
    assert response.status_code == 200
    # array_agg(... ORDER BY tags.title) → alphabetical
    assert response.json()["tags"] == ["python", "rust"]


async def test_get_project_without_tags_returns_null(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    member_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=member_id)
    project_id = await _insert_project(kanae.pool, name="untagged")
    await _link_project_member(
        kanae.pool, project_id=project_id, member_id=member_id, role="lead"
    )
    response = await client.client.get(f"/projects/{project_id}")
    assert response.status_code == 200
    assert response.json()["tags"] is None


async def test_list_projects_surfaces_tags(
    client: KanaeTestClient, kanae: Kanae
) -> None:
    member_id = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=member_id)
    project_id = await _insert_project(kanae.pool, name="listed-tags")
    await _link_project_member(
        kanae.pool, project_id=project_id, member_id=member_id, role="lead"
    )
    tag_id = await _insert_tag(kanae.pool, title="golang")
    await _link_project_tag(kanae.pool, project_id=project_id, tag_id=tag_id)

    response = await client.client.get("/projects")
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    row = next(r for r in body["data"] if r["name"] == "listed-tags")
    assert row["tags"] == ["golang"]


# ──────────────────────────────────────────────────────────────────
# Overwrite project tags, requires Project.edit, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_overwrite_tags_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.put(
        f"/projects/{uuid.uuid4()}/tags", json={"tags": ["python"]}
    )
    assert response.status_code == 401


async def test_overwrite_tags_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.put(
        f"/projects/{uuid.uuid4()}/tags", json={"tags": ["python"]}
    )
    assert response.status_code == 403


async def test_overwrite_tags_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing = uuid.uuid4()
    await fake_ory.grant("Project", str(missing), "edit", identity_id)
    response = await client.client.put(f"/projects/{missing}/tags", json={"tags": []})
    assert response.status_code == 404


async def test_overwrite_tags_replaces_existing_set(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="tagged")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    old_tag = await _insert_tag(kanae.pool, title="old")
    await _link_project_tag(kanae.pool, project_id=project_id, tag_id=old_tag)
    await _insert_tag(kanae.pool, title="python")
    await _insert_tag(kanae.pool, title="rust")

    response = await client.client.put(
        f"/projects/{project_id}/tags", json={"tags": ["python", "rust"]}
    )
    assert response.status_code == 200
    assert sorted(response.json()["tags"]) == ["python", "rust"]
    assert await _project_tag_titles(kanae.pool, project_id) == {"python", "rust"}


async def test_overwrite_tags_empty_list_clears_all(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="to-empty")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    tag_id = await _insert_tag(kanae.pool, title="solo")
    await _link_project_tag(kanae.pool, project_id=project_id, tag_id=tag_id)

    response = await client.client.put(
        f"/projects/{project_id}/tags", json={"tags": []}
    )
    assert response.status_code == 200
    assert response.json()["tags"] == []
    assert await _project_tag_titles(kanae.pool, project_id) == set()


async def test_overwrite_tags_partial_removal_keeps_survivors(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="partial")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    for title in ("ai", "swe", "cyber"):
        tag_id = await _insert_tag(kanae.pool, title=title)
        await _link_project_tag(kanae.pool, project_id=project_id, tag_id=tag_id)

    # Drop "cyber" by sending only the survivors.
    response = await client.client.put(
        f"/projects/{project_id}/tags", json={"tags": ["ai", "swe"]}
    )
    assert response.status_code == 200
    assert await _project_tag_titles(kanae.pool, project_id) == {"ai", "swe"}


async def test_overwrite_tags_response_dedupes_and_reflects_db(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # Case-variant duplicates all lower-case to one tag; the response echoes the
    # resulting DB state (deduped, sorted), not the raw request list.
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="tag-dedup")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    await _insert_tag(kanae.pool, title="python")

    response = await client.client.put(
        f"/projects/{project_id}/tags", json={"tags": ["python", "Python", "python"]}
    )
    assert response.status_code == 200
    assert response.json()["tags"] == ["python"]


async def test_overwrite_tags_unknown_tag_rolls_back(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="rollback")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    keep = await _insert_tag(kanae.pool, title="keep")
    await _link_project_tag(kanae.pool, project_id=project_id, tag_id=keep)

    response = await client.client.put(
        f"/projects/{project_id}/tags", json={"tags": ["nonexistent"]}
    )
    assert response.status_code == 422
    # Transaction rolled back — the pre-existing tag (and its clearing) survives.
    assert await _project_tag_titles(kanae.pool, project_id) == {"keep"}


# ──────────────────────────────────────────────────────────────────
# Clear project tags, requires Project.edit, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_clear_tags_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.delete(f"/projects/{uuid.uuid4()}/tags")
    assert response.status_code == 401


async def test_clear_tags_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.delete(f"/projects/{uuid.uuid4()}/tags")
    assert response.status_code == 403


async def test_clear_tags_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing = uuid.uuid4()
    await fake_ory.grant("Project", str(missing), "edit", identity_id)
    response = await client.client.delete(f"/projects/{missing}/tags")
    assert response.status_code == 404


async def test_clear_tags_removes_all(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="clearable")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    for title in ("a", "b"):
        tag_id = await _insert_tag(kanae.pool, title=title)
        await _link_project_tag(kanae.pool, project_id=project_id, tag_id=tag_id)

    response = await client.client.delete(f"/projects/{project_id}/tags")
    assert response.status_code == 200
    assert await _project_tag_titles(kanae.pool, project_id) == set()


# ──────────────────────────────────────────────────────────────────
# Create project, manager role required, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_create_project_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post("/projects/create", json=_create_payload())
    assert response.status_code == 401


async def test_create_project_rejects_non_manager(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.LEADS)
    response = await client.client.post("/projects/create", json=_create_payload())
    assert response.status_code == 403


async def test_create_project_persists_row_and_creator_link(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as(Role.MANAGER)
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    payload = _create_payload(name="freshly-created")
    response = await client.client.post("/projects/create", json=payload)
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["name"] == "freshly-created"

    membership = await kanae.pool.fetchrow(
        "SELECT role FROM project_members WHERE project_id = $1 AND member_id = $2",
        uuid.UUID(body["id"]),
        uuid.UUID(identity_id),
    )
    assert membership is not None
    assert membership["role"] == "lead"


async def test_create_project_with_unknown_tag_rolls_back(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as(Role.MANAGER)
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    payload = _create_payload(name="tagged-bad", tags=["nonexistent-tag"])
    response = await client.client.post("/projects/create", json=payload)
    assert response.status_code == 422

    count: int = await kanae.pool.fetchval(
        "SELECT count(*) FROM projects WHERE name = $1", "tagged-bad"
    )
    assert count == 0


async def test_create_project_rejects_invalid_type(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.MANAGER)
    payload = _create_payload()
    payload["type"] = "not-a-valid-type"
    response = await client.client.post("/projects/create", json=payload)
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Join project, requires session, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_join_project_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(f"/projects/{uuid.uuid4()}/join")
    assert response.status_code == 401


async def test_join_project_inserts_membership(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="joinable")

    response = await client.client.post(f"/projects/{project_id}/join")
    assert response.status_code == 200

    role: str = await kanae.pool.fetchval(
        "SELECT role FROM project_members WHERE project_id = $1 AND member_id = $2",
        project_id,
        member_uuid,
    )
    assert role == "member"


async def test_join_project_returns_409_on_duplicate(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="single-join")

    first = await client.client.post(f"/projects/{project_id}/join")
    assert first.status_code == 200
    second = await client.client.post(f"/projects/{project_id}/join")
    assert second.status_code == 409


# ──────────────────────────────────────────────────────────────────
# Bulk join project, manager OR Project.own, 1 per minute
# ──────────────────────────────────────────────────────────────────


async def test_bulk_join_project_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/bulk-join",
        json=[{"id": str(uuid.uuid4())}],
    )
    assert response.status_code == 401


async def test_bulk_join_project_rejects_without_role_or_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/bulk-join",
        json=[{"id": str(uuid.uuid4())}],
    )
    assert response.status_code == 403


async def test_bulk_join_project_rejects_more_than_ten_members(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as(Role.MANAGER)
    payload = [{"id": str(uuid.uuid4())} for _ in range(11)]
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/bulk-join", json=payload
    )
    assert response.status_code == 400


async def test_bulk_join_project_inserts_all_members(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.MANAGER)
    project_id = await _insert_project(kanae.pool, name="bulk-target")

    member_ids = [uuid.uuid4() for _ in range(3)]
    for member_id in member_ids:
        await _insert_member(kanae.pool, member_id=member_id)

    response = await client.client.post(
        f"/projects/{project_id}/bulk-join",
        json=[{"id": str(mid)} for mid in member_ids],
    )
    assert response.status_code == 200

    inserted: list[Any] = await kanae.pool.fetch(
        "SELECT member_id FROM project_members WHERE project_id = $1",
        project_id,
    )
    assert {row["member_id"] for row in inserted} == set(member_ids)


# ──────────────────────────────────────────────────────────────────
# Leave project, requires session, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_leave_project_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.delete(f"/projects/{uuid.uuid4()}/leave")
    assert response.status_code == 401


async def test_leave_project_returns_404_when_not_member(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.delete(f"/projects/{uuid.uuid4()}/leave")
    assert response.status_code == 404


async def test_leave_project_removes_membership(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="leavable")
    await _link_project_member(kanae.pool, project_id=project_id, member_id=member_uuid)

    response = await client.client.delete(f"/projects/{project_id}/leave")
    assert response.status_code == 200

    remaining: int = await kanae.pool.fetchval(
        "SELECT count(*) FROM project_members WHERE project_id = $1 AND member_id = $2",
        project_id,
        member_uuid,
    )
    assert remaining == 0


# ──────────────────────────────────────────────────────────────────
# Modify member role, undocumented, Project.own + manager, 3 per minute
# ──────────────────────────────────────────────────────────────────


async def test_modify_member_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.put(
        f"/projects/{uuid.uuid4()}/member/modify",
        json={"id": str(uuid.uuid4()), "role": "lead"},
    )
    assert response.status_code == 401


async def test_modify_member_rejects_without_manager_role(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    target_project = uuid.uuid4()
    await fake_ory.grant("Project", str(target_project), "own", identity_id)
    response = await client.client.put(
        f"/projects/{target_project}/member/modify",
        json={"id": str(uuid.uuid4()), "role": "lead"},
    )
    assert response.status_code == 403


async def test_modify_member_promotes_existing_membership(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as(Role.MANAGER)
    member_to_promote = uuid.uuid4()
    project_id = await _insert_project(kanae.pool, name="promotable")
    await fake_ory.grant("Project", str(project_id), "own", identity_id)

    await _insert_member(kanae.pool, member_id=member_to_promote)
    await _link_project_member(
        kanae.pool,
        project_id=project_id,
        member_id=member_to_promote,
        role="member",
    )

    response = await client.client.put(
        f"/projects/{project_id}/member/modify",
        json={"id": str(member_to_promote), "role": "lead"},
    )
    assert response.status_code == 200

    role: str = await kanae.pool.fetchval(
        "SELECT role FROM project_members WHERE project_id = $1 AND member_id = $2",
        project_id,
        member_to_promote,
    )
    assert role == "lead"


async def test_modify_member_rejects_invalid_role_value(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as(Role.MANAGER)
    project_id = await _insert_project(kanae.pool, name="role-validator")
    await fake_ory.grant("Project", str(project_id), "own", identity_id)

    response = await client.client.put(
        f"/projects/{project_id}/member/modify",
        json={"id": str(uuid.uuid4()), "role": "manager"},  # not in {former, lead}
    )
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Media upload and commit, auth + edit permission
# ──────────────────────────────────────────────────────────────────

_VALID_HASH = "a" * 64  # 64 hex chars to match the route pattern


async def test_media_upload_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/media/upload",
        json={"hash": _VALID_HASH, "content_type": "image/png", "size": 1024},
    )
    assert response.status_code == 401


async def test_media_upload_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/media/upload",
        json={"hash": _VALID_HASH, "content_type": "image/png", "size": 1024},
    )
    assert response.status_code == 403


async def test_media_upload_rejects_unknown_content_type(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    project_id = uuid.uuid4()
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.post(
        f"/projects/{project_id}/media/upload",
        json={
            "hash": _VALID_HASH,
            "content_type": "application/x-cursed",
            "size": 1024,
        },
    )
    assert response.status_code == 415


async def test_media_upload_rejects_zero_size(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    project_id = uuid.uuid4()
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.post(
        f"/projects/{project_id}/media/upload",
        json={"hash": _VALID_HASH, "content_type": "image/png", "size": 0},
    )
    assert response.status_code == 400


async def test_media_upload_rejects_oversized_image(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    project_id = uuid.uuid4()
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    too_big = 32 * 1024 * 1024 + 1  # 32 MB image cap + 1 byte
    response = await client.client.post(
        f"/projects/{project_id}/media/upload",
        json={"hash": _VALID_HASH, "content_type": "image/png", "size": too_big},
    )
    assert response.status_code == 413


async def test_media_upload_rejects_bad_hash(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    project_id = uuid.uuid4()
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.post(
        f"/projects/{project_id}/media/upload",
        json={"hash": "not-hex-64", "content_type": "image/png", "size": 1024},
    )
    assert response.status_code == 422


async def test_media_commit_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/media/commit",
        json={"hash": _VALID_HASH, "content_type": "image/png", "size": 1024},
    )
    assert response.status_code == 403


async def test_media_commit_rejects_partial_multipart_args(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    project_id = uuid.uuid4()
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.post(
        f"/projects/{project_id}/media/commit",
        json={
            "hash": _VALID_HASH,
            "content_type": "image/png",
            "size": 1024,
            "upload_id": "abc",
        },
    )
    assert response.status_code == 400


# ──────────────────────────────────────────────────────────────────
# Thumbnail, auth + edit permission
# ──────────────────────────────────────────────────────────────────


async def test_set_thumbnail_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/thumbnail",
        json={"hash": _VALID_HASH, "content_type": "image/png"},
    )
    assert response.status_code == 401


async def test_set_thumbnail_rejects_non_image(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    project_id = uuid.uuid4()
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    response = await client.client.post(
        f"/projects/{project_id}/thumbnail",
        json={"hash": _VALID_HASH, "content_type": "video/mp4"},
    )
    assert response.status_code == 400


async def test_remove_thumbnail_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing = uuid.uuid4()
    await fake_ory.grant("Project", str(missing), "edit", identity_id)

    response = await client.client.delete(f"/projects/{missing}/thumbnail")
    assert response.status_code == 404


# ──────────────────────────────────────────────────────────────────
# Listing project media, requires Project.view, 60 per minute
# ──────────────────────────────────────────────────────────────────


async def test_list_project_media_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.get(f"/projects/{uuid.uuid4()}/media")
    assert response.status_code == 401


async def test_list_project_media_rejects_without_view_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.get(f"/projects/{uuid.uuid4()}/media")
    assert response.status_code == 403


async def test_list_project_media_returns_empty_when_unlinked(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="no-media")
    await fake_ory.grant("Project", str(project_id), "view", identity_id)

    response = await client.client.get(f"/projects/{project_id}/media")
    assert response.status_code == 200
    assert response.json() == []


# ──────────────────────────────────────────────────────────────────
# Reorder media, requires Project.edit, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_reorder_media_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.put(
        f"/projects/{uuid.uuid4()}/media/positions",
        json={"hashes": [_VALID_HASH]},
    )
    assert response.status_code == 401


async def test_reorder_media_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.put(
        f"/projects/{uuid.uuid4()}/media/positions",
        json={"hashes": [_VALID_HASH]},
    )
    assert response.status_code == 403


async def test_reorder_media_returns_404_when_hashes_do_not_belong(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="reorderable")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.put(
        f"/projects/{project_id}/media/positions",
        json={"hashes": [_VALID_HASH]},
    )
    assert response.status_code == 404


async def test_reorder_media_rejects_invalid_hash_format(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    project_id = uuid.uuid4()
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.put(
        f"/projects/{project_id}/media/positions",
        json={"hashes": ["not-a-hash"]},
    )
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Remove project media, requires Project.edit, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_remove_project_media_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.delete(
        f"/projects/{uuid.uuid4()}/media/{_VALID_HASH}"
    )
    assert response.status_code == 401


async def test_remove_project_media_rejects_without_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.delete(
        f"/projects/{uuid.uuid4()}/media/{_VALID_HASH}"
    )
    assert response.status_code == 403


async def test_remove_project_media_returns_404_when_unlinked(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="empty-media")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.delete(f"/projects/{project_id}/media/{_VALID_HASH}")
    assert response.status_code == 404


# ──────────────────────────────────────────────────────────────────
# Rate limits
# ──────────────────────────────────────────────────────────────────


async def test_create_project_enforces_15_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as(Role.MANAGER)
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))

    with hiro.Timeline().freeze():
        for i in range(15):
            response = await client.client.post(
                "/projects/create", json=_create_payload(name=f"rl-{i}")
            )
            assert response.status_code == 200

        blocked = await client.client.post(
            "/projects/create", json=_create_payload(name="blocked")
        )
        assert blocked.status_code == 429


async def test_bulk_join_enforces_1_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.MANAGER)
    project_id = await _insert_project(kanae.pool, name="bulk-rate")

    first = await client.client.post(f"/projects/{project_id}/bulk-join", json=[])
    assert first.status_code in {200, 400}

    second = await client.client.post(f"/projects/{project_id}/bulk-join", json=[])
    assert second.status_code == 429


# ══════════════════════════════════════════════════════════════════
# Project invite system
# ══════════════════════════════════════════════════════════════════


async def _set_join_policy(
    pool: asyncpg.Pool, *, project_id: uuid.UUID, policy: str
) -> None:
    await pool.execute(
        "UPDATE projects SET join_policy = $2 WHERE id = $1", project_id, policy
    )


async def _insert_invite(
    pool: asyncpg.Pool,
    *,
    project_id: uuid.UUID,
    member_id: uuid.UUID | str,
    kind: str,
    invited_by: uuid.UUID | str | None = None,
    status: str = "pending",
    message: str | None = None,
    expires_at: datetime.datetime | None = None,
) -> uuid.UUID:
    return await pool.fetchval(
        """
        INSERT INTO project_invites
            (project_id, member_id, invited_by, kind, status, message, expires_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id
        """,
        project_id,
        member_id,
        invited_by,
        kind,
        status,
        message,
        expires_at,
    )


async def _invite_status(pool: asyncpg.Pool, invite_id: uuid.UUID) -> str | None:
    return await pool.fetchval(
        "SELECT status FROM project_invites WHERE id = $1", invite_id
    )


async def _membership_role(
    pool: asyncpg.Pool, *, project_id: uuid.UUID, member_id: uuid.UUID | str
) -> str | None:
    return await pool.fetchval(
        "SELECT role FROM project_members WHERE project_id = $1 AND member_id = $2",
        project_id,
        member_id,
    )


def _past() -> datetime.datetime:
    return datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=1)


# ──────────────────────────────────────────────────────────────────
# Set join policy, manager OR Project.edit, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_set_join_policy_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/join-policy", json={"join_policy": "request"}
    )
    assert response.status_code == 401


async def test_set_join_policy_rejects_without_role_or_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/join-policy", json={"join_policy": "request"}
    )
    assert response.status_code == 403


async def test_set_join_policy_returns_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    identity_id = fake_ory.login_as()
    missing = uuid.uuid4()
    await fake_ory.grant("Project", str(missing), "edit", identity_id)
    response = await client.client.post(
        f"/projects/{missing}/join-policy", json={"join_policy": "request"}
    )
    assert response.status_code == 404


async def test_set_join_policy_persists_with_edit_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="policy-edit")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.post(
        f"/projects/{project_id}/join-policy", json={"join_policy": "closed"}
    )
    assert response.status_code == 200
    assert response.json()["join_policy"] == "closed"
    assert (
        await kanae.pool.fetchval(
            "SELECT join_policy FROM projects WHERE id = $1", project_id
        )
        == "closed"
    )


async def test_set_join_policy_persists_with_manager_role(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.MANAGER)
    project_id = await _insert_project(kanae.pool, name="policy-manager")

    response = await client.client.post(
        f"/projects/{project_id}/join-policy", json={"join_policy": "request"}
    )
    assert response.status_code == 200
    assert response.json()["join_policy"] == "request"


async def test_set_join_policy_rejects_invalid_value(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.MANAGER)
    project_id = await _insert_project(kanae.pool, name="policy-bad")
    response = await client.client.post(
        f"/projects/{project_id}/join-policy", json={"join_policy": "whenever"}
    )
    assert response.status_code == 422


async def test_join_rejected_once_policy_not_open(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="gated")
    await _set_join_policy(kanae.pool, project_id=project_id, policy="request")

    response = await client.client.post(f"/projects/{project_id}/join")
    assert response.status_code == 409


# ──────────────────────────────────────────────────────────────────
# Create invite (lead invites member), manager OR Project.edit, 5/min
# ──────────────────────────────────────────────────────────────────


async def test_create_invite_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/invites", json={"member_id": str(uuid.uuid4())}
    )
    assert response.status_code == 401


async def test_create_invite_rejects_without_role_or_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/invites", json={"member_id": str(uuid.uuid4())}
    )
    assert response.status_code == 403


async def test_create_invite_persists_pending_row(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    # the initiator is recorded as `invited_by`, which references members(id)
    await _insert_member(
        kanae.pool, member_id=uuid.UUID(identity_id), email="lead@test.local"
    )
    project_id = await _insert_project(kanae.pool, name="inviting")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target, name="Invitee")

    response = await client.client.post(
        f"/projects/{project_id}/invites",
        json={"member_id": str(target), "message": "join us"},
    )
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["kind"] == "invite"
    assert body["status"] == "pending"
    assert body["member"]["id"] == str(target)
    assert body["invited_by"] == identity_id
    assert body["message"] == "join us"
    assert body["expires_at"] is not None

    row = await kanae.pool.fetchrow(
        "SELECT kind, status, invited_by FROM project_invites WHERE id = $1",
        uuid.UUID(body["id"]),
    )
    assert row["kind"] == "invite"
    assert row["status"] == "pending"
    assert row["invited_by"] == uuid.UUID(identity_id)


async def test_create_invite_works_for_manager_role(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as(Role.MANAGER)
    await _insert_member(
        kanae.pool, member_id=uuid.UUID(identity_id), email="lead@test.local"
    )
    project_id = await _insert_project(kanae.pool, name="manager-invite")
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)

    response = await client.client.post(
        f"/projects/{project_id}/invites", json={"member_id": str(target)}
    )
    assert response.status_code == 200


async def test_create_invite_409_when_already_member(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="already-in")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    await _link_project_member(
        kanae.pool, project_id=project_id, member_id=target, role="member"
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites", json={"member_id": str(target)}
    )
    assert response.status_code == 409


async def test_create_invite_409_when_pending_already_exists(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="dup-invite")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    await _insert_invite(
        kanae.pool, project_id=project_id, member_id=target, kind="invite"
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites", json={"member_id": str(target)}
    )
    assert response.status_code == 409


async def test_create_invite_409_when_pending_request_exists(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # A lead invites someone who already has a pending request in the opposite
    # direction: the message should point them at accepting the request.
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="cross-invite")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        invited_by=target,
        kind="request",
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites", json={"member_id": str(target)}
    )
    assert response.status_code == 409
    assert "request" in response.json()["detail"].lower()


async def test_create_invite_404_when_member_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="no-such-member")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    response = await client.client.post(
        f"/projects/{project_id}/invites", json={"member_id": str(uuid.uuid4())}
    )
    assert response.status_code == 404


async def test_create_invite_allowed_after_decline(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # terminal rows do not trip the one-pending partial unique index
    identity_id = fake_ory.login_as()
    await _insert_member(
        kanae.pool, member_id=uuid.UUID(identity_id), email="lead@test.local"
    )
    project_id = await _insert_project(kanae.pool, name="reinvite")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        kind="invite",
        status="declined",
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites", json={"member_id": str(target)}
    )
    assert response.status_code == 200


async def test_create_invite_rejects_overlong_message(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="msg-cap")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)

    response = await client.client.post(
        f"/projects/{project_id}/invites",
        json={"member_id": str(target), "message": "x" * 501},
    )
    assert response.status_code == 422


async def test_create_invite_rejects_missing_member_id(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.MANAGER)
    project_id = await _insert_project(kanae.pool, name="no-body")
    response = await client.client.post(f"/projects/{project_id}/invites", json={})
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Create request (member asks to join), auth only, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_create_request_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(f"/projects/{uuid.uuid4()}/requests", json={})
    assert response.status_code == 401


async def test_create_request_404_when_project_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.post(f"/projects/{uuid.uuid4()}/requests", json={})
    assert response.status_code == 404


async def test_create_request_persists_pending_row(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="requestable")
    await _set_join_policy(kanae.pool, project_id=project_id, policy="request")

    response = await client.client.post(
        f"/projects/{project_id}/requests", json={"message": "please"}
    )
    assert response.status_code == 200
    body: dict[str, Any] = response.json()
    assert body["kind"] == "request"
    assert body["status"] == "pending"
    assert body["member"]["id"] == identity_id
    assert body["invited_by"] == identity_id


async def test_create_request_sets_expiry(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # Requests expire like invites, so a stale one doesn't hold the pending slot
    # forever (the partial-unique (project, member) constraint).
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="request-expiry")
    await _set_join_policy(kanae.pool, project_id=project_id, policy="request")

    response = await client.client.post(f"/projects/{project_id}/requests", json={})
    assert response.status_code == 200
    assert response.json()["expires_at"] is not None

    expires_at = await kanae.pool.fetchval(
        "SELECT expires_at FROM project_invites"
        " WHERE project_id = $1 AND member_id = $2",
        project_id,
        member_uuid,
    )
    assert expires_at is not None


async def test_create_request_409_when_already_member(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="member-already")
    await _set_join_policy(kanae.pool, project_id=project_id, policy="request")
    await _link_project_member(
        kanae.pool, project_id=project_id, member_id=member_uuid, role="member"
    )

    response = await client.client.post(f"/projects/{project_id}/requests", json={})
    assert response.status_code == 409


async def test_create_request_409_when_open(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))
    project_id = await _insert_project(kanae.pool, name="open-proj")  # default open

    response = await client.client.post(f"/projects/{project_id}/requests", json={})
    assert response.status_code == 409


async def test_create_request_409_when_closed(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))
    project_id = await _insert_project(kanae.pool, name="closed-proj")
    await _set_join_policy(kanae.pool, project_id=project_id, policy="closed")

    response = await client.client.post(f"/projects/{project_id}/requests", json={})
    assert response.status_code == 409


async def test_create_request_409_on_duplicate_pending(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="dup-request")
    await _set_join_policy(kanae.pool, project_id=project_id, policy="request")
    await _insert_invite(
        kanae.pool, project_id=project_id, member_id=member_uuid, kind="request"
    )

    response = await client.client.post(f"/projects/{project_id}/requests", json={})
    assert response.status_code == 409


async def test_create_request_409_when_pending_invite_exists(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # The member already has a pending invite in the opposite direction: the
    # message should point them at accepting the invite.
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="cross-request")
    await _set_join_policy(kanae.pool, project_id=project_id, policy="request")
    await _insert_invite(
        kanae.pool, project_id=project_id, member_id=member_uuid, kind="invite"
    )

    response = await client.client.post(f"/projects/{project_id}/requests", json={})
    assert response.status_code == 409
    assert "invite" in response.json()["detail"].lower()


async def test_create_request_sweeps_stale_then_allows(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    member_uuid = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=member_uuid)
    project_id = await _insert_project(kanae.pool, name="stale-request")
    await _set_join_policy(kanae.pool, project_id=project_id, policy="request")
    stale = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=member_uuid,
        kind="request",
        expires_at=_past(),
    )

    response = await client.client.post(f"/projects/{project_id}/requests", json={})
    assert response.status_code == 200
    # the expired row was swept rather than blocking the fresh handshake
    assert await _invite_status(kanae.pool, stale) == "expired"


async def test_create_request_rejects_overlong_message(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(kanae.pool, member_id=uuid.UUID(identity_id))
    project_id = await _insert_project(kanae.pool, name="req-msg-cap")
    await _set_join_policy(kanae.pool, project_id=project_id, policy="request")

    response = await client.client.post(
        f"/projects/{project_id}/requests", json={"message": "x" * 501}
    )
    assert response.status_code == 422


# ──────────────────────────────────────────────────────────────────
# Accept invite, auth + row-resolved symmetry gate, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_accept_invite_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/invites/{uuid.uuid4()}/accept"
    )
    assert response.status_code == 401


async def test_accept_invite_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="accept-missing")
    response = await client.client.post(
        f"/projects/{project_id}/invites/{uuid.uuid4()}/accept"
    )
    assert response.status_code == 404


async def test_accept_invite_target_member_joins(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    target = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="accept-invite")
    invite_id = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=target, kind="invite"
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/accept"
    )
    assert response.status_code == 200
    assert response.json()["status"] == "accepted"
    assert await _invite_status(kanae.pool, invite_id) == "accepted"
    assert (
        await _membership_role(kanae.pool, project_id=project_id, member_id=target)
        == "member"
    )


async def test_accept_invite_rejects_non_target(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as()  # some other authenticated member
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="accept-wrong")
    invite_id = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=target, kind="invite"
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/accept"
    )
    assert response.status_code == 403
    # the speculative UPDATE/insert were rolled back
    assert await _invite_status(kanae.pool, invite_id) == "pending"
    assert (
        await _membership_role(kanae.pool, project_id=project_id, member_id=target)
        is None
    )


async def test_accept_request_lead_via_edit_approves(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="approve-edit")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    requester = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=requester)
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=requester,
        invited_by=requester,
        kind="request",
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/accept"
    )
    assert response.status_code == 200
    assert await _invite_status(kanae.pool, invite_id) == "accepted"
    assert (
        await _membership_role(kanae.pool, project_id=project_id, member_id=requester)
        == "member"
    )


async def test_accept_request_lead_via_manager_approves(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.MANAGER)
    project_id = await _insert_project(kanae.pool, name="approve-manager")
    requester = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=requester)
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=requester,
        invited_by=requester,
        kind="request",
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/accept"
    )
    assert response.status_code == 200


async def test_accept_request_rejects_non_lead(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as()  # plain member, no role/permission
    project_id = await _insert_project(kanae.pool, name="approve-denied")
    requester = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=requester)
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=requester,
        invited_by=requester,
        kind="request",
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/accept"
    )
    assert response.status_code == 403
    assert await _invite_status(kanae.pool, invite_id) == "pending"
    assert (
        await _membership_role(kanae.pool, project_id=project_id, member_id=requester)
        is None
    )


async def test_accept_invite_409_when_already_terminal(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    target = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="accept-terminal")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        kind="invite",
        status="declined",
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/accept"
    )
    assert response.status_code == 409


async def test_accept_invite_409_when_expired(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    target = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="accept-expired")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        kind="invite",
        expires_at=_past(),
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/accept"
    )
    assert response.status_code == 409
    # The expired invite is persisted as 'expired', not left masked as 'pending'.
    assert await _invite_status(kanae.pool, invite_id) == "expired"
    assert (
        await _membership_role(kanae.pool, project_id=project_id, member_id=target)
        is None
    )


async def test_accept_invite_idempotent_when_already_member(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # a race where the target joined after the invite was created still resolves
    identity_id = fake_ory.login_as()
    target = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="accept-idem")
    await _link_project_member(
        kanae.pool, project_id=project_id, member_id=target, role="member"
    )
    invite_id = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=target, kind="invite"
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/accept"
    )
    assert response.status_code == 200
    assert await _invite_status(kanae.pool, invite_id) == "accepted"


async def test_accept_invite_isolated_by_project(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # an invite id is only actionable under its own project path
    identity_id = fake_ory.login_as()
    target = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="real-proj")
    other_project = await _insert_project(kanae.pool, name="other-proj")
    invite_id = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=target, kind="invite"
    )

    response = await client.client.post(
        f"/projects/{other_project}/invites/{invite_id}/accept"
    )
    assert response.status_code == 404
    assert await _invite_status(kanae.pool, invite_id) == "pending"


# ──────────────────────────────────────────────────────────────────
# Decline invite, auth + row-resolved symmetry gate, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_decline_invite_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.post(
        f"/projects/{uuid.uuid4()}/invites/{uuid.uuid4()}/decline"
    )
    assert response.status_code == 401


async def test_decline_invite_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="decline-missing")
    response = await client.client.post(
        f"/projects/{project_id}/invites/{uuid.uuid4()}/decline"
    )
    assert response.status_code == 404


async def test_decline_invite_target_member_declines(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    target = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="decline-invite")
    invite_id = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=target, kind="invite"
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/decline"
    )
    assert response.status_code == 200
    assert response.json()["status"] == "declined"
    assert await _invite_status(kanae.pool, invite_id) == "declined"
    # declining never creates a membership
    assert (
        await _membership_role(kanae.pool, project_id=project_id, member_id=target)
        is None
    )


async def test_decline_request_lead_denies(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="deny-request")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    requester = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=requester)
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=requester,
        invited_by=requester,
        kind="request",
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/decline"
    )
    assert response.status_code == 200
    assert await _invite_status(kanae.pool, invite_id) == "declined"


async def test_decline_invite_rejects_non_target(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as()
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="decline-wrong")
    invite_id = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=target, kind="invite"
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/decline"
    )
    assert response.status_code == 403
    assert await _invite_status(kanae.pool, invite_id) == "pending"


async def test_decline_request_rejects_non_lead(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="deny-denied")
    requester = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=requester)
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=requester,
        invited_by=requester,
        kind="request",
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/decline"
    )
    assert response.status_code == 403


async def test_decline_invite_409_when_terminal(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    target = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="decline-terminal")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        kind="invite",
        status="accepted",
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/decline"
    )
    assert response.status_code == 409


async def test_decline_invite_409_when_expired(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    target = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="decline-expired")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        kind="invite",
        expires_at=_past(),
    )

    response = await client.client.post(
        f"/projects/{project_id}/invites/{invite_id}/decline"
    )
    assert response.status_code == 409
    # The expired invite is persisted as 'expired', not left masked as 'pending'.
    assert await _invite_status(kanae.pool, invite_id) == "expired"


# ──────────────────────────────────────────────────────────────────
# Revoke invite, initiator-only, 5 per minute
# ──────────────────────────────────────────────────────────────────


async def test_revoke_invite_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.delete(
        f"/projects/{uuid.uuid4()}/invites/{uuid.uuid4()}/revoke"
    )
    assert response.status_code == 401


async def test_revoke_invite_404_when_missing(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="revoke-missing")
    response = await client.client.delete(
        f"/projects/{project_id}/invites/{uuid.uuid4()}/revoke"
    )
    assert response.status_code == 404


async def test_revoke_invite_initiator_lead_succeeds(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    lead = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=lead)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="revoke-invite")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        invited_by=lead,
        kind="invite",
    )

    response = await client.client.delete(
        f"/projects/{project_id}/invites/{invite_id}/revoke"
    )
    assert response.status_code == 200
    assert response.json()["status"] == "revoked"
    assert await _invite_status(kanae.pool, invite_id) == "revoked"


async def test_revoke_request_initiator_member_succeeds(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    requester = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=requester)
    project_id = await _insert_project(kanae.pool, name="revoke-request")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=requester,
        invited_by=requester,
        kind="request",
    )

    response = await client.client.delete(
        f"/projects/{project_id}/invites/{invite_id}/revoke"
    )
    assert response.status_code == 200
    assert await _invite_status(kanae.pool, invite_id) == "revoked"


async def test_revoke_invite_rejects_non_initiator(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as()  # not the initiator
    lead = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=lead)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="revoke-wrong")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        invited_by=lead,
        kind="invite",
    )

    response = await client.client.delete(
        f"/projects/{project_id}/invites/{invite_id}/revoke"
    )
    assert response.status_code == 403
    assert await _invite_status(kanae.pool, invite_id) == "pending"


async def test_revoke_invite_via_project_edit_succeeds(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # A co-lead holding Project.edit can revoke an invite they didn't initiate.
    identity_id = fake_ory.login_as()
    co_lead = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=co_lead)
    initiator = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=initiator)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="revoke-colead")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        invited_by=initiator,
        kind="invite",
    )

    response = await client.client.delete(
        f"/projects/{project_id}/invites/{invite_id}/revoke"
    )
    assert response.status_code == 200
    assert await _invite_status(kanae.pool, invite_id) == "revoked"


async def test_revoke_orphaned_invite_via_project_edit_succeeds(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # invited_by is NULL (the initiator's account was deleted); an edit holder
    # can still clean up the dangling pending invite.
    identity_id = fake_ory.login_as()
    lead = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=lead)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="revoke-orphaned")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        invited_by=None,
        kind="invite",
    )

    response = await client.client.delete(
        f"/projects/{project_id}/invites/{invite_id}/revoke"
    )
    assert response.status_code == 200
    assert await _invite_status(kanae.pool, invite_id) == "revoked"


async def test_revoke_request_rejects_project_edit_holder(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    # A lead rejects a join *request* by declining it, not revoking it; only the
    # requesting member can revoke their own request.
    identity_id = fake_ory.login_as()
    lead = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=lead)
    requester = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=requester)
    project_id = await _insert_project(kanae.pool, name="revoke-req-lead")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=requester,
        invited_by=requester,
        kind="request",
    )

    response = await client.client.delete(
        f"/projects/{project_id}/invites/{invite_id}/revoke"
    )
    assert response.status_code == 403
    assert await _invite_status(kanae.pool, invite_id) == "pending"


async def test_revoke_invite_409_when_terminal(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    lead = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=lead)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="revoke-terminal")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        invited_by=lead,
        kind="invite",
        status="revoked",
    )

    response = await client.client.delete(
        f"/projects/{project_id}/invites/{invite_id}/revoke"
    )
    assert response.status_code == 409


async def test_revoke_invite_409_when_expired(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    lead = uuid.UUID(identity_id)
    await _insert_member(kanae.pool, member_id=lead)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    project_id = await _insert_project(kanae.pool, name="revoke-expired")
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        invited_by=lead,
        kind="invite",
        expires_at=_past(),
    )

    response = await client.client.delete(
        f"/projects/{project_id}/invites/{invite_id}/revoke"
    )
    assert response.status_code == 409
    # The expired invite is persisted as 'expired', not left masked as 'pending'.
    assert await _invite_status(kanae.pool, invite_id) == "expired"


# ──────────────────────────────────────────────────────────────────
# List project invites (lead view), manager OR Project.edit, 10/min
# ──────────────────────────────────────────────────────────────────


async def test_list_project_invites_requires_session(client: KanaeTestClient) -> None:
    response = await client.client.get(f"/projects/{uuid.uuid4()}/invites")
    assert response.status_code == 401


async def test_list_project_invites_rejects_without_role_or_permission(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    response = await client.client.get(f"/projects/{uuid.uuid4()}/invites")
    assert response.status_code == 403


async def test_list_project_invites_returns_rows(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="list-invites")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    first = uuid.uuid4()
    second = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=first)
    await _insert_member(kanae.pool, member_id=second)
    invite_a = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=first, kind="invite"
    )
    invite_b = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=second, kind="request"
    )

    response = await client.client.get(f"/projects/{project_id}/invites")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert {row["id"] for row in body} == {str(invite_a), str(invite_b)}


async def test_list_project_invites_filters_by_status(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="filter-status")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    pending_member = uuid.uuid4()
    declined_member = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=pending_member)
    await _insert_member(kanae.pool, member_id=declined_member)
    pending = await _insert_invite(
        kanae.pool, project_id=project_id, member_id=pending_member, kind="invite"
    )
    await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=declined_member,
        kind="invite",
        status="declined",
    )

    response = await client.client.get(
        f"/projects/{project_id}/invites", params={"status": "pending"}
    )
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert [row["id"] for row in body] == [str(pending)]


async def test_list_project_invites_filters_by_kind(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="filter-kind")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    invited = uuid.uuid4()
    requested = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=invited)
    await _insert_member(kanae.pool, member_id=requested)
    await _insert_invite(
        kanae.pool, project_id=project_id, member_id=invited, kind="invite"
    )
    request_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=requested,
        invited_by=requested,
        kind="request",
    )

    response = await client.client.get(
        f"/projects/{project_id}/invites", params={"kind": "request"}
    )
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    assert [row["id"] for row in body] == [str(request_id)]


async def test_list_project_invites_lazily_marks_expired(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="lazy-expire")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    target = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=target)
    invite_id = await _insert_invite(
        kanae.pool,
        project_id=project_id,
        member_id=target,
        kind="invite",
        expires_at=_past(),
    )

    response = await client.client.get(f"/projects/{project_id}/invites")
    assert response.status_code == 200
    body: list[dict[str, Any]] = response.json()
    row = next(r for r in body if r["id"] == str(invite_id))
    # surfaced as expired even though the stored row is still pending
    assert row["status"] == "expired"
    assert await _invite_status(kanae.pool, invite_id) == "pending"


async def test_list_project_invites_isolated_by_project(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="mine")
    other = await _insert_project(kanae.pool, name="theirs")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)
    member = uuid.uuid4()
    await _insert_member(kanae.pool, member_id=member)
    await _insert_invite(kanae.pool, project_id=other, member_id=member, kind="invite")

    response = await client.client.get(f"/projects/{project_id}/invites")
    assert response.status_code == 200
    assert response.json() == []


# ──────────────────────────────────────────────────────────────────
# Invite-system rate limits
# ──────────────────────────────────────────────────────────────────


async def test_set_join_policy_enforces_5_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as(Role.MANAGER)
    project_id = await _insert_project(kanae.pool, name="policy-rate")

    with hiro.Timeline().freeze():
        for _ in range(5):
            response = await client.client.post(
                f"/projects/{project_id}/join-policy", json={"join_policy": "request"}
            )
            assert response.status_code == 200

        blocked = await client.client.post(
            f"/projects/{project_id}/join-policy", json={"join_policy": "open"}
        )
        assert blocked.status_code == 429


async def test_create_invite_enforces_5_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    await _insert_member(
        kanae.pool, member_id=uuid.UUID(identity_id), email="lead@test.local"
    )
    project_id = await _insert_project(kanae.pool, name="invite-rate")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    with hiro.Timeline().freeze():
        for _ in range(5):
            target = uuid.uuid4()
            await _insert_member(kanae.pool, member_id=target)
            response = await client.client.post(
                f"/projects/{project_id}/invites", json={"member_id": str(target)}
            )
            assert response.status_code == 200

        blocked = await client.client.post(
            f"/projects/{project_id}/invites", json={"member_id": str(uuid.uuid4())}
        )
        assert blocked.status_code == 429


async def test_create_request_enforces_5_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    fake_ory.login_as()  # authenticated; missing project yields 404 but still counts
    # the limiter buckets per-URL, so every hit must reuse the same path
    project_id = uuid.uuid4()
    with hiro.Timeline().freeze():
        for _ in range(5):
            response = await client.client.post(
                f"/projects/{project_id}/requests", json={}
            )
            assert response.status_code == 404

        blocked = await client.client.post(f"/projects/{project_id}/requests", json={})
        assert blocked.status_code == 429


async def test_accept_invite_enforces_5_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient
) -> None:
    fake_ory.login_as()
    # the limiter buckets per-URL, so every hit must reuse the same path
    project_id = uuid.uuid4()
    invite_id = uuid.uuid4()
    with hiro.Timeline().freeze():
        for _ in range(5):
            response = await client.client.post(
                f"/projects/{project_id}/invites/{invite_id}/accept"
            )
            assert response.status_code == 404

        blocked = await client.client.post(
            f"/projects/{project_id}/invites/{invite_id}/accept"
        )
        assert blocked.status_code == 429


async def test_list_project_invites_enforces_10_per_minute(
    client: KanaeTestClient, fake_ory: FakeOryClient, kanae: Kanae
) -> None:
    identity_id = fake_ory.login_as()
    project_id = await _insert_project(kanae.pool, name="list-rate")
    await fake_ory.grant("Project", str(project_id), "edit", identity_id)

    with hiro.Timeline().freeze():
        for _ in range(10):
            response = await client.client.get(f"/projects/{project_id}/invites")
            assert response.status_code == 200

        blocked = await client.client.get(f"/projects/{project_id}/invites")
        assert blocked.status_code == 429
