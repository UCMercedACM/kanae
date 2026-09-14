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

## The migration Jobs and the two Ory ConfigMaps are `kapp.k14s.io/versioned`, so `dist/` does not match the cluster on five names

`kanae-migrate`, `kratos-migrate` and `keto-migrate` carry
`kapp.k14s.io/versioned` with `kapp.k14s.io/num-versions: "2"`. kapp applies
them as `kanae-migrate-ver-1` and so on, creates a new version when the content
changes, and prunes the old ones.

`kratos-config` and `keto-config` carry the same pair of annotations, for a
different reason recorded further down.

This is a deliberate exception to the promise that `deploy/kubernetes/dist/` is
what runs in the cluster, and it is bounded to these five names. For the Jobs it
buys the one thing a Job cannot otherwise do: a pod template is immutable, so re-applying the
same Job name with new contents fails outright, and without versioning a changed
migration cannot be deployed at all.

Each Job also carries a checksum of the file it mounts on its pod template. The
schema and the two Ory configs live in ConfigMaps, not in the Jobs, so a
schema-only change otherwise leaves the Job byte-identical, produces no new
version, and never runs. On a Deployment the annotation alone would be enough;
here it works only because `versioned` turns the update into a new Job.

Pruning lags by one deploy. The deploy that creates a new version leaves the
older ones alone, and the deploy after it reports `0 create, 1 delete` on a
diff nobody wrote. Measured on k3d with three versions of `kanae-migrate`
present under `num-versions: "2"`: the fourth deploy is what removed `ver-1`.
That delete is kapp catching up, not drift.

A Job that ends in `Failed` is not retried by a later deploy either. The content
is unchanged, so kapp produces no new version, applies nothing, and reports the
deploy green. Recovering from that means changing the file the Job mounts, or
deleting the failed version so kapp recreates it.

Decided 2026-09-08.

## Migrations are forward-only

There is no down migration in this system and no plan to add one. `git revert`
on the manifests returns the code to the previous version and leaves the
database migrated, because nothing un-runs a migration.

Atlas makes that sharper than it sounds. It applies a declarative diff between
`src/schema.sql` and the live database, so a column deleted from that file
becomes a `DROP COLUMN`, and reverting the commit afterwards does not bring the
column or its data back.

Roll forward instead. Write the change that returns the schema to where you want
it, apply that, and let the audit trail show both steps.

This is not theoretical. Adding a column to `tags` on k3d produced
`kanae-migrate-ver-2` and the column; putting `src/schema.sql` back produced
`ver-3`, and the column was gone. Neither run printed the statement anywhere a
person would see it, because the Job applies with `--auto-approve`.

The consequence for a rollback under pressure is that the database is the part
that does not roll back. If a release has to be reverted after a destructive
migration, the schema change has to be reverted as a new forward migration
first, or the previous version of the code has to tolerate the new schema.

Decided 2026-09-08.

## The migration DSNs drop to `max_conns=5`, the serving ones stay at 20

The two migration DSNs in `_helpers.tpl` now carry
`max_conns=5&max_idle_conns=2`. The two serving ones keep
`max_conns=20&max_idle_conns=4`.

Five is already generous. Migrations need one connection. Both binaries apply
them through `github.com/ory/x/popx`: Kratos's `migrate sql` reaches
`popx.MigrateSQLUp`, Keto's `migrate up` reaches the same `MigrationBox`, and
`UpTo` is a plain sequential `for` loop that opens one `isolatedTransaction` at a
time. There is no goroutine, errgroup, or worker pool anywhere in that file, and
`popx.Transaction` checks out exactly one `database/sql` connection per
migration. `Status`, which Keto runs either side of `Up`, is one more query on
the same connection. Go's pool never opens a connection nobody asked for, so
`max_idle_conns` caps what stays pooled and never pre-opens anything.

Deleting the parameter would have been worse than shrinking it.
`sqlcon.ParseConnectionOptions` defaults `max_conns` to `maxParallelism() * 2`
and `max_idle_conns` to `maxParallelism()`, so an unset DSN scales with the
node's CPU count. Setting it small is the only way to make it small.

What this buys is the connection budget, not memory. A Postgres backend costs
about 1.5 to 1.8MiB, measured by opening connections against the running pod and
reading its cgroup: 110.7MiB at 2 connections, 330.7MiB at 146, with page tables
alone accounting for 27.7MiB of that. So the three migration Jobs were never a
memory problem. They were 60 configured slots against a `max_connections` of 150
that the serving pools, kanae's role limit of 85, and the monitor already spend
130 of. Fifteen instead of sixty removes that.

The serving pools stay at 20 because the whole set should be decided together,
and kanae's pool is a Phase 7 question. Postgres currently runs with a 1Gi limit
rather than the 512Mi the node budget assumes, and measured 330.7MiB with
`max_connections` saturated, so there is more headroom there than the budget
describes. Phase 10 sets the serving pools and that limit against each other.

The Compose stacks keep `max_conns=20` on their migration DSNs. They run against
a database with no such contention and were left alone deliberately.

Decided 2026-09-14, replacing the "keep 20 for now" entry of 2026-09-13.

## The chart mounts `kratos.prod.yml`, and the dev Compose stack keeps `kratos.yml`

`deploy/kubernetes/src/files/kratos/kratos.prod.yml` is what the ConfigMap
holds, under the key `kratos.yml`. `docker/ory/docker-compose.yml` runs the
other file. `docker/ory/docker-compose.prod.yml` runs the same one the chart
does.

A local Kubernetes run therefore exercises a file the dev Compose stack never
loads, and that is deliberate. `kratos.yml` points its webhooks at
`host.docker.internal:8000` and its UI at `localhost:5173`, and neither resolves
to anything useful from inside a pod. The cluster needs `kanae:8000`, which only
`kratos.prod.yml` has.

The divergence is bounded, and the boundary is what makes this safe. Everything
that differs between the two files is a URL, a CORS header, a comment, or
`log.leak_sensitive_values`. The flow structure and the hook ordering are
identical, which matters because the three webhook tokens reach Kratos as
environment variables that index into the hook lists by position.

What you give up is a browser flow you can finish on a laptop: every `ui_url` in
`kratos.prod.yml` is `https://ucmacm.dev`, so a local login redirects to
production's front end. The seed script does not care, because it drives the
self-service JSON API and the admin API rather than a browser, and Phase 9's
end-to-end test works the same way. Anyone who wants a local browser flow should
run the Compose stack, which is what it is for.

Decided 2026-09-13.

## `ory.insecureCookies` sets `COOKIES_SECURE`, and its effect is observed rather than inferred

`deploy/kubernetes/values.local.yml` sets `insecureCookies: true`, which puts
`COOKIES_SECURE=false` in the Kratos container's environment.
`src/values.yaml` sets it false and production never changes that.

The variable is written out either way, `"true"` in `dist/` and `"false"`
locally, rather than appearing only when the flag is on. Kratos defaults to
`true`, so the production value changes nothing at runtime, but a reader of
`dist/` should not have to know that default to know whether these cookies are
`Secure`. An absent variable and a variable set to the safe value look the same
until you go and read Ory's schema.

HANDOFF.md recorded this as worked out from the config schema and never seen.
Both directions have now been watched on k3d, from a pod inside the cluster
against `http://kratos:4433`, the same request each time:

| `Secure` enabled | `Set-Cookie` on `/self-service/login/browser` | the POST that follows |
| --- | --- | --- |
| no | `Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax` | reaches the password check |
| yes | the same, plus `Secure` | `security_csrf_violation`, 403 |

The second row is the whole problem in one line. The client received the cookie
and threw it away, because a `Secure` cookie does not survive a plain `http://`
response, so the next request carried no CSRF cookie and Kratos rejected it. The
error names CSRF and nothing about CSRF is misconfigured.

Test it from inside the cluster or not at all. `curl` and every browser treat
`127.0.0.1` as a secure context, so a `kubectl port-forward` test keeps the
cookie, passes, and tells you nothing about the path that broke.

This is not only a browser concern. `scripts/seed/init.sh` drives the same
browser self-service flows over plain HTTP, so the seed Job in wave 6 fails at
the same CSRF check without this setting.

`--dev` was the first thing tried and it works, but it is the wrong tool.
Alongside the cookie flag it drops the minimum bcrypt cost, arms an
API-flow-enforcement bypass, and changes the serve defaults, so the local
cluster would differ from production on four axes when the intent was one, and
Phase 9's end-to-end test would run against the looser one. `cookies.secure` is
the narrow key. Both were measured here and produce an identical `Set-Cookie`.

Two details cost time and are worth writing down. The schema types this as a
string, so `secure: false` as a YAML boolean fails validation at startup with
`expected string, but got boolean` and Kratos refuses to boot. And it is
delivered as a plain environment variable rather than through the mounted
`overrides.yml`, because that file is a Secret and this is not a secret.

Decided 2026-09-13.

## Kratos reads every secret from a mounted file, and nothing secret reaches it through the environment

`kratos-db` carries two files. `overrides.yml` holds the DSN, the cookie and
cipher secrets, and the SMTP URI, and the Deployment passes it as the last `-c`
so it wins, the same trick the migration Jobs already use for their DSN. Keto's
`dsn.yml` is the same shape, and holds only a DSN because that is all Keto has.

The three webhook tokens cannot go in `overrides.yml`. They sit inside a hook
list, and Ory's file provider replaces a list wholesale rather than merging into
it, so an overlay would have to restate every hook under those flows. That is a
second copy of the webhook definitions drifting away from `kratos.prod.yml` the
first time somebody edits one.

So they are substituted instead. `kratos-db` also carries a `kratos.yml`, which
is the canonical file with its `${KRATOS_WEBHOOK_TOKEN_REGISTRATION}` and
`${KRATOS_WEBHOOK_TOKEN_SETTINGS}` placeholders filled in by `kanae.kratosConfig`,
the same move `users.acl` already makes for its `resetpass` token. That helper
is named for Kratos rather than written as a general `substitute`, because it
knows which file it reads and which two tokens belong in it, and a caller that
had to supply those could supply the wrong ones. The
placeholders were in the file for exactly this purpose. That copy is a Secret
because it now holds credentials, and it is the one the Deployment serves from.

The first version of this shipped the three tokens as
`SELFSERVICE_FLOWS_*_HOOKS_0_CONFIG_AUTH_CONFIG_VALUE` environment variables,
which cost a `C-0207` kubescape exception and coupled the env var names to hook
ordering in `kratos.prod.yml`. Both are gone. The Kratos pod spec now holds one
environment variable, `COOKIES_SECURE`, which is not a secret and is written out
in both value sets.

Upstream is no help here, and was checked before deciding. `ory/k8s` renders the
whole config into a ConfigMap minus `dsn`, `secrets` and
`courier.smtp.connection_uri`, ships those four as `secretKeyRef` environment
variables, and documents `deployment.environmentSecretsName`, an `envFrom` over
an entire Secret, as the way to supply anything else sensitive. A webhook
`auth.config.value` in that chart lands in a ConfigMap in plaintext. Five
`C-0207` hits and a token in a ConfigMap is worse on both counts.

`kanae.kratosConfig` fails the render when a placeholder is missing, because
`replace` would otherwise do nothing and ship the literal `${KRATOS_WEBHOOK_TOKEN_...}`
as the credential: Kratos would send it, kanae would answer 401, and
registration would break for everybody with nothing naming the cause. That check
replaces the hook-ordering guard that used to live in `check-policy.sh` and
`check-policy.ps1`, which only existed because the environment variable
addressed hook 0 by index. Nothing addresses a hook by index now.

Verified on k3d: the pod spec carries one environment variable,
`/etc/secrets/kratos.yml` holds both real tokens and no remaining placeholder,
and `k8s:scan` exits 0 with no `C-0207` entry in `.kubescape/exceptions.json`.
Falsified the guard by renaming one placeholder in `kratos.prod.yml`, which
fails the render naming the token, and restored the file byte-identical.

The cost is that the config Kratos actually serves is not in `dist/`, because
secrets are never rendered there. The ConfigMap copy is, with the placeholders
intact, so the config stays reviewable and a diff to it still rolls the pod.

Decided 2026-09-14.

## Kratos mounts one ConfigMap, remapped onto the paths its config names

`kratos-config` holds six flat keys, because a ConfigMap key cannot contain a
`/`. The Deployment's volume maps them back onto the tree `kratos.yml` asks
for: `payload.jsonnet` becomes `hooks/payload.jsonnet`, and the three recovery
templates land under `templates/recovery/valid/`.

Mounting three ConfigMaps at `/etc/config`, `/etc/config/hooks` and
`/etc/config/templates/...` was the obvious alternative and it needs the kubelet
to create directories inside a read-only volume. `items[].path` takes a
subdirectory and produces the tree in one mount instead.

Five of the six keys reach the serving pod. `kratos.yml` is deliberately left
out of its `items`, because the copy it serves from has the webhook tokens
substituted in and so lives in `kratos-db`. Verified on k3d with
`find /etc/config` in the running pod.

The Kratos migration Job mounts the same ConfigMap flat, with no `items`, and is
the only reader of the `kratos.yml` in it. `migrate sql` never looks at the
webhook hooks, so the placeholders there are harmless.

Decided 2026-09-13.

## Kratos is sized at 512Mi against argon2, because nothing else bounds it

`hashers.argon2.memory` is per hash, and nothing in Kratos limits how many hashes
run at once. `hash/hasher_argon2.go` `Generate` calls `argon2.IDKey` directly,
with no semaphore, no mutex, and no queue. Every concurrent password operation
allocates another full block.

That made the original 256Mi limit a one-request ceiling. Measured on k3d from
the container's own cgroup:

| what | `memory.peak` | against a 256Mi limit |
| --- | --- | --- |
| idle | 51.9Mi | 20% |
| one password hash | 179.8Mi | 70% |
| two concurrent | — | `OOMKilled`, both requests returned nothing |

Every password path hashes: registration, login, and a settings password change.
Two people logging in at the same moment was enough.

`dedicated_memory` is not the knob, and the name invites the mistake twice over.
It reads as a ceiling on hasher memory, and its own CLI help says "Kratos will
try to not consume more memory", but it appears only in `cmd/hashers/argon2`
(calibrate and loadtest) and in config parsing. The serving path never reads it.
Lowering it to `128MB` was tried on the cluster and concurrent hashes still
OOMKilled the container. It records what a calibration assumed. Nothing more.

So the pod limit is the only ceiling, and it was sized from a calibration rather
than a guess. `kratos hashers argon2 calibrate 15 --dedicated-memory=384MB
--max-memory=384MB --expected-deviation=500ms`, run inside the cluster against
the node this deploys to, settled on `memory: 128MB` with `iterations: 3` and
measured a 504ms median at 146.86MB used over a 19.5s load test. 15 logins per
minute is the assumed worst case and is written down as an assumption: it is
what the sizing rests on, and real traffic is what should replace it.

512Mi holds three concurrent hashes against that profile. `dedicated_memory` is
set to `384MB` to match what the calibration assumed, understanding that it
enforces nothing. Request equals limit per rule 7, so this reserves 512Mi and the
plan's steady-state budget moves from ~2.1Gi to ~2.6Gi against a node reporting
under 4GB allocatable. That is the real cost of this decision and it is why 1Gi
was not chosen instead.

The alternative was lowering `hashers.argon2.memory`, which weakens per-hash cost
and edits a file the Compose production stack also loads. Rejected: the point of
argon2 is the memory.

Worth knowing why this survived the proof of concept.
`docker/ory/docker-compose.prod.yml` sets no memory limit on Kratos, so these
argon2 settings had never run against a ceiling until this phase.

Still unresolved: `parallelism: 16` against a `100m` CPU request. The calibration
above was run on a node that was otherwise idle, so the 504ms median is a
best case, not a saturated one.

Decided 2026-09-14, replacing the "recorded rather than fixed" entry of
2026-09-13.

## Nothing rolls Kratos when the secrets it reads are rotated, and a config reload is not proof that a value took effect

Nothing rolls the pod when `kratos-db` changes. Secret values are deliberately
absent from `deploy/kubernetes/dist/`, so a render-time hash would be a hash of
empty strings, and `kapp.k14s.io/versioned` on the Secret would leave old
versions in the cluster holding live credentials. Neither option is taken.

The concrete failure: `deploy/kubernetes/init.sh` regenerates
`kratosWebhookMasterKey`, `scripts/derive-webhook-tokens.py` re-derives both
tokens, and the apply writes the new ones into `kratos-db` and `kanae-config`
together. kanae starts expecting the new token, and because all three hooks set
`response.ignore: false`, registration and every settings change fail if Kratos
is still sending the old one.

That last "if" is where this decision changed. Both of Kratos's `-c` files are
mounted, not environment variables, and Kratos watches them. Patching the
in-cluster `kratos-db` and waiting produced, with no restart and
`restartCount` still 0:

```
"file":"/etc/secrets/kratos.yml","msg":"A change to a configuration file was detected."
"file":"/etc/secrets/kratos.yml","msg":"Configuration change processed successfully."
```

The mount took about 70 seconds to update, which is the kubelet sync period, not
Kratos.

Do not read that log line as "the new value is live". The same test changed
`log.level` from `info` to `debug`, Kratos reported the change processed, and
zero debug lines were logged afterwards, because the logger is built once at
startup. So a reload is per-key, and whether the webhook token specifically takes
effect without a restart is **unproven here**: proving it needs kanae deployed to
receive the hook, which is Phase 7.

Until it is proven, the manual step stands: **restart Kratos after rotating the
webhook tokens.** It is cheap and it is certainly correct. `dsn` is known not to
reload at all, which Ory treats as immutable. Phase 7 meets the same question for
kanae's own config and should settle it for both.

Recorded 2026-09-13, revised 2026-09-14 after the mounted-file test.

## `kratos-config` and `keto-config` are `kapp.k14s.io/versioned`, so neither Deployment carries a checksum

Both pods have to restart when the files they mount change. Kratos caches a
parsed courier template for the life of the process with no invalidation, so an
edited recovery email that reaches the ConfigMap without a rollout keeps going
out with the old body. Keto compiles its namespace definitions at startup, so a
new namespace does nothing until the pod restarts.

The first version of this used `checksum/config` annotations. That is the usual
Helm idiom and it failed here immediately: the first draft hashed three of the
six Kratos files, and the three it missed were the courier templates. Wrapping
the ConfigMap's `data` in a named template and hashing that fixed the omission,
at the cost of a `define` whose only purpose was to be hashed.

`kapp.k14s.io/versioned` removes the problem rather than guarding it. kapp gives
the ConfigMap a per-revision name, `kratos-config-ver-2`, and rewrites every
reference to it, so an edited file produces a new name in the Deployment's volume
and the rollout follows from the pod spec. There is no hash to keep in step with
a file list, because there is no file list. A seventh file cannot be forgotten.

Verified on k3d. Changing one word in `email.subject.gotmpl` moved the
Deployment's volume from `kratos-config-ver-1` to `ver-2` and replaced the pod,
with no checksum annotation anywhere in the chart. An earlier run of that test
appeared to prove the opposite and was wrong: appending a trailing newline
changes nothing, because a YAML block scalar clips trailing newlines, so the
rendered ConfigMap came out byte-identical. Test this with a real edit or not at
all.

The cost is that the Kratos and Keto migration Jobs mount these same ConfigMaps,
so kapp rewrites their references too, and a courier template edit now produces a
new `kratos-migrate` version and re-runs `migrate sql`. That is idempotent and
reports "Migrations already up to date", but it is a blocking wave 4 step on a
change with nothing to do with the schema.

Splitting the ConfigMap would remove that cost, and the split is clean, because
the two readers no longer overlap: the serving pod reads the identity schema, the
jsonnet payload and the courier templates, while the migration Job reads only
`kratos.yml`, now that the pod serves from the copy in its Secret. Confirmed on
k3d that `migrate sql` succeeds with `kratos.yml` as the only mounted file. It
was not done, because the Deployment would then need a checksum back over
`kratos.prod.yml` alone, that being the one file it reads which would no longer
be in any ConfigMap it mounts. One extra resource and one annotation, against one
idempotent Job re-run. Revisit if the Kratos migration ever gets slow enough to
notice.

Neither ConfigMap sets `kapp.k14s.io/num-versions`. It is a retention count,
not a version number: kapp names revisions `kratos-config-ver-1`, `-ver-2` and
upward, monotonically, and keeps the most recent N. A fresh cluster starts at
`ver-1`, and a high number just means the file has changed that many times.

Copying the migration Jobs' `"2"` across was a mistake. Retention on a ConfigMap
is not a housekeeping number, because Kubernetes keeps its own ReplicaSet
history and the two mechanisms do not know about each other. Prune a version an
old ReplicaSet still names and Kubernetes will offer a rollback that cannot
mount:

```
$ kubectl rollout undo deployment/kratos --to-revision=6
MountVolume.SetUp failed for volume "config" : configmap "kratos-config-ver-1" not found
```

The pod sits in `ContainerCreating`, and at the time `maxSurge` was 0, so the
only running Kratos had already stopped. That is an outage with no automatic
recovery, from a command an operator would reasonably reach for.

The annotation is gone rather than tuned. kapp's own default retention is 5,
measured by making four consecutive edits and counting what survived, which is
both more than a Job needs and closer to how far back anyone rolls. Picking a
number here was solving the wrong problem: `kubectl rollout undo` is not the
rollback path in a kapp-managed cluster. Re-apply a previous `dist/` and kapp
produces a new ConfigMap version rather than reaching for a pruned one.

Decided 2026-09-14, replacing the checksum decision of 2026-09-13.

## The mail courier runs inside the Kratos process, which is what costs us a seamless deploy

`serve --watch-courier` runs the courier as a background task in the serving
process. Ory's help text calls the flag a way "to simplify single-instance
setup", and their self-hosting page points multi-instance deployments at a
standalone `kratos courier watch` instead. Multi-instance there means more than
one Kratos replica, which this chart's non-goals rule out, so the flag is the
documented shape for what we actually run.

The worker is the same code either way. `cmd/daemon/serve.go`'s `courierTask`
calls `courier.Watch(ctx, d)`, and that is the same function `courier watch`
reaches through `StartCourier`. Same polling, same dispatch, same backoff. A
split changes process topology and nothing else, so it buys nothing until there
is a second replica to protect the queue from.

The constraint that does bind is that two couriers cannot run at once.
`NextMessages` reads the `status = queued` rows and marks them processing inside
one transaction, but the select takes no row lock, the update carries no status
predicate, and nothing uses `SKIP LOCKED`. Two workers can read the same rows and
both dispatch them, so every mail goes out twice. That is why `replicas` is 1 and
why the rollout is `maxSurge: 0` with `maxUnavailable: 1` rather than the surge
the other Deployments use.

The price is a real one and it is not hidden: with one replica and no surge, the
only serving pod stops before its replacement starts, so login and registration
are unavailable for the length of a deploy. Measured on k3d by polling
`availableReplicas` through a `kubectl rollout restart`, that is 11.7 seconds at
zero. A standalone courier Deployment was built and run to remove exactly that
gap, verified the same way and watching it hold at 1, and then reverted.
Anyone reaching for that again should know what it costs: a second pod carrying
the whole config, and probes with nothing real to probe. `courier watch` serves
no health endpoint at all. `--expose-metrics-port` is the only listener it can be
made to open, it answers `/metrics/prometheus` and 404s `/health/alive` and
`/health/ready`, and what it serves is Go runtime and process metrics with no
courier metric in them. A port opened so that a probe has a target is not a probe.

One property of the combined shape is worth knowing because it has no analogue in
the split. `courierTask` joins the same errgroup as the public and admin servers.
`courier.Work` retries `DispatchQueue` behind `backoff.NewExponentialBackOff()`,
whose default `MaxElapsedTime` is 15 minutes, and on exhaustion it returns the
error, `g.Wait()` returns, and the process exits. A mail backend broken for a
quarter of an hour therefore restarts Kratos. The pod comes back and the restart
is visible in `restartCount`, so this is a crash loop rather than silent
breakage, but it does mean SMTP being down is an authentication outage and not
just a mail outage.

Measured on k3d, idle: the serving pod sits at 48Mi with the courier inside it,
against a 256Mi limit. Split, the pair measured 50Mi and 39Mi, so folding the
courier back in costs nothing at rest and removes a 128Mi request from the
cluster.

Decided 2026-09-14, replacing the split of earlier the same day.
