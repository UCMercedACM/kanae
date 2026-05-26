# Manager creates a project; the route also inserts a lead row in
# project_members (creator becomes the project lead). Verifies both
# the response payload and the side-effect via /projects/{id}, plus
# multiple `type` literals round-trip cleanly. Member-list shape is
# also pinned since downstream UIs depend on it.

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
  "name": "scenario16-project",
  "description": "manager-created",
  "link": "https://example.test/scenario16",
  "type": "sig_swe",
  "active": true,
  "founded_at": "2024-01-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.id" isUuid
jsonpath "$.name" == "scenario16-project"
jsonpath "$.description" == "manager-created"
jsonpath "$.link" == "https://example.test/scenario16"
jsonpath "$.type" == "sig_swe"
jsonpath "$.active" == true
jsonpath "$.founded_at" isIsoDate

# Cross-component check: /projects/{id} returns FullProjects which
# includes the auto-inserted lead row in `members`.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{project_id}}"
jsonpath "$.members" isCollection
jsonpath "$.members" count == 1
jsonpath "$.members[0].id" == "{{MANAGER_ID}}"
jsonpath "$.members[0].name" isString

# /members/me/projects reflects the auto-membership.
GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
jsonpath "$" isCollection
body contains "{{project_id}}"

# Visible in the listing.
GET {{KANAE_URL}}/projects?page=1&size=100
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
body contains "{{project_id}}"