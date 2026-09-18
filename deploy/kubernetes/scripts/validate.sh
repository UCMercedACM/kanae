#!/usr/bin/env bash

set -euo pipefail

CRD_CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

kubeconform -strict -summary \
	-schema-location default \
	-schema-location "$CRD_CATALOG" \
	-ignore-filename-pattern 'kubernetes/src/' \
	-ignore-filename-pattern 'k3d\.yml$' \
	-ignore-filename-pattern 'helmfile\.ya?ml$' \
	-ignore-filename-pattern 'values.*\.(ya?ml|json)$' \
	-ignore-filename-pattern 'secrets.*\.ya?ml$' \
	deploy/kubernetes
