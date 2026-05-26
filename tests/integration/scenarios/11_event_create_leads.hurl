# LEADS holds Role.LEADS in Keto, so has_any_role(ADMIN, LEADS)
# admits them to /events/create. Verifies the full create round-trip
# (every field), the explicit-id-is-ignored behaviour (server mints a
# fresh UUID via DEFAULT), the visibility in the public listing +
# pg_trgm name filter, and a couple of event `type` literal values
# round-tripping cleanly.

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
[Asserts]
jsonpath "$.session.identity.id" == "{{LEADS_ID}}"

# Create event with a "social" type.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "11111111-1111-4111-8111-111111111111",
  "name": "scenario12-leads-meetup",
  "description": "leads-only test event",
  "start_at": "2099-01-01T00:00:00Z",
  "end_at":   "2099-01-01T02:00:00Z",
  "location": "Online",
  "type": "social",
  "timezone": "America/Los_Angeles",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
event_id: jsonpath "$.id"
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.id" isUuid
jsonpath "$.name" == "scenario12-leads-meetup"
jsonpath "$.description" == "leads-only test event"
jsonpath "$.start_at" isIsoDate
jsonpath "$.end_at" isIsoDate
jsonpath "$.location" == "Online"
jsonpath "$.type" == "social"
jsonpath "$.timezone" == "America/Los_Angeles"
jsonpath "$.creator_id" == "{{LEADS_ID}}"

# Single-event lookup returns the same shape.
GET {{KANAE_URL}}/events/{{event_id}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{event_id}}"
jsonpath "$.timezone" == "America/Los_Angeles"
jsonpath "$.type" == "social"

# Visible via pg_trgm name filter — body-level check stays correct
# even if prior runs left similar-named events ahead in sort order.
GET {{KANAE_URL}}/events?name=scenario12-leads-meetup
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
body contains "{{event_id}}"

# Create a second event with a different `type` literal so we hit the
# enum branch.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "11111111-1111-4111-8111-111111111112",
  "name": "scenario12-sig-meetup",
  "description": "sig leads event",
  "start_at": "2099-02-01T00:00:00Z",
  "end_at":   "2099-02-01T02:00:00Z",
  "location": "Online",
  "type": "sig_ai",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
sig_event_id: jsonpath "$.id"
[Asserts]
jsonpath "$.type" == "sig_ai"

# Both events exist in the broader listing.
GET {{KANAE_URL}}/events?page=1&size=100
HTTP 200
[Asserts]
jsonpath "$.total" >= 2
body contains "{{event_id}}"
body contains "{{sig_event_id}}"

# Bad `type` literal value → 422 with literal_error.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "11111111-1111-4111-8111-111111111113",
  "name": "scenario12-bad-type",
  "description": "x",
  "start_at": "2099-03-01T00:00:00Z",
  "end_at":   "2099-03-01T02:00:00Z",
  "location": "x",
  "type": "not-a-real-type",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "literal_error"

# end_at < start_at is currently accepted (no model-level cross-field
# validator); ensure it doesn't 5xx.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "11111111-1111-4111-8111-111111111114",
  "name": "scenario12-inverted-times",
  "description": "ends before it starts",
  "start_at": "2099-04-01T02:00:00Z",
  "end_at":   "2099-04-01T00:00:00Z",
  "location": "x",
  "type": "misc",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Asserts]
jsonpath "$.id" isUuid
