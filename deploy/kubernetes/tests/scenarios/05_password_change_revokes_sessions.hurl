# Password-change journey. A new member holds two sessions: an API session
# (a session token from the API registration flow) and a browser session
# (the cookie). They change their password in the browser settings flow.
#
# Kratos checks every candidate password (length, identifier similarity,
# HIBP over the internet), then runs the after-password hooks: the web_hook
# into kanae's /member/webhooks/settings (response.ignore false, so the
# flow only succeeds if kanae accepted the rendered token and answered 2xx)
# and revoke_active_sessions, which kills every session except the one
# that made the change. One jar holds one cookie, so the "other session" is
# the API token: X-Session-Token wins over the jar cookie at /sessions/whoami,
# which lets the file ask Kratos about each session separately.
#
# The API registration also proves the registration webhook fires for API
# flows, not just browser ones.
#
# The identity is deleted at the end. Derived from integration 04 and 02.

# ── sign up through the API flow: a token, no cookie ─────────────────────────
GET {{KRATOS_URL}}/self-service/registration/api
Accept: application/json
HTTP 200
[Captures]
rflow: jsonpath "$.id"
[Asserts]
jsonpath "$.type" == "api"
jsonpath "$.ui.action" == "https://kanae/auth/self-service/registration?flow={{rflow}}"

POST {{KRATOS_URL}}/self-service/registration?flow={{rflow}}
Content-Type: application/json
Accept: application/json
[Options]
variable: tag={{newUuid}}
variable: email=e2e-05-passwd-{{tag}}@hurl.test.local
variable: old_pw=E2e-Old-Pass-{{newUuid}}
variable: new_pw=E2e-New-Pass-{{newUuid}}
{ "method": "password", "password": "{{old_pw}}", "traits": { "email": "{{email}}", "name": "passwd-{{tag}}" } }
HTTP 200
[Captures]
uid: jsonpath "$.identity.id"
api_token: jsonpath "$.session_token"
api_session: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session_token" isString
jsonpath "$.session.active" == true
cookie "ory_kratos_session" not exists

# the webhook wrote the row even though no browser was involved
GET {{KANAE_URL}}/members/{{uid}}
HTTP 200
[Asserts]
jsonpath "$.name" == "passwd-{{tag}}"

# a token is not a cookie: kanae only reads ory_kratos_session
GET {{KANAE_URL}}/members/me
X-Session-Token: {{api_token}}
HTTP 401

# ── second session: log in through the browser flow ──────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email}}", "password": "{{old_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
browser_session: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{uid}}"
jsonpath "$.session.id" != "{{api_session}}"

# both sessions are live, and Kratos tells them apart
GET {{KRATOS_URL}}/sessions/whoami
X-Session-Token: {{api_token}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{api_session}}"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.id" == "{{browser_session}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"

# Kratos lists the API session as the browser session's "other" session:
# exactly the one revoke_active_sessions is about to kill.
GET {{KRATOS_URL}}/sessions
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{api_session}}"
jsonpath "$[0].active" == true

# ── settings flow ────────────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 200
[Captures]
sflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.state" == "show_form"
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].attributes.autocomplete" == "new-password"

# ── rejected passwords: no hook runs, nothing is revoked ─────────────────────
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "short" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].id" == 4000032
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].context.min_length" == 12

# identifier_similarity_check_enabled
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{email}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].id" == 4000031

# HIBP on the settings path too: Kratos -> api.pwnedpasswords.com:443
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "password1234" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].id" == 4000034
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].context.breaches" > 0

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "not-the-token", "password": "{{new_pw}}" }
HTTP 403
[Asserts]
jsonpath "$.error.id" == "security_csrf_violation"

# three rejections later the API session is untouched
GET {{KRATOS_URL}}/sessions/whoami
X-Session-Token: {{api_token}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{api_session}}"

# ── the real change: webhook, then revoke_active_sessions ────────────────────
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{new_pw}}" }
HTTP 200
[Asserts]
jsonpath "$.state" == "success"
jsonpath "$.ui.messages[0].id" == 1050001
jsonpath "$.identity.id" == "{{uid}}"
jsonpath "$.continue_with[0].redirect_browser_to" startsWith "https://kanae:5173/dashboard/settings"

# the other session is gone
GET {{KRATOS_URL}}/sessions/whoami
X-Session-Token: {{api_token}}
HTTP 401
[Asserts]
jsonpath "$.error.code" == 401

# the session that made the change is kept, at Kratos and at kanae
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.id" == "{{browser_session}}"
jsonpath "$.active" == true

# Kratos lists no other session for the identity any more.
GET {{KRATOS_URL}}/sessions
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$" count == 0

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.name" == "passwd-{{tag}}"
jsonpath "$.session.active" == true

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── the old password is refused, the new one works ───────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email}}", "password": "{{old_pw}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006
cookie "ory_kratos_session" not exists

GET {{KANAE_URL}}/members/me
HTTP 401

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email}}", "password": "{{new_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{uid}}"
jsonpath "$.session.id" != "{{browser_session}}"
jsonpath "$.session.authentication_methods[0].method" == "password"

# the API token did not come back to life with the new password
GET {{KRATOS_URL}}/sessions/whoami
X-Session-Token: {{api_token}}
HTTP 401

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.roles" count == 0

# ── cleanup ──────────────────────────────────────────────────────────────────
DELETE {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.message" == "okie dokie"

# Self-delete revoked the browser session at Kratos. kanae is not asked:
# its whoami cache would still serve this cookie for up to 60s (known bug).
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401
