#!/usr/bin/env bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION pg_trgm;
    CREATE DATABASE kratos;
    CREATE DATABASE keto;
EOSQL

# Apparently Atlas requires this for diff computation...
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EOSQL