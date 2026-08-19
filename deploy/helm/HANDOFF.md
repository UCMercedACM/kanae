# Helm chart — handoff

Context for picking up the Kubernetes work. `README.md` in this directory covers
how to *run* it; this file covers why it looks the way it does and what is still
missing.

## Where things stand

Branch `claude/kanae-infrastructure`. The chart covers every service in
`deploy/docker/docker-compose.yml` and targets **Scaleway Kubernetes Kapsule**
(free Mutualized control plane, ~€21/mo for a DEV1-M node + block storage +
IPv4). Nothing has been deployed anywhere yet.

```
deploy/helm/
├── kanae/
│   ├── values.yaml            production defaults
│   ├── files/                 copies of Ory configs, schema.sql, config.dist.yml,
│   │                          seed scripts
│   └── templates/             10 manifests + _helpers.tpl
├── values-local.yaml          k3d overrides (seeding on, backup/ingress off)
├── secrets-prod.example.yaml  documents the SOPS secrets file
├── seed-k8s.sh                creates the kanae-env / kanae-config Secrets
└── README.md                  how to run it
```

## Decisions worth not re-litigating

**Service names are hardcoded** (`kanae`, `database`, `valkey`, `kratos`,
`keto`) rather than templated with `{{ include "kanae.fullname" }}`. This is
deliberate and load-bearing: `kratos.prod.yml` posts webhooks to
`http://kanae:8000/member/webhooks/registration`, its admin `base_url` is
`http://kratos:4434/`, and every DSN points at `database:5432`. Keeping the k8s
Service names identical to the compose service names means those config files
need zero edits. It also forces everything into one namespace, since CoreDNS
only resolves short names within one.

**Migrations are Jobs, not init containers.** They run once per release, not
once per pod. As init containers they would re-run on every restart and, with
`replicas > 1`, run concurrently — two `atlas schema apply` against one database,
on a declarative diff that can drop columns.

**Seeding is a Job at hook-weight 10, and cannot be an init container.**
`scripts/seed/init.sh` curls `$KANAE/...` and `$KRATOS_PUBLIC/self-service/...`,
so it needs kanae already serving. Gating kanae on it deadlocks.

**Hooks are `post-install,post-upgrade`, not `pre-install`.** Helm hooks run
outside the normal release, so a `pre-install` hook cannot wait on a StatefulSet
that does not exist yet.

**Kubernetes has no cross-pod `depends_on`** — "Pods in general are not intended
to support DAG workflows" (`design-proposals-archive/node/container-init.md`).
Most of the compose `depends_on` block needs no translation: `asyncpg.create_pool`
and `GlideClient.create` both connect eagerly in the lifespan, so a missing
Postgres or Valkey fails fast and kubelet retries with backoff. Kratos and Keto
are not contacted at startup at all. Only the migration does not fail fast — the
pool connects to an empty database, kanae reports ready, then errors per request
— so kanae has exactly one init container gating on the schema.

**Every startup gate is single-shot.** No `for i in $(seq ...)`, no `until`
loops. The init-containers docs state kubelet "repeatedly restarts that init
container until it succeeds", so an in-container loop duplicates kubelet's
backoff and inflates worst-case startup. An earlier unbounded `until` loop in
the migration Jobs was worse than useless: it could never exit non-zero, so
`backoffLimit` never tripped and a stuck Postgres hung the whole `helm upgrade`.

**Probes use images that actually ship the tool.** This bit three times during
development: `nc` is not in `postgres:18`, and neither is `curl`. Each probe now
runs in the image that has its binary — `pg_isready`/`psql` in `postgres:18`,
`valkey-cli` in the Valkey image, `wget` in the Ory images, `curl` in kanae's own
image. Check this before adding a probe.

**Probe commands are copied verbatim from the compose healthchecks**, including
the `pg_stat_database` checksum query. Do not "simplify" them.

**Two Ingress objects, not one.** `haproxy.org/path-rewrite` applies to every
path in the object it is attached to, and only the Kratos backend may have
`/auth` stripped. Kratos generates URLs with that prefix but serves its routes at
the root, so without the rewrite every self-service flow 404s. Port-forwarding
bypasses the Ingress and will not catch a broken rewrite.

**No TLS in the chart.** Certificates come from certbot/letsencrypt assembled
into HAProxy's combined PEM and referenced from the HAProxy config. No
cert-manager annotations, no `spec.tls`.

**Postgres PVC is standalone, not a `volumeClaimTemplate`**, with
`helm.sh/resource-policy: keep`, and `storageClass` must be a Retain-policy
class. Stock `scw-bssd` is `reclaimPolicy: Delete` — deleting the PVC would
destroy the volume. The Retain class is created once per cluster out of band
(see the comment in `templates/postgres.yaml`); it is not templated because it
is cluster-scoped infrastructure, not part of a release.

**Valkey has no PVC.** It is a pure cache — presign URLs on a 270s TTL and
limiter counters that already have `limiter.in_memory_fallback` — run with
`volatile-ttl` eviction and no AOF/RDB.

**`/kanae/logs` is an `emptyDir`.** `_is_docker()` in `src/core.py:166` checks
`/.dockerenv` and `"docker"` in `/proc/self/cgroup`, neither of which holds under
containerd, so `rotating_handler()` returns `AppRotatingHandler` and kanae writes
log files. Rather than change the code, the chart gives it a writable directory
so `readOnlyRootFilesystem` can stay on. Those files duplicate stdout/stderr and
nothing collects them. **If you later fix `_is_docker()`, remove this mount.**

**No resource requests or limits anywhere**, deliberately, pending real numbers
from a running deployment.

**Secrets have two paths that produce identical output.** `secrets.create false`
(the default) mounts Secrets somebody else created — `seed-k8s.sh` without `-o`,
which is the local flow. `secrets.create true`, set by the SOPS file itself,
renders them from `.Values.secrets.*`. Both produce the same names
(`kanae-env`, `kanae-config`, `kanae-borg`), so no workload knows which path ran.
False is the default because it is the failure-safe one: an install that forgets
the secrets file mounts what is already in the cluster rather than overwriting it
with blanks. Every value is wrapped in `required`, so a half-filled file fails at
render naming the key instead of installing an empty password.

**`config.yml` is an overlay, not a second copy.** `_helpers.tpl` merges the
deployment's values onto `files/config.dist.yml` rather than maintaining a
`config.tpl.yml`, so a key added to `config.dist.yml` arrives with its documented
default and `helm:check` catches the copy going stale. It is a named template
because the kanae Deployment hashes the same bytes into `checksum/config` — a
checksum computed from anything other than the real output stops matching the
moment the overlay grows a key. The overlay mirrors the yq expression in
`seed-k8s.sh`; keep them in step.

**Webhook tokens are stored, not derived, in the chart.** Sprig has no blake3.
`seed-k8s.sh` recomputes both from the master key on every run, which is what
stops them drifting.

**`files/` holds copies.** Helm cannot read outside the chart directory, so the
Ory configs, `schema.sql`, `config.dist.yml` and the seed scripts are duplicated
there.
`mise run helm:sync` refreshes them; `mise run helm:check` fails CI on drift.
Source of truth remains `docker/ory/config/**`, `src/schema.sql`,
`scripts/seed/**`.

## What has now been verified

**The chart renders.** `helm lint` is clean and
`helm template | kubeconform -strict -kubernetes-version 1.31.0` passes over all
three value sets: production (22 resources), `values-local.yaml` (20), and a
filled secrets file (25, the three Secrets being the extra).

That pass found nothing by itself — the real bugs were in what the rendered
commands *do*, which no schema check can see. Fixed since:

- The **Postgres readiness probe could never have passed**, and because
  `database` is headless, a never-Ready Postgres means no DNS record and
  nothing in the release resolves `database:5432`. `$$` was copied from the
  compose healthcheck; compose collapses it to `$` before the shell sees it,
  but **kubelet expands nothing in an exec probe** — the `$(VAR)` expansion
  Kubernetes does perform applies to a container's command/args, never to
  probes. `sh` got a literal `$$` and substituted its own PID.
- The **atlas Job assumed the image ships `/bin/sh`**, which the chart cannot
  check. It now passes args to the image's entrypoint the way compose does, and
  lets Kubernetes' `$(VAR)` expansion build the DSNs.
- **Kratos issues Secure cookies**, which breaks local seeding — see below.

**`seed-k8s.sh -o` runs end to end** and its output feeds `helm template`
directly. The blake3 tokens still match `scripts/derive-webhook-tokens.py`, and
the `config.yml` it renders with yq is now **key-for-key identical** to the one
the chart renders from the same values — that was checked by diffing them, and
it is an invariant worth re-checking if either side changes.

## Not verified

**Nothing has been deployed.** Not to Kapsule, not to k3d, and the environment
this was written in could not do it: the egress policy blocks
`production.cloudfront.docker.com` (where Docker Hub serves every blob),
`registry.k8s.io` and `quay.io`, so no image can be pulled and no k3d cluster
can start. helm, kubeconform and mikefarah yq were built from source through
the Go module proxy, which is reachable. Anyone with normal network access
should start by doing what could not be done here.

**`seed-k8s.sh`'s `kubectl apply` path has still never run against a cluster.**

**The borg Secret's env var names are a guess.** `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` are what rclone, borgstore's `s3:` backend and boto all
read, but confirm against the image in `backup.image` before trusting a backup.

## Open work

1. **First real deploy**, local then Kapsule. Everything below is downstream of
   actually running it once.

   The first thing to watch on a local run is **Kratos cookies**. The v26.2.0
   config schema says of `cookies.secure` and `session.cookie.secure`: "If unset,
   defaults to !dev mode." Kratos is not started with `--dev`, so both are
   Secure, and curl drops a Secure cookie on an `http://` request to a
   non-localhost host (verified locally; note curl special-cases `127.0.0.1` as
   a secure context, so a port-forwarded probe can succeed while the in-cluster
   seed Job against `http://kratos:4433` fails). `scripts/seed/init.sh` drives
   the *browser* self-service flows, which are double-submit CSRF protected: it
   reads `csrf_token` out of the flow body, but the matching cookie never comes
   back, so the POST is rejected. `ory.insecureCookies` in `values-local.yaml`
   exists for this and is off in production. It is reasoned from the schema, not
   observed — if seeding still fails CSRF, that is the first place to look.

   Also note the chart mounts `kratos.prod.yml` while compose seeds against
   `kratos.yml`, so a local run exercises a config combination the compose stack
   never has.
2. **borgmatic config.** The chart schedules it and expects a ConfigMap named by
   `backup.configMap`; the config itself is maintained separately. Borg 1.x
   cannot write to S3/R2 — only Borg 2.x can, via `borgstore` (`s3:`, `b2:`,
   `rclone:`). Check which the image ships before setting `backup.repository`,
   and confirm the credential env var names against the Secret the chart now
   renders.
3. **Publish `kanae-seed`.** `docker/Dockerfile.seed` exists and
   `mise run seed:image` builds it for k3d, but nothing pushes it to ghcr.
4. **Resource requests/limits**, once there are numbers.
5. **Ory pool sizing.** DSNs use the compose value of `max_conns=20` per service.
   With Kratos + Keto + kanae's asyncpg pool that is up to ~50 backends against a
   Postgres sized for a 4 GB node. Lowering to 5 was recommended and deliberately
   left as a separate decision.

## Gotchas that cost time

- The repo pins **mikefarah `yq` 4.53.3** via mise. The Python `yq` (a jq
  wrapper) has no `strenv` and breaks `seed-k8s.sh`'s config rendering. If it is
  earlier on `PATH`, that is the error you will see.
- Helper functions in `seed-k8s.sh` run inside `$(...)`, so **`log()` writes to
  stderr**. Anything printed to stdout there ends up inside a secret value.
- `image.pullPolicy` is `Always` because `edge` is a moving tag. With
  `IfNotPresent` a node keeps whatever it pulled first and silently serves a
  stale image.
