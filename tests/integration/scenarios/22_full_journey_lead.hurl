# Full lead journey across every read/write path their session
# touches: login → /members/me → POST /events/create → public listing
# reflects it → GET /events/{id} → POST /events/{id}/join → /members/me
# /events?planned=true reflects the join. One scenario, many endpoints,
# verifies the data they create flows back through every route a real
# user would actually open.

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

# /members/me reflects the leads identity (bootstrap-seeded row).
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{LEADS_ID}}"
jsonpath "$.name" == "leads"

# Create an event.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "name": "scenario23-journey-event",
  "description": "Created by leads",
  "start_at": "2099-09-01T00:00:00Z",
  "end_at":   "2099-09-01T02:00:00Z",
  "location": "Test Hall",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
event_id: jsonpath "$.id"

# Visible in the public listing (pg_trgm name filter).
GET {{KANAE_URL}}/events?name=scenario23-journey-event
HTTP 200
[Asserts]
body contains "{{event_id}}"

# Single-event lookup returns creator_id + timezone.
GET {{KANAE_URL}}/events/{{event_id}}
HTTP 200
[Asserts]
jsonpath "$.creator_id" == "{{LEADS_ID}}"
jsonpath "$.timezone" == "UTC"

# Lead joins their own event.
POST {{KANAE_URL}}/events/{{event_id}}/join
HTTP 200

# Reflected in their /members/me/events?planned=true slice.
GET {{KANAE_URL}}/members/me/events?planned=true
HTTP 200
[Asserts]
body contains "{{event_id}}"
