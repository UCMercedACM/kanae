# Edge: kanae -> Postgres (database:5432 as the `kanae` role from the
# rendered postgres_uri). Proves the six rows init.sh upserted are the rows
# kanae reads, that a tag write round-trips through reads, that every
# paginated list bounds page and size before building the OFFSET (the
# largest accepted page is a bigint OFFSET Postgres answers with nothing),
# that int32 path ids are bounded, and that NUL bytes and oversized inputs are
# refused before they reach asyncpg or Kratos' identity table.
#
# The seeded rows are found by per-email directory queries: /members orders
# by created_at DESC, so the oldest rows fall off any fixed page once other
# files' leftovers pile up. Events and projects live in 11 and 12.
#
# Uses seeded ROOT; the one tag it creates is deleted. Derived from
# integration 05, 06, 09, 10, 20, 21 and 29.

# ── oversized and NUL inputs, before any session exists ──

# ── oversized identity trait, over the identity.schema.json maxLength ──────
GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{
  "method": "password",
  "csrf_token": "{{csrf}}",
  "password": "{{flow_id}}",
  "traits": {
    "email": "oversized-{{newUuid}}@hurl.test.local",
    "name": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  }
}
HTTP 400
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'traits.name')].messages[0].id" == 4000017
jsonpath "$.ui.nodes[?(@.attributes.name == 'traits.name')].messages[0].text" contains "length must be"

# About 2KB at an auth-gated route: auth still fires first regardless of body
# size, so a large body cannot skip the session dependency.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "BIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIGBIG", "description": "x" }
HTTP 401
[Asserts]
jsonpath "$.result" == "error"

# ── NUL byte through kanae's own query-string guard, via the Gateway ───────
GET {{KANAE_URL}}/tags?title=ok%00bad
HTTP 422
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

GET {{KANAE_URL}}/events?name=ok%00bad
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

GET {{KANAE_URL}}/projects?name=ok%00bad
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

# ── pagination bounds on the public lists ──

# ── /events (public) ──

GET {{KANAE_URL}}/events?page=0
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "0"

GET {{KANAE_URL}}/events?page=-1
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "-1"

GET {{KANAE_URL}}/events?page=2147483648
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "2147483648"

GET {{KANAE_URL}}/events?page=9223372036854775808
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "9223372036854775808"

GET {{KANAE_URL}}/events?size=0
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "size"
jsonpath "$.errors[0].input" == "0"

GET {{KANAE_URL}}/events?size=101
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "size"
jsonpath "$.errors[0].input" == "101"

GET {{KANAE_URL}}/events?size=abc
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "int_parsing"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "size"
jsonpath "$.errors[0].input" == "abc"

GET {{KANAE_URL}}/events?size=100
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.data" count <= 100
jsonpath "$.total" isInteger

# largest accepted page: OFFSET (2^31-2)*100 is past int32, so Postgres runs a bigint OFFSET and returns nothing
GET {{KANAE_URL}}/events?page=2147483647&size=100
HTTP 200
[Asserts]
jsonpath "$.data" count == 0
jsonpath "$.total" isInteger

# ── /projects (public) ──

GET {{KANAE_URL}}/projects?page=0
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "0"

GET {{KANAE_URL}}/projects?page=-1
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "-1"

GET {{KANAE_URL}}/projects?page=2147483648
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "2147483648"

GET {{KANAE_URL}}/projects?page=9223372036854775808
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "9223372036854775808"

GET {{KANAE_URL}}/projects?size=0
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "size"
jsonpath "$.errors[0].input" == "0"

GET {{KANAE_URL}}/projects?size=101
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "size"
jsonpath "$.errors[0].input" == "101"

GET {{KANAE_URL}}/projects?size=abc
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "int_parsing"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "size"
jsonpath "$.errors[0].input" == "abc"

GET {{KANAE_URL}}/projects?size=100
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.data" count <= 100
jsonpath "$.total" isInteger

# largest accepted page: OFFSET (2^31-2)*100 is past int32, so Postgres runs a bigint OFFSET and returns nothing
GET {{KANAE_URL}}/projects?page=2147483647&size=100
HTTP 200
[Asserts]
jsonpath "$.data" count == 0
jsonpath "$.total" isInteger

# ── root: the seeded rows ──

GET {{KANAE_URL}}/members?page=0
HTTP 401

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
[Asserts]
jsonpath "$.session.identity.id" == "{{ROOT_ID}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{ROOT_ID}}"
jsonpath "$.name" == "root"
jsonpath "$.created_at" isIsoDate

GET {{KANAE_URL}}/members?query={{ROOT_EMAIL}}
HTTP 200
[Asserts]
jsonpath "$.data[?(@.id == '{{ROOT_ID}}')].email" == "{{ROOT_EMAIL}}"

GET {{KANAE_URL}}/members?query={{ADMIN_EMAIL}}
HTTP 200
[Asserts]
jsonpath "$.data[?(@.id == '{{ADMIN_ID}}')].email" == "{{ADMIN_EMAIL}}"

GET {{KANAE_URL}}/members?query={{MANAGER_EMAIL}}
HTTP 200
[Asserts]
jsonpath "$.data[?(@.id == '{{MANAGER_ID}}')].email" == "{{MANAGER_EMAIL}}"

GET {{KANAE_URL}}/members?query={{LEADS_EMAIL}}
HTTP 200
[Asserts]
jsonpath "$.data[?(@.id == '{{LEADS_ID}}')].email" == "{{LEADS_EMAIL}}"

GET {{KANAE_URL}}/members?query={{MEMBER_EMAIL}}
HTTP 200
[Asserts]
jsonpath "$.data[?(@.id == '{{MEMBER_ID}}')].email" == "{{MEMBER_EMAIL}}"

GET {{KANAE_URL}}/members?query={{SCRATCH_EMAIL}}
HTTP 200
[Asserts]
jsonpath "$.data[?(@.id == '{{SCRATCH_ID}}')].email" == "{{SCRATCH_EMAIL}}"
jsonpath "$.data[?(@.id == '{{SCRATCH_ID}}')].display_name" == "scratch"

GET {{KANAE_URL}}/members?page=1&size=2
HTTP 200
[Asserts]
jsonpath "$.data" count == 2
jsonpath "$.total" >= 6

GET {{KANAE_URL}}/members/{{SCRATCH_ID}}
HTTP 200
[Asserts]
jsonpath "$.name" == "scratch"
jsonpath "$.projects" count == 0
jsonpath "$.events" count == 0

# The sudo_grants table is readable (root-only oversight route).
GET {{KANAE_URL}}/sudo/active
HTTP 200
[Asserts]
jsonpath "$" isCollection

# ── pagination bounds on the admin directory: auth runs first, then validation ──


GET {{KANAE_URL}}/members?page=0
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "0"

GET {{KANAE_URL}}/members?page=-1
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "-1"

GET {{KANAE_URL}}/members?page=2147483648
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "2147483648"

GET {{KANAE_URL}}/members?page=9223372036854775808
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "page"
jsonpath "$.errors[0].input" == "9223372036854775808"

GET {{KANAE_URL}}/members?size=0
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "size"
jsonpath "$.errors[0].input" == "0"

GET {{KANAE_URL}}/members?size=101
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "size"
jsonpath "$.errors[0].input" == "101"

GET {{KANAE_URL}}/members?size=abc
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "int_parsing"
jsonpath "$.errors[0].loc[0]" == "query"
jsonpath "$.errors[0].loc[1]" == "size"
jsonpath "$.errors[0].input" == "abc"

GET {{KANAE_URL}}/members?size=100
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.data" count <= 100
jsonpath "$.total" isInteger

# largest accepted page: OFFSET (2^31-2)*100 is past int32, so Postgres runs a bigint OFFSET and returns nothing
GET {{KANAE_URL}}/members?page=2147483647&size=100
HTTP 200
[Asserts]
jsonpath "$.data" count == 0
jsonpath "$.total" isInteger

# ── tags: insert, select, update, delete ──

POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "pg-{{newUuid}}", "description": "postgres round trip" }
HTTP 200
[Captures]
tag_id: jsonpath "$.id"
tag_title: jsonpath "$.title"
[Asserts]
jsonpath "$.id" isInteger
jsonpath "$.title" startsWith "pg-"

GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.id" == {{tag_id}}
jsonpath "$.title" == "{{tag_title}}"
jsonpath "$.description" == "postgres round trip"
jsonpath "$.in_use" == false

GET {{KANAE_URL}}/tags?title={{tag_title}}
HTTP 200
[Asserts]
jsonpath "$[?(@.id == {{tag_id}})].id" == {{tag_id}}

PUT {{KANAE_URL}}/tags/{{tag_id}}
Content-Type: application/json
{ "title": "{{tag_title}}-renamed", "description": "updated" }
HTTP 200
[Asserts]
jsonpath "$.title" == "{{tag_title}}-renamed"

GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.title" == "{{tag_title}}-renamed"
jsonpath "$.description" == "updated"

# A NUL byte never reaches Postgres: 422 from the pattern guard, not a 500.
PUT {{KANAE_URL}}/tags/{{tag_id}}
Content-Type: application/json
{ "title": "pg\u0000nul", "description": "x" }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "string_pattern_mismatch"

GET {{KANAE_URL}}/tags?title=pg%00nul
HTTP 422

DELETE {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 404

PUT {{KANAE_URL}}/tags/{{tag_id}}
Content-Type: application/json
{ "title": "ghost", "description": "no row" }
HTTP 404
[Asserts]
jsonpath "$.detail" == "Resource cannot be updated"

DELETE {{KANAE_URL}}/tags/{{tag_id}}
HTTP 404

# ── /tags/{id}: int32 path bounds ──
GET {{KANAE_URL}}/tags/0
HTTP 422
[Asserts]
jsonpath "$.errors[0].type" == "greater_than_equal"
jsonpath "$.errors[0].loc[1]" == "tag_id"

GET {{KANAE_URL}}/tags/2147483648
HTTP 422
[Asserts]
jsonpath "$.errors[0].type" == "less_than_equal"
jsonpath "$.errors[0].loc[1]" == "tag_id"

GET {{KANAE_URL}}/tags/2147483647
HTTP 404
[Asserts]
jsonpath "$.detail" == "Resource not found"

POST {{KANAE_URL}}/members/logout
HTTP 200
