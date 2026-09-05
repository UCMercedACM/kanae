#!/usr/bin/env bash
set -euo pipefail

TEMPLATES=deploy/kubernetes/src/templates
FILES=deploy/kubernetes/src/files

reject() {
	echo "check-policy: $1" >&2
	exit 1
}

if grep -rnE 'database:5432|kanae:8000' "$TEMPLATES"; then
	reject "service address typed into a template"
fi

if find "$FILES" -type f -print | grep .; then
	reject "copy under $FILES, it should be a symlink"
fi

if find "$FILES" -type l ! -exec test -e {} \; -print | grep .; then
	reject "dangling link under $FILES, its source was renamed"
fi

if grep -rn 'Files.Get' "$TEMPLATES" --exclude=_helpers.tpl; then
	reject ".Files.Get outside _helpers.tpl, read the file through kanae.file"
fi

kube-linter lint --config .kube-linter.yml deploy/kubernetes/dist .k8s-local
