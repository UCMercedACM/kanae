# /events/{id}/verify is the attendance-check route. LEADS creates an
# event whose start_at / end_at bracket "now" (2020 → 2099 keeps the
# window valid for any plausible test-run date), MEMBER joins, then
# every VerifyRequest validation path is exercised. The real
# attendance code is server-minted (hash stored in
# event_attendance_codes, the plaintext is only handed out at event
# time), so we don't test the 200 path here — only the validation
# and 404 paths, which is what the route's `responses=` declares
# anyway.
#
# /events/{id}/verify is rate-limited at `5/second`, far above the
# call volume here.

# --- LEADS creates an event whose window contains "now" ---
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
  "id": "25252525-2525-4525-8525-252525252525",
  "name": "scenario25-verify-event",
  "description": "always-in-window for verify testing",
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
[Asserts]
jsonpath "$.id" isUuid
jsonpath "$.start_at" isIsoDate
jsonpath "$.end_at" isIsoDate

# --- MEMBER joins (refresh=true; LEADS session in jar) ---
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

POST {{KANAE_URL}}/events/{{event_id}}/join
HTTP 200

# --- VerifyRequest validation matrix ---

# Missing `code` → 422 with the missing-field error.
POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
{}
HTTP 422
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.errors[*].loc[*]" contains "code"
jsonpath "$.errors[*].type" contains "missing"

# Empty string fails `_NO_NULL_REGEX = ^[^\x00]+$` (non-empty).
POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
{ "code": "" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# Wrong type for `code`.
POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
{ "code": 12345 }
HTTP 422

POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
{ "code": null }
HTTP 422

# Code > 8 chars → 422 from the `check_code_length` model_validator
# (raised as a value-error, surfaces as `value_error`).
POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
{ "code": "123456789" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "value_error"

POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
{ "code": "thisistoolong" }
HTTP 422

# Body is not JSON / not an object.
POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
"just a string"
HTTP 422

# Path-param malformed UUID → 422 from path validation.
POST {{KANAE_URL}}/events/not-a-uuid/verify
Content-Type: application/json
{ "code": "abcdef12" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "event_id"

# Valid-shape code that doesn't match any attendance_code in the DB
# → 404 (the route looks up the hash first, raises NotFoundError on
# miss). This is the documented 404 response shape.
POST {{KANAE_URL}}/events/{{event_id}}/verify
Content-Type: application/json
{ "code": "abcdef12" }
HTTP 404
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" isString

# Verify against a valid-but-nonexistent event id — still 404 because
# the code lookup doesn't join on event_id (it scans across all
# attendance_codes for the given prefix).
POST {{KANAE_URL}}/events/00000000-0000-4000-8000-000000000025/verify
Content-Type: application/json
{ "code": "wrongco" }
HTTP 404

# Unauthenticated verify must 401, not 404.
POST {{KANAE_URL}}/events/{{event_id}}/verify
Cookie: ory_kratos_session=
Content-Type: application/json
{ "code": "abcdef12" }
HTTP 401
