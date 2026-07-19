# Full CRUD walk over /tags as ROOT (the superuser fixture: tag create is
# admin-gated, edit/delete are root/sudo-gated) with every response shape and
# round-trip pinned. Exercises the role check, asyncpg upsert, the
# returning-* row → Pydantic round-trip, the 404 + custom-detail
# branch on edit-after-delete, and the no-implicit-sort order on
# /tags listing.

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

# Create — verify the returned row's shape exactly matches the request.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario07-rust", "description": "systems language" }
HTTP 200
[Captures]
tag_id: jsonpath "$.id"
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.id" isInteger
jsonpath "$.id" > 0
jsonpath "$.title" == "scenario07-rust"
jsonpath "$.description" == "systems language"

# Get-by-id round-trip. Now carries in_use (FullTags) — a freshly created,
# unattached tag is not in use.
GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.id" == {{tag_id}}
jsonpath "$.title" == "scenario07-rust"
jsonpath "$.description" == "systems language"
jsonpath "$.in_use" == false

# Listing reflects the new row and every row carries the in_use flag.
GET {{KANAE_URL}}/tags
HTTP 200
[Asserts]
jsonpath "$" isCollection
body contains "scenario07-rust"
jsonpath "$[0].in_use" isBoolean

# Filter by similarity returns at least one match.
GET {{KANAE_URL}}/tags?title=scenario07-rust
HTTP 200
[Asserts]
body contains "scenario07-rust"

# PUT — overwrite both fields.
PUT {{KANAE_URL}}/tags/{{tag_id}}
Content-Type: application/json
{ "title": "scenario07-rust-renamed", "description": "now with lifetimes" }
HTTP 200
[Asserts]
jsonpath "$.id" == {{tag_id}}
jsonpath "$.title" == "scenario07-rust-renamed"
jsonpath "$.description" == "now with lifetimes"

# Verify update persisted.
GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.title" == "scenario07-rust-renamed"

# Delete returns the documented {message: "ok"} shape.
DELETE {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# Subsequent GET → 404 with NotFoundResponse default detail.
GET {{KANAE_URL}}/tags/{{tag_id}}
HTTP 404
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" isString

# PUT on a now-gone id surfaces the explicit "cannot be updated"
# detail rather than the default not-found copy.
PUT {{KANAE_URL}}/tags/{{tag_id}}
Content-Type: application/json
{ "title": "ghost", "description": "no-row" }
HTTP 404
[Asserts]
jsonpath "$.detail" == "Resource cannot be updated"

# DELETE on a now-gone id → 404, no double-error.
DELETE {{KANAE_URL}}/tags/{{tag_id}}
HTTP 404
[Asserts]
jsonpath "$.result" == "error"

# Edge: very long description still round-trips.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario07-long-desc", "description": "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur" }
HTTP 200
[Asserts]
jsonpath "$.description" startsWith "lorem ipsum"
jsonpath "$.description" endsWith "pariatur"

# Edge: hyphens / dots / digits in title pass the NO_NULL pattern.
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario07-go.1.21", "description": "with dots and digits" }
HTTP 200
[Asserts]
jsonpath "$.title" == "scenario07-go.1.21"
