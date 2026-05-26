# /events is public + KanaePages-shaped + pg_trgm-filtered. Pins:
# pagination contract ({data, total}), the int_parsing + bound guards
# on page/size, the NO_NULL pattern on `name`, and the single-event
# 404/422 paths.

GET {{KANAE_URL}}/events
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.data" isCollection
jsonpath "$.total" isInteger
jsonpath "$.total" >= 0
duration <= 3000

# Explicit pagination.
GET {{KANAE_URL}}/events?page=1&size=10
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" isInteger

GET {{KANAE_URL}}/events?page=1&size=1
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" isInteger

# Empty-result page (way past the end).
GET {{KANAE_URL}}/events?page=999999&size=50
HTTP 200
[Asserts]
jsonpath "$.data" count == 0
jsonpath "$.total" isInteger

# Bound guards.
GET {{KANAE_URL}}/events?page=0
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "greater_than_equal"

GET {{KANAE_URL}}/events?size=0
HTTP 422

GET {{KANAE_URL}}/events?size=101
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "less_than_equal"

GET {{KANAE_URL}}/events?page=-1
HTTP 422

GET {{KANAE_URL}}/events?page=abc
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "int_parsing"

GET {{KANAE_URL}}/events?size=null
HTTP 422

# Name filter guards.
GET {{KANAE_URL}}/events?name=ab
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_too_short"

GET {{KANAE_URL}}/events?name=
HTTP 422

# Name with valid shape that won't match anything → 200 + empty page.
GET {{KANAE_URL}}/events?name=zzz-no-event-anywhere-xyz
HTTP 200
[Asserts]
jsonpath "$.data" isCollection

# Single-event endpoint.
GET {{KANAE_URL}}/events/00000000-0000-0000-0000-000000000000
HTTP 404
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" isString

# Malformed UUID → 422 before asyncpg sees it.
GET {{KANAE_URL}}/events/not-a-uuid
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "event_id"

GET {{KANAE_URL}}/events/12345
HTTP 422

# UUID with trailing junk.
GET {{KANAE_URL}}/events/00000000-0000-0000-0000-000000000000-extra
HTTP 422

# UUID with wrong group sizes.
GET {{KANAE_URL}}/events/0000-0000-0000-0000-0000-0000-0000-0000
HTTP 422
