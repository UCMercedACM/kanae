# Every user-supplied string that hits Postgres goes through
# `_NO_NULL_REGEX = ^[^\x00]+$`. NUL bytes must surface as 422 with
# the documented validation error shape, never bubble out as
# `CharacterNotInRepertoireError` 500. Three injection surfaces:
#   - JSON body fields (` ` escape)
#   - query-string params (URL-encoded `%00`)
#   - list-element strings (project `tags`)
# Hit across tags + events + projects routers so a regression in any
# one router's `_NO_NULL_REGEX` annotation stands out.

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ADMIN_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

# Body NUL in tag title (\u0000 is valid JSON; decodes to a literal
# 0x00; Pydantic then 422s on the pattern).
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario21\u0000nul", "description": "evil" }
HTTP 422
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"
jsonpath "$.errors[*].loc[*]" contains "title"

# Body NUL in tag description.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario21-ok-title", "description": "ev\u0000nul desc" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "description"

# NUL in a PUT body too.
PUT {{KANAE_URL}}/tags/1
Content-Type: application/json
{ "title": "ev\u0000nul", "description": "x" }
HTTP 422

# Query param NUL in /tags filter — pattern guard on
# Query(min_length=3, pattern=_NO_NULL_REGEX).
GET {{KANAE_URL}}/tags?title=ok%00bad
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# Same trap on /events list filter.
GET {{KANAE_URL}}/events?name=ok%00bad
HTTP 422

# And on /projects list filter.
GET {{KANAE_URL}}/projects?name=ok%00bad
HTTP 422

# NUL anywhere in the bulk-create batch fails the entire batch.
POST {{KANAE_URL}}/tags/bulk-create
Content-Type: application/json
[
  { "title": "scenario21-bulk-ok",  "description": "ok" },
  { "title": "scenario21-bulk\u0000nul", "description": "ev\u0000nul desc" }
]
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# Event body field NUL (location).
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "21212121-2121-4121-8121-212121212121",
  "name": "scenario21-event-nul",
  "description": "ok",
  "start_at": "2099-01-01T00:00:00Z",
  "end_at":   "2099-01-01T01:00:00Z",
  "location": "ev\u0000nul location",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{ADMIN_ID}}"
}
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "location"