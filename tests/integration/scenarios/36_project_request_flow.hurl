# Flow B (member requests to join), gated by join_policy:
#   MANAGER creates a project (open) → a MEMBER request is rejected
#   while open ("use /join") → MANAGER flips join_policy to 'request' →
#   MEMBER requests (kind=request, member_id = invited_by = the member)
#   → a duplicate request 409s (one-pending index) → the request is in
#   MEMBER's outbox and the lead's listing → MANAGER accepts it (the
#   request-side gate is satisfied by Role.MANAGER) → MEMBER joins →
#   re-requesting after joining 409s ("already part").
#
# Budget: 1 create, 2 join-policy POSTs, 4 /requests POSTs (open-reject,
# happy, dedup, already-member), 1 accept. Closed-policy + nonexistent
# rejections live in scenario 38 to keep /requests under 5/min here.

# --- MANAGER creates the project (default open) ---
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
  "name": "scenario36-request-flow",
  "description": "member requests to join under request policy",
  "link": "https://example.test/scenario36",
  "type": "sig_data",
  "active": true,
  "founded_at": "2024-09-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"
[Asserts]
jsonpath "$.join_policy" == "open"

# --- MEMBER tries to request while the project is still open ---
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

# Open projects don't take requests — the hint points at /join.
POST {{KANAE_URL}}/projects/{{project_id}}/requests
Content-Type: application/json
{}
HTTP 409
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "open"

# --- MANAGER flips the policy to 'request' ---
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
{ "join_policy": "request" }
HTTP 200
[Asserts]
jsonpath "$.id" == "{{project_id}}"
jsonpath "$.join_policy" == "request"

# A direct /join is now refused — the policy gate redirects to a request.
POST {{KANAE_URL}}/projects/{{project_id}}/join
HTTP 409
[Asserts]
jsonpath "$.detail" contains "request"

# --- MEMBER submits the request ---
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

POST {{KANAE_URL}}/projects/{{project_id}}/requests
Content-Type: application/json
{ "message": "I'd like to help out" }
HTTP 200
[Captures]
request_id: jsonpath "$.id"
[Asserts]
jsonpath "$.kind" == "request"
jsonpath "$.status" == "pending"
jsonpath "$.member.id" == "{{MEMBER_ID}}"
jsonpath "$.invited_by" == "{{MEMBER_ID}}"
jsonpath "$.message" == "I'd like to help out"

# A second pending request collides on the one-pending index → 409.
POST {{KANAE_URL}}/projects/{{project_id}}/requests
Content-Type: application/json
{}
HTTP 409
[Asserts]
jsonpath "$.detail" contains "pending handshake"

# The request shows in the member's own outbox.
GET {{KANAE_URL}}/members/me/projects/invites?kind=request
HTTP 200
[Asserts]
jsonpath "$[?(@.id == '{{request_id}}')].status" contains "pending"
jsonpath "$[?(@.id == '{{request_id}}')].kind" contains "request"

# --- MANAGER reviews and accepts the request ---
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

GET {{KANAE_URL}}/projects/{{project_id}}/invites?kind=request&status=pending
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{request_id}}"

# MANAGER satisfies the request-side gate via Role.MANAGER.
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{request_id}}/accept
HTTP 200
[Asserts]
jsonpath "$.id" == "{{request_id}}"
jsonpath "$.status" == "accepted"

# The requester is now a project member.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 2
body contains "{{MEMBER_ID}}"

# --- MEMBER, now a member, cannot request again ---
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

POST {{KANAE_URL}}/projects/{{project_id}}/requests
Content-Type: application/json
{}
HTTP 409
[Asserts]
jsonpath "$.detail" contains "already part"
