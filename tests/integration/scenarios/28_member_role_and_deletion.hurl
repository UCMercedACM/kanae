# Sudo-gated member management: PUT /members/{id}/role + DELETE /members/{id}.
#
# Both routes gate on check_any(has_role(Role.ROOT), has_sudo()). Hurl can
# satisfy the ROOT branch (bootstrapped root identity) but not the sudo branch
# (needs a fresh AAL2/TOTP session), so this scenario covers the integration
# concerns hurl is uniquely good at: real Keto role gating (401/403), the
# self-modification guard (409), schema rejection of unassignable roles (422),
# the not-found path (404), and a net-zero ROOT grant→verify→revoke that drives
# the real Keto write path against a dedicated role-less `scratch` identity
# (SCRATCH_ID) — kept distinct from `member` so this mutation never races the
# role-less assertions other scenarios make about `member` under Hurl's
# parallel --test execution. The destructive delete + the /members/me
# self-service flow are covered end-to-end by scripts/test-flow.sh and the unit
# suite (tests/test_members.py), which can mint the sudo/AAL2 conditions hurl
# cannot.

# ── unauthenticated → 401 on every member-management route ────────────────────
PUT {{KANAE_URL}}/members/{{MEMBER_ID}}/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 401

DELETE {{KANAE_URL}}/members/{{MEMBER_ID}}
HTTP 401

DELETE {{KANAE_URL}}/members/me
HTTP 401

# ── MEMBER (no role tuple) → 403 on the sudo-gated routes ─────────────────────
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

PUT {{KANAE_URL}}/members/{{ADMIN_ID}}/role
Content-Type: application/json
{ "role": "leads", "action": "grant" }
HTTP 403

DELETE {{KANAE_URL}}/members/{{ADMIN_ID}}
HTTP 403

# ── ROOT: guards + net-zero grant→verify→revoke on MEMBER ─────────────────────
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

# self-modification refused (the guard runs before any Keto/DB work)
PUT {{KANAE_URL}}/members/{{ROOT_ID}}/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 409

DELETE {{KANAE_URL}}/members/{{ROOT_ID}}
HTTP 409

# unassignable role rejected at validation — "root" is not an AssignableRole
PUT {{KANAE_URL}}/members/{{MEMBER_ID}}/role
Content-Type: application/json
{ "role": "root", "action": "grant" }
HTTP 422

# unknown member → 404 (authorized, but no members row to act on)
PUT {{KANAE_URL}}/members/00000000-0000-0000-0000-000000000000/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 404

# unknown member DELETE → 404. Unlike the role-write 404 above (which stops at
# the existence check), this runs purge_member() → Keto's per-namespace tuple
# delete BEFORE the Postgres delete reports the missing row, so it's the
# cheapest assertion that exercises the real purge path. Regression guard: purge
# once issued a subject-only / undefined-namespace Keto delete that Keto 400'd,
# surfacing as a 502 here instead of a 404.
DELETE {{KANAE_URL}}/members/00000000-0000-0000-0000-000000000000
HTTP 404

# grant manager to SCRATCH → 200
PUT {{KANAE_URL}}/members/{{SCRATCH_ID}}/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 200

# the real Keto tuple now resolves (direct read, bypassing Kanae's cache)
GET {{KETO_READ_URL}}/relation-tuples/check?namespace=Role&object=manager&relation=member&subject_id={{SCRATCH_ID}}
HTTP 200
[Asserts]
jsonpath "$.allowed" == true

# revoke it again → 200, restoring SCRATCH to role-less
PUT {{KANAE_URL}}/members/{{SCRATCH_ID}}/role
Content-Type: application/json
{ "role": "manager", "action": "revoke" }
HTTP 200

# Keto's check endpoint signals the result via status: 200 allowed, 403 denied.
GET {{KETO_READ_URL}}/relation-tuples/check?namespace=Role&object=manager&relation=member&subject_id={{SCRATCH_ID}}
HTTP 403
[Asserts]
jsonpath "$.allowed" == false
