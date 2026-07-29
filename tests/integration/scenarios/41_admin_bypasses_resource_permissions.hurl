# Regression: an ADMIN could not read the attendance of an event it did not
# create. Event creation writes only `owners@creator` and
# `editors@Role:leads#member` (routes/events.py), and project creation only
# `owners@creator` and `editors@Role:manager#member` — so a global admin holds
# NO relation tuple on any resource it did not personally create. Keto's OPL
# cannot express "admins reach every object in a namespace" without a per-object
# tuple, so `has_permissions` carries the bypass instead.
#
# This scenario proves both halves at once:
#   1. Keto itself still says NO for the admin on the resource (direct check
#      against KETO_READ_URL returns 403 / allowed:false).
#   2. Kanae says YES anyway, because of the bypass in has_permissions.
#
# LEADS/MANAGER create the resources so that ADMIN is genuinely un-tupled;
# creating them as ADMIN would grant `owners` and prove nothing.
#
# Note: `check_permission` is @cached_method for 60s keyed on
# `(namespace, object, relation, subject_id)`. Every resource here is created
# fresh inside this scenario, so no stale entry can pre-exist.

# --- LEADS creates the event (and auto-owns it).

GET {{KRATOS_URL}}/self-service/login/browser
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

POST {{KANAE_URL}}/events/create
Content-Type: application/json
{
  "id": "41414141-4141-4141-8141-414141414141",
  "name": "scenario41-admin-bypass",
  "description": "created by leads, read by admin",
  "start_at": "2099-06-01T00:00:00Z",
  "end_at":   "2099-06-01T03:00:00Z",
  "location": "Online",
  "type": "general",
  "timezone": "UTC",
  "creator_id": "{{LEADS_ID}}"
}
HTTP 200
[Captures]
event_id: jsonpath "$.id"

# --- MANAGER creates the project (and auto-owns it).

GET {{KRATOS_URL}}/self-service/login/browser?refresh=true
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

POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{
  "name": "scenario41-admin-bypass",
  "description": "created by manager, edited by admin",
  "link": "https://example.test/scenario41",
  "type": "sig_arch",
  "active": true,
  "founded_at": "2024-01-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"

# --- Keto's own view: the ADMIN holds nothing on either resource.
# The check endpoint answers 403 (not 200) when the relation does not hold.

GET {{KETO_READ_URL}}/relation-tuples/check?namespace=Event&object={{event_id}}&relation=edit&subject_id={{ADMIN_ID}}
HTTP 403
[Asserts]
jsonpath "$.allowed" == false

GET {{KETO_READ_URL}}/relation-tuples/check?namespace=Project&object={{project_id}}&relation=edit&subject_id={{ADMIN_ID}}
HTTP 403
[Asserts]
jsonpath "$.allowed" == false

# Sanity: the admin DOES hold the global role the bypass keys off.
GET {{KETO_READ_URL}}/relation-tuples/check?namespace=Role&object=admin&relation=member&subject_id={{ADMIN_ID}}
HTTP 200
[Asserts]
jsonpath "$.allowed" == true

# --- Switch to ADMIN. Kanae admits it anyway.

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

# The exact route from the bug report: has_permissions(Event.edit).
GET {{KANAE_URL}}/events/{{event_id}}/attendance?page=1&size=100
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" == 0

# Also gated on Event.edit.
GET {{KANAE_URL}}/events/{{event_id}}/attendance-code
HTTP 200
[Asserts]
jsonpath "$.code" isString

PUT {{KANAE_URL}}/events/{{event_id}}
Content-Type: application/json
{ "name": "scenario41-renamed-by-admin", "description": "admin edit", "location": "Online" }
HTTP 200
[Asserts]
jsonpath "$.name" == "scenario41-renamed-by-admin"

# Project side: has_permissions(Project.edit).
PUT {{KANAE_URL}}/projects/{{project_id}}
Content-Type: application/json
{ "name": "scenario41-renamed-by-admin", "description": "admin edit", "link": "https://example.test/scenario41" }
HTTP 200
[Asserts]
jsonpath "$.name" == "scenario41-renamed-by-admin"

# check_any(has_role(MANAGER), has_permissions(Project.edit)) — the admin
# passes via the inner has_permissions, not the role arm.
GET {{KANAE_URL}}/projects/{{project_id}}/invites?status=pending
HTTP 200

# check_any(has_role(MANAGER), has_permissions(Project.own)) — ADMIN matches
# neither arm directly; it gets in via the bypass inside has_permissions.
PUT {{KANAE_URL}}/projects/{{project_id}}/member/modify
Content-Type: application/json
{ "id": "{{MANAGER_ID}}", "role": "former" }
HTTP 200

# --- The bypass is Role.ADMIN only: a plain MEMBER is still refused.

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

GET {{KANAE_URL}}/events/{{event_id}}/attendance
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

PUT {{KANAE_URL}}/projects/{{project_id}}/member/modify
Content-Type: application/json
{ "id": "{{MEMBER_ID}}", "role": "lead" }
HTTP 403
