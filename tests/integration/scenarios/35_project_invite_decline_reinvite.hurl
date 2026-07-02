# Flow A again, but the member says no first, then yes — exercises the
# decline terminal state, the partial-unique-index dedup on the live
# pending row, and re-invite after a terminal row:
#   MANAGER invites MEMBER → a second invite while the first is pending
#   409s (one-pending index) → MEMBER declines → project membership
#   unchanged → MANAGER re-invites (allowed: the declined row no longer
#   trips the index) → MEMBER accepts the new one → joined.
#
# Also proves the revoke gate: the target MEMBER is not the initiator,
# so MEMBER revoking the lead's invite is 403.
#
# Budget: 1 create, 3 /invites POST (one is the dedup 409), 1 decline,
# 1 accept.

# --- MANAGER creates + invites ---
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
  "name": "scenario35-decline-reinvite",
  "description": "member declines then accepts a re-invite",
  "link": "https://example.test/scenario35",
  "type": "sig_cyber",
  "active": true,
  "founded_at": "2024-09-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"

POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}" }
HTTP 200
[Captures]
invite1: jsonpath "$.id"
[Asserts]
jsonpath "$.status" == "pending"
jsonpath "$.message" == null

# A second invite for the same (project, member) while pending is
# blocked by project_invites_pending → 409.
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}" }
HTTP 409
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "pending invite already exists"

# --- switch to MEMBER ---
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
[Asserts]
jsonpath "$.session.identity.id" == "{{MEMBER_ID}}"

# The target is neither the initiator nor a lead (no Role.MANAGER /
# Project.edit), so they cannot revoke the lead's invite (403) — a
# distinct gate from decline.
DELETE {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite1}}/revoke
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "cannot revoke"

# MEMBER declines the first invite.
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite1}}/decline
HTTP 200
[Asserts]
jsonpath "$.id" == "{{invite1}}"
jsonpath "$.status" == "declined"

# Declining didn't add a membership row.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 1
jsonpath "$.members[0].id" == "{{MANAGER_ID}}"

# Accepting a declined row is no longer possible → 409.
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite1}}/accept
HTTP 409
[Asserts]
jsonpath "$.detail" contains "already declined"

# --- back to MANAGER to re-invite ---
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

# The declined row is terminal, so it no longer trips the partial
# unique index — a fresh invite is allowed and gets a new id.
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}", "message": "second time's the charm" }
HTTP 200
[Captures]
invite2: jsonpath "$.id"
[Asserts]
jsonpath "$.status" == "pending"
jsonpath "$.id" != "{{invite1}}"

# Lead view now holds both rows: one declined, one pending.
GET {{KANAE_URL}}/projects/{{project_id}}/invites
HTTP 200
[Asserts]
jsonpath "$" count == 2
GET {{KANAE_URL}}/projects/{{project_id}}/invites?status=declined
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{invite1}}"
GET {{KANAE_URL}}/projects/{{project_id}}/invites?status=pending
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{invite2}}"

# --- MEMBER accepts the re-invite ---
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

POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite2}}/accept
HTTP 200
[Asserts]
jsonpath "$.status" == "accepted"

GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 2
body contains "{{MEMBER_ID}}"
