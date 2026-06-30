# Flow A (lead invites) end-to-end, the happy path plus the terminal
# edges around it:
#   MANAGER creates a project (still join_policy=open by default) →
#   MANAGER invites MEMBER (kind=invite, status=pending) →
#   the invite shows up in MANAGER's project view AND in MEMBER's
#   /members/me/projects/invites inbox → MEMBER accepts → MEMBER is now
#   a project_member → accepting/declining the same row again 409s
#   ("already accepted"), proving the row is terminal.
#
# Budget: 1 /projects/create, 1 /projects/{id}/invites, 1 accept.
# Everything else is reads or terminal-state 409s (handler-reached but
# cheap). join_policy stays 'open' here on purpose — a lead invite must
# work regardless of policy (the policy only gates /join and /requests).

# --- MANAGER creates the project ---
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
[Asserts]
jsonpath "$.session.identity.id" == "{{MANAGER_ID}}"

POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{
  "name": "scenario34-invite-accept",
  "description": "lead invites a member who accepts",
  "link": "https://example.test/scenario34",
  "type": "sig_ai",
  "active": true,
  "founded_at": "2024-09-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"
[Asserts]
jsonpath "$.id" isUuid
jsonpath "$.join_policy" == "open"

# Baseline: only the creator is a member.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 1
jsonpath "$.members[0].id" == "{{MANAGER_ID}}"

# --- MANAGER invites MEMBER (kind=invite) ---
POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}", "message": "come build with us" }
HTTP 200
[Captures]
invite_id: jsonpath "$.id"
[Asserts]
jsonpath "$.id" isUuid
jsonpath "$.project_id" == "{{project_id}}"
jsonpath "$.kind" == "invite"
jsonpath "$.status" == "pending"
jsonpath "$.member.id" == "{{MEMBER_ID}}"
jsonpath "$.invited_by" == "{{MANAGER_ID}}"
jsonpath "$.message" == "come build with us"
jsonpath "$.responded_at" == null
jsonpath "$.expires_at" exists

# Lead-side listing surfaces the pending invite; filters narrow it.
GET {{KANAE_URL}}/projects/{{project_id}}/invites
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{invite_id}}"
jsonpath "$[0].status" == "pending"
jsonpath "$[0].kind" == "invite"

GET {{KANAE_URL}}/projects/{{project_id}}/invites?status=pending&kind=invite
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{invite_id}}"

# Wrong-direction filter → empty, not the row.
GET {{KANAE_URL}}/projects/{{project_id}}/invites?kind=request
HTTP 200
[Asserts]
jsonpath "$" count == 0

# Still nobody joined just from the invite existing.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 1

# --- switch to MEMBER; the invite is in their inbox ---
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

GET {{KANAE_URL}}/members/me/projects/invites
HTTP 200
[Asserts]
jsonpath "$" isCollection
body contains "{{invite_id}}"

GET {{KANAE_URL}}/members/me/projects/invites?kind=invite&status=pending
HTTP 200
[Asserts]
jsonpath "$[*].id" contains "{{invite_id}}"
jsonpath "$[?(@.id == '{{invite_id}}')].status" contains "pending"

# --- MEMBER accepts → joins the project ---
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite_id}}/accept
HTTP 200
[Asserts]
jsonpath "$.id" == "{{invite_id}}"
jsonpath "$.status" == "accepted"

# Membership now reflects the join from both sides.
GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
body contains "{{project_id}}"

GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 2
body contains "{{MEMBER_ID}}"
body contains "{{MANAGER_ID}}"

# The row is terminal: a second accept and a late decline both 409.
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite_id}}/accept
HTTP 409
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "already accepted"

POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite_id}}/decline
HTTP 409
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "already accepted"

# Inbox now shows it accepted, not pending.
GET {{KANAE_URL}}/members/me/projects/invites?status=accepted
HTTP 200
[Asserts]
jsonpath "$[?(@.id == '{{invite_id}}')].status" contains "accepted"
