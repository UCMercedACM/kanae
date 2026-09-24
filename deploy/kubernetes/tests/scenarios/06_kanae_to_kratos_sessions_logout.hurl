# Edge: kanae -> Kratos. The public port (kratos:4433) for /sessions/whoami,
# the admin port (kratos:4434) for DELETE /admin/sessions/{id} on logout and
# for DELETE /admin/identities/{id} on account deletion. Both ports are
# allowed by the kanae NetworkPolicy and nothing else may reach 4434. Proves
# that kanae relays the browser cookie and mirrors the Kratos session, that
# a failed login leaves kanae with nothing, that junk and tampered cookies come
# back as 401, and that a kanae logout is a Kratos-side revocation (Kratos
# itself rejects the cookie afterwards). It also proves kanae accepts only the
# cookie, never a Kratos session token, and that a logout revokes that one
# session: a parallel API session of the same member survives it until
# Kratos's own API logout. Self-deletion lives in 16.
#
# Uses the seeded MEMBER; only logs it in and out. Derived from integration
# 02, 03 and 04.

GET {{KANAE_URL}}/members/me
HTTP 401

# An API login gives a session token and no cookie. It runs first because
# Kratos refuses an API flow submission that carries any cookie, and the jar
# is still empty here. The token is used near the end.
GET {{KRATOS_URL}}/self-service/login/api
Accept: application/json
HTTP 200
[Captures]
api_flow: jsonpath "$.id"
[Asserts]
jsonpath "$.type" == "api"

POST {{KRATOS_URL}}/self-service/login?flow={{api_flow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MEMBER_EMAIL}}", "password": "{{PASSWORD}}" }
HTTP 200
[Captures]
token: jsonpath "$.session_token"
token_sid: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{MEMBER_ID}}"
cookie "ory_kratos_session" not exists

# ── whoami relay: kanae's session view is the Kratos session ──

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.action" == "https://kanae/auth/self-service/login?flow={{flow_id}}"
jsonpath "$.refresh" == false
jsonpath "$.requested_aal" == "aal1"

# A wrong password: Kratos refuses, no cookie is set, kanae still sees nobody.
POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MEMBER_EMAIL}}", "password": "not-the-member-password", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006
cookie "ory_kratos_session" not exists

GET {{KANAE_URL}}/members/me
HTTP 401

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MEMBER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
session_id: jsonpath "$.session.id"
m_cookie: cookie "ory_kratos_session"
[Asserts]
jsonpath "$.session.identity.id" == "{{MEMBER_ID}}"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
# Kratos prints these without trailing zeros (.29206Z) and kanae with six
# digits (.292060Z), so they are compared as Z-stripped prefixes.
[Captures]
authenticated_at: jsonpath "$.authenticated_at" regex /^(.*)Z$/
issued_at: jsonpath "$.issued_at" regex /^(.*)Z$/
expires_at: jsonpath "$.expires_at" regex /^(.*)Z$/
[Asserts]
jsonpath "$.id" == "{{session_id}}"
jsonpath "$.authenticator_assurance_level" == "aal1"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"
jsonpath "$.email" == "{{MEMBER_EMAIL}}"
jsonpath "$.name" == "member"
jsonpath "$.display_name" == "member"
jsonpath "$.session.aal" == "aal1"
jsonpath "$.session.active" == true
jsonpath "$.session.authenticated_at" startsWith "{{authenticated_at}}"
jsonpath "$.session.issued_at" startsWith "{{issued_at}}"
jsonpath "$.session.expires_at" startsWith "{{expires_at}}"

# With a session in hand Kratos refuses a plain login flow, and kanae is not
# involved in that decision.
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 400
[Asserts]
jsonpath "$.error.id" == "session_already_available"

# ── junk cookies are relayed and rejected, not guessed at ──

# kanae reads the last ory_kratos_session cookie in the request, so this
# explicit header wins over the jar and is what reaches Kratos.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session=garbage
HTTP 401
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" == "Authentication required"

# A well-formed base64 blob that was never issued by Kratos.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session=MTIzNDU2Nzg5MGFiY2RlZi5mYWtlLnNpZ25hdHVyZS5ub3QtYS1zZXNzaW9u
HTTP 401

# A live cookie with one extra byte in front is no longer a session.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session=x{{m_cookie}}
HTTP 401

# A live cookie with its tail cut off is not one either.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{m_cookie}}x
HTTP 401

# The jar cookie is still good: junk did not poison anything.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"

# ── logout: kanae calls the Kratos admin API, Kratos itself drops the session ──

POST {{KANAE_URL}}/members/logout
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.message" == "ok"

# Asked directly, Kratos no longer knows the cookie: the revoke went through
# DELETE /admin/sessions/{id} on 4434.
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401
[Asserts]
jsonpath "$.error.code" == 401

GET {{KANAE_URL}}/members/me
HTTP 401
[Asserts]
jsonpath "$.detail" == "Authentication required"

GET {{KANAE_URL}}/members/me/projects
HTTP 401

POST {{KANAE_URL}}/members/logout
HTTP 401

# A revoked cookie does not block a new login flow.
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

# ── session tokens are Kratos's, not kanae's ──

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
X-Session-Token: {{token}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{token_sid}}"

# kanae only reads the ory_kratos_session cookie, so the live token gets
# nowhere in any of the places a client might put it.
GET {{KANAE_URL}}/members/me
X-Session-Token: {{token}}
HTTP 401
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Authentication required"

GET {{KANAE_URL}}/members/me
Authorization: Bearer {{token}}
HTTP 401

GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{token}}
HTTP 401

# ── one identity, two sessions: a kanae logout revokes only its own ──

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MEMBER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
browser_sid: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.id" != "{{token_sid}}"
jsonpath "$.session.id" != "{{session_id}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"

# Kratos lists the member's other active sessions: the API one, not this one.
GET {{KRATOS_URL}}/sessions
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$[?(@.id == '{{token_sid}}')].id" == "{{token_sid}}"
jsonpath "$[?(@.id == '{{browser_sid}}')].id" not exists

# the cookie revoked at the first logout stays dead next to the new one
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{m_cookie}}
HTTP 401

POST {{KANAE_URL}}/members/logout
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

GET {{KANAE_URL}}/members/me
HTTP 401

# The API session outlived the browser logout.
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
X-Session-Token: {{token}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{token_sid}}"
jsonpath "$.identity.id" == "{{MEMBER_ID}}"

# Kratos's own API logout ends it.
DELETE {{KRATOS_URL}}/self-service/logout/api
Content-Type: application/json
{ "session_token": "{{token}}" }
HTTP 204

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
X-Session-Token: {{token}}
HTTP 401

# ── logout route edges ──

# logout is POST-only; a GET falls through to /members/{id} and fails the
# uuid check.
GET {{KANAE_URL}}/members/logout
HTTP 422
[Asserts]
header "server" == "granian"

POST {{KANAE_URL}}/members/logout
Cookie: ory_kratos_session=garbage
HTTP 401
