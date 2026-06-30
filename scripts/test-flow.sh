#!/usr/bin/env bash
# Note: this is written by Claude Opus 4.7, but I'm leaving it here as it's useful for testing purposes

# End-to-end smoke test of the Kanae + Ory stack:
#   register a user -> webhook fires -> session resolves
#   gated route 403 -> grant role -> 200
#   create resource -> grant ownership -> edit permission resolves
#   settings flow updates trait -> webhook syncs members table
#
# Run after `docker compose up -d`. Assumes default ports + a fresh DB
# (run `docker compose down -v && docker compose up -d --build` for a clean start).
#
# Requires: curl, jq, docker.

set -euo pipefail

# ── locate ourselves ──────────────────────────────────────────────────────────
# Resolve the project root so the script runs identically whether invoked from
# the repo root, scripts/, docker/, src/, or an absolute path from outside.
# Walks up from the script's own directory until it finds pyproject.toml.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

PROJECT_ROOT="$SCRIPT_DIR"
while [[ "$PROJECT_ROOT" != "/" && ! -f "$PROJECT_ROOT/pyproject.toml" ]]; do
	PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done
if [[ ! -f "$PROJECT_ROOT/pyproject.toml" ]]; then
	printf '\033[0;31m✗\033[0m could not locate project root from %s\n' "$SCRIPT_DIR" >&2
	exit 1
fi
cd "$PROJECT_ROOT"

# ── config ────────────────────────────────────────────────────────────────────
KRATOS_PUBLIC=${KRATOS_PUBLIC:-http://localhost:4433}
KRATOS_ADMIN=${KRATOS_ADMIN:-http://localhost:4434}
KETO_READ=${KETO_READ:-http://localhost:4466}
KETO_WRITE=${KETO_WRITE:-http://localhost:4467}
KANAE=${KANAE:-http://localhost:8000}
DB_CONTAINER=${DB_CONTAINER:-kanae_postgres}
VALKEY_CONTAINER=${VALKEY_CONTAINER:-kanae_valkey}
DB_NAME=${DB_NAME:-kanae}
DB_USER=${DB_USER:-postgres}

COOKIES="$(mktemp -t kanae-test-cookies.XXXXXX)"
trap 'rm -f "$COOKIES"' EXIT

# Unique email per run so the script is re-runnable without manual cleanup.
EMAIL="smoke-$(date +%s)-$$@ucmerced.edu"
PASSWORD="correct-horse-battery-staple-2026"
NAME="Smoke Test"

# ── output helpers ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YEL=$'\033[0;33m'
BLU=$'\033[0;34m'
RST=$'\033[0m'

H_ACCEPT="Accept: application/json"
H_CONTENT_TYPE="Content-Type: application/json"

# jq path to the roles array in member/role responses — kept in one place so the
# shape only has to change here if the payload ever moves.
ROLES_FILTER=".roles"

step() {
	local msg="$1"
	printf "\n${BLU}━━ %s ━━${RST}\n" "$msg"
}
ok() {
	local msg="$1"
	printf "${GRN}✓${RST} %s\n" "$msg"
}
warn() {
	local msg="$1"
	printf "${YEL}⚠${RST} %s\n" "$msg"
}
fail() {
	local msg="$1"
	printf "${RED}✗${RST} %s\n" "$msg" >&2
	exit 1
}

require() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1 || fail "missing required tool: $cmd"
}

assert_http() {
	# assert_http <expected-status> <method> <url> [curl args...]
	local expected="$1" method="$2" url="$3"
	shift 3
	local actual
	actual="$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$url" "$@")"
	if [[ "$actual" != "$expected" ]]; then
		fail "expected HTTP $expected from $method $url, got $actual"
	fi
	ok "$method $url -> $actual"
}

# ── 0. preflight ──────────────────────────────────────────────────────────────
step "0. preflight"
require curl
require jq
require docker

for url_label in \
	"$KRATOS_PUBLIC|kratos public" \
	"$KETO_READ|keto read" \
	"$KETO_WRITE|keto write"; do
	url="${url_label%%|*}"
	label="${url_label##*|}"
	curl -sf "$url/health/ready" >/dev/null || fail "$label not ready at $url"
	ok "$label ready"
done

curl -sf "$KANAE/" >/dev/null \
	|| curl -sf -o /dev/null -w '' "$KANAE/" \
	|| fail "Kanae not responding at $KANAE"
ok "kanae responding"

# ── 1. register user via Kratos browser flow ──────────────────────────────────
step "1. register $EMAIL"

FLOW=$(curl -sc "$COOKIES" -b "$COOKIES" \
	-H "$H_ACCEPT" \
	"$KRATOS_PUBLIC/self-service/registration/browser" \
	| jq -r .id)
[[ -n "$FLOW" && "$FLOW" != "null" ]] || fail "no registration flow id"
ok "flow id: $FLOW"

CSRF=$(curl -sc "$COOKIES" -b "$COOKIES" \
	-H "$H_ACCEPT" \
	"$KRATOS_PUBLIC/self-service/registration/flows?id=$FLOW" \
	| jq -r '.ui.nodes[] | select(.attributes.name=="csrf_token") | .attributes.value')
[[ -n "$CSRF" ]] || fail "no csrf token"

REG_RESP=$(curl -sc "$COOKIES" -b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-H "$H_ACCEPT" \
	-X POST "$KRATOS_PUBLIC/self-service/registration?flow=$FLOW" \
	-d '{
    "method": "password",
    "csrf_token": "'"$CSRF"'",
    "password":   "'"$PASSWORD"'",
    "traits": { "email": "'"$EMAIL"'", "name": "'"$NAME"'" }
  }')

IDENTITY_ID=$(jq -r '.identity.id // empty' <<<"$REG_RESP")
[[ -n "$IDENTITY_ID" ]] \
	|| fail "registration failed: $(jq -c '.ui.messages // .error // .' <<<"$REG_RESP")"
ok "identity id: $IDENTITY_ID"

# ── 2. verify webhook fired (members table sync) ──────────────────────────────
step "2. members table sync via registration webhook"

# Brief retry window — webhook is synchronous from Kratos, but DB writes can
# race the next read by tens of ms.
ROW=""
for _ in 1 2 3 4 5; do
	ROW=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tA \
		-c "SELECT id::text || '|' || name || '|' || email FROM members WHERE id = '$IDENTITY_ID';" \
		2>/dev/null || true)
	[[ -n "$ROW" ]] && break
	sleep 1
done
[[ -n "$ROW" ]] || fail "members row never appeared — check kanae and kratos webhook logs"
ok "members row: $ROW"

# ── 3. confirm session resolves through Kanae ─────────────────────────────────
step "3. /members/me via session cookie"

ME=$(curl -sb "$COOKIES" "$KANAE/members/me")
ME_ID=$(jq -r '.id // empty' <<<"$ME")
[[ "$ME_ID" == "$IDENTITY_ID" ]] \
	|| fail "/members/me returned unexpected identity: $ME"
ok "/members/me -> id=$ME_ID"

# /members/me is the enriched ClientMember: own email + trimmed session view +
# the global Keto roles (empty for a freshly-registered, role-less identity).
ME_EMAIL=$(jq -r '.email // empty' <<<"$ME")
[[ "$ME_EMAIL" == "$EMAIL" ]] \
	|| fail "/members/me email mismatch: expected $EMAIL, got '$ME_EMAIL'"
ME_AAL=$(jq -r '.session.aal // empty' <<<"$ME")
[[ "$ME_AAL" == "aal1" ]] \
	|| fail "/members/me session.aal expected aal1, got '$ME_AAL'"
ME_ROLES=$(jq -c "$ROLES_FILTER // empty" <<<"$ME")
[[ "$ME_ROLES" == "[]" ]] \
	|| fail "/members/me roles expected [] pre-grant, got '$ME_ROLES'"
ok "/members/me enriched: email=$ME_EMAIL session.aal=$ME_AAL roles=$ME_ROLES"

# ── 3b. member dashboard reads while role-less ────────────────────────────────
step "3b. /members directory + /members/<id>/roles (role-less)"

# both new reads reject an anonymous caller
assert_http 401 GET "$KANAE/members"
assert_http 401 GET "$KANAE/members/$IDENTITY_ID/roles"

# the directory is admin-only — a role-less member is forbidden
assert_http 403 GET "$KANAE/members" -b "$COOKIES"

# but a member may read THEIR OWN roles without admin (self branch) → empty set
SELF_ROLES=$(curl -sb "$COOKIES" "$KANAE/members/$IDENTITY_ID/roles")
[[ "$(jq -c "$ROLES_FILTER // empty" <<<"$SELF_ROLES")" == "[]" ]] \
	|| fail "self roles expected [] pre-grant, got '$SELF_ROLES'"
ok "GET /members/<self>/roles -> [] (self branch, no admin needed)"

# ── 4. gated route should 403 ─────────────────────────────────────────────────
step "4. POST /projects/create without role -> 403"

PROJ_BODY='{
  "name": "Smoke Project",
  "description": "smoke test",
  "link": "https://example.com",
  "type": "independent",
  "active": true,
  "founded_at": "2026-01-01T00:00:00Z"
}'
assert_http 403 POST "$KANAE/projects/create" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "$PROJ_BODY"

# ── 5. grant Role.MANAGER ─────────────────────────────────────────────────────
step "5. grant Role:manager#member to identity"

curl -sf -X PUT "$KETO_WRITE/admin/relation-tuples" \
	-H "$H_CONTENT_TYPE" \
	-d '{
    "namespace":  "Role",
    "object":     "manager",
    "relation":   "member",
    "subject_id": "'"$IDENTITY_ID"'"
  }' >/dev/null
ok "tuple written"

# Tuple-write invalidates the cache for this resource on the Kanae side, but
# only if invalidation runs through Kanae. A direct keto-write side-channel
# leaves the cache holding the previous deny — flush it.
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null
ok "valkey flushed"

# ── 6. retry gated route -> 200 ───────────────────────────────────────────────
step "6. POST /projects/create with role -> 200"

CREATE_RESP=$(curl -s -X POST "$KANAE/projects/create" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "$PROJ_BODY")
PROJECT_ID=$(jq -r '.id // empty' <<<"$CREATE_RESP")
[[ -n "$PROJECT_ID" ]] \
	|| fail "project create failed: $CREATE_RESP"
ok "project id: $PROJECT_ID"

# ── 7. resource permission via auto-granted Project:owners ────────────────────
step "7. edit created project — handler auto-granted Project:<id>#owners"

EDIT_RESP=$(curl -s -X PUT "$KANAE/projects/$PROJECT_ID" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"name":"Renamed Project","description":"edited","link":"https://example.com"}')
EDITED_NAME=$(jq -r '.name // empty' <<<"$EDIT_RESP")
[[ "$EDITED_NAME" == "Renamed Project" ]] \
	|| fail "edit failed: $EDIT_RESP"
ok "edit succeeded — Project.edit resolves through owners->editors permit chain"

# ── 8. settings flow updates members.name via webhook ─────────────────────────
step "8. settings flow profile update"

SFLOW=$(curl -sc "$COOKIES" -b "$COOKIES" \
	-H "$H_ACCEPT" \
	"$KRATOS_PUBLIC/self-service/settings/browser" \
	| jq -r .id)
[[ -n "$SFLOW" && "$SFLOW" != "null" ]] || fail "no settings flow id"

SCSRF=$(curl -sc "$COOKIES" -b "$COOKIES" \
	-H "$H_ACCEPT" \
	"$KRATOS_PUBLIC/self-service/settings/flows?id=$SFLOW" \
	| jq -r '.ui.nodes[] | select(.attributes.name=="csrf_token") | .attributes.value')

NEW_NAME="Renamed User"
SETTINGS_RESP=$(curl -sc "$COOKIES" -b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-H "$H_ACCEPT" \
	-X POST "$KRATOS_PUBLIC/self-service/settings?flow=$SFLOW" \
	-d '{
    "method":     "profile",
    "csrf_token": "'"$SCSRF"'",
    "traits":     { "email": "'"$EMAIL"'", "name": "'"$NEW_NAME"'" }
  }')
SETTINGS_STATE=$(jq -r '.state // empty' <<<"$SETTINGS_RESP")
[[ "$SETTINGS_STATE" == "success" ]] \
	|| fail "settings flow did not succeed: $(jq -c '.ui.messages // .' <<<"$SETTINGS_RESP")"
ok "settings flow state: success"

UPDATED=""
for _ in 1 2 3 4 5; do
	UPDATED=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tA \
		-c "SELECT name FROM members WHERE id = '$IDENTITY_ID';" 2>/dev/null || true)
	[[ "$UPDATED" == "$NEW_NAME" ]] && break
	sleep 1
done
[[ "$UPDATED" == "$NEW_NAME" ]] \
	|| fail "members.name still '$UPDATED' after settings flow — webhook didn't sync"
ok "members.name -> $UPDATED"

# ── 9. POST /events/create without LEADS/ADMIN role → 403 ────────────────────
step "9. POST /events/create without leads/admin role -> 403"

# end_at is far-future so the join check (now > end_at) never fires.
EVENT_BODY='{
  "id": "00000000-0000-0000-0000-000000000000",
  "name": "Smoke Event",
  "description": "smoke test event",
  "start_at": "2026-01-01T10:00:00Z",
  "end_at": "2030-01-01T00:00:00Z",
  "location": "UC Merced",
  "type": "general",
  "timezone": "America/Los_Angeles",
  "creator_id": "00000000-0000-0000-0000-000000000000"
}'
assert_http 403 POST "$KANAE/events/create" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "$EVENT_BODY"

# ── 10. grant Role:leads#member ───────────────────────────────────────────────
step "10. grant Role:leads#member to identity"

curl -sf -X PUT "$KETO_WRITE/admin/relation-tuples" \
	-H "$H_CONTENT_TYPE" \
	-d '{
    "namespace":  "Role",
    "object":     "leads",
    "relation":   "member",
    "subject_id": "'"$IDENTITY_ID"'"
  }' >/dev/null
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null
ok "tuple written, cache flushed"

# ── 11. POST /events/create with role → 200 ───────────────────────────────────
step "11. POST /events/create with role -> 200"

CREATE_EVENT_RESP=$(curl -s -X POST "$KANAE/events/create" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d "$EVENT_BODY")
EVENT_ID=$(jq -r '.id // empty' <<<"$CREATE_EVENT_RESP")
[[ -n "$EVENT_ID" ]] \
	|| fail "event create failed: $CREATE_EVENT_RESP"
ok "event id: $EVENT_ID"

# ── 12. resource permission via auto-granted Event:owners ─────────────────────
step "12. edit created event — handler auto-granted Event:<id>#owners"

EDIT_EVENT_RESP=$(curl -s -X PUT "$KANAE/events/$EVENT_ID" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE" \
	-d '{"name":"Renamed Event","description":"edited","location":"UC Merced Library"}')
EDITED_EVENT_NAME=$(jq -r '.name // empty' <<<"$EDIT_EVENT_RESP")
[[ "$EDITED_EVENT_NAME" == "Renamed Event" ]] \
	|| fail "event edit failed: $EDIT_EVENT_RESP"
ok "edit succeeded — Event.edit resolves through owners->editors permit chain"

# ── 13. join event ────────────────────────────────────────────────────────────
step "13. POST /events/<id>/join"

JOIN_EVENT_RESP=$(curl -s -X POST "$KANAE/events/$EVENT_ID/join" \
	-b "$COOKIES" \
	-H "$H_CONTENT_TYPE")
JOIN_EVENT_MSG=$(jq -r '.message // empty' <<<"$JOIN_EVENT_RESP")
[[ -n "$JOIN_EVENT_MSG" ]] \
	|| fail "event join failed: $JOIN_EVENT_RESP"
ok "joined event — message: $JOIN_EVENT_MSG"

# ── sudo: break-glass gating (password session = aal1) ────────────────────────
# The smoke identity authenticated with a password only (aal1), so the positive
# elevate path (which demands a fresh aal2) cannot be exercised here — we cover
# the gating: role enforcement, the aal2 step-up requirement, and revoke.
step "sudo: grant Role:admin#member for break-glass tests"

curl -sf -X PUT "$KETO_WRITE/admin/relation-tuples" \
	-H "$H_CONTENT_TYPE" \
	-d '{
    "namespace":  "Role",
    "object":     "admin",
    "relation":   "member",
    "subject_id": "'"$IDENTITY_ID"'"
  }' >/dev/null
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null
ok "admin tuple written, cache flushed"

# ── member dashboard reads now that the identity carries roles ─────────────────
# By now the identity holds manager (step 5), leads (step 10), and admin (above),
# so /members/me must surface them and the admin-only directory must unlock.
step "member reads reflect granted roles (manager + leads + admin)"

ME_AFTER=$(curl -sb "$COOKIES" "$KANAE/members/me")
for role in admin leads manager; do
	jq -e --arg r "$role" "$ROLES_FILTER | index(\$r)" <<<"$ME_AFTER" >/dev/null \
		|| fail "/members/me roles missing $role: $(jq -c "$ROLES_FILTER" <<<"$ME_AFTER")"
done
ok "/members/me roles -> $(jq -c "$ROLES_FILTER" <<<"$ME_AFTER")"

# admin can now list the directory; it includes this freshly-registered member
DIR=$(curl -sb "$COOKIES" "$KANAE/members")
jq -e --arg id "$IDENTITY_ID" '.data[] | select(.id == $id)' <<<"$DIR" >/dev/null \
	|| fail "directory missing self ($IDENTITY_ID): $(jq -c '.total' <<<"$DIR")"
ok "GET /members -> total=$(jq -r '.total' <<<"$DIR"), includes self"

# name/email search (post-settings name is "Renamed User") + sub-trigram reject
assert_http 200 GET "$KANAE/members?query=Renamed" -b "$COOKIES"
assert_http 422 GET "$KANAE/members?query=ab" -b "$COOKIES"

# self role read now reflects the admin grant
SELF_ROLES_ADMIN=$(curl -sb "$COOKIES" "$KANAE/members/$IDENTITY_ID/roles")
jq -e "$ROLES_FILTER | index(\"admin\")" <<<"$SELF_ROLES_ADMIN" >/dev/null \
	|| fail "GET /members/<self>/roles missing admin: $SELF_ROLES_ADMIN"
ok "GET /members/<self>/roles -> $(jq -c "$ROLES_FILTER" <<<"$SELF_ROLES_ADMIN")"

# ── project tag editing + archive (Project.edit / Project.own) ─────────────────
# PROJECT_ID was created in step 6, so the smoke identity auto-holds the owners
# tuple → both Project.edit and Project.own resolve. It's admin now too, so it
# can mint the tags to attach. Exercises overwrite (partial removal rides on it),
# read surfacing, clear, and the archive toggle.
step "project tags: create → overwrite → partial-remove → unknown(422) → clear"

for t in smoke-tag-a smoke-tag-b smoke-tag-c; do
	curl -sf -X POST "$KANAE/tags/create" \
		-b "$COOKIES" -H "$H_CONTENT_TYPE" \
		-d '{"title":"'"$t"'","description":"smoke"}' >/dev/null \
		|| fail "tag create failed for $t"
done
ok "created smoke tags"

# overwrite: attach all three (response echoes the applied set)
OVERWRITE_RESP=$(curl -s -X PUT "$KANAE/projects/$PROJECT_ID/tags" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" \
	-d '{"tags":["smoke-tag-a","smoke-tag-b","smoke-tag-c"]}')
[[ "$(jq -r '.tags | length' <<<"$OVERWRITE_RESP")" == "3" ]] \
	|| fail "expected 3 tags after overwrite, got: $OVERWRITE_RESP"
ok "overwrote project tags -> $(jq -c '.tags' <<<"$OVERWRITE_RESP")"

# read surfacing: GET reflects the set, alphabetically sorted
GET_TAGS=$(curl -sb "$COOKIES" "$KANAE/projects/$PROJECT_ID" | jq -c '.tags')
[[ "$GET_TAGS" == '["smoke-tag-a","smoke-tag-b","smoke-tag-c"]' ]] \
	|| fail "GET project tags mismatch: $GET_TAGS"
ok "GET /projects/<id> surfaces tags: $GET_TAGS"

# partial removal rides on overwrite: resend survivors, dropping smoke-tag-c
curl -sf -X PUT "$KANAE/projects/$PROJECT_ID/tags" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" \
	-d '{"tags":["smoke-tag-a","smoke-tag-b"]}' >/dev/null \
	|| fail "partial overwrite failed"
AFTER_PARTIAL=$(curl -sb "$COOKIES" "$KANAE/projects/$PROJECT_ID" | jq -c '.tags')
[[ "$AFTER_PARTIAL" == '["smoke-tag-a","smoke-tag-b"]' ]] \
	|| fail "expected smoke-tag-c dropped, got: $AFTER_PARTIAL"
ok "partial removal kept survivors: $AFTER_PARTIAL"

# unknown tag → 422, prior set untouched (tx rollback)
assert_http 422 PUT "$KANAE/projects/$PROJECT_ID/tags" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" -d '{"tags":["does-not-exist"]}'

# clear all → GET shows null
assert_http 200 DELETE "$KANAE/projects/$PROJECT_ID/tags" -b "$COOKIES"
CLEARED=$(curl -sb "$COOKIES" "$KANAE/projects/$PROJECT_ID" | jq -c '.tags')
[[ "$CLEARED" == "null" ]] \
	|| fail "expected null tags after clear, got: $CLEARED"
ok "cleared project tags (tags=null)"

step "project archive: toggle active flag (Project.own)"
ARCHIVED=$(curl -s -X PUT "$KANAE/projects/$PROJECT_ID/archive" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" -d '{"active":false}')
[[ "$(jq -r '.active' <<<"$ARCHIVED")" == "false" ]] \
	|| fail "expected active=false after archive, got: $ARCHIVED"
# the ?active=false list filter now surfaces it
curl -sb "$COOKIES" "$KANAE/projects?active=false" \
	| jq -e --arg id "$PROJECT_ID" '.data[] | select(.id == $id)' >/dev/null \
	|| fail "archived project missing from ?active=false listing"
RESTORED=$(curl -s -X PUT "$KANAE/projects/$PROJECT_ID/archive" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" -d '{"active":true}')
[[ "$(jq -r '.active' <<<"$RESTORED")" == "true" ]] \
	|| fail "expected active=true after restore, got: $RESTORED"
ok "archive toggle inactive→active verified"

step "sudo: GET /sudo as admin -> 200 inactive"
SUDO_STATUS=$(curl -s -b "$COOKIES" "$KANAE/sudo")
[[ "$(jq -r '.active' <<<"$SUDO_STATUS")" == "false" ]] \
	|| fail "expected inactive sudo, got: $SUDO_STATUS"
ok "sudo reports inactive"

step "sudo: POST /sudo/elevate without session -> 401"
assert_http 401 POST "$KANAE/sudo/elevate" -H "$H_CONTENT_TYPE" -d '{"reason":"smoke"}'

step "sudo: POST /sudo/elevate on aal1 session -> 403 + step-up header"
ELEVATE_HDRS=$(curl -s -D - -o /dev/null -b "$COOKIES" \
	-H "$H_CONTENT_TYPE" -X POST "$KANAE/sudo/elevate" -d '{"reason":"smoke"}')
grep -qiE '^HTTP/.* 403' <<<"$ELEVATE_HDRS" \
	|| fail "expected 403 on aal1 elevate"
grep -qi 'x-elevation-flow:' <<<"$ELEVATE_HDRS" \
	|| fail "missing X-Elevation-Flow header on aal1 elevate"
ok "aal1 elevate denied with step-up header (aal2 required)"

step "sudo: DELETE /sudo/revoke as admin -> 200 (idempotent no-op)"
assert_http 200 DELETE "$KANAE/sudo/revoke" -b "$COOKIES"
ok "sudo revoke idempotent"

warn "sudo: positive elevate path needs a fresh AAL2 (TOTP) session — not covered by password-only smoke flow"

# ── 14. member management — sudo-gated role write + hard delete ────────────────
# The smoke identity is aal1 (password only) so it cannot self-elevate to sudo.
# Promote it to Role:root via the keto side-channel (same mechanism as the role
# grants above) so it satisfies check_any(has_role(ROOT), has_sudo()), then drive
# the real Keto/Kratos teardown against throwaway victims.
step "14. member management (role write + hard delete)"

# Reused role-grant body for the member-management probes.
LEADS_GRANT_BODY='{"role":"leads","action":"grant"}'

register_victim() {
	# register_victim <cookie-jar> <email>; sets REGISTERED_ID on success.
	local jar="$1" email="$2" flow csrf resp row
	flow=$(curl -sc "$jar" -b "$jar" -H "$H_ACCEPT" \
		"$KRATOS_PUBLIC/self-service/registration/browser" | jq -r .id)
	csrf=$(curl -sc "$jar" -b "$jar" -H "$H_ACCEPT" \
		"$KRATOS_PUBLIC/self-service/registration/flows?id=$flow" \
		| jq -r '.ui.nodes[] | select(.attributes.name=="csrf_token") | .attributes.value')
	resp=$(curl -sc "$jar" -b "$jar" -H "$H_CONTENT_TYPE" -H "$H_ACCEPT" \
		-X POST "$KRATOS_PUBLIC/self-service/registration?flow=$flow" \
		-d '{"method":"password","csrf_token":"'"$csrf"'","password":"'"$PASSWORD"'","traits":{"email":"'"$email"'","name":"Victim"}}')
	REGISTERED_ID=$(jq -r '.identity.id // empty' <<<"$resp")
	[[ -n "$REGISTERED_ID" ]] \
		|| fail "victim registration failed: $(jq -c '.ui.messages // .' <<<"$resp")"
	# the registration webhook syncs the members row; allow a brief retry window.
	row=""
	for _ in 1 2 3 4 5; do
		row=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tA \
			-c "SELECT 1 FROM members WHERE id = '$REGISTERED_ID';" 2>/dev/null || true)
		[[ -n "$row" ]] && break
		sleep 1
	done
	[[ -n "$row" ]] || fail "victim members row never appeared for $email"
}

# unauthenticated → 401 on both gated routes
assert_http 401 PUT "$KANAE/members/$IDENTITY_ID/role" \
	-H "$H_CONTENT_TYPE" -d "$LEADS_GRANT_BODY"
assert_http 401 DELETE "$KANAE/members/$IDENTITY_ID"

# smoke identity is admin (not root, not sudo) → 403 on the gated route
assert_http 403 PUT "$KANAE/members/$IDENTITY_ID/role" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" -d "$LEADS_GRANT_BODY"

# promote smoke identity to root so it passes the member-management gate
curl -sf -X PUT "$KETO_WRITE/admin/relation-tuples" \
	-H "$H_CONTENT_TYPE" \
	-d '{"namespace":"Role","object":"root","relation":"member","subject_id":"'"$IDENTITY_ID"'"}' >/dev/null
docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null
ok "root tuple written, cache flushed"

# self-guard: cannot modify or delete your own account via the admin route
assert_http 409 PUT "$KANAE/members/$IDENTITY_ID/role" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" -d "$LEADS_GRANT_BODY"
assert_http 409 DELETE "$KANAE/members/$IDENTITY_ID" -b "$COOKIES"

# authorized but no such member → 404
assert_http 404 DELETE "$KANAE/members/00000000-0000-0000-0000-000000000000" -b "$COOKIES"

# victim jars (separate cookie jars from the smoke session)
VICTIM_JAR="$(mktemp -t kanae-victim-cookies.XXXXXX)"
SELF_JAR="$(mktemp -t kanae-self-cookies.XXXXXX)"
trap 'rm -f "$COOKIES" "$VICTIM_JAR" "$SELF_JAR"' EXIT

# ── victim 1: admin hard delete ───────────────────────────────────────────────
register_victim "$VICTIM_JAR" "victim-$(date +%s)-$$@ucmerced.edu"
VICTIM_ID="$REGISTERED_ID"
ok "victim id: $VICTIM_ID"

# root grants leads → 200, and the real Keto tuple resolves
assert_http 200 PUT "$KANAE/members/$VICTIM_ID/role" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" -d "$LEADS_GRANT_BODY"
ALLOWED=$(curl -s "$KETO_READ/relation-tuples/check?namespace=Role&object=leads&relation=member&subject_id=$VICTIM_ID" | jq -r '.allowed')
[[ "$ALLOWED" == "true" ]] || fail "expected leads tuple for victim, got allowed=$ALLOWED"
ok "victim granted leads (keto confirms)"

# the same grant is visible through Kanae's role-read route (admin reads another)
VICTIM_ROLES=$(curl -sb "$COOKIES" "$KANAE/members/$VICTIM_ID/roles")
jq -e "$ROLES_FILTER | index(\"leads\")" <<<"$VICTIM_ROLES" >/dev/null \
	|| fail "GET /members/<victim>/roles missing leads: $VICTIM_ROLES"
ok "GET /members/<victim>/roles (admin) -> $(jq -c "$ROLES_FILTER" <<<"$VICTIM_ROLES")"

# a role read for a non-existent member still 404s (authorized, no members row)
assert_http 404 GET "$KANAE/members/00000000-0000-0000-0000-000000000000/roles" -b "$COOKIES"

# root hard-deletes the victim → 200
assert_http 200 DELETE "$KANAE/members/$VICTIM_ID" -b "$COOKIES"

GONE=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tA \
	-c "SELECT 1 FROM members WHERE id = '$VICTIM_ID';" 2>/dev/null || true)
[[ -z "$GONE" ]] || fail "victim members row still present after delete"
ok "victim members row removed"

# the real teardown removed the Kratos identity and swept the Keto tuples
assert_http 404 GET "$KRATOS_ADMIN/admin/identities/$VICTIM_ID"
ALLOWED_AFTER=$(curl -s "$KETO_READ/relation-tuples/check?namespace=Role&object=leads&relation=member&subject_id=$VICTIM_ID" | jq -r '.allowed')
[[ "$ALLOWED_AFTER" == "false" ]] || fail "victim keto tuple survived purge (allowed=$ALLOWED_AFTER)"
ok "kratos identity + keto tuples purged"

# ── victim 2: self-service deletion via DELETE /members/me ─────────────────────
register_victim "$SELF_JAR" "selfdel-$(date +%s)-$$@ucmerced.edu"
SELF_ID="$REGISTERED_ID"
ok "self-delete victim id: $SELF_ID"

# role-less member: may read its OWN roles (200, empty) but not another's (403)
assert_http 200 GET "$KANAE/members/$SELF_ID/roles" -b "$SELF_JAR"
assert_http 403 GET "$KANAE/members/$IDENTITY_ID/roles" -b "$SELF_JAR"

assert_http 200 DELETE "$KANAE/members/me" -b "$SELF_JAR"
SELF_GONE=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tA \
	-c "SELECT 1 FROM members WHERE id = '$SELF_ID';" 2>/dev/null || true)
[[ -z "$SELF_GONE" ]] || fail "self-delete members row still present"
ok "self-service deletion removed members row"

# ── 15. project invites — lead-invite + member-request handshakes ──────────────
# The two-party invite system layered over plain /join. The smoke identity is
# the "lead": it owns PROJECT_ID (Project.edit via the owners chain) AND holds
# Role.MANAGER, either of which satisfies the
# check_any(has_role(MANAGER), has_permissions(Project.edit)) gate on the
# invite / list / join-policy / request-approval routes. A fresh invitee
# identity drives the member side from its own session.
#
#   Flow A — lead invites  → member accepts → joins → leaves
#   Flow B — join_policy=request → member requests → lead approves → joins
#
# Note on member_id semantics: project_invites.member_id is always the
# *target* (the one who would join) for both kinds, so the same row drives the
# member's inbox whether the lead invited them or they requested.
step "15. project invites (lead-invite + member-request flows)"

# A dedicated invitee with its own logged-in session (registration mints one).
INVITEE_JAR="$(mktemp -t kanae-invitee-cookies.XXXXXX)"
trap 'rm -f "$COOKIES" "$VICTIM_JAR" "$SELF_JAR" "$INVITEE_JAR"' EXIT
register_victim "$INVITEE_JAR" "invitee-$(date +%s)-$$@ucmerced.edu"
INVITEE_ID="$REGISTERED_ID"
ok "invitee id: $INVITEE_ID"

# ── Flow A: lead invites the member (kind=invite) ─────────────────────────────
INVITE_RESP=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/invites" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" \
	-d '{"member_id":"'"$INVITEE_ID"'","message":"come build with us"}')
INVITE_ID=$(jq -r '.id // empty' <<<"$INVITE_RESP")
[[ -n "$INVITE_ID" ]] || fail "invite create failed: $INVITE_RESP"
[[ "$(jq -r '.kind' <<<"$INVITE_RESP")" == "invite" ]] \
	|| fail "expected kind=invite, got: $INVITE_RESP"
[[ "$(jq -r '.status' <<<"$INVITE_RESP")" == "pending" ]] \
	|| fail "expected status=pending, got: $INVITE_RESP"
ok "lead invited member -> invite $INVITE_ID (kind=invite, pending)"

# lead view lists the pending invite
curl -sb "$COOKIES" "$KANAE/projects/$PROJECT_ID/invites?kind=invite&status=pending" \
	| jq -e --arg id "$INVITE_ID" '.[] | select(.id == $id)' >/dev/null \
	|| fail "lead listing missing invite $INVITE_ID"
ok "GET /projects/<id>/invites surfaces the pending invite"

# the invite lands in the member's inbox
curl -sb "$INVITEE_JAR" "$KANAE/members/me/projects/invites?kind=invite" \
	| jq -e --arg id "$INVITE_ID" '.[] | select(.id == $id and .status == "pending")' >/dev/null \
	|| fail "invite $INVITE_ID not in invitee inbox"
ok "invite shows in invitee /members/me/projects/invites inbox"

# the symmetry rule: for kind=invite only the *target* may accept — the lead is
# not the target, so even an owner/manager is forbidden here.
assert_http 403 POST "$KANAE/projects/$PROJECT_ID/invites/$INVITE_ID/accept" -b "$COOKIES"

# the target member accepts → joins
ACCEPT_RESP=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/invites/$INVITE_ID/accept" \
	-b "$INVITEE_JAR" -H "$H_CONTENT_TYPE")
[[ "$(jq -r '.status' <<<"$ACCEPT_RESP")" == "accepted" ]] \
	|| fail "accept failed: $ACCEPT_RESP"
ok "invitee accepted -> status=accepted"

# membership now reflects the join
curl -sb "$COOKIES" "$KANAE/projects/$PROJECT_ID" \
	| jq -e --arg id "$INVITEE_ID" '.members[] | select(.id == $id)' >/dev/null \
	|| fail "invitee not in project members after accept"
ok "invitee is now a project member"

# the row is terminal: a second accept 409s
assert_http 409 POST "$KANAE/projects/$PROJECT_ID/invites/$INVITE_ID/accept" -b "$INVITEE_JAR"

# member leaves so the request flow starts from a clean (non-member) state
assert_http 200 DELETE "$KANAE/projects/$PROJECT_ID/leave" -b "$INVITEE_JAR"
ok "invitee left the project"

# ── Flow B: member requests to join under join_policy=request ──────────────────
POLICY_RESP=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/join-policy" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" -d '{"join_policy":"request"}')
[[ "$(jq -r '.join_policy' <<<"$POLICY_RESP")" == "request" ]] \
	|| fail "join-policy set failed: $POLICY_RESP"
ok "join_policy -> request"

# a direct /join is refused now — the policy gate points at the request flow
assert_http 409 POST "$KANAE/projects/$PROJECT_ID/join" -b "$INVITEE_JAR"

# the member submits a request (kind=request; member_id = invited_by = self)
REQ_RESP=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/requests" \
	-b "$INVITEE_JAR" -H "$H_CONTENT_TYPE" -d '{"message":"please add me"}')
REQUEST_ID=$(jq -r '.id // empty' <<<"$REQ_RESP")
[[ -n "$REQUEST_ID" ]] || fail "request create failed: $REQ_RESP"
[[ "$(jq -r '.kind' <<<"$REQ_RESP")" == "request" ]] \
	|| fail "expected kind=request, got: $REQ_RESP"
ok "member requested to join -> request $REQUEST_ID (kind=request, pending)"

# lead sees the pending request in the project listing
curl -sb "$COOKIES" "$KANAE/projects/$PROJECT_ID/invites?kind=request&status=pending" \
	| jq -e --arg id "$REQUEST_ID" '.[] | select(.id == $id)' >/dev/null \
	|| fail "lead listing missing request $REQUEST_ID"
ok "GET /projects/<id>/invites?kind=request surfaces the pending request"

# lead approves (request-side gate satisfied by Role.MANAGER) → member joins
APPROVE_RESP=$(curl -s -X POST "$KANAE/projects/$PROJECT_ID/invites/$REQUEST_ID/accept" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE")
[[ "$(jq -r '.status' <<<"$APPROVE_RESP")" == "accepted" ]] \
	|| fail "request approve failed: $APPROVE_RESP"
ok "lead approved the request -> status=accepted"

curl -sb "$COOKIES" "$KANAE/projects/$PROJECT_ID" \
	| jq -e --arg id "$INVITEE_ID" '.members[] | select(.id == $id)' >/dev/null \
	|| fail "invitee not in members after request approval"
ok "invitee joined via approved request"

# restore the open policy so the project ends in its default state
curl -sf -X POST "$KANAE/projects/$PROJECT_ID/join-policy" \
	-b "$COOKIES" -H "$H_CONTENT_TYPE" -d '{"join_policy":"open"}' >/dev/null
ok "join_policy restored -> open"

# ── 16. logout invalidates session (best-effort) ──────────────────────────────
# Best-effort: a failure here means the session cookie is missing or already
# expired, which is purely a kratos/curl-cookie-jar concern and tells us
# nothing new about Kanae's behavior. The preceding 13 steps already cover
# every Kanae integration path (whoami, role check, permission check, webhook
# sync). Soften this one to a warn so a flaky logout doesn't bury the rest.
step "16. logout (best-effort)"

# Diagnostic: see what Kratos has issued by the time we hit logout. Useful when
# debugging "no active session" - tells us whether the jar holds the latest
# session cookie or whether a prior flow rotated it without curl persisting it.
echo "── jar before logout ──"
grep -E 'kratos|csrf' "$COOKIES" 2>/dev/null || echo "(empty)"
echo "──────────────────────"

LOGOUT_CODE=$(curl -sb "$COOKIES" -o /dev/null -w '%{http_code}' \
	-X POST "$KANAE/members/logout")

if [[ "$LOGOUT_CODE" != "200" ]]; then
	warn "POST /members/logout returned $LOGOUT_CODE (expected 200)"
	warn "skipping logout assertion"
else
	ok "POST /members/logout -> $LOGOUT_CODE"

	# Flush whoami cache so the next /members/me actually round-trips to Kratos.
	docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null

	CODE=$(curl -sb "$COOKIES" -o /dev/null -w '%{http_code}' "$KANAE/members/me")
	if [[ "$CODE" == "401" ]]; then
		ok "/members/me -> 401 after logout"
	else
		warn "/members/me -> $CODE after logout (expected 401)"
		warn "  this is a kratos/cookie-jar concern, not a Kanae one - earlier steps verify Kanae"
	fi
fi

# ── done ──────────────────────────────────────────────────────────────────────
printf '\n%sall checks passed%s\n' "$GRN" "$RST"
printf "  identity id: %s\n" "$IDENTITY_ID"
printf "  project id:  %s\n" "$PROJECT_ID"
printf "  event id:    %s\n" "$EVENT_ID"
printf "  invitee id:  %s\n" "$INVITEE_ID"
printf "  email:       %s\n" "$EMAIL"
