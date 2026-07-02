# Event tag editing as the LEADS creator (G0 auto-owns the event → Event.edit).
# Mirrors the project tag flow (scenario 17): overwrite → surface on GET →
# partial-remove → unknown-tag 422 (set intact) → clear. Reuses the tags
# bulk-created in scenario 08 (scenario09-alpha/beta/gamma). /events/create is
# 15/min so the extra create is cheap, and the tag routes (5/min) are their own
# buckets.

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

POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "30303030-3030-4030-8030-303030303030",
  "name": "scenario30-tagged-event",
  "description": "event tag editing",
  "start_at": "2099-06-01T00:00:00Z",
  "end_at":   "2099-06-01T03:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
event_id: jsonpath "$.id"

# Fresh event has no tags.
GET {{KANAE_URL}}/events/{{event_id}}
HTTP 200
[Asserts]
jsonpath "$.tags" == null

# Overwrite the tag set (Event.edit, satisfied by creator-owns). Send them
# out of order with a duplicate; the response now echoes the resulting DB
# state — deduplicated and alphabetically sorted — not the raw request list.
PUT {{KANAE_URL}}/events/{{event_id}}/tags
Content-Type: application/json
{ "tags": ["scenario09-gamma", "scenario09-alpha", "scenario09-beta", "scenario09-alpha"] }
HTTP 200
[Asserts]
jsonpath "$.tags" count == 3
jsonpath "$.tags[0]" == "scenario09-alpha"
jsonpath "$.tags[1]" == "scenario09-beta"
jsonpath "$.tags[2]" == "scenario09-gamma"

# GET surfaces them, alphabetically (array_agg ORDER BY title).
GET {{KANAE_URL}}/events/{{event_id}}
HTTP 200
[Asserts]
jsonpath "$.tags" count == 3
jsonpath "$.tags" contains "scenario09-gamma"

# Partial removal rides on the overwrite: resend only the survivors.
PUT {{KANAE_URL}}/events/{{event_id}}/tags
Content-Type: application/json
{ "tags": ["scenario09-alpha", "scenario09-beta"] }
HTTP 200

GET {{KANAE_URL}}/events/{{event_id}}
HTTP 200
[Asserts]
jsonpath "$.tags" count == 2
jsonpath "$.tags" contains "scenario09-alpha"
jsonpath "$.tags" contains "scenario09-beta"

# Unknown tag → 422, and the prior set is left intact (tx rollback).
PUT {{KANAE_URL}}/events/{{event_id}}/tags
Content-Type: application/json
{ "tags": ["this-tag-does-not-exist"] }
HTTP 422

GET {{KANAE_URL}}/events/{{event_id}}
HTTP 200
[Asserts]
jsonpath "$.tags" count == 2

# Clear all tags (Event.edit) → GET shows null again.
DELETE {{KANAE_URL}}/events/{{event_id}}/tags
HTTP 200

GET {{KANAE_URL}}/events/{{event_id}}
HTTP 200
[Asserts]
jsonpath "$.tags" == null
