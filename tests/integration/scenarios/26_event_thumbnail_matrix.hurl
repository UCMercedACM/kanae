# Event thumbnail routes (access-control + validation matrix), mirroring the
# project thumbnail coverage in scenario 25 for the routes it doesn't touch:
#
#   POST   /events/{id}/thumbnail
#   DELETE /events/{id}/thumbnail
#
# No new event is created — the 15/min limit on /events/create is consumed by
# scenarios 11/13/14/24. A Keto grant on a dummy UUID
# ("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee") stands in for a real event and lets
# every auth-gated path be reached without a DB row for the event itself.
#
# Dependency chain on /events/{id}/thumbnail is: session check → Keto check
# (has_permissions(Event.edit), using the raw path string as the object id
# BEFORE FastAPI coerces it to uuid.UUID) → body coercion → handler. So:
#   - unauthenticated requests short-circuit to 401
#   - authenticated requests without the Event.edit grant short-circuit to 403
#   - 422 from body coercion is only observable once auth + Keto pass
#
# Both routes use the same Event.edit relation, so a single grant unlocks both.
#
#   auth matrix
#     unauthenticated               → 401   (Phase 2)
#     authenticated, no Keto grant  → 403   (LEADS, Phase 3)
#     authenticated, grant present  → 422 / 400 / 404   (ADMIN, Phase 5+)
#
#   Pydantic 422 paths (Phase 5, behind auth+Keto)
#     thumbnail: missing hash, bad hash pattern, missing content_type
#
#   thumbnail business logic (Phase 6)
#     video content_type            → 400  (store_thumbnail ALLOWED_IMAGE_TYPES miss)
#     image type, hash absent in S3  → 404  (ClientError → NotFoundError; runs
#                                            before the row UPDATE, so the
#                                            missing event row is never reached)
#     DELETE on non-existent row     → 404  (UPDATE returns no rows)
#
# Unlike projects, events have no media-association table, so the POST has no
# project_media-style EXISTS guard — but that branch is unreachable here anyway
# because the S3 fetch 404s first.

# ── Phase 1: Keto grant for ADMIN on the dummy event UUID ────────────────────
# (Keto admin API requires no user session)

PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Event", "object": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "relation": "edit", "subject_id": "{{ADMIN_ID}}" }
HTTP 201
[Asserts]
jsonpath "$.namespace" == "Event"
jsonpath "$.object" == "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
jsonpath "$.relation" == "edit"

# ── Phase 2: Unauthenticated 401 (auth dep fires before any other check) ─────

# Even an obviously-malformed body returns 401 first — the Kratos session
# check short-circuits before Pydantic ever sees the payload.
POST {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
Content-Type: application/json
{ "garbage": true }
HTTP 401

DELETE {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
HTTP 401

# ── Phase 3: LEADS login → 403 on dummy event (no Event.edit grant for LEADS) ─

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

# LEADS has no Keto Event.edit on the dummy UUID → body-valid request still 403.
POST {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg" }
HTTP 403

DELETE {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
HTTP 403

# ── Phase 4: Re-login as ADMIN (holds Event.edit grant on dummy) ─────────────

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

# ── Phase 5: Pydantic 422 paths (ADMIN session + Keto grant in place) ────────

# thumbnail POST: missing hash.
POST {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
Content-Type: application/json
{ "content_type": "image/jpeg" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "hash"

# thumbnail POST: hash too short — _HASH_REGEX mismatch.
POST {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
Content-Type: application/json
{ "hash": "tooshort", "content_type": "image/jpeg" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# thumbnail POST: missing content_type.
POST {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "content_type"

# ── Phase 6: thumbnail business logic (ADMIN + edit grant) ───────────────────

# Video content_type → 400 (store_thumbnail ALLOWED_IMAGE_TYPES check).
POST {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "video/mp4" }
HTTP 400

# Valid image type but hash absent in S3 → fetch_and_process_thumbnail raises
# ClientError → NotFoundError → 404. This fires before the row UPDATE, so the
# dummy event having no DB row is irrelevant here.
POST {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
Content-Type: application/json
{ "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "content_type": "image/jpeg" }
HTTP 404

# DELETE thumbnail on non-existent event row → UPDATE returns no rows → 404.
DELETE {{KANAE_URL}}/events/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee/thumbnail
HTTP 404
