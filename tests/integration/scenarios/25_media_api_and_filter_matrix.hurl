# Project media API (access-control + validation matrix) and query-parameter
# edge cases for /projects and /events.
#
# Exercises routes no prior scenario directly touches:
#   GET    /projects/{id}/media
#   POST   /projects/{id}/media/upload
#   POST   /projects/{id}/media/commit
#   PUT    /projects/{id}/media/positions
#   DELETE /projects/{id}/media/{hash}
#   POST   /projects/{id}/thumbnail
#   DELETE /projects/{id}/thumbnail
#
# No new project is created — the 5/min limit on /projects/create is
# consumed by scenarios 15/17/18/19/23. Keto grants on a dummy UUID
# ("dddddddd-dddd-4ddd-8ddd-dddddddddddd") stand in for a real project
# and let every auth-gated path be reached without a DB row for the
# project itself.
#
# Phase ordering matters. The dependency chain on every /projects/{id}/*
# route is: session check → Keto check (using the raw path string as the
# object id, BEFORE FastAPI coerces it to uuid.UUID) → path/body coercion
# → handler. Consequences:
#   - unauthenticated requests short-circuit to 401
#   - authenticated requests without the Keto grant for *this exact
#     project_id string* short-circuit to 403, even if the string isn't
#     a valid UUID
#   - 422 from body/path coercion is only observable once both auth and
#     Keto pass — so all the Pydantic 422 assertions below run as ADMIN
#     against the dummy UUID that ADMIN holds Project.{view,edit} on
#   - path-param-malformed 422 on these routes is therefore *not*
#     reachable (Keto fails first on the bogus string); scenario 23
#     covers that 422 path via bulk-join, whose role-based check is
#     project-id-agnostic and lets coercion fire
#
#   auth matrix
#     unauthenticated               → 401   (Phase 3)
#     authenticated, no Keto grant  → 403   (LEADS, Phase 4)
#     authenticated, grant present  → 422 / 200 / 400 / 404 / 413 / 415
#                                     (ADMIN, Phase 6+)
#
#   Pydantic 422 paths (Phase 6, behind auth+Keto)
#     path:      malformed UUID
#     upload:    missing hash, bad hash pattern, missing content_type, missing size
#     commit:    missing hash
#     thumbnail: bad hash pattern, NUL byte in content_type
#     positions: hash in list doesn't match pattern, missing hashes field
#     DELETE media: path-param hash doesn't match pattern
#
#   _validate_media (Phase 7)
#     unsupported content type      → 415
#     size ≤ 0                      → 400
#     size over image cap (32 MB+1) → 413
#
#   commit XOR guard (Phase 8)
#     upload_id without chunks      → 400  (after _validate_media passes)
#
#   thumbnail (Phase 9)
#     video content_type            → 400  (_ALLOWED_IMAGE_TYPES miss)
#     image type, hash absent in S3 → 404  (ClientError → NotFoundError)
#     DELETE on non-existent row    → 404
#
#   positions / remove edge cases (Phase 10)
#     non-existent hash             → 404  (updated count ≠ requested count)
#     empty hashes list             → 200  (0 updated == 0 requested — no error)
#
#   /projects + /events public query-parameter matrix (Phase 2 — no auth):
#     name < min_length=3           → 422
#     since + until together        → 400  (/projects only)
#     since not a datetime          → 422  (/projects only)
#     active=false                  → 200  (/projects only)
#     name=<high-entropy nomatch>   → 200, total 0 (filter applied, DB-state-independent)
#     name=<...> + since/until      → 200, shape only / total 0 (/projects only)

# ── Phase 1: Keto grants for ADMIN on the dummy project UUID ─────────────────
# (Keto admin API requires no user session)

PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Project", "object": "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "relation": "view", "subject_id": "{{ADMIN_ID}}" }
HTTP 201

PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Project", "object": "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "relation": "edit", "subject_id": "{{ADMIN_ID}}" }
HTTP 201

# ── Phase 2: Public route query-parameter matrix (no auth) ───────────────────
# /projects and /events have no auth dependency, so Pydantic Query/Body
# validation fires immediately and 422s can be observed without a session.

# /projects: name shorter than min_length=3 → 422.
GET {{KANAE_URL}}/projects?name=sc
HTTP 422

# /projects: since + until together → 400 (mutually-exclusive guard).
GET {{KANAE_URL}}/projects?since=2024-01-01T00:00:00Z&until=2025-01-01T00:00:00Z
HTTP 400

# /projects: unparsable since → 422 from datetime coercion.
GET {{KANAE_URL}}/projects?since=not-a-datetime
HTTP 422

# /projects: active=false — valid filter; may return empty list.
GET {{KANAE_URL}}/projects?active=false
HTTP 200
[Asserts]
jsonpath "$.data" isCollection

# /projects: pg_trgm name search — well-formed term with no DB matches.
# A high-entropy string that no other scenario uses guarantees total==0
# regardless of what state earlier scenarios left behind, so this verifies
# the filter is *applied* without coupling to cross-scenario fixtures.
GET {{KANAE_URL}}/projects?name=zzz_nomatch_xyz_abc
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" == 0

# /projects: name + since combination is accepted (shape only — we don't
# care which rows match, only that the compound filter doesn't 422/400).
GET {{KANAE_URL}}/projects?name=zzz_nomatch_xyz_abc&since=2023-01-01T00:00:00Z
HTTP 200
[Asserts]
jsonpath "$.data" isCollection

# /projects: any name + until in the distant past → similarity matches all
# get windowed out by founded_at filter, so total==0 holds for any DB state.
GET {{KANAE_URL}}/projects?name=zzz_nomatch_xyz_abc&until=1970-01-01T00:00:00Z
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" == 0

# /events: name shorter than min_length=3 → 422.
GET {{KANAE_URL}}/events?name=sc
HTTP 422

# /events: pg_trgm name search — same self-contained pattern as /projects.
GET {{KANAE_URL}}/events?name=zzz_nomatch_xyz_abc
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" == 0

# ── Phase 3: Unauthenticated 401 (auth dep fires before any other check) ─────

GET {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media
HTTP 401

DELETE {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/thumbnail
HTTP 401

# Even an obviously-malformed body returns 401 first — the Kratos session
# check short-circuits before Pydantic ever sees the payload.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/upload
Content-Type: application/json
{ "garbage": true }
HTTP 401

# ── Phase 4: LEADS login → 403 on dummy project (no Keto grant for LEADS) ────

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{LEADS_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{LEADS_ID}}"

# LEADS has no Keto Project.view on the dummy UUID → 403.
GET {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media
HTTP 403

# LEADS has no Keto Project.edit either → body-valid upload still 403.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 1024 }
HTTP 403

# ── Phase 5: Re-login as ADMIN (holds view + edit Keto grants on dummy) ──────

GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ADMIN_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{ADMIN_ID}}"

# ── Phase 6: Pydantic 422 paths (ADMIN session + Keto grants in place) ───────
# Each call has valid auth + Keto, so Pydantic body/path validation is the
# first thing that can fail.

# Path-param malformed UUID — has_permissions(Project.view) reads the raw
# path string as the Keto object id BEFORE FastAPI coerces it to uuid.UUID.
# ADMIN holds Project:dddddddd-…/view but not Project:not-a-uuid/view, so
# Keto answers "no" and the dependency returns 403 — the path-coercion 422
# is never reached. (Routes that bypass Keto via has_role — bulk-join,
# tested in scenario 23 — *do* surface path 422 because the role check is
# project-id-agnostic.)
GET {{KANAE_URL}}/projects/not-a-uuid/media
HTTP 403

# upload: missing hash.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/upload
Content-Type: application/json
{ "content_type": "image/jpeg", "size": 1024 }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "hash"

# upload: hash contains non-hex chars → _HASH_REGEX mismatch.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/upload
Content-Type: application/json
{ "hash": "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg", "content_type": "image/jpeg", "size": 1024 }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# upload: missing content_type.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size": 1024 }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "content_type"

# upload: missing size.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "size"

# commit: missing hash.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/commit
Content-Type: application/json
{ "content_type": "image/jpeg", "size": 1024 }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "hash"

# thumbnail POST: hash too short — _HASH_REGEX mismatch.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/thumbnail
Content-Type: application/json
{ "hash": "tooshort", "content_type": "image/jpeg" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# positions: hash in list doesn't match _HASH_REGEX.
PUT {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/positions
Content-Type: application/json
{ "hashes": ["not-a-hash"] }
HTTP 422

# positions: missing hashes field entirely.
PUT {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/positions
Content-Type: application/json
{}
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "hashes"

# DELETE media: path-param hash doesn't match _HASH_REGEX.
DELETE {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/not-a-hash
HTTP 422

# ── Phase 7: Media listing (ADMIN + view grant → 200 empty array) ────────────
# The dummy UUID has no project row in the DB so the JOIN returns zero rows.

GET {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media
HTTP 200
[Asserts]
jsonpath "$" isCollection
jsonpath "$" count == 0

# ── Phase 8: _validate_media errors (auth + Keto + valid Pydantic) ───────────

# Unsupported content type → 415 Unsupported Media Type.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "audio/mpeg", "size": 1024 }
HTTP 415

# size = 0 → 400 "Size must be positive".
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 0 }
HTTP 400

# size = 32 MB + 1 byte (33554433) → over _MAX_IMAGE_SIZE → 413.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 33554433 }
HTTP 413

# ── Phase 9: commit XOR guard (upload_id provided without chunks → 400) ──────
# _validate_media runs first (and passes), then the XOR check fires.

POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/commit
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 1024, "upload_id": "orphan-upload-id" }
HTTP 400

# ── Phase 10: thumbnail operations (ADMIN + edit grant) ──────────────────────

# Video content_type → 400 (_ALLOWED_IMAGE_TYPES check, not _validate_media).
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/thumbnail
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "video/mp4" }
HTTP 400

# Valid image type but hash absent in S3 → fetch_and_process_thumbnail raises
# ClientError → NotFoundError → 404.
POST {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/thumbnail
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg" }
HTTP 404

# DELETE thumbnail on non-existent project row → UPDATE returns no rows → 404.
DELETE {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/thumbnail
HTTP 404

# ── Phase 11: media remove + positions on non-existent resources ─────────────

# DELETE media — valid hash format but not in DB → DELETE returns 0 rows → 404.
DELETE {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HTTP 404

# Reorder: hash is valid but not in project_media → updated count (0) ≠
# requested count (1) → 404.
PUT {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/positions
Content-Type: application/json
{ "hashes": ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] }
HTTP 404

# Reorder: empty list → 0 updated == 0 requested → SuccessResponse → 200.
# This edge-case is the only reorder path that succeeds without real media.
PUT {{KANAE_URL}}/projects/dddddddd-dddd-4ddd-8ddd-dddddddddddd/media/positions
Content-Type: application/json
{ "hashes": [] }
HTTP 200
[Asserts]
jsonpath "$.message" isString
