#!/usr/bin/env bash
set -e

### Roles and databases

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
	CREATE ROLE kanae_migrate LOGIN PASSWORD '${KANAE_MIGRATE_PASSWORD:?}';
	CREATE ROLE kratos_migrate LOGIN PASSWORD '${KRATOS_MIGRATE_PASSWORD:?}';
	CREATE ROLE keto_migrate LOGIN PASSWORD '${KETO_MIGRATE_PASSWORD:?}';

	-- 85 comes from 8 Granian workers * 10 (asyncpg max_size) with 5 for headroom
	CREATE ROLE kanae LOGIN PASSWORD '${KANAE_PASSWORD:?}' CONNECTION LIMIT 85;
	CREATE ROLE kratos LOGIN PASSWORD '${KRATOS_PASSWORD:?}';
	CREATE ROLE keto LOGIN PASSWORD '${KETO_PASSWORD:?}';

	CREATE ROLE postgres_monitor LOGIN PASSWORD '${POSTGRES_MONITOR_PASSWORD:?}' CONNECTION LIMIT 5;

	ALTER DATABASE kanae OWNER TO kanae_migrate;
	CREATE DATABASE kratos OWNER kratos_migrate;
	CREATE DATABASE keto OWNER keto_migrate;

	REVOKE CONNECT ON DATABASE kanae, kratos, keto, postgres, template1 FROM public;

	GRANT CONNECT ON DATABASE kanae TO kanae;
	GRANT CONNECT ON DATABASE kanae TO kanae_migrate;
	GRANT CONNECT ON DATABASE kratos TO kratos;
	GRANT CONNECT ON DATABASE kratos TO kratos_migrate;
	GRANT CONNECT ON DATABASE keto TO keto;
	GRANT CONNECT ON DATABASE keto TO keto_migrate;

	GRANT CONNECT ON DATABASE postgres TO postgres_monitor;

	GRANT CONNECT ON DATABASE postgres TO kanae_migrate;
	GRANT CREATE ON SCHEMA public TO kanae_migrate;

	-- Atlas also requires this for some reason...
	CREATE EXTENSION pg_trgm;
EOSQL

### Per database hardening

harden() {
	local db=$1 owner=$2 app=$3

	psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-EOSQL
		ALTER SCHEMA public OWNER TO $owner;
		REVOKE ALL ON SCHEMA public FROM public;
		GRANT ALL ON SCHEMA public TO $owner;
		GRANT USAGE ON SCHEMA public TO $app;

		ALTER DEFAULT PRIVILEGES FOR ROLE $owner IN SCHEMA public
		GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $app;
		ALTER DEFAULT PRIVILEGES FOR ROLE $owner IN SCHEMA public
		GRANT USAGE, SELECT ON SEQUENCES TO $app;

		ALTER DEFAULT PRIVILEGES FOR ROLE $owner REVOKE EXECUTE ON FUNCTIONS FROM public;
	EOSQL
}

harden kanae kanae_migrate kanae
harden kratos kratos_migrate kratos
harden keto keto_migrate keto

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname kanae -c 'CREATE EXTENSION pg_trgm'

### Banning of superusers

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-'EOSQL'
	ALTER ROLE postgres PASSWORD NULL;
EOSQL
