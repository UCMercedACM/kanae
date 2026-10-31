#!/usr/bin/env bats
#
# The backups end to end: the nightly CronJob, the snapshot ahead of a
# migration, and scripts/restore.sh putting the databases back, against a
# Borg repository reached over SSH the way production reaches BorgBase.
#
# k3d has no BorgBase, so this starts one: tests/borg-server/ is sshd in front
# of the same borg the backup pods run, with the cluster's key in its
# authorized_keys and a host key generated here. Nothing about the backup pods
# is bent for it. They get their repository URL, host key and SSH key from
# the kanae-borg Secret as in production; only the values differ, and one
# test-only NetworkPolicy lets them reach the stand-in, which the chart's policy
# would not, since it is not a public address.
#
# The usual local render leaves the backup workloads out, so this renders the
# whole stack again with them in, and deploys it as kanae-local with the
# Secrets pointed at the stand-in. teardown_file deploys the usual render back.
#
# The tests run in order and build on each other: each one leaves the
# archives the next one restores from. It replaces the live databases, so run
# it against a throwaway k3d stack only.

bats_require_minimum_version 1.5.0

NAMESPACE=kanae
CONTEXT=k3d-kanae
CHART=deploy/kubernetes/src
VALUES=deploy/kubernetes/values.local.yml
ROOT_DIR=${BATS_TEST_DIRNAME%/deploy/kubernetes/tests}
SERVER=borg-server.kanae.svc.cluster.local

pg() { kubectl -n "$NAMESPACE" exec statefulset/database -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 -tAq "$@"; }

# The stand-in's own borg, so nothing on this machine needs one.
server_borg() {
	kubectl -n "$NAMESPACE" exec borg-server -- su borg -s /bin/sh -c \
		"BORG_PASSPHRASE='$(yq -r '.secrets.borgPassphrase' "$BATS_FILE_TMPDIR/secrets.yml")' borg $*"
}
archives() { server_borg list --short /home/borg/repo; }

backup_now() {
	local job=restore-bats-$RANDOM
	kubectl -n "$NAMESPACE" create job --from=cronjob/kanae-backup "$job" >/dev/null
	kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$job" --timeout=600s >/dev/null
}

# Renders the whole local stack, then deploys it with the Secrets in
# $BATS_FILE_TMPDIR/secrets.yml. $1 is the yq select for the manifests.
deploy() {
	rm -rf "$BATS_FILE_TMPDIR/render"
	mkdir "$BATS_FILE_TMPDIR/render"
	helm template kanae "$CHART" --namespace "$NAMESPACE" --values "$VALUES" \
		| yq --no-doc "select($1)" -s "\"$BATS_FILE_TMPDIR/render/\(.kind | downcase)-\(.metadata.name).yml\""
	kapp deploy --yes -a kanae-local -n "$NAMESPACE" -f "$BATS_FILE_TMPDIR/render" \
		-f <(helm template kanae "$CHART" --namespace "$NAMESPACE" --values "$VALUES" \
			--values "$BATS_FILE_TMPDIR/secrets.yml" --set renderSecrets=true --show-only templates/secrets.yml) \
		>"$BATS_FILE_TMPDIR/kapp.log" 2>&1
}

setup_file() {
	[[ $(kubectl config current-context) == "$CONTEXT" ]] || {
		echo "kubectl is not pointed at $CONTEXT; refusing to touch another cluster" >&2
		return 1
	}
	kubectl -n "$NAMESPACE" get deployment kanae >/dev/null 2>&1 || {
		echo "the kanae stack is not up; run deploy/kubernetes/tests/init.sh first" >&2
		return 1
	}
	cd "$ROOT_DIR" || return 1

	docker build -q -t kanae-borg-server:test deploy/kubernetes/tests/borg-server >/dev/null
	k3d image import -c kanae kanae-borg-server:test >/dev/null 2>&1

	deploy/kubernetes/init.sh --local >"$BATS_FILE_TMPDIR/secrets.yml"
	yq -r '.secrets.borgSshKey' "$BATS_FILE_TMPDIR/secrets.yml" >"$BATS_FILE_TMPDIR/client_key"
	chmod 600 "$BATS_FILE_TMPDIR/client_key"
	ssh-keygen -q -t ed25519 -N '' -C borg-server -f "$BATS_FILE_TMPDIR/host_key"

	kubectl -n "$NAMESPACE" create secret generic borg-server \
		--from-file=ssh_host_ed25519_key="$BATS_FILE_TMPDIR/host_key" \
		--from-literal=authorized_keys="command=\"borg serve --restrict-to-repository /home/borg/repo\",restrict $(ssh-keygen -y -f "$BATS_FILE_TMPDIR/client_key")" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null
	kubectl apply -f deploy/kubernetes/tests/borg-server/borg-server.yml >/dev/null
	kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/borg-server --timeout=180s >/dev/null
	server_borg init --encryption repokey-blake2 /home/borg/repo

	REPO="ssh://borg@$SERVER/./repo" KNOWN="$SERVER $(cut -d' ' -f1,2 "$BATS_FILE_TMPDIR/host_key.pub")" \
		yq -i '.secrets.borgRepo = strenv(REPO) | .secrets.borgKnownHosts = strenv(KNOWN)' "$BATS_FILE_TMPDIR/secrets.yml"

	# The first deploy with the backups in creates kanae-snapshot, so the
	# repository has to exist before it.
	deploy '.kind != null and .kind != "Secret"'
}

teardown_file() {
	cd "$ROOT_DIR" || return 1
	pg -d postgres -c "SELECT datname FROM pg_database WHERE datname LIKE '%\_before\_restore\_%' OR datname LIKE 'restore\_%'" \
		| while read -r db; do pg -d postgres -c "DROP DATABASE $db WITH (FORCE)"; done
	pg -d kanae -c "DELETE FROM tags WHERE title = 'restore-bats'"
	deploy/kubernetes/init.sh --local >"$BATS_FILE_TMPDIR/secrets.yml"
	deploy '.kind != null and .kind != "Secret" and .metadata.name != "kanae-snapshot" and (.kind != "CronJob" or .metadata.name != "kanae-backup")'
	kubectl delete -f deploy/kubernetes/tests/borg-server/borg-server.yml --ignore-not-found >/dev/null
	kubectl -n "$NAMESPACE" delete secret borg-server --ignore-not-found >/dev/null
}

@test "the first deploy with the backups in took a snapshot" {
	run -0 archives
	echo "$output"

	[[ $output == *kanae-db-snapshot-* ]]
}

@test "the snapshot runs before the migrations it guards" {
	# kapp re-creates a versioned Job that is gone, in its change-group order,
	# which is what a new migration looks like to it.
	kubectl -n "$NAMESPACE" delete jobs -l 'app.kubernetes.io/component=snapshot' >/dev/null
	kubectl -n "$NAMESPACE" delete jobs -l 'app in (kanae-migrate, kratos-migrate, keto-migrate)' >/dev/null
	cd "$ROOT_DIR"
	deploy '.kind != null and .kind != "Secret"'

	local snapshot migrate
	snapshot=$(kubectl -n "$NAMESPACE" get jobs -l 'app.kubernetes.io/component=snapshot' -o jsonpath='{.items[0].status.completionTime}')
	migrate=$(kubectl -n "$NAMESPACE" get jobs -l app=kanae-migrate -o jsonpath='{.items[0].status.startTime}')
	echo "snapshot completed $snapshot, kanae-migrate started $migrate"

	[[ -n $snapshot && -n $migrate ]]
	[[ ! $migrate < $snapshot ]]
	[[ $(archives | grep -c '^kanae-db-snapshot-') -ge 2 ]]
}

@test "the nightly backup archives all three databases" {
	backup_now

	local archive
	archive=$(archives | grep -v -e '^kanae-db-snapshot-' -e '^kanae-db-pre-restore-' | tail -n 1)
	[[ -n $archive ]]

	run -0 server_borg list --format '{path}{NL}' "/home/borg/repo::$archive"
	echo "$output"

	[[ $output == *postgresql_databases/database/kanae* ]]
	[[ $output == *postgresql_databases/database/kratos* ]]
	[[ $output == *postgresql_databases/database/keto* ]]
}

@test "restore.sh refuses to start while a backup is running" {
	local job=restore-bats-$RANDOM
	kubectl -n "$NAMESPACE" create job --from=cronjob/kanae-backup "$job" >/dev/null

	cd "$ROOT_DIR"
	run deploy/kubernetes/scripts/restore.sh --yes
	kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$job" --timeout=600s >/dev/null
	echo "$output"

	[[ $status -ne 0 ]]
	[[ $output == *"a backup or snapshot is running"* ]]
}

@test "restore.sh brings back a dropped table from the newest backup" {
	pg -d kanae -c "DELETE FROM tags WHERE title = 'restore-bats'" \
		-c "INSERT INTO tags (title, description) VALUES ('restore-bats', 'kept by the backup')"
	backup_now
	pg -d kanae -c "DROP TABLE tags CASCADE"

	cd "$ROOT_DIR"
	run -0 deploy/kubernetes/scripts/restore.sh --yes
	echo "$output"

	[[ $(pg -d kanae -c "SELECT description FROM tags WHERE title = 'restore-bats'") == "kept by the backup" ]]
	[[ $(archives) == *kanae-db-pre-restore-* ]]
	[[ -n $(pg -d postgres -c "SELECT 1 FROM pg_database WHERE datname LIKE 'kanae\_before\_restore\_%'") ]]
	[[ $(kubectl -n "$NAMESPACE" get deployment kanae kratos keto -o jsonpath='{.items[*].spec.replicas}') == "1 1 1" ]]
	[[ $(kubectl -n "$NAMESPACE" get cronjob kanae-backup -o jsonpath='{.spec.suspend}') == false ]]
}

@test "a second restore.sh run skips its own pre-restore archive" {
	local expected
	expected=$(archives | grep -v '^kanae-db-pre-restore-' | tail -n 1)

	cd "$ROOT_DIR"
	run -0 deploy/kubernetes/scripts/restore.sh --yes
	echo "$output"

	[[ $output == *"restoring from $expected"* ]]
	[[ $(pg -d kanae -c "SELECT description FROM tags WHERE title = 'restore-bats'") == "kept by the backup" ]]
}

@test "restore.sh --check finds every table's row count in the newest backup" {
	backup_now

	cd "$ROOT_DIR"
	run -0 deploy/kubernetes/scripts/restore.sh --check
	echo "$output"

	[[ $output == *"kanae: the live database matches the backup"* ]]
	[[ $output == *"kratos: the live database matches the backup"* ]]
	[[ $output == *"keto: the live database matches the backup"* ]]
}
