# Edge: kanae -> Valkey. OryClient.whoami caches the resolved Kratos session
# for 60s under a blake3 digest of the cookie (ory:whoami:*); logout deletes
# that one entry. Proves the warm path takes real traffic, that entries are
# per cookie, and that invalidation on logout is immediate and targeted: the
# logged-out cookie is rejected at once instead of being served from cache
# for up to 60s, while the other session is untouched at kanae and at
# Kratos. Two argon2 hashes (leads, then member).
#
# Two sessions are needed and a refresh login of the same identity only
# refreshes the existing session (same id), so they belong to two seeded
# identities. Hurl keeps one jar; the leads cookie is replayed explicitly at
# kanae, which reads the last ory_kratos_session in the request, while the
# member cookie stays in the jar so Kratos (which reads the first) can be
# asked about it directly.
#
# The last section is the only proof that the cache is live at all: a
# Kratos self-service logout, which kanae never sees, leaves the cookie served
# from Valkey until kanae's own logout drops the entry. Cache read errors are
# swallowed, so every other 200 here would also pass with no Valkey.
#
# Uses seeded LEADS and MEMBER; only logs them in and out. Derived from
# integration 02 and 04.

# ── session B (leads): captured for explicit replay ──

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
[Captures]
b: cookie "ory_kratos_session"
b_sid: jsonpath "$.session.id"

# Timestamps come from whoami, Z-stripped: the login response prints
# nanoseconds, whoami trims trailing zeros, kanae prints six digits.
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Captures]
b_issued: jsonpath "$.issued_at" regex /^(.*)Z$/
[Asserts]
jsonpath "$.id" == "{{b_sid}}"

# ── session A (member): the jar, and the warm path under load ──

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
[Captures]
a_sid: jsonpath "$.session.id"
[Asserts]
jsonpath "$.session.identity.id" == "{{MEMBER_ID}}"
jsonpath "$.session.id" != "{{b_sid}}"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Captures]
a_issued: jsonpath "$.issued_at" regex /^(.*)Z$/
[Asserts]
jsonpath "$.id" == "{{a_sid}}"
jsonpath "$.identity.id" == "{{MEMBER_ID}}"

# Cold call: fills ory:whoami:<digest of A>.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"
jsonpath "$.session.issued_at" startsWith "{{a_issued}}"

# 100 reads on the same cookie: the cached KanaeSession comes back every time
# (same issued_at snapshot) and none of them needs Kratos.
GET {{KANAE_URL}}/members/me
[Options]
repeat: 100
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"
jsonpath "$.session.issued_at" startsWith "{{a_issued}}"
duration <= 3000

GET {{KANAE_URL}}/members/me/projects
[Options]
repeat: 10
HTTP 200
[Asserts]
jsonpath "$" isCollection

# ── B replayed explicitly: its own entry, not A's ──

GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{b}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{LEADS_ID}}"
jsonpath "$.session.issued_at" startsWith "{{b_issued}}"

GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{b}}
[Options]
repeat: 5
HTTP 200
[Asserts]
jsonpath "$.id" == "{{LEADS_ID}}"

GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"

# ── logout B: its entry is deleted at once, A's is not ──

# The logout handler reads the cookie it was given, so this revokes B only.
POST {{KANAE_URL}}/members/logout
Cookie: ory_kratos_session={{b}}
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

# B was warm in the cache a moment ago. Without cache_invalidate this would be
# a 200 served from Valkey for up to 60s.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{b}}
HTTP 401
[Asserts]
jsonpath "$.detail" == "Authentication required"

GET {{KANAE_URL}}/members/me/events
Cookie: ory_kratos_session={{b}}
HTTP 401

# A is untouched at kanae ...
GET {{KANAE_URL}}/members/me
[Options]
repeat: 5
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"
jsonpath "$.session.issued_at" startsWith "{{a_issued}}"

# ... and at Kratos: the revoke was for B's session id only.
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 200
[Asserts]
jsonpath "$.id" == "{{a_sid}}"

# ── logout A: same immediate rejection for the jar cookie ──

POST {{KANAE_URL}}/members/logout
HTTP 200
[Asserts]
jsonpath "$.message" == "ok"

GET {{KANAE_URL}}/members/me
HTTP 401
[Asserts]
jsonpath "$.detail" == "Authentication required"

GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
HTTP 401

POST {{KANAE_URL}}/members/logout
HTTP 401

# ── a logout kanae never sees: the cache is provably live ──

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
[Captures]
c_sid: jsonpath "$.session.id"
c_cookie: cookie "ory_kratos_session"
[Asserts]
jsonpath "$.session.id" != "{{a_sid}}"
jsonpath "$.session.identity.id" == "{{MEMBER_ID}}"

# Fills the cache for c_cookie.
GET {{KANAE_URL}}/members/me
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"

GET {{KRATOS_URL}}/self-service/logout/browser
Accept: application/json
HTTP 200
[Captures]
logout_token: jsonpath "$.logout_token"
[Asserts]
jsonpath "$.logout_url" startsWith "https://kanae/auth/self-service/logout?token="

GET {{KRATOS_URL}}/self-service/logout?token={{logout_token}}
Accept: application/json
HTTP 204

# Kratos cleared the jar cookie; the old value is replayed explicitly.
GET {{KRATOS_URL}}/sessions/whoami
Accept: application/json
Cookie: ory_kratos_session={{c_cookie}}
HTTP 401

# PINNED, same root cause as the known stale-whoami-after-DELETE bug: a
# revocation kanae never sees stays served from Valkey for up to 60s. This is
# the only proof Valkey is live. Flip it if kanae ever subscribes to
# revocations.
GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{c_cookie}}
HTTP 200
[Asserts]
jsonpath "$.id" == "{{MEMBER_ID}}"

# kanae's logout drops the entry (its admin revoke of an already-dead session
# is a no-op), and the next read goes back to Kratos.
POST {{KANAE_URL}}/members/logout
Cookie: ory_kratos_session={{c_cookie}}
HTTP 200

GET {{KANAE_URL}}/members/me
Cookie: ory_kratos_session={{c_cookie}}
HTTP 401
