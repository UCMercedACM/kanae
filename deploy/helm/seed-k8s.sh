#!/usr/bin/env bash
#
# Creates the two Secrets the Helm chart expects:
#
#   kanae-env     DB_*, KRATOS_SECRETS_*, KRATOS_WEBHOOK_TOKEN_*, KRATOS_SMTP_URI
#   kanae-config  config.yml, rendered from config.dist.yml
#
# Idempotent: existing values are read back out of the cluster and kept, so
# re-running does not rotate anything. Pass -r to rotate the generated secrets.
# The webhook tokens are ALWAYS recomputed from the master key, so they cannot
# drift from it.
#
# Same shape as deploy/docker/init.sh, which does this for the compose stack.

set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
HELM_DIR=${SCRIPT_PATH%/*}
ROOT_DIR=${HELM_DIR%/deploy/helm}

CONFIG_DIST=${CONFIG_DIST:-$ROOT_DIR/config.dist.yml}

NAMESPACE=${NAMESPACE:-kanae}
ENV_SECRET=${ENV_SECRET:-kanae-env}
CONFIG_SECRET=${CONFIG_SECRET:-kanae-config}

# MUST match scripts/derive-webhook-tokens.py and src/routes/members.py.
# Bumping a version suffix changes the derived token.
declare -A HOOKS=(
	[KRATOS_WEBHOOK_TOKEN_REGISTRATION]=kratos.registration.v1
	[KRATOS_WEBHOOK_TOKEN_SETTINGS]=kratos.settings.v1
)

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	BLUE=$'\033[1;34m' YELLOW=$'\033[1;33m' RED=$'\033[1;31m' RESET=$'\033[0m'
else
	BLUE='' YELLOW='' RED='' RESET=''
fi

# stderr, not stdout: several helpers below run inside $(...) and any stray
# stdout would be captured into the secret value.
log() { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*" >&2; }
warn() { printf '%swarn:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
abort() {
	printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
	exit 1
}

usage() {
	printf 'usage: %s [-l] [-r] [-n NAMESPACE] [-o FILE] [-h]\n\n' "${0##*/}"
	printf '  -l  local mode: fill the externally-issued secrets (R2, SMTP) with\n'
	printf '      throwaway values instead of prompting. For k3d only.\n'
	printf '  -r  rotate the generated secrets instead of keeping existing ones\n'
	printf '  -n  namespace to write into (default: %s)\n' "$NAMESPACE"
	printf '  -o  write the values to FILE (mode 0600) instead of applying them,\n'
	printf '      for encrypting with sops. Nothing touches the cluster.\n'
	printf '  -h  show this help\n'
}

LOCAL=false ROTATE=false OUT_FILE=''
while getopts ':lrn:o:h' OPT; do
	case $OPT in
		l) LOCAL=true ;;
		r) ROTATE=true ;;
		n) NAMESPACE=$OPTARG ;;
		o) OUT_FILE=$OPTARG ;;
		h)
			usage
			exit 0
			;;
		*)
			usage >&2
			abort "unknown option: -$OPTARG"
			;;
	esac
done
shift "$((OPTIND - 1))"
[[ $# -eq 0 ]] || { usage >&2; abort "unexpected argument: $1"; }

for cmd in uv yq openssl; do
	command -v "$cmd" >/dev/null 2>&1 || abort "$cmd is required but was not found on PATH"
done
# -o writes a file and never talks to the cluster, so kubectl is only needed
# when we are actually applying.
if [[ -z $OUT_FILE ]]; then
	command -v kubectl >/dev/null 2>&1 || abort "kubectl is required but was not found on PATH"
fi
[[ -f $CONFIG_DIST ]] || abort "config template not found: $CONFIG_DIST"

# ---------------------------------------------------------------- helpers ---

# Read one key out of the existing Secret. Empty string when absent.
existing() {
	kubectl -n "$NAMESPACE" get secret "$ENV_SECRET" \
		-o "jsonpath={.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# Keep what is already there unless -r. $2 is the generator command.
keep_or_generate() {
	local key=$1 gen=$2 current=''
	[[ -n $OUT_FILE ]] || current=$(existing "$key")
	if [[ -n $current && $ROTATE == false ]]; then
		log "$key already set, keeping it"
		printf '%s' "$current"
		return
	fi
	log "$key generated"
	eval "$gen"
}

prompt_secret() {
	local key=$1 desc=$2 current=''
	[[ -n $OUT_FILE ]] || current=$(existing "$key")
	if [[ -n $current ]]; then
		log "$key already set, keeping it"
		printf '%s' "$current"
		return
	fi
	if [[ $LOCAL == true ]]; then
		printf 'local-dev-%s' "$(printf '%s' "$key" | tr 'A-Z_' 'a-z-')"
		return
	fi
	local value=''
	read -r -s -p "  $desc: " value </dev/tty
	printf '\n' >&2
	[[ -n $value ]] || abort "$key cannot be empty"
	printf '%s' "$value"
}

derive_token() {
	local context=$1 master=$2
	MASTER_KEY=$master CONTEXT=$context uv run -q --no-project --with blake3 python -c '
import os
from blake3 import blake3
key = bytes.fromhex(os.environ["MASTER_KEY"])
if len(key) != 32:
    raise SystemExit("master key must be 32 bytes / 64 hex chars")
print(blake3(os.environ["CONTEXT"].encode(), key=key).hexdigest())
'
}

# ------------------------------------------------------------- generation ---

log "namespace: $NAMESPACE"
[[ -n $OUT_FILE ]] && log "writing to $OUT_FILE (cluster untouched)"
[[ $LOCAL == true ]] && warn "local mode: R2 and SMTP values are throwaway placeholders"

DB_USERNAME=postgres
DB_DATABASE_NAME=kanae

DB_PASSWORD=$(keep_or_generate DB_PASSWORD 'openssl rand -hex 32')
KRATOS_SECRETS_COOKIE=$(keep_or_generate KRATOS_SECRETS_COOKIE 'openssl rand -hex 32')
KRATOS_SECRETS_CIPHER=$(keep_or_generate KRATOS_SECRETS_CIPHER 'openssl rand -hex 16')
KRATOS_WEBHOOK_MASTER_KEY=$(keep_or_generate KRATOS_WEBHOOK_MASTER_KEY 'openssl rand -hex 32')

[[ ${#KRATOS_WEBHOOK_MASTER_KEY} -eq 64 ]] \
	|| abort "KRATOS_WEBHOOK_MASTER_KEY must be 64 hex characters (blake3 needs 32 bytes)"

log "deriving webhook tokens from the master key"
declare -A TOKENS=()
for name in "${!HOOKS[@]}"; do
	TOKENS[$name]=$(derive_token "${HOOKS[$name]}" "$KRATOS_WEBHOOK_MASTER_KEY")
done

if [[ $LOCAL == false && -z $(existing STORAGE_KEY_ID) ]]; then
	printf '\n%sExternally-issued secrets%s (Cloudflare R2, SMTP). Input is hidden.\n' \
		"$BLUE" "$RESET" >&2
fi
STORAGE_KEY_ID=$(prompt_secret STORAGE_KEY_ID 'R2 access key id')
STORAGE_SECRET_KEY=$(prompt_secret STORAGE_SECRET_KEY 'R2 secret access key')
KRATOS_SMTP_URI=$(prompt_secret KRATOS_SMTP_URI 'SMTP URI (smtps://user:pass@host:465)')

# ----------------------------------------------------------- config.yml -----

log "rendering config.yml from ${CONFIG_DIST##*/}"
CONFIG_YML=$(
	DB_PASSWORD=$DB_PASSWORD \
	DB_USERNAME=$DB_USERNAME \
	DB_DATABASE_NAME=$DB_DATABASE_NAME \
	MASTER_KEY=$KRATOS_WEBHOOK_MASTER_KEY \
	KEY_ID=$STORAGE_KEY_ID \
	SECRET_KEY=$STORAGE_SECRET_KEY \
	S3_URL=${S3_URL:-https://s3.example.r2.cloudflarestorage.com} \
	S3_PUBLIC_URL=${S3_PUBLIC_URL:-https://media.ucmacm.dev} \
		yq '
		.kanae.host = "0.0.0.0" |
		.kanae.dev_mode = false |
		.kanae.prometheus.enabled = true |
		.kanae.prometheus.host = "0.0.0.0" |
		.kanae.limiter.storage_uri = "valkey://valkey:6379/" |
		.ory.kratos_public_url = "http://kratos:4433" |
		.ory.kratos_admin_url  = "http://kratos:4434" |
		.ory.keto_read_url     = "http://keto:4466" |
		.ory.keto_write_url    = "http://keto:4467" |
		.ory.kratos_webhook_master_key = strenv(MASTER_KEY) |
		.storage.url         = strenv(S3_URL) |
		.storage.presign_url = strenv(S3_URL) |
		.storage.region      = "auto" |
		.storage.key_id      = strenv(KEY_ID) |
		.storage.secret_key  = strenv(SECRET_KEY) |
		.storage.public.url  = strenv(S3_PUBLIC_URL) |
		.postgres_uri = "postgresql://" + strenv(DB_USERNAME) + ":" + strenv(DB_PASSWORD)
		                 + "@database:5432/" + strenv(DB_DATABASE_NAME)
	' "$CONFIG_DIST"
)

# --------------------------------------------------------------- output -----

if [[ -n $OUT_FILE ]]; then
	umask 077
	{
		printf '# Generated by %s — encrypt with sops before committing.\n' "${0##*/}"
		printf 'secrets:\n'
		printf '  dbUsername: %s\n' "$DB_USERNAME"
		printf '  dbDatabaseName: %s\n' "$DB_DATABASE_NAME"
		printf '  dbPassword: %s\n' "$DB_PASSWORD"
		printf '  kratosSecretsCookie: %s\n' "$KRATOS_SECRETS_COOKIE"
		printf '  kratosSecretsCipher: %s\n' "$KRATOS_SECRETS_CIPHER"
		printf '  kratosWebhookMasterKey: %s\n' "$KRATOS_WEBHOOK_MASTER_KEY"
		printf '  kratosWebhookTokenRegistration: %s\n' "${TOKENS[KRATOS_WEBHOOK_TOKEN_REGISTRATION]}"
		printf '  kratosWebhookTokenSettings: %s\n' "${TOKENS[KRATOS_WEBHOOK_TOKEN_SETTINGS]}"
		printf '  storageKeyId: %s\n' "$STORAGE_KEY_ID"
		printf '  storageSecretKey: %s\n' "$STORAGE_SECRET_KEY"
		printf '  kratosSmtpUri: %s\n' "$KRATOS_SMTP_URI"
	} >"$OUT_FILE"
	log "wrote $OUT_FILE (0600)"
	warn "contains plaintext secrets — 'sops -e -i $OUT_FILE' now, and never commit it unencrypted"
	exit 0
fi

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
	log "creating namespace $NAMESPACE"
	kubectl create namespace "$NAMESPACE"
}

log "applying $ENV_SECRET"
kubectl -n "$NAMESPACE" create secret generic "$ENV_SECRET" \
	--from-literal=DB_USERNAME="$DB_USERNAME" \
	--from-literal=DB_DATABASE_NAME="$DB_DATABASE_NAME" \
	--from-literal=DB_PASSWORD="$DB_PASSWORD" \
	--from-literal=KRATOS_SECRETS_COOKIE="$KRATOS_SECRETS_COOKIE" \
	--from-literal=KRATOS_SECRETS_CIPHER="$KRATOS_SECRETS_CIPHER" \
	--from-literal=KRATOS_WEBHOOK_MASTER_KEY="$KRATOS_WEBHOOK_MASTER_KEY" \
	--from-literal=KRATOS_WEBHOOK_TOKEN_REGISTRATION="${TOKENS[KRATOS_WEBHOOK_TOKEN_REGISTRATION]}" \
	--from-literal=KRATOS_WEBHOOK_TOKEN_SETTINGS="${TOKENS[KRATOS_WEBHOOK_TOKEN_SETTINGS]}" \
	--from-literal=STORAGE_KEY_ID="$STORAGE_KEY_ID" \
	--from-literal=STORAGE_SECRET_KEY="$STORAGE_SECRET_KEY" \
	--from-literal=KRATOS_SMTP_URI="$KRATOS_SMTP_URI" \
	--dry-run=client -o yaml | kubectl apply -f -

log "applying $CONFIG_SECRET"
printf '%s' "$CONFIG_YML" | kubectl -n "$NAMESPACE" create secret generic "$CONFIG_SECRET" \
	--from-file=config.yml=/dev/stdin \
	--dry-run=client -o yaml | kubectl apply -f -

log "done"

if [[ $LOCAL == false ]]; then
	printf '\n%s--- back these up ---%s\n' "$YELLOW" "$RESET" >&2
	warn "KRATOS_SECRETS_CIPHER encrypts Kratos data at rest. Your borgmatic dumps"
	warn "hold the ciphertext, not this key — lose it and a perfect database restore"
	warn "yields unreadable identities. Same for KRATOS_WEBHOOK_MASTER_KEY."
	warn "Re-run with -o to emit them for sops, and store the age key off-cluster."
fi
