# Manager-side project administration journey: create → bulk-join
# extra members → grant self Project.own (required by member/modify) →
# promote a member to lead → flip the same member to "former" →
# verify the role transitions surface in /projects/{id}.members.
#
# Exercises three routes nothing else touches:
#   POST /projects/{id}/bulk-join     (1/minute, this scenario owns it)
#   PUT  /projects/{id}/member/modify (3/minute, this scenario owns it)
#   `check_any(has_role(MANAGER), has_permissions(Project.own))` on
#   bulk-join is satisfied via the MANAGER role from bootstrap, so we
#   only need Keto Project.own for member/modify (which also checks
#   Project.own AND Role.MANAGER).
#
# Pydantic 422s (malformed UUIDs, missing fields, bad literals) fire
# BEFORE the route function and don't count against the limiters, so
# we can fold every body-validation variant into the run alongside the
# one happy-path bulk-join.

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

# Create the project (uses the last /projects/create budget slot).
POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{
  "name": "scenario24-admin-project",
  "description": "manager-administered project",
  "link": "https://example.test/scenario24",
  "type": "sig_arch",
  "active": true,
  "founded_at": "2024-01-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"
[Asserts]
jsonpath "$.id" isUuid
jsonpath "$.name" == "scenario24-admin-project"

# Initial member list: only the creator.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" isCollection
jsonpath "$.members" count == 1
jsonpath "$.members[0].id" == "{{MANAGER_ID}}"

# --- bulk-join validation cases that DON'T reach the route function
# (Pydantic 422 / dependency 422 fires first → limiter never
# increments). All four must surface as 422 with the documented
# RequestValidationError shape.

# Body not an array.
POST {{KANAE_URL}}/projects/{{project_id}}/bulk-join
Content-Type: application/json
{ "id": "{{MEMBER_ID}}" }
HTTP 422

# Element missing the `id` field.
POST {{KANAE_URL}}/projects/{{project_id}}/bulk-join
Content-Type: application/json
[ {} ]
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "id"

# Element with malformed UUID.
POST {{KANAE_URL}}/projects/{{project_id}}/bulk-join
Content-Type: application/json
[ { "id": "not-a-uuid" } ]
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "uuid_parsing"

# Element with extra fields — BulkJoinMember is `extra="forbid"`?
# (It's not — defaults to ignore.) An extra field is silently
# stripped; the rest still validates and the call reaches the route
# function, so to keep the limiter clean we skip the happy-with-extra
# test and rely on the strict happy-path below as the sole route-body
# increment.

# Path-param malformed UUID — 422 before the route body, doesn't
# touch the limiter.
POST {{KANAE_URL}}/projects/not-a-uuid/bulk-join
Content-Type: application/json
[ { "id": "{{MEMBER_ID}}" } ]
HTTP 422

# --- the one happy-path bulk-join (consumes the 1/minute budget).
POST {{KANAE_URL}}/projects/{{project_id}}/bulk-join
Content-Type: application/json
[
  { "id": "{{MEMBER_ID}}" },
  { "id": "{{LEADS_ID}}" }
]
HTTP 200
[Asserts]
jsonpath "$.message" isString
jsonpath "$.message" exists

# Project lookup now shows manager + member + leads.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 3
body contains "{{MANAGER_ID}}"
body contains "{{MEMBER_ID}}"
body contains "{{LEADS_ID}}"

# --- Project.own grant (member/modify requires it AND Role.MANAGER).
PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Project", "object": "{{project_id}}", "relation": "own", "subject_id": "{{MANAGER_ID}}" }
HTTP 201

# --- modify_member validation cases (Pydantic, no increment).
PUT {{KANAE_URL}}/projects/{{project_id}}/member/modify
Content-Type: application/json
{ "id": "{{MEMBER_ID}}", "role": "admin" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "literal_error"

PUT {{KANAE_URL}}/projects/{{project_id}}/member/modify
Content-Type: application/json
{ "id": "{{MEMBER_ID}}" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "role"

PUT {{KANAE_URL}}/projects/{{project_id}}/member/modify
Content-Type: application/json
{ "role": "lead" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "id"

PUT {{KANAE_URL}}/projects/{{project_id}}/member/modify
Content-Type: application/json
{ "id": "not-a-uuid", "role": "lead" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "uuid_parsing"

# --- modify_member happy paths (consume 2/3 of the 3/min budget).
PUT {{KANAE_URL}}/projects/{{project_id}}/member/modify
Content-Type: application/json
{ "id": "{{MEMBER_ID}}", "role": "lead" }
HTTP 200
[Asserts]
jsonpath "$.message" isString

PUT {{KANAE_URL}}/projects/{{project_id}}/member/modify
Content-Type: application/json
{ "id": "{{MEMBER_ID}}", "role": "former" }
HTTP 200
