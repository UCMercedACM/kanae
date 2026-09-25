# Promotion and break-glass journey. A new member enrolls backup codes, root
# promotes them to admin (kanae -> Keto write), they step up to aal2 and
# elevate to sudo (kanae -> Postgres sudo_grants + sudo_audit), use sudo on
# the has_sudo-gated member and tag routes against rows this file created,
# revoke sudo, and watch the gate close again. Root then reads the live grant
# from sudo_grants, removes the admin, and reads the audit trail.
#
# Every gate is checked closed before it is checked open:
#   not admin            -> elevate 403 (Keto says no; shown on the target)
#   admin, aal1          -> elevate 403 with the step-up flow (root)
#   admin, no sudo       -> PUT /members/{id}/role 403 (check_any fails)
#   admin, sudo          -> 200, and Keto holds the new tuple
#   admin, sudo revoked  -> 403 again, Keto unchanged
#
# Known bug: ValkeyCache._clear (src/utils/cache.py:465) does a single SCAN,
# so the sudoer asks no admin-gated question before root promotes it; the
# role-less target shows those refusals instead.
#
# Derived from integration 27, 28 and 29.

# ── no session, no sudo ──────────────────────────────────────────────────────
GET {{KANAE_URL}}/sudo
HTTP 401

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "anonymous" }
HTTP 401

DELETE {{KANAE_URL}}/sudo/revoke
HTTP 401

GET {{KANAE_URL}}/sudo/active
HTTP 401

# ── the target: a plain member the sudoer will act on ────────────────────────
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
variable: tag={{newUuid}}
variable: target_email=e2e-15-target-{{tag}}@hurl.test.local
variable: target_pw=E2e-15-Target-{{newUuid}}
variable: sudoer_email=e2e-15-sudoer-{{tag}}@hurl.test.local
variable: sudoer_pw=E2e-15-Sudoer-{{newUuid}}
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{target_pw}}", "traits": { "email": "{{target_email}}", "name": "e2e-15-target-{{tag}}" } }
HTTP 200
[Captures]
tid: jsonpath "$.identity.id"

# a member with no role: every sudo door is shut, by Keto
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{tid}}"
jsonpath "$.roles" count == 0

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "no role {{tag}}" }
HTTP 403
[Asserts]
jsonpath "$.detail" contains "admin"
header "X-Elevation-Flow" not exists

GET {{KANAE_URL}}/sudo
HTTP 403

GET {{KANAE_URL}}/members/{{ROOT_ID}}/roles
HTTP 403
[Asserts]
jsonpath "$.detail" == "Only an admin may read another member's roles"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── the sudoer signs up and enrolls backup codes ─────────────────────────────
GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{sudoer_pw}}", "traits": { "email": "{{sudoer_email}}", "name": "e2e-15-sudoer-{{tag}}" } }
HTTP 200
[Captures]
uid: jsonpath "$.identity.id"
[Asserts]
jsonpath "$.identity.id" != "{{tid}}"
jsonpath "$.session.authenticator_assurance_level" == "aal1"

GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 200
[Captures]
sflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_regenerate')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'totp_code')]" exists

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret_regenerate": true, "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
code0: jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets[0].context.secret"
code1: jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets[1].context.secret"
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets" count == 12

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.authenticator_assurance_level" == "aal1"

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret_confirm": true, "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.state" == "success"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.identity.id" == "{{uid}}"
jsonpath "$.authenticator_assurance_level" == "aal2"
jsonpath "$.authentication_methods[*].method" contains "lookup_secret"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.session.aal" == "aal2"
jsonpath "$.roles" count == 0

# aal2 but not root and no sudo. check_any(has_role(ROOT), has_sudo()) asks
# nothing of the admin role, so this does not poison the promotion below.
PUT {{KANAE_URL}}/members/{{tid}}/role
Content-Type: application/json
{ "role": "leads", "action": "grant" }
HTTP 403
[Asserts]
jsonpath "$.detail" == "All checks have failed"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── root promotes the sudoer to admin ────────────────────────────────────────
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
jsonpath "$.session.authenticator_assurance_level" == "aal1"

GET {{KANAE_URL}}/members/{{uid}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

# Root is also admin, but its password session is aal1, so elevate points at
# the step-up flow.
# KNOWN BUG: the header is a bare Kratos path without the /auth prefix, so
# behind this Gateway it lands on kanae; reported separately.
POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "root at aal1 {{tag}}" }
HTTP 403
[Asserts]
jsonpath "$.detail" == "2fa re-authentication required"
header "X-Elevation-Flow" contains "aal=aal2"
header "X-Elevation-Flow" contains "refresh=true"

GET {{KRATOS_URL}}/self-service/login/browser?aal=aal2&refresh=true
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.requested_aal" == "aal2"
jsonpath "$.refresh" == true

GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false

# root's arm of check_any(has_role(ROOT), has_sudo()): no sudo needed
PUT {{KANAE_URL}}/members/{{uid}}/role
Content-Type: application/json
{ "role": "admin", "action": "grant" }
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# list_roles reads Keto uncached, so the tuple shows at once
GET {{KANAE_URL}}/members/{{uid}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "admin"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── the new admin logs in: password, then the aal2 step-up ───────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{sudoer_email}}", "password": "{{sudoer_pw}}", "csrf_token": "{{csrf}}" }
HTTP 422
[Asserts]
jsonpath "$.error.id" == "browser_location_change_required"
jsonpath "$.redirect_browser_to" == "https://kanae/auth/self-service/login/browser?aal=aal2"
cookie "ory_kratos_session" exists

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 403
[Asserts]
jsonpath "$.error.id" == "session_aal2_required"

# the half-finished session is invisible to kanae, admin or not
GET {{KANAE_URL}}/members/me
HTTP 401
[Asserts]
jsonpath "$.detail" == "Authentication required"
header "X-Elevation-Flow" not exists

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "aal1 attempt {{tag}}" }
HTTP 401

GET {{KRATOS_URL}}/self-service/login/browser?aal=aal2
Accept: application/json
HTTP 200
[Captures]
aflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.requested_aal" == "aal2"
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')]" not exists

POST {{KRATOS_URL}}/self-service/login?flow={{aflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret": "not-a-code", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000016

POST {{KRATOS_URL}}/self-service/login?flow={{aflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret": "{{code0}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{uid}}"
jsonpath "$.session.authenticator_assurance_level" == "aal2"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.session.aal" == "aal2"
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "admin"

# ── admin without sudo ───────────────────────────────────────────────────────
GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false
jsonpath "$.expires_at" == null

# admin reads: the directory and other members' roles. The name trigram
# also matches the sudoer (same tag), so pick the target out by id.
GET {{KANAE_URL}}/members?query=e2e-15-target-{{tag}}
HTTP 200
[Asserts]
jsonpath "$.total" >= 1
jsonpath "$.data[?(@.id == '{{tid}}')].email" == "{{target_email}}"
jsonpath "$.data[?(@.id == '{{tid}}')].name" == "e2e-15-target-{{tag}}"

GET {{KANAE_URL}}/members/{{tid}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 0

# the oversight endpoints stay root-only
GET {{KANAE_URL}}/sudo/active
HTTP 403

GET {{KANAE_URL}}/sudo/audit
HTTP 403

# admin alone does not open the has_sudo routes
PUT {{KANAE_URL}}/members/{{tid}}/role
Content-Type: application/json
{ "role": "leads", "action": "grant" }
HTTP 403
[Asserts]
jsonpath "$.detail" == "All checks have failed"

DELETE {{KANAE_URL}}/members/{{tid}}
HTTP 403

# ── elevate ──────────────────────────────────────────────────────────────────
POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "" }
HTTP 422

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ }
HTTP 422

# the failed attempts granted nothing
GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "e2e-15 grant one {{tag}}" }
HTTP 200
[Captures]
expires_one: jsonpath "$.expires_at"
[Asserts]
jsonpath "$.active" == true
jsonpath "$.expires_at" isIsoDate

GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == true
jsonpath "$.expires_at" == "{{expires_one}}"

# sudo is not root: the oversight routes are still closed
GET {{KANAE_URL}}/sudo/active
HTTP 403

GET {{KANAE_URL}}/sudo/audit
HTTP 403

# ── use sudo on the target ───────────────────────────────────────────────────
PUT {{KANAE_URL}}/members/{{tid}}/role
Content-Type: application/json
{ "role": "leads", "action": "grant" }
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

GET {{KANAE_URL}}/members/{{tid}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "leads"

# tag create is admin; edits and deletes are root-or-sudo
POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "e2e-15-tag-{{newUuid}}", "description": "made under sudo" }
HTTP 200
[Captures]
tag_id: jsonpath "$.id"

PUT {{KANAE_URL}}/tags/{{tag_id}}
Content-Type: application/json
{ "title": "e2e-15-tag-renamed-{{newUuid}}", "description": "renamed under sudo" }
HTTP 200
[Asserts]
jsonpath "$.description" == "renamed under sudo"

DELETE {{KANAE_URL}}/tags/{{tag_id}}
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# past the gate, the handler's own guards still hold
PUT {{KANAE_URL}}/members/{{uid}}/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 409

PUT {{KANAE_URL}}/members/{{tid}}/role
Content-Type: application/json
{ "role": "root", "action": "grant" }
HTTP 422

PUT {{KANAE_URL}}/members/00000000-0000-4000-8000-000000000000/role
Content-Type: application/json
{ "role": "leads", "action": "grant" }
HTTP 404

DELETE {{KANAE_URL}}/members/{{uid}}
HTTP 409
[Asserts]
jsonpath "$.detail" contains "/members/me"

# ── revoke: the gate closes again ────────────────────────────────────────────
DELETE {{KANAE_URL}}/sudo/revoke
HTTP 200
[Asserts]
jsonpath "$.message" == "Sudo access revoked"

GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false

PUT {{KANAE_URL}}/members/{{tid}}/role
Content-Type: application/json
{ "role": "leads", "action": "revoke" }
HTTP 403

GET {{KANAE_URL}}/members/{{tid}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "leads"

# revoking with nothing to revoke is fine
DELETE {{KANAE_URL}}/sudo/revoke
HTTP 200

# ── elevate once more and delete the target ──────────────────────────────────
POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "e2e-15 grant two {{tag}}" }
HTTP 200
[Asserts]
jsonpath "$.active" == true

DELETE {{KANAE_URL}}/members/{{tid}}
HTTP 200
[Asserts]
jsonpath "$.message" == "okie dokie"

GET {{KANAE_URL}}/members/{{tid}}
HTTP 404

GET {{KANAE_URL}}/members/{{tid}}/roles
HTTP 404

DELETE {{KANAE_URL}}/members/{{tid}}
HTTP 404

# ── a spent code is dead on a re-auth; an unused one still works ─────────────
GET {{KRATOS_URL}}/self-service/login/browser?aal=aal2&refresh=true
Accept: application/json
HTTP 200
[Captures]
aflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.refresh" == true

POST {{KRATOS_URL}}/self-service/login?flow={{aflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret": "{{code0}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000012
jsonpath "$.ui.messages[0].text" == "This backup recovery code has already been used."

POST {{KRATOS_URL}}/self-service/login?flow={{aflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret": "{{code1}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{uid}}"
jsonpath "$.session.authenticator_assurance_level" == "aal2"

# the grant survives the re-auth: it is a Postgres row, not session state
GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == true

# log out with the grant still live
POST {{KANAE_URL}}/members/logout
HTTP 200

# the deleted target is gone from Kratos too
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{target_email}}", "password": "{{target_pw}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006

# ── root sees the live grant, then removes the admin ─────────────────────────
POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ROOT_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{ROOT_ID}}"

# another user's session reads the sudoer's grant out of sudo_grants
GET {{KANAE_URL}}/sudo/active
HTTP 200
[Asserts]
jsonpath "$[?(@.member_id == '{{uid}}')].reason" == "e2e-15 grant two {{tag}}"
jsonpath "$[?(@.member_id == '{{uid}}')].expires_at" isIsoDate

# the grant is the sudoer's, not root's
GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false

DELETE {{KANAE_URL}}/members/{{uid}}
HTTP 200
[Asserts]
jsonpath "$.message" == "okie dokie"

GET {{KANAE_URL}}/members/{{uid}}
HTTP 404

# sudo_grants cascades with the member row
GET {{KANAE_URL}}/sudo/active
HTTP 200
[Asserts]
body not contains "{{uid}}"

# ── the audit trail outlives the sudoer ─────────────────────────────────────
# Both grants must still be in the audit log after the sudoer is deleted;
# the refused elevates must not be. Root's session is left to expire.
GET {{KANAE_URL}}/sudo/audit
HTTP 200
[Asserts]
jsonpath "$[?(@.reason == 'e2e-15 grant one {{tag}}')].reason" exists
jsonpath "$[?(@.reason == 'e2e-15 grant two {{tag}}')].reason" exists
body not contains "no role {{tag}}"
body not contains "root at aal1 {{tag}}"
body not contains "aal1 attempt {{tag}}"
