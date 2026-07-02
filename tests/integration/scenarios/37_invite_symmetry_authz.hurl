# The symmetry rule is the whole authorization model, so hammer it:
#   - kind=invite  → only the TARGET member may accept/decline; the
#     initiator OR any lead (Role.MANAGER / Project.edit) may revoke; a
#     plain member (not the target's counterpart) may do nothing.
#   - kind=request → only a lead (Role.MANAGER OR Project.edit) may
#     accept/decline; the initiator (the member) may revoke.
# Plus the non-manager "lead" path: LEADS holds Project.edit (granted
# via Keto, not Role.MANAGER) and must be able to invite and to respond
# to requests, exactly like a manager.
#
# Cast on one project:
#   MANAGER  — owner, Role.MANAGER, invites MEMBER (invite_id)
#   LEADS    — Project.edit grantee, invites ADMIN (invite2)
#   ROOT     — outsider, opens a request (request_id) once policy=request
#   MEMBER   — target of invite_id; a plain member elsewhere
#
# Budget: 1 create, 2 /invites, 1 /requests, 1 join-policy, 4 accept
# (all expected non-200), 1 decline, 3 revoke. Pure-422 path cases are
# free (validation fires before the limiter).

# --- MANAGER: project + invite MEMBER + open the request door ---
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
  "name": "scenario37-symmetry",
  "description": "every wrong party is blocked",
  "link": "https://example.test/scenario37",
  "type": "sig_swe",
  "active": true,
  "founded_at": "2024-09-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"

# Grant LEADS Project.edit up front so no cached False lingers on
# (Project, project_id, edit, LEADS) before the first check.
PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Project", "object": "{{project_id}}", "relation": "edit", "subject_id": "{{LEADS_ID}}" }
HTTP 201

POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{MEMBER_ID}}" }
HTTP 200
[Captures]
invite_id: jsonpath "$.id"

# Open the request door for ROOT later (lead invites already work
# regardless of policy).
POST {{KANAE_URL}}/projects/{{project_id}}/join-policy
Content-Type: application/json
{ "join_policy": "request" }
HTTP 200
[Asserts]
jsonpath "$.join_policy" == "request"

# --- LEADS is a lead via Project.edit, not Role.MANAGER ---
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
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

# Editor can read the lead listing and can invite (non-manager path).
GET {{KANAE_URL}}/projects/{{project_id}}/invites
HTTP 200
[Asserts]
jsonpath "$[*].id" contains "{{invite_id}}"

POST {{KANAE_URL}}/projects/{{project_id}}/invites
Content-Type: application/json
{ "member_id": "{{ADMIN_ID}}" }
HTTP 200
[Captures]
invite2: jsonpath "$.id"
[Asserts]
jsonpath "$.member.id" == "{{ADMIN_ID}}"
jsonpath "$.invited_by" == "{{LEADS_ID}}"

# --- ROOT, an outsider with no pending row, opens a request ---
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ROOT_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{ROOT_ID}}"

POST {{KANAE_URL}}/projects/{{project_id}}/requests
Content-Type: application/json
{ "message": "let me in" }
HTTP 200
[Captures]
request_id: jsonpath "$.id"
[Asserts]
jsonpath "$.kind" == "request"
jsonpath "$.invited_by" == "{{ROOT_ID}}"

# --- MEMBER: target of invite_id, wrong party for everything else ---
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

# kind=request → a non-lead member cannot accept it (symmetry).
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{request_id}}/accept
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "cannot respond"

# kind=invite for ADMIN → MEMBER is not the target, so 403.
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite2}}/accept
HTTP 403
[Asserts]
jsonpath "$.detail" contains "cannot respond"

# MEMBER is the target of invite_id, not its initiator, and holds neither
# Role.MANAGER nor Project.edit → cannot revoke it (a different gate than
# accept/decline).
DELETE {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite_id}}/revoke
HTTP 403
[Asserts]
jsonpath "$.detail" contains "cannot revoke"

# Malformed invite UUID → 422 before the handler (free, no limiter hit).
POST {{KANAE_URL}}/projects/{{project_id}}/invites/not-a-uuid/accept
HTTP 422

# --- LEADS (editor) responds to the request, and is blocked on the
#     invite it isn't a party to ---
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
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

# kind=request → editor LEADS may decline it (non-manager lead path).
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{request_id}}/decline
HTTP 200
[Asserts]
jsonpath "$.id" == "{{request_id}}"
jsonpath "$.status" == "declined"

# kind=invite (target MEMBER) → even a lead cannot accept on the
# member's behalf; only the target member may.
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite_id}}/accept
HTTP 403
[Asserts]
jsonpath "$.detail" contains "cannot respond"

# ROOT's request is terminal now → accepting it 409s.
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{request_id}}/accept
HTTP 409
[Asserts]
jsonpath "$.detail" contains "already declined"

# --- MANAGER: revoke own invite, and prove it can't revoke LEADS's ---
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

# Initiator MANAGER revokes its own invite to MEMBER.
DELETE {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite_id}}/revoke
HTTP 200
[Asserts]
jsonpath "$.id" == "{{invite_id}}"
jsonpath "$.status" == "revoked"

# Revoked is terminal → MEMBER could no longer accept it either (409).
POST {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite_id}}/accept
HTTP 409
[Asserts]
jsonpath "$.detail" contains "already revoked"

# invite2 was opened by LEADS — MANAGER isn't its initiator, but under the
# initiator-OR-lead rule a Role.MANAGER holder may revoke a project-side
# invite it didn't create.
DELETE {{KANAE_URL}}/projects/{{project_id}}/invites/{{invite2}}/revoke
HTTP 200
[Asserts]
jsonpath "$.id" == "{{invite2}}"
jsonpath "$.status" == "revoked"

# Nobody actually joined: every invite was revoked and the request declined.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 1
jsonpath "$.members[0].id" == "{{MANAGER_ID}}"
