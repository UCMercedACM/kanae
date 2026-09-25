#!/usr/bin/env bats
#
# The NetworkPolicies refuse what they should. Read-only: the probes are
# throwaway pods that delete themselves.
#
# hurl only sees the allow side. Every request it makes enters through the
# Gateway, and every hop behind that is one a policy admits, so the deny side
# has to be probed from inside the cluster.
#
# The probes run from two places. The first is envoy-gateway-system, the only
# namespace any policy admits. From there kanae:8000 and kratos:4433 must
# open, which proves the probe reaches the namespace at all, and every other
# port must not. The second is an unlabelled pod in kanae, which only
# default-deny and allow-dns select. It must get DNS and nothing else.
#
# Each port is dialled once with bash's /dev/tcp and a 3s timeout. A drop and
# a refusal both read as closed. The probe image is the chart's own Postgres
# image, which is already on the node, so nothing is pulled from outside.

bats_require_minimum_version 1.5.0

NAMESPACE=kanae
CONTEXT=k3d-kanae
GATEWAY_NAMESPACE=envoy-gateway-system

# shellcheck disable=SC2016 # expanded by the pod's bash, not this one
PROBE='for target in "$@"; do
	if timeout 3 bash -c ": </dev/tcp/${target%:*}/${target##*:}" 2>/dev/null; then
		echo "$target open"
	else
		echo "$target closed"
	fi
done'

setup_file() {
	[[ $(kubectl config current-context) == "$CONTEXT" ]] || {
		echo "kubectl is not pointed at $CONTEXT; refusing to touch another cluster" >&2
		return 1
	}
	kubectl -n "$NAMESPACE" get deployment kanae >/dev/null 2>&1 || {
		echo "the kanae stack is not up; run deploy/kubernetes/tests/init.sh first" >&2
		return 1
	}

	local image
	image=$(kubectl -n "$NAMESPACE" get statefulset database \
		-o jsonpath='{.spec.template.spec.containers[?(@.name=="postgres")].image}')

	kubectl -n "$GATEWAY_NAMESPACE" run "netpol-probe-$RANDOM" \
		--rm --attach --quiet --restart=Never \
		--image="$image" --image-pull-policy=IfNotPresent \
		--command -- bash -c "$PROBE" probe \
		kanae.kanae:8000 kratos.kanae:4433 kratos.kanae:4434 \
		keto.kanae:4466 keto.kanae:4467 valkey.kanae:6379 database.kanae:5432 \
		>"$BATS_FILE_TMPDIR/from-gateway"

	kubectl -n "$NAMESPACE" run "netpol-probe-$RANDOM" \
		--rm --attach --quiet --restart=Never \
		--image="$image" --image-pull-policy=IfNotPresent \
		--command -- bash -c "$PROBE" probe \
		kube-dns.kube-system:53 kanae:8000 kratos:4433 keto:4466 database:5432 \
		>"$BATS_FILE_TMPDIR/from-unlabelled"
}

@test "the Gateway's namespace reaches kanae and Kratos's public port" {
	local probe
	probe=$(<"$BATS_FILE_TMPDIR/from-gateway")
	echo "$probe"

	[[ $probe == *"kanae.kanae:8000 open"* ]]
	[[ $probe == *"kratos.kanae:4433 open"* ]]
}

@test "the Gateway's namespace cannot reach Kratos's admin API" {
	local probe
	probe=$(<"$BATS_FILE_TMPDIR/from-gateway")
	echo "$probe"

	[[ $probe == *"kanae.kanae:8000 open"* ]]
	[[ $probe == *"kratos.kanae:4434 closed"* ]]
}

@test "the Gateway's namespace cannot reach Keto's read API" {
	local probe
	probe=$(<"$BATS_FILE_TMPDIR/from-gateway")
	echo "$probe"

	[[ $probe == *"kanae.kanae:8000 open"* ]]
	[[ $probe == *"keto.kanae:4466 closed"* ]]
}

@test "the Gateway's namespace cannot reach Keto's write API" {
	local probe
	probe=$(<"$BATS_FILE_TMPDIR/from-gateway")
	echo "$probe"

	[[ $probe == *"kanae.kanae:8000 open"* ]]
	[[ $probe == *"keto.kanae:4467 closed"* ]]
}

@test "the Gateway's namespace cannot reach Valkey" {
	local probe
	probe=$(<"$BATS_FILE_TMPDIR/from-gateway")
	echo "$probe"

	[[ $probe == *"kanae.kanae:8000 open"* ]]
	[[ $probe == *"valkey.kanae:6379 closed"* ]]
}

@test "the Gateway's namespace cannot reach Postgres" {
	local probe
	probe=$(<"$BATS_FILE_TMPDIR/from-gateway")
	echo "$probe"

	[[ $probe == *"kanae.kanae:8000 open"* ]]
	[[ $probe == *"database.kanae:5432 closed"* ]]
}

@test "a pod no policy names gets DNS and nothing else" {
	local probe
	probe=$(<"$BATS_FILE_TMPDIR/from-unlabelled")
	echo "$probe"

	[[ $probe == *"kube-dns.kube-system:53 open"* ]]
	[[ $probe == *"kanae:8000 closed"* ]]
	[[ $probe == *"kratos:4433 closed"* ]]
	[[ $probe == *"keto:4466 closed"* ]]
	[[ $probe == *"database:5432 closed"* ]]
}
