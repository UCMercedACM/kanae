#!/usr/bin/env bash
set -euo pipefail

# Fills in deploy/docker/.deploy.env for a production deployment.
#
# The file is copied from deploy/docker/deploy.dist.env and edited in place, so
# the template's comments, grouping and key order survive untouched — only the
# values on the right-hand side change.
#
# Re-running is safe. Existing values are kept, because replacing them is
# destructive: a new KRATOS_SECRETS_COOKIE signs every user out, and a new
# DB_PASSWORD locks the stack out of its own database until every DSN is
# updated in step. Pass -r to rotate the generated secrets deliberately.

# readlink resolves the script through any symlink, so the directory it sits in
# is the deployment directory no matter what path was typed to reach it — the
# env file and its template are siblings. Stripping the fixed `/deploy/docker`
# suffix from that yields the repository root. The layout is what anchors this,
# not the location, so a plain clone at /opt/kanae and a submodule at
# /opt/ucmacm/kanae both resolve correctly.
SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
DEPLOY_DIR=${SCRIPT_PATH%/*}
ROOT_DIR=${DEPLOY_DIR%/deploy/docker}

ENV_FILE=${ENV_FILE:-$DEPLOY_DIR/.deploy.env}
ENV_DIST_FILE=${ENV_DIST_FILE:-$DEPLOY_DIR/deploy.dist.env}
CONFIG_FILE=${CONFIG_FILE:-$ROOT_DIR/config.yml}
CONFIG_DIST_FILE=${CONFIG_DIST_FILE:-$ROOT_DIR/config.dist.yml}

# Relative to the repository root, because it is resolved inside the container
# where the root is mounted at /work.
DERIVE_SCRIPT=${DERIVE_SCRIPT:-scripts/derive-webhook-tokens.py}

# Matches the builder stage in docker/Dockerfile, so a deployment host that
# has already built Kanae has this layer cached.
UV_IMAGE=${UV_IMAGE:-ghcr.io/astral-sh/uv:python3.14-trixie-slim}

# Pinned to the version mise.toml pins for development. Running mikefarah's yq
# from its own image rather than the host's PATH also settles which yq this is:
# the Debian package is a different tool (a jq wrapper) with a different CLI,
# and is no longer maintained upstream.
YQ_IMAGE=${YQ_IMAGE:-mikefarah/yq:4.53.3}

# Values the operator has to supply; nothing can invent them.
MANUAL_KEYS=(CONFIG_LOCATION KRATOS_SMTP_URI)

# Anything that needs a human before this deployment is real. Collected as it
# is discovered and printed together at the end, so the important parts are not
# buried in the middle of the run.
NOTES=()

# Escapes are only emitted for a terminal, so redirecting to a file or to
# journald does not litter it with control characters. \033 is understood by
# every printf worth the name, unlike \e which is a bash/zsh extension.
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

# getopts stops at the first non-option, so anything left over is a typo the
# script would otherwise ignore in silence.
if [[ $# -gt 0 ]]; then
	usage >&2
	abort "unexpected argument: $1"
fi

# derive-webhook-tokens.py imports yaml, blake3 and dotenv, so a bare
# interpreter will not do. Rather than hunting for a local virtualenv, uv or
# system python — none of which a deployment host is obliged to have — every
# Python call goes through the official uv image, which is already a build
# dependency of Kanae. Docker is a hard requirement for the stack this script
# initialises, so it is the one tool that is always present.
#
# `--no-project` keeps uv away from pyproject.toml, so only the three imports
# are resolved rather than the whole project. `--user` stops the files it
# writes coming back owned by root. HOME and UV_CACHE_DIR keep uv's scratch
# inside the container instead of in the mount.
#
# `-q` drops uv's "Installed N packages" progress line, which it writes to
# stderr on every run. Silencing it that way rather than with `2>/dev/null`
# keeps resolution failures, tracebacks and the exit status intact.
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

# Only the config's own directory is mounted, so this works wherever
# CONFIG_FILE points rather than assuming it sits under ROOT_DIR — expressions
# therefore address it by bare filename. /workdir is the image's working
# directory, per mikefarah's documented docker usage. MASTER_KEY is forwarded so
# the write below can reach it through strenv() instead of being spliced into
# the expression as text.
run_yq() {
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		--volume "${CONFIG_FILE%/*}:/workdir" \
		--env MASTER_KEY \
		"$YQ_IMAGE" "$@" "${CONFIG_FILE##*/}"
}

command -v docker >/dev/null 2>&1 || abort "docker is required but was not found on PATH"

# A directory that does not match the layout comes back from the strip above
# unchanged, which would otherwise point ROOT_DIR at the deployment directory
# itself and send every path derived from it somewhere meaningless.
[[ $ROOT_DIR != "$DEPLOY_DIR" ]] \
	|| abort "expected this script in deploy/docker/, found it in $DEPLOY_DIR"

if [[ -f $ENV_FILE ]]; then
	log "updating ${ENV_FILE##*/}"
else
	[[ -f $ENV_DIST_FILE ]] || abort "no template to copy from: $ENV_DIST_FILE"
	install -m 600 "$ENV_DIST_FILE" "$ENV_FILE"
	log "created ${ENV_FILE##*/} from ${ENV_DIST_FILE##*/}"
fi

# 644 rather than 600, unlike the env file: the kanae image runs as USER kanae
# (uid 999) and a bind mount keeps the host's ownership, so a 600 config owned
# by whoever ran this script is unreadable inside the container. Tighten to
# 640 with group 999 if the host can spare the gid.
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

# The webhook tokens are keyed blake3 digests of ory.kratos_webhook_master_key,
# so that key has to exist first. They must match what Kanae computes at
# runtime — the registration hook runs with `response.ignore: false`, so a
# mismatch fails registration outright instead of degrading quietly.
#
# Rotating the master key is deliberately out of scope for -r: it would change
# both tokens underneath a Kanae still serving with the old config.
MASTER_KEY=$(run_yq -r '.ory.kratos_webhook_master_key // ""')

if [[ -n $MASTER_KEY ]]; then
	# Hex validity is enforced downstream by derive-webhook-tokens.py, which
	# already exits with a clear message; only the length is worth catching
	# here, since keyed blake3 accepts nothing but 32 bytes.
	[[ ${#MASTER_KEY} -eq 64 ]] \
		|| abort "ory.kratos_webhook_master_key must be 64 hex characters (blake3 needs 32 bytes)"
	log "ory.kratos_webhook_master_key already set, keeping it"
else
	# `-i` edits the one field and re-emits the rest of the document, so the
	# comments an operator needs stay attached to their keys. It does drop
	# the blank lines between entries, which is why the write happens once,
	# on a config that has no master key yet.
	#
	# yq rewrites through a temporary file and renames it over the original,
	# which replaces the inode and with it the mode set on copy above, so the
	# 644 the container needs is reapplied rather than left to yq's umask.
	MASTER_KEY=$(run_python -c 'import secrets; print(secrets.token_hex(32))')
	export MASTER_KEY
	run_yq -i '.ory.kratos_webhook_master_key = strenv(MASTER_KEY)'
	chmod 644 "$CONFIG_FILE"
	log "generated ory.kratos_webhook_master_key in ${CONFIG_FILE##*/}"
fi

log "deriving webhook tokens"
run_python "/work/$DERIVE_SCRIPT" >/dev/null

# Read after the derive step, which writes the token values itself — loading
# earlier would mean saving a stale copy back over them.
#
# Bash has no .env facility, and `source` is not a substitute: it expands `$`
# inside values, splits on whitespace and executes substitutions, so a password
# containing `$` comes back silently truncated. The file is data, so it is read
# as data — mapfile slurps it in one builtin, and the single pass below records
# both each key's value and the line it sits on, making later reads and writes
# direct index operations rather than repeated scans.
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
	local key=$1 value=$2 index=${LINE_OF[$1]:-}
	VALUES[$key]=$value
	if [[ -n $index ]]; then
		ENV_LINES[index]="$key=$value"
	else
		LINE_OF[$key]=${#ENV_LINES[@]}
		ENV_LINES+=("$key=$value")
	fi
}

# Hex rather than base64: DB_PASSWORD is interpolated into six postgres DSNs,
# and base64's `/` terminates the userinfo component, so `postgres://user:a/b@host`
# parses with the host as `user`. Hex is a subset of the URI unreserved set, so
# it never needs escaping anywhere it lands — DSN, compose .env, or config.yml.
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

# Rewrites in place, so the 600 mode set when the file was created is kept.
printf '%s\n' "${ENV_LINES[@]}" >"$ENV_FILE"

for KEY in "${MANUAL_KEYS[@]}"; do
	if [[ -z ${VALUES[$KEY]:-} ]]; then
		NOTES+=("$KEY still needs a value")
	fi
done

# The template ships a developer's absolute path, so this is non-empty but
# wrong on any other host.
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
