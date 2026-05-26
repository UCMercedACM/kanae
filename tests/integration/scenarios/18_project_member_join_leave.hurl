# MANAGER creates a project; MEMBER joins (single + double + bad ids),
# sees it in /members/me/projects, then leaves and it disappears.
# Covers double-join 409, FK-violation 404 on /join with a junk
# project id, leave + leave-again 404, and the post-leave listing
# state.

# --- MANAGER creates ---
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
  "name": "scenario19-club",
  "description": "open for join",
  "link": "https://example.test/club",
  "type": "sig_ai",
  "active": true,
  "founded_at": "2024-09-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"
[Asserts]
jsonpath "$.id" isUuid

# Pre-flight: project lookup shows just the manager as lead.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 1
jsonpath "$.members[0].id" == "{{MANAGER_ID}}"

# --- MEMBER joins (refresh=true since the MANAGER session is in the jar) ---
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

POST {{KANAE_URL}}/projects/{{project_id}}/join
HTTP 200
[Asserts]
jsonpath "$.message" isString
jsonpath "$.message" exists

# Visible from /members/me/projects.
GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
jsonpath "$" isCollection
body contains "{{project_id}}"

# Project lookup now shows MEMBER alongside MANAGER.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 2
body contains "{{MEMBER_ID}}"
body contains "{{MANAGER_ID}}"

# Double-join → 409, transaction rolled back cleanly.
POST {{KANAE_URL}}/projects/{{project_id}}/join
HTTP 409
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "already joined"

# Join a nonexistent project → 404 from FK violation.
POST {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777777/join
HTTP 404
[Asserts]
jsonpath "$.result" == "error"

# Malformed project UUID → 422 (path validation before route body).
POST {{KANAE_URL}}/projects/not-a-uuid/join
HTTP 422

# Leave → no longer in /members/me/projects.
DELETE {{KANAE_URL}}/projects/{{project_id}}/leave
HTTP 200
[Asserts]
jsonpath "$.message" isString
jsonpath "$.message" exists

GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
body not contains "{{project_id}}"

# Project lookup now shows MANAGER alone again.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 1
jsonpath "$.members[0].id" == "{{MANAGER_ID}}"

# Leaving again → 404 (no row to delete).
DELETE {{KANAE_URL}}/projects/{{project_id}}/leave
HTTP 404
[Asserts]
jsonpath "$.result" == "error"

# Leaving a nonexistent project also 404 (no row to delete).
DELETE {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777778/leave
HTTP 404

# Malformed UUID on leave → 422.
DELETE {{KANAE_URL}}/projects/not-a-uuid/leave
HTTP 422
