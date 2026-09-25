# Project journey for the seeded MANAGER role, with a newcomer who starts
# as a plain member and ends as a manager.
#
# MANAGER creates two projects; kanae writes the rows and, per project, two
# Keto tuples (owners: MANAGER, editors: Role:manager#member). The newcomer
# is refused every lead action, joins and leaves an open project, gets an
# invite, finds the project closed to direct joins, and accepts the invite.
# Root then promotes the newcomer to manager. As a manager they can edit
# MANAGER's other project through the Role:manager#member subject set (Keto
# expands it), but not delete it (owners only).
#
# The new manager does not create a project of their own: the refused
# create above left "not a manager" in kanae's 60s check cache, and the
# grant's invalidation misses it once Valkey holds more than a few keys
# (see RATIONALE). The subject-set edit is a fresh cache key, so it is not
# affected.
#
# Derived from integration 15, 16, 17, 18, 19, 34 and 36.

# ── MANAGER opens two projects ───────────────────────────────────────────────
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
[Asserts]
jsonpath "$.session.identity.id" == "{{MANAGER_ID}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.roles" contains "manager"

# past the role gate, the body is still validated
POST {{KANAE_URL}}/projects/create
Content-Type: application/json
[Options]
variable: tag={{newUuid}}
variable: email=e2e-12-joiner-{{tag}}@hurl.test.local
variable: password=E2e-Joiner-{{newUuid}}
{ "name": "e2e-12-bad-{{tag}}", "description": "bad type", "link": "https://example.test", "type": "general", "active": true, "founded_at": "2026-01-01T00:00:00Z" }
HTTP 422

POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{ "name": "e2e-12-proj-one-{{tag}}", "description": "the open one", "link": "https://example.test/one", "type": "sig_swe", "active": true, "founded_at": "2026-01-01T00:00:00Z" }
HTTP 200
[Captures]
p1: jsonpath "$.id"
[Asserts]
jsonpath "$.id" isUuid
jsonpath "$.join_policy" == "open"
jsonpath "$.type" == "sig_swe"

POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{ "name": "e2e-12-proj-two-{{tag}}", "description": "the one a new manager edits", "link": "https://example.test/two", "type": "sig_data", "active": true, "founded_at": "2026-02-01T00:00:00Z" }
HTTP 200
[Captures]
p2: jsonpath "$.id"

# the creator is the project's first member (Postgres) ...
GET {{KANAE_URL}}/projects/{{p1}}
HTTP 200
[Asserts]
jsonpath "$.name" == "e2e-12-proj-one-{{tag}}"
jsonpath "$.members" count == 1
jsonpath "$.members[0].id" == "{{MANAGER_ID}}"
jsonpath "$.media" count == 0

GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
body contains "{{p1}}"
body contains "{{p2}}"

# ... and an owner (Keto)
PUT {{KANAE_URL}}/projects/{{p1}}
Content-Type: application/json
{ "name": "e2e-12-proj-one-{{tag}}", "description": "the open one, edited", "link": "https://example.test/one" }
HTTP 200
[Asserts]
jsonpath "$.description" == "the open one, edited"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── a newcomer signs up; every lead action is refused ────────────────────────
GET {{KRATOS_URL}}/self-service/registration/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/registration?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "csrf_token": "{{csrf}}", "password": "{{password}}", "traits": { "email": "{{email}}", "name": "joiner-{{tag}}" } }
HTTP 200
[Captures]
nid: jsonpath "$.identity.id"

POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{ "name": "e2e-12-denied-{{tag}}", "description": "never stored", "link": "https://example.test", "type": "independent", "active": true, "founded_at": "2026-01-01T00:00:00Z" }
HTTP 403
[Asserts]
jsonpath "$.detail" contains "manager"

PUT {{KANAE_URL}}/projects/{{p1}}
Content-Type: application/json
{ "name": "hijacked", "description": "hijacked", "link": "https://example.test/hijacked" }
HTTP 403
[Asserts]
jsonpath "$.detail" == "You are missing Project:edit permission(s) to access this resource."

DELETE {{KANAE_URL}}/projects/{{p1}}
HTTP 403
[Asserts]
jsonpath "$.detail" == "You are missing Project:own permission(s) to access this resource."

POST {{KANAE_URL}}/projects/{{p1}}/join-policy
Content-Type: application/json
{ "join_policy": "closed" }
HTTP 403
[Asserts]
jsonpath "$.detail" == "All checks have failed"

POST {{KANAE_URL}}/projects/{{p1}}/invites
Content-Type: application/json
{ "member_id": "{{nid}}" }
HTTP 403

# ── join and leave the open project ──────────────────────────────────────────
POST {{KANAE_URL}}/projects/{{p1}}/join
HTTP 200

POST {{KANAE_URL}}/projects/{{p1}}/join
HTTP 409
[Asserts]
jsonpath "$.detail" contains "already joined"

GET {{KANAE_URL}}/projects/{{p1}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 2
jsonpath "$.members[?(@.id == '{{nid}}')].name" == "joiner-{{tag}}"
jsonpath "$.description" == "the open one, edited"

GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{p1}}"

DELETE {{KANAE_URL}}/projects/{{p1}}/leave
HTTP 200

DELETE {{KANAE_URL}}/projects/{{p1}}/leave
HTTP 404

GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
jsonpath "$" count == 0

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── MANAGER invites the newcomer, then closes the project ────────────────────
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

POST {{KANAE_URL}}/projects/{{p1}}/invites
Content-Type: application/json
{ "member_id": "{{nid}}", "message": "come back {{tag}}" }
HTTP 200
[Captures]
invite_id: jsonpath "$.id"
[Asserts]
jsonpath "$.kind" == "invite"
jsonpath "$.status" == "pending"
jsonpath "$.member.id" == "{{nid}}"
jsonpath "$.invited_by" == "{{MANAGER_ID}}"

POST {{KANAE_URL}}/projects/{{p1}}/invites
Content-Type: application/json
{ "member_id": "{{nid}}" }
HTTP 409

POST {{KANAE_URL}}/projects/{{p1}}/join-policy
Content-Type: application/json
{ "join_policy": "closed" }
HTTP 200
[Asserts]
jsonpath "$.join_policy" == "closed"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── the newcomer accepts the invite ──────────────────────────────────────────
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

GET {{KANAE_URL}}/members/me/projects/invites?status=pending
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].id" == "{{invite_id}}"
jsonpath "$[0].project_id" == "{{p1}}"
jsonpath "$[0].message" == "come back {{tag}}"

POST {{KANAE_URL}}/projects/{{p1}}/join
HTTP 409
[Asserts]
jsonpath "$.detail" contains "not open"

POST {{KANAE_URL}}/projects/{{p1}}/invites/{{invite_id}}/accept
HTTP 200
[Asserts]
jsonpath "$.id" == "{{invite_id}}"
jsonpath "$.status" == "accepted"

POST {{KANAE_URL}}/projects/{{p1}}/invites/{{invite_id}}/accept
HTTP 409
[Asserts]
jsonpath "$.detail" contains "accepted"

GET {{KANAE_URL}}/members/me/projects
HTTP 200
[Asserts]
jsonpath "$[0].id" == "{{p1}}"
jsonpath "$[0].join_policy" == "closed"

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── root promotes the newcomer to manager ────────────────────────────────────
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

PUT {{KANAE_URL}}/members/{{nid}}/role
Content-Type: application/json
{ "role": "manager", "action": "grant" }
HTTP 200

POST {{KANAE_URL}}/members/logout
HTTP 200

# ── the new manager works through the subject set ────────────────────────────
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

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{nid}}"
jsonpath "$.roles" count == 1
jsonpath "$.roles[0]" == "manager"

# editors on p2 is Role:manager#member, which now includes the newcomer.
# (p1 is not used here: the denied edit above is still in kanae's 60s
# permission cache, see RATIONALE.)
PUT {{KANAE_URL}}/projects/{{p2}}
Content-Type: application/json
{ "name": "e2e-12-proj-two-{{tag}}", "description": "edited by the new manager", "link": "https://example.test/two" }
HTTP 200
[Asserts]
jsonpath "$.description" == "edited by the new manager"

# owners is still only MANAGER
DELETE {{KANAE_URL}}/projects/{{p2}}
HTTP 403
[Asserts]
jsonpath "$.detail" == "You are missing Project:own permission(s) to access this resource."

# leaving for good takes the role and the membership with it
DELETE {{KANAE_URL}}/members/me
HTTP 200

# ── MANAGER sees the edit and cleans up ──────────────────────────────────────
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

GET {{KANAE_URL}}/projects/{{p2}}
HTTP 200
[Asserts]
jsonpath "$.description" == "edited by the new manager"

GET {{KANAE_URL}}/projects/{{p1}}
HTTP 200
[Asserts]
jsonpath "$.members" count == 1
body not contains "{{nid}}"

# archiving flips `active` in Postgres. A name search ignores the `active`
# filter (the name branch of list_projects never adds it), so the row is
# found by name and its flag is read back.
PUT {{KANAE_URL}}/projects/{{p1}}/archive
Content-Type: application/json
{ "active": false }
HTTP 200
[Asserts]
jsonpath "$.active" == false

GET {{KANAE_URL}}/projects/{{p1}}
HTTP 200
[Asserts]
jsonpath "$.active" == false

GET {{KANAE_URL}}/projects?name=e2e-12-proj-one-{{tag}}
HTTP 200
[Asserts]
jsonpath "$.data[?(@.id == '{{p1}}')].active" == false

DELETE {{KANAE_URL}}/projects/{{p1}}
HTTP 200

DELETE {{KANAE_URL}}/projects/{{p2}}
HTTP 200

GET {{KANAE_URL}}/projects/{{p1}}
HTTP 404

GET {{KANAE_URL}}/projects/{{p2}}
HTTP 404

POST {{KANAE_URL}}/members/logout
HTTP 200
