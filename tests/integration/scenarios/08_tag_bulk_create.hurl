# /tags/bulk-create takes a JSON array and round-trips each row
# through fetchmany. Pins: response order = insertion order (no
# implicit sort), every row gets an integer id, and each created tag
# appears in the subsequent /tags listing.
#
# Rate-limit gotcha: the endpoint is `@router.limiter.limit("1/minute")`
# (very tight — bulk inserts are expensive and admin-only) and the
# limiter is per-IP, shared with every other scenario in the run.
# Only one successful bulk per minute, so this file fires exactly one
# happy-path POST and verifies it richly. The bulk-specific
# validation paths (empty array, missing field in element, NUL in any
# row) are exercised through the single-create variants in
# `10_tag_validation_errors.hurl`, which fail at Pydantic *before*
# the rate-limit decorator counts the request.

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ROOT_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

# Three-row bulk — verify exact response order matches request order,
# count, types, and that every row got a real SERIAL id.
POST {{KANAE_URL}}/tags/bulk-create
Content-Type: application/json
[
  { "title": "scenario09-alpha", "description": "first" },
  { "title": "scenario09-beta",  "description": "second" },
  { "title": "scenario09-gamma", "description": "third" }
]
HTTP 200
[Captures]
alpha_id: jsonpath "$[0].id"
beta_id: jsonpath "$[1].id"
gamma_id: jsonpath "$[2].id"
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$" isCollection
jsonpath "$" count == 3
jsonpath "$[0].title" == "scenario09-alpha"
jsonpath "$[0].description" == "first"
jsonpath "$[1].title" == "scenario09-beta"
jsonpath "$[1].description" == "second"
jsonpath "$[2].title" == "scenario09-gamma"
jsonpath "$[2].description" == "third"
jsonpath "$[0].id" isInteger
jsonpath "$[1].id" isInteger
jsonpath "$[2].id" isInteger
jsonpath "$[0].id" > 0
jsonpath "$[1].id" > {{alpha_id}}
jsonpath "$[2].id" > {{beta_id}}

# Cross-route consistency: every row is visible via GET /tags/{id}.
GET {{KANAE_URL}}/tags/{{alpha_id}}
HTTP 200
[Asserts]
jsonpath "$.id" == {{alpha_id}}
jsonpath "$.title" == "scenario09-alpha"

GET {{KANAE_URL}}/tags/{{beta_id}}
HTTP 200
[Asserts]
jsonpath "$.title" == "scenario09-beta"

GET {{KANAE_URL}}/tags/{{gamma_id}}
HTTP 200
[Asserts]
jsonpath "$.title" == "scenario09-gamma"

# All three appear in the public listing.
GET {{KANAE_URL}}/tags
HTTP 200
[Asserts]
jsonpath "$" isCollection
body contains "scenario09-alpha"
body contains "scenario09-beta"
body contains "scenario09-gamma"
