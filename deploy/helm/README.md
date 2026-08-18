# Running the stack on Kubernetes

Helm chart translating `deploy/docker/docker-compose.yml` for Scaleway
Kubernetes Kapsule, plus a local k3d setup for seeing it work.

```
deploy/helm/
├── kanae/                    the chart
│   ├── values.yaml           production defaults (Kapsule)
│   ├── files/                copies of the Ory configs, schema.sql and seed
│   │                         scripts — Helm can only read inside the chart
│   └── templates/
├── values-local.yaml         k3d overrides
├── secrets-prod.example.yaml documents what the secrets file holds
└── seed-k8s.sh               creates the kanae-env / kanae-config Secrets
```

## Tools

Everything is pinned in `mise.toml`:

```bash
mise install    # helm kubectl k3d k9s kubeconform sops age (+ existing tools)
```

`helm-secrets` is a Helm plugin, not a mise tool, and installs separately. Only
needed for the production SOPS flow:

```bash
helm plugin install https://github.com/jkroepke/helm-secrets
```

## Lint first

The chart has never been rendered against a real Kubernetes schema. Do this
before spending time on a cluster:

```bash
mise run helm:lint
```

That runs `helm lint` (chart structure, template parse errors) and pipes
`helm template` through `kubeconform` (validates the rendered manifests against
the Kubernetes OpenAPI schemas). `helm lint` alone does **not** tell you whether
the output is valid Kubernetes — kubeconform is the one that catches a wrong
field name or a bad type.

## Local run with k3d

```bash
# 1. cluster
k3d cluster create kanae

# 2. image — built locally, never pulled (values-local sets pullPolicy: Never)
docker build -f docker/Dockerfile -t ghcr.io/ucmercedacm/kanae:dev .
k3d image import ghcr.io/ucmercedacm/kanae:dev -c kanae

# 3. secrets — -l fills the R2/SMTP values with throwaway placeholders
./deploy/helm/seed-k8s.sh -l

# 4. install
helm install kanae ./deploy/helm/kanae \
  -n kanae --create-namespace \
  -f deploy/helm/values-local.yaml

# 5. watch it come up
k9s -n kanae
```

Then reach it:

```bash
kubectl -n kanae port-forward svc/kanae 8000:8000
kubectl -n kanae port-forward svc/kratos 4433:4433
```

`values-local.yaml` turns off backup, ingress and seeding, and points storage at
k3d's `local-path` provisioner. The production default is `scw-bssd-retain`,
which does not exist locally — without the override the PVC sits `Pending`
forever.

### Iterating

```bash
docker build -f docker/Dockerfile -t ghcr.io/ucmercedacm/kanae:dev .
k3d image import ghcr.io/ucmercedacm/kanae:dev -c kanae
kubectl -n kanae rollout restart deploy/kanae
```

`helm upgrade` re-runs the three migration Jobs (they are
`post-install,post-upgrade` hooks). That is intended — atlas is a declarative
diff, so re-applying an unchanged schema is a no-op.

Tear down with `k3d cluster delete kanae`.

### Exercising the HAProxy `/auth` rewrite

Worth doing once — it is the most breakable part of the chart. Kratos'
`serve.public.base_url` is `https://api.ucmacm.dev/auth`, but Kratos serves its
routes at the root, so `/auth` has to be stripped or every self-service flow
404s. Port-forwarding bypasses the Ingress entirely and will not catch it.

```bash
k3d cluster delete kanae
k3d cluster create kanae --port "8080:80@loadbalancer"
helm repo add haproxytech https://haproxytech.github.io/helm-charts
helm install haproxy-ingress haproxytech/kubernetes-ingress \
  -n haproxy-controller --create-namespace \
  --set controller.ingressClass=haproxy

helm upgrade kanae ./deploy/helm/kanae -n kanae \
  -f deploy/helm/values-local.yaml \
  --set ingress.enabled=true --set ingress.host=api.kanae.localhost

curl http://api.kanae.localhost:8080/auth/self-service/login/browser
```

## Secrets

`seed-k8s.sh` produces the two Secrets the chart reads:

| Secret | Contents |
| --- | --- |
| `kanae-env` | `DB_*`, `KRATOS_SECRETS_*`, `KRATOS_WEBHOOK_TOKEN_*`, `STORAGE_*`, `KRATOS_SMTP_URI` |
| `kanae-config` | `config.yml`, rendered from `config.dist.yml` |

It is **idempotent** — existing values are read back out of the cluster and
kept, so re-running changes nothing. `-r` rotates the generated ones.

The two webhook tokens are never stored as inputs. They are derived on every run
as `blake3(context, key=master_key)`, matching
`scripts/derive-webhook-tokens.py` and `_verify_webhook_token` in
`src/routes/members.py`, so they cannot drift from the master key.

```bash
./deploy/helm/seed-k8s.sh -l              # local: throwaway R2/SMTP values
./deploy/helm/seed-k8s.sh                 # prod: prompts for R2 + SMTP, hidden input
./deploy/helm/seed-k8s.sh -o secrets.yaml # emit to a 0600 file for sops, cluster untouched
```

### Production: SOPS + age

```bash
age-keygen -o ~/.config/sops/age/keys.txt        # each officer; share the public key
./deploy/helm/seed-k8s.sh -o deploy/helm/secrets-prod.enc.yaml
sops -e -i deploy/helm/secrets-prod.enc.yaml
git add deploy/helm/secrets-prod.enc.yaml && git commit
```

Recipients live in `.sops.yaml` at the repo root. Adding or removing an officer
is `sops updatekeys deploy/helm/secrets-prod.enc.yaml` after editing that file.

> **Not wired up yet.** The chart still reads pre-created Secrets via
> `existingSecret` / `existingEnvSecret` (`TODO(sops)` in `values.yaml`).
> Rendering them from `.Values.secrets.*` so `helm secrets install` works is
> outstanding. Until then, `seed-k8s.sh` without `-o` is the path that works.

### What you cannot afford to lose

`KRATOS_SECRETS_CIPHER` encrypts Kratos data at rest. The borgmatic archives
contain the **ciphertext** — without this key a perfect database restore gives
you unreadable identities. `KRATOS_WEBHOOK_MASTER_KEY` is the same story: lose
it and registration and settings flows fail silently against a restored
database.

Neither is protected by the backups. Keep the age key in the club's shared
Drive, passphrase-wrapped:

```bash
age -p -o break-glass.age ~/.config/sops/age/keys.txt
```

Recovery chain: shared Drive → age key → `secrets-prod.enc.yaml` →
`BORG_PASSPHRASE` → R2 archives → database. Test it once, with someone who did
not set it up.

## Notes on the chart

**Service names are fixed** (`kanae`, `database`, `valkey`, `kratos`, `keto`)
rather than templated. `kratos.prod.yml` posts webhooks to
`http://kanae:8000/...` and every DSN points at `database:5432`; keeping the
names identical means those configs need no edits.

**Startup ordering.** Kubernetes has no cross-pod `depends_on` — "Pods in
general are not intended to support DAG workflows". Most of the compose
`depends_on` block is unnecessary here: `asyncpg.create_pool` and
`GlideClient.create` both connect eagerly, so a missing Postgres or Valkey fails
fast and kubelet retries. Only the migration does not fail fast, so kanae has
one init container gating on the schema. Every gate is a single command whose
exit code is the check — kubelet owns the retry.

**Migrations are Jobs, not init containers.** They run once per release, not
once per pod. Seeding is a `post-install` Job at a later hook weight because
`scripts/seed/init.sh` curls kanae's own API — as an init container it would
deadlock.

**Log files.** `_is_docker()` in `src/core.py` looks for `/.dockerenv`, which
containerd does not create, so kanae writes `logs/*.log` under `/kanae`. The
chart mounts an `emptyDir` there so `readOnlyRootFilesystem` can stay on. Those
files duplicate stdout/stderr and nothing collects them.

**Chart file copies.** `files/` holds copies of the Ory configs, `schema.sql`
and the seed scripts, because Helm cannot read outside the chart directory.
`mise run helm:sync` refreshes them; `mise run helm:check` fails CI on drift.
