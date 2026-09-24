# Edge: kanae -> Keto. Read port 4466 for /relation-tuples/check (has_role,
# cached 60s per tuple in Valkey) and /relation-tuples (list_roles, uncached);
# write port 4467 for PUT/DELETE /admin/relation-tuples behind
# PUT /members/{id}/role. Keto is reachable from kanae only, so every proof
# goes through kanae. Proves that a fresh identity holds nothing, that the
# guards run before any Keto write, that each grant is visible at once through
# the uncached list and through a first-time check, that a revoke is visible
# through a first-time check, and that deleting a member purges it.
#
# Known bug: ValkeyCache._clear (src/utils/cache.py:465) does a single SCAN,
# so a grant or revoke can leave an already-cached check answer in place for
# up to 60s. Every gated call here is therefore the first one for its
# (role, subject) pair after the grant or revoke under test: nothing gated on
# a role is asked for K before that role's grant, and no admin gate is asked
# again after the admin revoke.
#
# K registers, root refresh-logs-in on top of it, and K's cookie is replayed
# explicitly at kanae, which reads the last cookie in the request. Root
# deletes K at the end. The seeded role matrix lives in 09. Derived from
# integration 07, 12, 16, 27, 28 and 29.

# ── a fresh identity holds no Role tuple ──

GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
[Options]
variable: k_email=e2e-08-keto-{{newUuid}}@hurl.test.local
{ "method": "password", "csrf_token": "{{csrf}}", "password": "Rk3!wZ9$hM6&tQ2p", "traits": { "email": "{{k_email}}", "name": "keto probe" } }
HTTP 200
[Captures]
k_id: jsonpath "$.identity.id"
k: cookie "ory_kratos_session"
k_sid: jsonpath "$.session.id"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{k_id}}"
jsonpath "$.roles" count == 0

# Reading one's own roles needs no role (the handler short-circuits on self).
GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

# ── root on top of K, in the same jar ──

GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
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
jsonpath "$.session.id" != "{{k_sid}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{ROOT_ID}}"
jsonpath "$.roles" contains "root"
jsonpath "$.roles" contains "admin"

# K's cookie is still its own session.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{k}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{k_id}}"

GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

GET {{KANAE_URL}}/members/00000000-0000-0000-0000-000000000000/roles
HTTP 404

# Guards that run before any Keto write.
PUT {{KANAE_URL}}/members/{{ROOT_ID}}/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 409

PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "root", "action": "grant" }
HTTP 422

PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "admin", "action": "toggle" }
HTTP 422

PUT {{KANAE_URL}}/members/00000000-0000-0000-0000-000000000000/role
Content-Type: application/json
{ "role": "admin", "action": "grant" }
HTTP 404

# The action and role enums are validated: a wrong role name and an empty
# body never reach Keto.
PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "superuser", "action": "grant" }
HTTP 422

PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{}
HTTP 422

GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

# ── manager: grant, revoke, and the revoke seen by a first-time check ──

PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "manager"

GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{k}}
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "manager"

PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "manager", "action": "revoke" }
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

# has_role(MANAGER) has never been asked for K, so this goes to Keto and
# finds the tuple gone.
POST {{KANAE_URL}}/projects/create
Content-Type: application/json
Cookie: ory_kratos_session={{k}}
{}
HTTP 403
[Asserts]
jsonpath "$.detail" contains "manager"

# Revoking a tuple that is not there is a 204 at Keto, so still 200 here.
PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "manager", "action": "revoke" }
HTTP 200

# ── admin: the grant seen by first-time checks ──

PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "admin", "action": "grant" }
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# list_roles is uncached: the tuple is read straight back from Keto.
GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "admin"

# has_role(ADMIN) has never been asked for K, so this goes to Keto.
GET {{KANAE_URL}}/members
Cookie: ory_kratos_session={{k}}
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" >= 6

GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{k}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{k_id}}"
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "admin"

# check_any(MANAGER, ADMIN): the admin arm now passes.
GET {{KANAE_URL}}/projects/invites
Cookie: ory_kratos_session={{k}}
HTTP 200
[Asserts]
jsonpath "$" isCollection

GET {{KANAE_URL}}/sudo
Cookie: ory_kratos_session={{k}}
HTTP 200
[Asserts]
jsonpath "$.active" == false

# Admin is not root: root-only and root-or-sudo routes stay closed.
GET {{KANAE_URL}}/sudo/audit
Cookie: ory_kratos_session={{k}}
HTTP 403

PUT {{KANAE_URL}}/members/{{SCRATCH_ID}}/role
Content-Type: application/json
Cookie: ory_kratos_session={{k}}
{ "role": "leads", "action": "grant" }
HTTP 403
[Asserts]
jsonpath "$.detail" == "All checks have failed"


# The admin directory also lets K read another member's roles now.
GET {{KANAE_URL}}/members/{{MANAGER_ID}}/roles
Cookie: ory_kratos_session={{k}}
HTTP 200
[Asserts]
jsonpath "$.roles" contains "manager"

# KNOWN BUG: a repeated grant is accepted and Keto stores a second identical
# tuple, so list_roles can echo ["admin", "admin"]. Only the set of role names
# is asserted.
PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "admin", "action": "grant" }
HTTP 200

GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" contains "admin"
jsonpath "$.roles" not contains "manager"
jsonpath "$.roles" not contains "leads"
jsonpath "$.roles" not contains "root"

# ── revoke admin: closed again at once ──

PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "admin", "action": "revoke" }
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

# One revoke cleared both copies. No admin gate is asked for K again: the
# check cached True above may survive the revoke (single-SCAN bug).

# ── leads: list only ──

PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "leads", "action": "grant" }
HTTP 200

GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "leads"

GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{k}}
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "leads"

# ── root deletes the member: members row, Kratos identity and Keto tuples go ──

DELETE {{KANAE_URL}}/members/{{k_id}}
HTTP 200
[Asserts]
jsonpath "$.message" == "okie dokie"

GET {{KANAE_URL}}/members/{{k_id}}
HTTP 404

GET {{KANAE_URL}}/members/{{k_id}}/roles
HTTP 404

PUT {{KANAE_URL}}/members/{{k_id}}/role
Content-Type: application/json
{ "role": "leads", "action": "grant" }
HTTP 404

DELETE {{KANAE_URL}}/members/{{k_id}}
HTTP 404

POST {{KANAE_URL}}/members/logout
HTTP 200

# Kratos-side truth: the purge also revoked K's session.
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
Cookie: ory_kratos_session={{k}}
HTTP 401
