# /members/logout calls Kratos admin DELETE /admin/sessions/{id} AND
# invalidates Kanae's per-cookie whoami cache. Post-logout, the same
# cookie value must be rejected by Kratos on the next call, and Kanae
# must surface the rejection as 401 (not 500, not 200-stale-cache).

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{
  "method": "password",
  "identifier": "{{MEMBER_EMAIL}}",
  "password": "{{PASSWORD}}",
  "csrf_token": "{{csrf}}"
}
HTTP 200
[Captures]
session_id: jsonpath "$.session.id"
session_identity: jsonpath "$.session.identity.id"
[Asserts]
variable "session_id" isUuid
variable "session_identity" == "{{MEMBER_ID}}"

# Pre-logout sanity: cookie works.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"

# Warm the cache (verify it gets invalidated below).
GET {{KANAE_URL}}/members/me
HTTP 200

# Logout — Kanae responds 200 with a documented message.
POST {{KANAE_URL}}/members/logout
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.message" isString
jsonpath "$.message" exists

# Same cookie is still in the Hurl jar — but Kratos revoked the
# session, so /sessions/whoami 401s. Kanae's cache was invalidated by
# the logout handler so the 401 is fresh, not stale-200.
GET {{KANAE_URL}}/members/me
HTTP 401
[Asserts]
jsonpath "$.result" == "error"

# Other auth-gated routes also reject the same cookie.
GET {{KANAE_URL}}/members/me/projects
HTTP 401

GET {{KANAE_URL}}/members/me/events
HTTP 401

# Second logout against an already-dead session — auth dependency
# runs first and 401s before the limiter or the route body.
POST {{KANAE_URL}}/members/logout
HTTP 401
