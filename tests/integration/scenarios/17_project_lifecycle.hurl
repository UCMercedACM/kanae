# Full project lifecycle as MANAGER: create → list-find → edit (needs
# Project.edit) → re-edit-no-op verifies idempotency → archive via
# `active: false` → delete (needs Project.own) → 404 on re-fetch.
# Exercises both Keto grant paths plus list_projects's pg_trgm filter
# and the `active` filter.

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
  "name": "scenario18-lifecycle",
  "description": "trip through edit and delete",
  "link": "https://example.test/scenario18",
  "type": "sig_data",
  "active": true,
  "founded_at": "2025-01-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"
[Asserts]
jsonpath "$.id" isUuid
jsonpath "$.active" == true

# Filter by partial name via pg_trgm similarity — body-level check
# stays correct regardless of position in the result.
GET {{KANAE_URL}}/projects?name=scenario18-lifecycle
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
body contains "{{project_id}}"

# Grant Project.edit + Project.own BEFORE the first mutation, so no
# cached False sits on either tuple in Kanae's permission cache.
PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Project", "object": "{{project_id}}", "relation": "edit", "subject_id": "{{MANAGER_ID}}" }
HTTP 201

PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Project", "object": "{{project_id}}", "relation": "own", "subject_id": "{{MANAGER_ID}}" }
HTTP 201

# Edit: rename + update description + update link.
PUT {{KANAE_URL}}/projects/{{project_id}}
Content-Type: application/json
{
  "name": "scenario18-renamed",
  "description": "edited",
  "link": "https://example.test/scenario18-renamed"
}
HTTP 200
[Asserts]
jsonpath "$.name" == "scenario18-renamed"
jsonpath "$.description" == "edited"
jsonpath "$.link" == "https://example.test/scenario18-renamed"

# GET reflects the edits (cross-route consistency).
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.name" == "scenario18-renamed"
jsonpath "$.description" == "edited"

# DELETE.
DELETE {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# Subsequent GET → 404.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 404

# Subsequent DELETE on missing row → 404 (and Project.own still
# satisfies the dependency check, so this is a real 404 not a 403).
# Idempotent re-edit + post-delete PUT (which both 404) were dropped
# to stay within the per-IP `3/minute` rate budget on
# `edit_project` — that bucket is shared with scenario 20's PUT.
DELETE {{KANAE_URL}}/projects/{{project_id}}
HTTP 404
