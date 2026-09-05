#!/usr/bin/env bash
set -euo pipefail

FILES=deploy/kubernetes/src/files
MAP=deploy/kubernetes/files.map
WORKFLOW=.github/workflows/kubernetes.yml

failed=0
fail() {
	echo "check-symlinks: $*" >&2
	failed=1
}

mapfile -t PATTERNS < <(
	yq '.jobs.Changes.steps[] | select(.id == "filter") | .with.filters | from_yaml | .kubernetes[]' "$WORKFLOW"
)

LINKS=() SOURCES=()
while IFS='|' read -r link source; do
	[[ ! $link =~ ^[[:space:]]*(#|$) ]] || continue
	LINKS+=("$FILES/$link")
	SOURCES+=("$source")
done <"$MAP"

symlinks=()
for path in "${LINKS[@]}"; do
	[[ -L $path ]] && symlinks+=("$path")
done

declare -A TARGET=()
if ((${#symlinks[@]})); then
	mapfile -t targets < <(readlink "${symlinks[@]}")
	for i in "${!symlinks[@]}"; do TARGET[${symlinks[i]}]=${targets[i]}; done
fi

for i in "${!LINKS[@]}"; do
	path=${LINKS[i]}
	source=${SOURCES[i]}

	dir=${path%/*}
	slashes=${dir//[!\/]/}
	expected=../${slashes//\//..\/}$source

	[[ -e $source ]] || fail "$source does not exist, so $path has nothing to point at"

	if [[ -f $path && ! -L $path ]]; then
		fail "$path is a plain file. This checkout has no symlink support: run 'git config core.symlinks true' and check out again, or clone with 'git clone -c core.symlinks=true'"
		continue
	fi
	if [[ ! -L $path ]]; then
		fail "$path is not a symlink"
		continue
	fi

	target=${TARGET[$path]}
	[[ $target != /* ]] || fail "$path has an absolute target: $target"
	[[ $target == "$expected" ]] || fail "$path points at $target, expected $expected"
	[[ -e $path ]] || fail "$path does not resolve"

	covered=false
	for pattern in "${PATTERNS[@]}"; do
		# The filter entries are globs, so this comparison has to glob too.
		# shellcheck disable=SC2053
		if [[ $source == $pattern ]]; then
			covered=true
			break
		fi
	done
	[[ $covered == true ]] || fail "$source matches no pattern in the kubernetes filter of $WORKFLOW, so a change to it would run no CI"
done

exit $failed
