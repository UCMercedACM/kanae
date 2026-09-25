# Edge: Kratos -> kanae webhooks. kratos.prod.yml fires
# POST http://kanae:8000/member/webhooks/registration after a password
# registration and POST /member/webhooks/settings after a profile or password
# settings flow, each with an X-Webhook-Token that kanae derives from the
# rendered master key. Proves: the registration hook writes the members row
# (with and without display_name), the settings hook syncs name/display_name/
# email into members, a rejected settings edit never reaches the hook, and the
# webhook endpoints, which are reachable from outside through the Gateway,
# reject a missing or forged token without touching any row.
#
# Password changes and revoke_active_sessions live in 05, where a second,
# separate session exists to be revoked.
#
# After a settings change kanae still serves the identity traits cached with
# the whoami result for up to 60s, so display_name/email are read from
# Postgres through the admin directory and from Kratos directly, never from
# /members/me on the same cookie.
#
# Both identities are deleted by root at the end. Derived from integration
# 02, 28 and 29.

# ── registration hook: an identity without display_name gets a members row ──

GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.ui.nodes[?(@.attributes.name == 'traits.email')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'traits.name')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'traits.display_name')]" exists

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
[Options]
variable: w_email=e2e-04-nodisplay-{{newUuid}}@hurl.test.local
{ "method": "password", "csrf_token": "{{csrf}}", "password": "Hq2$vN8!kL4&pZ7c", "traits": { "email": "{{w_email}}", "name": "wh no display" } }
HTTP 200
[Captures]
w_id: jsonpath "$.identity.id"
[Asserts]
jsonpath "$.identity.id" isUuid
jsonpath "$.identity.traits.email" == "{{w_email}}"
jsonpath "$.identity.traits.display_name" not exists
jsonpath "$.session.active" == true
cookie "ory_kratos_session" exists

# The hook already ran (response.ignore is false, so Kratos waited for it):
# the row exists before the session is even handed to the browser.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{w_id}}"
jsonpath "$.name" == "wh no display"
jsonpath "$.display_name" == null
jsonpath "$.email" == "{{w_email}}"
jsonpath "$.roles" count == 0
jsonpath "$.created_at" isIsoDate
jsonpath "$.session.aal" == "aal1"

GET {{KANAE_URL}}/members/{{w_id}}
HTTP 200
[Asserts]
jsonpath "$.name" == "wh no display"
jsonpath "$.projects" count == 0
jsonpath "$.events" count == 0

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── registration hook: full traits ──

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
variable: u_email=e2e-04-user-{{newUuid}}@hurl.test.local
{ "method": "password", "csrf_token": "{{csrf}}", "password": "Vq7#pL9$wE2@nR5m", "traits": { "email": "{{u_email}}", "name": "wh user", "display_name": "whu" } }
HTTP 200
[Captures]
u_id: jsonpath "$.identity.id"
u_sid: jsonpath "$.session.id"
[Asserts]
jsonpath "$.identity.schema_id" == "default"
jsonpath "$.identity.state" == "active"
jsonpath "$.identity.traits.email" == "{{u_email}}"
jsonpath "$.identity.traits.display_name" == "whu"
jsonpath "$.identity.verifiable_addresses[0].value" == "{{u_email}}"
jsonpath "$.identity.verifiable_addresses[0].verified" == false
jsonpath "$.session.authenticator_assurance_level" == "aal1"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{u_id}}"
jsonpath "$.name" == "wh user"
jsonpath "$.display_name" == "whu"
jsonpath "$.email" == "{{u_email}}"

# The public read is a plain Postgres query and never exposes the email.
GET {{KANAE_URL}}/members/{{u_id}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{u_id}}"
jsonpath "$.name" == "wh user"
jsonpath "$.email" not exists

# ── settings hook, profile method: rejected edits never reach the hook ──

GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 200
[Captures]
sflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.state" == "show_form"
jsonpath "$.ui.action" == "https://kanae/auth/self-service/settings?flow={{sflow}}"
jsonpath "$.ui.nodes[?(@.attributes.name == 'traits.name')].attributes.value" == "wh user"
jsonpath "$.ui.nodes[?(@.attributes.name == 'traits.display_name')].attributes.value" == "whu"
jsonpath "$.ui.nodes[?(@.attributes.name == 'traits.email')].attributes.value" == "{{u_email}}"
jsonpath "$.ui.nodes[?(@.attributes.name == 'lookup_secret_regenerate')]" exists

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "profile", "csrf_token": "not-the-token", "traits": { "email": "{{u_email}}", "name": "csrf edit" } }
HTTP 403
[Asserts]
jsonpath "$.error.id" == "security_csrf_violation"

# An empty name breaks the identity schema (minLength 1).
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "profile", "csrf_token": "{{csrf}}", "traits": { "email": "{{u_email}}", "name": "" } }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.state" != "success"

# A trait the schema does not declare (additionalProperties false).
POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "profile", "csrf_token": "{{csrf}}", "traits": { "email": "{{u_email}}", "name": "sneaky", "role": "admin" } }
HTTP 400
[Captures]
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"
[Asserts]
jsonpath "$.state" != "success"

GET {{KANAE_URL}}/members/{{u_id}}
HTTP 200
[Asserts]
jsonpath "$.name" == "wh user"

# ── settings hook, profile method: name and display_name ──

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
{ "method": "profile", "csrf_token": "{{csrf}}", "traits": { "email": "{{u_email}}", "name": "wh renamed", "display_name": "whr" } }
HTTP 200
[Asserts]
jsonpath "$.state" == "success"
jsonpath "$.ui.messages[0].id" == 1050001
jsonpath "$.identity.traits.name" == "wh renamed"
jsonpath "$.identity.traits.display_name" == "whr"

# name is read from members (Postgres) on every call, so the hook's upsert is
# visible at once, on the cached cookie and on the public route.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{u_id}}"
jsonpath "$.name" == "wh renamed"

GET {{KANAE_URL}}/members/{{u_id}}
HTTP 200
[Asserts]
jsonpath "$.name" == "wh renamed"

# ── settings hook, profile method: the login email itself ──

GET {{KRATOS_URL}}/self-service/settings/browser
Accept: application/json
HTTP 200
[Captures]
sflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/settings?flow={{sflow}}
Content-Type: application/json
Accept: application/json
[Options]
variable: u_email2=e2e-04-moved-{{newUuid}}@hurl.test.local
{ "method": "profile", "csrf_token": "{{csrf}}", "traits": { "email": "{{u_email2}}", "name": "wh renamed", "display_name": "whr" } }
HTTP 200
[Asserts]
jsonpath "$.state" == "success"
jsonpath "$.identity.traits.email" == "{{u_email2}}"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.id" == "{{u_sid}}"
jsonpath "$.identity.traits.email" == "{{u_email2}}"
jsonpath "$.identity.traits.display_name" == "whr"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── the login identifier followed the email change ──

GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{u_email}}", "password": "Vq7#pL9$wE2@nR5m", "csrf_token": "{{csrf}}" }
HTTP 400
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006
cookie "ory_kratos_session" not exists

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{u_email2}}", "password": "Vq7#pL9$wE2@nR5m", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{u_id}}"
jsonpath "$.session.identity.traits.email" == "{{u_email2}}"

# A fresh cookie means a fresh whoami: every trait change is visible here.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{u_id}}"
jsonpath "$.name" == "wh renamed"
jsonpath "$.display_name" == "whr"
jsonpath "$.email" == "{{u_email2}}"

# ── the members rows as Postgres holds them, through the admin directory ──

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

GET {{KANAE_URL}}/members?query={{u_email2}}
HTTP 200
[Asserts]
jsonpath "$.total" == 1
jsonpath "$.data[0].id" == "{{u_id}}"
jsonpath "$.data[0].name" == "wh renamed"
jsonpath "$.data[0].display_name" == "whr"
jsonpath "$.data[0].email" == "{{u_email2}}"

# The old email is gone from members too.
GET {{KANAE_URL}}/members?query={{u_email}}
HTTP 200
[Asserts]
jsonpath "$.total" == 0

GET {{KANAE_URL}}/members?query={{w_email}}
HTTP 200
[Asserts]
jsonpath "$.total" == 1
jsonpath "$.data[0].id" == "{{w_id}}"
jsonpath "$.data[0].name" == "wh no display"
jsonpath "$.data[0].display_name" == null

# ── cleanup: root deletes both identities (Postgres row, Keto, Kratos) ──

DELETE {{KANAE_URL}}/members/{{w_id}}
HTTP 200
[Asserts]
jsonpath "$.message" == "okie dokie"

DELETE {{KANAE_URL}}/members/{{u_id}}
HTTP 200

GET {{KANAE_URL}}/members/{{w_id}}
HTTP 404

GET {{KANAE_URL}}/members/{{u_id}}
HTTP 404

GET {{KANAE_URL}}/members?query={{u_email2}}
HTTP 200
[Asserts]
jsonpath "$.total" == 0

# Deleting again finds no row.
DELETE {{KANAE_URL}}/members/{{u_id}}
HTTP 404

# Root cannot delete itself through the admin path.
DELETE {{KANAE_URL}}/members/{{ROOT_ID}}
HTTP 409
[Asserts]
jsonpath "$.detail" contains "DELETE /members/me"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── the webhook endpoints from outside: reachable, but the token gate holds ──

# Header validation runs first: no token is a 422 naming the header.
POST {{KANAE_URL}}/member/webhooks/registration
Content-Type: application/json
{ "flow_id": "00000000-0000-4000-8000-0000000000f1", "identity": { "id": "00000000-0000-4000-8000-0000000000ab", "schema_id": "default", "traits": { "email": "forged@hurl.test.local", "name": "forged" } } }
HTTP 422
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.errors[0].type" == "missing"
jsonpath "$.errors[0].loc" contains "x-webhook-token"

POST {{KANAE_URL}}/member/webhooks/settings
Content-Type: application/json
{ "flow_id": "00000000-0000-4000-8000-0000000000f1", "identity": { "id": "{{MEMBER_ID}}", "schema_id": "default", "traits": { "email": "{{MEMBER_EMAIL}}", "name": "hijacked" } } }
HTTP 422
[Asserts]
jsonpath "$.errors[0].loc" contains "x-webhook-token"

# A header that is present but empty reaches the handler and fails the compare.
POST {{KANAE_URL}}/member/webhooks/registration
Content-Type: application/json
X-Webhook-Token:
{ "flow_id": "00000000-0000-4000-8000-0000000000f1", "identity": { "id": "00000000-0000-4000-8000-0000000000ab", "schema_id": "default", "traits": { "email": "forged@hurl.test.local", "name": "forged" } } }
HTTP 401
[Asserts]
jsonpath "$.detail" == "Invalid webhook token detected"

# A well-formed but forged token: 401 from the blake3 comparison, no upsert.
POST {{KANAE_URL}}/member/webhooks/registration
Content-Type: application/json
X-Webhook-Token: 0000000000000000000000000000000000000000000000000000000000000000
{ "flow_id": "00000000-0000-4000-8000-0000000000f1", "identity": { "id": "00000000-0000-4000-8000-0000000000ab", "schema_id": "default", "traits": { "email": "forged@hurl.test.local", "name": "forged" } } }
HTTP 401
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" == "Invalid webhook token detected"

GET {{KANAE_URL}}/members/00000000-0000-4000-8000-0000000000ab
HTTP 404

POST {{KANAE_URL}}/member/webhooks/settings
Content-Type: application/json
X-Webhook-Token: forged
{ "flow_id": "00000000-0000-4000-8000-0000000000f1", "identity": { "id": "{{MEMBER_ID}}", "schema_id": "default", "traits": { "email": "{{MEMBER_EMAIL}}", "name": "hijacked", "display_name": "hijacked" } } }
HTTP 401
[Asserts]
jsonpath "$.detail" == "Invalid webhook token detected"

# The seeded row was not touched.
GET {{KANAE_URL}}/members/{{MEMBER_ID}}
HTTP 200
[Asserts]
jsonpath "$.name" == "member"

# Body validation is strict (extra="forbid") and runs before the token check.
POST {{KANAE_URL}}/member/webhooks/settings
Content-Type: application/json
X-Webhook-Token: forged
{ "flow_id": "00000000-0000-4000-8000-0000000000f1", "identity": { "id": "{{MEMBER_ID}}", "schema_id": "default", "traits": { "email": "{{MEMBER_EMAIL}}", "name": "x", "role": "admin" } } }
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "extra_forbidden"

POST {{KANAE_URL}}/member/webhooks/registration
Content-Type: application/json
X-Webhook-Token: forged
{ "nope": true }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "flow_id"
jsonpath "$.errors[*].loc[*]" contains "identity"


# A non-JSON body is refused by validation before the token is compared.
POST {{KANAE_URL}}/member/webhooks/registration
Content-Type: text/plain
X-Webhook-Token: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
```
not even json
```
HTTP 422
[Asserts]
jsonpath "$.errors[*].type" contains "model_attributes_type"

# A NUL byte in a trait, without a token, is refused on the missing header
# and never gets near a database write.
POST {{KANAE_URL}}/member/webhooks/registration
Content-Type: application/json
{ "flow_id": "00000000-0000-4000-8000-0000000000f1", "identity": { "id": "00000000-0000-4000-8000-0000000000ab", "schema_id": "default", "traits": { "email": "forged@hurl.test.local", "name": "ev\u0000il" } } }
HTTP 422
[Asserts]
jsonpath "$.errors[*].loc[*]" contains "x-webhook-token"

GET {{KANAE_URL}}/members/00000000-0000-4000-8000-0000000000ab
HTTP 404

GET {{KANAE_URL}}/member/webhooks/registration
HTTP 405
[Asserts]
header "allow" == "POST"

GET {{KANAE_URL}}/member/webhooks/settings
HTTP 405
[Asserts]
header "allow" == "POST"
