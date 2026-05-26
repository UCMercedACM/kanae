# Sentry scenario: granting Project.<id>#edit via Keto unlocks the
# route for an identity that isn't the project owner. A
# misconfigured Keto policy that lets MEMBERs through unconditionally
# would fail loudly here.


# --- MANAGER creates the project ---
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

POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{
  "name": "scenario20-allowed",
  "description": "member-locked, will be granted",
  "link": "https://example.test/allowed",
  "type": "sig_cyber",
  "active": true,
  "founded_at": "2024-01-01T00:00:00Z"
}
HTTP 200
[Captures]
project_id: jsonpath "$.id"

# --- switch to MEMBER (refresh=true since MANAGER session is in jar) ---
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

# Grant Project:<id>#edit to MEMBER BEFORE the first PUT against it
# so no cached False sits on (Project, project_id, edit, MEMBER).
PUT {{KETO_WRITE_URL}}/admin/relation-tuples
Content-Type: application/json
Accept: application/json
{ "namespace": "Project", "object": "{{project_id}}", "relation": "edit", "subject_id": "{{MEMBER_ID}}" }
HTTP 201
[Asserts]
jsonpath "$.namespace" == "Project"
jsonpath "$.object" == "{{project_id}}"
jsonpath "$.relation" == "edit"
jsonpath "$.subject_id" == "{{MEMBER_ID}}"

PUT {{KANAE_URL}}/projects/{{project_id}}
Content-Type: application/json
{ "name": "scenario20-now-editable", "description": "allowed", "link": "https://example.test/x" }
HTTP 200
[Asserts]
jsonpath "$.id" == "{{project_id}}"
jsonpath "$.name" == "scenario20-now-editable"
jsonpath "$.description" == "allowed"

# Cross-check: GET reflects the edit.
GET {{KANAE_URL}}/projects/{{project_id}}
HTTP 200
[Asserts]
jsonpath "$.name" == "scenario20-now-editable"

# Edit grant doesn't imply delete grant — DELETE still 403.
DELETE {{KANAE_URL}}/projects/{{project_id}}
HTTP 403
