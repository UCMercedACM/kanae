#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
DEPLOY_DIR=${SCRIPT_PATH%/*}
ROOT_DIR=${DEPLOY_DIR%/deploy/docker}

ENV_FILE=${ENV_FILE:-$DEPLOY_DIR/.deploy.env}
ENV_DIST_FILE=${ENV_DIST_FILE:-$DEPLOY_DIR/deploy.dist.env}
CONFIG_FILE=${CONFIG_FILE:-$ROOT_DIR/config.yml}
CONFIG_DIST_FILE=${CONFIG_DIST_FILE:-$ROOT_DIR/config.dist.yml}

DERIVE_SCRIPT=${DERIVE_SCRIPT:-scripts/derive-webhook-tokens.py}

UV_IMAGE=${UV_IMAGE:-ghcr.io/astral-sh/uv:python3.14-trixie-slim}
YQ_IMAGE=${YQ_IMAGE:-mikefarah/yq:4.53.3}

MANUAL_KEYS=(CONFIG_LOCATION KRATOS_SMTP_URI)
NOTES=()

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	BLUE=$'\033[1;34m' YELLOW=$'\033[1;33m' RED=$'\033[1;31m' RESET=$'\033[0m'
else
	BLUE='' YELLOW='' RED='' RESET=''
fi

log() { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
warn() { printf '%swarn:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
abort() {
	printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
	exit 1
}

usage() {
	printf 'usage: %s [-r] [-h]\n\n' "${0##*/}"
	printf '  -r  rotate the generated secrets instead of keeping existing ones\n'
	printf '  -h  show this help\n'
}

ROTATE=false
while getopts ':rh' OPT; do
	case $OPT in
		r) ROTATE=true ;;
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

if [[ $# -gt 0 ]]; then
	usage >&2
	abort "unexpected argument: $1"
fi

run_python() {
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		--volume "$ROOT_DIR:/work" --workdir /work \
		--env HOME=/tmp --env UV_CACHE_DIR=/tmp/uv-cache \
		"$UV_IMAGE" \
		uv run -q --no-project \
		--with pyyaml --with blake3 --with python-dotenv \
		python "$@"
}

run_yq() {
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		--volume "${CONFIG_FILE%/*}:/workdir" \
		--env MASTER_KEY \
		"$YQ_IMAGE" "$@" "${CONFIG_FILE##*/}"
}

command -v docker >/dev/null 2>&1 || abort "docker is required but was not found on PATH"

[[ $ROOT_DIR != "$DEPLOY_DIR" ]] \
	|| abort "expected this script in deploy/docker/, found it in $DEPLOY_DIR"

if [[ -f $ENV_FILE ]]; then
	log "updating ${ENV_FILE##*/}"
else
	[[ -f $ENV_DIST_FILE ]] || abort "no template to copy from: $ENV_DIST_FILE"
	install -m 600 "$ENV_DIST_FILE" "$ENV_FILE"
	log "created ${ENV_FILE##*/} from ${ENV_DIST_FILE##*/}"
fi

# 644 is used here to allow whoever ran this script to actually have it readable in the container
# IF needed, tighten to 640 w/ group 999
if [[ -f $CONFIG_FILE ]]; then
	log "using ${CONFIG_FILE##*/}"
else
	[[ -f $CONFIG_DIST_FILE ]] || abort "no template to copy from: $CONFIG_DIST_FILE"
	install -m 644 "$CONFIG_DIST_FILE" "$CONFIG_FILE"
	log "created ${CONFIG_FILE##*/} from ${CONFIG_DIST_FILE##*/}"
	NOTES+=("$(
		printf '%s\n' \
			"${CONFIG_FILE##*/} is a fresh copy of ${CONFIG_DIST_FILE##*/} and is NOT production-ready:" \
			"        review at minimum kanae.allowed_origins, ory.* URLs, postgres_uri and storage.*" \
			"        then point CONFIG_LOCATION at it: $CONFIG_FILE"
	)")
fi

MASTER_KEY=$(run_yq -r '.ory.kratos_webhook_master_key // ""')

if [[ -n $MASTER_KEY ]]; then
	[[ ${#MASTER_KEY} -eq 64 ]] \
		|| abort "ory.kratos_webhook_master_key must be 64 hex characters (blake3 needs 32 bytes)"
	log "ory.kratos_webhook_master_key already set, keeping it"
else
	MASTER_KEY=$(run_python -c 'import secrets; print(secrets.token_hex(32))')
	export MASTER_KEY

	run_yq -i '.ory.kratos_webhook_master_key = strenv(MASTER_KEY)'
	chmod 644 "$CONFIG_FILE"
	log "generated ory.kratos_webhook_master_key in ${CONFIG_FILE##*/}"
fi

log "deriving webhook tokens"
run_python "/work/$DERIVE_SCRIPT" >/dev/null

mapfile -t ENV_LINES <"$ENV_FILE"

declare -A VALUES=() LINE_OF=()
for INDEX in "${!ENV_LINES[@]}"; do
	LINE=${ENV_LINES[INDEX]}
	if [[ $LINE == [A-Za-z_]*=* ]]; then
		VALUES[${LINE%%=*}]=${LINE#*=}
		LINE_OF[${LINE%%=*}]=$INDEX
	fi
done

set_var() {
	local key=$1 value=$2
	local index=${LINE_OF[$key]:-}
	VALUES[$key]=$value
	if [[ -n $index ]]; then
		ENV_LINES[index]="$key=$value"
	else
		LINE_OF[$key]=${#ENV_LINES[@]}
		ENV_LINES+=("$key=$value")
	fi
}

generate_secret() {
	local key=$1 bytes=$2
	if [[ -n ${VALUES[$key]:-} && $ROTATE == false ]]; then
		log "$key already set, keeping it"
		return
	fi
	set_var "$key" "$(openssl rand -hex "$bytes")"
	log "$key generated"
}

generate_secret DB_PASSWORD 32
generate_secret KRATOS_SECRETS_COOKIE 32
generate_secret KRATOS_SECRETS_CIPHER 16

printf '%s\n' "${ENV_LINES[@]}" >"$ENV_FILE"

for KEY in "${MANUAL_KEYS[@]}"; do
	if [[ -z ${VALUES[$KEY]:-} ]]; then
		NOTES+=("$KEY still needs a value")
	fi
done

CONFIG_LOCATION=${VALUES[CONFIG_LOCATION]:-}
if [[ -n $CONFIG_LOCATION && ! -e $CONFIG_LOCATION ]]; then
	NOTES+=("CONFIG_LOCATION is $CONFIG_LOCATION, which does not exist here")
fi

log "done"

if [[ ${#NOTES[@]} -gt 0 ]]; then
	printf '\n%s--- before deploying ---%s\n' "$YELLOW" "$RESET" >&2
	for NOTE in "${NOTES[@]}"; do
		warn "$NOTE"
	done
fi
