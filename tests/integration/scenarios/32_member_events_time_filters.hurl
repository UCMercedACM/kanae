# /members/me/events time filters (G11). LEADS creates a clearly-future event;
# MEMBER joins it (allowed while end_at is in the future); ?upcoming=true then
# includes it, ?past=true excludes it, and supplying both at once is a 400.
#
# A past membership can't be created through the API (join_event rejects ended
# events), so the past branch is verified as an exclusion of the future event
# rather than an inclusion.

# --- LEADS creates a future event ---
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
  "id": "32323232-3232-4232-8232-323232323232",
  "name": "scenario32-future-event",
  "description": "upcoming/past filter target",
  "start_at": "2099-01-01T00:00:00Z",
  "end_at":   "2099-12-31T23:59:59Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
future_event_id: jsonpath "$.id"

# --- switch to MEMBER (refresh=true; LEADS session in jar) and join ---
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

POST {{KANAE_URL}}/events/{{future_event_id}}/join
HTTP 200

# ?upcoming=true → start_at > now → includes the future event.
GET {{KANAE_URL}}/members/me/events?upcoming=true
HTTP 200
[Asserts]
jsonpath "$" isCollection
body contains "{{future_event_id}}"

# ?past=true → end_at < now → excludes the future event.
GET {{KANAE_URL}}/members/me/events?past=true
HTTP 200
[Asserts]
jsonpath "$" isCollection
body not contains "{{future_event_id}}"

# Mutually exclusive → 400.
GET {{KANAE_URL}}/members/me/events?upcoming=true&past=true
HTTP 400
