#!/usr/bin/env bash
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
AGE_KEY=${SOPS_AGE_KEY_FILE:-$CONFIG_HOME/sops/age/keys.txt}

if [[ -z ${SOPS_AGE_KEY:-} && ! -f $AGE_KEY ]]; then
	echo "apply: no age key at $AGE_KEY, so deploy/kubernetes/secrets.sops.yml cannot be decrypted. Point SOPS_AGE_KEY_FILE at yours" >&2
	exit 1
fi

log "rendering the Secrets from deploy/kubernetes/secrets.sops.yml"
secrets=$(sops --decrypt deploy/kubernetes/secrets.sops.yml \
	| helm template kanae deploy/kubernetes/src --namespace kanae \
		--set renderSecrets=true --values - --show-only templates/secrets.yml)

log "handing them to kapp beside deploy/kubernetes/dist"
kapp deploy --yes -a kanae -n kanae -c -f deploy/kubernetes/dist -f <(printf '%s\n' "$secrets")
