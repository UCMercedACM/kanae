#!/usr/bin/env bash
# Runs once from /docker-entrypoint-initdb.d on an empty volume.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
	CREATE ROLE kanae_owner  NOLOGIN;
	CREATE ROLE kratos_owner NOLOGIN;
	CREATE ROLE keto_owner   NOLOGIN;

	CREATE ROLE kanae_app       LOGIN PASSWORD '${KANAE_APP_PW:?}' CONNECTION LIMIT 120;
	CREATE ROLE kanae_monitor   LOGIN PASSWORD '${KANAE_MONITOR_PW:?}' CONNECTION LIMIT 5;
	CREATE ROLE kanae_migrator  LOGIN PASSWORD '${KANAE_MIGRATOR_PW:?}'  IN ROLE kanae_owner;
	CREATE ROLE kratos_app      LOGIN PASSWORD '${KRATOS_APP_PW:?}';
	CREATE ROLE kratos_migrator LOGIN PASSWORD '${KRATOS_MIGRATOR_PW:?}' IN ROLE kratos_owner;
	CREATE ROLE keto_app        LOGIN PASSWORD '${KETO_APP_PW:?}';
	CREATE ROLE keto_migrator   LOGIN PASSWORD '${KETO_MIGRATOR_PW:?}'   IN ROLE keto_owner;

	ALTER ROLE kanae_app     SET statement_timeout = '30s';
	ALTER ROLE kanae_monitor SET statement_timeout = '15s';

	-- Migrations create objects as the group, so a rotated credential never orphans a table.
	ALTER ROLE kanae_migrator  SET role TO kanae_owner;
	ALTER ROLE kratos_migrator SET role TO kratos_owner;
	ALTER ROLE keto_migrator   SET role TO keto_owner;

	-- The entrypoint already made \$POSTGRES_DB, owned by postgres.
	ALTER DATABASE "$POSTGRES_DB" OWNER TO kanae_owner;
	CREATE DATABASE kanae_dev OWNER kanae_owner;
	CREATE DATABASE kratos    OWNER kratos_owner;
	CREATE DATABASE keto      OWNER keto_owner;

	-- CONNECT is granted to PUBLIC by default; revoking it is what keeps
	-- kratos_app out of the kanae database.
	REVOKE CONNECT ON DATABASE "$POSTGRES_DB", kanae_dev, kratos, keto, postgres, template1 FROM PUBLIC;
	GRANT  CONNECT ON DATABASE "$POSTGRES_DB" TO kanae_app, kanae_migrator;
	GRANT  CONNECT ON DATABASE kanae_dev      TO kanae_migrator;
	GRANT  CONNECT ON DATABASE kratos         TO kratos_app, kratos_migrator;
	GRANT  CONNECT ON DATABASE keto           TO keto_app, keto_migrator;
	GRANT  CONNECT ON DATABASE postgres       TO kanae_monitor;
EOSQL

# Per database: who owns the schema, and what the runtime role may do in it.
harden() {
	psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$1" <<-EOSQL
		ALTER SCHEMA public OWNER TO $2;
		REVOKE ALL   ON SCHEMA public FROM PUBLIC;
		GRANT  ALL   ON SCHEMA public TO $2;
		GRANT  USAGE ON SCHEMA public TO $3;

		-- Tables a future migration adds inherit these.
		ALTER DEFAULT PRIVILEGES FOR ROLE $2 IN SCHEMA public
		  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $3;
		ALTER DEFAULT PRIVILEGES FOR ROLE $2 IN SCHEMA public
		  GRANT USAGE, SELECT ON SEQUENCES TO $3;

		-- PUBLIC gets EXECUTE on new functions by default. Omitting IN SCHEMA
		-- is required here; the per-schema form of this REVOKE does nothing.
		ALTER DEFAULT PRIVILEGES FOR ROLE $2 REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
	EOSQL
}

harden "$POSTGRES_DB" kanae_owner kanae_app
harden kratos kratos_owner kratos_app
harden keto keto_owner keto_app

# kanae_dev is Atlas's scratch database. Nothing runs against it at runtime and
# kanae_migrator already has everything through kanae_owner, so it needs only an
# owner and PUBLIC kept out.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname kanae_dev <<-EOSQL
	ALTER SCHEMA public OWNER TO kanae_owner;
	REVOKE ALL ON SCHEMA public FROM PUBLIC;
EOSQL

# src/schema.sql uses gin_trgm_ops; Atlas needs it in the dev database too.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c 'CREATE EXTENSION pg_trgm'
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname kanae_dev -c 'CREATE EXTENSION pg_trgm'
