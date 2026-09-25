# Load: sequential argon2 work on Kratos. Every password registration hashes
# and every password login verifies with argon2 (memory 128MB, iterations 3,
# parallelism 16 in kratos.prod.yml), so this file is the heaviest steady
# CPU and memory load the suite puts on the Kratos pod: 20 wrong-password
# verifications back to back on one flow, then ten more logins and four more
# registrations. It proves the pod survives them in its 4Gi limit (health
# stays up, and the next request works), that failed logins neither lock the
# account nor spend the flow, and that each login/registration still reaches
# kanae through the whoami check and the registration webhook.
#
# Each request goes through Envoy's default route timeout, so a hash slow
# enough to cross it fails here as a 504. The Kratos restart count is checked
# outside Hurl.
#
# Every identity is deleted. Derived from integration 02 and 04.

# ── L: the identity the logins run against ───────────────────────────────────
GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
rflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{rflow}}
Content-Type: application/json
Accept: application/json
[Options]
variable: l_email=e2e-17-l-{{newUuid}}@hurl.test.local
variable: l_pw=E2e-17-L-Pass-{{newUuid}}
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{l_pw}}", "traits": { "email": "{{l_email}}", "name": "e2e-17-l" } }
HTTP 200
[Captures]
l_id: jsonpath "$.identity.id"
[Asserts]
jsonpath "$.identity.traits.email" == "{{l_email}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{l_id}}"
jsonpath "$.email" == "{{l_email}}"

POST {{KANAE_URL}}/members/logout
HTTP 200

GET {{KANAE_URL}}/members/me
HTTP 401

# ── 20 wrong-password verifications on one flow ──────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

# Each attempt runs a full 128MB verification. The flow and its csrf token
# survive every failure.
POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
[Options]
repeat: 20
{ "method": "password", "identifier": "{{l_email}}", "password": "Wrong-{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Asserts]
jsonpath "$.id" == "{{lflow}}"
jsonpath "$.state" == "choose_method"
jsonpath "$.ui.messages[0].id" == 4000006
jsonpath "$.ui.nodes[?(@.attributes.name == 'identifier')].attributes.value" == "{{l_email}}"
cookie "ory_kratos_session" not exists

# An unknown identifier is refused the same way.
POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "e2e-17-nobody-{{newUuid}}@hurl.test.local", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006
cookie "ory_kratos_session" not exists

GET {{KRATOS_URL}}/health/alive
HTTP 200
[Asserts]
jsonpath "$.status" == "ok"

GET {{KRATOS_URL}}/health/ready
HTTP 200
[Asserts]
jsonpath "$.status" == "ok"

GET {{KANAE_URL}}/members/me
HTTP 401

# No lockout: the right password on the same flow and csrf still logs in.
POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{l_email}}", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
l_sid1: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{l_id}}"
jsonpath "$.session.authentication_methods[0].method" == "password"
cookie "ory_kratos_session" exists

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{l_id}}"

# a completed flow cannot be replayed
POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{l_email}}", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 400

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── five login -> kanae -> logout cycles, each a new session ─────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{l_email}}", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
l_sid2: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{l_id}}"
jsonpath "$.session.id" != "{{l_sid1}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{l_id}}"

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
{ "method": "password", "identifier": "{{l_email}}", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
l_sid3: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{l_id}}"
jsonpath "$.session.id" != "{{l_sid2}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{l_id}}"

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
{ "method": "password", "identifier": "{{l_email}}", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
l_sid4: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{l_id}}"
jsonpath "$.session.id" != "{{l_sid3}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{l_id}}"

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
{ "method": "password", "identifier": "{{l_email}}", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
l_sid5: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{l_id}}"
jsonpath "$.session.id" != "{{l_sid4}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{l_id}}"

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
{ "method": "password", "identifier": "{{l_email}}", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
l_sid6: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{l_id}}"
jsonpath "$.session.id" != "{{l_sid5}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{l_id}}"

POST {{KANAE_URL}}/members/logout
HTTP 200

# Every logout revoked its session; none of them linger.
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

GET {{KRATOS_URL}}/health/ready
HTTP 200

# ── three register -> kanae -> delete cycles ─────────────────────────────────
# Each one hashes a new password, runs the registration webhook into kanae's
# Postgres, and the delete revokes and removes the identity again.
GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
rflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{rflow}}
Content-Type: application/json
Accept: application/json
[Options]
variable: c1_email=e2e-17-c1-{{newUuid}}@hurl.test.local
{ "method": "password", "csrf_token": "{{csrf}}", "password": "E2e-17-C1-{{newUuid}}", "traits": { "email": "{{c1_email}}", "name": "e2e-17-c1" } }
HTTP 200
[Captures]
c1_id: jsonpath "$.identity.id"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{c1_id}}"
jsonpath "$.email" == "{{c1_email}}"

DELETE {{KANAE_URL}}/members/me
HTTP 200

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
rflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{rflow}}
Content-Type: application/json
Accept: application/json
[Options]
variable: c2_email=e2e-17-c2-{{newUuid}}@hurl.test.local
{ "method": "password", "csrf_token": "{{csrf}}", "password": "E2e-17-C2-{{newUuid}}", "traits": { "email": "{{c2_email}}", "name": "e2e-17-c2" } }
HTTP 200
[Captures]
c2_id: jsonpath "$.identity.id"
[Asserts]
jsonpath "$.identity.id" != "{{c1_id}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{c2_id}}"
jsonpath "$.email" == "{{c2_email}}"

DELETE {{KANAE_URL}}/members/me
HTTP 200

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
rflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{rflow}}
Content-Type: application/json
Accept: application/json
[Options]
variable: c3_email=e2e-17-c3-{{newUuid}}@hurl.test.local
{ "method": "password", "csrf_token": "{{csrf}}", "password": "E2e-17-C3-{{newUuid}}", "traits": { "email": "{{c3_email}}", "name": "e2e-17-c3" } }
HTTP 200
[Captures]
c3_id: jsonpath "$.identity.id"
[Asserts]
jsonpath "$.identity.id" != "{{c2_id}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{c3_id}}"
jsonpath "$.email" == "{{c3_email}}"

DELETE {{KANAE_URL}}/members/me
HTTP 200

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

# ── L leaves; Kratos is still healthy afterwards ─────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{l_email}}", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{l_id}}"

DELETE {{KANAE_URL}}/members/me
HTTP 200

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

# the deleted identity no longer verifies at all
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{l_email}}", "password": "{{l_pw}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006

GET {{KRATOS_URL}}/health/alive
HTTP 200

GET {{KRATOS_URL}}/health/ready
HTTP 200
