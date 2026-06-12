# Break-glass (sudo) gating + audit-oversight access control.
#
# The positive elevate path requires a fresh AAL2 (TOTP) session, which Hurl
# cannot produce (no TOTP code generator), so this scenario covers everything
# around it: role gating on status/elevate/revoke, the AAL2 step-up
# requirement on elevate, and the root-only access to the /sudo/active and
# /sudo/audit oversight endpoints. The actual elevate→audit-capture behaviour
# is covered by the unit suite (tests/test_sudo.py), which can mint an AAL2
# session via the fake Ory client.

# ── unauthenticated → 401 ─────────────────────────────────────────────────────
GET {{KANAE_URL}}/sudo
HTTP 401

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "smoke" }
HTTP 401

DELETE {{KANAE_URL}}/sudo/revoke
HTTP 401

# ── MEMBER: not an admin → 403 on every sudo op, not root → no oversight ──────
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

GET {{KANAE_URL}}/sudo
HTTP 403

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "smoke" }
HTTP 403

DELETE {{KANAE_URL}}/sudo/revoke
HTTP 403

GET {{KANAE_URL}}/sudo/active
HTTP 403

GET {{KANAE_URL}}/sudo/audit
HTTP 403

# ── ADMIN: status works; elevate needs AAL2; revoke idempotent; no oversight ──
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
[Asserts]
jsonpath "$.session.identity.id" == "{{ADMIN_ID}}"

GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false

# password login is aal1 → elevate demands a fresh aal2 step-up
POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "break glass attempt" }
HTTP 403
[Asserts]
header "X-Elevation-Flow" contains "aal2"

# the denied elevate left no active grant
GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false

# revoke is admin-gated and idempotent (no active grant to drop)
DELETE {{KANAE_URL}}/sudo/revoke
HTTP 200

# admin is not root → oversight endpoints denied
GET {{KANAE_URL}}/sudo/active
HTTP 403

GET {{KANAE_URL}}/sudo/audit
HTTP 403

# ── ROOT: oversight endpoints accessible ──────────────────────────────────────
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

GET {{KANAE_URL}}/sudo/active
HTTP 200
[Asserts]
jsonpath "$" count >= 0

GET {{KANAE_URL}}/sudo/audit
HTTP 200
[Asserts]
jsonpath "$" count >= 0
