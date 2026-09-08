# Securing Postgres with roles and least privilege

Status: proposal. Nothing here is applied to the repo yet.

Every consumer of our Postgres instance connects as the `postgres` superuser with the same
password. This document says what that actually costs us, what the replacement looks like, and
what breaks on the way there. Every privilege claim below was checked in a scratch container
against the real images we run, `postgres:18`, `oryd/kratos:v26.2.0`, `oryd/keto:v26.2.0`, and
`arigaio/atlas:latest`. The evidence is in the last section.

## What one leaked password gets today

`DB_PASSWORD` is the superuser password. It is handed to Kanae, Kratos, Keto, Atlas, the seed
script, and the k8s checksum CronJob:

- `docker/docker-compose.yml:59` sets `POSTGRES_USER: ${DB_USERNAME}` where `DB_USERNAME=postgres`
- `docker/ory/docker-compose.yml:17` builds the Kratos DSN from the same pair
- `deploy/kubernetes/src/templates/_helpers.tpl:14` hardcodes `postgresql://postgres:...` for Kanae
- `deploy/kubernetes/src/templates/postgres.yml:199` runs the checksum CronJob as `PGUSER=postgres`

I stood the current stack up and attacked it over the network with nothing but that password.
All ten probes succeeded. The one that mattered most:

```
$ psql -h db -U postgres -d kanae -c \
    "CREATE TEMP TABLE x(l text); COPY x FROM PROGRAM 'id'; SELECT l FROM x"
uid=999(postgres) gid=999(postgres) groups=999(postgres),101(ssl-cert)
```

That is arbitrary command execution inside the database container, reachable from any container
that holds the password. The same credential also read `postgresql.conf` off disk, dumped every
role's SCRAM hash out of `pg_authid`, ran `ALTER SYSTEM`, and connected to the `kratos` and `keto`
databases. So a bug in a Kanae route that leaks config is not a Kanae incident. It is a full
cluster compromise, including every user's password hash and recovery address in Kratos.

Worth being precise about the shape of this: superusers bypass all `GRANT` checks and all
row-level security. As long as services connect as `postgres`, no amount of grant tuning does
anything at all. Splitting the roles is the prerequisite for every other control.

Two more things the container showed:

The shipped `pg_hba.conf` starts with `local all all trust` and `host all all 127.0.0.1/32 trust`.
Anything that gets code running inside the container is superuser with no password, and
`docker exec ... psql -U postgres` needs no credential at all.

Every DSN in the repo sets `sslmode=disable`.

## The role model

Three databases, three owners, and no service holding more than it needs.

| Role | Login | Purpose | Rights |
| --- | --- | --- | --- |
| `kanae_owner` | no | owns the `kanae` and `kanae_dev` databases and their objects | owner |
| `kanae_migrator` | yes | Atlas | member of `kanae_owner` |
| `kanae_app` | yes | the API at runtime | `SELECT`, `INSERT`, `UPDATE`, `DELETE` only |
| `kratos_owner` | no | owns the `kratos` database | owner |
| `kratos_migrator` | yes | `kratos migrate sql` | member of `kratos_owner` |
| `kratos_app` | yes | `kratos serve` | DML only |
| `keto_owner` | no | owns the `keto` database | owner |
| `keto_migrator` | yes | `keto migrate up` | member of `keto_owner` |
| `keto_app` | yes | `keto serve` | DML only |
| `kanae_monitor` | yes | the checksum CronJob | `CONNECT` on `postgres`, nothing else |

`postgres` stays as the break-glass superuser. Nothing routine uses it, its password lives in a
separate secret from the service credentials, and `pg_hba` refuses it over TCP.

### Two roles I removed after testing them

I originally gave `kanae_monitor` the `pg_monitor` role and added a `kanae_backup` role holding
`pg_read_all_data`. Both were wrong, and the second was badly wrong.

`pg_read_all_data` is not "read the application tables". The manual defines it as reading "all data
(tables, views, sequences), as if having `SELECT` rights on those objects", and system catalogs are
tables, so it reaches them too. The manual separately says `pg_authid` "must not be publicly
readable" and that `pg_roles` exists as the safe view with the password column blanked. Those two
statements collide. I checked on a role holding `pg_read_all_data` and nothing else, not a
superuser: it returned `SCRAM-SHA-256$4096:...` from both `pg_authid` and `pg_shadow` for the
`postgres` role, while a plain role got `permission denied for table pg_authid`. `pg_authid`'s own
ACL grants to `postgres` alone, so the predefined role is overriding it. It also read Kratos
identity rows from a second database. That is two of the baseline attacks,
reopened by a role I had listed as contained. A backup credential with that grant is roughly as
valuable to an attacker as the superuser password. There is also no backup job in the chart yet,
only a `kanae-borg` Secret, so the role was being created ahead of any consumer. It is out until
the backup job lands. To be clear about what that is: a deferral, not a design. When the job
arrives it needs its own pass, and the shape I would start from is explicit `SELECT` on the
application tables plus `CONNECT` on only the databases being dumped, with the same containment
probes run against it. Nothing here proves that role is safe, because it does not exist yet.

`pg_monitor` turned out to be unnecessary. The only monitoring query in the repo is
`SELECT SUM(checksum_failures) FROM pg_stat_database`, and a role holding nothing but `CONNECT`
reads that fine. I tested it. What `pg_monitor` adds is `pg_read_all_stats`, which unmasks
`pg_stat_activity.query` for every session: the plain role saw one query, the `pg_monitor` role saw
nine. Since the bootstrap runs `ALTER ROLE ... PASSWORD` with plaintext in the statement text, a
monitoring credential that can read other sessions' queries is a credential that can harvest the
others during a rotation. Dropped.

Both of these are the same mistake, which is worth naming: I reached for a built-in role because it
was named after the job, without checking what it actually grants.

### Why owners are separate from logins

An owner role that cannot log in is not ceremony. It buys two things. Rotating or dropping
`kanae_migrator` never orphans a table, because the tables belong to `kanae_owner`. And revoking
the group membership freezes DDL without touching ownership, so migrations can be locked outside a
deploy window.

The piece that makes this work is one line:

```sql
ALTER ROLE kanae_migrator SET role TO kanae_owner;
```

Every session the migrator opens assumes the group first, so anything it creates belongs to the
group. Without it, Atlas creates 14 tables owned by the credential and the whole arrangement is
decoration. I checked this after a real `atlas schema apply` run: all 14 tables came back owned by
`kanae_owner`.

### Why the app gets four verbs and nothing else

`kanae_app` gets `SELECT`, `INSERT`, `UPDATE`, `DELETE` and `USAGE` on the schema. No `CREATE`, no
`TRUNCATE`, no `REFERENCES`, no `TEMP` beyond the default. `TRUNCATE` is withheld on purpose. It is
the one DML-adjacent verb that empties a table without leaving per-row work for point-in-time
recovery to replay.

New tables are the failure mode people hit here. If you only `GRANT ... ON ALL TABLES`, the next
Ory upgrade adds a table, the app has no rights on it, and you find out in production. So the
grants are attached to the owner as defaults:

```sql
ALTER DEFAULT PRIVILEGES FOR ROLE kanae_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kanae_app;
```

I confirmed this holds: after Atlas created the schema, `kanae_app` had exactly those four
privileges on `members` with no grant statement run after the migration.

### Why Atlas gets its own database

Atlas needs a dev database to materialize the desired schema and compute the diff. It creates and
drops schemas there. Today `--dev-url` points at the `postgres` maintenance database, which means
the migration credential holds `CREATE` rights sitting next to every other database's metadata.
A dedicated `kanae_dev` database owned by `kanae_owner` gives Atlas the same freedom in a box that
contains nothing.

`src/schema.sql` uses `gin_trgm_ops`, so `pg_trgm` has to exist in both. That is fine without
superuser. `pg_trgm` has been a trusted extension since Postgres 13, so the owner can install it.
I verified the boundary holds in both directions: `kanae_migrator` can create `pg_trgm` and is
refused on `file_fdw`.

### Staying in the `public` schema

I considered moving the app to a dedicated `app` schema and rejected it. Postgres 15 already
removed `CREATE` on `public` from `PUBLIC`, and the plan asserts the revoke explicitly rather than
inheriting it. The remaining gain over a locked-down `public` is small, and the cost is real:
`search_path=public` is baked into the Atlas URLs in three compose files plus `mise.toml`, and
every query in `src/routes/` is unqualified. Not worth it. Revisit if a second application ever shares the
database.

## The bootstrap

It replaces `docker/ory/init.sh` and works the same way: one script in
`/docker-entrypoint-initdb.d`, run once when the volume is empty. Because it runs before anything
else exists, every object is created by the right owner from the start. Nothing needs adopting,
nothing needs to be idempotent, and there is no rerun to guard against. Passwords come in as
environment variables, the way the container already gets `POSTGRES_PASSWORD`.

```bash
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

harden "$POSTGRES_DB" kanae_owner  kanae_app
harden kratos         kratos_owner kratos_app
harden keto           keto_owner   keto_app

# kanae_dev is Atlas's scratch database. Nothing runs against it at runtime and
# kanae_migrator already has everything through kanae_owner, so it needs only an
# owner and PUBLIC kept out.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname kanae_dev <<-EOSQL
	ALTER SCHEMA public OWNER TO kanae_owner;
	REVOKE ALL ON SCHEMA public FROM PUBLIC;
EOSQL

# src/schema.sql uses gin_trgm_ops; Atlas needs it in the dev database too.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c 'CREATE EXTENSION pg_trgm'
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname kanae_dev     -c 'CREATE EXTENSION pg_trgm'
```

That is the whole thing. I booted a container with only this script and nothing else: Atlas applied
`src/schema.sql` in 38 statements, Kratos ran its 338 migrations, Keto migrated, all 14 kanae tables
came out owned by `kanae_owner`, and the containment harness passed 20 of 20.

`kanae_dev` gets two lines rather than the full treatment because it earns nothing more. It is
Atlas's scratch database, nothing connects to it at runtime, and `kanae_migrator` already holds
everything through `kanae_owner`. An earlier draft ran all four databases through one loop, which
forced a row granting `kanae_dev` privileges to `kanae_migrator` that it already had. The loop was
inventing work to keep its own shape. Atlas is happy with just the owner and the revoke; I checked.

The `pg_trgm` lines matter more than they look. This script is the only place in the repo that
creates it, `src/schema.sql` does not, and without it Atlas hits the first
`USING gin (name gin_trgm_ops)` index and fails with `operator class "gin_trgm_ops" does not exist`.

One thing to know rather than plan around: an initdb script only runs on an empty volume, so a
database that already holds data will not pick this up. If that is the case when you roll this out,
the fix is to run the same statements by hand once, plus `ALTER ... OWNER TO` for the tables that
already exist and belong to `postgres`. That is a one-time console session during the rollout, not
something that needs to live in the repo.

### One wrinkle if you migrate an existing cluster

Extensions cannot be re-owned. `ALTER EXTENSION pg_trgm OWNER TO kanae_owner` is a parse error, and
`REASSIGN OWNED BY postgres` is refused outright. So on a database that already exists, `pg_trgm`
stays owned by `postgres`, along with anything Kratos installed during its migrations.

Day to day that costs nothing, and it is why the app's `%` queries keep working. It bites only on a
major-version upgrade, where `ALTER EXTENSION ... UPDATE` needs the extension's owner. Accept it and
treat extension updates as a break-glass operation, or drop and recreate the extension as the owner
during a maintenance window, which rebuilds the four trigram indexes. I would accept it.

On a fresh volume none of this applies: the init script creates `pg_trgm` as the superuser
alongside everything else, which is what the entrypoint runs as anyway.

### Limits that need arithmetic

Two of these settings look like round numbers and are not.

`CONNECTION LIMIT 120` comes from the pool, not from taste. `src/core.py:1442` calls
`asyncpg.create_pool(dsn=..., init=init)` with no `min_size` or `max_size`, so it takes asyncpg's
defaults of 10 and 10, and `min_size` connections open eagerly at startup. Granian forks one
process per worker, each running its own lifespan and its own pool. `docker/example.env` ships
`KANAE_WORKERS=8`, so the app asks for 80 connections before it serves a request. My first draft of
this plan said 40, which would not have degraded under load, it would have failed to boot with
`FATAL: too many connections for role "kanae_app"`. Fix the arithmetic at the source by pinning
`max_size` in `create_pool`, then set the limit from `workers × max_size` with headroom. Until
then, 120 covers the 8-worker default with room for the migrator.

While you are in there: the server's `max_connections` is still the stock 100. Eight Kanae workers
at 80, plus Kratos and Keto at `max_conns=20` each, already oversubscribes it. That is true today
and is not caused by this plan, but per-role limits will turn a vague failure into a clear one.

`idle_in_transaction_session_timeout` is deliberately not set, and this is the change I most
nearly shipped by accident. `src/routes/events.py:357` and `src/routes/projects.py` both hold an
open transaction across two `await request.app.ory.grant(...)` calls, which are HTTP requests to
Keto. `core.py:1443` builds the session as a bare `aiohttp.ClientSession()`, so those requests
inherit aiohttp's 300s default timeout. A 60s idle-in-transaction timeout would let Postgres kill
the transaction while Keto is still being waited on: the event rows roll back, Keto keeps the
relation tuples it already accepted, and the two stores disagree. Set it only after the session
gets an explicit timeout comfortably below it. A 10s `ClientTimeout` and a 60s database timeout
would be a sound pair, but that is an application change and belongs in its own commit.

The enum loop matters for us specifically. `src/schema.sql` declares seven enum types, and Atlas
needs to own them to alter them later.

Note there is no matching `GRANT EXECUTE ... TO :"app"`. I had one, and it undid the point: the
app could still call any function the owner created, `SECURITY DEFINER` ones included, which is the
exact escalation the revoke exists to stop. `src/schema.sql` defines no functions today, so the
strict version costs nothing. When a function does get added, grant `EXECUTE` on that function to
that role, deliberately. I checked what the app still needs and it is all unaffected: the `%`
operator, `similarity()`, `gen_random_uuid()`, the generated `media.kind` column, and trigram index
scans all keep working, because those functions belong to `pg_catalog` or to `postgres` rather than
to `kanae_owner`.

The missing `IN SCHEMA` on the function line is not a typo, and it is not my discovery either. Write
`ALTER DEFAULT PRIVILEGES FOR ROLE kanae_owner IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM
PUBLIC` and Postgres reports `ALTER DEFAULT PRIVILEGES`, stores no row in `pg_default_acl`, and
changes nothing. I hit it while testing, then found the manual documents it with almost exactly this
example: per-schema default privileges are added to the global defaults, so "you cannot revoke
privileges per-schema if they are granted globally", and the manual's own sample of the mistake is
the `public` schema plus `REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`. Drop `IN SCHEMA` and the row
appears as `{kanae_owner=X/kanae_owner}`. It fails silently in the direction that looks secure,
which is the worst way for it to fail.

This does not break trigram search. `src/routes/projects.py` leans on the `%` operator, and
`pg_trgm`'s functions stay owned by `postgres` even when a non-superuser installs it, because a
trusted extension's script runs as the bootstrap superuser. The default-privilege change is scoped
to the owner role, so it never touches them. I checked the `%` query still returns from `kanae_app`
after the revoke.

## Locking down pg_hba

This ships in two revisions, and the order is not optional. Revision one, alongside the role
cutover:

```
# TYPE   DATABASE  USER      ADDRESS  METHOD
local    all       all                trust
host     all       postgres  all      reject
host     all       all       all      scram-sha-256
```

Revision two, in the same deploy that turns `ssl=on`:

```
# TYPE   DATABASE  USER      ADDRESS  METHOD
local    all       all                trust
host     all       postgres  all      reject
hostssl  all       all       all      scram-sha-256
```

```yaml
command: ["-c", "hba_file=/etc/postgresql/pg_hba.conf"]
```

I had these as one file and one rollout step, and it was an outage. The manual is explicit: a
`hostssl` record is "ignored except for logging a warning that it cannot match any connections"
unless the `ssl` parameter is on. And records are matched in order with "no fall-through or backup",
so with `hostssl` as the only TCP rule and `ssl` still off, there is nothing left to match. Every consumer loses TCP access at once, not just the superuser,
and `sslmode=require` does not save them either. The failure text is
`no pg_hba.conf entry for host "...", user "...", no encryption`. Three of the four reviewers who
read this plan caught it independently, which is a fair signal about how easy it is to miss. So
`hostssl` only lands once `ssl=on` is already live in the same change.

Mounting the file beats writing it from an init script, and the reason is ordering. Init scripts
only run on an empty volume, and the entrypoint appends its own `host all all all scram-sha-256`
before they run. `pg_hba` is first match wins, so a `reject` line appended afterwards can never
fire. A mounted file also applies to the volume we already have.

The `reject` line is the cheap win. The superuser becomes unreachable over TCP even with the right
password, from any container, so a leaked break-glass credential is not remotely exploitable. I
verified it rejects `postgres` over both plaintext and TLS while normal roles connect fine.

One caveat on that line: it is a denylist keyed to a role name. It is right for today's single
superuser and it fails open for any future role created with `SUPERUSER`, or granted
`pg_execute_server_program` or `pg_read_server_files`. If more privileged roles ever appear, invert
it into an allowlist that names the service roles and rejects everything else. The `USER` column
takes a `+groupname` form that matches any member of a role, which makes that allowlist short.

I also dropped `local all all scram-sha-256`, which was in my first draft. The argument for it was
weak to begin with, since anyone who can `docker exec` into the container can read the data files
directly. The argument against turned out to be concrete. The compose healthcheck, the seed script
at `scripts/seed/init.sh:89`, and `tests/integration/init.sh:233` all reach Postgres over the local
socket with no password, and none of them can prompt. Making them work would mean putting a live
service credential inside the database container, which is worse than what it fixes. `trust` on the
local socket stays. Use `peer` if you want the tighter version, but do not pay a credential to get
there.

## TLS

Every DSN in the repo says `sslmode=disable`. With `hostssl` above plus:

```yaml
command:
  - "-c"
  - "hba_file=/etc/postgresql/pg_hba.conf"
  - "-c"
  - "ssl=on"
  - "-c"
  - "ssl_cert_file=/tls/server.crt"
  - "-c"
  - "ssl_key_file=/tls/server.key"
```

plaintext is refused outright and sessions negotiate TLS 1.3. One trap that cost me a container:
Postgres refuses to start if the key file is not owned by root or the database user, and it also
rejects a key that is group- or world-readable. A k8s Secret mounts root-owned at `defaultMode`
0644, which fails the second check.

The manual's rule is `0600` when the key is owned by the database user, or `0640` when it is owned
by root, and in the root case the server's user must be a member of the group that can read it. The
server refuses to start if the permissions are more liberal than that.

In the StatefulSet that means a Secret plus a mount, and the existing `securityContext` already
does the work:

```yaml
volumes:
  - name: tls
    secret:
      secretName: kanae-postgres-tls
      defaultMode: 0640
volumeMounts:
  - name: tls
    mountPath: /tls
    readOnly: true
```

`postgres.yml` already sets `fsGroup: 999`, so the mounted files come out group-owned by the
postgres gid, which satisfies the root-owned-plus-group-read case exactly. That is currently true by
luck rather than by intent, so it is worth a comment in the manifest.

### Let's Encrypt is the wrong tool here

Worth stating plainly, because it is the first thing people reach for. Let's Encrypt only issues
certificates for public DNS names it can validate. Every client in this repo connects to
`database`, which is a Docker service name and a Kubernetes ClusterIP name. It resolves only inside
your own network, so there is nothing for Let's Encrypt to check and it will never issue for it.

There is one path that technically works: buy or reuse a real domain, get a certificate for
something like `db.internal.yourdomain.com` over DNS-01 validation (which does not require exposing
the server), and point every client at that name. But look at what it costs. Ninety-day
certificates, so renewal automation you must not let break. DNS provider credentials living in the
cluster. Split-horizon DNS so the public name resolves to a private address. A reload hook wired
into Postgres. All of that to protect traffic that never leaves a Docker bridge or a single
Kubernetes node.

A private CA is less work, not more, and it is the standard answer for service-to-service TLS.
Three `openssl` commands produce a CA and a server certificate valid for ten years, with
`subjectAltName=DNS:database,DNS:localhost` so it matches the names actually in use. Mount the
server key and certificate into the database, mount the CA certificate into each client, done. No
renewal treadmill and no external dependency.

I ran it end to end. A ten-year certificate for `database`, `ssl=on`, `hostssl` in pg_hba, and both
`psql` and asyncpg connecting at `sslmode=verify-full` with the CA: TLS 1.3, connection accepted.
Without the CA the client refuses to connect, and plaintext is rejected by pg_hba. asyncpg reads
`sslmode` and `sslrootcert` straight out of the DSN, so this is a `postgres_uri` change in
`config.yml` and nothing in `src/core.py`.

Keep the CA key offline, not in the cluster. It signs once and is not needed again until you add a
host. If cert-manager ever lands for other reasons its CA issuer does the same job with automatic
rotation, and that is a fine reason to switch, but it is not a prerequisite.

Clients should end at `sslmode=verify-full` with the CA mounted. `require` alone encrypts and
authenticates nothing, so it stops passive sniffing and not an attacker who can answer for the
`database` service name.

## What changes where

`DB_USERNAME` is the thing to be careful with. Nineteen files read it or hardcode `postgres`, and
every DSN in the repo is built as `postgres://${DB_USERNAME}:${DB_PASSWORD}@...`. Deleting the
variable turns those into `postgres://:pw@...` and every service fails to connect. So the rule is:
each DSN gets its role name written in literally, and the password comes from a per-role variable
next to it. No `DB_USERNAME` survives, and no new `*_USER` variables are introduced either. One
role per connection string, spelled out, so grepping for a role finds every place it is used.

| File | Change |
| --- | --- |
| `docker/example.env` | drop `DB_USERNAME`; add `KANAE_APP_PW`, `KANAE_MIGRATOR_PW`, `KRATOS_APP_PW`, `KRATOS_MIGRATOR_PW`, `KETO_APP_PW`, `KETO_MIGRATOR_PW`, `KANAE_MONITOR_PW`, `KANAE_BACKUP_PW`, `POSTGRES_SUPERUSER_PW` |
| `docker/.env` | same, local and gitignored, has to be regenerated by hand |
| `docker/docker-compose.yml` | `database` keeps `POSTGRES_USER: postgres` with the superuser password; `migrate` uses `kanae_migrator` with `--dev-url` on `kanae_dev`; `kanae` uses `kanae_app`; healthcheck uses `kanae_monitor`; publish on `127.0.0.1:5432:5432` |
| `docker/docker-compose.dev.yml` | same `database` and healthcheck changes |
| `docker/docker-compose.test.yml` | same, plus the `migrate` service's `--url` and `--dev-url` |
| `docker/docker-compose.seed.yml` | `DB_USER` becomes `kanae_app`; seeding writes application rows |
| `docker/docker-compose.web.yml` | `DB_USER` becomes `kanae_app` |
| `docker/ory/docker-compose.yml` | `kratos-migrate` and `keto-migrate` get the migrator DSNs, `kratos` and `keto` the app DSNs |
| `docker/ory/docker-compose.prod.yml` | same split |
| `docker/ory/config/kratos/kratos.yml` | the `dsn:` on line 4 is currently shadowed by the `DSN` env var; update it or delete it rather than leaving a stale superuser DSN in the file |
| `docker/ory/config/kratos/kratos.prod.yml` | same |
| `docker/ory/config/keto/keto.yml` | same |
| `docker/ory/init.sh` | replaced by the bootstrap above; it currently creates the Ory databases as superuser-owned |
| `config.dist.yml:177` | `postgres_uri` switches to `kanae_app` |
| `deploy/docker/deploy.dist.env` and `.deploy.env` | drop `DB_USERNAME`, add the per-role passwords |
| `deploy/docker/docker-compose.yml` | same as the dev compose, and remove the `ports:` block on `database` entirely since every consumer is on `db_bridge` |
| `deploy/kubernetes/src/templates/_helpers.tpl:14` | `postgresUri` switches from `postgres:` to `kanae_app:` with its own secret key |
| `deploy/kubernetes/src/templates/secrets.yml` | see below |
| `deploy/kubernetes/src/templates/postgres.yml` | checksum CronJob runs as `kanae_monitor`; mount `pg_hba.conf` and the TLS pair |
| `deploy/kubernetes/dist/**` | generated. `mise run k8s:render` picks these up, and `k8s:render:check` fails CI if you forget |
| `scripts/seed/vars.env:9` and `scripts/seed/init.sh:36` | `DB_USER` becomes `kanae_app`; `DB_PASSWORD` becomes the per-role variable |
| `tests/integration/init.sh:80,233` | the hardcoded `postgres:password` DSN and the `psql -U "$DB_USERNAME"` insert both move to `kanae_app` |
| `mise.toml:41-42` | `DATABASE_URL` and `DEV_DATABASE_URL` move to `kanae_migrator`, dev URL to `kanae_dev` |
| `deploy/docker/init.sh:160` | generates a single `DB_PASSWORD`; extend to the per-role set |
| `deploy/kubernetes/init.sh:101` | same, `generate dbPassword 32` becomes one call per role |
| `deploy/kubernetes/src/values.yaml`, `secrets.dist.yml`, `secrets.sops.yml` | add the per-role keys; sops file needs re-encrypting |
| `deploy/kubernetes/src/values.schema.json` | `additionalProperties: false` on `secrets` means new keys fail validation until the schema declares them |

On the k8s secrets, split by consumer rather than adding keys to one blob. Today `kanae-env` holds
`DB_PASSWORD` alongside the Kratos cookie and cipher secrets, so any pod that mounts it holds
everything. Three Secrets, `kanae-db`, `kratos-db`, and `keto-db`, each with the two credentials
its pods need, means a compromised Kanae pod never sees a Kratos credential. That is the whole
point of the role split, and keeping one Secret would undo it at the k8s layer. The superuser
password goes in a fourth Secret that no Deployment mounts.

The Kanae Deployment has not landed in the chart yet, so doing this before it does means no pod
spec has to be rewritten later.

The database is currently attached to both the `default` and `db_bridge` networks, so Mailpit and
Garage can reach it for no reason. Putting it on `db_bridge` alone, with only Kanae, Atlas, Kratos,
and Keto joining, is free segmentation.

## Verifying it worked

The design has one silent failure mode worth a check.
`ALTER ROLE ... SET role` is applied at login through a path whose error level is `WARNING`. If the
group membership is ever missing, the session logs a warning nobody reads and proceeds as
`kanae_migrator`. Atlas then creates tables owned by the credential, `ALTER DEFAULT PRIVILEGES FOR
ROLE kanae_owner` never fires, and `kanae_app` has no rights on the new tables. You find out in
production. I reproduced it: after revoking the membership, login succeeded with
`WARNING: permission denied to set role "kanae_owner"`, and the DDL then failed with
`no schema has been selected to create in`, which points at nothing useful.

So assert the invariant after every migration, in CI:

```sql
-- Must return zero rows.
SELECT c.relname, pg_get_userbyid(c.relowner) AS owner
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r','p')
  AND (pg_get_userbyid(c.relowner) <> 'kanae_owner'
       OR NOT has_table_privilege('kanae_app', c.oid, 'SELECT,INSERT,UPDATE,DELETE'));
```

One query catches a missing `SET role`, a half-applied bootstrap, and a table that slipped past the
default privileges.

## Rollout

Each phase leaves a working system. Step 6 is the one that did not, in the first draft.

1. Land the new `init.sh` and the verifier query.
2. Recreate staging from an empty volume so the script runs. Services keep using `postgres` for
   now, so nothing changes behaviourally. Run the verifier.
3. Move Kratos and Keto to their four roles. Ory is the risky pair, so it goes first while the
   superuser path still exists as a fallback.
4. Move Atlas to `kanae_migrator` with `kanae_dev`, then Kanae to `kanae_app`.
5. Move the checksum CronJob to `kanae_monitor`.
6. Swap in pg_hba revision one. Superuser over TCP dies here, once nothing needs it.
7. TLS and pg_hba revision two in the same deploy, then `sslmode=verify-full` on the clients.
8. Rotate the old `DB_PASSWORD` and cut it down to break-glass.

Rolling back is a `SET` of DSNs plus reverting `pg_hba`, up until step 8.

Step 8 is not a one-liner, which is how I first wrote it. Kubernetes does not re-inject env vars
into running containers when a Secret changes, and every consumer reads its credential through
`secretKeyRef`. Changing the password in the database without rolling the pods locks out everything
still holding the old value. The order is: write the new Secret, roll each Deployment and
StatefulSet in dependency order, confirm every pod is on the new credential, and only then
invalidate the old password. Compose needs the same care, a `down` and `up` on every container that
reads the changed variable. If you want a grace window instead, `ALTER ROLE ... VALID UNTIL` on a
second credential is the usual trick.

## Tasks

Grouped by what they touch. The rollout above says when each group lands; this says what the work
actually is.

### Roles and ownership

- [ ] Rewrite `docker/ory/init.sh` with the script above. The k8s ConfigMap symlink at
      `deploy/kubernetes/src/files/init.sh` picks it up unchanged
- [ ] Pass the per-role passwords into the database container's environment, in compose and in the
      StatefulSet
- [ ] If the target cluster already has data, run the equivalent statements by hand once, plus
      `ALTER ... OWNER TO` for the existing tables

### Credentials and secrets

- [ ] `docker/example.env` and `docker/.env`: drop `DB_USERNAME`, add the per-role passwords
- [ ] `deploy/docker/deploy.dist.env` and `.deploy.env`: same
- [ ] `deploy/docker/init.sh:160` and `deploy/kubernetes/init.sh:101`: generate one secret per role
- [ ] `values.yaml`, `values.schema.json`, `secrets.dist.yml`, `secrets.sops.yml`: add the keys and
      re-encrypt. The schema has `additionalProperties: false`, so it fails validation until updated
- [ ] Split `kanae-env` into `kanae-db`, `kratos-db`, `keto-db` so no pod holds another's credential
- [ ] Put the superuser password in its own Secret that no Deployment mounts

### Service wiring

Every DSN gets its role name written in literally. No `DB_USERNAME`, no new `*_USER` variables.

- [ ] `docker/docker-compose.yml`, `.dev.yml`, `.test.yml` (including the Atlas `--url`/`--dev-url`)
- [ ] `docker/docker-compose.seed.yml` and `.web.yml`: `DB_USER` becomes `kanae_app`
- [ ] `docker/ory/docker-compose.yml` and `.prod.yml`: migrator DSNs for migrate, app DSNs for serve
- [ ] `docker/ory/config/kratos.yml`, `kratos.prod.yml`, `keto.yml`: the `dsn:` line on line 4
- [ ] `deploy/docker/docker-compose.yml`
- [ ] `deploy/kubernetes/src/templates/_helpers.tpl:14`: `postgresUri` to `kanae_app`
- [ ] `deploy/kubernetes/src/templates/postgres.yml:199`: CronJob to `kanae_monitor`
- [ ] `config.dist.yml:177`
- [ ] `mise.toml:41-42`: `kanae_migrator`, dev URL to `kanae_dev`
- [ ] `scripts/seed/vars.env:9` and `scripts/seed/init.sh:36`
- [ ] `tests/integration/init.sh:80,233`
- [ ] Re-render `deploy/kubernetes/dist/` with `mise run k8s:render`

### Network

- [ ] Ship pg_hba revision one via `-c hba_file=`
- [ ] Bind the dev port to `127.0.0.1:5432:5432`; drop the `ports:` block in `deploy/docker`
- [ ] Put `database` on `db_bridge` only, not `default`
- [ ] Add a k8s NetworkPolicy: default deny, then allow the app, migrators, and CronJob

### TLS

Lands after the roles are in, not before.

- [ ] Generate the private CA and a server cert for `DNS:database,DNS:localhost`
- [ ] Store `ca.key` offline; ship `server.crt`/`server.key` as a Secret at `defaultMode: 0640`
- [ ] Mount them, add `ssl=on` and the cert paths to the `command:`
- [ ] pg_hba revision two (`host` to `hostssl`) in the *same* deploy as `ssl=on`
- [ ] Move clients to `sslmode=verify-full` with the CA mounted

### App changes these depend on

- [ ] Pin `min_size`/`max_size` in `create_pool` (`src/core.py:1442`), then set `CONNECTION LIMIT`
      from `workers × max_size`
- [ ] Give the `aiohttp.ClientSession` an explicit timeout (`src/core.py:1443`) before adding
      `idle_in_transaction_session_timeout`, or the Keto calls inside open transactions will break
- [ ] Raise `max_connections` above the stock 100, or lower the pool sizes

### Verification

- [ ] Land the ownership and grants query as a script
- [ ] Run it in CI after every migration
- [ ] Land the baseline and containment harnesses so the checks are rerunnable

## What this breaks

The k8s checksum CronJob at `deploy/kubernetes/src/templates/postgres.yml:199` connects as
`PGUSER=postgres` over TCP, which the `reject` line kills. Move it to `kanae_monitor`. Its
`readinessProbe` is `pg_isready`, which never authenticates, so that is unaffected. The compose
healthcheck is fine as long as the local socket stays `trust`, which is why it does.

`mise.toml:41` and `:42` are the local `db:apply` and `db:plan` workflow. Both build a superuser DSN
from `DB_USERNAME`, both go over TCP, and `DEV_DATABASE_URL` points `--dev-url` at the `postgres`
maintenance database, which loses `CONNECT` for `PUBLIC` in the bootstrap. Two separate reasons this
stops working. It moves to `kanae_migrator` and `kanae_dev`.

`tests/integration/init.sh:233` writes into `members` as `psql -U "$DB_USERNAME"` through
`docker compose exec -T`, and line 80 hardcodes `postgresql://postgres:password@database:5432/kanae`
outright. The script runs `set -euo pipefail`, so once `DB_USERNAME` is gone from the env it aborts
on the unbound variable before it reaches Postgres. It should use `kanae_app`, which already holds
the `INSERT` and `UPDATE` it needs.

`scripts/seed/init.sh` has the same shape. `vars.env:9` defaults `DB_USER=postgres` and line 36
reads a single `DB_PASSWORD`; both need per-role values, and the writes it performs are covered by
`kanae_app`'s four verbs. I checked the `sudo_grants` upsert specifically, since
`INSERT ... ON CONFLICT DO UPDATE` needs both `INSERT` and `UPDATE`, and it does hold.

The app's connection math, covered above, is the one that fails at boot rather than at a boundary.

`deploy/kubernetes/src/values.schema.json` sets `"additionalProperties": false` on the `secrets`
object. Adding password keys to `secrets.yml` without editing the schema makes `helm template` fail
validation, so the schema, `values.yaml`, `secrets.dist.yml`, and the sops-encrypted
`secrets.sops.yml` all move together or none of them do.

## What is still open after this

Least privilege is not the same as safe, and three things stay open.

A compromised `kanae_migrator` can bait the break-glass superuser. It can `SET ROLE kanae_owner`,
and the owner holds `ALL` on schema `public`, so it can create a function or a table whose name
shadows an unqualified reference. The next time an operator opens a break-glass superuser session
against the `kanae` database and types an unqualified query, the shadowing object runs with
superuser rights, and `COPY FROM PROGRAM` is back. The `reject` line stops an attacker from using
the superuser; it does not stop them from setting a trap for one. The mitigation is procedural:
break-glass sessions connect to the `postgres` database, not to an application database, and run
`SET search_path = pg_catalog` before anything else. Worth writing on the runbook rather than
trusting to memory.

There is no NetworkPolicy in the chart. `deploy/kubernetes/src/templates/` holds `postgres.yml`,
`valkey.yml`, `secrets.yml`, and `_helpers.tpl`, and the database is a ClusterIP Service on 5432 in
a shared namespace. So the compose half of the segmentation story lands and the Kubernetes half
does not: any pod in the namespace can still reach 5432. A default-deny policy with explicit
allowances for the app, the migrators, and the CronJob is the missing piece, and it is a separate
change rather than something to bolt onto this one.

`PUBLIC` keeps `TEMP` on each database. Removing it is defensible, but Ory's use of temp tables
across future migrations is not something I tested, and a broken login flow is worse than a
temp-file DoS from a role that already authenticated.

## Deliberate omissions

No row-level security. One role owns every row in `kanae` and there is no second tenant, so RLS
would add policy surface and no isolation. It becomes worth it the day a role should see a subset
of rows.

No separate read-only role for the API. Kanae's routes both read and write and share one pool, so
splitting would mean two pools and a per-route decision about which to use. Real, but it is
application work, not database work.

Revoking `CONNECT` on the maintenance databases does not hide database or role names.
`pg_database` and `pg_roles` are cluster-shared and readable from inside `kanae` regardless. I
checked. It closes a foothold, not an information leak, and I would rather say so than oversell it.

## Is this more machinery than the problem needs

Worth asking directly, because the answer is partly yes. Nine of the ten baseline attacks are
consequences of superuser-ness alone, and every one of them closes the moment services stop
connecting as `postgres`. That is six login roles and one `reject` line. The tenth, the passwordless
local socket, is not closed by any of this and is deliberately left open. The owner groups,
`kanae_dev`, and the default-privilege plumbing close nothing on that list.

What the owner groups buy is protection against a class of problem the list does not cover:
a migration credential that can drop the schema it migrates, and ownership that survives credential
rotation. Both are real, and neither has a consumer in this repo today. There is no rotation
automation, and no deploy-window gate on migrations. So that layer is paying now for capabilities
nothing uses yet, and it brings the `SET role` failure mode that needs a CI verifier to catch.

I would still keep it, for one reason: the ownership decision is the expensive one to reverse.
Changing which role owns a table on a live database, after Atlas and 338 Kratos migrations have run
against it, is a maintenance window. Adding roles later is not. Structural decisions that are cheap
now and expensive later are the ones worth making early, and this is one.

That argument is weaker than it looks in one place, and it is worth saying so. Extensions cannot be
re-owned, so on a cluster upgraded in place the owner roles never fully own their database's
objects, and the "ownership survives credential rotation" claim holds for tables, sequences, types,
and routines but not for extensions. If that exception bothers you more than it bothers me, it is a
fair reason to prefer the smaller version below.

But if you want the smaller version, it is coherent and I would not argue hard against it: six
login roles, each migrator owning its own database directly, no owner group, no `SET role`, keep
`ALTER DEFAULT PRIVILEGES FOR ROLE <migrator>`, keep the `CONNECT` revokes, keep the `reject` line
and the network changes. That is roughly a third of the SQL and it passes the same containment
probes. The verifier is still worth having.

## Evidence

Everything above was run against real containers, with two harnesses sharing the same probe set.
The baseline harness runs ten probes and nine passed on the first attempt; the tenth was a
mis-written assertion of mine, not a control that held, and it passed once I fixed the regex. So
the honest score against the current configuration is ten for ten. The containment harness covers
the same ground in 20 assertions, because several probes split into a positive and a negative case
and the four maintenance-database connections are asserted separately.

Baseline, current configuration, attacking as `postgres` with the shared password. All ten
succeeded:

| Probe | Result |
| --- | --- |
| app credential is superuser | succeeded |
| enumerate every database | succeeded |
| connect to `kratos` and `keto` | succeeded |
| `COPY FROM PROGRAM` command execution | succeeded, `uid=999(postgres)` |
| `pg_read_file('postgresql.conf')` | succeeded |
| read SCRAM hashes from `pg_authid` | succeeded |
| `ALTER SYSTEM` | succeeded |
| `DROP SCHEMA` in another service's database | succeeded |
| superuser reachable over TCP | succeeded |
| passwordless superuser on the local socket | succeeded |

After the plan, the same ground as `kanae_app` unless noted, 20 of 20 assertions passed:

| Probe | Result |
| --- | --- |
| superuser over TCP | rejected by `pg_hba` |
| superuser on local socket | still works, break-glass intact |
| app is superuser | false |
| app DML | works |
| connect to `kratos` / `keto` / `postgres` / `template1` | `permission denied for database` |
| `COPY FROM PROGRAM` | permission denied |
| `pg_read_file` | permission denied |
| `pg_authid` | permission denied |
| `ALTER SYSTEM` | permission denied |
| `CREATE TABLE` / `DROP TABLE` / `TRUNCATE` | denied |
| `CREATE ROLE` / `CREATE EXTENSION` | denied |
| monitor reads checksum counters | works |
| monitor reads table rows | denied |
| `statement_timeout` on app | 30s |

Functional checks on the real images:

- Atlas applied `src/schema.sql` as `kanae_migrator` against `kanae_dev`. 38 statements, 14 tables,
  all owned by `kanae_owner`, and `kanae_app` picked up its four privileges with no grant run
  afterwards.
- Atlas does not disturb the grants. I ran it four times: the initial apply, a no-op resync, an
  added index, and a brand new table. `kanae_app` kept exactly its four privileges on `members`
  throughout, and the new table came back owned by `kanae_owner` with those same four privileges
  already attached. The app inserted into it with no grant statement in between. This is the part
  of the design I most expected to break.
- Keto applied 4 migrations as `keto_migrator`, then served on `keto_app`. Writing and reading a
  relation tuple both returned 201 and the row. Zero permission errors in its log.
- Kratos applied 338 migrations as `kratos_migrator`, then served on `kratos_app`. Health ready,
  identity created through the admin API across four tables, login flow persisted. Zero permission
  errors in its log.
- `pg_trgm` installed as `kanae_migrator`. `file_fdw` refused.
- Rerunning the whole bootstrap on the populated cluster left the data intact and both Ory services
  live, and containment still passed in full. A rerun does not rotate credentials: the app kept
  connecting on its existing password, and only a run with the rotate flag set changed it.
- The final pass re-extracted the SQL from this document and ran it on clean clusters, rather than
  trusting the earlier harness copy that had drifted from the text. On the first: Atlas applied 38
  statements, Keto migrated and served, Kratos applied 338 migrations and served, and an identity
  and a relation tuple both came back 201, with zero permission errors in either Ory log. On the
  second, Atlas plus the containment harness, 20 of 20.
- A `SECURITY DEFINER` function created by `kanae_owner` is refused to `kanae_app`
  (`permission denied for function`), while the app's trigram operator, `similarity()`,
  `gen_random_uuid()`, and the generated `media.kind` column all still work.

The two Ory results are the ones I would have bet against. A DML-only runtime role is the part of
this plan most likely to fail at the next upgrade, so it is worth rerunning these checks when
Kratos or Keto is bumped.

### What is not proven

Naming these is more useful than a clean scorecard.

The fresh-`initdb` path was never run end to end with the mounted `hba_file` and `ssl=on` together.
I tested the mounted hba on a fresh container and TLS on a separate one, but not the combination
alongside the entrypoint's own temporary-server startup, which is exactly the kind of interaction
that bites.

The connection-limit arithmetic is arithmetic, not a measurement. I did not boot eight Granian
workers against a capped role.

The bootstrap rerun was tested against a populated cluster, not against one mid-rollout with some
services already moved and others not.
