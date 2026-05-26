# /events/{id} mutations gate on has_permissions(Event.edit) and
# has_permissions(Event.own). LEADS creates events but doesn't auto-
# own the relation tuples; they have to be written explicitly.
#
# Kanae's `check_permission` is `@cached_method` for 60s keyed on
# `(namespace, object, relation, subject_id)` — re-login does NOT
# invalidate it (the key has no cookie component, and the bypass-
# Kanae direct-to-Keto PUT below also skips Kanae's `.grant()`
# invalidation path). So we use THREE events:
#   - denied_event_id   → never granted, verifies the 403 path.
#   - editable_event_id → Event:<id>#edit granted, verifies PUT 200.
#   - deletable_event_id → Event:<id>#own  granted, verifies DELETE 200.
# Grants land BEFORE the first PUT/DELETE against each so no cached
# False sits on the resource we want to pass.

GET {{KRATOS_URL}}/self-service/login/browser
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

# Event A — never granted.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "55555555-5555-4555-8555-555555555555",
  "name": "scenario15-denied",
  "description": "no grant",
  "start_at": "2099-06-01T00:00:00Z",
  "end_at":   "2099-06-01T03:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
denied_event_id: jsonpath "$.id"

# Event B — will get Event.edit granted.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "55555555-5555-4555-8555-555555555556",
  "name": "scenario15-editable",
  "description": "edit-granted",
  "start_at": "2099-06-01T00:00:00Z",
  "end_at":   "2099-06-01T03:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
editable_event_id: jsonpath "$.id"

# Event C — will get Event.own granted (for DELETE).
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "55555555-5555-4555-8555-555555555557",
  "name": "scenario15-deletable",
  "description": "own-granted",
  "start_at": "2099-06-01T00:00:00Z",
  "end_at":   "2099-06-01T03:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
deletable_event_id: jsonpath "$.id"

# A: no tuple → 403 (and Kanae caches False for A, harmless).
PUT {{KANAE_URL}}/events/{{denied_event_id}}
Content-Type: application/json
{ "name": "scenario15-cant-rename", "description": "denied", "location": "Online" }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

DELETE {{KANAE_URL}}/events/{{denied_event_id}}
HTTP 403

# Grant Event:B#edit BEFORE the first PUT against B.
PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{
  "namespace": "Event",
  "object": "{{editable_event_id}}",
  "relation": "edit",
  "subject_id": "{{LEADS_ID}}"
}
HTTP 201
[Asserts]
jsonpath "$.namespace" == "Event"
jsonpath "$.object" == "{{editable_event_id}}"
jsonpath "$.relation" == "edit"

PUT {{KANAE_URL}}/events/{{editable_event_id}}
Content-Type: application/json
{ "name": "scenario15-renamed", "description": "now editable", "location": "Online" }
HTTP 200
[Asserts]
jsonpath "$.name" == "scenario15-renamed"
jsonpath "$.description" == "now editable"
jsonpath "$.location" == "Online"

# Subsequent GET reflects the edit.
GET {{KANAE_URL}}/events/{{editable_event_id}}
HTTP 200
[Asserts]
jsonpath "$.name" == "scenario15-renamed"

# Grant Event:C#own BEFORE the first DELETE against C.
PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{
  "namespace": "Event",
  "object": "{{deletable_event_id}}",
  "relation": "own",
  "subject_id": "{{LEADS_ID}}"
}
HTTP 201

DELETE {{KANAE_URL}}/events/{{deletable_event_id}}
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# Verify the row is actually gone.
GET {{KANAE_URL}}/events/{{deletable_event_id}}
HTTP 404
