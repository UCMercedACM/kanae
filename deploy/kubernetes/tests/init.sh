#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
TESTS_DIR=${SCRIPT_PATH%/*}
ROOT_DIR=${TESTS_DIR%/deploy/kubernetes/tests}
cd "$ROOT_DIR"

HELMFILE=deploy/kubernetes/helmfile.yaml
CHART=deploy/kubernetes/src
VALUES=deploy/kubernetes/values.local.yml
RENDER=.k8s-local
APP=kanae-local
NAMESPACE=kanae
HURL_VARS="deploy/kubernetes/tests/vars.env"
HURL_SECRETS_FILE="deploy/kubernetes/tests/secrets.env"
ACCEPT_JSON="Accept: application/json"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	BLUE=$'\033[1;34m' RED=$'\033[1;31m' RESET=$'\033[0m'
else
	BLUE='' RED='' RESET=''
fi

log() { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*" >&2; }
abort() {
	printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
	exit 1
}

usage() {
	printf 'usage: %s [--help]\n\n' "${0##*/}"
	printf '  --help  show this help\n'
}

while [[ $# -gt 0 ]]; do
	case $1 in
		--help)
			usage
			exit 0
			;;
		*)
			usage >&2
			abort "unknown option: $1"
			;;
	esac
done

for cmd in docker k3d helm helmfile kapp kubectl yq jq openssl; do
	command -v "$cmd" >/dev/null || abort "$cmd is required"
done

### 1. Create cluster

log "creating the cluster"
k3d cluster create --config deploy/kubernetes/k3d.yml

log "installing Cilium"
helmfile -f "$HELMFILE" sync -l name=cilium
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl create namespace "$NAMESPACE"

log "installing Envoy Gateway and cert-manager"
helmfile -f "$HELMFILE" sync -l tier=controllers
kubectl apply -f deploy/kubernetes/envoy.yml -f deploy/kubernetes/gateway.yml

### 2. Render and apply to cluster

log "rendering $VALUES into $RENDER"
rm -f "$RENDER"/*.yml
helm template kanae "$CHART" --namespace "$NAMESPACE" --values "$VALUES" \
	| yq --no-doc 'select(.kind != null and .kind != "Secret")' \
		-s "\"$RENDER/\(.kind | downcase)-\(.metadata.name).yml\""

log "rendering throwaway Secrets from deploy/kubernetes/init.sh --local"
secrets=$(deploy/kubernetes/init.sh --local \
	| helm template kanae "$CHART" --namespace "$NAMESPACE" \
		--values "$VALUES" --values - \
		--set renderSecrets=true --show-only templates/secrets.yml)

log "applying $RENDER as $APP"
kapp deploy --yes -a "$APP" -n "$NAMESPACE" -c \
	-f "$RENDER" -f <(printf '%s\n' "$secrets")

### 3. Seed identities, member rows, etc

if [[ -f "$HURL_SECRETS_FILE" ]]; then
	PASSWORD=$(grep '^PASSWORD=' "$HURL_SECRETS_FILE" | cut -d= -f2)
	log "reusing PASSWORD from existing $HURL_SECRETS_FILE"
else
	PASSWORD=$(openssl rand -hex 32)
fi

# shellcheck source=/dev/null
source "$HURL_VARS"

declare -A ROLE_TO_EMAIL_VAR=(
	[root]=ROOT_EMAIL
	[admin]=ADMIN_EMAIL
	[manager]=MANAGER_EMAIL
	[leads]=LEADS_EMAIL
	[member]=MEMBER_EMAIL
	[scratch]=SCRATCH_EMAIL
)
declare -A IDS=()
ROLE_ORDER=(root admin manager leads member scratch)

log "creating identities via Kratos admin API"
for role in "${ROLE_ORDER[@]}"; do
	email_var="${ROLE_TO_EMAIL_VAR[$role]}"
	email="${!email_var}"
	body=$(jq -n \
		--arg email "$email" --arg name "$role" --arg pw "$PASSWORD" '
	{
	  schema_id: "default",
	  state: "active",
	  traits: { email: $email, name: $name, display_name: $name },
	  credentials: { password: { config: { password: $pw } } },
	  verifiable_addresses: [
	    { value: $email, verified: true, via: "email", status: "completed" }
	  ]
	}')

	resp=$(kubectl -n "$NAMESPACE" exec deploy/kanae -- curl -sS -w '\n%{http_code}' \
		-H "$ACCEPT_JSON" \
		-H 'Content-Type: application/json' \
		-X POST "$KRATOS_ADMIN_URL/admin/identities" \
		-d "$body")
	code="${resp##*$'\n'}"
	body="${resp%$'\n'*}"

	case "$code" in
		201)
			id=$(jq -r '.id' <<<"$body")
			;;
		409)
			id=$(kubectl -n "$NAMESPACE" exec deploy/kanae -- curl -fsS -H "$ACCEPT_JSON" \
				"$KRATOS_ADMIN_URL/admin/identities?credentials_identifier=$email" \
				| jq -r '.[0].id')
			;;
		*)
			abort "kratos POST /admin/identities failed ($code): $body"
			;;
	esac

	IDS[$role]="$id"
	printf '    %-8s  %s  (%s)\n' "$role" "$id" "$email"
done

log "upserting matching members rows (admin-create bypasses the registration webhook)"
for role in "${ROLE_ORDER[@]}"; do
	email_var="${ROLE_TO_EMAIL_VAR[$role]}"
	email="${!email_var}"
	id="${IDS[$role]}"
	kubectl -n "$NAMESPACE" exec statefulset/database -- \
		psql -U kanae -d kanae -v ON_ERROR_STOP=1 -q -c \
		"INSERT INTO members (id, name, display_name, email)
	 VALUES ('$id', '$role', '$role', '$email')
	 ON CONFLICT (id) DO UPDATE
	   SET name = EXCLUDED.name,
	       display_name = EXCLUDED.display_name,
	       email = EXCLUDED.email;" >/dev/null
done

log "writing Keto Role:* tuples for root / admin / manager / leads"
for role in root admin manager leads; do
	id="${IDS[$role]}"
	body=$(jq -n --arg ns Role --arg obj "$role" --arg rel member --arg subj "$id" '
	{ namespace: $ns, object: $obj, relation: $rel, subject_id: $subj }')
	kubectl -n "$NAMESPACE" exec deploy/kanae -- curl -fsS \
		-H "$ACCEPT_JSON" \
		-H 'Content-Type: application/json' \
		-X PUT "$KETO_WRITE_URL/admin/relation-tuples" \
		-d "$body" \
		>/dev/null
done

root_admin=$(jq -n --arg ns Role --arg obj admin --arg rel member --arg subj "${IDS[root]}" '
	{ namespace: $ns, object: $obj, relation: $rel, subject_id: $subj }')
kubectl -n "$NAMESPACE" exec deploy/kanae -- curl -fsS \
	-H "$ACCEPT_JSON" \
	-H 'Content-Type: application/json' \
	-X PUT "$KETO_WRITE_URL/admin/relation-tuples" \
	-d "$root_admin" \
	>/dev/null

log "writing secrets (password + identity UUIDs) to $HURL_SECRETS_FILE"
cat >"$HURL_SECRETS_FILE" <<EOF
PASSWORD=$PASSWORD
ROOT_ID=${IDS[root]}
ADMIN_ID=${IDS[admin]}
MANAGER_ID=${IDS[manager]}
LEADS_ID=${IDS[leads]}
MEMBER_ID=${IDS[member]}
SCRATCH_ID=${IDS[scratch]}
EOF

log "cluster is now fully ready."
log "hurl: hurl --test --insecure --resolve kanae:443:127.0.0.1 --resolve kanae:80:127.0.0.1 --variables-file $HURL_VARS --secrets-file $HURL_SECRETS_FILE deploy/kubernetes/tests/scenarios/*.hurl"
