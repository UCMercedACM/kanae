#!/usr/bin/env bash

set -euo pipefail

NAMESPACE=${NAMESPACE:-kanae}
POD=kanae-restore
SERVICES=(kanae kratos keto)

COUNTS="SELECT table_name || ' ' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	BLUE=$'\033[1;34m' GREEN=$'\033[1;32m' RED=$'\033[1;31m' RESET=$'\033[0m'
else
	BLUE='' GREEN='' RED='' RESET=''
fi

log() { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*" >&2; }
abort() {
	printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
	exit 1
}

usage() {
	printf 'usage: %s [--archive NAME] [--database NAME] [--check] [--yes] [--help]\n\n' "${0##*/}"
	printf '  --archive   an archive name, or latest: the newest that is not a\n'
	printf '              pre-restore archive (default: latest)\n'
	printf '  --database  kanae, kratos or keto (default: all three)\n'
	printf '  --check     restore into restore_<database> beside the live one and\n'
	printf '              list the tables whose row counts differ, instead of\n'
	printf '              replacing it\n'
	printf '  --yes       do not ask before replacing the live databases\n'
	printf '  --help      show this help\n'
}

ARCHIVE=latest
DATABASES=(kanae kratos keto)
CHECK=
YES=
while [[ $# -gt 0 ]]; do
	case $1 in
		--archive)
			ARCHIVE=${2:?--archive needs a value}
			shift 2
			;;
		--database)
			DATABASES=("${2:?--database needs a value}")
			shift 2
			;;
		--check)
			CHECK=1
			shift
			;;
		--yes)
			YES=1
			shift
			;;
		--help)
			usage
			exit 0
			;;
		*)
			usage >&2
			abort "unknown option: $1"
			;;
	esac
done

REQUIRED=(kubectl yq)
[[ -n $YES && -z $CHECK ]] || REQUIRED+=(gum)
for cmd in "${REQUIRED[@]}"; do
	command -v "$cmd" >/dev/null || abort "$cmd is required"
done

kube() { kubectl -n "$NAMESPACE" "$@"; }
pg() { kube exec statefulset/database -c postgres -- env PGOPTIONS='-c client_min_messages=warning' psql -U postgres -v ON_ERROR_STOP=1 -tAq "$@"; }
pg_restore() { kube exec -i statefulset/database -c postgres -- pg_restore -U postgres --exit-on-error "$@"; }
borg() { kube exec -i "$POD" -c borgmatic -- borgmatic --verbosity -1 borg "$@"; }
dump() { borg extract --stdout "::$ARCHIVE" "${DUMP[$1]}"; }
suspend_backups() { kube patch cronjob kanae-backup -p "{\"spec\":{\"suspend\":$1}}" >/dev/null; }

REPLICAS=()
finish() {
	kube delete pod "$POD" --ignore-not-found >/dev/null
	((${#REPLICAS[@]})) || return 0
	log "scaling ${SERVICES[*]} back up and resuming the backup CronJob"
	for i in "${!SERVICES[@]}"; do
		kube scale deployment "${SERVICES[i]}" --replicas="${REPLICAS[i]}" >/dev/null
	done
	suspend_backups false
}
trap finish EXIT

running=$(kube get pods -l app=kanae-backup --field-selector=status.phase!=Succeeded,status.phase!=Failed -o name)
[[ -z $running ]] || abort "a backup or snapshot is running ($running); wait for it to finish, then run this again"

log "starting $POD from the kanae-backup CronJob's pod spec"
kube get cronjob kanae-backup -o yaml \
	| POD=$POD yq '{
		"apiVersion": "v1",
		"kind": "Pod",
		"metadata": {"name": strenv(POD), "namespace": .metadata.namespace, "labels": .spec.jobTemplate.spec.template.metadata.labels},
		"spec": .spec.jobTemplate.spec.template.spec
	} | .spec.containers[0].command = ["sleep"] | .spec.containers[0].args = ["3600"] | .spec.terminationGracePeriodSeconds = 0' \
	| kube apply -f - >/dev/null
kube wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null

if [[ $ARCHIVE == latest || -z $CHECK ]]; then
	archives=$(borg list --short --glob-archives 'kanae-db-*')
fi
if [[ $ARCHIVE == latest ]]; then
	ARCHIVE=$(grep -v '^kanae-db-pre-restore-' <<<"$archives" | tail -n 1 || true)
	[[ -n $ARCHIVE ]] || abort "the repository holds no kanae-db-* archive to restore"
fi

declare -A DUMP=()
paths=$(borg list --format '{path}{NL}' "::$ARCHIVE") || abort "$ARCHIVE is not in the repository"
for db in "${DATABASES[@]}"; do
	DUMP[$db]=$(grep -m1 "postgresql_databases/.*/$db\$" <<<"$paths") || abort "$ARCHIVE holds no dump of $db"
done

if [[ -n $CHECK ]]; then
	status=0
	for db in "${DATABASES[@]}"; do
		scratch=restore_$db
		log "$db: copying the backup from $ARCHIVE into the $scratch database to compare with the live $db database"
		pg -d postgres -c "DROP DATABASE IF EXISTS $scratch" -c "CREATE DATABASE $scratch"
		dump "$db" | pg_restore -d "$scratch" --no-owner --no-acl

		declare -A live=() backup=()
		while read -r table rows; do live[$table]=$rows; done < <(pg -d "$db" -c "$COUNTS")
		while read -r table rows; do backup[$table]=$rows; done < <(pg -d "$scratch" -c "$COUNTS")

		names=$(printf '%s\n' "${!live[@]}" "${!backup[@]}" | sort -u)
		tables=$(grep -c . <<<"$names" || true)
		report=()
		for table in $names; do
			if [[ ${live[$table]:-missing} != "${backup[$table]:-missing}" ]]; then
				report+=("$table"$'\t'"${live[$table]:-missing}"$'\t'"${backup[$table]:-missing}")
			fi
		done

		if ((${#report[@]} == 0)); then
			log "$db: the live database matches the backup: all tables and row counts match in both"
		else
			printf '%serror:%s %s: %d of %d tables in the live database do not match the backup:\n' "$RED" "$RESET" "$db" "${#report[@]}" "$tables" >&2
			printf '%s\n' "${report[@]}" \
				| gum table --print --separator $'\t' --columns 'table,rows now,rows in backup' >&2
			log "$db: the backup is kept in the $scratch database to look at by hand; drop it when done: DROP DATABASE $scratch;"
			status=1
		fi
	done
	exit "$status"
fi

log "the newest archives, oldest first:"
tail -n 5 <<<"$archives" | sed 's/^/    /' >&2
log "restoring from $ARCHIVE"
databases=$(printf '%s, ' "${DATABASES[@]}") services=$(printf '%s, ' "${SERVICES[@]}")
if [[ -z $YES ]]; then
	gum confirm "Overwrite the ${databases%, } database data with backup $ARCHIVE?"$'\n'"The ${services%, } services will be offline until the restore finishes." </dev/tty \
		|| abort "nothing was changed"
fi

read -ra REPLICAS <<<"$(kube get deployment "${SERVICES[@]}" -o jsonpath='{.items[*].spec.replicas}')"
log "suspending the backup CronJob and scaling ${SERVICES[*]} to zero"
suspend_backups true
kube scale deployment "${SERVICES[@]}" --replicas=0 >/dev/null
kube wait --for=delete pod -l "app in ($(IFS=,; echo "${SERVICES[*]}"))" --timeout=180s >/dev/null

log "archiving the current databases as kanae-db-pre-restore-*"
kube exec "$POD" -c borgmatic -- \
	borgmatic create --stats --archive-name-format 'kanae-db-pre-restore-{now:%Y-%m-%dT%H:%M:%S}'

stamp=$(date -u +%Y%m%d%H%M%S)
existing=" $(pg -d postgres -c "SELECT string_agg(datname, ' ') FROM pg_database") "
RENAMED=()
rollback() {
	for db in "${RENAMED[@]}"; do
		log "$db: putting the original back"
		pg -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" -c "ALTER DATABASE ${db}_before_restore_$stamp RENAME TO $db"
	done
}

for db in "${DATABASES[@]}"; do
	if [[ $existing == *" $db "* ]]; then
		log "$db: keeping the live database as ${db}_before_restore_$stamp"
		pg -d postgres \
			-c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid()" \
			-c "ALTER DATABASE $db RENAME TO ${db}_before_restore_$stamp" >/dev/null
		RENAMED+=("$db")
	fi

	log "$db: restoring ${DUMP[$db]} from $ARCHIVE"
	if ! dump "$db" | pg_restore -d postgres --create; then
		rollback
		abort "$db did not restore, so every database was put back as it was"
	fi
done

trap - EXIT
finish
kube wait --for=condition=Available deployment "${SERVICES[@]}" --timeout=300s >/dev/null
printf '%ssuccess:%s the %s database data was restored from backup %s, and the %s services are running again\n' \
	"$GREEN" "$RESET" "${databases%, }" "$ARCHIVE" "${services%, }" >&2
for db in "${RENAMED[@]}"; do
	log "once the restore is confirmed good: DROP DATABASE ${db}_before_restore_$stamp;"
done
