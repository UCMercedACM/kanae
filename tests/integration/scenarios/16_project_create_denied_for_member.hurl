# /projects/create gates on has_role(MANAGER). LEADS and ADMIN both
# lack Role.MANAGER (bootstrap.sh writes only the role each identity
# is named after). This scenario hits every project-mutation endpoint
# as MEMBER to verify dependency wiring across the whole router, then
# confirms the read paths and create-listing aren't polluted.

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
[Asserts]
jsonpath "$.session.identity.id" == "{{MEMBER_ID}}"

# Create — 403 even with a valid body.
POST {{KANAE_URL}}/projects/create
Content-Type: application/json
{
  "name": "scenario17-denied",
  "description": "should never insert",
  "link": "https://example.test/denied",
  "type": "independent",
  "active": true,
  "founded_at": "2024-01-01T00:00:00Z"
}
HTTP 403
[Asserts]
jsonpath "$.result" == "error"

# Edit on a junk project — Project.edit check fires before not-found.
PUT {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777777
Content-Type: application/json
{ "name": "n", "description": "d", "link": "https://example.test/x" }
HTTP 403

# Delete on a junk project — Project.own check fires before not-found.
DELETE {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777777
HTTP 403

# Bulk-join requires has_role(MANAGER) OR Project.own — MEMBER has
# neither.
POST {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777777/bulk-join
Content-Type: application/json
[{ "id": "{{MEMBER_ID}}" }]
HTTP 403

# Member role modify — Project.own AND Role.MANAGER required.
PUT {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777777/member/modify
Content-Type: application/json
{ "id": "{{MEMBER_ID}}", "role": "lead" }
HTTP 403

# Sentinel project was never created.
GET {{KANAE_URL}}/projects
HTTP 200
[Asserts]
body not contains "scenario17-denied"

# But individual project lookups are public, so they don't 403 on
# read — only on mutation. /projects/{junk-id} 404s, not 403.
GET {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777777
HTTP 404

# A MEMBER CAN still join an existing project (no role required).
# /projects/{junk-id}/join → FK violation → 404 (transaction rolled
# back).
POST {{KANAE_URL}}/projects/77777777-7777-4777-8777-777777777777/join
HTTP 404
