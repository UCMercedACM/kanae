# Kanae infrastructure plan — interrogation responses

Working notes on the review of [KANAE_INFRA_PLAN.md](KANAE_INFRA_PLAN.md).
Points 1 through 5 have been reviewed and decided. Points 6 through 10 are
still outstanding and are listed at the end so nothing gets lost.

Nothing here has been written into the plan yet. This file records the
decisions and the exact edits they imply, so the plan can be updated in one
pass once the remaining points are settled.

---

## Point 1. `deploy/k8s/` is generated and immutable

**Decision.** `deploy/k8s/` is build output. Nothing edits it, nothing pushes
to it directly. Every change reaches it through the templating layer: edit the
chart, run `mise run k8s:render`, commit the result. That includes image
digests — to deploy a new build you change the digest in the chart and
re-render, never the manifest.

**What was wrong.** `deploy/helm/kanae/values.yaml:14` pins `tag: edge` with
`pullPolicy: Always`. That combination works under `helm upgrade`, which bumps
a revision and recreates pods. It does not work under rendered manifests. A
push to main rebuilds `edge`, `deploy/k8s/deployment-kanae.yaml` comes out
byte-identical, `kapp deploy` sees no diff and changes nothing, and the pod
keeps running the previous image indefinitely. `pullPolicy: Always` never fires
because nothing ever recreates the pod.

The plan's "How a change reaches that cluster" diagram only covers
infrastructure changes. The common case — somebody merges a PR touching
`src/` — had no path through it at all.

**Mechanism.** Pin the digest and let Renovate move it. Renovate's
`helm-values` manager reads `deploy/helm/kanae/values.yaml` and recognises the
`image: {repository, tag}` shape. With `pinDigests`, `tag: edge` becomes
`tag: edge@sha256:…` and Renovate opens a PR every time `edge` moves. The tag
stays readable, the digest is what deploys, and the manifest changes on every
release so kapp has something to see.

With a digest pinned, `pullPolicy` should become `IfNotPresent`. A digest is
immutable by construction, so re-pulling it buys nothing.

**Enforcement is already free.** A hand edit to `deploy/k8s/` is just drift:
CI re-renders from the chart, the output differs from what is committed, and
`k8s:render:check` fails. No separate mechanism is needed. The README banner in
that directory exists so people understand why it failed, not to prevent it.

**Open items before this can be written down as working:**

- **A render-back workflow is required.** A Renovate PR touches `values.yaml`
  and nothing else, so `deploy/k8s/` is instantly stale and the drift check
  fails, which blocks automerge forever. Hosted Renovate cannot fix this
  itself — `postUpgradeTasks` is self-hosted only. Something has to run
  `k8s:render` on the PR branch and commit the result.
- **Token gotcha in that workflow.** A push made with the default
  `GITHUB_TOKEN` does not trigger downstream workflow runs, so the drift check
  will never re-run on the rendered commit and the PR sits with a stale red
  check. Either run the drift check in the same workflow after the commit, or
  push with an app token.
- **Five images are invisible to Renovate as values.yaml is written.**
  `postgres.image`, `valkey.image`, `ory.kratosImage`, `ory.ketoImage` and
  `migrate.atlasImage` are bare strings, not the `repository`/`tag` pair the
  helm-values manager looks for. `arigaio/atlas:latest` in particular is
  unpinned today and would stay unpinned. Either restructure them into the
  two-key shape or add a `customManagers` regex block.
- **Private package credentials.** `ghcr.io/ucmercedacm/kanae` is private, so
  Renovate needs a host rule with `packages:read` to resolve its digests at all.
- **Cadence.** `.github/renovate.json` currently groups all `docker` manager
  updates into a monthly automerged rule (`* 0-3 1 * *`). That is fine for base
  images and far too slow for the application image, which needs its own rule.

**Draft paragraph for Phase 2**, to sit after the `k8s:render` task:

> **How a code change reaches the cluster.** `deploy/k8s/` is generated, so a
> new image only deploys when a manifest changes. `values.yaml` therefore pins
> `image.tag` to a digest (`edge@sha256:…`), and Renovate keeps that digest
> current: when `docker.yml` pushes a new `edge`, Renovate opens a PR bumping
> the digest, a render workflow commits the regenerated manifests onto that PR,
> and merging it makes `mise run k8s:apply` roll the pod. The tag stays `edge`
> for readability; the digest is what is deployed. Pin a semver tag instead for
> a release you want to hold still. Without the digest, a push to main changes
> nothing kapp can see and the cluster keeps serving the previous image
> indefinitely.

---

## Point 2. kapp apply ordering

**Decision.** Declare the deploy order explicitly with kapp's
`change-group` and `change-rule` annotations. Six waves.

### Background

Kubernetes has no `depends_on`. Hand it a pile of YAML and it creates all of it
at once. kapp fills that gap, but only if told what waits for what — it cannot
infer it, because nothing in the YAML says so. Its only built-in ordering is
CRDs before custom resources and Namespaces before namespaced resources.

Two annotations do the work:

- **`kapp.k14s.io/change-group`** names a bucket of resources. On its own it
  does nothing; it exists so other resources can refer to the group by name.
- **`kapp.k14s.io/change-rule`** declares ordering, in the grammar
  `(upsert|delete) (after|before) (upserting|deleting) <group>`. `upsert` is
  create-or-update. The verb appears twice because both halves need one —
  what happens to me, and what happens to them.

Both annotations take an optional unique suffix
(`kapp.k14s.io/change-rule.teardown`), so one resource can hold several rules
and belong to several groups. A group name is only needed when something else
names you; the last wave needs no group.

Docs: [Apply Ordering](https://carvel.dev/kapp/docs/latest/apply-ordering/),
[Apply Waiting](https://carvel.dev/kapp/docs/latest/apply-waiting/),
[Configuration](https://carvel.dev/kapp/docs/latest/config/). The docs site's
version dropdown tops out at `v0.64.x` while `mise.toml` pins kapp 0.65.4, so
use `latest`.

### The waves

| # | Group | What's in it | kapp waits for |
| --- | --- | --- | --- |
| 1 | `kanae/config` | ConfigMaps, all five Services, ServiceAccount, image pull Secret | Nothing — ready the moment they exist |
| 2 | `kanae/databases` | Postgres StatefulSet, Valkey Deployment, Postgres PVC | Pods `Ready`, which is `pg_isready` passing |
| 3 | `kanae/database-init` | The Job creating the `kratos` and `keto` databases and `pg_trgm` | Job `Complete` |
| 4 | `kanae/schemas` | Jobs: atlas, `kratos migrate sql`, `keto migrate up` | All three `Complete` |
| 5 | `kanae/services` | kanae, Kratos, Keto Deployments | Deployments `Available` |
| 6 | *(no group)* | Gateway, HTTPRoute, seed Job | Gateway `Programmed` |

Inside a wave everything runs concurrently. All three migration Jobs fire
together; all three Deployments start together. Only the waves are sequential.

Naming follows how the team already talks about the stack: the "databases" are
Postgres and Valkey, and the internal `CREATE DATABASE` work is initialisation.

Every Service sits in wave 1, including `database` and `valkey`, even though
their pods are in wave 2. A Service needs no pods — it is a name and a selector.

The Postgres PVC sits in wave 2 alongside the StatefulSet that consumes it, not
in wave 1 with the other passive resources. Most CSI storage classes, Scaleway's
included, use `volumeBindingMode: WaitForFirstConsumer`, so the claim stays
`Pending` on purpose until a pod needs it. Alone in wave 1 it would have no pod
to trigger binding.

Wave 5 keeps a group name solely so the seed Job in wave 6 can wait on it. Wave
6 needs no name because nothing points at it.

`backup-borgmatic.yaml` gets neither annotation. A CronJob creates nothing at
apply time, so there is nothing to order or wait for.

### Why each boundary exists

Wave 3 cannot merge upward into wave 2, because same-group means concurrent and
the Job would run against a Postgres that is still booting. It cannot merge
downward into wave 4, because `kratos migrate sql` needs the `kratos` database
to already exist and would race its creation.

The `database-init` Job replaces `docker/ory/init.sh`, which is currently
mounted into `/docker-entrypoint-initdb.d/`. Postgres runs that folder only when
the data directory is empty, so it works on first boot and is silently skipped
forever after. Add a third database to that script and redeploy and nothing
happens, with no error. The script is also not idempotent — it uses bare
`CREATE DATABASE kratos` and `CREATE EXTENSION pg_trgm`, so a second run would
fail. The Job version uses `IF NOT EXISTS` and is a no-op on every deploy after
the first.

### The annotations

```yaml
# postgres.yaml, valkey.yaml, kanae.yaml, kratos.yaml, keto.yaml: Services
# postgres.yaml, kratos.yaml, keto.yaml, jobs-migrate.yaml, job-seed.yaml: ConfigMaps
kapp.k14s.io/change-group: "kanae/config"

# postgres.yaml: StatefulSet + PVC. valkey.yaml: Deployment
kapp.k14s.io/change-group: "kanae/databases"
kapp.k14s.io/change-rule: "upsert after upserting kanae/config"

# the new database-init Job
kapp.k14s.io/change-group: "kanae/database-init"
kapp.k14s.io/change-rule: "upsert after upserting kanae/databases"

# jobs-migrate.yaml: all three Jobs
kapp.k14s.io/change-group: "kanae/schemas"
kapp.k14s.io/change-rule: "upsert after upserting kanae/database-init"

# kanae.yaml, kratos.yaml, keto.yaml: Deployments
kapp.k14s.io/change-group: "kanae/services"
kapp.k14s.io/change-rule: "upsert after upserting kanae/schemas"
kapp.k14s.io/change-rule.teardown: "delete before deleting kanae/databases"

# gateway.yaml: Gateway + HTTPRoute. job-seed.yaml: Job
kapp.k14s.io/change-rule: "upsert after upserting kanae/services"
```

### On the Gateway going last

Correct, but for a narrower reason than "it gates traffic."

On a first install it genuinely does: nothing is routable until kanae, Kratos
and Keto are serving. On a redeploy it buys nothing, because the Gateway already
exists unchanged and kapp does not touch it. What protects traffic during a
redeploy is the readiness probe — a restarting kanae pod drops out of the
Service's endpoints and the HTTPRoute stops sending to it. That is Kubernetes,
not kapp.

The real argument for last is failure ordering. kapp waits for the Gateway to
report `Programmed`. In wave 1, a certificate that cannot issue or a
LoadBalancer that never gets an IP fails the deploy before you learn whether the
rest of the stack works. Last means the whole stack comes up and then you find
out about routing specifically.

The cost is that on a cold install, DNS-01 issuance no longer overlaps with the
rest of the deploy, so the first install is a few minutes slower. DNS is being
pointed at it for the first time anyway, so nobody is waiting.

### Teardown rules

Low value, one line. The rule on the Deployments buys a clean shutdown instead
of a log full of connection errors as three services notice Postgres vanished.
Worth writing, not worth thinking about.

Deletion ordering only matters in three situations:

1. **Full `kapp delete`** — ordering is cosmetic, and this should essentially
   never be run in production.
2. **Pruning**, where a resource is removed from the chart and kapp deletes it
   on the next normal deploy. This is the realistic path and what Phase 9's
   deletion test exercises.
3. **A rename.** kapp reads a changed name as delete-the-old, create-the-new.
   Harmless for a Deployment. For the PVC it is data loss, and no ordering rule
   prevents it.

### What a teardown actually removes

Three layers, dying at different times:

| Layer | What it is | Cost of deleting it |
| --- | --- | --- |
| Pod | The running Postgres process | Nothing, it comes back |
| PVC | The claim — "I need a 20GB disk" | The binding between pod and disk |
| PV / block volume | The actual bytes | Everything |

`kapp delete -a kanae` removes the StatefulSet **and** the PVC, because both are
in the manifests and kapp owns both. Whether the data survives is decided one
level lower by the StorageClass: `reclaimPolicy: Delete` (stock `scw-bssd`)
destroys the volume with the claim, `Retain` (`scw-bssd-retain`) drops the PV to
`Released` and leaves the disk orphaned but recoverable by hand.

Valkey has no PVC at all, so tearing it down costs a cache warm-up.

**The plan currently relies on protection that does not exist.**
`KANAE_INFRA_PLAN.md:598` says to keep `helm.sh/resource-policy: keep` on the
Postgres claim. kapp does not read Helm annotations, and Helm no longer installs
anything under this design, so that annotation is inert. It is the same failure
the plan already names for Helm hook annotations on the migration Jobs — "an
inert comment that misleads whoever reads it next" — with much higher stakes,
because this one reads as data-loss protection.

The kapp equivalent, which makes kapp forget the resource rather than delete it:

```yaml
# on the Postgres PVC
kapp.k14s.io/delete-strategy: "orphan"
```

Both protections are wanted, because they cover different accidents.
`delete-strategy: orphan` stops kapp deleting the claim, covering `kapp delete`
and the rename case. `reclaimPolicy: Retain` stops the disk vanishing if the
claim goes anyway.

One interaction to note: if a `Namespace` is added to the manifests and kapp
owns it, `kapp delete` removes the namespace and the cluster cascades that to
everything inside. `orphan` does not help there, because Kubernetes is doing the
deleting, not kapp. `Retain` still does. That is an argument for creating the
namespace as cluster setup in Phase 11 alongside the StorageClass rather than
shipping it in the app's manifests.

### Edits this implies

**Corrections to what the plan currently states:**

- `:598` — replace `helm.sh/resource-policy: keep` with
  `kapp.k14s.io/delete-strategy: "orphan"`, and record that it and the `Retain`
  StorageClass cover different accidents. Highest priority edit in this file.
- `:341` — "applies in dependency order" is false. kapp applies in an order you
  declare with change-group and change-rule annotations.

**Additions:**

- Glossary (~`:71-103`) — rows for change-group / change-rule, versioned
  resources, and `delete-strategy: orphan`.
- Phase 2 — a new task defining the six waves, plus the table above. This is
  where kapp is chosen, so it is where the ordering contract belongs. Later
  phases only annotate the resources they build.
- Phase 2, `:384-388` — `k8s:apply:local` needs a no-wait mode for Layers B and
  C. With ordering in place a partial stack fails legibly, stopping at the first
  wave it cannot satisfy rather than timing out on everything at once, but it
  still fails, and Phases 4 through 7 all deploy incomplete stacks by design.
- Phase 4 — annotate Postgres, Valkey and the PVC into `kanae/databases`.
- Phase 5 — annotate the database-init Job and the three migration Jobs.
- Phases 6 and 7 — annotate the three Deployments into `kanae/services`, plus
  the teardown rule.
- Phase 8 — Gateway and HTTPRoute get `upsert after upserting kanae/services`
  and no group of their own.
- Phase 9, `:993` — extend the deletion test to confirm the orphaned PVC
  *survives* a delete, not just that kapp removes what left the manifests. That
  is the branch where being wrong costs the database.

**Behaviour the plan documents that ordering removes:**

- `:646` and `:703` — "Expect the kanae pod in `Init:Error` with a climbing
  restart count while this runs. That is the design." No longer true. kanae will
  not start until `kanae/schemas` completes.
- `:1075` — "Document that restart counts climbing during startup are normal
  here." Delete. It is now a signal that something is wrong.
- `:1071` — `Init:Error` stays in the runbook but its entry inverts. It used to
  mean "wait, this is normal." It now means the schema check failed against a
  database whose migrations reported success, which is a real fault.

That last group needs care. The plan currently teaches people to ignore a crash
loop, and after this change that instinct is wrong.

---

## Point 3. `kapp.k14s.io/versioned` for the migration Jobs

**Decision.** Use kapp's versioned-resources annotation instead of hand-rolled
content-hash names, and drop `ttlSecondsAfterFinished` entirely.

**What was wrong.** `KANAE_INFRA_PLAN.md:664-669` asks for both a content hash
in the Job name and a TTL. They fight each other. kapp reconciles desired state,
so once the TTL controller deletes a finished Job, the next `kapp deploy` sees a
manifest with no matching cluster resource and recreates it. The migration
re-runs.

This contradicts the phase's own exit gate at `:693` — "run `mise run k8s:apply`
again with nothing changed, and confirm it is a no-op." That gate passes inside
the TTL window and silently stops being true afterwards. It is exactly the class
of bug the plan exists to eliminate: a check that passes for reasons unrelated
to the property it claims to verify.

The general rule: anything that deletes a resource kapp owns behind kapp's back
makes the next deploy recreate it.

**The replacement.** `kapp.k14s.io/versioned` with an empty value makes kapp
create uniquely named resources rather than updating in place, and
`kapp.k14s.io/num-versions` bounds how many it keeps. kapp versions on content
change, so the hash is computed for you, and kapp prunes old versions itself, so
the TTL is unnecessary.

Keep the plan's existing paragraph about immutable pod templates — the reasoning
is correct, it now just describes something kapp does rather than something you
build.

The exit gate at `:693` then holds for the right reason. Reword its
justification from "the Job names have not changed" to "unchanged content
produces the same version, and nothing deletes it behind kapp's back."

**Worth knowing for point 6.** `versioned` on Secrets rewrites the references in
Deployments that mount them, which restarts the pods. That is most of the
secret-rotation problem in point 6 solved for free. Revisit when that point is
reviewed.

---

## Point 4. A standalone node budget section

**Decision.** Add a section documenting the node memory budget and the
constraints of running on one small node, separate from the layers, phases and
task lists.

**Why it needs to exist separately.** Rule 7 mandates request equals limit on
every container, and the scheduler reserves requests. Phase 11 targets a
Scaleway DEV1-M, which is 4 GB. The per-container numbers are scattered across
Phases 4, 6, 7 and 8, so nobody ever adds them up. k3d on a developer laptop
will never reproduce the problem: everything passes locally and the first
production deploy is where a pod goes `Pending` with `Insufficient memory`.

**One rule to state first.** A pod's effective request is `max(largest init
container request, sum of app container requests)`. kanae's 64Mi init container
therefore adds nothing on top of its 512Mi app container. Init containers are
free unless they are the biggest thing in the pod.

**Steady state, from the numbers the plan currently sets:**

| Pod | Request = limit |
| --- | --- |
| kanae | 512Mi |
| postgres | 512Mi |
| kratos | 256Mi |
| keto | 256Mi |
| valkey | 256Mi |
| envoy proxy (one per Gateway) | 64Mi |
| envoy gateway control plane | 64Mi |
| cert-manager controller | 64Mi |
| cert-manager cainjector | 128Mi |
| cert-manager webhook | 32Mi |
| **Total** | **~2.1Gi** |

**Deploy-time additions**, all transient but all reserved while they exist:
atlas 256Mi, kratos migrate 256Mi, keto migrate 256Mi, and — under
RollingUpdate — a 512Mi surge replica of kanae. That is roughly **3.3Gi peak**
against a 4 GB node, of which k3s hands you materially less than 4 GB as
allocatable.

**On deployment strategies.** A Deployment's `strategy` controls how pods are
replaced on update. `RollingUpdate` is the default and starts the new pod
*before* killing the old one, so with the default `maxSurge` you transiently run
two copies and need double the memory. `Recreate` kills the old pod first, then
starts the new one — a few seconds of downtime, no extra memory. On one node
with request equal to limit, `Recreate` (or `maxSurge: 0`) is right for kanae.
The cost is a few seconds of failed requests per deploy, which is already true
of the systemd setup being replaced.

**What the section should say:**

- Run `kubectl describe node` and write the real allocatable figure next to the
  table, rather than assuming 4 GB.
- Set `strategy: Recreate` on kanae while there is one node.
- Use the change-rules from point 2, so migration Jobs complete and release
  their memory before app pods are scheduled. This removes most of the
  deploy-time peak.
- Note the borgmatic CronJob. A backup firing mid-deploy is another pod
  competing for the same headroom.
- Phase 10 replaces the estimates with measurements and must re-total the table
  when it does.

---

## Point 5. Build the e2e harness incrementally

**Decision.** Build the test harness early and grow its assertions as each layer
lands, rather than building the whole thing in one phase at the end.

**What was wrong.** Phase 9 is described in the plan's own words as "the most
valuable phase here," and it comes after everything it would have protected.
Every exit gate in Phases 4 through 8 is a command a human types once, and
nothing re-runs them. If Phase 6 breaks while somebody works on Phase 7, nobody
learns until Phase 9 — and at that point the failure surfaces far from its
cause, which the plan already identifies as this stack's dominant failure mode.

**The shape.** Build the harness once, right after Phase 2, when it asserts
almost nothing: create cluster, import images, render local, apply, wait, run
hurl, tear down. Then each phase converts its exit gate into a hurl file instead
of leaving it as a command somebody typed once.

| Phase | Assertion it contributes |
| --- | --- |
| 4 | Postgres reachable, Valkey answers `PING` |
| 5 | The three databases have their tables |
| 6 | Both Ory health endpoints return `{"status":"ok"}` |
| 7 | `GET /` returns 200, and the request appears in `kubectl logs` |
| 8 | Both HTTPRoute rules work from outside the cluster |

Same total work. The difference is that after Phase 6 lands, nothing can break
Phase 4 without CI saying so.

**Phase 9 still exists**, with real work: widen from three scenarios to all 43,
add the negative test, add the deletion test, wire the nightly schedule.

**Move the seed-script fix out of Phase 9.** "Fix the seed script so it completes
all fifteen members. Find the real cause rather than removing another limit" is
an application bug with an unknown cause. It should not sit on the critical path
to production, and it should not sit inside the phase that carries the
regression safety net for everything before it.

---

## Point 6. Secrets

**Decision.** Bring Secrets under kapp's ownership, and use a `checksum/secret`
pod-template annotation rather than kapp's versioned-resources feature to make
rotation restart the pods that read them.

**Why "pruning" came up at all.** Not a kapp limitation — the plan deliberately
bypasses kapp. `KANAE_INFRA_PLAN.md:511` decrypts with SOPS, renders
`templates/secrets.yaml`, and pipes it into `kubectl apply`. kapp never sees
those resources, so it does not own them, prune them, or diff them.

**The fix is a second `-f`.** Secrets stay out of `deploy/k8s/` — that decision
was right, a committed rendered Secret is a base64 credential in a directory
meant to be read — while still reaching kapp:

```sh
sops -d deploy/helm/secrets-prod.enc.yaml \
  | helm template kanae deploy/helm/kanae -f - --show-only templates/secrets.yaml \
  | kapp deploy -a kanae -f deploy/k8s/ -f -
```

Pruning, ordering and diffing all start working. kapp masks Secret values in its
diff by default, so it reports *which* Secret changed without printing what it
changed to — which is the reviewable property the plan wants and something
`kubectl apply` cannot give at all.

**The rotation problem, concretely.** `deploy/helm/kanae/templates/kratos.yaml:72`
reads the cipher through `secretKeyRef`, which is an environment variable.
Env vars are fixed at container start and never refresh. Rotate the Secret and
the running pod keeps the old value; the Deployment manifest did not change, so
nothing restarts it, and nothing reports this. You believe you rotated and the
cluster has not. Volume-mounted Secrets do refresh in place after a kubelet
sync, but every Kratos and kanae secret here is an env var.

**Why checksum over `kapp.k14s.io/versioned`.** Both work. `versioned` creates
`kanae-env-ver-N` and rewrites references, so the pod template changes and the
pods roll. It was rejected on one specific ground: `num-versions` leaves old
Secrets in the cluster holding the previous credentials. If the reason for
rotating is that something leaked, the leaked value is still sitting there. That
is the one cost on the comparison that gets worse under exactly the circumstance
you would be rotating for. A checksum updates the single Secret in place, so the
old value is gone the moment the new one lands.

Secondary reasons: `kubectl get secret kanae-env` keeps working, and it matches
the `checksum/config` pattern Phase 7 already establishes.

**The cost, and how it is paid.** A checksum must be computed from the secret
contents, so whatever renders `deploy/k8s/` needs the age key. Resolved by
splitting the two render paths:

- `k8s:render` → `deploy/k8s/` reads `secrets-prod.enc.yaml` and needs the key.
  Run by CI and by people who deploy. Nobody else.
- `k8s:render:local` → `.k8s-local/` uses throwaway dev credentials from
  `deploy/helm/init.sh`. No production key, and the output is gitignored.

A contributor changing the chart never touches the production key. They push,
and CI renders `deploy/k8s/` and commits it back to the PR. This is the same
render-back workflow point 1 needs for Renovate digest bumps — one workflow owns
that directory, which is better than the current arrangement where a human has
to remember to run a task.

**Scope the hash per Secret, not globally.**

```yaml
# on the workloads that read kanae-env through secretKeyRef
checksum/env-secret: {{ include "kanae.envSecret" . | sha256sum }}
```

One combined hash would roll Kratos every time the Borg S3 key changed. The
borgmatic CronJob needs no annotation — it creates a fresh pod per run and reads
whatever the Secret holds at that moment. `checksum/config` stays as Phase 7
specifies; two annotations, two sources, no overlap.

**The hash in git is not a leak.** It is a sha256 over values generated by
`openssl rand -hex 32`. The low-entropy fields in the bundle do not weaken it,
because the hash covers the concatenation and the random values dominate. What
it does reveal is the date a credential rotated, which is an audit trail worth
having.

**`delete-strategy: orphan` applies here too.** `templates/secrets.yaml` puts
`helm.sh/resource-policy: keep` on `kanae-env` and `kanae-borg`, not just on the
PVC. Same problem as `:598` — inert under kapp. Both want
`kapp.k14s.io/delete-strategy: "orphan"`.

**Alternatives considered and rejected.** Sealed Secrets, External Secrets
Operator and sops-secrets-operator each add a controller to run, upgrade and
debug on one node. The plan uses exactly that reasoning to defer Argo CD and
Flux, and adding a controller for secrets while deferring one for deploys would
be inconsistent. Sealed Secrets is the one worth revisiting later, because it is
the only option that would put secrets inside `deploy/k8s/` and make them
reviewable with everything else.

**Edits this implies:**

- `:511` — replace the `kubectl apply` step with the `kapp deploy -f -` pipeline.
- `templates/secrets.yaml` — `helm.sh/resource-policy: keep` becomes
  `kapp.k14s.io/delete-strategy: "orphan"` on both Secrets.
- Phase 7 — add `checksum/env-secret` alongside the existing `checksum/config`
  task, on the workloads that read `kanae-env`.
- Phase 2, `:416-430` — the exit gate currently says to run `mise run k8s:render`
  locally and inspect `git diff deploy/k8s/`. A contributor without the age key
  cannot. Reword it to run through the PR: push the values change, CI renders,
  and the PR diff shows the single changed line in `deployment-kanae.yaml`.
- Phase 2 — `k8s:apply` should check for the age key up front and fail with a
  clear message. Without that, a missing key makes SOPS error, the pipe carries
  something useless into `helm template`, and the failure names a missing value
  rather than a missing key.
- Phase 10 runbook — routine rotation goes through the PR flow. Emergency
  rotation does not: rotate directly against the cluster, `rollout restart`,
  then reconcile `secrets-prod.enc.yaml` and let CI re-render. The drift check
  nags until git matches, which is the right amount of nagging. Same
  forward-only shape as the migration policy.

---

## Point 7. Local TLS

**Decision.** cert-manager `selfSigned` issuer locally, ACME DNS-01 in
production, selected by values.

Let's Encrypt cannot issue for a k3d hostname — it only signs names it can
validate control of. The workaround of pointing a real subdomain at 127.0.0.1
and using DNS-01 does work, but it needs DNS provider credentials on every
developer's machine and in CI, and burns rate limits on throwaway clusters.
Not worth it when the exit gate is already `curl -sk` and `-k` skips
verification entirely.

Structurally the two issuers are identical: same Gateway, same HTTPS listener,
same cert-manager, same Secret. Only `issuerRef` differs. Local and production
keep the same shape, which is what Phase 8 is protecting.

Write this in the phase explicitly, so nobody later reads the self-signed cert
as a shortcut that "should" have been Let's Encrypt.

(Noted but not adopted: Tailscale issues real Let's Encrypt certs for `*.ts.net`
via its own DNS-01, so a trusted cert locally is available without exposing
anything, if that is ever wanted.)

---

## Point 8. Namespace

**Decision.** The namespace is `kanae`. Set `namespace: kanae` explicitly on
every resource in the manifests, so `deploy/k8s/` says where it deploys rather
than depending on a `-n` flag or the kubeconfig context.

**Create the Namespace object as cluster setup in Phase 11**, alongside the
StorageClass — not as part of the app's manifests. If the Namespace ships in
`deploy/k8s/` and kapp owns it, `kapp delete -a kanae` deletes the namespace and
Kubernetes cascades that to everything inside it, including the PVC.
`delete-strategy: orphan` does not help, because the cluster is doing the
deleting rather than kapp. Keeping it out of the app removes that path.

---

## Point 9. The Kratos cipher, and where backup keys live

**Correction.** The cipher must never be regenerated. The repo already says so
in two places: `templates/secrets.yaml` calls `KRATOS_SECRETS_CIPHER`
"IRRECOVERABLE. Encrypts Kratos data at rest; the borgmatic dumps hold only the
ciphertext, so losing this turns a perfect restore into unreadable identities."
`deploy/helm/seed-k8s.sh:97` says the same. `keep_or_generate` exists precisely
to preserve it, and rotating requires an explicit `-r` flag with a warning.

The three Kratos secrets behave differently:

| Secret | Rotating it |
| --- | --- |
| `KRATOS_SECRETS_COOKIE` | Signs session cookies. Everyone is logged out. Reversible. |
| `KRATOS_SECRETS_CIPHER` | xchacha20-poly1305 encryption at rest. Existing rows become undecryptable. **Irreversible.** |
| `KRATOS_WEBHOOK_MASTER_KEY` | Derives both webhook tokens via blake3. Kratos and kanae read the same secret, so they rotate together. Safe. |

**Phase 11 is simpler than the original review assumed.** There is no Kratos
serving real users today — it runs locally, reachable over a tailnet. So there
is nothing to carry across at cutover. The first production deploy generates the
cipher for the first time, and from that moment it is permanent. State that in
Phase 11 as a property of the deploy rather than as a migration warning.

**Where secrets live in backups: they do not.** Borg holds the database only.
The secrets are already backed up, encrypted, by git — `secrets-prod.enc.yaml`
is committed, so it exists in every clone and on GitHub. Putting the cipher
inside the Borg archive would make the archive's own encryption the only thing
protecting user data, which is the failure to avoid.

That leaves exactly one thing stored outside the system: a single age private
key. The recursion terminates there, and one root key is the floor — any system
that encrypts anything has to hold one key somewhere it cannot reach itself.

**How that key is held:**

- `.sops.yaml` has four age recipient slots (all currently `REPLACE`). Four
  officers each keep their own private key in their own password manager. Any
  one can decrypt, so losing one person is not a recovery event.
- One break-glass key on top, passphrase-wrapped. `mise.toml` already
  anticipates this, noting `age` is needed for "passphrase-wrapping the
  break-glass key." This is the copy that survives all four officers graduating
  in the same year — which for a student org is the realistic failure, not an
  attacker exfiltrating an archive.
- `sops updatekeys` re-encrypts the data key to a new recipient list without
  touching the values. That is the mechanic for adding an incoming officer and
  removing a departing one, and it belongs in the operations runbook.

**Structure.** The infra plan finishes at Phase 11. A separate operations
runbook then owns deploying, key rotation, officer handover, and restore drills.

**Gap noted.** The 3-2-1 discussion in Phase 10 covers Postgres only. Uploaded
media in R2 is not in the backup story anywhere. R2 has its own durability so it
is not urgent, but "what happens if someone deletes the bucket" should get an
answer in Phase 10 rather than being found out later.

---

## Point 10. Symlinks

**Decision.** Keep the symlink system. Enforce it in three layers, each catching
something the others cannot.

### Why not a directory scan

The first design ranged over `.Files.Glob "files/**"` and flagged any file whose
content looked like a path string. It was rejected for three reasons:

- **`.Files.Get` returns an empty string and exits 0** for a path it cannot
  resolve. That is the failure Phase 3 already documents as the reason the
  copies exist. A glob inspects what it finds, so a file that is not there
  produces no iteration and nothing fails — you get an empty ConfigMap and a
  clean render. Kratos then dies reporting a bad configuration rather than a
  missing file.
- **A directory symlink vanishes entirely.** Helm's loader walks with
  `filepath.Walk`, which does not descend into symlinked directories. Replace
  the four `seed/data` links with one link to the directory — a tidy-looking
  simplification — and every file under it silently leaves the chart.
- **Coverage and usage are different sets.** A glob checks files the chart may
  never read while missing files the chart does read.

### Layer 1. In the chart

Guard the read itself, so the check cannot be forgotten and is scoped to exactly
the files the chart consumes.

```gotemplate
{{/*
  Every read of files/ goes through here. .Files.Get returns an empty string and
  exits 0 for a path it cannot resolve, so an unguarded read turns a broken
  symlink into an empty ConfigMap and a clean render. This turns both failures
  into a render error naming the file.
*/}}
{{- define "kanae.file" -}}
{{- $content := .ctx.Files.Get .path -}}
{{- if eq (len $content) 0 -}}
{{-   fail (printf "chart file %s is missing or empty. On a fresh Windows clone run 'git config core.symlinks true' and re-checkout; otherwise run 'mise run helm:files'. See deploy/k8s/README.md" .path) -}}
{{- end -}}
{{- $trimmed := trim $content -}}
{{- if and (not (contains "\n" $trimmed)) (or (hasPrefix "../" $trimmed) (hasPrefix "./" $trimmed) (hasPrefix "/" $trimmed)) -}}
{{-   fail (printf "chart file %s is not a symlink: it holds the literal path %q. Run 'git config core.symlinks true' and re-checkout." .path $trimmed) -}}
{{- end -}}
{{- $content -}}
{{- end -}}
```

All eighteen call sites convert:

```gotemplate
{{ include "kanae.file" (dict "ctx" $ "path" "files/schema.sql") | indent 4 }}
```

Two are easy to miss and matter more than they look — the checksum reads at
`keto.yaml:35` and `kratos.yaml:46`:

```gotemplate
checksum/config: {{ include "kanae.file" (dict "ctx" $ "path" "files/keto/keto.yml") | sha256sum }}
```

Unguarded, those hash the empty string, so a broken checkout produces a *stable*
checksum and the pod never restarts on a config change.

`_helpers.tpl:20` needs it too, where `config.dist.yml` is read and piped into
`fromYaml`. An empty read there yields an empty map, and the overlay silently
produces a config holding only the overlay's own keys.

`trim` stays despite costing the trailing-newline signal — git never writes a
trailing newline into a symlink blob, but `core.autocrlf` may add CRLF when
materialising one as a regular text file on Windows, so the signal is not
reliable anyway.

### Layer 2. `helm:files`

The list stores repo-relative source paths, which are readable in review. The
relative link is computed, so nobody hand-counts `../`.

```bash
set -euo pipefail
cd "{{ config_root }}"

files=deploy/helm/kanae/files
status=0

while IFS='|' read -r link src; do
  [[ -n $link ]] || continue
  target=$files/$link

  if [[ ! -f $src ]]; then
    printf 'error: source %s does not exist (renamed or deleted?)\n' "$src" >&2
    status=1
    continue
  fi

  want=$(realpath -s --relative-to="$(dirname "$target")" "$src")

  if [[ -e $target && ! -L $target ]]; then
    printf 'error: %s is a regular file, not a symlink.\n' "$target" >&2
    printf '       On Windows: git config core.symlinks true, then re-checkout.\n' >&2
    status=1
    continue
  fi

  if [[ ! -L $target ]]; then
    mkdir -p "$(dirname "$target")"
    ln -s "$want" "$target"
    if [[ ! -L $target ]]; then
      printf 'error: this checkout cannot create symlinks.\n' >&2
      printf '       git config core.symlinks true && re-checkout, or\n' >&2
      printf '       git clone -c core.symlinks=true\n' >&2
      exit 1
    fi
    printf 'created %s -> %s\n' "$target" "$want"
  fi

  got=$(readlink "$target")

  if [[ $got == /* ]]; then
    printf 'error: %s is absolute (%s). Links must be relative or they break on every other machine.\n' "$target" "$got" >&2
    status=1
  elif [[ $got != "$want" ]]; then
    printf 'error: %s points at %s, expected %s\n' "$target" "$got" "$want" >&2
    status=1
  elif [[ ! -e $target ]]; then
    printf 'error: %s is dangling (%s does not resolve)\n' "$target" "$got" >&2
    status=1
  fi
done <<'LIST'
init.sh|docker/ory/init.sh
schema.sql|src/schema.sql
config.dist.yml|config.dist.yml
kratos/kratos.prod.yml|docker/ory/config/kratos/kratos.prod.yml
kratos/identity.schema.json|docker/ory/config/kratos/identity.schema.json
kratos/hooks/payload.jsonnet|docker/ory/config/kratos/hooks/payload.jsonnet
kratos/templates/recovery/valid/email.subject.gotmpl|docker/ory/config/kratos/templates/recovery/valid/email.subject.gotmpl
kratos/templates/recovery/valid/email.body.gotmpl|docker/ory/config/kratos/templates/recovery/valid/email.body.gotmpl
kratos/templates/recovery/valid/email.body.plaintext.gotmpl|docker/ory/config/kratos/templates/recovery/valid/email.body.plaintext.gotmpl
keto/keto.yml|docker/ory/config/keto/keto.yml
keto/namespaces.keto.ts|docker/ory/config/keto/namespaces.keto.ts
seed/init.sh|scripts/seed/init.sh
seed/vars.env|scripts/seed/vars.env
seed/data/tags.json|scripts/seed/data/tags.json
seed/data/members.json|scripts/seed/data/members.json
seed/data/events.json|scripts/seed/data/events.json
seed/data/projects.json|scripts/seed/data/projects.json
LIST

exit "$status"
```

Eighteen entries, matching the eighteen reads. Four assertions per entry: is a
symlink, is relative, points at the expected target, resolves. The
source-exists check catches a rename from the other direction — if
`src/schema.sql` moves, this names the source rather than reporting a
mysteriously dangling link.

`realpath -s` is `--no-symlinks`, so the path is computed textually rather than
resolved through any links on the way. Without it, `--relative-to` canonicalises
and can produce a target that never matches what is recorded.

`k8s:render`, `k8s:render:local` and `k8s:schema` declare
`depends = ["helm:files"]`, so nothing renders without this passing.

### Layer 3. `k8s:policy`

A backstop for things the list does not know about, plus a guard against the
wrapper being bypassed later.

```bash
if find deploy/helm/kanae/files \( -type f -o -xtype l \) -print | grep -q .; then
  echo "error: deploy/helm/kanae/files must contain only resolving symlinks" >&2
  find deploy/helm/kanae/files \( -type f -o -xtype l \) -print >&2
  exit 1
fi

if grep -rn 'Files\.Get' deploy/helm/kanae/templates/ | grep -v '_helpers.tpl'; then
  echo "error: read chart files through 'kanae.file', not .Files.Get directly" >&2
  exit 1
fi
```

The parentheses in `find` are load-bearing. `find A -o B -print` binds `-print`
to `B` alone, so without them the output is misleading.

The grep closes the last gap: an `.Files.Get` added later that skips the
wrapper. The only legitimate one left is inside the `kanae.file` define itself.

### What each layer catches

| Failure | Chart | `helm:files` | `k8s:policy` |
| --- | --- | --- | --- |
| Whole checkout has no symlinks (Windows) | render fails | fails with instructions | yes |
| Link replaced by a copy, content is a path | yes | yes | yes |
| Link replaced by a copy of the real content | no | yes | yes |
| Dangling link (source renamed) | empty read | names the source | yes |
| Link points at the wrong existing file | no | yes | no |
| Link is absolute | no | yes | no |
| Helm stops following escaping links | empty read | no | no |
| An unguarded `.Files.Get` added later | no | no | yes |

Three checks, eight failures, no redundancy.

### Notes

**This is not a Windows check.** Windows is the documented failure, but the
question it asks is OS-agnostic: did the read return the target's contents or
something else. It also catches a copy placed over a link, an archive export or
CI checkout that flattens links, `rsync` without `-l`, and a docker build context
that dereferences.

**The Helm loader assumption is no longer silent.** Everything here rests on
Helm continuing to follow links that escape the chart directory, and Helm has
hardened that loader before. Under the wrapper, a version that stops following
them produces empty content and aborts the render with the file's name. That was
previously a silent failure and is now a loud one, so no separate CI test for it
is needed.

**Blast radius, for context.** A bad local render only reaches production by
being committed, and if it is, CI re-renders on Linux and the drift check fails.
Point 6 moved `deploy/k8s/` rendering to CI, so a Windows contributor never
renders the committed artifact at all — their render goes to `.k8s-local/`,
which is gitignored. The cost of a bad checkout is a confused developer, not a
broken deploy.

---

## Status

All ten points reviewed and decided. Next step is to write these changes into
`KANAE_INFRA_PLAN.md` in one pass.
