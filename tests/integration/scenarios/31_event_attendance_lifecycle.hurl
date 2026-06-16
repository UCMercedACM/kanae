# Attendance lifecycle as the LEADS creator (auto-owns → Event.edit):
#   organizer reads the code (G7) → creator joins → roster (G5) →
#   verify happy-path (now possible because G7 hands out the code) →
#   verify again → 409 already-recorded (G13 idempotency) →
#   a valid code against a DIFFERENT event → 403 (argon2 mismatch, caught
#   by the global VerificationError handler) → undo the check-in (G12).
#
# Event window 2020 → 2099 brackets "now" on any plausible run date (same
# trick as scenario 24), keeping verify inside its [start-1h, end] window.

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

# Event A — the one we exercise fully.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "31313131-3131-4131-8131-313131313131",
  "name": "scenario31-attendance",
  "description": "attendance lifecycle",
  "start_at": "2020-01-01T00:00:00Z",
  "end_at":   "2099-12-31T23:59:59Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
event_id: jsonpath "$.id"

# Event B — only used to prove a valid code for A is rejected against B.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "31313131-3131-4131-8131-313131313132",
  "name": "scenario31-other",
  "description": "wrong-event target",
  "start_at": "2020-01-01T00:00:00Z",
  "end_at":   "2099-12-31T23:59:59Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
other_event_id: jsonpath "$.id"

# G7: organizer reads the attendance code (first 8 chars).
GET {{KANAE_URL}}/events/{{event_id}}/attendance-code
HTTP 200
[Captures]
code: jsonpath "$.code"
[Asserts]
jsonpath "$.code" isString

# Creator RSVPs so the roster has an entry.
POST {{KANAE_URL}}/events/{{event_id}}/join
HTTP 200

# G5: roster contains the creator (only member so far).
GET {{KANAE_URL}}/events/{{event_id}}/attendance
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" == 1
body contains "{{LEADS_ID}}"

# G13: verify happy path using the code from G7.
POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
{ "code": "{{code}}" }
HTTP 200
[Asserts]
jsonpath "$.message" == "Successfully verified attendance!"

# G13: verifying again is now a 409 (already recorded), not a silent re-success.
POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
{ "code": "{{code}}" }
HTTP 409

# G13: event A's code against event B → argon2 mismatch → global handler 403.
POST {{KANAE_URL}}/events/{{other_event_id}}/verify
Content-Type: application/json
{ "code": "{{code}}" }
HTTP 403

# G12: undo the check-in (flips attended → false, keeps the RSVP).
DELETE {{KANAE_URL}}/events/{{event_id}}/attendance/{{LEADS_ID}}
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# G12: removing a member with no attendance row → 404.
DELETE {{KANAE_URL}}/events/{{event_id}}/attendance/00000000-0000-4000-8000-000000000031
HTTP 404
