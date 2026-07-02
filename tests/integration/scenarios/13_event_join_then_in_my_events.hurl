# Multi-user cross-component chain. LEADS creates two events, MEMBER
# joins one of them, and we verify the full filter matrix on
# /members/me/events?planned=?&attended=?. Also covers the double-
# join 409 (UNIQUE on events_members PK) and the FK-violation 404 on
# join against a junk event id — both must roll back the explicit
# transaction cleanly.

# --- LEADS creates two events ---
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
  "id": "33333333-3333-4333-8333-333333333333",
  "name": "scenario14-joinable",
  "description": "joinable event",
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

POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "33333333-3333-4333-8333-333333333334",
  "name": "scenario14-other",
  "description": "another event member won't join",
  "start_at": "2099-07-01T00:00:00Z",
  "end_at":   "2099-07-01T03:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
other_event_id: jsonpath "$.id"

# --- MEMBER (refresh=true; the LEADS session cookie is in the jar) ---
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

# Join the first event.
POST {{KANAE_URL}}/events/{{event_id}}/join
HTTP 200
[Asserts]
jsonpath "$.message" isString
jsonpath "$.message" exists

# Second join on the same event → 409 (UNIQUE on events_members PK,
# transaction rolled back).
POST {{KANAE_URL}}/events/{{event_id}}/join
HTTP 409
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "already joined"

# Join a non-existent event → 404 (FK violation, transaction rolled
# back).
POST {{KANAE_URL}}/events/44444444-4444-4444-8444-444444444444/join
HTTP 404
[Asserts]
jsonpath "$.result" == "error"

# Join a malformed UUID → 422, never 500.
POST {{KANAE_URL}}/events/not-a-uuid/join
HTTP 422

# Filter matrix on /members/me/events.
GET {{KANAE_URL}}/members/me/events
HTTP 200
[Asserts]
jsonpath "$" isCollection
body contains "{{event_id}}"
body not contains "{{other_event_id}}"

GET {{KANAE_URL}}/members/me/events?planned=true
HTTP 200
[Asserts]
body contains "{{event_id}}"
body not contains "{{other_event_id}}"

# We joined but haven't been verified-attendance, so attended=true
# excludes our event.
GET {{KANAE_URL}}/members/me/events?attended=true
HTTP 200
[Asserts]
body not contains "{{event_id}}"

# Both filters set → true AND semantics. We RSVP'd (planned=true) but were
# never verified-attendance (attended=false), so requiring BOTH excludes the
# event. This is the regression guard for the old bug where the combined
# constraint was overwritten and degenerated to planned-only.
GET {{KANAE_URL}}/members/me/events?planned=true&attended=true
HTTP 200
[Asserts]
body not contains "{{event_id}}"

# planned=true AND attended=false → the RSVP'd-but-unattended event IS returned.
GET {{KANAE_URL}}/members/me/events?planned=true&attended=false
HTTP 200
[Asserts]
body contains "{{event_id}}"

# planned=false excludes our event (we DID plan); `false` is a real filter now,
# not treated as "unset".
GET {{KANAE_URL}}/members/me/events?planned=false
HTTP 200
[Asserts]
body not contains "{{event_id}}"
