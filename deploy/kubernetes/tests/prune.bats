#!/usr/bin/env bats
#
# kapp prunes a resource that is gone from the render. Mutates the stack, then
# restores it before asserting.
#
# "Remove a resource from the chart and re-apply" is a copy of .k8s-local
# without one file, handed to apply-local.sh through RENDER. kapp sees what it
# would see if the template were gone, and neither the chart nor .k8s-local is
# touched, so an interrupted run leaves nothing to put back in the checkout.
#
# The target is the postgres-checksum CronJob. Nothing else depends on it, so
# the stack keeps working while it is gone.
#
# apply-local.sh renders the Secrets through deploy/kubernetes/init.sh --local,
# which reuses secrets.local.yml. setup_file refuses to run unless that file
# still matches the live Secrets, since Postgres only knows those passwords.

bats_require_minimum_version 1.5.0

NAMESPACE=kanae
CONTEXT=k3d-kanae
ROOT_DIR=${BATS_TEST_DIRNAME%/deploy/kubernetes/tests}
LOCAL_VALUES=$ROOT_DIR/deploy/kubernetes/secrets.local.yml

setup_file() {
	[[ $(kubectl config current-context) == "$CONTEXT" ]] || {
		echo "kubectl is not pointed at $CONTEXT; refusing to touch another cluster" >&2
		return 1
	}
	kubectl -n "$NAMESPACE" get deployment kanae >/dev/null 2>&1 || {
		echo "the kanae stack is not up; run deploy/kubernetes/tests/init.sh first" >&2
		return 1
	}
	[[ -s $LOCAL_VALUES ]] || {
		echo "$LOCAL_VALUES is missing; run deploy/kubernetes/tests/init.sh first" >&2
		return 1
	}
	local live
	live=$(kubectl -n "$NAMESPACE" get secret kanae-db -o jsonpath='{.data.KANAE_PASSWORD}' | base64 -d)
	[[ $live == "$(yq '.secrets.kanaePassword' "$LOCAL_VALUES")" ]] || {
		echo "$LOCAL_VALUES does not match the live Secrets; a re-apply would render passwords Postgres does not have" >&2
		return 1
	}
}

setup() {
	cd "$ROOT_DIR" || return 1
}

@test "kapp deletes a resource dropped from the render" {
	local render=$BATS_TEST_TMPDIR/render pruned gone absent

	run -0 kubectl -n "$NAMESPACE" get cronjob postgres-checksum
	cp -R .k8s-local "$render"
	rm "$render/cronjob-postgres-checksum.yml"

	run env RENDER="$render" deploy/kubernetes/scripts/apply-local.sh
	pruned=$status

	run kubectl -n "$NAMESPACE" get cronjob postgres-checksum
	gone=$status
	absent=$output

	run -0 deploy/kubernetes/scripts/apply-local.sh

	[[ $pruned -eq 0 ]]
	[[ $gone -ne 0 ]]
	[[ $absent == *NotFound* ]]
	run -0 kubectl -n "$NAMESPACE" get cronjob postgres-checksum
}
