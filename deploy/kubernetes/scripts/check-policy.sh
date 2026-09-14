#!/usr/bin/env bash
set -euo pipefail

TEMPLATES=deploy/kubernetes/src/templates
FILES=deploy/kubernetes/src/files
ACL=docker/valkey/users.acl
INIT=deploy/docker/init.sh

reject() {
	local message=$1
	echo "check-policy: $message" >&2
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

grep -Fq resetpass "$ACL" || reject "$ACL no longer holds the resetpass token, so the substitution finds nothing to replace and kanae ships with no password"
grep -Fq resetpass "$TEMPLATES/secrets.yml" || reject "secrets.yml no longer substitutes the resetpass token, so kanae ships with no password"
grep -Fq resetpass "$INIT" || reject "$INIT no longer substitutes the resetpass token, so the compose stack ships with no password"

kube-linter lint --config .kube-linter.yml deploy/kubernetes/dist .k8s-local
