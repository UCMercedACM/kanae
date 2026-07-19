# Deleting a tag that is still attached to a project/event must 409 with the
# AttachedTagResponse shape (detail + entries[]), leaving the tag intact —
# rather than silently deleting or 500-ing on the bridge FK. Once the tag is
# detached it deletes cleanly. Driven entirely as ROOT (superuser satisfies the
# admin create gate, owns the event it creates → Event.edit, and is root for
# the delete). The delete route is 5/min; this uses 2 of that bucket.

GET {{KRATOS_URL}}/self-service/login/browser
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

# Fresh tag — nothing references it yet, so in_use is false.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario40-inuse", "description": "attached to an event" }
HTTP 200
[Captures]
tag_id: jsonpath "$.id"

GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.in_use" == false

# Create an event owned by ROOT and attach the tag to it.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "40404040-4040-4040-8040-404040404040",
  "name": "scenario40-tagged-event",
  "description": "holds the tag hostage",
  "start_at": "2099-06-01T00:00:00Z",
  "end_at":   "2099-06-01T03:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{ROOT_ID}}"
}
HTTP 200
[Captures]
event_id: jsonpath "$.id"

PUT {{KANAE_URL}}/events/{{event_id}}/tags
Content-Type: application/json
{ "tags": ["scenario40-inuse"] }
HTTP 200

# The tag now reports in_use.
GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.in_use" == true

# Delete is blocked: 409 + the AttachedTagResponse listing the event that
# references it. The tag row must survive.
DELETE {{KANAE_URL}}/tags/{{tag_id}}
HTTP 409
[Asserts]
jsonpath "$.detail" == "Tag is still in use"
jsonpath "$.entries" isCollection
jsonpath "$.entries" count == 1
jsonpath "$.entries[0].id" == "{{event_id}}"
jsonpath "$.entries[0].name" == "scenario40-tagged-event"
jsonpath "$.entries[0].type" == "Event"

GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.id" == {{tag_id}}
jsonpath "$.in_use" == true

# Detach the tag, then the same delete succeeds with the {message: "ok"} shape.
DELETE {{KANAE_URL}}/events/{{event_id}}/tags
HTTP 200

DELETE {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# And it is really gone.
GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 404
[Asserts]
jsonpath "$.result" == "error"
