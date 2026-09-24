# Edge: Envoy -> kanae:8000 through the `/` HTTPRoute rule. Proves the
# catch-all forwards every path and method to kanae, that kanae's rendered
# config is the local one (allowedOrigins https://kanae:5173, the limiter off
# so a burst is not throttled), that public routes carry real traffic, and
# that a browser session cookie set by Kratos through /auth is accepted by
# kanae through /. One password login (one argon2 hash).
#
# Derived from integration 01, 03, 05, 10 and 15 (public lists).

# ── the app is behind `/` ──

GET {{KANAE_URL}}/
HTTP 307
[Asserts]
header "location" == "/docs"

GET {{KANAE_URL}}/docs
HTTP 200
[Asserts]
header "content-type" startsWith "text/html"
body contains "/openapi.json"

# The OpenAPI document lists the public routes and hides the Kratos webhooks
# (include_in_schema=False), so the internal surface is not advertised.
GET {{KANAE_URL}}/openapi.json
HTTP 200
[Asserts]
jsonpath "$.openapi" matches /^3\./
jsonpath "$.paths['/members/me']" exists
jsonpath "$.paths['/members/logout']" exists
jsonpath "$.paths['/tags']" exists
jsonpath "$.paths['/member/webhooks/registration']" not exists
jsonpath "$.paths['/member/webhooks/settings']" not exists
jsonpath "$.paths['/sudo/elevate']" not exists

# ── public routes carry traffic, and keep doing so under a burst (limiter disabled) ──

GET {{KANAE_URL}}/tags
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$" isCollection

GET {{KANAE_URL}}/events
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" isInteger

GET {{KANAE_URL}}/projects
HTTP 200
[Asserts]
jsonpath "$.data" isCollection
jsonpath "$.total" isInteger

GET {{KANAE_URL}}/tags
[Options]
repeat: 30
HTTP 200
[Asserts]
jsonpath "$" isCollection

# ── every method reaches kanae; kanae answers 404/405/422 itself ──

GET {{KANAE_URL}}/members/not-a-uuid
HTTP 422
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.errors[0].loc" contains "member_id"

PUT {{KANAE_URL}}/no/such/path
Content-Type: application/json
{ "x": 1 }
HTTP 404
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Not Found"

DELETE {{KANAE_URL}}/no/such/path
HTTP 404
[Asserts]
header "server" == "granian"

PATCH {{KANAE_URL}}/tags
HTTP 405
[Asserts]
header "server" == "granian"
header "allow" == "GET"

# ── CORS: allowedOrigins from values.local.yml ──

OPTIONS {{KANAE_URL}}/tags
Origin: https://kanae:5173
Access-Control-Request-Method: GET
Access-Control-Request-Headers: content-type
HTTP 200
[Asserts]
header "access-control-allow-origin" == "https://kanae:5173"
header "access-control-allow-credentials" == "true"
header "access-control-allow-methods" contains "PATCH"
header "access-control-allow-headers" contains "Content-Type"

OPTIONS {{KANAE_URL}}/tags
Origin: https://evil.example
Access-Control-Request-Method: GET
HTTP 400
[Asserts]
header "access-control-allow-origin" not exists
body == "Disallowed CORS origin"

# The compose suite's origin is not on this cluster's list.
OPTIONS {{KANAE_URL}}/tags
Origin: http://localhost:5173
Access-Control-Request-Method: GET
HTTP 400
[Asserts]
header "access-control-allow-origin" not exists

# The allow-list is an exact match. The wrong scheme, the wrong port, a
# subdomain, a lookalike suffix, a trailing slash and the opaque `null`
# origin are all refused.
OPTIONS {{KANAE_URL}}/tags
Origin: http://kanae:5173
Access-Control-Request-Method: GET
HTTP 400
[Asserts]
header "access-control-allow-origin" not exists

OPTIONS {{KANAE_URL}}/tags
Origin: https://kanae
Access-Control-Request-Method: GET
HTTP 400
[Asserts]
header "access-control-allow-origin" not exists

OPTIONS {{KANAE_URL}}/tags
Origin: https://evil.kanae:5173
Access-Control-Request-Method: GET
HTTP 400
[Asserts]
header "access-control-allow-origin" not exists

OPTIONS {{KANAE_URL}}/tags
Origin: https://kanae:5173.evil.example
Access-Control-Request-Method: GET
HTTP 400
[Asserts]
header "access-control-allow-origin" not exists

OPTIONS {{KANAE_URL}}/tags
Origin: https://kanae:5173/
Access-Control-Request-Method: GET
HTTP 400
[Asserts]
header "access-control-allow-origin" not exists

OPTIONS {{KANAE_URL}}/tags
Origin: null
Access-Control-Request-Method: GET
HTTP 400
[Asserts]
header "access-control-allow-origin" not exists

# CORS is middleware that runs before auth, so the preflight for a
# session-gated route is still granted to the SPA origin.
OPTIONS {{KANAE_URL}}/sudo
Origin: https://kanae:5173
Access-Control-Request-Method: GET
HTTP 200
[Asserts]
header "access-control-allow-origin" == "https://kanae:5173"
header "access-control-allow-credentials" == "true"

OPTIONS {{KANAE_URL}}/sudo/elevate
Origin: https://kanae:5173
Access-Control-Request-Method: POST
Access-Control-Request-Headers: content-type
HTTP 200
[Asserts]
header "access-control-allow-origin" == "https://kanae:5173"
header "access-control-allow-methods" contains "POST"

GET {{KANAE_URL}}/tags
Origin: https://kanae:5173
HTTP 200
[Asserts]
header "access-control-allow-origin" == "https://kanae:5173"
header "access-control-allow-credentials" == "true"

GET {{KANAE_URL}}/tags
Origin: https://evil.example
HTTP 200
[Asserts]
header "access-control-allow-origin" not exists

# ── auth-gated routes without a usable cookie: 401 shaped by kanae ──

GET {{KANAE_URL}}/members/me
HTTP 401
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$.result" == "error"
jsonpath "$.detail" == "Authentication required"

GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session=
HTTP 401

GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session=not-a-real-session
HTTP 401
[Asserts]
jsonpath "$.detail" == "Authentication required"

POST {{KANAE_URL}}/members/logout
HTTP 401

GET {{KANAE_URL}}/members
HTTP 401

POST {{KANAE_URL}}/sudo/elevate
Content-Type: application/json
{ "reason": "no session" }
HTTP 401

# ── a Kratos cookie set through /auth is honoured by kanae through / ──

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

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
header "server" == "granian"
jsonpath "$.id" == "{{MEMBER_ID}}"
jsonpath "$.email" == "{{MEMBER_EMAIL}}"
jsonpath "$.roles" isCollection

# A cross-origin credentialed read from the SPA origin gets the CORS headers
# alongside the authenticated body.
GET {{KANAE_URL}}/members/me
Origin: https://kanae:5173
HTTP 200
[Asserts]
header "access-control-allow-origin" == "https://kanae:5173"
header "access-control-allow-credentials" == "true"
jsonpath "$.id" == "{{MEMBER_ID}}"

POST {{KANAE_URL}}/members/logout
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

GET {{KANAE_URL}}/members/me
HTTP 401
