# One member, start to finish. Files 04-16 each take a fresh identity
# through one chapter; this file takes a single identity through all of
# them in order, so each chapter runs on the state the last one left:
#
#   sign up -> rename -> change password -> enroll backup codes ->
#   promoted by root -> log in with the NEW password + a code ->
#   elevate -> use sudo on a member this file made -> revoke ->
#   delete the account -> Kratos no longer knows the NEW password
#
# The checks are the ones that prove the hand-off between chapters (the
# new name is what root's directory shows, the new password is the one
# that logs in, the codes enrolled before the promotion are the ones that
# step up after it). The chapter files hold the exhaustive negatives.
#
# Derived from integration 02, 04, 27 and 28.

# ── a member for the sudo chapter to act on ──────────────────────────────────
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
variable: email=e2e-18-life-{{tag}}@hurl.test.local
variable: email2=e2e-18-life-renamed-{{tag}}@hurl.test.local
variable: pw1=E2e-18-Life-One-{{newUuid}}
variable: pw2=E2e-18-Life-Two-{{newUuid}}
{ "method": "password", "csrf_token": "{{csrf}}", "password": "E2e-18-Bystander-{{newUuid}}", "traits": { "email": "e2e-18-bystander-{{tag}}@hurl.test.local", "name": "bystander-{{tag}}" } }
HTTP 200
[Captures]
tid: jsonpath "$.identity.id"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── 1. sign up (HIBP says no first) ──────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "password1234", "traits": { "email": "{{email}}", "name": "life-{{tag}}" } }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')].messages[0].id" == 4000034

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{pw1}}", "traits": { "email": "{{email}}", "name": "life-{{tag}}" } }
HTTP 200
[Captures]
uid: jsonpath "$.identity.id"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.name" == "life-{{tag}}"
jsonpath "$.roles" count == 0
jsonpath "$.session.aal" == "aal1"

# ── 2. rename (settings webhook, profile) ────────────────────────────────────
GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 200
[Captures]
sflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "profile", "csrf_token": "{{csrf}}", "traits": { "email": "{{email2}}", "name": "renamed-{{tag}}", "display_name": "Life" } }
HTTP 200
[Asserts]
jsonpath "$.state" == "success"

GET {{KANAE_URL}}/members/{{uid}}
HTTP 200
[Asserts]
jsonpath "$.name" == "renamed-{{tag}}"

# ── 3. change password (settings webhook, password) ──────────────────────────
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{pw2}}" }
HTTP 200
[Asserts]
jsonpath "$.state" == "success"

# ── 4. enroll backup codes ───────────────────────────────────────────────────
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "lookup_secret", "lookup_secret_regenerate": true, "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
code0: jsonpath "$.ui.nodes[?(@.attributes.id == 'lookup_secret_codes')].attributes.text.context.secrets[0].context.secret"

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
jsonpath "$.authenticator_assurance_level" == "aal2"
jsonpath "$.identity.traits.email" == "{{email2}}"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── 5. root finds the renamed member and promotes them ───────────────────────
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

# the directory shows what the profile webhook wrote
GET {{KANAE_URL}}/members?query=e2e-18-life-renamed-{{tag}}
HTTP 200
[Asserts]
jsonpath "$.data[?(@.id == '{{uid}}')].email" == "{{email2}}"
jsonpath "$.data[?(@.id == '{{uid}}')].name" == "renamed-{{tag}}"
jsonpath "$.data[?(@.id == '{{uid}}')].display_name" == "Life"

PUT {{KANAE_URL}}/members/{{uid}}/role
Content-Type: application/json
{ "role": "admin", "action": "grant" }
HTTP 200

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── 6. log in: new email, new password, then a code ──────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email}}", "password": "{{pw2}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email2}}", "password": "{{pw1}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email2}}", "password": "{{pw2}}", "csrf_token": "{{csrf}}" }
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
{ "method": "lookup_secret", "lookup_secret": "{{code0}}", "csrf_token": "{{csrf}}" }
HTTP 200

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.name" == "renamed-{{tag}}"
jsonpath "$.email" == "{{email2}}"
jsonpath "$.display_name" == "Life"
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "admin"
jsonpath "$.session.aal" == "aal2"

# ── 7. elevate, act, revoke ──────────────────────────────────────────────────
PUT {{KANAE_URL}}/members/{{tid}}/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 403

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "e2e-18 lifecycle {{tag}}" }
HTTP 200
[Asserts]
jsonpath "$.active" == true

PUT {{KANAE_URL}}/members/{{tid}}/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 200

GET {{KANAE_URL}}/members/{{tid}}/roles
HTTP 200
[Asserts]
jsonpath "$.roles[0]" == "manager"

DELETE {{KANAE_URL}}/members/{{tid}}
HTTP 200

DELETE {{KANAE_URL}}/sudo/revoke
HTTP 200

GET {{KANAE_URL}}/sudo
HTTP 200
[Asserts]
jsonpath "$.active" == false

GET {{KANAE_URL}}/members/{{tid}}
HTTP 404

# ── 8. leave for good ────────────────────────────────────────────────────────
DELETE {{KANAE_URL}}/members/me
HTTP 200

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

GET {{KANAE_URL}}/members/{{uid}}
HTTP 404

# the newest credentials are the ones that stop working
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{email2}}", "password": "{{pw2}}", "csrf_token": "{{csrf}}" }
HTTP 400
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006
cookie "ory_kratos_session" not exists
