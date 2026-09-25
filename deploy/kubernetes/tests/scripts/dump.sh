#!/usr/bin/env bash

set -uo pipefail

NAMESPACE=${NAMESPACE:-kanae}

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

log "pods in every namespace"
kubectl get pods -A -o wide

log "warning events in every namespace"
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp

log "gateway and TLS certificate"
kubectl -n "$NAMESPACE" describe gateway/kanae certificate/kanae-tls

# One line per container of each non-Ready pod: pod, container, started, restarted.
containers=$(kubectl -n "$NAMESPACE" get pods -o json | jq -r '
	.items[]
	| select(.status.phase != "Succeeded")
	| select(any(.status.conditions[]?; .type == "Ready" and .status != "True"))
	| .metadata.name as $pod
	| .status.initContainerStatuses[]?, .status.containerStatuses[]?
	| [$pod, .name, .state.waiting == null, .restartCount > 0]
	| @tsv')

for pod in $(cut -f1 <<<"$containers" | uniq); do
	log "description of $pod"
	kubectl -n "$NAMESPACE" describe pod "$pod"
done

while IFS=$'\t' read -r pod container started restarted; do
	if [[ $started == true ]]; then
		log "logs of $pod/$container"
		kubectl -n "$NAMESPACE" logs "$pod" -c "$container" --tail=200
	fi
	if [[ $restarted == true ]]; then
		log "logs of $pod/$container before its last restart"
		kubectl -n "$NAMESPACE" logs "$pod" -c "$container" --previous --tail=200
	fi
done <<<"$containers"
