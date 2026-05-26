FROM postgres:18

RUN echo 'CREATE EXTENSION IF NOT EXISTS pg_trgm;' > /docker-entrypoint-initdb.d/0_extensions.sql
COPY src/schema.sql /docker-entrypoint-initdb.d/schema.sql

USER postgres
