# KanaeParams bounds: page in [1, 2**31-1], size in [1, 100].
# `to_raw_params()` computes `offset = (page - 1) * size` and that
# value is spliced into SQL as a literal `OFFSET <n>` — Postgres
# parses OFFSET as bigint, so unbounded page lets fuzz inputs trip
# `NumericValueOutOfRangeError`. Boundaries pinned across both
# paginated endpoints (events + projects) so a regression on one
# Annotated[int, Query(ge=…, le=…)] decoration on the shared
# KanaeParams stands out.

# --- /events boundaries ---

GET {{KANAE_URL}}/events?page=1&size=1
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" isInteger
jsonpath "$.total" >= 0

# page lower bound: 1 ok, 0 / -1 rejected.
GET {{KANAE_URL}}/events?page=0
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "greater_than_equal"

GET {{KANAE_URL}}/events?page=-1
HTTP 422

# size lower bound: 1 ok, 0 / -5 rejected.
GET {{KANAE_URL}}/events?size=1
HTTP 200

GET {{KANAE_URL}}/events?size=0
HTTP 422

GET {{KANAE_URL}}/events?size=-5
HTTP 422

# size upper bound: 100 ok, 101 rejected.
GET {{KANAE_URL}}/events?size=100
HTTP 200

GET {{KANAE_URL}}/events?size=101
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "less_than_equal"

# page upper bound: 2**31 - 1 ok (returns empty page), 2**31 rejected.
GET {{KANAE_URL}}/events?page=2147483647&size=100
HTTP 200
[Asserts]
jsonpath "$.data" count == 0

GET {{KANAE_URL}}/events?page=2147483648
HTTP 422

# Non-numeric values.
GET {{KANAE_URL}}/events?page=abc
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "int_parsing"

GET {{KANAE_URL}}/events?size=null
HTTP 422

GET {{KANAE_URL}}/events?page=1.5
HTTP 422

GET {{KANAE_URL}}/events?size=true
HTTP 422

# Combined: bad page + bad size → both errors surface.
GET {{KANAE_URL}}/events?page=0&size=0
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "page"
jsonpath "$.errors[*].loc[*]" contains "size"

# Combined with name filter — bounds still fire.
GET {{KANAE_URL}}/events?name=abc&page=0
HTTP 422

GET {{KANAE_URL}}/events?name=abc&size=101
HTTP 422

# --- /projects boundaries (same KanaeParams) ---

GET {{KANAE_URL}}/projects?page=1&size=1
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" isInteger

GET {{KANAE_URL}}/projects?page=0
HTTP 422

GET {{KANAE_URL}}/projects?size=0
HTTP 422

GET {{KANAE_URL}}/projects?size=101
HTTP 422

GET {{KANAE_URL}}/projects?page=2147483648
HTTP 422

# /projects also has since/until — clearly-invalid date inputs must
# 422 (not 500) at the param validation step. Note: Pydantic v2's
# `datetime` parser accepts bare integers as Unix timestamps, so
# `until=99999` parses fine (→ 1970-01-02T03:46:39Z, returns 200) —
# use a non-numeric, non-ISO string to actually exercise the
# rejection path.
GET {{KANAE_URL}}/projects?since=not-a-date
HTTP 422

GET {{KANAE_URL}}/projects?until=tomorrow
HTTP 422

GET {{KANAE_URL}}/projects?until=2024-13-99T00:00:00Z
HTTP 422

# since AND until together → 400 BadRequestError (route-level guard).
GET {{KANAE_URL}}/projects?since=2024-01-01T00:00:00Z&until=2025-01-01T00:00:00Z
HTTP 400
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "Cannot specify both"

# active filter accepts true/false; nonsense → 422.
GET {{KANAE_URL}}/projects?active=true
HTTP 200

GET {{KANAE_URL}}/projects?active=false
HTTP 200

GET {{KANAE_URL}}/projects?active=maybe
HTTP 422
