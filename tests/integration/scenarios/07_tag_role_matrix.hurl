# Real Keto enforcement: only ADMIN may mutate tags. MEMBER, LEADS,
# and MANAGER are all denied on every mutating endpoint. Catches the
# regression where one endpoint loses its `has_role(Role.ADMIN)`
# dependency. A misconfigured Keto policy that lets `leads` through
# would fail loudly here.

# --- as MEMBER → 403 on every tag mutation ---
GET {{KRATOS_URL}}/self-service/login/browser
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

POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario08-member-create", "description": "no" }
HTTP 403
[Asserts]
jsonpath "$.result" == "error"
jsonpath "$.detail" isString

POST {{KANAE_URL}}/tags/bulk-create
Content-Type: application/json
[{ "title": "scenario08-member-bulk", "description": "no" }]
HTTP 403

PUT {{KANAE_URL}}/tags/1
Content-Type: application/json
{ "title": "x", "description": "x" }
HTTP 403

DELETE {{KANAE_URL}}/tags/1
HTTP 403

# --- as LEADS (refresh=true since the MEMBER session is in the jar) ---
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

POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario08-leads-create", "description": "no" }
HTTP 403

PUT {{KANAE_URL}}/tags/1
Content-Type: application/json
{ "title": "x", "description": "x" }
HTTP 403

DELETE {{KANAE_URL}}/tags/1
HTTP 403

# --- as MANAGER → 403 (only ADMIN may mutate tags) ---
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

POST {{KANAE_URL}}/tags/create
Content-Type: application/json
{ "title": "scenario08-manager-create", "description": "no" }
HTTP 403

POST {{KANAE_URL}}/tags/bulk-create
Content-Type: application/json
[{ "title": "scenario08-manager-bulk", "description": "no" }]
HTTP 403

DELETE {{KANAE_URL}}/tags/1
HTTP 403

# Public reads still allowed for all three identities (the last one
# is still logged in here).
GET {{KANAE_URL}}/tags
HTTP 200
