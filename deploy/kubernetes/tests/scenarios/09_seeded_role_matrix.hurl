# Role matrix: the five seeded identities against eleven role gates, one
# login each. Every answer comes from Keto (kanae -> keto:4466 check API),
# and the role list shown first comes from Keto's relation-tuple listing.
#
# The gated writes are sent with bodies that cannot be stored (empty
# objects, an unassignable role, a member id with no row). FastAPI runs the
# route's check dependencies before it rejects the body, so a caller the
# gate lets through gets 422 (or 404), and one it stops gets 403. That
# shows the allow side of each gate without writing anything, which keeps
# the matrix repeatable and leaves the seeded state alone.
#
#   gate                          root  admin  manager  leads  member
#   GET  /members                  200   200    403      403    403
#   GET  /sudo                     200   200    403      403    403
#   GET  /sudo/audit               *     403    403      403    403
#   GET  /projects/invites         200   200    200      403    403
#   GET  /members/{other}/roles    200   200    403      403    403
#   POST /events/create            422   422    403      422    403
#   POST /projects/create          403   403    422      403    403
#   POST /tags/create              422   422    403      403    403
#   POST /tags/bulk-create         422   403    403      403    403
#   PUT  /members/{id}/role        422   403    403      403    403
#   DELETE /members/{id}           404   403    403      403    403
#
# root is not a manager: projects/create checks has_role(MANAGER) alone.
# (* = past the gate; the audit handler itself 500s once any sudoer has been
# deleted, a known bug pinned only in 15.)
#
# Seeded roles are exact here because no file grants, revokes or deletes a
# seeded identity. Nothing is written. Derived from integration 07, 12, 16,
# 27, 28, 29 and 42.

# ── root ──────────────────────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
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
jsonpath "$.roles" contains "root"
jsonpath "$.roles" contains "admin"
jsonpath "$.roles" not contains "manager"
jsonpath "$.roles" not contains "leads"

# admin directory (has_role ADMIN)
GET {{KANAE_URL}}/members?size=1
HTTP 200

# sudo status (has_role ADMIN)
GET {{KANAE_URL}}/sudo
HTTP 200

# sudo audit (has_role ROOT). Only the gate is checked: past it the
# handler is a 500 once any sudoer has been deleted (see RATIONALE)
GET {{KANAE_URL}}/sudo/audit
HTTP *
[Asserts]
status != 401
status != 403

# all project invites (MANAGER or ADMIN)
GET {{KANAE_URL}}/projects/invites
HTTP 200

# another member's roles (ADMIN or self)
GET {{KANAE_URL}}/members/{{SCRATCH_ID}}/roles
HTTP 200

# create event (ADMIN or LEADS)
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{ }
HTTP 422

# create project (MANAGER only)
POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# create tag (ADMIN)
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ }
HTTP 422

# bulk-create tags (ROOT or sudo)
POST {{KANAE_URL}}/tags/bulk-create
Content-Type: application/json
{ }
HTTP 422

# change a role (ROOT or sudo); "root" is not assignable, so it never writes
PUT {{KANAE_URL}}/members/{{SCRATCH_ID}}/role
Content-Type: application/json
{ "role": "root", "action": "grant" }
HTTP 422

# delete a member (ROOT or sudo); the id has no row, so nothing is deleted
DELETE {{KANAE_URL}}/members/00000000-0000-4000-8000-000000000011
HTTP 404

# every seeded identity's tuples, as Keto lists them (uncached)
GET {{KANAE_URL}}/members/{{ADMIN_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "admin"

GET {{KANAE_URL}}/members/{{MANAGER_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "manager"

GET {{KANAE_URL}}/members/{{LEADS_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "leads"

GET {{KANAE_URL}}/members/{{MEMBER_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

GET {{KANAE_URL}}/members/{{SCRATCH_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

GET {{KANAE_URL}}/members/{{ROOT_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" contains "root"
jsonpath "$.roles" contains "admin"

# guards that run before any Keto write
PUT {{KANAE_URL}}/members/{{ROOT_ID}}/role
Content-Type: application/json
{ "role": "admin", "action": "grant" }
HTTP 409
[Asserts]
jsonpath "$.detail" contains "your own roles"

PUT {{KANAE_URL}}/members/{{SCRATCH_ID}}/role
Content-Type: application/json
{ "role": "admin", "action": "toggle" }
HTTP 422

PUT {{KANAE_URL}}/members/00000000-0000-0000-0000-000000000000/role
Content-Type: application/json
{ "role": "admin", "action": "grant" }
HTTP 404

GET {{KANAE_URL}}/members/00000000-0000-0000-0000-000000000000/roles
HTTP 404

# none of the guards touched SCRATCH
GET {{KANAE_URL}}/members/{{SCRATCH_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── admin ─────────────────────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ADMIN_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{ADMIN_ID}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{ADMIN_ID}}"
jsonpath "$.roles" contains "admin"
jsonpath "$.roles" not contains "root"
jsonpath "$.roles" not contains "manager"
jsonpath "$.roles" not contains "leads"

# admin directory (has_role ADMIN)
GET {{KANAE_URL}}/members?size=1
HTTP 200

# sudo status (has_role ADMIN)
GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false

# an aal1 admin passes the role gate but not the 2FA one: kanae points the
# browser at an aal2 refresh login instead
POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "aal1 admin trying to skip the step-up" }
HTTP 403
[Asserts]
header "X-Elevation-Flow" contains "aal=aal2"
header "X-Elevation-Flow" contains "refresh=true"

# the refused attempt granted nothing
GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false

# sudo audit (has_role ROOT)
GET {{KANAE_URL}}/sudo/audit
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# all project invites (MANAGER or ADMIN)
GET {{KANAE_URL}}/projects/invites
HTTP 200

# another member's roles (ADMIN or self)
GET {{KANAE_URL}}/members/{{SCRATCH_ID}}/roles
HTTP 200

# create event (ADMIN or LEADS)
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{ }
HTTP 422

# create project (MANAGER only)
POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# create tag (ADMIN)
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ }
HTTP 422

# bulk-create tags (ROOT or sudo)
POST {{KANAE_URL}}/tags/bulk-create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# change a role (ROOT or sudo); "root" is not assignable, so it never writes
PUT {{KANAE_URL}}/members/{{SCRATCH_ID}}/role
Content-Type: application/json
{ "role": "root", "action": "grant" }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# delete a member (ROOT or sudo); the id has no row, so nothing is deleted
DELETE {{KANAE_URL}}/members/00000000-0000-4000-8000-000000000011
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── manager ───────────────────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MANAGER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{MANAGER_ID}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MANAGER_ID}}"
jsonpath "$.roles" contains "manager"
jsonpath "$.roles" not contains "root"
jsonpath "$.roles" not contains "admin"
jsonpath "$.roles" not contains "leads"

# admin directory (has_role ADMIN)
GET {{KANAE_URL}}/members?size=1
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# sudo status (has_role ADMIN)
GET {{KANAE_URL}}/sudo
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# sudo audit (has_role ROOT)
GET {{KANAE_URL}}/sudo/audit
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# all project invites (MANAGER or ADMIN)
GET {{KANAE_URL}}/projects/invites
HTTP 200

# another member's roles (ADMIN or self)
GET {{KANAE_URL}}/members/{{SCRATCH_ID}}/roles
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# create event (ADMIN or LEADS)
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# create project (MANAGER only)
POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{ }
HTTP 422

# create tag (ADMIN)
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# bulk-create tags (ROOT or sudo)
POST {{KANAE_URL}}/tags/bulk-create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# change a role (ROOT or sudo); "root" is not assignable, so it never writes
PUT {{KANAE_URL}}/members/{{SCRATCH_ID}}/role
Content-Type: application/json
{ "role": "root", "action": "grant" }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# delete a member (ROOT or sudo); the id has no row, so nothing is deleted
DELETE {{KANAE_URL}}/members/00000000-0000-4000-8000-000000000011
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── leads ─────────────────────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{LEADS_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{LEADS_ID}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{LEADS_ID}}"
jsonpath "$.roles" contains "leads"
jsonpath "$.roles" not contains "root"
jsonpath "$.roles" not contains "manager"
jsonpath "$.roles" not contains "admin"

# admin directory (has_role ADMIN)
GET {{KANAE_URL}}/members?size=1
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# sudo status (has_role ADMIN)
GET {{KANAE_URL}}/sudo
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# sudo audit (has_role ROOT)
GET {{KANAE_URL}}/sudo/audit
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# all project invites (MANAGER or ADMIN)
GET {{KANAE_URL}}/projects/invites
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# another member's roles (ADMIN or self)
GET {{KANAE_URL}}/members/{{SCRATCH_ID}}/roles
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# create event (ADMIN or LEADS)
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{ }
HTTP 422

# create project (MANAGER only)
POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# create tag (ADMIN)
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# bulk-create tags (ROOT or sudo)
POST {{KANAE_URL}}/tags/bulk-create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# change a role (ROOT or sudo); "root" is not assignable, so it never writes
PUT {{KANAE_URL}}/members/{{SCRATCH_ID}}/role
Content-Type: application/json
{ "role": "root", "action": "grant" }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# delete a member (ROOT or sudo); the id has no row, so nothing is deleted
DELETE {{KANAE_URL}}/members/00000000-0000-4000-8000-000000000011
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── member ────────────────────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MEMBER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{MEMBER_ID}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"
jsonpath "$.roles" count == 0

# admin directory (has_role ADMIN)
GET {{KANAE_URL}}/members?size=1
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "admin"

# sudo status (has_role ADMIN)
GET {{KANAE_URL}}/sudo
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "no role" }
HTTP 403
[Asserts]
jsonpath "$.detail" contains "admin"
header "X-Elevation-Flow" not exists

# sudo audit (has_role ROOT)
GET {{KANAE_URL}}/sudo/audit
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# all project invites (MANAGER or ADMIN): check_any reports that every arm failed
GET {{KANAE_URL}}/projects/invites
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" == "All checks have failed"

# another member's roles (ADMIN or self)
GET {{KANAE_URL}}/members/{{ADMIN_ID}}/roles
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" == "Only an admin may read another member's roles"

GET {{KANAE_URL}}/members/{{SCRATCH_ID}}/roles
HTTP 403
[Asserts]
jsonpath "$.detail" == "Only an admin may read another member's roles"

# one's own roles need no role
GET {{KANAE_URL}}/members/{{MEMBER_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

# create event (ADMIN or LEADS)
POST {{KANAE_URL}}/events/create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" == "You are missing at least one of the required roles: 'admin', 'leads'"

# create project (MANAGER only)
POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" contains "manager"

# create tag (ADMIN)
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# bulk-create tags (ROOT or sudo)
POST {{KANAE_URL}}/tags/bulk-create
Content-Type: application/json
{ }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# change a role (ROOT or sudo); "root" is not assignable, so it never writes
PUT {{KANAE_URL}}/members/{{SCRATCH_ID}}/role
Content-Type: application/json
{ "role": "root", "action": "grant" }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" == "All checks have failed"

# delete a member (ROOT or sudo); the id has no row, so nothing is deleted
DELETE {{KANAE_URL}}/members/00000000-0000-4000-8000-000000000011
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

POST {{KANAE_URL}}/members/logout
HTTP 200
