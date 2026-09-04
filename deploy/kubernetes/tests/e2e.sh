#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR/../../.."

K3D_CONFIG=deploy/kubernetes/k3d.yml
CHART=deploy/kubernetes/src
VALUES=deploy/kubernetes/values.local.yml
RENDER=.k8s-local
APP=kanae-local

CLUSTER=${CLUSTER:-kanae}
NAMESPACE=${NAMESPACE:-kanae}
IMAGE=${IMAGE:-ghcr.io/ucmercedacm/kanae:dev}
GATES=${GATES:-$SCRIPT_DIR/gates}
VARS_ENV=${VARS_ENV:-tests/integration/vars.env}

WAIT=${WAIT:-false}
KEEP=${KEEP:-0}

step() {
	local message=$1
	printf '\n==> %s\n' "$message"
}

note() {
	local message=$1
	printf '    %s\n' "$message"
}

teardown() {
	if [[ $KEEP == 1 ]]; then
		step "keeping cluster $CLUSTER"
		note "k3d cluster delete --config $K3D_CONFIG"
		return
	fi

	step "deleting cluster $CLUSTER"
	k3d cluster delete --config "$K3D_CONFIG"
}

step "creating cluster $CLUSTER"
k3d cluster create --config "$K3D_CONFIG"
trap teardown EXIT
kubectl wait --for=condition=Ready nodes --all --timeout=300s

step "creating namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

step "importing $IMAGE"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	k3d image import "$IMAGE" --cluster "$CLUSTER"
else
	note "not built locally, the cluster pulls it instead"
fi

step "rendering $VALUES into $RENDER"
rm -f "$RENDER"/*.yml
helm template kanae "$CHART" --namespace "$NAMESPACE" --values "$VALUES" \
	| yq --no-doc 'select(.kind != null and .kind != "Secret")' \
		-s "\"$RENDER/\(.kind | downcase)-\(.metadata.name).yml\""

step "applying $RENDER as $APP"
if compgen -G "$RENDER/*.yml" >/dev/null; then
	kapp deploy -a "$APP" -n "$NAMESPACE" -c -f "$RENDER" --wait="$WAIT" --yes
else
	note "the chart renders nothing yet"
fi

step "what is running"
kubectl -n "$NAMESPACE" get all

step "running the gates"
if compgen -G "$GATES/*.hurl" >/dev/null; then
	hurl --test --glob "$GATES/*.hurl" --variables-file "$VARS_ENV"
else
	note "no gates in $GATES yet"
fi
