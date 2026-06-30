# The error surface of the invite endpoints: body validation, the
# dependency gates, FK/not-found, the closed-policy door, and the
# cross-direction dedup (a pending invite blocks the opposite-direction
# request on the same project+member).
#
# Most cases here are "free": Pydantic 422s and dependency 403s fire
# before the rate-limited handler, so we can be exhaustive without
# burning budget. Handler-reached calls are kept modest:
#   1 create, 3 /invites (2 FK-404 + 1 ok), 3 /requests (dedup 409,
#   closed 409, missing-project 404), 2 join-policy, 1 accept-404,
#   1 revoke-404.
#
# Junk ids used below (inlined, matching the suite's convention):
#   project 77777777-7777-4777-8777-777777777737
#   invite  88888888-8888-4888-8888-888888888838

# --- MANAGER baseline ---
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MANAGER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{
  "name": "scenario38-validation",
  "description": "error surface of the invite endpoints",
  "link": "https://example.test/scenario38",
  "type": "sig_graph",
  "active": true,
  "founded_at": "2024-09-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"

# --- invite body validation (all 422 before the handler/limiter) ---

# Missing member_id.
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "message": "no target" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "member_id"

# Malformed member_id UUID.
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "not-a-uuid" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "uuid_parsing"

# Null byte in message violates the no-NUL pattern.
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}", "message": "bad\u0000byte" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"
jsonpath "$.errors[*].loc[*]" contains "message"

# Message over the 500-char cap.
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}", "message": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }
HTTP 422

# --- not-found / FK (these reach the handler) ---

# Valid project, member id that doesn't exist → FK violation → 404.
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "88888888-8888-4888-8888-888888888838" }
HTTP 404
[Asserts]
jsonpath "$.result" == "error"

# Nonexistent project (Role.MANAGER still satisfies the gate, so the
# handler runs and FK-404s on project_id).
POST {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777737/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}" }
HTTP 404

# Accept / revoke against a row that doesn't exist → 404.
POST {{KANAE_URL}}/projects/{{project_id}}/invites/88888888-8888-4888-8888-888888888838/accept
HTTP 404
[Asserts]
jsonpath "$.detail" contains "does not exist"

DELETE {{KANAE_URL}}/projects/{{project_id}}/invites/88888888-8888-4888-8888-888888888838/revoke
HTTP 404

# --- join-policy validation (free 422s) ---

# Not a member of the enum.
POST {{KANAE_URL}}/projects/{{project_id}}/join-policy
Content-Type: application/json
{ "join_policy": "invite-only" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "literal_error"

# Missing field.
POST {{KANAE_URL}}/projects/{{project_id}}/join-policy
Content-Type: application/json
{}
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "join_policy"

# --- set up the cross-direction dedup: a pending invite for MEMBER ---
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}" }
HTTP 200

POST {{KANAE_URL}}/projects/{{project_id}}/join-policy
Content-Type: application/json
{ "join_policy": "request" }
HTTP 200
[Asserts]
jsonpath "$.join_policy" == "request"

# --- MEMBER: dependency gates are 403 (free), and a request collides
#     with the lead's pending invite on the one-pending index ---
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MEMBER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

# A plain member can't create invites, list them, or set policy — all
# blocked by the dependency before the handler (403, no limiter hit).
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{LEADS_ID}}" }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

GET {{KANAE_URL}}/projects/{{project_id}}/invites
HTTP 403

POST {{KANAE_URL}}/projects/{{project_id}}/join-policy
Content-Type: application/json
{ "join_policy": "open" }
HTTP 403

# MEMBER already has a pending invite from the lead → a request in the
# opposite direction trips the same partial unique index → 409.
POST {{KANAE_URL}}/projects/{{project_id}}/requests
Content-Type: application/json
{}
HTTP 409
[Asserts]
jsonpath "$.detail" contains "pending handshake"

# --- MANAGER closes the project entirely ---
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MANAGER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

POST {{KANAE_URL}}/projects/{{project_id}}/join-policy
Content-Type: application/json
{ "join_policy": "closed" }
HTTP 200
[Asserts]
jsonpath "$.join_policy" == "closed"

# --- ADMIN: an outsider with no pending row hits the closed door, and
#     a request to a missing project 404s ---
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

# Closed projects refuse requests.
POST {{KANAE_URL}}/projects/{{project_id}}/requests
Content-Type: application/json
{}
HTTP 409
[Asserts]
jsonpath "$.detail" contains "not accepting"

# Request against a project that doesn't exist → 404.
POST {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777737/requests
Content-Type: application/json
{}
HTTP 404
[Asserts]
jsonpath "$.detail" contains "does not exist"
