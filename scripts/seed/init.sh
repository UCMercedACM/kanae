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
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-kanae}
DB_USER=${DB_USER:-postgres}
VALKEY_HOST=${VALKEY_HOST:-localhost}
VALKEY_PORT=${VALKEY_PORT:-6379}
DB_CONTAINER=${DB_CONTAINER:-kanae_postgres}
VALKEY_CONTAINER=${VALKEY_CONTAINER:-kanae_valkey}
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@seed.test.local}
MEMBER_EMAIL=${MEMBER_EMAIL:-member@seed.test.local}
MANAGER_EMAIL=${MANAGER_EMAIL:-manager@seed.test.local}
LEADS_EMAIL=${LEADS_EMAIL:-leads@seed.test.local}
MEMBERS_TIMEOUT=${SEED_MEMBERS_TIMEOUT:-15}
MEMBERS_INTERVAL=0.2
MEMBERS_ATTEMPTS=$((MEMBERS_TIMEOUT * 5))
WAIT_RETRIES=${SEED_WAIT_RETRIES:-30}

if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
	POSTGRES_PASSWORD=${DB_PASSWORD:-password}
fi

HAS_PSQL=0
HAS_VALKEY_CLI=0
if command -v psql >/dev/null 2>&1; then HAS_PSQL=1; fi
if command -v valkey-cli >/dev/null 2>&1; then HAS_VALKEY_CLI=1; fi

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
named_row() {
	local role="$1" email="$2" id="$3"
	printf '    %-8s %-30s %s\n' "$role" "$email" "$id"
}

psql_query() {
	if ((HAS_PSQL)); then
		PGPASSWORD="$POSTGRES_PASSWORD" psql \
			--host "$DB_HOST" --port "$DB_PORT" \
			--username "$DB_USER" --dbname "$DB_NAME" \
			--no-psqlrc --quiet --tuples-only --no-align "$@"
	else
		docker exec "$DB_CONTAINER" psql \
			--username "$DB_USER" --dbname "$DB_NAME" \
			--no-psqlrc --quiet --tuples-only --no-align "$@"
	fi
}

valkey_query() {
	if ((HAS_VALKEY_CLI)); then
		valkey-cli -h "$VALKEY_HOST" -p "$VALKEY_PORT" "$@"
	else
		docker exec "$VALKEY_CONTAINER" valkey-cli "$@"
	fi
}

existing_values() {
	local table="$1" column="$2"
	psql_query -c "SELECT $column FROM $table;" \
		| jq -Rsc 'split("\n") | map(select(length > 0))'
}

cookie_curl() {
	local jar="$1" headers="$1.headers" cookies=""
	shift
	if [[ -s "$jar" ]]; then read -r cookies <"$jar" || true; fi

	local -a cookie_header=()
	if [[ -n "$cookies" ]]; then cookie_header=(-H "Cookie: $cookies"); fi

	curl -s -D "$headers" "${cookie_header[@]}" "$@"
	absorb_cookies "$jar" "$headers"
}

absorb_cookies() {
	local jar="$1" headers="$2" entry name line merged="" sep=""
	local -A value=()
	local -a order=()

	if [[ -s "$jar" ]]; then
		local -a stored=()
		IFS=';' read -ra stored <"$jar" || true
		for entry in "${stored[@]}"; do
			entry="${entry# }"
			[[ "$entry" == *=* ]] || continue

			name="${entry%%=*}"
			order+=("$name")
			value["$name"]="${entry#*=}"
		done
	fi

	while IFS= read -r line; do
		line="${line%$'\r'}"
		[[ "${line,,}" == set-cookie:* ]] || continue
		entry="${line#*:}"   # drop the header name
		entry="${entry%%;*}" # keep the pair, drop Path/HttpOnly/…
		entry="${entry# }"
		[[ "$entry" == *=* ]] || continue

		name="${entry%%=*}"
		[[ -v value["$name"] ]] || order+=("$name")
		value["$name"]="${entry#*=}"
	done <"$headers"

	for name in "${order[@]}"; do
		[[ -n "${value[$name]}" ]] || continue
		merged+="$sep$name=${value[$name]}"
		sep="; "
	done
	printf '%s\n' "$merged" >"$jar"
}

wait_http() {
	local url="$1" label="$2"
	curl --silent --show-error --fail --output /dev/null \
		--connect-timeout 2 --max-time 5 \
		--retry "$WAIT_RETRIES" --retry-delay 1 \
		--retry-connrefused --retry-all-errors \
		"$url" || fail "$label never became ready at $url"
	ok "$label ready"
}

lookup_identity() {
	local email="$1" identity
	identity=$(curl -sf -G "$KRATOS_ADMIN/admin/identities" \
		--data-urlencode "credentials_identifier=$email" | jq -c '.[0] // empty')
	[[ -n "$identity" ]] || return 1
	printf '%s' "$identity"
}

reset_password() {
	local identity="$1" password="$2" id body
	id=$(jq -r .id <<<"$identity")
	body=$(jq -n --argjson idn "$identity" --arg pw "$password" \
		'{schema_id: $idn.schema_id, state: "active", traits: $idn.traits,
      credentials: {password: {config: {password: $pw}}}}')
	curl -sf -X PUT "$KRATOS_ADMIN/admin/identities/$id" \
		-H "$H_CONTENT_TYPE" -d "$body" >/dev/null
}

flow_csrf() {
	local jar="$1" kind="$2" flow="$3" resp csrf
	resp=$(cookie_curl "$jar" -H "$H_ACCEPT" \
		"$KRATOS_PUBLIC/self-service/$kind/flows?id=$flow")
	csrf=$(jq -r '.ui.nodes[]? | select(.attributes.name=="csrf_token") | .attributes.value' \
		<<<"$resp")
	[[ -n "$csrf" ]] \
		|| fail "$kind flow $flow carried no csrf token: $(jq -c '.error // .' <<<"$resp")"
	printf '%s' "$csrf"
}

login_identity() {
	local jar="$1" email="$2" password="$3" flow csrf resp
	flow=$(cookie_curl "$jar" -H "$H_ACCEPT" \
		"$KRATOS_PUBLIC/self-service/login/browser" | jq -r .id)
	[[ -n "$flow" && "$flow" != "null" ]] || return 1
	csrf=$(flow_csrf "$jar" login "$flow")
	resp=$(cookie_curl "$jar" -H "$H_CONTENT_TYPE" -H "$H_ACCEPT" \
		-X POST "$KRATOS_PUBLIC/self-service/login?flow=$flow" \
		-d '{
      "method": "password",
      "csrf_token": "'"$csrf"'",
      "identifier": "'"$email"'",
      "password":   "'"$password"'"
    }')
	[[ -n "$(jq -r '.session.id // empty' <<<"$resp")" ]]
}

provision_identity() {
	local jar="$1" email="$2" name="$3" password="$4" flow csrf resp identity
	: >"$jar"

	if identity=$(lookup_identity "$email"); then
		reset_password "$identity" "$password" \
			|| fail "could not reset existing identity $email"
		login_identity "$jar" "$email" "$password" \
			|| fail "login for existing identity $email failed"
		IDENTITY_ID=$(cookie_curl "$jar" "$KANAE/members/me" | jq -r "$ID_FILTER")
		[[ -n "$IDENTITY_ID" ]] || fail "login for $email did not resolve an identity"
		return 0
	fi

	flow=$(cookie_curl "$jar" -H "$H_ACCEPT" \
		"$KRATOS_PUBLIC/self-service/registration/browser" | jq -r .id)
	[[ -n "$flow" && "$flow" != "null" ]] || fail "no registration flow id for $email"
	csrf=$(flow_csrf "$jar" registration "$flow")

	resp=$(cookie_curl "$jar" -H "$H_CONTENT_TYPE" -H "$H_ACCEPT" \
		-X POST "$KRATOS_PUBLIC/self-service/registration?flow=$flow" \
		-d '{
      "method": "password",
      "csrf_token": "'"$csrf"'",
      "password":   "'"$password"'",
      "traits": { "email": "'"$email"'", "name": "'"$name"'" }
    }')
	IDENTITY_ID=$(jq -r '.identity.id // empty' <<<"$resp")
	[[ -n "$IDENTITY_ID" ]] && return 0

	warn "registration for $email did not mint an identity; resetting password and logging in"
	identity=$(lookup_identity "$email") \
		|| fail "could not register or reset $email: $(jq -c '.ui.messages // .error // .' <<<"$resp")"
	reset_password "$identity" "$password" \
		|| fail "could not reset $email after a failed registration"
	login_identity "$jar" "$email" "$password" \
		|| fail "login for $email failed after password reset"
	IDENTITY_ID=$(cookie_curl "$jar" "$KANAE/members/me" | jq -r "$ID_FILTER")
	[[ -n "$IDENTITY_ID" ]] || fail "login for $email did not resolve an identity"
}

wait_for_members() {
	local ids=("$@") expected=$# in_list count attempt
	printf -v in_list "'%s'," "${ids[@]}"
	in_list="${in_list%,}"

	for ((attempt = 0; attempt < MEMBERS_ATTEMPTS; attempt++)); do
		count=$(psql_query \
			-c "SELECT count(*) FROM members WHERE id IN ($in_list);" 2>/dev/null || echo 0)
		[[ "$count" == "$expected" ]] && return 0
		sleep "$MEMBERS_INTERVAL"
	done
	return 1
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
	psql_query \
		-c "INSERT INTO sudo_grants (member_id, expires_at, reason)
		    VALUES ('$id', now() + interval '30 minutes', 'seed script')
		    ON CONFLICT (member_id) DO UPDATE
		      SET granted_at = now(),
		          expires_at = EXCLUDED.expires_at,
		          reason     = EXCLUDED.reason;" >/dev/null \
		|| fail "failed to grant sudo to $id"
}

seed_from_json() {
	local file="$1" endpoint="$2" jar="$3" label="$4" table="$5" transform="${6:-.}"
	local obj resp total seeded=0
	local -a rows=() pending=()

	mapfile -t rows < <(jq -r --argjson seen "$(existing_values "$table" name)" \
		"length, (.[] | select(.name as \$n | \$seen | index(\$n) | not) | $transform | @json)" \
		"$file")
	((${#rows[@]})) || fail "could not read ${label}s from $file"
	total=${rows[0]}
	pending=("${rows[@]:1}")

	for obj in "${pending[@]}"; do
		resp=$(cookie_curl "$jar" -X POST "$KANAE$endpoint" \
			-H "$H_CONTENT_TYPE" -d "$obj")
		if jq -e "$ID_FILTER" >/dev/null <<<"$resp"; then
			seeded=$((seeded + 1))
		else
			warn "$label '$(jq -r '.name // .title // "?"' <<<"$obj")' not created: $(jq -c '.message // .detail // .' <<<"$resp")"
		fi
	done

	ok "created $seeded/$total ${label}s ($((total - ${#pending[@]})) already present)"
}

step "0. preflight"
require curl
require jq
require openssl

if ((HAS_PSQL == 0 || HAS_VALKEY_CLI == 0)); then
	require docker
	warn "psql/valkey-cli not on PATH; falling back to docker exec"
fi

PASSWORD="$(openssl rand -hex 16)"

for f in members tags projects events; do
	[[ -f "$DATA_DIR/$f.json" ]] || fail "missing data file: $DATA_DIR/$f.json"
	jq -e . "$DATA_DIR/$f.json" >/dev/null || fail "invalid JSON in $DATA_DIR/$f.json"
done
ok "data files present and valid JSON"

wait_http "$KRATOS_PUBLIC/health/ready" "kratos public"
wait_http "$KRATOS_ADMIN/health/ready" "kratos admin"
wait_http "$KETO_WRITE/health/ready" "keto write"
wait_http "$KANAE/" "kanae"

WORK="$(mktemp -d -t kanae-seed.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ADMIN_JAR="$WORK/admin.jar"
MEMBER_JAR="$WORK/member.jar"
MANAGER_JAR="$WORK/manager.jar"
LEAD_JAR="$WORK/lead.jar"
ROSTER_JAR="$WORK/roster.jar"

step "1. provision identities + roster (serial)"

ROSTER_NAMES=() ROSTER_EMAILS=() ROSTER_ROLES=() ROSTER_IDS=() ROSTER_PASSWORDS=()
while IFS=$'\t' read -r name email role; do
	ROSTER_NAMES+=("$name")
	ROSTER_EMAILS+=("$email")
	ROSTER_ROLES+=("$role")
done < <(jq -r '.[] | [.name, .email, .role] | @tsv' "$DATA_DIR/members.json")

provision_identity "$ADMIN_JAR" "$ADMIN_EMAIL" "Seed Admin" "$PASSWORD"
ADMIN_ID=$IDENTITY_ID
provision_identity "$MEMBER_JAR" "$MEMBER_EMAIL" "Seed Member" "$PASSWORD"
MEMBER_ID=$IDENTITY_ID
provision_identity "$MANAGER_JAR" "$MANAGER_EMAIL" "Seed Manager" "$PASSWORD"
MANAGER_ID=$IDENTITY_ID
provision_identity "$LEAD_JAR" "$LEADS_EMAIL" "Seed Lead" "$PASSWORD"
LEAD_ID=$IDENTITY_ID

for i in "${!ROSTER_EMAILS[@]}"; do
	ROSTER_PASSWORDS[i]="$(openssl rand -hex 16)"
	provision_identity "$ROSTER_JAR" \
		"${ROSTER_EMAILS[$i]}" "${ROSTER_NAMES[$i]}" "${ROSTER_PASSWORDS[$i]}"
	ROSTER_IDS[i]=$IDENTITY_ID
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

valkey_query FLUSHDB >/dev/null
grant_sudo "$ADMIN_ID"
ok "granted named + roster ($roster_admins admin, $roster_managers manager, $roster_leads leads) + admin sudo, valkey flushed"

step "3. seed tags (bulk-create)"

{
	read -r TAG_TOTAL
	read -r TAG_PENDING
	read -r PENDING_TAGS
} < <(jq -c --argjson seen "$(existing_values tags title)" \
	'[.[] | select(.title as $t | $seen | index($t) | not)] as $pending
	 | length, ($pending | length), $pending' "$DATA_DIR/tags.json")

if ((TAG_PENDING == 0)); then
	ok "all $TAG_TOTAL tags already present, skipping"
else
	tag_resp=$(cookie_curl "$ADMIN_JAR" -X POST "$KANAE/tags/bulk-create" \
		-H "$H_CONTENT_TYPE" -d "$PENDING_TAGS")
	if tag_created=$(jq -e 'if type == "array" then length else empty end' <<<"$tag_resp"); then
		ok "created $tag_created/$TAG_TOTAL tags ($((TAG_TOTAL - TAG_PENDING)) already present)"
	else
		warn "bulk tag create returned no list: $(jq -c '.message // .detail // .' <<<"$tag_resp")"
	fi
fi

step "4. seed projects + events (parallel)"
seed_from_json "$DATA_DIR/projects.json" "/projects/create" "$MANAGER_JAR" "project" "projects" &
seed_from_json "$DATA_DIR/events.json" "/events/create" "$LEAD_JAR" "event" "events" \
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
