# The member's side of the handshake — every move a member can make,
# walked sequentially on ONE project by toggling the member in and out
# (the one-pending index forbids a simultaneous invite+request for the
# same member+project, so the directions are exercised in turn rather
# than at once; the simultaneous-collision case lives in scenario 38):
#
#   invite_a: lead invites → member ACCEPTS → joins → member LEAVES.
#   invite_b: lead RE-INVITES (leaving freed the handshake; the accepted
#             row is terminal and doesn't block) → member DECLINES.
#   req_a:    policy=request; member REQUESTS → revokes their OWN request
#             (initiator path, the success case).
#   req_b:    member RE-REQUESTS (the revoked row no longer blocks) →
#             lead APPROVES → joins. Lead view then holds all four rows.
#
# Inbox/outbox checks are scoped by id (other scenarios also write
# invites for this member), never by absolute count.
#
# Budget: 1 create, 2 /invites, 2 /requests, 2 accept, 1 decline,
# 1 revoke, 1 join-policy, 1 leave.

# --- MANAGER: project + first invite ---
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
  "name": "scenario39-member-moves",
  "description": "one project, every member-side handshake move",
  "link": "https://example.test/scenario39",
  "type": "sig_arch",
  "active": true,
  "founded_at": "2024-09-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"

POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}", "message": "join us" }
HTTP 200
[Captures]
invite_a: jsonpath "$.id"
[Asserts]
jsonpath "$.kind" == "invite"

# --- MEMBER: accept, confirm membership, then leave ---
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

# The incoming invite is in the inbox (scoped to this invite's id).
GET {{KANAE_URL}}/members/me/projects/invites?kind=invite
HTTP 200
[Asserts]
jsonpath "$[?(@.id == '{{invite_a}}')].status" contains "pending"

POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite_a}}/accept
HTTP 200
[Asserts]
jsonpath "$.status" == "accepted"

GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
body contains "{{project_id}}"

DELETE {{KANAE_URL}}/projects/{{project_id}}/leave
HTTP 200

GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
body not contains "{{project_id}}"

# --- MANAGER: re-invite (leaving reopened eligibility) + open requests ---
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

# The accepted row is terminal and the member is no longer a member, so
# a fresh invite is allowed and gets a new id.
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}" }
HTTP 200
[Captures]
invite_b: jsonpath "$.id"
[Asserts]
jsonpath "$.status" == "pending"
jsonpath "$.id" != "{{invite_a}}"

POST {{KANAE_URL}}/projects/{{project_id}}/join-policy
Content-Type: application/json
{ "join_policy": "request" }
HTTP 200
[Asserts]
jsonpath "$.join_policy" == "request"

# --- MEMBER: decline the re-invite, then drive the request side ---
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

# Decline frees the pending row so a request can take its place.
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite_b}}/decline
HTTP 200
[Asserts]
jsonpath "$.id" == "{{invite_b}}"
jsonpath "$.status" == "declined"

POST {{KANAE_URL}}/projects/{{project_id}}/requests
Content-Type: application/json
{ "message": "please add me" }
HTTP 200
[Captures]
req_a: jsonpath "$.id"
[Asserts]
jsonpath "$.kind" == "request"
jsonpath "$.invited_by" == "{{MEMBER_ID}}"

# Outbox now carries the request (scoped to this request's id).
GET {{KANAE_URL}}/members/me/projects/invites?kind=request
HTTP 200
[Asserts]
jsonpath "$[?(@.id == '{{req_a}}')].status" contains "pending"

# Member revokes their OWN request — initiator path, succeeds.
DELETE {{KANAE_URL}}/projects/{{project_id}}/invites/{{req_a}}/revoke
HTTP 200
[Asserts]
jsonpath "$.id" == "{{req_a}}"
jsonpath "$.status" == "revoked"

GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
body not contains "{{project_id}}"

# The revoked row is terminal, so a fresh request is allowed.
POST {{KANAE_URL}}/projects/{{project_id}}/requests
Content-Type: application/json
{ "message": "actually, yes" }
HTTP 200
[Captures]
req_b: jsonpath "$.id"
[Asserts]
jsonpath "$.id" != "{{req_a}}"
jsonpath "$.status" == "pending"

# --- MANAGER: approve the re-issued request, inspect the full history ---
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

POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{req_b}}/accept
HTTP 200
[Asserts]
jsonpath "$.status" == "accepted"

GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 2
body contains "{{MEMBER_ID}}"

# Lead view holds the entire handshake history for this project: two
# invites (accepted, declined) and two requests (revoked, accepted).
GET {{KANAE_URL}}/projects/{{project_id}}/invites
HTTP 200
[Asserts]
jsonpath "$" count == 4

GET {{KANAE_URL}}/projects/{{project_id}}/invites?kind=invite
HTTP 200
[Asserts]
jsonpath "$" count == 2
jsonpath "$[?(@.id == '{{invite_a}}')].status" contains "accepted"
jsonpath "$[?(@.id == '{{invite_b}}')].status" contains "declined"

GET {{KANAE_URL}}/projects/{{project_id}}/invites?kind=request
HTTP 200
[Asserts]
jsonpath "$" count == 2
jsonpath "$[?(@.id == '{{req_a}}')].status" contains "revoked"
jsonpath "$[?(@.id == '{{req_b}}')].status" contains "accepted"
