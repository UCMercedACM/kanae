# Edge: Kratos -> the internet. The kratos NetworkPolicy allows egress to
# 0.0.0.0/0 on 443/587 minus the private ranges, and kratos.prod.yml turns
# on haveibeenpwned with max_breaches 0. A breached password is rejected with
# message 4000034 and a breach count, which can only come from
# api.pwnedpasswords.com; Kratos' default ignore_network_errors means a
# password that passes proves nothing about egress, so only the rejections
# do. The local policy checks (length, similarity to the identifier) are
# pinned alongside so a 400 from them is not mistaken for a HIBP answer.
#
# Before that, CSRF and flow integrity through /auth: a missing or wrong csrf
# token and a never-issued flow id are refused before any password is looked
# at, and a stale token cannot replay the completed flow.
#
# After it, Kratos -> SMTP. The courier's mail:1025 is unreachable in this
# cluster, so no message is ever delivered. Recovery and verification must
# still answer at once with state sent_email: the courier works a queue in
# the background and never holds up a request. The answer is the same for a
# registered and an unknown address, so it does not reveal which emails have
# accounts. Nothing here depends on delivery.
#
# The one identity this file creates is deleted at the end. Derived from
# integration 02 and the probe pwned.json.

# ── CSRF and flow integrity ──

GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

# ── missing csrf_token field entirely ───────────────────────────────────────
POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "password": "{{flow_id}}", "traits": { "email": "e2e-13-csrfmiss-{{newUuid}}@hurl.test.local", "name": "x" } }
HTTP 403
[Asserts]
jsonpath "$.error.id" == "security_csrf_violation"
jsonpath "$.error.code" == 403

# ── wrong csrf_token value, correct cookie jar (the real defense: cookie
#    vs body-token comparison, not merely "is a token present") ────────────
POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "not-the-real-token", "password": "{{flow_id}}", "traits": { "email": "e2e-13-csrfwrong-{{newUuid}}@hurl.test.local", "name": "x" } }
HTTP 403
[Asserts]
jsonpath "$.error.id" == "security_csrf_violation"

# ── foreign / never-issued flow id, valid-looking csrf token ────────────────
# A flow id nobody ever received from Kratos — not expired, just never
# existed — is rejected as a missing resource, distinct from the CSRF
# violation above.
POST {{KRATOS_URL}}/self-service/registration?flow=00000000-0000-4000-8000-000000000000
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{flow_id}}", "traits": { "email": "e2e-13-csrfforeign-{{newUuid}}@hurl.test.local", "name": "x" } }
HTTP 404
[Asserts]
jsonpath "$.error.message" == "Unable to locate the resource"

# ── registration: HIBP answers ──

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
variable: hibp_email=e2e-13-pwned-{{newUuid}}@hurl.test.local
{ "method": "password", "csrf_token": "{{csrf}}", "password": "password1234", "traits": { "email": "{{hibp_email}}", "name": "hibp" } }
HTTP 400
[Asserts]
jsonpath "$.state" == "choose_method"
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].id" == 4000034
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].type" == "error"
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].context.breaches" > 0
# the rejected form comes back with the traits the user typed
jsonpath "$.ui.nodes[?(@.attributes.name == 'traits.email')].attributes.value" == "{{hibp_email}}"
cookie "ory_kratos_session" not exists

# The flow survives a rejection and answers again for another breached one.
POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "correcthorsebatterystaple", "traits": { "email": "e2e-13-hibp-{{newUuid}}@hurl.test.local", "name": "hibp" } }
HTTP 400
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].id" == 4000034
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].context.breaches" > 0

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "123456789012", "traits": { "email": "e2e-13-hibp-{{newUuid}}@hurl.test.local", "name": "hibp" } }
HTTP 400
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].id" == 4000034

# ── registration: local policy, no network involved ──

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "Ab3!x", "traits": { "email": "e2e-13-hibp-{{newUuid}}@hurl.test.local", "name": "hibp" } }
HTTP 400
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].id" == 4000032
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].context.min_length" == 12
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].context.actual_length" == 5

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "hibp-similar-identifier-x", "traits": { "email": "hibp-similar-identifier-x@hurl.test.local", "name": "hibp" } }
HTTP 400
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].id" == 4000031
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].text" == "The password can not be used because it is too similar to the identifier."

# ── a unique strong password passes and the flow completes ──

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
[Options]
variable: ok_email=e2e-13-ok-{{newUuid}}@hurl.test.local
variable: ok_pw=Hibp-Ok-{{newUuid}}
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{ok_pw}}", "traits": { "email": "{{ok_email}}", "name": "hibp ok", "display_name": "hibp" } }
HTTP 200
[Captures]
u_id: jsonpath "$.identity.id"
[Asserts]
jsonpath "$.session.active" == true
cookie "ory_kratos_session" exists

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{u_id}}"
jsonpath "$.name" == "hibp ok"

# Registration queued a verification email; the address stays unverified.
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.identity.verifiable_addresses[0].value" == "{{ok_email}}"
jsonpath "$.identity.verifiable_addresses[0].verified" == false
jsonpath "$.identity.verifiable_addresses[0].status" == "sent"

# ── courier: verification while signed in ──
GET {{KRATOS_URL}}/self-service/verification/browser
Accept: application/json
HTTP 200
[Captures]
vflow: jsonpath "$.id"
vcsrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.state" == "choose_method"
jsonpath "$.ui.nodes[?(@.attributes.name == 'email')]" exists

POST {{KRATOS_URL}}/self-service/verification?flow={{vflow}}
Content-Type: application/json
Accept: application/json
{ "method": "code", "email": "{{ok_email}}", "csrf_token": "{{vcsrf}}" }
HTTP 200
[Captures]
vcsrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.id" == "{{vflow}}"
jsonpath "$.state" == "sent_email"
jsonpath "$.active" == "code"
jsonpath "$.ui.messages[0].id" == 1080003
duration < 3000

# a guessed code is refused, and the flow stays waiting for the real one
POST {{KRATOS_URL}}/self-service/verification?flow={{vflow}}
Content-Type: application/json
Accept: application/json
{ "method": "code", "code": "000000", "csrf_token": "{{vcsrf}}" }
HTTP 200
[Asserts]
jsonpath "$.state" == "sent_email"
jsonpath "$.ui.messages[0].id" == 4070006
jsonpath "$.ui.messages[0].text" == "The verification code is invalid or has already been used. Please try again."

# the refusal did not verify anything
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.identity.verifiable_addresses[0].verified" == false

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── replaying the completed flow ──

# Same flow id and the csrf token the form was rendered with, a different
# email: the successful registration rotated the csrf cookie, so the stale
# token is a CSRF violation and no second account appears. (The completed
# flow itself is not closed: a token taken after the registration is
# accepted and registers a second identity. Reported separately; not pinned.)
POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{ok_pw}}", "traits": { "email": "e2e-13-replay-{{newUuid}}@hurl.test.local", "name": "replay" } }
HTTP 403
[Asserts]
jsonpath "$.error.id" == "security_csrf_violation"
cookie "ory_kratos_session" not exists

GET {{KANAE_URL}}/members/me
HTTP 401

# ── courier: recovery, signed out ──
GET {{KRATOS_URL}}/self-service/recovery/browser
Accept: application/json
HTTP 200
[Captures]
rflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.state" == "choose_method"
jsonpath "$.active" == "link"

# a malformed address never reaches the courier
POST {{KRATOS_URL}}/self-service/recovery?flow={{rflow}}
Content-Type: application/json
Accept: application/json
{ "method": "link", "email": "not-an-email", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.state" == "choose_method"
jsonpath "$.ui.nodes[?(@.attributes.name == 'email')].messages[0].id" == 4000040

# recovery is configured with `use: link`, so the code method is unknown
POST {{KRATOS_URL}}/self-service/recovery?flow={{rflow}}
Content-Type: application/json
Accept: application/json
{ "method": "code", "email": "{{ok_email}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4010005

POST {{KRATOS_URL}}/self-service/recovery?flow={{rflow}}
Content-Type: application/json
Accept: application/json
{ "method": "link", "email": "{{ok_email}}" }
HTTP 403
[Asserts]
jsonpath "$.error.id" == "security_csrf_violation"

POST {{KRATOS_URL}}/self-service/recovery?flow={{rflow}}
Content-Type: application/json
Accept: application/json
{ "method": "link", "email": "{{ok_email}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.id" == "{{rflow}}"
jsonpath "$.state" == "sent_email"
jsonpath "$.ui.messages[0].id" == 1060002
cookie "ory_kratos_session" not exists
duration < 3000

# the same answer for an address with no account
GET {{KRATOS_URL}}/self-service/recovery/browser
Accept: application/json
HTTP 200
[Captures]
rflow2: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/recovery?flow={{rflow2}}
Content-Type: application/json
Accept: application/json
{ "method": "link", "email": "e2e-13-nobody-{{newUuid}}@hurl.test.local", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.state" == "sent_email"
jsonpath "$.ui.messages[0].id" == 1060002
duration < 3000

# a made-up link token is turned into a fresh flow on the UI, not a session
GET {{KRATOS_URL}}/self-service/recovery?flow={{rflow2}}&token=e2e-13-not-a-token
Accept: application/json
HTTP 303
[Asserts]
header "location" startsWith "https://kanae:5173/recovery?flow="
header "location" not contains "{{rflow2}}"
cookie "ory_kratos_session" not exists

GET {{KANAE_URL}}/members/me
HTTP 401

# ── courier: verification, signed out, unknown address ──
GET {{KRATOS_URL}}/self-service/verification/browser
Accept: application/json
HTTP 200
[Captures]
vflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/verification?flow={{vflow}}
Content-Type: application/json
Accept: application/json
{ "method": "code", "email": "e2e-13-nobody-{{newUuid}}@hurl.test.local", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.state" == "sent_email"
jsonpath "$.ui.messages[0].id" == 1080003
duration < 3000

# the queue of undeliverable mail leaves Kratos ready
GET {{KRATOS_URL}}/health/ready
HTTP 200
[Asserts]
jsonpath "$.status" == "ok"

# ── cleanup: log back in with the strong password and delete ──

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ok_email}}", "password": "{{ok_pw}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{u_id}}"

DELETE {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.message" == "okie dokie"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401
