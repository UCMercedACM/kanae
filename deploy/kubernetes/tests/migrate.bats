#!/usr/bin/env bats
#
# The migrate Jobs and the role split they enforce. Read-only: the one DDL
# statement it sends is meant to be refused, and is dropped if it is not.
#
# kapp orders the three Jobs after the databases and waits for them, so a
# failed Job fails init.sh and hurl never runs. What hurl cannot see is
# whether they needed a retry (backoffLimit 3 hides a first attempt that
# raced Postgres, which is the ordering the change-rules exist to prevent),
# and which role made the schema. The schema is owned by the *_migrate roles
# and the app roles get DML through the owner's default privileges; a Job
# rewired to run as the app role would pass every hurl file and leave the
# app able to alter its own tables.
#
# Jobs are found by label because kapp versions their names. psql goes over
# the pod's unix socket, which pg_hba.conf trusts. The exec names the postgres
# container: without it kubectl prints which one it defaulted to past the
# check-version init container, and that line lands in $output.

bats_require_minimum_version 1.5.0

NAMESPACE=kanae
CONTEXT=k3d-kanae

setup_file() {
	[[ $(kubectl config current-context) == "$CONTEXT" ]] || {
		echo "kubectl is not pointed at $CONTEXT; refusing to touch another cluster" >&2
		return 1
	}
	kubectl -n "$NAMESPACE" get deployment kanae >/dev/null 2>&1 || {
		echo "the kanae stack is not up; run deploy/kubernetes/tests/init.sh first" >&2
		return 1
	}
}

@test "kanae-migrate completed on its first attempt" {
	run -0 kubectl -n "$NAMESPACE" get jobs -l app=kanae-migrate \
		-o jsonpath='{.items[*].status.succeeded}'
	[[ $output =~ ^1(\ 1)*$ ]]

	run -0 kubectl -n "$NAMESPACE" get jobs -l app=kanae-migrate \
		-o jsonpath='{.items[*].status.failed}'
	[[ -z "$output" ]]
}

@test "kratos-migrate completed on its first attempt" {
	run -0 kubectl -n "$NAMESPACE" get jobs -l app=kratos-migrate \
		-o jsonpath='{.items[*].status.succeeded}'
	[[ $output =~ ^1(\ 1)*$ ]]

	run -0 kubectl -n "$NAMESPACE" get jobs -l app=kratos-migrate \
		-o jsonpath='{.items[*].status.failed}'
	[[ -z "$output" ]]
}

@test "keto-migrate completed on its first attempt" {
	run -0 kubectl -n "$NAMESPACE" get jobs -l app=keto-migrate \
		-o jsonpath='{.items[*].status.succeeded}'
	[[ $output =~ ^1(\ 1)*$ ]]

	run -0 kubectl -n "$NAMESPACE" get jobs -l app=keto-migrate \
		-o jsonpath='{.items[*].status.failed}'
	[[ -z "$output" ]]
}

@test "every table in kanae is owned by kanae_migrate" {
	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -tAq -U kanae -d kanae -v ON_ERROR_STOP=1 -c \
		"SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname = 'public'"
	[[ "$output" = kanae_migrate ]]
}

@test "every table in kratos is owned by kratos_migrate" {
	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -tAq -U kratos -d kratos -v ON_ERROR_STOP=1 -c \
		"SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname = 'public'"
	[[ "$output" = kratos_migrate ]]
}

@test "every table in keto is owned by keto_migrate" {
	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -tAq -U keto -d keto -v ON_ERROR_STOP=1 -c \
		"SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname = 'public'"
	[[ "$output" = keto_migrate ]]
}

@test "the kanae role cannot create a table" {
	run kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U kanae -d kanae -v ON_ERROR_STOP=1 -c \
		'CREATE TABLE e2e_ddl_probe (id int)'
	local refused=$status refused_output=$output

	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U kanae -d kanae -v ON_ERROR_STOP=1 -c \
		'DROP TABLE IF EXISTS e2e_ddl_probe'

	[[ "$refused" -ne 0 ]]
	[[ $refused_output == *'permission denied for schema public'* ]]
}
