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
│   ├── files/                 copies of Ory configs, schema.sql, seed scripts
│   └── templates/             9 templates
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

**`files/` holds copies.** Helm cannot read outside the chart directory, so the
Ory configs, `schema.sql` and the seed scripts are duplicated there.
`mise run helm:sync` refreshes them; `mise run helm:check` fails CI on drift.
Source of truth remains `docker/ory/config/**`, `src/schema.sql`,
`scripts/seed/**`.

## Not verified

**The chart has never been rendered.** No helm binary was available in the
session that wrote it and the egress proxy blocked the download. Validation was
YAML-structure only — template actions stripped, then parsed — which catches
indentation but not template logic, value references, or whether the output is
valid Kubernetes.

**Run `mise run helm:lint` first.** It does `helm lint` plus
`helm template | kubeconform -strict` over both value sets. Expect it to find
something.

**`seed-k8s.sh` has only been exercised in `-o` mode.** The blake3 derivation is
verified to match `scripts/derive-webhook-tokens.py` byte-for-byte, and the
generated value lengths are correct, but the `kubectl apply` path has never run
against a cluster.

**Nothing has been deployed.** Not to Kapsule, not to k3d.

## Open work

1. **SOPS migration.** The chart reads pre-created Secrets via
   `existingSecret` / `existingEnvSecret` (`TODO(sops)` in `values.yaml`). To
   make `helm secrets install` work it needs `templates/secrets.yaml` rendering
   both Secrets from `.Values.secrets.*`, plus `files/config.tpl.yml` so
   `postgres_uri` and the env Secret share one `dbPassword`. `.sops.yaml` and
   `secrets-prod.example.yaml` already document the layout. Note Sprig has no
   blake3, so the webhook tokens cannot be derived in a template — `seed-k8s.sh`
   recomputes them, which is why they are stored despite being derived values.
2. **First real deploy**, local then Kapsule.
3. **borgmatic config.** The chart schedules it and expects a ConfigMap named by
   `backup.configMap`; the config itself is maintained separately. Borg 1.x
   cannot write to S3/R2 — only Borg 2.x can, via `borgstore` (`s3:`, `b2:`,
   `rclone:`). Check which the image ships before setting `backup.repository`.
4. **Publish `kanae-seed`.** `docker/Dockerfile.seed` exists and
   `mise run seed:image` builds it for k3d, but nothing pushes it to ghcr.
5. **Resource requests/limits**, once there are numbers.
6. **Ory pool sizing.** DSNs use the compose value of `max_conns=20` per service.
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
