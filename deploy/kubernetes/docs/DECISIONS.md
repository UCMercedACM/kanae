# Decisions

Each section holds one decision about the Kubernetes deployment, the reason for
it, and the date. Add a section whenever you make a choice that somebody will
otherwise reopen. Keep the reason. The outcome on its own is what gets argued
with six months later.

## Helm builds the manifests and kapp deploys them

Helm is a build tool here. `mise run k8s:render` turns the chart in
`deploy/kubernetes/src/` into plain Kubernetes YAML under
`deploy/kubernetes/dist/`, one file per resource. `mise run k8s:apply` hands
that directory to kapp. Nothing runs `helm install`.

Reviewers read Kubernetes instead of Go templates. A pull request names the
resource that changed in the path of the file that changed.

You lose `helm rollback`. A git revert and a re-apply replace it, which is
slower under pressure and easier to audit afterwards.

Decided 2026-09-04.

## kapp applies the manifests, not `kubectl apply`

`kubectl apply` never deletes. Remove a resource from the chart and it keeps
running in the cluster with nothing reporting it. kapp records the resources it
owns, shows a field-level diff before it changes anything, and deletes what has
left the manifests.

A run against a k3d cluster gave 22 creates on the first deploy, then
`0 create, 1 delete, 1 update` after a manifest was removed.

kapp is one binary with no controller, so nothing of it runs in the cluster
between deploys. Argo CD and Flux stay open as later options, because rendered
manifests in git are what they read too.

Decided 2026-09-04.

## The values schema rejects unknown keys

`deploy/kubernetes/src/values.schema.json` sets `"additionalProperties": false`
on every object. Helm validates the values against it on every render.

Without that, `kanae.granianWorkerss: 3` passes validation, renders the default,
and installs cleanly. JSON Schema accepts unknown keys unless you forbid them.
Catching that typo is why the file exists.

Decided 2026-09-04.

## Apply-order annotations are written out, not generated

Each resource carries its own `kapp.k14s.io/change-group` and
`kapp.k14s.io/change-rule`. No template helper derives them. Phase 4 of
`infra-plans/KANAE_INFRA_PLAN.md` declares the six waves.

A helper that looks up the preceding wave saves one edit, on the day somebody
inserts a wave. It costs every reader of a template a lookup to learn what the
resource waits for. It also cannot catch the failure that matters, which is a
misspelled annotation key. A check over `deploy/kubernetes/dist/` catches the
misspelled key and the wrong wave together.

Decided 2026-09-04.

## Policy rules live in `.kube-linter.yml`

`mise run k8s:policy` runs one command:

```
kube-linter lint --config .kube-linter.yml deploy/kubernetes/dist .k8s-local
```

Three rules started as `yq` expressions inside a 30-line shell script. Every
container declares a CPU request, no container sets a CPU limit, and no Secret
reaches `dist/`. kube-linter expresses all three as custom checks.
`unset-cpu-request` and `set-cpu-limit` come from its `cpu-requirements`
template, and `no-rendered-secret` comes from `disallowed-api-obj`. The script
is gone. The rules are now readable by anyone who knows kube-linter rather than
only by someone who reads `yq`.

The built-in `unset-cpu-requirements` check stays off. It demands a request and
a limit together, and rule 7 of the plan asks for a request with no limit, so
the built-in would fail on every container.

Decided 2026-09-04.

## `deploy/kubernetes/dist/` holds no Secrets

The render filters them out. `no-rendered-secret` fails the build if one
appears anyway.

A rendered Secret holds a base64 credential, and this directory exists to be
read. The filter is one line that somebody can delete, so the check is there to
notice when they do.

Decided 2026-09-04.

## Every image is pinned to a digest

All six images in `deploy/kubernetes/src/values.yaml` carry a digest, and
`pullPolicy` is `IfNotPresent`.

`deploy/kubernetes/dist/` is generated, so a manifest that does not change
deploys nothing. Without a digest, a push to main rebuilds the tag, the rendered
Deployment comes out byte-identical, kapp sees no diff, and the pod keeps the
old image for as long as it lives.

Each image uses the `repository` and `tag` shape that Renovate reads, so
Renovate opens a pull request when a digest moves.

Decided 2026-09-04.

## Local renders stay out of the repository

`mise run k8s:render:local` writes `.k8s-local/`, which `.gitignore` excludes.
There is no `local/` directory beside `dist/`.

Two near-identical directories, one disposable and one holding what runs in
production, means checking which one you are in before you can trust what you
see. CI still renders the local values and validates the result on every run,
so that path stays checked without being committed.

Decided 2026-09-04.

## CI installs its tools directly

`.github/workflows/kubernetes.yml` pins `HELM_VERSION`, `KUBECONFORM_VERSION`,
and `KUBE_LINTER_VERSION` in `env` and installs each binary itself. It does not
install mise.

The cost is two places holding a version for one tool. When `mise.toml` and the
workflow disagree, CI can render something different from a laptop, and the
drift check then fails on every pull request with a diff nobody wrote. That
failure is loud, so somebody fixes it, but it is confusing the first time you
meet it.

Decided 2026-09-04.

## Only Renovate's pull requests get an automatic render

The `Render` job in `.github/workflows/kubernetes.yml` commits
`deploy/kubernetes/dist/` back to the branch. It runs only when
`github.event.pull_request.user.id` is `29139614`, the `renovate[bot]` account.

Renovate edits the pinned image versions but cannot run Helm, so its pull
requests arrive with a stale `dist/` and fail the drift check. Without this job,
every version bump needs a person to check out the branch, render, and push.

Pull requests from people are left alone on purpose. A stale `dist/` from a
person is a mistake, and the failing check is how you find out. A bot committing
to your branch during review also forces you to pull before you can push again.

The job matches an account ID rather than a login or a branch prefix. Renovate
documents `branchPrefix`, `gitAuthor`, and `labels` as settings you configure,
so a person can change or copy any of the three. A GitHub account ID is neither
configurable nor transferable.

Decided 2026-09-04.

## The chart reaches its sources through symlinks, not copies

`deploy/kubernetes/src/files/` holds one symlink per file the chart reads from
elsewhere in the repository: the Ory configs, the Postgres initdb script, the
schema, `config.dist.yml`, and the seed data. Nothing moves and no Compose
bind mount changes.

Two programs producing the same file drift eventually, and `.Files.Get` makes
that drift silent: a path it cannot resolve renders an empty string and exits
0. Helm follows symlinks, so a link removes the copy without changing the
render. `mise run helm:files` runs before every render and checks each link is
relative, points where it should, resolves, and names a source CI watches.

Decided 2026-09-04.

## Secrets go through kapp, decrypted in memory

`deploy/kubernetes/secrets.sops.yml` holds the values. `mise run k8s:apply`
decrypts it with SOPS, renders `templates/secrets.yml` alone with
`renderSecrets` on, and hands the result to kapp beside `dist/`. Nothing
decrypts to disk and `k8s:render` never sees a secret value.

Piping Secrets to `kubectl apply` would put them outside kapp, where nothing
prunes them and nothing diffs them. kapp masks Secret values in its diff, so it
reports which Secret changed without printing what it changed to.

Committing them encrypted into `dist/` fails too. SOPS uses a fresh data key on
every run, so identical content encrypts to different bytes and the drift check
never passes.

`scripts/apply.sh` decrypts and renders them into a variable, then hands that
to kapp. It is two steps rather than one pipeline because a failure inside
`<(...)` is invisible to the outer command: kapp would read an empty file and
treat all three Secrets as removed from the app.

Windows is the exception. `scripts/apply.ps1` writes them to a file in the
per-user temp directory, which no other account can read, and removes it in a
`finally` block. PowerShell has no process substitution, and handing kapp the
manifest on stdin instead leaves it reading EOF at its confirmation prompt.

Decided 2026-09-04, Windows note added 2026-09-05.

## Postgres readiness is `pg_isready`, and the checksum query is a CronJob

The readiness probe on `database` runs `pg_isready --username=postgres` and
nothing else. The checksum query it used to run is `postgres-checksum`, a
CronJob that reads `pg_stat_database` once a day at 04:17 and fails when the
count is not zero.

Finding 1 in POC_FINDINGS.md is that query in the probe. It was copied from the
Compose healthcheck with its `$$` intact, which Compose turns into one `$`
before the shell sees it and Kubernetes does not, so the probe could never pass
and the deployment never started. Corruption is still worth knowing about, but
not from a place that can stop the database serving traffic.

A failed CronJob leaves a failed Job in the namespace, and
`failedJobsHistoryLimit: 3` keeps it there. That is the alert until Phase 10
has somewhere to send one.

The Job's command uses no command substitution and no `$$`. Compose, Kubernetes
and the shell each read those differently, and this is the query that proved
what that costs.

Decided 2026-09-06.

## The `database` Service is ClusterIP, not headless

A headless Service publishes no DNS record for a pod that is not Ready. With
the broken probe above, the name `database` stopped existing, every DSN in the
system failed to resolve, and nothing started — one wrong probe took down the
whole deployment and reported it as a DNS error pointing nowhere near the cause.

ClusterIP fails as a connection refused against a name that still resolves.
Postgres runs one replica, so headless bought nothing to weigh against that.

Decided 2026-09-06.

## The Postgres claim outlives kapp, and the volume outlives the claim

`database-data` carries `kapp.k14s.io/delete-strategy: "orphan"`, and
`deploy/kubernetes/storage.yml` holds a `reclaimPolicy: Retain` StorageClass
applied once per cluster.

The two cover different accidents. Orphan stops kapp deleting the claim when it
leaves the manifests. Retain stops the underlying volume going if the claim goes
anyway. Scaleway's stock `scw-bssd` is `reclaimPolicy: Delete`, which turns a
routine mistake into data loss.

The `helm.sh/resource-policy: keep` the claim carried in the proof of concept is
read by `helm install`, which no longer runs, so it protected nothing.

The claim is applied in the same kapp wave as the StatefulSet. The class binds
`WaitForFirstConsumer`, so a claim in an earlier wave has no pod to trigger
binding and kapp waits on `Pending` until it gives up.

Decided 2026-09-06.

## Postgres and Valkey run as the non-root users in their own images

Postgres runs as uid and gid 999, Valkey as uid 999 and gid 1000, each with a
matching `fsGroup`. Both are the user the image already ships.

Finding 3 is Valkey crash-looping on `chown: .: Operation not permitted`. Its
startup script takes ownership of its data directory when it starts as root, and
this chart drops the privilege that needs. Handing the privilege back would fix
the symptom; starting as the user that already owns the directory means the
script never tries.

Postgres gets the same treatment for the same reason, and one consequence is not
obvious: the claim mounts `/var/lib/postgresql`, the parent of `PGDATA`, rather
than `PGDATA` itself. `fsGroup` leaves the volume root group-writable, and
`initdb` refuses a data directory that is not 0700 or 0750. Mounting the parent
lets the entrypoint create `/var/lib/postgresql/18/docker` itself, with the mode
it wants. Compose does not hit this because it runs as root on a Docker volume.

Decided 2026-09-06.

## The Postgres claim mounts the parent of `PGDATA`, and an init container guards it

Since 18 the official image puts the major version in `PGDATA`
(`/var/lib/postgresql/18/docker`) and declares `/var/lib/postgresql` as its
`VOLUME`. That is deliberate: both clusters then sit on one filesystem during a
major upgrade, so `pg_upgrade --link` works without bind-mount contortions.
Pinning `PGDATA` to a version-free path would trade that for a dump and restore.

It has a sharp edge. Bump the image to 19 and the entrypoint finds
`/var/lib/postgresql/19/docker` empty, runs `initdb` beside the 18 cluster, and
the pod goes Ready serving an empty database while the old one sits untouched on
the same volume. Nothing reports it, and the initdb script runs again on top.

The `check-version` init container refuses to start in that state. It is
single-shot, per the startup-gate rule: it exits 0 when `$PGDATA` holds a
cluster or the volume is empty, and exits 1 when the volume holds a cluster
under another major version, naming `pg_upgrade --link` in the message. Tested
against all three.

Decided 2026-09-06.

## Valkey's `maxmemory` is half its memory limit

The container limit is 256Mi and `maxmemory` is `128mb`.

Valkey evicts keys when its dataset reaches `maxmemory`. Its own process,
memory fragmentation and client buffers all count against the container limit
and none of them count against `maxmemory`. Set the two equal and the kernel
kills the container before Valkey ever evicts a key, which reads as a restart
loop rather than as a cache that is full.

Decided 2026-09-06.

## Local Secrets are generated, never decrypted

`deploy/kubernetes/init.sh --local` prints values to stdout instead of encrypting
them, and `scripts/apply-local.sh` pipes them through the same
`templates/secrets.yml` the production path renders, so the `kanae-local` app
owns its Secrets and kapp prunes them with it.

`--local` is the only mode that prints a value in the clear, and it cannot print a
real one: it never opens `secrets.sops.yml`. That property is what makes it
safe, rather than a promise about what the caller does with the output.

Decrypting the real file into a laptop cluster was the alternative. It needs an
age key on every machine and in CI, and it puts the production Kratos cipher and
the real S3 credentials on a cluster that exists for twenty minutes.

The values are freshly generated on every run, exactly as the encrypted path
generates them, and the Kratos webhook tokens still come from
`scripts/derive-webhook-tokens.py` rather than from anything this script
computes itself.

New values therefore mean a new cluster, which is the same rule any secret
rotation follows. `initdb` reads `POSTGRES_PASSWORD` once, on an empty data
directory, so restarting the pod is not enough on its own; the volume has to go
with it. `mise run k8s:reset` and `tests/e2e.sh` both do that by deleting the
k3d cluster, which takes local-path's storage with it.

This supersedes the Phase 3 note that local overrides go through a plaintext
`values.local.yml`. That file is committed, and throwaway credentials in git are
worse than throwaway credentials in a pipe.

The local apply is bash-only, as `deploy/kubernetes/init.sh` has always been.
There is no PowerShell twin for either, so local applies on Windows go through
WSL. `k8s:apply` against production still has one.

Decided 2026-09-06.

## Measurement reads the kernel's high-water mark, it does not sample

`mise run k8s:measure` reads `memory.peak`, `memory.max` and `cpu.stat` out of
each container's cgroup once, and `tests/e2e.sh` runs it before it deletes the
cluster. Nothing polls, nothing accumulates a file, and there is no window to
miss.

`kubectl top` was the obvious tool and it is the wrong one for this. It reports
the latest metrics-server window, so a peak is only visible to a sampler that
happens to be looking when it occurs. Measured here: `kubectl top` said Postgres
was using 43Mi while the kernel had recorded a peak of 138Mi, because the peak
belongs to `initdb` and is over in seconds. Limits set from the sampled figure
would have been a third of what the container needs.

cgroup v2 keeps `memory.peak` for the life of the container, which is exactly
the number a memory limit has to clear. `cpu.stat` gives cumulative CPU time,
so the CPU column is an average over the container's life rather than a peak,
which suits a request: a request is a share weight, not a ceiling.

The read is `kubectl exec … -- cat`, with no shell, so an image that ships none
still answers. An image with no `cat` reports `?` rather than failing the run.

Decided 2026-09-06.
