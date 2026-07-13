#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
VARS_ENV="$SCRIPT_DIR/vars.env"

if [[ -f "$VARS_ENV" ]]; then
	set -a
	# shellcheck source=/dev/null
	source "$VARS_ENV"
	set +a
fi

KRATOS_PUBLIC=${KRATOS_PUBLIC:-http://localhost:4433}
KRATOS_ADMIN=${KRATOS_ADMIN:-http://localhost:4434}
KETO_WRITE=${KETO_WRITE:-http://localhost:4467}
KANAE=${KANAE:-http://localhost:8000}
DB_CONTAINER=${DB_CONTAINER:-kanae_postgres}
VALKEY_CONTAINER=${VALKEY_CONTAINER:-kanae_valkey}
DB_NAME=${DB_NAME:-kanae}
DB_USER=${DB_USER:-postgres}
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@seed.test.local}
MEMBER_EMAIL=${MEMBER_EMAIL:-member@seed.test.local}
MANAGER_EMAIL=${MANAGER_EMAIL:-manager@seed.test.local}
LEADS_EMAIL=${LEADS_EMAIL:-leads@seed.test.local}
MEMBERS_TIMEOUT=${SEED_MEMBERS_TIMEOUT:-15}

H_ACCEPT="Accept: application/json"
H_CONTENT_TYPE="Content-Type: application/json"
ID_FILTER='.id // empty'
ZERO_UUID="00000000-0000-0000-0000-000000000000"

RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YEL=$'\033[0;33m'
BLU=$'\033[0;34m'
RST=$'\033[0m'

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
	local tool="$1"
	command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
}

provision_identity() {
	local jar="$1" email="$2" name="$3" password="$4" flow csrf resp

	flow=$(curl -sc "$jar" -b "$jar" -H "$H_ACCEPT" \
		"$KRATOS_PUBLIC/self-service/registration/browser" | jq -r .id)
	[[ -n "$flow" && "$flow" != "null" ]] || fail "no registration flow id for $email"
	csrf=$(curl -sc "$jar" -b "$jar" -H "$H_ACCEPT" \
		"$KRATOS_PUBLIC/self-service/registration/flows?id=$flow" \
		| jq -r '.ui.nodes[] | select(.attributes.name=="csrf_token") | .attributes.value')

	resp=$(curl -sc "$jar" -b "$jar" -H "$H_CONTENT_TYPE" -H "$H_ACCEPT" \
		-X POST "$KRATOS_PUBLIC/self-service/registration?flow=$flow" \
		-d '{
      "method": "password",
      "csrf_token": "'"$csrf"'",
      "password":   "'"$password"'",
      "traits": { "email": "'"$email"'", "name": "'"$name"'" }
    }')
	IDENTITY_ID=$(jq -r '.identity.id // empty' <<<"$resp")

	if [[ -z "$IDENTITY_ID" ]]; then
		warn "registration for $email did not mint an identity; resetting password and logging in"
		reset_password "$email" "$password" \
			|| fail "could not register or reset $email: $(jq -c '.ui.messages // .error // .' <<<"$resp")"
		login_identity "$jar" "$email" "$password" \
			|| fail "login for $email failed after password reset"
		IDENTITY_ID=$(curl -sb "$jar" "$KANAE/members/me" | jq -r "$ID_FILTER")
		[[ -n "$IDENTITY_ID" ]] || fail "login for $email did not resolve an identity"
	fi
}

provision_bg() {
	local idfile="$1"
	shift
	provision_identity "$@"
	printf '%s' "$IDENTITY_ID" >"$idfile"
}

read_id() {
	local idfile="$1" label="$2"
	[[ -s "$idfile" ]] || fail "provisioning failed for $label"
	printf '%s' "$(<"$idfile")"
}

named_row() {
	local role="$1" email="$2" id="$3"
	printf '    %-8s %-30s %s\n' "$role" "$email" "$id"
}

reset_password() {
	local email="$1" password="$2" identity id body
	identity=$(curl -sf -G "$KRATOS_ADMIN/admin/identities" \
		--data-urlencode "credentials_identifier=$email" | jq -c '.[0] // empty')
	[[ -n "$identity" ]] || return 1
	id=$(jq -r '.id' <<<"$identity")

	body=$(jq -n --argjson idn "$identity" --arg pw "$password" \
		'{schema_id: $idn.schema_id, state: "active", traits: $idn.traits,
      credentials: {password: {config: {password: $pw}}}}')
	curl -sf -X PUT "$KRATOS_ADMIN/admin/identities/$id" \
		-H "$H_CONTENT_TYPE" -d "$body" >/dev/null
}

login_identity() {
	local jar="$1" email="$2" password="$3" flow csrf resp
	flow=$(curl -sc "$jar" -b "$jar" -H "$H_ACCEPT" \
		"$KRATOS_PUBLIC/self-service/login/browser" | jq -r .id)
	[[ -n "$flow" && "$flow" != "null" ]] || return 1
	csrf=$(curl -sc "$jar" -b "$jar" -H "$H_ACCEPT" \
		"$KRATOS_PUBLIC/self-service/login/flows?id=$flow" \
		| jq -r '.ui.nodes[] | select(.attributes.name=="csrf_token") | .attributes.value')
	resp=$(curl -sc "$jar" -b "$jar" -H "$H_CONTENT_TYPE" -H "$H_ACCEPT" \
		-X POST "$KRATOS_PUBLIC/self-service/login?flow=$flow" \
		-d '{
      "method": "password",
      "csrf_token": "'"$csrf"'",
      "identifier": "'"$email"'",
      "password":   "'"$password"'"
    }')
	[[ -n "$(jq -r '.session.id // empty' <<<"$resp")" ]]
}

wait_for_members() {
	local ids=("$@") expected=$# deadline in_list count
	in_list=$(printf "'%s'," "${ids[@]}")
	in_list="${in_list%,}"
	deadline=$(($(date +%s) + MEMBERS_TIMEOUT))

	while :; do
		count=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tA \
			-c "SELECT count(*) FROM members WHERE id IN ($in_list);" 2>/dev/null || echo 0)
		[[ "$count" == "$expected" ]] && return 0
		(($(date +%s) >= deadline)) && return 1
		sleep 0.2
	done
}

grant_role() {
	local id="$1" role="$2"
	curl -sf -X PUT "$KETO_WRITE/admin/relation-tuples" \
		-H "$H_CONTENT_TYPE" \
		-d '{
      "namespace":  "Role",
      "object":     "'"$role"'",
      "relation":   "member",
      "subject_id": "'"$id"'"
    }' >/dev/null || fail "failed to grant Role:$role to $id"
}

grant_sudo() {
	local id="$1"
	docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q \
		-c "INSERT INTO sudo_grants (member_id, expires_at, reason)
		    VALUES ('$id', now() + interval '30 minutes', 'seed script')
		    ON CONFLICT (member_id) DO UPDATE
		      SET granted_at = now(),
		          expires_at = EXCLUDED.expires_at,
		          reason     = EXCLUDED.reason;" >/dev/null \
		|| fail "failed to grant sudo to $id"
}

seed_from_json() {
	local file="$1" endpoint="$2" jar="$3" label="$4" transform="${5:-.}"
	local obj resp seeded=0 total
	total=$(jq 'length' "$file")

	while IFS= read -r obj; do
		resp=$(curl -s -X POST "$KANAE$endpoint" \
			-b "$jar" -H "$H_CONTENT_TYPE" -d "$obj")
		if [[ -n "$(jq -r "$ID_FILTER" <<<"$resp")" ]]; then
			seeded=$((seeded + 1))
		else
			warn "$label '$(jq -r '.name // .title // "?"' <<<"$obj")' not created: $(jq -c '.message // .detail // .' <<<"$resp")"
		fi
	done < <(jq -c ".[] | $transform" "$file")

	ok "created $seeded/$total ${label}s"
}

step "0. preflight"
require curl
require jq
require docker
require openssl

PASSWORD="$(openssl rand -hex 16)"

for f in members tags projects events; do
	[[ -f "$DATA_DIR/$f.json" ]] || fail "missing data file: $DATA_DIR/$f.json"
	jq -e . "$DATA_DIR/$f.json" >/dev/null || fail "invalid JSON in $DATA_DIR/$f.json"
done
ok "data files present and valid JSON"

curl -sf "$KRATOS_PUBLIC/health/ready" >/dev/null || fail "kratos not ready at $KRATOS_PUBLIC"
ok "kratos public ready"
curl -sf "$KRATOS_ADMIN/health/ready" >/dev/null || fail "kratos admin not ready at $KRATOS_ADMIN"
ok "kratos admin ready"
curl -sf "$KETO_WRITE/health/ready" >/dev/null || fail "keto write not ready at $KETO_WRITE"
ok "keto write ready"
curl -sf -o /dev/null -w '' "$KANAE/" || fail "kanae not responding at $KANAE"
ok "kanae responding"

WORK="$(mktemp -d -t kanae-seed.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ADMIN_JAR="$WORK/admin.jar"
MANAGER_JAR="$WORK/manager.jar"
LEAD_JAR="$WORK/lead.jar"

step "1. provision identities + roster (parallel)"

ROSTER_NAMES=() ROSTER_EMAILS=() ROSTER_ROLES=() ROSTER_IDS=() ROSTER_PASSWORDS=()
while IFS=$'\t' read -r name email role; do
	ROSTER_NAMES+=("$name")
	ROSTER_EMAILS+=("$email")
	ROSTER_ROLES+=("$role")
done < <(jq -r '.[] | [.name, .email, .role] | @tsv' "$DATA_DIR/members.json")

provision_bg "$WORK/admin.id" "$ADMIN_JAR" "$ADMIN_EMAIL" "Seed Admin" "$PASSWORD" &
provision_bg "$WORK/member.id" "$WORK/member.jar" "$MEMBER_EMAIL" "Seed Member" "$PASSWORD" &
provision_bg "$WORK/manager.id" "$MANAGER_JAR" "$MANAGER_EMAIL" "Seed Manager" "$PASSWORD" &
provision_bg "$WORK/lead.id" "$LEAD_JAR" "$LEADS_EMAIL" "Seed Lead" "$PASSWORD" &

for i in "${!ROSTER_EMAILS[@]}"; do
	ROSTER_PASSWORDS[i]="$(openssl rand -hex 16)"
	provision_bg "$WORK/roster-$i.id" "$WORK/roster-$i.jar" \
		"${ROSTER_EMAILS[$i]}" "${ROSTER_NAMES[$i]}" "${ROSTER_PASSWORDS[$i]}" &
done

wait

ADMIN_ID=$(read_id "$WORK/admin.id" "$ADMIN_EMAIL")
MEMBER_ID=$(read_id "$WORK/member.id" "$MEMBER_EMAIL")
MANAGER_ID=$(read_id "$WORK/manager.id" "$MANAGER_EMAIL")
LEAD_ID=$(read_id "$WORK/lead.id" "$LEADS_EMAIL")
for i in "${!ROSTER_EMAILS[@]}"; do
	ROSTER_IDS[i]=$(read_id "$WORK/roster-$i.id" "${ROSTER_EMAILS[$i]}")
done
ok "provisioned 4 named + ${#ROSTER_IDS[@]} roster identities"

wait_for_members "$ADMIN_ID" "$MEMBER_ID" "$MANAGER_ID" "$LEAD_ID" "${ROSTER_IDS[@]}" \
	|| fail "members rows never synced within ${MEMBERS_TIMEOUT}s — check kanae/kratos webhook logs"
ok "all members rows synced"

step "2. grant roles + sudo"

grant_role "$ADMIN_ID" admin
grant_role "$MANAGER_ID" manager
grant_role "$LEAD_ID" leads

roster_admins=0 roster_managers=0 roster_leads=0
for i in "${!ROSTER_ROLES[@]}"; do
	case "${ROSTER_ROLES[$i]}" in
		admin) grant_role "${ROSTER_IDS[$i]}" admin && roster_admins=$((roster_admins + 1)) ;;
		manager) grant_role "${ROSTER_IDS[$i]}" manager && roster_managers=$((roster_managers + 1)) ;;
		leads) grant_role "${ROSTER_IDS[$i]}" leads && roster_leads=$((roster_leads + 1)) ;;
		member) ;;
		*) warn "unknown roster role '${ROSTER_ROLES[$i]}' for ${ROSTER_EMAILS[$i]}; no role granted" ;;
	esac
done

docker exec "$VALKEY_CONTAINER" valkey-cli FLUSHDB >/dev/null
grant_sudo "$ADMIN_ID"
ok "granted named + roster ($roster_admins admin, $roster_managers manager, $roster_leads leads) + admin sudo, valkey flushed"

step "3. seed tags (bulk-create)"
TAG_TOTAL=$(jq 'length' "$DATA_DIR/tags.json")
tag_resp=$(curl -s -X POST "$KANAE/tags/bulk-create" \
	-b "$ADMIN_JAR" -H "$H_CONTENT_TYPE" -d @"$DATA_DIR/tags.json")
if tag_created=$(jq -e 'if type == "array" then length else empty end' <<<"$tag_resp"); then
	ok "created $tag_created/$TAG_TOTAL tags"
else
	warn "bulk tag create returned no list (tags may already exist): $(jq -c '.message // .detail // .' <<<"$tag_resp")"
fi

step "4. seed projects + events (parallel)"
seed_from_json "$DATA_DIR/projects.json" "/projects/create" "$MANAGER_JAR" "project" &
seed_from_json "$DATA_DIR/events.json" "/events/create" "$LEAD_JAR" "event" \
	". + {id: \"$ZERO_UUID\", creator_id: \"$ZERO_UUID\"}" &
wait

printf '\n%sseed complete%s\n' "$GRN" "$RST"

printf "\n  ${BLU}named accounts${RST} (shared password: %s)\n" "$PASSWORD"
named_row "role" "email" "identity id"
named_row "admin" "$ADMIN_EMAIL" "$ADMIN_ID"
named_row "member" "$MEMBER_EMAIL" "$MEMBER_ID"
named_row "manager" "$MANAGER_EMAIL" "$MANAGER_ID"
named_row "lead" "$LEADS_EMAIL" "$LEAD_ID"

printf "\n  ${BLU}roster members${RST}: %d (data/members.json)\n" "${#ROSTER_IDS[@]}"
printf "    %-8s %-32s %-32s %s\n" "role" "email" "password" "identity id"
for i in "${!ROSTER_IDS[@]}"; do
	printf "    %-8s %-32s %-32s %s\n" \
		"${ROSTER_ROLES[$i]}" "${ROSTER_EMAILS[$i]}" "${ROSTER_PASSWORDS[$i]}" "${ROSTER_IDS[$i]}"
done
