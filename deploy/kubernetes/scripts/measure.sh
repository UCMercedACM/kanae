#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=kanae

abort() {
	printf 'measure: %s\n' "$*" >&2
	exit 1
}

usage() {
	printf 'usage: %s [--namespace NAME] [--help]\n\n' "${0##*/}"
	printf '  --namespace NAME  namespace to read, default %s\n' "$NAMESPACE"
	printf '  --help            show this help\n'
}

while [[ $# -gt 0 ]]; do
	case $1 in
		--namespace)
			[[ $# -ge 2 ]] || abort "--namespace needs a value"
			NAMESPACE=$2
			shift 2
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

now=$(date -u +%s)

read_cgroup() {
	local pod=$1 container=$2
	kubectl exec "$pod" --container "$container" --namespace "$NAMESPACE" -- \
		cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.stat 2>/dev/null
}

printf '%-26s %-16s %10s %10s %7s %8s\n' POD CONTAINER 'PEAK (Mi)' 'LIMIT (Mi)' 'OF LIMIT' 'CPU (m)'

for pod in $(kubectl get pods --namespace "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
	while read -r container started; do
		[[ -n $started ]] || continue

		if ! mapfile -t lines < <(read_cgroup "$pod" "$container") || ((${#lines[@]} < 3)); then
			printf '%-26s %-16s %10s %10s %7s %8s\n' "$pod" "$container" '?' '?' '?' '?'
			continue
		fi

		peak=$((lines[0] / 1024 / 1024))
		limit='-' share='-'
		if [[ ${lines[1]} != max ]]; then
			limit=$((lines[1] / 1024 / 1024))
			share=$((lines[0] * 100 / lines[1]))%
		fi

		elapsed=$((now - $(date -u -d "$started" +%s)))
		cpu=0
		((elapsed > 0)) && cpu=$((${lines[2]#usage_usec } / 1000 / elapsed))

		printf '%-26s %-16s %10d %10s %7s %8d\n' "$pod" "$container" "$peak" "$limit" "$share" "$cpu"
	done < <(kubectl get pod "$pod" --namespace "$NAMESPACE" \
		-o jsonpath='{range .status.containerStatuses[*]}{.name} {.state.running.startedAt}{"\n"}{end}')
done
