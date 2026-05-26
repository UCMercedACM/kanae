# A plain MEMBER lacks Role.ADMIN and Role.LEADS, so has_any_role
# must 403 every event mutation. The body, no matter how valid, must
# never reach asyncpg. Covers create + edit (which gates on
# Event.edit) + delete (Event.own).

GET {{KRATOS_URL}}/self-service/login/browser
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

# Create — 403 even with an otherwise valid body.
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "22222222-2222-4222-8222-222222222222",
  "name": "scenario13-denied",
  "description": "should never insert",
  "start_at": "2099-01-01T00:00:00Z",
  "end_at":   "2099-01-01T01:00:00Z",
  "location": "nowhere",
  "type": "misc",
  "timezone": "UTC",
  "creator_id": "{{MEMBER_ID}}"
}
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" isString

# And the row was never created.
GET {{KANAE_URL}}/events/22222222-2222-4222-8222-222222222222
HTTP 404

# Edit on an arbitrary (non-existent) UUID — has_permissions(Event.edit)
# fires first, no Keto tuple → 403 regardless of whether the event
# exists. Permission check runs before the not-found check.
PUT {{KANAE_URL}}/events/22222222-2222-4222-8222-222222222222
Content-Type: application/json
{ "name": "x", "description": "x", "location": "x" }
HTTP 403

# Delete on the same — gates on Event.own → 403.
DELETE {{KANAE_URL}}/events/22222222-2222-4222-8222-222222222222
HTTP 403

# Member CAN join existing events (no role requirement); the join
# itself 404s only if the event doesn't exist, not 403.
POST {{KANAE_URL}}/events/22222222-2222-4222-8222-222222222222/join
HTTP 404

# Same with verify — gates on session, not role/permission, so a
# missing event 404s.
POST {{KANAE_URL}}/events/22222222-2222-4222-8222-222222222222/verify
Content-Type: application/json
{ "code": "abcd1234" }
HTTP 404

# Read paths are public — sanity that auth/role didn't break listing.
GET {{KANAE_URL}}/events
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
