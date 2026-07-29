# The dashboard's manage/projects page loads its invite tab from
# GET /projects/invites with `?status=pending` — one cross-project read,
# no project id anywhere. This scenario walks that exact call plus the
# gate around it.
#
# Two things separate this route from /projects/{id}/invites:
#   - The gate is `check_any(has_role(MANAGER), has_role(ADMIN))`.
#     `Project.edit` cannot appear here: has_permissions resolves the
#     object id out of request.path_params["project_id"], and this path
#     has none. So LEADS — a lead by Keto grant rather than by role — is
#     refused here even though it reads the per-project route freely.
#   - The rows span every project, not one. Proven below by comparing
#     the global count against the count for a single project taken
#     out of the same response.
#
# A 422 with `uuid_parsing` on any call here means the route ended up
# registered after GET /projects/{project_id} and the parameterized
# path swallowed the literal one (Starlette matches in registration
# order).
#
# Reads only — nothing is created, so this scenario spends nothing from
# the 15/minute /projects/create budget. It does assume the earlier
# invite scenarios (34-38) have run and left invites on several
# projects, which is what the cross-project assertions rest on; the
# suite is run as one glob (tests/integration/init.sh).
# Handler-reached calls: 5 of this route's 10/minute (4 as MANAGER, 1 as
# ADMIN) plus one per-project read. The 401/403s are refused by the
# dependency before the limiter and cost nothing.

# --- No session at all: 401, not 422 and not 403. ---
GET {{KANAE_URL}}/projects/invites?status=pending
HTTP 401
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.result" == "error"

# --- MANAGER: the page load. ---
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MANAGER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{MANAGER_ID}}"

# Byte-for-byte what manageInvitesQueryOptions issues on mount.
GET {{KANAE_URL}}/projects/invites?status=pending
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$" isCollection
# the filter is applied server-side — no other status may come back
jsonpath "$[*].status" not contains "accepted"
jsonpath "$[*].status" not contains "declined"
jsonpath "$[*].status" not contains "revoked"
jsonpath "$[*].status" not contains "expired"

# Unfiltered, and the cross-project claim. `total` is every invite in
# the system; `first_project` is the project of the newest one.
GET {{KANAE_URL}}/projects/invites
HTTP 200
[Captures]
first_project: jsonpath "$[0].project_id"
total: jsonpath "$" count
[Asserts]
jsonpath "$" isCollection
jsonpath "$" count > 1
# the shape the page renders each row from
jsonpath "$[0].id" isString
jsonpath "$[0].project_id" isString
jsonpath "$[0].member.id" isString
jsonpath "$[0].member.name" isString
jsonpath "$[0].kind" matches "invite|request"
jsonpath "$[0].status" matches "pending|accepted|declined|revoked|expired"
jsonpath "$[0].created_at" isString
jsonpath "$[*].project_id" contains "{{first_project}}"

# Same manager, same invite model, scoped to one project: strictly
# fewer rows. That gap is the whole point of the new route — the rows
# it returned above belong to projects this call cannot see.
GET {{KANAE_URL}}/projects/{{first_project}}/invites
HTTP 200
[Asserts]
jsonpath "$" isCollection
jsonpath "$" count < {{total}}

# kind filter, the one-placeholder branch of the constraint.
GET {{KANAE_URL}}/projects/invites?kind=request
HTTP 200
[Asserts]
jsonpath "$[*].kind" not contains "invite"

# Both filters set, the two-placeholder branch.
GET {{KANAE_URL}}/projects/invites?status=pending&kind=invite
HTTP 200
[Asserts]
jsonpath "$[*].kind" not contains "request"
jsonpath "$[*].status" not contains "accepted"
jsonpath "$[*].status" not contains "declined"
jsonpath "$[*].status" not contains "revoked"
jsonpath "$[*].status" not contains "expired"

# --- ADMIN: admitted by the second arm of the check. ---
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{ADMIN_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{ADMIN_ID}}"

# Roles are flat (scripts/seed/init.sh grants one tuple per member), so
# the admin holds no manager role...
GET {{KETO_READ_URL}}/relation-tuples/check?namespace=Role&object=manager&relation=member&subject_id={{ADMIN_ID}}
HTTP 403
[Asserts]
jsonpath "$.allowed" == false

# ...and there is no resource in this path for the has_permissions
# bypass to key off. This 200 comes from has_role(ADMIN) alone.
GET {{KANAE_URL}}/projects/invites?status=pending
HTTP 200
[Asserts]
jsonpath "$" isCollection

# --- LEADS: a lead by Keto grant, refused here. ---
# Scenario 37 grants LEADS Project.edit on its project, which opens
# GET /projects/{id}/invites there. This route has no such arm.
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{LEADS_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{LEADS_ID}}"

GET {{KANAE_URL}}/projects/invites?status=pending
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# --- MEMBER: no roles at all. ---
GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MEMBER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Asserts]
jsonpath "$.session.identity.id" == "{{MEMBER_ID}}"

GET {{KANAE_URL}}/projects/invites
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# Query params don't change the answer — the gate runs before them.
GET {{KANAE_URL}}/projects/invites?status=pending&kind=invite
HTTP 403
