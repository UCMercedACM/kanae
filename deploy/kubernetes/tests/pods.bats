#!/usr/bin/env bats
#
# No container in the namespace has restarted and no pod has failed.
# Read-only.
#
# A pod that crashes and comes back between two requests is invisible to hurl.
# 17_sequential_argon2_load.hurl leaves the Kratos restart count to be checked
# outside it, and an OOM kill under argon2 load is how the first e2e run found
# Kratos's memory limit too low.
#
# The counts live only as long as the pods, and pvc.bats recreates every pod.
# Run after hurl and before pvc.bats, this file reports on hurl's load; bats's
# name order does that for `bats deploy/kubernetes/tests/`. Run after pvc.bats,
# it passes on fresh pods and says nothing about hurl. credentials.bats sorts
# first and replaces kanae's pod, so in a directory run the kanae count covers
# only that file's restore; Kratos, Keto, Valkey and Postgres keep hurl's.

bats_require_minimum_version 1.5.0

NAMESPACE=kanae
CONTEXT=k3d-kanae

setup_file() {
	[[ $(kubectl config current-context) == "$CONTEXT" ]] || {
		echo "kubectl is not pointed at $CONTEXT; refusing to touch another cluster" >&2
		return 1
	}
	kubectl -n "$NAMESPACE" get deployment kanae >/dev/null 2>&1 || {
		echo "the kanae stack is not up; run deploy/kubernetes/tests/init.sh first" >&2
		return 1
	}
}

@test "no container in the namespace has restarted" {
	local pods restarted
	pods=$(kubectl -n "$NAMESPACE" get pods -o json)

	restarted=$(jq -r '
		.items[]
		| select(.metadata.deletionTimestamp == null)
		| .metadata.name as $pod
		| (.status.initContainerStatuses // []) + (.status.containerStatuses // [])
		| .[]
		| select(.restartCount > 0)
		| "\($pod)/\(.name): \(.restartCount) restarts, last \(.lastState.terminated.reason // "unknown")"
	' <<<"$pods")
	echo "$restarted"

	[[ -z $restarted ]]
}

@test "no pod in the namespace has failed" {
	local pods failed
	pods=$(kubectl -n "$NAMESPACE" get pods -o json)

	failed=$(jq -r '
		.items[]
		| select(.status.phase == "Failed")
		| "\(.metadata.name): \(.status.reason // .status.containerStatuses[0].state.terminated.reason // "unknown")"
	' <<<"$pods")
	echo "$failed"

	[[ -z $failed ]]
}
