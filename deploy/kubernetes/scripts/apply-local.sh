#!/usr/bin/env bash

set -euo pipefail

CHART=${CHART:-deploy/kubernetes/src}
VALUES=${VALUES:-deploy/kubernetes/values.local.yml}
RENDER=${RENDER:-.k8s-local}
APP=${APP:-kanae-local}
NAMESPACE=${NAMESPACE:-kanae}
WAIT=${WAIT:-true}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "rendering throwaway Secrets from deploy/kubernetes/init.sh --local"
secrets=$(deploy/kubernetes/init.sh --local \
	| helm template kanae "$CHART" --namespace "$NAMESPACE" \
		--values "$VALUES" --values - \
		--set renderSecrets=true --show-only templates/secrets.yml)

log "applying $RENDER as $APP"
kapp deploy --yes -a "$APP" -n "$NAMESPACE" -c \
	-f "$RENDER" -f <(printf '%s\n' "$secrets") --wait="$WAIT"
