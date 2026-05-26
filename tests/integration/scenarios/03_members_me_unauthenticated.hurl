# Every auth-gated route must hard-fail with 401 when no valid cookie
# is present. No login dance — exercises the use_session dependency's
# missing/invalid-cookie branches across every router.

# --- truly empty jar → 401 with documented error shape ---
GET {{KANAE_URL}}/members/me
HTTP 401
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.result" == "error"
jsonpath "$.detail" isString
jsonpath "$.detail" matches "Authentication required|Unauthorized|not authenticated"

GET {{KANAE_URL}}/members/me/projects
HTTP 401
[Asserts]
jsonpath "$.result" == "error"

GET {{KANAE_URL}}/members/me/events
HTTP 401

GET {{KANAE_URL}}/members/me/events?planned=true&attended=true
HTTP 401

POST {{KANAE_URL}}/members/logout
HTTP 401

# Auth-gated mutations on tags/events/projects must also 401, not
# 422/403 (auth runs before role checks via Depends ordering).
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "should-401", "description": "x" }
HTTP 401

POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "00000000-0000-4000-8000-000000000004",
  "name": "n", "description": "d",
  "start_at": "2099-01-01T00:00:00Z", "end_at": "2099-01-01T01:00:00Z",
  "location": "x", "type": "general", "timezone": "UTC",
  "creator_id": "00000000-0000-4000-8000-000000000004"
}
HTTP 401

POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{
  "name": "n", "description": "d", "link": "https://example.test/",
  "type": "independent", "active": true,
  "founded_at": "2024-01-01T00:00:00Z"
}
HTTP 401

# Garbage cookie value → Kratos /sessions/whoami rejects → 401.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session=not-a-real-cookie-value
HTTP 401
[Asserts]
jsonpath "$.result" == "error"

# Empty cookie value — Kanae checks `if cookie` before forwarding;
# empty string is falsy → goes straight to UnauthorizedError.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session=
HTTP 401

# Well-formed-looking but not actually a Kratos cookie.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session=MTIzNDU2Nzg5MGFiY2RlZi5mYWtlLnNpZ25hdHVyZQ==
HTTP 401

# Public routes still work without auth — sanity that the 401s above
# are *targeted* and not a global outage.
GET {{KANAE_URL}}/tags
HTTP 200

GET {{KANAE_URL}}/events
HTTP 200

GET {{KANAE_URL}}/projects
HTTP 200
