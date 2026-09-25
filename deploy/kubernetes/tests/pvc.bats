#!/usr/bin/env bats
#
# The Postgres claim and the data on it survive kapp delete. Deletes the whole
# app, then re-applies it before asserting.
#
# persistentvolumeclaim-database-data and every Secret carry
# kapp.k14s.io/delete-strategy: orphan. This is the branch where being wrong
# costs the database: the claim has to outlive kapp delete, and the re-apply
# has to adopt the same claim and Secrets rather than create fresh ones.
#
# apply-local.sh renders the Secrets through deploy/kubernetes/init.sh --local,
# which reuses secrets.local.yml. Postgres comes back on the old volume and
# skips initdb, so setup_file refuses to run unless that file still matches
# the live Secrets.

bats_require_minimum_version 1.5.0

NAMESPACE=kanae
APP=kanae-local
CONTEXT=k3d-kanae
ROOT_DIR=${BATS_TEST_DIRNAME%/deploy/kubernetes/tests}
LOCAL_VALUES=$ROOT_DIR/deploy/kubernetes/secrets.local.yml

FINGERPRINT="SELECT count(*) || ' ' || md5(coalesce(string_agg(id::text, ',' ORDER BY id), '')) FROM members"

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

@test "the Postgres claim and its rows survive kapp delete" {
	local uid_before secret_before rows_before deleted sts_gone phase uid_after secret_after rows_after

	uid_before=$(kubectl -n "$NAMESPACE" get pvc database-data -o jsonpath='{.metadata.uid}')
	secret_before=$(kubectl -n "$NAMESPACE" get secret kanae-db -o jsonpath='{.metadata.uid}')
	rows_before=$(kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U kanae -d kanae -tAq -c "$FINGERPRINT")
	[[ -n $uid_before ]]
	[[ -n $secret_before ]]
	[[ ${rows_before%% *} -gt 0 ]]

	run kapp delete --yes -a "$APP" -n "$NAMESPACE"
	deleted=$status

	run kubectl -n "$NAMESPACE" get statefulset database
	sts_gone=$status
	phase=$(kubectl -n "$NAMESPACE" get pvc database-data -o jsonpath='{.status.phase}' 2>&1 || true)

	run -0 deploy/kubernetes/scripts/apply-local.sh
	run -0 kubectl -n "$NAMESPACE" wait certificate/kanae-tls --timeout=300s \
		--for=create --for=condition=Ready
	run -0 kubectl -n "$NAMESPACE" wait gateway/kanae --timeout=300s \
		--for=condition=Programmed

	uid_after=$(kubectl -n "$NAMESPACE" get pvc database-data -o jsonpath='{.metadata.uid}')
	secret_after=$(kubectl -n "$NAMESPACE" get secret kanae-db -o jsonpath='{.metadata.uid}')
	rows_after=$(kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U kanae -d kanae -tAq -c "$FINGERPRINT")

	[[ $deleted -eq 0 ]]
	[[ $sts_gone -ne 0 ]]
	[[ $phase = Bound ]]
	# The UID, not the name: a fresh claim with the same name has lost the data.
	[[ $uid_after = "$uid_before" ]]
	[[ $secret_after = "$secret_before" ]]
	[[ $rows_after = "$rows_before" ]]
}
