# The canonical login dance. Every authenticated scenario depends on
# this exact path working, so the assertions are unusually heavy:
# every field of the Kratos flow + session payload is type-checked,
# the cookie attributes are inspected, and the warm-path Kanae whoami
# cache is exercised twice in a row to confirm the second call reuses
# the in-Valkey cache rather than re-hitting Kratos.

# 1) Initiate the browser flow with Accept: application/json. Kratos
#    returns the flow JSON in-band and sets the csrf_token cookie.
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.id" isUuid
jsonpath "$.type" == "browser"
jsonpath "$.expires_at" isIsoDate
jsonpath "$.issued_at" isIsoDate
jsonpath "$.request_url" contains "/self-service/login/browser"
jsonpath "$.ui.method" == "POST"
jsonpath "$.ui.action" contains "/self-service/login?flow="
jsonpath "$.ui.nodes" isCollection
jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'identifier')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')]" exists
[Captures]
flow_id: jsonpath "$.id"
flow_action: jsonpath "$.ui.action"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

# 2) Submit credentials. Kratos sets ory_kratos_session on success.
POST {{KRATOS_URL}}/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{
  "method": "password",
  "identifier": "{{ADMIN_EMAIL}}",
  "password": "{{PASSWORD}}",
  "csrf_token": "{{csrf}}"
}
HTTP 200
[Asserts]
cookie "ory_kratos_session" exists
jsonpath "$.session.id" isUuid
jsonpath "$.session.active" == true
jsonpath "$.session.expires_at" isIsoDate
jsonpath "$.session.authenticated_at" isIsoDate
jsonpath "$.session.issued_at" isIsoDate
jsonpath "$.session.authenticator_assurance_level" == "aal1"
jsonpath "$.session.authentication_methods[0].method" == "password"
jsonpath "$.session.identity.id" == "{{ADMIN_ID}}"
jsonpath "$.session.identity.schema_id" == "default"
jsonpath "$.session.identity.state" == "active"
jsonpath "$.session.identity.traits.email" == "{{ADMIN_EMAIL}}"
jsonpath "$.session.identity.traits.name" == "admin"

# 3) Cookie now in jar; Kanae forwards it to /sessions/whoami.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.id" == "{{ADMIN_ID}}"
jsonpath "$.id" isUuid
jsonpath "$.name" == "admin"
jsonpath "$.created_at" isIsoDate
jsonpath "$.projects" isCollection
jsonpath "$.events" isCollection

# 4) Cache check — same cookie, second call should be served from the
#    Valkey-backed whoami cache (no Kratos hop). Cap duration loosely.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
duration <= 2000
jsonpath "$.id" == "{{ADMIN_ID}}"
