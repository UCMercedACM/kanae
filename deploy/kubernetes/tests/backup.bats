#!/usr/bin/env bats
#
# The backup role dumps what a backup needs and can read nothing else, and a
# dump of it restores into a scratch database with the same row counts.
# Read-only against the live databases; the only things it creates are
# restore_bats and the refused probe table, both dropped before it asserts.
#
# There is no Borg host in k3d, so this stops short of Borg: it runs the part
# a Borg archive carries, pg_dump as kanae_backup into pg_restore, over the
# database's unix socket (pg_hba trusts it, so the role's password is not what
# is under test; its grants are). The Borg half, against the real repository,
# is the exit gate and runs by hand: deploy/kubernetes/scripts/restore.sh --check.
#
# Needs a cluster initialised after the kanae_backup role existed. An older
# volume has no role; RUNBOOK.md has the statements for it.

bats_require_minimum_version 1.5.0

NAMESPACE=kanae
CONTEXT=k3d-kanae

COUNTS="SELECT table_name || ' ' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name"

setup_file() {
	[[ $(kubectl config current-context) == "$CONTEXT" ]] || {
		echo "kubectl is not pointed at $CONTEXT; refusing to touch another cluster" >&2
		return 1
	}
	kubectl -n "$NAMESPACE" get deployment kanae >/dev/null 2>&1 || {
		echo "the kanae stack is not up; run deploy/kubernetes/tests/init.sh first" >&2
		return 1
	}
	kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U postgres -d postgres -tAq -c "SELECT 1 FROM pg_roles WHERE rolname = 'kanae_backup'" | grep -q 1 || {
		echo "the database has no kanae_backup role; the volume predates it." >&2
		return 1
	}
}

@test "kanae_backup dumps kanae" {
	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		bash -c 'pg_dump -U kanae_backup -Fc kanae | pg_restore --list | grep -c "TABLE DATA"'
	echo "$output"

	[[ $output -gt 0 ]]
}

@test "kanae_backup dumps kratos" {
	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		bash -c 'pg_dump -U kanae_backup -Fc kratos | pg_restore --list | grep -c "TABLE DATA"'
	echo "$output"

	[[ $output -gt 0 ]]
}

@test "kanae_backup dumps keto" {
	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		bash -c 'pg_dump -U kanae_backup -Fc keto | pg_restore --list | grep -c "TABLE DATA"'
	echo "$output"

	[[ $output -gt 0 ]]
}

@test "kanae_backup cannot read the password hashes" {
	run -1 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U kanae_backup -d kanae -tAq -c 'SELECT rolpassword FROM pg_authid'
	echo "$output"

	[[ $output == *"permission denied for table pg_authid"* ]]
}

@test "kanae_backup authenticates over TCP with the password in its Secret" {
	local password
	password=$(kubectl -n "$NAMESPACE" get secret postgres-backup-db \
		-o jsonpath='{.data.POSTGRES_BACKUP_PASSWORD}' | base64 -d)
	[[ -n $password ]]

	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		env PGPASSWORD="$password" psql -h 127.0.0.1 -U kanae_backup -d kanae -tAq -c 'SELECT 1'
	[[ $output == 1 ]]
}

@test "kanae_backup cannot write a row" {
	run -1 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U kanae_backup -d kanae -tAq -v ON_ERROR_STOP=1 -c 'DELETE FROM members WHERE false'
	echo "$output"

	[[ $output == *"permission denied for table members"* ]]
}

@test "kanae_backup cannot create a table" {
	run kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U kanae_backup -d kanae -v ON_ERROR_STOP=1 -c 'CREATE TABLE bats_backup_probe (id int)'
	local refused=$status refused_output=$output

	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U postgres -d kanae -v ON_ERROR_STOP=1 -c 'DROP TABLE IF EXISTS bats_backup_probe'

	[[ $refused -ne 0 ]]
	[[ $refused_output == *"permission denied for schema public"* ]]
}

@test "kanae_backup cannot read other sessions' queries" {
	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U kanae_backup -d kanae -tAq -v ON_ERROR_STOP=1 -c \
		"SELECT count(*) FROM pg_stat_activity WHERE usename <> 'kanae_backup' AND query <> '<insufficient privilege>'"
	[[ $output == 0 ]]
}

@test "kanae_backup cannot reach the postgres database" {
	run -2 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U kanae_backup -d postgres -tAq -c 'SELECT 1'
	echo "$output"

	[[ $output == *"permission denied for database"* ]]
}

@test "a kanae dump restores with the same row counts" {
	local live restored

	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		bash -c 'psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS restore_bats" -c "CREATE DATABASE restore_bats" && pg_dump -U kanae_backup -Fc kanae | pg_restore -U postgres -d restore_bats --no-owner --no-acl --exit-on-error'
	live=$(kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U postgres -d kanae -tAq -c "$COUNTS")
	restored=$(kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U postgres -d restore_bats -tAq -c "$COUNTS")
	run -0 kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- \
		psql -U postgres -d postgres -c "DROP DATABASE restore_bats"

	echo "$live"
	[[ -n $live ]]
	[[ $live == "$restored" ]]
}
