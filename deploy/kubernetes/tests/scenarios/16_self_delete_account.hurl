# Account-deletion journey. A new member joins a manager's project, then
# deletes their own account. DELETE /members/me removes the members row in
# Postgres (project_members cascades), then kanae revokes every session
# through the Kratos admin API, purges the member's Keto tuples and deletes
# the Kratos identity.
#
# "Kratos forgot" is shown three ways: whoami rejects the old cookie, the
# old password no longer logs in, and the same email registers again as a
# brand-new identity (the registration webhook's insert would fail on a
# leftover row, and Kratos would refuse a leftover credential).
#
# kanae itself is not asked about the deleted cookie: it may serve it from
# the whoami cache for up to 60s (known bug, reported separately).
#
# Derived from integration 18 and 28.

DELETE {{KANAE_URL}}/members/me
HTTP 401

# ── a manager opens a project to join ────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MANAGER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

POST {{KANAE_URL}}/projects/create
Content-Type: application/json
[Options]
variable: tag={{newUuid}}
variable: email=e2e-16-leaver-{{tag}}@hurl.test.local
variable: password=E2e-16-Leaver-{{newUuid}}
{ "name": "e2e-16-leaver-project-{{tag}}", "description": "joined, then the joiner leaves for good", "link": "https://example.test/e2e-16-leaver", "type": "independent", "active": true, "founded_at": "2026-01-01T00:00:00Z" }
HTTP 200
[Captures]
pid: jsonpath "$.id"
[Asserts]
jsonpath "$.join_policy" == "open"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── sign up and join ─────────────────────────────────────────────────────────
GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{password}}", "traits": { "email": "{{email}}", "name": "leaver-{{tag}}" } }
HTTP 200
[Captures]
uid: jsonpath "$.identity.id"

POST {{KANAE_URL}}/projects/{{pid}}/join
HTTP 200

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid}}"
jsonpath "$.projects" count == 1
jsonpath "$.projects[0].id" == "{{pid}}"

GET {{KANAE_URL}}/projects/{{pid}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 2
jsonpath "$.members[?(@.id == '{{uid}}')].name" == "leaver-{{tag}}"

# ── delete the account ───────────────────────────────────────────────────────
DELETE {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.message" exists

# Kratos: the session was revoked with the identity
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

# Postgres: the row and the membership are gone (public reads, no session)
GET {{KANAE_URL}}/members/{{uid}}
HTTP 404

GET {{KANAE_URL}}/projects/{{pid}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 1
jsonpath "$.members[0].id" == "{{MANAGER_ID}}"
body not contains "{{uid}}"

# ── Kratos forgot the credential ─────────────────────────────────────────────
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
HTTP 400
[Asserts]
jsonpath "$.ui.messages[0].id" == 4000006
cookie "ory_kratos_session" not exists

# ── the same email signs up again as someone new ─────────────────────────────
GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{password}}", "traits": { "email": "{{email}}", "name": "returner-{{tag}}" } }
HTTP 200
[Captures]
uid2: jsonpath "$.identity.id"
[Asserts]
jsonpath "$.identity.id" != "{{uid}}"
jsonpath "$.identity.traits.email" == "{{email}}"

# a fresh row: new id, new name, none of the old memberships
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{uid2}}"
jsonpath "$.name" == "returner-{{tag}}"
jsonpath "$.email" == "{{email}}"
jsonpath "$.projects" count == 0
jsonpath "$.roles" count == 0

GET {{KANAE_URL}}/members/{{uid}}
HTTP 404

DELETE {{KANAE_URL}}/members/me
HTTP 200

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

# ── cleanup: the manager deletes the project ─────────────────────────────────
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
lflow: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{lflow}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MANAGER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200

DELETE {{KANAE_URL}}/projects/{{pid}}
HTTP 200

GET {{KANAE_URL}}/projects/{{pid}}
HTTP 404

POST {{KANAE_URL}}/members/logout
HTTP 200
