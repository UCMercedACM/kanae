# Member dashboard reads: GET /members (admin directory) + GET /members/{id}/roles.
#
# GET /members is admin-only and paginated (KanaePages: data + total), with a
# trigram/substring search over name/email. GET /members/{id}/roles is self-or-
# admin and reads the global roles straight from Keto.
#
# Bootstrapped state (tests/integration/init.sh): the members table holds
# root/admin/manager/leads/member, and Keto grants admin->admin, manager->manager,
# leads->leads, root->{root,admin}; member holds no role. No scenario ever grants
# `member` a role — scenario 28's grant/revoke targets a dedicated `scratch`
# identity instead — so the empty-set assertions below are stable even under
# Hurl's parallel --test execution.

# ── unauthenticated → 401 on both routes ──────────────────────────────────────
GET {{KANAE_URL}}/members
HTTP 401
[Asserts]
jsonpath "$.result" == "error"

GET {{KANAE_URL}}/members/{{MEMBER_ID}}/roles
HTTP 401

# ── MEMBER (no role tuple) ────────────────────────────────────────────────────
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

# the admin-only directory is forbidden to a role-less member
GET {{KANAE_URL}}/members
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# a member may read THEIR OWN roles (self branch, no admin needed) → empty set
GET {{KANAE_URL}}/members/{{MEMBER_ID}}/roles
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.roles" isCollection
jsonpath "$.roles" count == 0

# but reading someone else's roles without admin → 403
GET {{KANAE_URL}}/members/{{ADMIN_ID}}/roles
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# ── ADMIN ─────────────────────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
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

# the directory is a KanaePages payload listing the bootstrapped members
GET {{KANAE_URL}}/members
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.data" isCollection
jsonpath "$.total" >= 5
jsonpath "$.data[?(@.name == 'member')]" exists
jsonpath "$.data[?(@.email == '{{ADMIN_EMAIL}}')]" exists

# search narrows by name (trigram) or email (substring)
GET {{KANAE_URL}}/members?query=manager
HTTP 200
[Asserts]
jsonpath "$.data[?(@.name == 'manager')]" exists

# a query shorter than a trigram is rejected (min_length=3)
GET {{KANAE_URL}}/members?query=ab
HTTP 422
[Asserts]
jsonpath "$.result" == "error"

# admins may read anyone's roles; the bootstrapped admin holds exactly "admin"
GET {{KANAE_URL}}/members/{{ADMIN_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" contains "admin"

# manager holds exactly "manager"
GET {{KANAE_URL}}/members/{{MANAGER_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" contains "manager"

# admin reading a role-less member → empty set
GET {{KANAE_URL}}/members/{{MEMBER_ID}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" isCollection
jsonpath "$.roles" count == 0

# unknown member → 404 (authorized admin, but no members row to read)
GET {{KANAE_URL}}/members/00000000-0000-0000-0000-000000000000/roles
HTTP 404
[Asserts]
jsonpath "$.result" == "error"
