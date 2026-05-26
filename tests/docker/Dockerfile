FROM postgres:18

# schema.sql relies on gin_trgm_ops without creating the extension itself
# (kanae's docker/ory/init.sh installs pg_trgm in the integration stack's
# postgres). For the test image we install it here so the schema.sql below
# can build its trigram indexes. The "0_" prefix orders this before
# schema.sql lexicographically — postgres runs /docker-entrypoint-initdb.d/*
# in lexical order.
RUN echo 'CREATE EXTENSION IF NOT EXISTS pg_trgm;' > /docker-entrypoint-initdb.d/0_extensions.sql

COPY src/schema.sql /docker-entrypoint-initdb.d/schema.sql
