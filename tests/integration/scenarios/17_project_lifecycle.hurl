# Full project lifecycle as MANAGER: create → list-find → grant
# Project.edit + Project.own → edit → tag overwrite/partial-remove/clear
# (needs Project.edit) → archive toggle via `active` (needs Project.own)
# → delete (needs Project.own) → 404 on re-fetch.
# Exercises both Keto grant paths plus list_projects's pg_trgm filter,
# the `active` filter, the tag-editing routes, and tag surfacing on reads.
# Tag steps reuse the persistent tags bulk-created in scenario 08
# (scenario09-alpha/beta/gamma); their buckets (tags 5/min, archive
# 3/min) are distinct from edit_project's 3/min.

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
# Freshly-created project has no tags yet.
jsonpath "$.tags" == null

# Overwrite the tag set (Project.edit) with the tags bulk-created in
# scenario 08. Sent out of order with a duplicate; the response echoes the
# resulting DB state — deduplicated and alphabetically sorted — not the raw
# request list.
PUT {{KANAE_URL}}/projects/{{project_id}}/tags
Content-Type: application/json
{ "tags": ["scenario09-gamma", "scenario09-alpha", "scenario09-beta", "scenario09-alpha"] }
HTTP 200
[Asserts]
jsonpath "$.tags" count == 3
jsonpath "$.tags[0]" == "scenario09-alpha"
jsonpath "$.tags[1]" == "scenario09-beta"
jsonpath "$.tags[2]" == "scenario09-gamma"

# GET surfaces them, alphabetically (array_agg ORDER BY title).
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.tags" count == 3
jsonpath "$.tags" contains "scenario09-gamma"

# Partial removal rides on the overwrite: resend only the survivors.
PUT {{KANAE_URL}}/projects/{{project_id}}/tags
Content-Type: application/json
{ "tags": ["scenario09-alpha", "scenario09-beta"] }
HTTP 200

GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.tags" count == 2
jsonpath "$.tags" contains "scenario09-alpha"
jsonpath "$.tags" contains "scenario09-beta"

# Unknown tag → 422, and the prior set is left intact (tx rollback).
PUT {{KANAE_URL}}/projects/{{project_id}}/tags
Content-Type: application/json
{ "tags": ["this-tag-does-not-exist"] }
HTTP 422

GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.tags" count == 2

# Clear all tags (Project.edit) → GET shows null again.
DELETE {{KANAE_URL}}/projects/{{project_id}}/tags
HTTP 200

GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.tags" == null

# Archive toggle (Project.own): flip inactive, confirm the
# `?active=false` list filter surfaces it, then restore.
PUT {{KANAE_URL}}/projects/{{project_id}}/archive
Content-Type: application/json
{ "active": false }
HTTP 200
[Asserts]
jsonpath "$.active" == false

GET {{KANAE_URL}}/projects?active=false
HTTP 200
[Asserts]
body contains "{{project_id}}"

PUT {{KANAE_URL}}/projects/{{project_id}}/archive
Content-Type: application/json
{ "active": true }
HTTP 200
[Asserts]
jsonpath "$.active" == true

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
