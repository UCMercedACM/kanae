#!/usr/bin/env bats
#
# The negative test: a wrong app database password fails kanae's rollout, and
# kanae's logs carry Postgres's authentication error. Breaks kanae, then
# restores it before asserting.
#
# Poisons kanaePassword, which _helpers.tpl:14 puts in the app's DSN.
# dbPassword is the Postgres superuser's: it is read once at initdb and nulled
# at the end of it, so poisoning it deploys green.
#
# The DSN reaches the pod through the kanae-config Secret, mounted by subPath
# and read at startup, and the pod template's checksum covers
# kanae.config.public only (kanae.yml:55). A Secret change alone does not roll
# the pod, so the test restarts it, on both the poisoned and the restored
# Secret.

bats_require_minimum_version 1.5.0

NAMESPACE=kanae
APP=kanae-local
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

@test "a wrong app database password fails kanae's rollout with Postgres's error" {
	local poisoned deployed restarted rolled logs

	poisoned=$(deploy/kubernetes/init.sh --local \
		| helm template kanae deploy/kubernetes/src --namespace "$NAMESPACE" \
			--values deploy/kubernetes/values.local.yml --values - \
			--set renderSecrets=true --set secrets.kanaePassword=not-the-kanae-password \
			--show-only templates/secrets.yml)
	[[ $poisoned == *not-the-kanae-password* ]]

	# --wait=false: kapp would otherwise wait on a kanae rollout onto the poisoned Secret.
	run kapp deploy --yes -a "$APP" -n "$NAMESPACE" -c \
		-f .k8s-local -f <(printf '%s\n' "$poisoned") --wait=false
	deployed=$status

	run kubectl -n "$NAMESPACE" rollout restart deployment/kanae
	restarted=$status

	# Not `wait Available`: with maxUnavailable 1 it stays True with no pod ready.
	run kubectl -n "$NAMESPACE" rollout status deployment/kanae --timeout=120s
	rolled=$status

	logs=$(kubectl -n "$NAMESPACE" logs -l app=kanae --tail=-1 2>&1 || true)
	logs+=$(kubectl -n "$NAMESPACE" logs -l app=kanae --tail=-1 --previous 2>&1 || true)

	run -0 env WAIT=false deploy/kubernetes/scripts/apply-local.sh
	run -0 kubectl -n "$NAMESPACE" rollout restart deployment/kanae
	run -0 kubectl -n "$NAMESPACE" rollout status deployment/kanae --timeout=300s

	echo "$logs"
	[[ $deployed -eq 0 ]]
	[[ $restarted -eq 0 ]]
	[[ $rolled -ne 0 ]]
	[[ $logs == *'password authentication failed for user "kanae"'* ]]
}
