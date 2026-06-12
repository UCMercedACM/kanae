# /events/{id} mutations gate on has_permissions(Event.edit) and
# has_permissions(Event.own). Post-G0, the CREATOR (LEADS) auto-owns every
# event it creates, so the denial path can no longer be tested with the
# creator — it must use a DIFFERENT, non-owner identity. LEADS creates the
# events (and auto-owns them); we then switch to MEMBER and verify MEMBER is
# denied until granted the relevant tuple.
#
# Kanae's `check_permission` is `@cached_method` for 60s keyed on
# `(namespace, object, relation, subject_id)` — re-login does NOT invalidate
# it (the key has no cookie component), and the bypass-Kanae direct-to-Keto
# PUT below also skips Kanae's `.grant()` invalidation path. So we use THREE
# events to keep the cache keys disjoint:
#   - denied_event_id   → MEMBER never granted, verifies the 403 path.
#   - editable_event_id → Event:<id>#edit granted to MEMBER, verifies PUT 200.
#   - deletable_event_id → Event:<id>#own  granted to MEMBER, verifies DELETE 200.
# Grants land BEFORE the first PUT/DELETE against each so no cached False sits
# on the resource we want to pass.

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

# Event A — MEMBER never granted (LEADS auto-owns it on create).
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "55555555-5555-4555-8555-555555555555",
  "name": "scenario14-denied",
  "description": "no grant for member",
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

# Event B — MEMBER will get Event.edit.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "55555555-5555-4555-8555-555555555556",
  "name": "scenario14-editable",
  "description": "edit-granted to member",
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

# Event C — MEMBER will get Event.own (for DELETE).
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "55555555-5555-4555-8555-555555555557",
  "name": "scenario14-deletable",
  "description": "own-granted to member",
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

# --- switch to MEMBER (refresh=true since the LEADS session is in the jar) ---
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

# A: MEMBER has no tuple → 403 (and Kanae caches False for A, harmless).
PUT {{KANAE_URL}}/events/{{denied_event_id}}
Content-Type: application/json
{ "name": "scenario14-cant-rename", "description": "denied", "location": "Online" }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

DELETE {{KANAE_URL}}/events/{{denied_event_id}}
HTTP 403

# Grant Event:B#edit to MEMBER BEFORE the first PUT against B.
PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Event", "object": "{{editable_event_id}}", "relation": "edit", "subject_id": "{{MEMBER_ID}}" }
HTTP 201
[Asserts]
jsonpath "$.namespace" == "Event"
jsonpath "$.object" == "{{editable_event_id}}"
jsonpath "$.relation" == "edit"
jsonpath "$.subject_id" == "{{MEMBER_ID}}"

PUT {{KANAE_URL}}/events/{{editable_event_id}}
Content-Type: application/json
{ "name": "scenario14-renamed", "description": "now editable", "location": "Online" }
HTTP 200
[Asserts]
jsonpath "$.name" == "scenario14-renamed"
jsonpath "$.description" == "now editable"
jsonpath "$.location" == "Online"

# Subsequent GET reflects the edit.
GET {{KANAE_URL}}/events/{{editable_event_id}}
HTTP 200
[Asserts]
jsonpath "$.name" == "scenario14-renamed"

# Grant Event:C#own to MEMBER BEFORE the first DELETE against C.
PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Event", "object": "{{deletable_event_id}}", "relation": "own", "subject_id": "{{MEMBER_ID}}" }
HTTP 201

DELETE {{KANAE_URL}}/events/{{deletable_event_id}}
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# Verify the row is actually gone.
GET {{KANAE_URL}}/events/{{deletable_event_id}}
HTTP 404
