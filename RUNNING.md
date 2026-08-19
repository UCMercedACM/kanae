# Running Kanae locally

How to get the stack up, what the pieces are, and what to do when it does not
come up. Two ways to run it:

| | Use it for | Start with |
| --- | --- | --- |
| **Docker Compose** | day-to-day backend work — edit code, hit save, reload | `mise run server:docker:up` + `mise run server:start` |
| **k3d + Helm** | the deployment itself — the chart, ordering, secrets, Ory wiring | `mise run k3d:images` then `helm install` |

Compose is what you want if you are writing route handlers. The Kubernetes path
is what you want if you are changing anything under `deploy/helm/`, because it
is the same chart that goes to Scaleway Kapsule — see
[`deploy/helm/README.md`](deploy/helm/README.md) and
[`deploy/helm/HANDOFF.md`](deploy/helm/HANDOFF.md).

## What is in the stack

| Service | Image | Port(s) | Does |
| --- | --- | --- | --- |
| `kanae` | built from `docker/Dockerfile` | 8000, 9555 | the API; 9555 is Prometheus |
| `database` | `postgres:18` | 5432 | three logical DBs: `kanae`, `kratos`, `keto` |
| `valkey` | `valkey/valkey:9-alpine` | 6379 | presign-URL cache and rate-limiter counters |
| `kratos` | `oryd/kratos:v26.2.0` | 4433 public, 4434 admin | identities, sessions, self-service flows |
| `keto` | `oryd/keto:v26.2.0` | 4466 read, 4467 write | relationship-based permissions |

The service names are fixed and load-bearing. `kratos.prod.yml` posts its
registration webhook to `http://kanae:8000/member/webhooks/registration` and
every DSN points at `database:5432`, so the Kubernetes Services are named to
match the Compose services and neither config needs editing.

Three databases live in one Postgres. `docker/ory/init.sh` creates the `kratos`
and `keto` ones plus `pg_trgm`, and it only runs on an empty data directory.

## Prerequisites

```bash
mise install     # helm kubectl k3d k9s kubeconform sops age uv yq atlas ...
```

Everything is pinned in `mise.toml`. Docker must be running. Nothing else needs
to be on `PATH` — if a command in this guide is "not found", you are outside
mise's shims; use `mise exec -- <cmd>` or `mise run <task>`.

> One pin matters more than the rest: **mikefarah `yq` 4.53.3**. The Python `yq`
> is a different program that happens to share the name, has no `strenv`, and
> makes `seed-k8s.sh` fail while rendering `config.yml`. If yours prints
> `yq 0.0.0` and mentions "jq wrapper", that is the wrong one.

## The local Kubernetes stack

### 1. Cluster

```bash
k3d cluster create kanae
kubectl config current-context      # k3d-kanae
```

`k3d cluster create` writes the context into `~/.kube/config` and selects it. If
`kubectl` says `connection to the server localhost:8080 was refused`, that write
did not happen or something else reset your context.

### 2. Images

```bash
mise run k3d:images
```

Builds `kanae:dev` and `kanae-seed:dev` and imports both into the cluster.

**Do not point this at `ghcr.io/ucmercedacm/kanae:edge`.** It reads like the
obvious choice and it does not work: the package is private, a k3d node has no
registry credentials, and you get

```
failed to resolve reference "ghcr.io/ucmercedacm/kanae:edge": failed to authorize:
failed to fetch anonymous token: ... 401 Unauthorized
```

with the `kanae` Deployment and the seed Job's `wait-for-kanae` init container
both in `ImagePullBackOff`. A `docker pull` of that same tag on your machine can
succeed, because your Docker daemon has ghcr credentials the cluster does not —
that is a trap, not evidence. `kanae-seed` is not published anywhere at all.
Both tags are unqualified and paired with `pullPolicy: Never` so nothing ever
reaches for a registry.

### 3. Secrets

```bash
./deploy/helm/seed-k8s.sh -l
```

Creates the namespace and three Secrets — `kanae-env`, `kanae-config`,
`kanae-borg`. `-l` fills the externally-issued values (R2, SMTP) with throwaway
placeholders.

It is idempotent: existing values are read back out of the cluster and kept, so
re-running changes nothing. `-r` rotates the generated ones. The two Kratos
webhook tokens are never stored as inputs — they are re-derived on every run as
`blake3(context, key=master_key)`, matching `scripts/derive-webhook-tokens.py`
and `_verify_webhook_token` in `src/routes/members.py`, so they cannot drift.

### 4. Install

```bash
helm install kanae ./deploy/helm/kanae -n kanae \
  -f deploy/helm/values-local.yaml --timeout 20m
```

Give it the long timeout. `helm install` blocks until the post-install hooks
finish, and the seed Job is one of them.

Watch it:

```bash
k9s -n kanae                            # or
kubectl -n kanae get pods -w
kubectl -n kanae logs job/kanae-seed -f
```

### What happens, in order

```
main release      Deployments and StatefulSet created; kanae's init container
                  waits for the schema
post-install  -1  kanae-schema ConfigMap
post-install   0  kanae-migrate, kratos-migrate, keto-migrate (concurrent)
                  → schema appears, kanae starts
post-install   9  kanae-seed ConfigMap
post-install  10  kanae-seed Job — waits for kanae to serve, then seeds
```

Expect three to five minutes. Pods showing `Init:Error` with a climbing restart
count during this window are **working as designed**, not broken. Every startup
gate is a single command whose exit code is the check — `pg_isready`, one
`psql -c 'SELECT 1 FROM members LIMIT 0'`, one `curl` — and kubelet owns the
retry with exponential backoff. There are deliberately no retry loops inside the
containers. `kanae`'s `wait-for-schema` fails until `kanae-migrate` lands, then
exits 0 and the pod starts.

Postgres reaching `1/1 Running` is the gate everything else waits on: `database`
is a **headless** Service, so until its probe passes there is no DNS record and
nothing can resolve `database:5432`.

### 5. Reach it

```bash
kubectl -n kanae port-forward svc/kanae 8000:8000
kubectl -n kanae port-forward svc/kratos 4433:4433
```

```bash
curl -s localhost:8000/health
curl -s localhost:8000/docs        # OpenAPI
```

The Ingress is off locally — it needs the HAProxy controller. Turning it on to
exercise the `/auth` path-rewrite is worth doing once and is written up in
`deploy/helm/README.md`; port-forwarding bypasses the Ingress entirely and will
not catch a broken rewrite.

### Seeded data

`values-local.yaml` enables seeding, because watching the parts wire together is
most of the reason to stand this up locally. The Job runs
`scripts/seed/init.sh`, which creates Kratos identities, logs them in through
the real self-service flows, writes Keto relation tuples, and posts events,
projects and tags into kanae. That path exercises the **Kratos → kanae
registration webhook**, which nothing else in a local run touches.

You get four named accounts — `admin@`, `member@`, `manager@` and
`leads@seed.test.local` — plus the 15-person roster in
`scripts/seed/data/members.json`, and 20 events, 15 projects, 15 tags.

Passwords are generated per run. The Job prints them at the end:

```bash
kubectl -n kanae logs job/kanae-seed | tail -30
```

Seeding is `post-install` only, so `helm upgrade` will not re-seed. To re-run
it, delete the Job and reinstall.

> **Known issue: the seed Job does not currently run to completion.** The stack
> itself comes up clean — all five services Ready, all three migration Jobs
> Complete — and identity provisioning works: registration mints Kratos
> identities, the Kratos → kanae registration webhook fires, and
> `GET /members/me` returns a real member (verified by hand). But the Job gets
> partway through the 15-person roster and then fails with
> `did not resolve an identity`, retries, and gets a little further each time.
> Turning the rate limiter off moved it past member 11 but did not finish it.
> Everything except the seed data is usable in the meantime.

## Day-to-day

```bash
# code change → rebuild and roll
mise run k3d:images
kubectl -n kanae rollout restart deploy/kanae

# logs
kubectl -n kanae logs deploy/kanae -f
kubectl -n kanae logs deploy/kratos --tail=50

# psql
kubectl -n kanae exec -it database-0 -- psql -U postgres -d kanae

# re-apply the chart (re-runs the three migration Jobs; atlas is a declarative
# diff, so re-applying an unchanged schema is a no-op)
helm upgrade kanae ./deploy/helm/kanae -n kanae -f deploy/helm/values-local.yaml

# validate the chart without a cluster
mise run helm:lint
```

Teardown:

```bash
helm uninstall kanae -n kanae     # leaves the PVC: resource-policy is keep
k3d cluster delete kanae          # the only complete reset
```

`helm uninstall` deliberately keeps `database-data`, and deleting the namespace
does not always clear what the local-path provisioner wrote. **If you want a
genuinely clean run, delete the cluster.** Stale Kratos identities in a
half-cleared database make the seed script take its "identity already exists"
branch and fail in ways that look like an auth bug and are not.

## When it does not come up

Start here — it is almost always one of these, and the surface error rarely
names the cause.

| Symptom | Cause |
| --- | --- |
| `ImagePullBackOff`, `401 Unauthorized` from ghcr | pointing at the private `ghcr.io/ucmercedacm/kanae` instead of the local `kanae:dev`. Run `mise run k3d:images`. |
| Kratos `CrashLoopBackOff`, `does not match pattern "^smtps?://.*"` | `KRATOS_SMTP_URI` is not a URI. Kratos validates it at startup and refuses to boot. |
| valkey `CrashLoopBackOff`, `chown: .: Operation not permitted` | the container is running as root with `CAP_CHOWN` dropped; it must run as uid 999. |
| Everything stuck, nothing resolves `database:5432` | Postgres is not Ready. It is headless — no Ready endpoint means no DNS at all. Check `kubectl -n kanae logs database-0`. |
| Seeding dies at `did not resolve an identity` | either stale identities from a previous run (delete the cluster), or the rate limiter is on (see below). |
| `helm install` hangs for many minutes | it is waiting on a post-install hook. `kubectl -n kanae get jobs` shows which. |

### The rate limiter and seeding cannot both be on

`values-local.yaml` sets `kanae.limiterEnabled: false`, and `seed-k8s.sh -l`
renders the same thing into `config.yml`. This is not tidiness:
`GET /members/me` carries `@router.limiter.limit("10/minute")`, and seeding
provisions 15 members serially, calling it once per member. Member 11 onward
gets a `429`, the script reads no `.id` out of the response, and it fails with
`did not resolve an identity` — a message that points nowhere near rate
limiting. It fails at the same place every run.

Both config-rendering paths have to agree here. `seed-k8s.sh` renders
`config.yml` with `yq` for the pre-created-Secret flow; the chart renders the
same file from `_helpers.tpl` for the SOPS flow. If you change one, change the
other.

## The Compose stack

For backend work, skip Kubernetes entirely.

```bash
cp docker/example.env docker/.env    # then fill it in
mise run server:docker:up            # dev | seed | test
mise run server:start                # granian with --reload
```

`server:docker:up` takes an environment argument: `dev` (databases only, the
default), `seed` (with seed data), `test` (what the integration tests use).
Every task that touches Compose depends on `docker/.env` existing and fails
immediately if it does not.

Other entry points:

```bash
mise run docker:preview   # the whole server stack, no local process
mise run docker:web       # the above plus the chapter-website frontend
```

Schema changes go through Atlas against the running dev database:

```bash
mise run server:schema:plan
mise run server:schema:apply
```

Object storage in Compose is Garage, not R2. After a fresh start or data loss:

```bash
mise run garage:generate:keys    # appends to docker/.env; re-run to rotate
mise run garage:setup            # layout, key import, bucket, CORS
mise run garage:status
```

## Before you push

```bash
mise run server:check     # ty + ruff, lint and format
mise run tests:check
mise run scripts:check    # shellcheck + shfmt
mise run helm:lint        # chart structure + rendered manifests vs k8s schemas
mise run helm:check       # fails if deploy/helm/kanae/files/ has drifted
```

`deploy/helm/kanae/files/` holds **copies** — Helm cannot read outside the chart
directory, so the Ory configs, `schema.sql`, `config.dist.yml` and the seed
scripts are duplicated there. Edit the originals, then `mise run helm:sync`.
