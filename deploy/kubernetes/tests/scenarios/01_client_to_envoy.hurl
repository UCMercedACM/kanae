# Edge: client -> Envoy Gateway. Proves the two listeners in routing.yml:
# https:443 terminates TLS with the cert-manager self-signed cert and speaks
# HTTP/2, http:80 answers every path with a 308 to https, and both only serve
# the hostname `kanae`. Nothing here needs a session, so no password hash
# lands on Kratos.
#
# The trailing-dot hostname is tested through the Host header, since
# `https://kanae./` itself is not covered by --resolve. A bare-IP
# `https://127.0.0.1/` is not testable: there is no SNI, Envoy has no default
# cert, and Hurl reports a transport error instead of a status.
#
# Derived from integration 01 (docs/index) and 03 (401 shapes).

# ── https listener: TLS terminated at Envoy, HTTP/2 negotiated, kanae behind it ──

GET {{KANAE_URL}}/
HTTP/2 307
[Asserts]
header "location" == "/docs"
header "server" == "granian"
certificate "Subject" == ""
certificate "Issuer" == ""
certificate "Serial-Number" exists
certificate "Expire-Date" daysAfterNow > 0
certificate "Expire-Date" daysAfterNow <= 90

# The same listener carries the /auth prefix to Kratos over the same cert.
GET {{KANAE_URL}}/auth/health/ready
HTTP/2 200
[Asserts]
jsonpath "$.status" == "ok"
header "server" not exists

# ── http listener: 308 to https, path and query preserved, no upstream involved ──

GET {{KANAE_HTTP_URL}}/
HTTP/1.1 308
[Asserts]
header "location" == "https://kanae/"
bytes count == 0

GET {{KANAE_HTTP_URL}}/auth/self-service/login/browser?x=1&y=2
HTTP/1.1 308
[Asserts]
header "location" == "https://kanae/auth/self-service/login/browser?x=1&y=2"

GET {{KANAE_HTTP_URL}}/members/me
HTTP/1.1 308
[Asserts]
header "location" == "https://kanae/members/me"

# 308 keeps the method, so a POST is not silently downgraded to a GET.
POST {{KANAE_HTTP_URL}}/members/logout
Content-Type: application/json
{ "ignored": true }
HTTP/1.1 308
[Asserts]
header "location" == "https://kanae/members/logout"
bytes count == 0

# DELETE is redirected the same way, before any route or auth check runs.
DELETE {{KANAE_HTTP_URL}}/sudo/revoke
HTTP/1.1 308
[Asserts]
header "location" == "https://kanae/sudo/revoke"
bytes count == 0

# Unknown paths still redirect: the http HTTPRoute is a `/` prefix, not a copy
# of the https routes.
GET {{KANAE_HTTP_URL}}/no/such/path
HTTP/1.1 308
[Asserts]
header "location" == "https://kanae/no/such/path"

# The redirect is served by Envoy alone, so it holds up under a burst.
GET {{KANAE_HTTP_URL}}/
[Options]
repeat: 25
HTTP/1.1 308
[Asserts]
header "location" == "https://kanae/"

# ── hostname matching: only `kanae` has routes ──

# Same TLS connection, different Host header: Envoy finds no HTTPRoute and
# answers itself (no `server: granian`, empty body).
GET {{KANAE_URL}}/members/me
Host: other.example
HTTP 404
[Asserts]
header "server" not exists
bytes count == 0

GET {{KANAE_URL}}/tags
Host: kanae.example.com
HTTP 404
[Asserts]
header "server" not exists

# The fully qualified form with a trailing dot is a different hostname to
# Envoy, so it finds no route either, for kanae or for Kratos.
GET {{KANAE_URL}}/members/me
Host: kanae.
HTTP 404
[Asserts]
header "server" not exists
bytes count == 0

GET {{KRATOS_URL}}/health/ready
Host: kanae.
HTTP 404
[Asserts]
header "server" not exists
bytes count == 0

GET {{KANAE_URL}}/members/me
Host: evil
HTTP 404
[Asserts]
header "server" not exists
bytes count == 0

# A port in the Host header is ignored for matching, whether it is the
# listener's own 443 or a port nothing listens on.
GET {{KANAE_URL}}/members/me
Host: kanae:443
HTTP 401
[Asserts]
header "server" == "granian"

GET {{KRATOS_URL}}/health/ready
Host: kanae:443
HTTP 200
[Asserts]
header "server" not exists
jsonpath "$.status" == "ok"

GET {{KANAE_URL}}/members/me
Host: kanae:8443
HTTP 401
[Asserts]
header "server" == "granian"

# Host names are case-insensitive, so the upper-case spelling still routes.
GET {{KANAE_URL}}/tags
Host: KANAE
HTTP 200
[Asserts]
header "server" == "granian"

# Same on the http listener: the redirect route is also bound to `kanae`.
GET {{KANAE_HTTP_URL}}/
Host: other.example
HTTP 404
[Asserts]
header "location" not exists

# ── unknown paths on the right host reach kanae, not an Envoy 404 ──

GET {{KANAE_URL}}/no/such/path
HTTP 404
[Asserts]
header "server" == "granian"
header "content-type" startsWith "application/json"
jsonpath "$.detail" == "Not Found"

# A wrong method on a real route is also answered by kanae (405 with Allow),
# which shows the `/` catch-all forwards every method.
PATCH {{KANAE_URL}}/members/me
HTTP 405
[Asserts]
header "server" == "granian"
header "allow" == "GET"
jsonpath "$.detail" == "Method Not Allowed"

# The schema kanae serves through the Gateway is the one this image was built
# with: sudo elevation is hidden from it.
GET {{KANAE_URL}}/openapi.json
HTTP/2 200
[Asserts]
header "server" == "granian"
header "content-type" startsWith "application/json"
jsonpath "$.info.title" == "Kanae"
jsonpath "$.paths['/members/me']" exists
jsonpath "$.paths['/sudo/elevate']" not exists

GET {{KANAE_URL}}/members/me
HTTP 401
[Asserts]
header "server" == "granian"
jsonpath "$.result" == "error"
jsonpath "$.detail" == "Authentication required"
