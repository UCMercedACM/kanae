# Edge: Envoy -> Kratos public port through the `/auth` HTTPRoute rule
# (PathPrefix /auth, URLRewrite ReplacePrefixMatch /). Proves the prefix
# boundary (/auth vs /auth/ vs /authx vs /AUTH), that only kratos:4433 is
# behind it (the admin API is not routed), and that the config Kratos serves
# through the Gateway is the rendered one: SERVE_PUBLIC_BASE_URL, the UI URLs
# and CORS origin from values.local.yml, cookie flags, allowed return URLs and
# the identity schema from the ConfigMap. One password login (one argon2
# hash) at the end pins the session cookie attributes and the logout flow.
#
# Also pins how Envoy treats odd paths before any route matches (doubled
# leading slash, an encoded-slash traversal) and that CORS on the Kratos side
# is only a browser control.
#
# Derived from integration 02 (login flow shape), 04 (logout) and 01.

# ── rendered config: base URL, csrf cookie flags ──

# First Kratos request of the file, so the jar has no csrf cookie yet and
# Kratos sets one: HttpOnly, SameSite=Lax, Path=/ and not Secure
# (ory.secureCookies=false). With Accept: application/json the flow comes
# back in-band and its action URL carries the public base URL with /auth.
GET {{KANAE_URL}}/auth/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
[Asserts]
jsonpath "$.id" isUuid
jsonpath "$.type" == "browser"
jsonpath "$.ui.action" == "https://kanae/auth/self-service/login?flow={{flow_id}}"
jsonpath "$.ui.method" == "POST"
jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'identifier')]" exists
jsonpath "$.ui.nodes[?(@.attributes.name == 'password')]" exists
header "set-cookie" matches /^csrf_token_[0-9a-f]{64}=[^;]+; Path=\/; Max-Age=31536000; HttpOnly; SameSite=Lax$/

# Kratos reports the request URL as it saw it after the rewrite: the `/auth`
# prefix is gone. Recorded here so a change in the rewrite shows up.
GET {{KANAE_URL}}/auth/self-service/login/browser
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.request_url" == "https://kanae/self-service/login/browser"

# ── prefix boundary ──

# `/auth` alone is rewritten to `/`, which Kratos does not serve: a Go
# text/plain 404 with Kratos' `vary` header and no granian `server` header.
GET {{KANAE_URL}}/auth
HTTP 404
[Asserts]
header "content-type" startsWith "text/plain"
header "vary" contains "Origin"
header "server" not exists
body contains "404 page not found"

GET {{KANAE_URL}}/auth/
HTTP 404
[Asserts]
header "content-type" startsWith "text/plain"
header "server" not exists
body contains "404 page not found"

# PathPrefix is segment-based: `/authx` is not under `/auth`, so it falls
# through to the `/` rule and kanae answers its own JSON 404.
GET {{KANAE_URL}}/authx
HTTP 404
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Not Found"

GET {{KANAE_URL}}/authx/health/ready
HTTP 404
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Not Found"

# Path matching is case-sensitive.
GET {{KANAE_URL}}/AUTH/health/ready
HTTP 404
[Asserts]
header "server" == "granian"

# The rewrite drops exactly the `/auth` prefix: `/auth/health/ready` becomes
# `/health/ready` at Kratos.
GET {{KANAE_URL}}/auth/health/ready
HTTP 200
[Asserts]
header "server" not exists
jsonpath "$.status" == "ok"

GET {{KANAE_URL}}/auth/health/alive
HTTP 200
[Asserts]
jsonpath "$.status" == "ok"

# A doubled slash after the prefix survives the rewrite as `//health/ready`,
# which Kratos' router still resolves.
GET {{KANAE_URL}}/auth//health/ready
HTTP 200
[Asserts]
jsonpath "$.status" == "ok"

# A doubled leading slash is merged before route matching, so it still lands
# on the /auth rule and reaches Kratos' real flow-init endpoint.
GET {{KANAE_URL}}//auth/self-service/login/browser
Accept: application/json
HTTP 200
[Asserts]
header "server" not exists
jsonpath "$.ui.action" contains "/self-service/login?flow="

# libcurl collapses a literal `..` before sending, so the wire request is
# plain `/members/me`: it only shows the resolved path still needs a session.
GET {{KANAE_URL}}/auth/../members/me
HTTP 401
[Asserts]
header "server" == "granian"

# An encoded-slash traversal is not collapsed client-side, so this exercises
# Envoy's own path handling: it answers with a redirect to the canonical path
# instead of proxying the raw traversal to either backend.
GET {{KANAE_URL}}/auth%2f..%2fmembers%2fme
HTTP 307
[Asserts]
header "location" == "/members/me"
header "server" not exists
header "content-type" not exists
bytes count == 0

GET {{KANAE_URL}}/auth%2F..%2Fmembers%2Fme
HTTP 307
[Asserts]
header "location" == "/members/me"
header "server" not exists

# Backslashes are treated as slashes too.
GET {{KANAE_URL}}/auth%5c..%5cmembers%5cme
HTTP 307
[Asserts]
header "location" == "/members/me"
header "server" not exists

# An encoded slash with no traversal is redirected to its decoded form, which
# the client must then request itself.
GET {{KANAE_URL}}/auth%2fsessions%2fwhoami
HTTP 307
[Asserts]
header "location" == "/auth/sessions/whoami"
header "server" not exists

# The admin API is not reachable this way either: the redirect points at a
# path with no route to port 4434.
GET {{KANAE_URL}}/auth%2f..%2fadmin%2fidentities
[Options]
path-as-is: true
HTTP 307
[Asserts]
header "location" == "/admin/identities"
header "server" not exists

GET {{KANAE_URL}}/admin/identities
HTTP 404
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Not Found"

# ── raw dot segments on the wire ──
# path-as-is stops libcurl collapsing them, so Envoy sees the traversal. It
# normalises before route matching: /auth/.. leaves the Kratos route and
# kanae (granian) answers the resolved path.
GET {{KANAE_URL}}/auth/../members/me
[Options]
path-as-is: true
HTTP 401
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Authentication required"

GET {{KANAE_URL}}/auth/%2e%2e/members/me
[Options]
path-as-is: true
HTTP 401
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Authentication required"

GET {{KANAE_URL}}/auth/..;/members/me
[Options]
path-as-is: true
HTTP 401
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Authentication required"

GET {{KANAE_URL}}/auth/../admin/identities
[Options]
path-as-is: true
HTTP 404
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Not Found"

# Traversal above the root clamps at /.
GET {{KANAE_URL}}/auth/../../../etc/passwd
[Options]
path-as-is: true
HTTP 404
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Not Found"

# /./ collapses and stays on the Kratos route.
GET {{KANAE_URL}}/auth/./sessions/whoami
Accept: application/json
[Options]
path-as-is: true
HTTP 401
[Asserts]
header "server" not exists
jsonpath "$.error.code" == 401

# The reverse also works: a kanae path that resolves into /auth is Kratos's.
GET {{KANAE_URL}}/members/../auth/health/ready
[Options]
path-as-is: true
HTTP 200
[Asserts]
header "server" not exists
jsonpath "$.status" == "ok"

# %61 is an unreserved character: Envoy decodes it to /auth before matching.
GET {{KANAE_URL}}/%61uth/health/ready
HTTP 200
[Asserts]
header "server" not exists
jsonpath "$.status" == "ok"

# The prefix match is per segment: "/auth;" is not "/auth".
GET {{KANAE_URL}}/auth;/health/ready
[Options]
path-as-is: true
HTTP 404
[Asserts]
header "server" == "granian"
jsonpath "$.detail" == "Not Found"

# "/auth/;/..." is on the Kratos route; after the rewrite Kratos's Go mux
# 404s "/;/health/ready" in plain text.
GET {{KANAE_URL}}/auth/;/health/ready
[Options]
path-as-is: true
HTTP 404
[Asserts]
header "server" not exists
header "content-type" == "text/plain; charset=utf-8"
body == "404 page not found\n"

# A NUL in the path is refused by Envoy before any route.
GET {{KANAE_URL}}/auth/health/ready%00
HTTP 400
[Asserts]
header "server" not exists

# A POST to the GET-only flow-init endpoint reaches a submission handler that
# demands a csrf token, so it is refused before touching the missing flow.
POST {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
HTTP 403
[Asserts]
jsonpath "$.error.id" == "security_csrf_violation"

# ── only the public port is behind /auth ──

# Kratos' public server answers admin paths with a redirect to its admin base
# URL. That URL is cluster-internal (no HTTPRoute, unresolvable from here), so
# nothing admin-side is reachable through the Gateway and no identity data
# leaks in the body.
GET {{KANAE_URL}}/auth/admin/identities
HTTP 307
[Asserts]
header "location" == "http://kratos:4434/admin/identities"
body not contains "hurl.test.local"

GET {{KANAE_URL}}/auth/admin/identities/{{MEMBER_ID}}
HTTP 307
[Asserts]
header "location" == "http://kratos:4434/admin/identities/{{MEMBER_ID}}"
body not contains "{{MEMBER_EMAIL}}"

# Aimed at an id that does not exist: a DELETE never names a seeded identity,
# even one that only gets redirected.
DELETE {{KANAE_URL}}/auth/admin/identities/00000000-0000-4000-8000-00000000dead
HTTP 307
[Asserts]
header "location" == "http://kratos:4434/admin/identities/00000000-0000-4000-8000-00000000dead"

# Not every admin path gets that redirect: /admin/sessions/* on the public
# server is Go's plain 404, so there are two refusal shapes, both a no.
GET {{KRATOS_URL}}/admin/sessions/00000000-0000-4000-8000-000000000000
Accept: application/json
HTTP 404
[Asserts]
header "content-type" startsWith "text/plain"
body contains "404 page not found"
body not contains "active"

# `/version` is admin-only, so it does not exist on the public port.
GET {{KANAE_URL}}/auth/version
HTTP 404

# ── rendered config: UI URLs ──

# Without Accept: application/json a browser is sent to the SPA. Each UI URL
# is an env override on the Deployment built from ory.publicOrigin.
GET {{KANAE_URL}}/auth/self-service/login/browser
HTTP 303
[Asserts]
header "location" matches /^https:\/\/kanae:5173\/login\?flow=[0-9a-f-]{36}$/

GET {{KANAE_URL}}/auth/self-service/registration/browser
HTTP 303
[Asserts]
header "location" matches /^https:\/\/kanae:5173\/register\?flow=[0-9a-f-]{36}$/

GET {{KANAE_URL}}/auth/self-service/verification/browser
HTTP 303
[Asserts]
header "location" matches /^https:\/\/kanae:5173\/verify\?flow=[0-9a-f-]{36}$/

GET {{KANAE_URL}}/auth/self-service/recovery/browser
HTTP 303
[Asserts]
header "location" matches /^https:\/\/kanae:5173\/recovery\?flow=[0-9a-f-]{36}$/

# Settings needs a session. A browser is bounced to Kratos' own login
# endpoint, built from the public base URL (so it keeps the /auth prefix).
GET {{KANAE_URL}}/auth/self-service/settings/browser
HTTP 303
[Asserts]
header "location" == "https://kanae/auth/self-service/login/browser"

GET {{KANAE_URL}}/auth/self-service/settings/browser
Accept: application/json
HTTP 401
[Asserts]
jsonpath "$.error.id" == "session_inactive"

GET {{KANAE_URL}}/auth/self-service/logout/browser
Accept: application/json
HTTP 401
[Asserts]
jsonpath "$.error.id" == "session_inactive"

# No cookie at whoami: the same 401 kanae turns into "Authentication required".
GET {{KANAE_URL}}/auth/sessions/whoami
Accept: application/json
HTTP 401
[Asserts]
jsonpath "$.error.code" == 401
jsonpath "$.error.reason" == "No valid session credentials found in the request."

# ── rendered config: allowed return URLs and CORS origin ──

GET {{KANAE_URL}}/auth/self-service/login/browser?return_to=https://evil.example/
Accept: application/json
HTTP 400
[Asserts]
jsonpath "$.error.id" == "self_service_flow_return_to_forbidden"
jsonpath "$.error.reason" contains "https://evil.example/"

GET {{KANAE_URL}}/auth/self-service/login/browser?return_to=https://kanae:5173/dashboard
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.return_to" == "https://kanae:5173/dashboard"

OPTIONS {{KANAE_URL}}/auth/self-service/login/browser
Origin: https://kanae:5173
Access-Control-Request-Method: GET
Access-Control-Request-Headers: content-type
HTTP 204
[Asserts]
header "access-control-allow-origin" == "https://kanae:5173"
header "access-control-allow-credentials" == "true"
header "access-control-allow-methods" == "GET"
header "access-control-allow-headers" == "content-type"
header "access-control-max-age" == "3600"

OPTIONS {{KANAE_URL}}/auth/self-service/login/browser
Origin: https://evil.example
Access-Control-Request-Method: GET
HTTP 204
[Asserts]
header "access-control-allow-origin" not exists
header "access-control-allow-credentials" not exists

# CORS only governs browsers: a plain GET with a foreign Origin still gets a
# real answer, just without the allow-origin header.
GET {{KRATOS_URL}}/self-service/login/browser
Accept: application/json
Origin: https://evil.example
HTTP 200
[Asserts]
header "access-control-allow-origin" not exists
jsonpath "$.id" isUuid

# ── rendered config: identity schema and static assets from the ConfigMap ──

# ZGVmYXVsdA is base64("default"), the schema id in kratos.prod.yml.
GET {{KANAE_URL}}/auth/schemas/ZGVmYXVsdA
HTTP 200
[Asserts]
header "content-type" startsWith "application/json"
jsonpath "$['$id']" == "https://schemas.kanae.acmucm.org/identity.v1.json"
jsonpath "$.properties.traits.required" count == 2
jsonpath "$.properties.traits.required" contains "email"
jsonpath "$.properties.traits.required" contains "name"
jsonpath "$.properties.traits.additionalProperties" == false
jsonpath "$.properties.traits.properties.email['ory.sh/kratos'].credentials.password.identifier" == true
jsonpath "$.properties.traits.properties.display_name.maxLength" == 50

GET {{KANAE_URL}}/auth/.well-known/ory/webauthn.js
HTTP 200
[Asserts]
header "content-type" startsWith "text/javascript"

# ── one login through the rewrite: session cookie flags, schema_url, logout flow ──

GET {{KANAE_URL}}/auth/self-service/login/browser
Accept: application/json
HTTP 200
[Captures]
flow_id: jsonpath "$.id"
csrf: jsonpath "$.ui.nodes[?(@.attributes.name == 'csrf_token')].attributes.value"

POST {{KANAE_URL}}/auth/self-service/login?flow={{flow_id}}
Content-Type: application/json
Accept: application/json
{ "method": "password", "identifier": "{{MEMBER_EMAIL}}", "password": "{{PASSWORD}}", "csrf_token": "{{csrf}}" }
HTTP 200
[Captures]
session_id: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{MEMBER_ID}}"
jsonpath "$.session.authenticator_assurance_level" == "aal1"
jsonpath "$.session.authentication_methods[0].method" == "password"
# schema_url is built from the public base URL, so it carries /auth too.
jsonpath "$.session.identity.schema_url" == "https://kanae/auth/schemas/ZGVmYXVsdA"
# The session cookie: 24h lifespan, HttpOnly, SameSite=Lax from kratos.prod.yml.
# Kratos marks it Secure although ory.secureCookies=false renders
# COOKIES_SECURE=false; recorded as observed (see RATIONALE).
cookie "ory_kratos_session" exists
cookie "ory_kratos_session[Path]" == "/"
cookie "ory_kratos_session[Max-Age]" == 86399
cookie "ory_kratos_session[HttpOnly]" exists
cookie "ory_kratos_session[SameSite]" == "Lax"
cookie "ory_kratos_session[Secure]" exists
header "set-cookie" count == 2

# The cookie set through /auth is sent back through /auth and reaches Kratos.
GET {{KANAE_URL}}/auth/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.id" == "{{session_id}}"
jsonpath "$.identity.id" == "{{MEMBER_ID}}"

# Kratos' own logout: the logout URL is built on the public base URL, and
# following it lands on the configured post-logout SPA page.
GET {{KANAE_URL}}/auth/self-service/logout/browser
Accept: application/json
HTTP 200
[Captures]
logout_token: jsonpath "$.logout_token"
[Asserts]
jsonpath "$.logout_url" == "https://kanae/auth/self-service/logout?token={{logout_token}}"

GET {{KANAE_URL}}/auth/self-service/logout?token={{logout_token}}
HTTP 303
[Asserts]
header "location" == "https://kanae:5173/login"

GET {{KANAE_URL}}/auth/sessions/whoami
Accept: application/json
HTTP 401
[Asserts]
jsonpath "$.error.code" == 401
