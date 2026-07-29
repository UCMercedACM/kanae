# Thumbnail upload/commit flow (access-control + validation matrix) for both
# resources, covering the four routes no prior scenario touches:
#
#   POST /projects/{id}/thumbnail/upload
#   POST /projects/{id}/thumbnail/commit
#   POST /events/{id}/thumbnail/upload
#   POST /events/{id}/thumbnail/commit
#
# Scenarios 25 and 26 cover the *set* form of the thumbnail routes
# (POST /{projects,events}/{id}/thumbnail) plus the media upload/commit pair;
# this file covers the thumbnail-specific staging flow layered on top.
#
# Dummy UUIDs with no DB row stand in for a real project/event, as in 25/26 —
# Keto grants alone let every auth-gated path be reached. That works here
# because neither upload route needs the resource row:
#   - projects: the project_media link is inserted only when the hash already
#     exists in `media`, and none of these hashes do
#   - events: there is no bridge table at all, so `events` is never consulted
#
# Phase ordering follows the same dependency chain as 25/26: session check →
# Keto check (raw path string, before UUID coercion) → Pydantic → handler.
# So 401 short-circuits everything, 403 short-circuits Pydantic, and the 422s
# are only observable as ADMIN holding the grant.
#
# Rate-limit budget — read before adding requests here. The two commit routes
# allow 3/minute each, the two upload routes 10/minute. Per-route limits live
# in KanaeLimiter._route_limits and are only collected with in_middleware=False
# (utils/limiter/extension.py), i.e. from the decorator that wraps the handler.
# So a request only spends budget if it *reaches the handler*: the 401s, 403s
# and 422s below are free, while every 400/413/404/200 costs one. With
# key_style="url" the key is the request path, so each dummy UUID is its own
# bucket and projects/events don't share.
#
#   /projects/cccc…/thumbnail/upload   4 of 10
#   /events/ffff…/thumbnail/upload     5 of 10
#   /projects/cccc…/thumbnail/commit   2 of 3   (Phase 6 ordering + Phase 7 404)
#   /events/ffff…/thumbnail/commit     2 of 3   (Phase 6 ordering + Phase 7 404)
#   /projects/cccc…/media/upload       1 of 10
#
# An earlier revision ran the whole validate_thumbnail matrix against all four
# routes and put the events commit at 4 handler-entering requests, which made
# the Phase 7 404 come back 429.
#
#   auth matrix
#     unauthenticated                   → 401   (Phase 2)
#     authenticated, no Keto grant      → 403   (LEADS, Phase 3)
#     authenticated, grant present      → 422 / 400 / 413 / 200 / 404
#
#   Pydantic 422 paths (Phase 5)
#     missing hash / bad hash pattern / missing content_type / missing size
#     `size` is required on both routes — unlike the set-thumbnail body,
#     which takes only hash + content_type
#
#   validate_thumbnail (Phase 6)
#     video content type                → 400  (NOT 415: thumbnails answer
#                                               with 400 to match
#                                               store_thumbnail, while
#                                               _validate_media answers 415
#                                               for the same input on
#                                               /media/upload — see the
#                                               contrast assertion below)
#     non-media content type            → 400
#     size ≤ 0                          → 400
#     size over 32 MB thumbnail cap     → 413
#
#   storage-dependent paths (Phase 7)
#     upload, hash unknown to `media`   → 200 + presigned PUT url. Presigning
#                                         is local SigV4, so no object need
#                                         exist for this to succeed.
#     commit, object absent from bucket → 404 (head raises ClientError). This
#                                         fires before any DB write, so the
#                                         dummy resource row never matters.

# ── Phase 1: Keto grants for ADMIN on the dummy project and event ────────────
# (Keto admin API requires no user session)

PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Project", "object": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "relation": "edit", "subject_id": "{{ADMIN_ID}}" }
HTTP 201
[Asserts]
jsonpath "$.namespace" == "Project"
jsonpath "$.relation" == "edit"

PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Event", "object": "ffffffff-ffff-4fff-8fff-ffffffffffff", "relation": "edit", "subject_id": "{{ADMIN_ID}}" }
HTTP 201
[Asserts]
jsonpath "$.namespace" == "Event"
jsonpath "$.relation" == "edit"

# ── Phase 2: Unauthenticated 401 on all four routes ──────────────────────────
# A malformed body still returns 401 — the Kratos check short-circuits before
# Pydantic sees the payload.

POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "garbage": true }
HTTP 401

POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/commit
Content-Type: application/json
{ "garbage": true }
HTTP 401

POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/upload
Content-Type: application/json
{ "garbage": true }
HTTP 401

POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/commit
Content-Type: application/json
{ "garbage": true }
HTTP 401

# ── Phase 3: LEADS login → 403 (no grant on either dummy resource) ───────────

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

# Body-valid requests still 403 — the Keto check precedes the handler.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 1024 }
HTTP 403

POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/commit
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 1024 }
HTTP 403

POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 1024 }
HTTP 403

POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/commit
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 1024 }
HTTP 403

# ── Phase 4: Re-login as ADMIN (holds both grants) ───────────────────────────

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

# ── Phase 5: Pydantic 422 paths (ADMIN session + grants in place) ────────────

# upload: missing hash.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "content_type": "image/jpeg", "size": 1024 }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "hash"

# upload: hash too short — _HASH_REGEX mismatch.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "hash": "tooshort", "content_type": "image/jpeg", "size": 1024 }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# upload: missing content_type.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size": 1024 }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "content_type"

# upload: missing size. The set-thumbnail route accepts a body without it;
# these two do not.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "size"

# commit: missing size — same model, same rejection.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/commit
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "size"

# events upload: NUL byte in content_type — _NO_NULL_REGEX mismatch.
POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/\u0000png", "size": 1024 }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# events commit: bad hash pattern.
POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/commit
Content-Type: application/json
{ "hash": "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", "content_type": "image/jpeg", "size": 1024 }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# ── Phase 6: validate_thumbnail (ADMIN + grants) ─────────────────────────────
#
# The guard matrix runs on the *upload* routes. validate_thumbnail is a single
# shared function that all four handlers call identically, so re-asserting
# every case against every route buys no coverage — and it would blow the
# commit routes' 3/minute budget (see the rate-limit note in the header).
# Commit keeps only the case that is specific to it: that validation runs
# before `head`.

# Video content type → 400. Videos are perfectly valid *media*, so this is the
# thumbnail-specific narrowing to the image allow-list.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "video/mp4", "size": 1024 }
HTTP 400

POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "video/mp4", "size": 1024 }
HTTP 400

# Content type outside the media allow-list entirely → still 400 here.
POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "application/pdf", "size": 1024 }
HTTP 400

# The deliberate divergence, asserted side by side: the same unsupported type
# is 415 on the media route (_validate_media) and 400 on the thumbnail route
# (validate_thumbnail, matching store_thumbnail and POST .../thumbnail).
# Both legs run against this scenario's own cccc… grant, so the contrast holds
# without depending on any other scenario's Keto state.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/media/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "application/pdf", "size": 1024 }
HTTP 415

# size ≤ 0 → 400.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 0 }
HTTP 400

POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": -1 }
HTTP 400

# Over the 32 MB thumbnail cap → 413.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 33554433 }
HTTP 413

POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/upload
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg", "size": 33554433 }
HTTP 413

# Content type is checked before size: a non-image that is *also* oversized
# reports 400, not 413. This is the commit-specific half of the matrix —
# without that ordering, `head` would derive a key from the bad content type
# and 404 on the wrong thing. One request per commit route, leaving the second
# of three for the 404 in Phase 7.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/commit
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "video/mp4", "size": 33554433 }
HTTP 400

POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/commit
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "video/mp4", "size": 33554433 }
HTTP 400

# ── Phase 7: storage-dependent paths (ADMIN + grants) ────────────────────────

# upload with a hash absent from `media` → SimpleUploadResponse. Presigning is
# local SigV4 against the configured credentials, so no object has to exist.
# The response carries only `url`; the MediaRecord branch (with hash/kind/size)
# is only taken for a hash already in the table.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/upload
Content-Type: application/json
{ "hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "content_type": "image/jpeg", "size": 1024 }
HTTP 200
[Asserts]
jsonpath "$.url" exists
jsonpath "$.url" matches "^https?://"
jsonpath "$.hash" not exists

# Same on the events side — and this one additionally proves the route never
# consults the `events` row, since ffff… has no DB record at all.
POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/upload
Content-Type: application/json
{ "hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "content_type": "image/jpeg", "size": 1024 }
HTTP 200
[Asserts]
jsonpath "$.url" exists
jsonpath "$.hash" not exists

# commit for an object that was never PUT → head raises ClientError → 404.
# This fires before any DB write, so the missing project row is never reached.
POST {{KANAE_URL}}/projects/cccccccc-cccc-4ccc-8ccc-cccccccccccc/thumbnail/commit
Content-Type: application/json
{ "hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "content_type": "image/jpeg", "size": 1024 }
HTTP 404

POST {{KANAE_URL}}/events/ffffffff-ffff-4fff-8fff-ffffffffffff/thumbnail/commit
Content-Type: application/json
{ "hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "content_type": "image/jpeg", "size": 1024 }
HTTP 404
