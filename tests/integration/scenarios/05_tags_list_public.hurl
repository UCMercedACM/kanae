# /tags is public + list-shaped (no pagination wrapper). Pins the
# response contract (id is int, title/description are str), the
# Query-param guards (min_length, NUL pattern), and the tag_id bounds
# (1 ≤ id ≤ 2**31 - 1) on the single-tag endpoint.

GET {{KANAE_URL}}/tags
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$" isCollection
duration <= 3000

# Same with explicit Accept negotiation.
GET {{KANAE_URL}}/tags
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$" isCollection

# title with fewer than 3 chars → 422 (Query(min_length=3, pattern=NO_NULL)).
GET {{KANAE_URL}}/tags?title=py
HTTP 422
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.errors" isCollection
jsonpath "$.errors[*].type" contains "string_too_short"

GET {{KANAE_URL}}/tags?title=p
HTTP 422

GET {{KANAE_URL}}/tags?title=
HTTP 422

# Valid-shape title that won't match anything → 200 + empty array.
GET {{KANAE_URL}}/tags?title=zzz-no-such-tag-anywhere
HTTP 200
[Asserts]
jsonpath "$" isCollection

# Single-tag endpoint: unknown id → 404 with the documented error
# detail. The handler raises `NotFoundError` so the body shape matches
# `NotFoundResponse`.
GET {{KANAE_URL}}/tags/999999
HTTP 404
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" isString

# tag_id at exactly int32 max → 200 or 404 (no record), never 5xx.
GET {{KANAE_URL}}/tags/2147483647
HTTP 404

# tag_id at int32 max + 1 → 422 before asyncpg ever sees it.
GET {{KANAE_URL}}/tags/2147483648
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "less_than_equal"

# tag_id < 1 → 422.
GET {{KANAE_URL}}/tags/0
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "greater_than_equal"

GET {{KANAE_URL}}/tags/-5
HTTP 422

# Non-integer id → 422 with int_parsing.
GET {{KANAE_URL}}/tags/abc
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "int_parsing"

GET {{KANAE_URL}}/tags/1.5
HTTP 422

# Float-y / hex-y / dangerous-shape ids all 422 cleanly.
GET {{KANAE_URL}}/tags/0x1
HTTP 422
