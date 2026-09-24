# Two-factor journey with backup codes (lookup_secret), the second factor
# Hurl can drive (it cannot compute TOTP). A new member enrolls, which
# upgrades the current session to aal2 on the spot. From then on Kratos
# enforces required_aal highest_available: a password alone gives a
# half-finished aal1 session that neither Kratos whoami, the settings flow
# nor kanae will accept, until the aal2 step-up with a code. Codes are
# single-use and belong to one identity. Disabling the codes brings plain
# password logins back.
#
# kanae never talks to a second factor itself; it trusts the AAL Kratos
# reports through whoami, so every step is checked at both.
#
# Two identities. B enrolls first and only lends its unspent first code:
# A's step-up refuses it, and B's own step-up later accepts it, which shows
# the refusal was identity scoping rather than a dead code. A runs the full
# journey. Both are deleted at the end.
#
# After a password login answers 422 (aal2 pending), the file never calls
# kanae logout: that half-finished session cannot log out through kanae.
#
# Derived from integration 27.

# ── identity B: register, enroll, keep one unspent code ──────────────────────
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
variable: b_email=e2e-14-b-{{newUuid}}@hurl.test.local
variable: b_pw=E2e-14-B-Pass-{{newUuid}}
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{b_pw}}", "traits": { "email": "{{b_email}}", "name": "e2e-14-b" } }
HTTP 200
[Captures]
b_id: jsonpath "$.identity.id"
[Asserts]
jsonpath "$.identity.traits.email" == "{{b_email}}"
jsonpath "$.session.authenticator_assurance_level" == "aal1"

GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 200
[Captures]
sflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret_regenerate": true, "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
b_code0: jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets[0].context.secret"
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets" count == 12

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
jsonpath "$.identity.id" == "{{b_id}}"
jsonpath "$.authenticator_assurance_level" == "aal2"

POST {{KANAE_URL}}/members/logout
HTTP 200

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

# ── identity A: sign up; the new session is aal1 ─────────────────────────────
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
variable: email=e2e-14-a-{{tag}}@hurl.test.local
variable: password=E2e-14-A-Pass-{{newUuid}}
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{password}}", "traits": { "email": "{{email}}", "name": "e2e-14-a-{{tag}}" } }
HTTP 200
[Captures]
uid: jsonpath "$.identity.id"
a_cookie0: cookie "ory_kratos_session"
[Asserts]
jsonpath "$.identity.id" != "{{b_id}}"
jsonpath "$.session.authenticator_assurance_level" == "aal1"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.identity.id" == "{{uid}}"
jsonpath "$.authenticator_assurance_level" == "aal1"
jsonpath "$.authentication_methods" count == 1

# kanae sees the aal1 session and caches it under this cookie for 60s.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.session.aal" == "aal1"

# ── enroll: regenerate, then confirm ─────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 200
[Captures]
sflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_regenerate')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_reveal')]" not exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_disable')]" not exists

# nothing to confirm yet
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret_confirm": true, "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.state" == "show_form"
jsonpath "$.ui.messages[0].id" == 4000001

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret_regenerate": true, "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
code0: jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets[0].context.secret"
code1: jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets[1].context.secret"
[Asserts]
jsonpath "$.state" == "show_form"
jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets" count == 12
jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets[0].context.secret" != "{{b_code0}}"
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_confirm')]" exists

# generated but not saved: still aal1, still one method
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.authenticator_assurance_level" == "aal1"

# Saving the codes re-issues the session cookie, so kanae's cache entry for
# the aal1 cookie is never consulted again.
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret_confirm": true, "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.state" == "success"
jsonpath "$.ui.messages[0].id" == 1050001
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_reveal')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_disable')]" exists
cookie "ory_kratos_session" exists
cookie "ory_kratos_session" != "{{a_cookie0}}"

# saving the codes upgraded this very session
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.identity.id" == "{{uid}}"
jsonpath "$.authenticator_assurance_level" == "aal2"
jsonpath "$.authentication_methods[1].method" == "lookup_secret"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.session.aal" == "aal2"
jsonpath "$.roles" count == 0

# aal2 is not a role: elevate still wants admin from Keto
POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "e2e-14 2fa journey" }
HTTP 403
[Asserts]
jsonpath "$.detail" contains "admin"
header "X-Elevation-Flow" not exists

GET {{KANAE_URL}}/sudo
HTTP 403

# reveal hands the saved codes back
GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 200
[Captures]
sflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret_reveal": true, "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.text" contains "{{code0}}"
jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.text" contains "{{code1}}"
jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.text" not contains "{{b_code0}}"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── a password alone is not enough any more ──────────────────────────────────
# an aal2 flow needs an existing session to step up from
GET {{KRATOS_URL}}/self-service/login/browser?aal=aal2
Accept: application/json
HTTP 401
[Asserts]
jsonpath "$.error.id" == "session_aal1_required"

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email}}", "password": "{{password}}", "csrf_token": "{{csrf}}" }
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

# settings is aal2-gated too (required_aal highest_available)
GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 403
[Asserts]
jsonpath "$.error.id" == "session_aal2_required"

# kanae treats Kratos's 403 as no session at all
GET {{KANAE_URL}}/members/me
HTTP 401
[Asserts]
jsonpath "$.detail" == "Authentication required"
header "X-Elevation-Flow" not exists

GET {{KANAE_URL}}/members/me/projects
HTTP 401

# ── step up with a backup code ───────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser?aal=aal2
Accept: application/json
HTTP 200
[Captures]
aflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.requested_aal" == "aal2"
jsonpath "$.ui.messages[0].id" == 1010004
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')]" not exists

POST {{KRATOS_URL}}/self-service/login?flow={{aflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret": "notacode", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000016

# B's code is real and unspent, but it is not A's: the same refusal as a
# made-up code, so nothing tells an attacker the code exists elsewhere.
POST {{KRATOS_URL}}/self-service/login?flow={{aflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret": "{{b_code0}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000016
jsonpath "$.ui.messages[0].type" == "error"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 403
[Asserts]
jsonpath "$.error.id" == "session_aal2_required"

GET {{KANAE_URL}}/members/me
HTTP 401

POST {{KRATOS_URL}}/self-service/login?flow={{aflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret": "{{code0}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
aal2_session: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{uid}}"
jsonpath "$.session.authenticator_assurance_level" == "aal2"
jsonpath "$.session.authentication_methods[0].method" == "password"
jsonpath "$.session.authentication_methods[1].method" == "lookup_secret"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.session.aal" == "aal2"

# a password re-auth (refresh) on an aal2 session keeps it aal2
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
Accept: application/json
HTTP 200
[Captures]
rflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.refresh" == true

POST {{KRATOS_URL}}/self-service/login?flow={{rflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email}}", "password": "{{password}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.id" == "{{aal2_session}}"
jsonpath "$.session.authenticator_assurance_level" == "aal2"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── codes are single-use ─────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email}}", "password": "{{password}}", "csrf_token": "{{csrf}}" }
HTTP 422

GET {{KRATOS_URL}}/self-service/login/browser?aal=aal2
Accept: application/json
HTTP 200
[Captures]
aflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

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

GET {{KANAE_URL}}/members/me
HTTP 401

POST {{KRATOS_URL}}/self-service/login?flow={{aflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret": "{{code1}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{uid}}"
jsonpath "$.session.authenticator_assurance_level" == "aal2"

# ── disable the codes; passwords work alone again ────────────────────────────
GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 200
[Captures]
sflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret_disable": true, "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.state" == "success"
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_regenerate')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_disable')]" not exists

POST {{KANAE_URL}}/members/logout
HTTP 200

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email}}", "password": "{{password}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.authenticator_assurance_level" == "aal1"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.session.aal" == "aal1"

DELETE {{KANAE_URL}}/members/me
HTTP 200

# ── B's own step-up accepts the code A was refused ───────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{b_email}}", "password": "{{b_pw}}", "csrf_token": "{{csrf}}" }
HTTP 422
[Asserts]
jsonpath "$.error.id" == "browser_location_change_required"

GET {{KRATOS_URL}}/self-service/login/browser?aal=aal2
Accept: application/json
HTTP 200
[Captures]
aflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{aflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret": "{{b_code0}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{b_id}}"
jsonpath "$.session.authenticator_assurance_level" == "aal2"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{b_id}}"
jsonpath "$.session.aal" == "aal2"

DELETE {{KANAE_URL}}/members/me
HTTP 200

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401
