#!/usr/bin/env bats
#
# The Valkey ACL. Read-only: every command is a GET of a key that does not
# exist, or one the ACL refuses before it runs.
#
# users.acl is rendered into the valkey-acl Secret with kanae's `resetpass`
# replaced by the generated password. hurl 07 proves kanae can use the cache,
# which is the positive half. The negative half is only visible from inside
# the pod: the Valkey NetworkPolicy admits kanae alone, so nothing outside
# can ask what the `default` user is allowed, or whether kanae is confined to
# its key patterns and its command list.
#
# valkey-cli exits 0 on an error reply, so every check reads the reply text.
# The kanae password goes in through REDISCLI_AUTH rather than valkey-cli's -a,
# which keeps it out of valkey-cli's arguments only: it is still on the
# kubectl exec and env command lines.

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
}

@test "the unauthenticated default user can ping and nothing more" {
	run -0 kubectl -n "$NAMESPACE" exec deployment/valkey -- valkey-cli PING
	[[ "$output" = PONG ]]

	run -0 kubectl -n "$NAMESPACE" exec deployment/valkey -- \
		valkey-cli GET ory:whoami:netpol-probe
	[[ $output == *NOPERM* ]]
}

@test "kanae authenticates with the rendered password and reads its own key space" {
	local password
	password=$(yq '.secrets.valkeyPassword' "$LOCAL_VALUES")
	[[ -n "$password" ]]

	run -0 kubectl -n "$NAMESPACE" exec deployment/valkey -- \
		env REDISCLI_AUTH="$password" valkey-cli --user kanae GET ory:whoami:netpol-probe
	[[ $output != *WRONGPASS* ]]
	[[ $output != *NOPERM* ]]
}

@test "kanae cannot read outside its key patterns" {
	local password
	password=$(yq '.secrets.valkeyPassword' "$LOCAL_VALUES")
	[[ -n "$password" ]]

	run -0 kubectl -n "$NAMESPACE" exec deployment/valkey -- \
		env REDISCLI_AUTH="$password" valkey-cli --user kanae GET somebody-elses-key
	[[ $output == *NOPERM* ]]
}

@test "kanae cannot administer the server" {
	local password
	password=$(yq '.secrets.valkeyPassword' "$LOCAL_VALUES")
	[[ -n "$password" ]]

	run -0 kubectl -n "$NAMESPACE" exec deployment/valkey -- \
		env REDISCLI_AUTH="$password" valkey-cli --user kanae CONFIG GET maxmemory
	[[ $output == *NOPERM* ]]
}
