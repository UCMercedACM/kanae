# Event journey for the seeded LEADS role. LEADS creates an event that is
# running now; kanae writes the row and the attendance code to Postgres and
# two tuples to Keto (owners: LEADS, editors: Role:leads#member). A newcomer
# signs up, is refused every organizer action by Keto, joins the event,
# checks in with the attendance code, and sees it in their events. LEADS
# reads the roster, clears the check-in, and deletes the event.
#
# Derived from integration 11, 12, 13, 22, 24 and 31, cut down to the
# requests that make kanae go to Keto or Postgres and come back with data
# another user wrote.

# ── LEADS creates an event that is on right now ──────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{LEADS_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{LEADS_ID}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{LEADS_ID}}"
jsonpath "$.roles" contains "leads"

# id and creator_id in the body are ignored: Postgres mints the id and the
# creator is whoever holds the session
POST {{KANAE_URL}}/events/create
Content-Type: application/json
[Options]
variable: tag={{newUuid}}
variable: email=e2e-11-attendee-{{tag}}@hurl.test.local
variable: password=E2e-Attendee-{{newUuid}}
{ "id": "00000000-0000-4000-8000-000000000009", "name": "e2e-11-event-{{tag}}", "description": "leads journey", "start_at": "2020-01-01T00:00:00Z", "end_at": "2099-12-31T23:00:00Z", "location": "Online", "type": "sig_swe", "timezone": "UTC", "creator_id": "{{MEMBER_ID}}" }
HTTP 200
[Captures]
eid: jsonpath "$.id"
[Asserts]
jsonpath "$.id" isUuid
jsonpath "$.id" != "00000000-0000-4000-8000-000000000009"
jsonpath "$.name" == "e2e-11-event-{{tag}}"
jsonpath "$.type" == "sig_swe"
jsonpath "$.creator_id" == "{{LEADS_ID}}"

# public reads, straight from Postgres
GET {{KANAE_URL}}/events/{{eid}}
HTTP 200
[Asserts]
jsonpath "$.name" == "e2e-11-event-{{tag}}"
jsonpath "$.timezone" == "UTC"
jsonpath "$.creator_id" == "{{LEADS_ID}}"
jsonpath "$.thumbnail" == null

GET {{KANAE_URL}}/events?name=e2e-11-event-{{tag}}
HTTP 200
[Asserts]
jsonpath "$.data[0].id" == "{{eid}}"

# organizer reads: allowed through the owners tuple kanae just wrote
GET {{KANAE_URL}}/events/{{eid}}/attendance-code
HTTP 200
[Captures]
code: jsonpath "$.code"
[Asserts]
jsonpath "$.code" matches "^[0-9A-Za-z]{8}$"

GET {{KANAE_URL}}/events/{{eid}}/attendance
HTTP 200
[Asserts]
jsonpath "$.total" == 0
jsonpath "$.data" count == 0

PUT {{KANAE_URL}}/events/{{eid}}
Content-Type: application/json
{ "name": "e2e-11-event-{{tag}}", "description": "leads journey, edited", "location": "Room 101" }
HTTP 200
[Asserts]
jsonpath "$.location" == "Room 101"
jsonpath "$.description" == "leads journey, edited"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── a newcomer signs up ──────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{password}}", "traits": { "email": "{{email}}", "name": "attendee-{{tag}}" } }
HTTP 200
[Captures]
aid: jsonpath "$.identity.id"

# ── Keto refuses every organizer action ──────────────────────────────────────
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{ "id": "00000000-0000-4000-8000-000000000009", "name": "e2e-11-denied-{{tag}}", "description": "never stored", "start_at": "2099-01-01T00:00:00Z", "end_at": "2099-01-01T01:00:00Z", "location": "Online", "type": "general", "timezone": "UTC" }
HTTP 403
[Asserts]
jsonpath "$.detail" == "You are missing at least one of the required roles: 'admin', 'leads'"

PUT {{KANAE_URL}}/events/{{eid}}
Content-Type: application/json
{ "name": "hijacked", "description": "hijacked", "location": "hijacked" }
HTTP 403
[Asserts]
jsonpath "$.detail" == "You are missing Event:edit permission(s) to access this resource."

DELETE {{KANAE_URL}}/events/{{eid}}
HTTP 403
[Asserts]
jsonpath "$.detail" == "You are missing Event:own permission(s) to access this resource."

GET {{KANAE_URL}}/events/{{eid}}/attendance-code
HTTP 403

GET {{KANAE_URL}}/events/{{eid}}/attendance
HTTP 403

# nothing changed
GET {{KANAE_URL}}/events/{{eid}}
HTTP 200
[Asserts]
jsonpath "$.name" == "e2e-11-event-{{tag}}"
jsonpath "$.location" == "Room 101"

GET {{KANAE_URL}}/events?name=e2e-11-denied-{{tag}}
HTTP 200
[Asserts]
body not contains "e2e-11-denied-{{tag}}"

# ── join ─────────────────────────────────────────────────────────────────────
GET {{KANAE_URL}}/members/me/events
HTTP 200
[Asserts]
jsonpath "$" count == 0

POST {{KANAE_URL}}/events/{{eid}}/join
HTTP 200

POST {{KANAE_URL}}/events/{{eid}}/join
HTTP 409
[Asserts]
jsonpath "$.detail" contains "already joined"

POST {{KANAE_URL}}/events/00000000-0000-4000-8000-000000000009/join
HTTP 404

GET {{KANAE_URL}}/members/me/events
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{eid}}"
jsonpath "$[0].location" == "Room 101"
jsonpath "$[0].creator_id" == "{{LEADS_ID}}"

GET {{KANAE_URL}}/members/me/events?planned=true&attended=false
HTTP 200
[Asserts]
jsonpath "$[0].id" == "{{eid}}"

GET {{KANAE_URL}}/members/me/events?attended=true
HTTP 200
[Asserts]
jsonpath "$" count == 0

# ── check in with the attendance code ────────────────────────────────────────
POST {{KANAE_URL}}/events/{{eid}}/verify
Content-Type: application/json
{ "code": "zzzzzzzz" }
HTTP 404
[Asserts]
jsonpath "$.detail" == "Unknown or invalid attendance code."

POST {{KANAE_URL}}/events/{{eid}}/verify
Content-Type: application/json
{ "code": "{{code}}9" }
HTTP 422

POST {{KANAE_URL}}/events/{{eid}}/verify
Content-Type: application/json
{ "code": "{{code}}" }
HTTP 200
[Asserts]
jsonpath "$.message" == "Successfully verified attendance!"

POST {{KANAE_URL}}/events/{{eid}}/verify
Content-Type: application/json
{ "code": "{{code}}" }
HTTP 409
[Asserts]
jsonpath "$.detail" == "Attendance was already recorded"

GET {{KANAE_URL}}/members/me/events?attended=true
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{eid}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.events" count == 1
jsonpath "$.events[0].id" == "{{eid}}"
jsonpath "$.events[0].creator_id" == "{{LEADS_ID}}"

GET {{KANAE_URL}}/members/{{aid}}
HTTP 200
[Asserts]
jsonpath "$.events[0].id" == "{{eid}}"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── ADMIN holds no tuple on the event, and reads it anyway ───────────────────
# Event creation writes only owners@creator and editors@Role:leads#member, so
# Keto says no for the seeded ADMIN. has_permissions lets Role.ADMIN through
# regardless (src/utils/checks.py), which is what integration 41 pins.
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ADMIN_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{ADMIN_ID}}"

GET {{KANAE_URL}}/events/{{eid}}/attendance
HTTP 200
[Asserts]
jsonpath "$.total" == 1
jsonpath "$.data[0].id" == "{{aid}}"
jsonpath "$.data[0].attended" == true

GET {{KANAE_URL}}/events/{{eid}}/attendance-code
HTTP 200
[Asserts]
jsonpath "$.code" == "{{code}}"

POST {{KANAE_URL}}/members/logout
HTTP 200

# MANAGER is neither admin nor leads: the same reads are refused.
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MANAGER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{MANAGER_ID}}"

GET {{KANAE_URL}}/events/{{eid}}/attendance
HTTP 403

GET {{KANAE_URL}}/events/{{eid}}/attendance-code
HTTP 403

DELETE {{KANAE_URL}}/events/{{eid}}/attendance/{{aid}}
HTTP 403

PUT {{KANAE_URL}}/events/{{eid}}
Content-Type: application/json
{ "name": "e2e-11-event-{{tag}}", "description": "manager was here", "location": "Nowhere" }
HTTP 403

DELETE {{KANAE_URL}}/events/{{eid}}
HTTP 403

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── LEADS reads the roster, clears the check-in, deletes the event ───────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{LEADS_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

GET {{KANAE_URL}}/events/{{eid}}/attendance
HTTP 200
[Asserts]
jsonpath "$.total" == 1
jsonpath "$.data[0].id" == "{{aid}}"
jsonpath "$.data[0].name" == "attendee-{{tag}}"
jsonpath "$.data[0].planned" == true
jsonpath "$.data[0].attended" == true

DELETE {{KANAE_URL}}/events/{{eid}}/attendance/{{aid}}
HTTP 200

GET {{KANAE_URL}}/events/{{eid}}/attendance
HTTP 200
[Asserts]
jsonpath "$.data[0].planned" == true
jsonpath "$.data[0].attended" == false

DELETE {{KANAE_URL}}/events/{{eid}}
HTTP 200

GET {{KANAE_URL}}/events/{{eid}}
HTTP 404

DELETE {{KANAE_URL}}/events/{{eid}}
HTTP 404

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── cleanup: the attendee's membership went with the event ───────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email}}", "password": "{{password}}", "csrf_token": "{{csrf}}" }
HTTP 200

GET {{KANAE_URL}}/members/me/events
HTTP 200
[Asserts]
jsonpath "$" count == 0

DELETE {{KANAE_URL}}/members/me
HTTP 200
