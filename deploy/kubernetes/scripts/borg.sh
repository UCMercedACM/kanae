#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
KUBERNETES_DIR=${SCRIPT_PATH%/scripts/*}

ENCRYPTED=${ENCRYPTED:-$KUBERNETES_DIR/secrets.sops.yml}
VALUES=$KUBERNETES_DIR/src/values.yaml

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
	printf 'Saves the BorgBase repository URL and host key to\n'
	printf '%s, then creates the repository.\n\n' "$ENCRYPTED"
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

REQUIRED=(docker gum sops ssh-keygen ssh-keyscan yq)
for cmd in "${REQUIRED[@]}"; do
	command -v "$cmd" >/dev/null || abort "$cmd is required"
done

[[ -f $ENCRYPTED ]] || abort "$ENCRYPTED not found, run deploy/kubernetes/init.sh first"

IMAGE=$(yq -r '.backup.borgmatic.image.repository + ":" + .backup.borgmatic.image.tag' "$VALUES")

log "reading the backup values in $ENCRYPTED"
SECRETS=$(sops --decrypt "$ENCRYPTED")
BORG_PASSPHRASE=$(yq -r '.secrets.borgPassphrase // ""' <<<"$SECRETS")
[[ -n $BORG_PASSPHRASE ]] || abort "$ENCRYPTED has no backup values, run deploy/kubernetes/init.sh first"

REPO=$(gum input --password --no-show-help --prompt 'BorgBase Repository URL: ' \
	--placeholder 'ssh://<id>@<id>.repo.borgbase.com/./repo' --placeholder.foreground 245 </dev/tty)
[[ $REPO =~ ^ssh://[a-z0-9]+@([a-z0-9]+\.repo\.borgbase\.com)/\./repo$ ]] \
	|| abort "$REPO is not a BorgBase repository URL"
HOST=${BASH_REMATCH[1]}

KNOWN_HOSTS=$(ssh-keyscan -q -t ed25519 "$HOST" 2>/dev/null) || true
[[ -n $KNOWN_HOSTS ]] || abort "$HOST did not return an ed25519 host key"

log "host key fingerprint for $HOST"
ssh-keygen -lf - <<<"$KNOWN_HOSTS" >&2
gum confirm 'Does it match the fingerprint BorgBase shows for the repository?' </dev/tty \
	|| abort "the host key does not match, nothing was saved"

umask 077
DIR=$(mktemp -d)
TMP=$(mktemp "$ENCRYPTED.XXXXXX")
trap 'rm -rf "$DIR" "$TMP"' EXIT

log "saving the repository URL and host key to $ENCRYPTED"
REPO=$REPO KNOWN_HOSTS=$KNOWN_HOSTS yq '
	.secrets.borgRepo = strenv(REPO)
	| .secrets.borgKnownHosts = strenv(KNOWN_HOSTS)
' <<<"$SECRETS" \
	| sops --encrypt --filename-override "$ENCRYPTED" --input-type yaml /dev/stdin >"$TMP"
mv "$TMP" "$ENCRYPTED"

yq -r '.secrets.borgSshKey' <<<"$SECRETS" >"$DIR/key"
printf '%s\n' "$KNOWN_HOSTS" >"$DIR/known_hosts"

log "creating the repository if it does not exist yet, then exporting its key. Store the key below with the break-glass age key, outside the cluster and off any one officer's laptop"
BORG_REPO=$REPO BORG_PASSPHRASE=$BORG_PASSPHRASE docker run --rm -i -v "$DIR:/keys:ro" \
	-e BORG_REPO -e BORG_PASSPHRASE \
	-e BORG_RSH='ssh -i /keys/key -o IdentitiesOnly=yes -o UserKnownHostsFile=/keys/known_hosts -o StrictHostKeyChecking=yes' \
	--entrypoint sh \
	"$IMAGE" -c 'borg info >/dev/null 2>&1 || borg init --encryption repokey-blake2 && borg key export'
