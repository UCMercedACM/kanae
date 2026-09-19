#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
TESTS_DIR=${SCRIPT_PATH%/*}
ROOT_DIR=${TESTS_DIR%/deploy/kubernetes/tests}
cd "$ROOT_DIR"

K3D_CONFIG=deploy/kubernetes/k3d.yml
HELMFILE=deploy/kubernetes/helmfile.yaml
CHART=deploy/kubernetes/src
VALUES=deploy/kubernetes/values.local.yml
RENDER=.k8s-local
NAMESPACE=kanae

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
abort() {
	printf 'e2e: %s\n' "$*" >&2
	exit 1
}

usage() {
	printf 'usage: %s [--keep] [--wait] [--help]\n\n' "${0##*/}"
	printf '  --keep  leave the cluster running afterwards instead of deleting it\n'
	printf '  --wait  wait for every applied resource to become healthy\n'
	printf '  --help  show this help\n'
}

KEEP=
WAIT=false
while [[ $# -gt 0 ]]; do
	case $1 in
		--keep)
			KEEP=1
			shift
			;;
		--wait)
			WAIT=true
			shift
			;;
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

CLUSTER=$(yq '.metadata.name' "$K3D_CONFIG")

log "creating cluster $CLUSTER"
k3d cluster create --config "$K3D_CONFIG"

if [[ -n $KEEP ]]; then
	log "--keep given, delete it yourself with: k3d cluster delete --config $K3D_CONFIG"
else
	trap 'k3d cluster delete --config "$K3D_CONFIG"' EXIT
fi

log "installing Cilium"
helmfile -f "$HELMFILE" sync -l name=cilium

kubectl wait --for=condition=Ready nodes --all --timeout=300s

log "creating namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE"

log "installing Envoy Gateway and cert-manager"
helmfile -f "$HELMFILE" sync -l tier=controllers

kubectl apply -f deploy/kubernetes/envoy.yml -f deploy/kubernetes/gateway.yml

log "rendering $VALUES into $RENDER"
mkdir -p "$RENDER"
rm -f "$RENDER"/*.yml
helm template kanae "$CHART" --namespace "$NAMESPACE" --values "$VALUES" \
	| yq --no-doc 'select(.kind != null and .kind != "Secret")' \
		-s "\"$RENDER/\(.kind | downcase)-\(.metadata.name).yml\""

log "applying $RENDER"
WAIT=$WAIT deploy/kubernetes/scripts/apply-local.sh

log "what is running"
kubectl -n "$NAMESPACE" get all
