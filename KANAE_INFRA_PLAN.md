# Kanae infrastructure plan

A build order for putting kanae on Kubernetes properly, replacing the proof of
concept in kanae#221.

Read [POC_FINDINGS.md](POC_FINDINGS.md) first if you have never used Kubernetes.
Its Part 1 explains the Kubernetes words used here (pod, Service, probe, Job,
init container) in plain web development language, and the rest describes the
six bugs that this plan is designed to stop happening again. This document
assumes you have read it and does not repeat those words. The tools this plan
adds on top of Kubernetes are explained in the glossary below.

The work is eleven phases in four layers. Each phase produces something you can
run. You finish a phase by running it, not by passing a linter, and the reason
for that rule is the whole point of the next section.

## Why rebuild instead of patching the proof of concept

The proof of concept works. It boots on a laptop, all five services come up, and
signup works end to end. That is real and it is worth keeping the knowledge from
it. What it does not have is any way for a second person to check it.

Six concrete problems, all verified in this repo at the current commit.

**No check runs automatically.** `mise.toml` defines `helm:lint` and
`helm:check`, and `deploy/helm/HANDOFF.md` says to run `helm:check` in CI.
Nothing in `.github/workflows/` mentions helm, kubeconform, or k3d. Both tasks
only run when somebody remembers.

**Reviewers cannot see what changes in the cluster.** Editing
`deploy/helm/kanae/templates/kanae.yaml` shows up in a pull request as a diff of
Go template code. To know what actually changes in the cluster you have to run
`helm template` yourself and diff the output by hand.

**Two programs render the same file.** `deploy/helm/seed-k8s.sh:247` builds
`config.yml` with `yq`. `deploy/helm/kanae/templates/_helpers.tpl` builds the
same `config.yml` with Helm. HANDOFF.md records that somebody diffed the two
outputs once and calls it "an invariant worth re-checking if either side
changes". A rule that a human has to remember to re-check is not a rule.

**The chart holds copies of files that live elsewhere.**
`deploy/helm/kanae/files/` duplicates `docker/ory/config/**`, `src/schema.sql`,
`config.dist.yml`, and `scripts/seed/**`. `mise run helm:sync` refreshes the
copies and `mise run helm:check` detects drift, but see the first problem.

**Nothing checks the values you pass in.** There is no
`deploy/helm/kanae/values.schema.json`. Misspell a key in a values file and Helm
renders an empty string into the manifest, and the install succeeds.

**Passing every check meant nothing.** `helm lint` and `kubeconform` both passed
cleanly, first try, on a configuration where no container could start. That is
the headline finding in POC_FINDINGS.md. More linting does not fix it.

Notice that five of these are about who can check the work, not about whether
the work is correct. That is the gap this plan closes.

### The two ideas the plan is built on

**The chart is source code. `deploy/k8s/` is the deployment.** Helm is a build
tool here, not the thing that installs. Phase 2 renders the chart to plain
Kubernetes YAML under `deploy/k8s/`, commits it, and that directory is what
`kubectl apply` sends to the production cluster. Nothing runs `helm install`.

Two things fall out of that. Reviewers read Kubernetes rather than Go templates,
because the pull request carries both the template change and the manifest it
produces. And there is no gap between the reviewed artifact and the applied one,
because they are the same file. This arrangement has a name, the rendered
manifests pattern, and the section at the end of Phase 2 covers what it costs.

**Every phase ends by running it.** Each phase below has an exit gate: a command
you run against a real cluster and the output you must see. A phase is not done
when it renders. It is done when it runs.

## Glossary for the tools this plan adds

POC_FINDINGS.md covers Kubernetes itself. These are the other names you will
meet, in the order you meet them.

| Name | What it is |
| --- | --- |
| **dprint** | A code formatter written in Rust that loads per-language plugins. Here it formats YAML through its `pretty_yaml` plugin. Formatting only, no opinions about meaning. |
| **yamllint** | A linter for YAML files. Used here only for the rules a formatter cannot cover, mainly duplicate keys. See the discussion in Phase 1. |
| **kubeconform** | Checks that a Kubernetes YAML file has the fields Kubernetes expects. It checks shape, never meaning. |
| **kube-linter** | Checks rendered Kubernetes YAML against policy rules, such as "this container runs as root" or "this container has no memory limit". |
| **JSON Schema** | A file that describes what a config file is allowed to contain: which keys exist, what type each one is, which are required. `values.schema.json` is Helm's version. |
| **rendered manifests pattern** | Running the templating tool as a build step, committing its plain-YAML output, and deploying that output rather than re-templating at install time. What is in git is exactly what is in the cluster. |
| **drift check** | A CI step that regenerates committed output and fails if the committed copy is stale, so nobody can change a template without also committing the manifest it produces. |
| **`kubectl diff`** | Compares files on disk against what is live in the cluster and prints the difference. The preview you run before `kubectl apply`. |
| **SOPS** | Encrypts the values in a YAML file and leaves the keys readable. That gives you a secrets file you can commit to git and still review, because the diff shows which key changed. |
| **age** | The encryption tool SOPS uses here. Each person has a key pair. You list the public halves in `.sops.yaml` and everybody listed can decrypt. |
| **Atlas** | The database migration tool this repo already uses, pinned in `mise.toml`. You give it the schema you want in `src/schema.sql` and it works out the SQL to get there. |
| **declarative diff** | How Atlas decides what to run. It compares your target schema against the live database and generates the difference. That difference can include `DROP COLUMN`, which is why this plan asks you to read it before it runs. |
| **DDL** | Data Definition Language. The SQL statements that change structure rather than rows: `CREATE TABLE`, `ALTER TABLE`, `DROP COLUMN`. |
| **blake3** | A hash function. Used here to turn one master key into the two webhook tokens Kratos sends to kanae. |
| **backoffLimit** | How many times Kubernetes retries a failed Job before it gives up and reports failure. |
| **cert-manager** | A program that runs inside the cluster, gets TLS certificates from Let's Encrypt, and renews them without anybody doing anything. |
| **CSRF, double-submit** | A defence against another website submitting a form on your behalf. Double-submit means the server sends a token twice, once in the page and once in a cookie, and rejects the request unless both arrive and match. Kratos uses it, so a dropped cookie shows up as a rejected login. |
| **Borg, borgmatic** | Borg is a backup tool. borgmatic is a wrapper that runs it on a schedule from a config file. |

## The layers and phases

| Layer | Phase | What you build |
| --- | --- | --- |
| A. Foundation | 1 | Pinned tools, formatters, linters, a local cluster you create with one command |
| A. Foundation | 2 | Values schema, committed rendered manifests, CI that gates on them |
| B. Platform | 3 | One source of truth per config file, one renderer per generated file, real SOPS keys |
| B. Platform | 4 | Postgres and Valkey, with probes that can pass and storage that survives |
| B. Platform | 5 | The three databases, their tables, and migrations you can review before they run |
| C. Services | 6 | Ory Kratos and Ory Keto |
| C. Services | 7 | The kanae API |
| C. Services | 8 | Ingress, path rewriting, and TLS (finishes after Phase 7) |
| D. Proof | 9 | An automated test that boots the whole stack and signs a user up |
| D. Proof | 10 | Backups you have restored from, resource limits from measurements, runbooks |
| D. Proof | 11 | The production cluster and the first real deploy |

Layers run in order, and inside a layer phases run in order, with one exception
noted at the top of Layer C.

## Rules that apply to every phase

1. **Finish the exit gate before starting the next phase.** The gate is the
   deliverable.
2. **One file is the source of truth for each thing.** If you need the same
   content in two places, generate the second from the first at build time.
3. **One program renders each generated file.** Never two.
4. **Commit the rendered manifests with the change that caused them.**
5. **When a command returns, the cluster is still changing.** Wait for it to
   settle before you conclude anything. See the process note at the end of Part
   3 in POC_FINDINGS.md, where two overlapping commands cost ten minutes.
6. **Write down decisions where the next person will look.** A decision that
   only exists in a pull request comment is lost.

---

# Layer A. Foundation

## Phase 1. Tools and a local cluster

**What you build.** Every tool pinned to an exact version, a formatter and a
linter for the YAML files, and a cluster on your laptop that you create and
destroy with one command each.

**Why it comes first.** Everything else is edited, checked, and run with these
tools. If two people have different Helm versions, they get different rendered
output, and the drift check in Phase 2 fails for reasons that have nothing to do
with the change.

**How it goes.** Three separate jobs, in this order. First pin the versions,
because the rest of the phase is easier once everybody has the same binaries.
Second set up the formatter and the linter, which is where most of the thinking
goes and which the section below explains. Third write the cluster config and
the four mise tasks around it, which is mechanical once you know what shape of
cluster you want.

Expect the cluster work to be the fiddly part. k3d maps ports from the container
running the cluster out to your laptop, and if you get that wrong the cluster
comes up healthy and nothing you do can reach it. Get one port working before
you add the rest.

The versions you pin should be versions you have actually run. Do not copy them
from a blog post. Write the date next to them, because in a year somebody will
want to know whether the pin was a considered choice or an accident.

**What formats and what lints.** These are two jobs and this plan splits them
between two tools.

`dprint` formats, using the `pretty_yaml` plugin. dprint is Rust, the plugin is
Rust compiled to WebAssembly, and formatting is the whole of its job.

The linter is the harder call, so here is the reasoning rather than just the
answer. Linting YAML breaks into rules about layout (indentation, line length,
spacing) and rules about meaning (duplicate keys, values that parse as something
you did not intend). Once dprint owns the file's layout, the layout rules are
not just redundant, they are actively harmful: two tools with opinions about the
same bytes will disagree eventually and you will spend an afternoon on it.

That leaves the rules about meaning, and two of them earn their place here.
A duplicate key in a YAML file is not an error. The last one silently wins, and
neither `kubeconform` nor `kube-linter` will tell you, because the file they see
has already lost the first value. The other is the one where `no` parses as the
boolean false rather than the string "no", which bites Kubernetes YAML often
enough to have a nickname.

`yamllint` is the tool for that, with its layout rules switched off. It is
Python, and this plan otherwise avoids adding a Python step to the infra checks,
so that choice needs defending on two counts.

On speed: `yamllint` over every YAML file in this repo, all 39 of them and 3,728
lines, takes 0.434 seconds including Python interpreter startup. That is
measured, not estimated. The concern about a slow development loop is real in
general and does not apply at this size.

On the alternatives: there are three Rust reimplementations of `yamllint` and
none of them clears the bar this plan sets for everything else. `ryl` is the
strongest, actively maintained, and drop-in compatible with `yamllint`'s config
format, and it has 65 stars and 3 forks and its first commit is a year old.
`yaml-lint-rs` has 7 stars and stopped in February 2026. `yamllint-rs` has 4
stars and two commits. By comparison `yamllint` has 3,447 stars, has been
maintained for ten years, and is what the Kubernetes ecosystem already reaches
for. A plan whose argument is that infrastructure should be auditable cannot put
a one-year-old single-maintainer tool in its foundation layer.

So: `dprint` formats, `yamllint` catches duplicate keys and surprising values,
`kubeconform` checks Kubernetes field types in Phase 2, and `kube-linter` checks
policy in Phase 2. Four tools, four jobs, no overlap.

If a Python dependency in the infra checks is a hard requirement to avoid rather
than a preference, `ryl` is the fallback, and you take on the risk of a young
tool with one maintainer knowingly. Write that down in `deploy/DECISIONS.md`
either way.

### Tasks

- [ ] Pin the versions in `mise.toml` that currently say `latest`: `helm`,
      `kubectl`, `k3d`, `k9s`, `kubeconform`, `sops`, and `age`. Pick the
      versions you have run, and write the date you picked them in a comment.
- [ ] Add `dprint` to `[tools]` in `mise.toml` and write `dprint.json` with the
      `pretty_yaml` plugin configured.
- [ ] Add `yamllint` to `mise.toml` and write `.yamllint.yaml`. Switch off every
      layout rule, because `dprint` owns layout. Leave on `key-duplicates`,
      `truthy`, `octal-values`, and `anchors`.
- [ ] Exclude `deploy/helm/kanae/templates/` from both tools. Those files are Go
      templates and are not valid YAML until Helm renders them. Phase 2 checks
      the rendered output instead, which is the version that matters.
- [ ] Add the mise tasks `k8s:fmt`, `k8s:fmt:check`, and `k8s:lint`, matching the
      shape of the existing `scripts:format` and `scripts:lint` tasks.
- [ ] Write `deploy/k3d/cluster.yaml`, a k3d cluster config file. Put the node
      count, the ports, and the registry settings in this file rather than in
      command-line flags, so the cluster shape is committed and reviewable.
- [ ] Add the mise task `k8s:up`. It creates the cluster from that file and then
      waits until `kubectl get nodes` reports Ready.
- [ ] Add the mise task `k8s:down`. It deletes the cluster and waits for the
      deletion to finish before returning.
- [ ] Add the mise task `k8s:reset`, which runs `k8s:down` then `k8s:up`.
- [ ] Write `.github/workflows/infra.yml`. Run it on pull requests that touch
      `deploy/**` or `mise.toml`. For now it runs `k8s:fmt:check` and the
      existing `scripts:lint`.

### Exit gate

Run these four commands and see these four results.

```
mise run k8s:up        # kubectl get nodes shows one node, STATUS Ready
mise run k8s:fmt:check # exits 0
mise run k8s:lint      # exits 0
mise run k8s:down      # k3d cluster list shows no kanae cluster
```

Then open a pull request that reformats one YAML file badly, and confirm CI
fails on it.

---

## Phase 2. The deployment artifact

**What you build.** A machine-checked description of every value the chart
accepts, and `deploy/k8s/`, the plain Kubernetes YAML that gets applied to
clusters.

**Why it comes second.** Every phase after this one adds manifests. If you build
the review mechanism now, every later change arrives with a readable diff. If
you build it at the end, you have to review eight phases of work at once.

**How the pieces relate.** Two directories, and each has exactly one meaning.

`deploy/helm/kanae/` is source code. Templates and values. You edit it. It is
never applied to anything.

`deploy/k8s/` is the production deployment. Plain Kubernetes YAML with no
templating left in it. You do not edit it, you regenerate it. It is what runs in
production.

```
deploy/
  helm/kanae/          the chart. source. edited by hand
  k8s/                 production manifests. generated. this is what is deployed
```

**There is no `local/` beside it, on purpose.** An earlier draft of this plan had
`deploy/k8s/local/` and `deploy/k8s/production/` side by side, and that is worse
than it looks. Two directories of nearly identical YAML, one disposable and one
holding the real cluster, means every reader has to check which one they are in
before they can trust anything they see, and every local tweak produces a diff in
a directory whose diffs are supposed to mean something. One wrong `kubectl apply`
away from a bad afternoon.

So `deploy/k8s/` means production and nothing else. Local manifests are rendered
on demand into `.k8s-local/`, which is in `.gitignore` and never committed. A
laptop render is a build artifact, not a deployment. CI still renders and
validates the local values on every pull request, so a chart change that only
breaks local rendering is still caught. It just does not leave a file behind.

The directory is called `k8s` rather than `k3s` on purpose. k3s is one
distribution of Kubernetes, and Kapsule is another, and the manifests contain
nothing specific to either. They would apply to any conformant cluster, so naming
the directory after one distribution would suggest a coupling that does not
exist.

**Two more guards, because a generated file that looks editable will get edited.**
Put a `deploy/k8s/README.md` in the directory saying what generates it and what
applies it. Put a banner comment at the top of every generated file saying the
same in one line. Both cost nothing and both catch the person who arrives at one
of these files from a search result with no idea where they are.

**How it goes.** Write the schema first, because writing it makes you read every
value in `values.yaml` and decide what it is actually for. Expect to find one or
two values that nothing reads. Delete those.

Then add the render tasks. The mechanism is small: `helm template` writes to
`deploy/k8s/`, you commit the result, and CI regenerates and compares. Set
the render to split output into one file per resource rather than one long
stream. A 900-line file changes on every edit and tells a reviewer nothing about
what moved. A directory of `deployment-kanae.yaml`, `service-database.yaml`, and
so on gives you a diff that names the resource in the file path.

The habit this creates is the deliverable, not the tooling. From here on, every
change is two things in one commit: the template edit and the manifest it
produces. The reviewer reads the second one, and it is the same bytes the
cluster will receive.

**What this costs, and how to cover it.** Deploying rendered manifests rather
than running `helm install` gives up two things Helm does for you. Both are
worth naming plainly.

You lose `helm rollback`. Git replaces it: the previous manifests are the
previous commit, so `git revert` and re-apply is the rollback. That is more
auditable, because the rollback is a reviewable commit rather than a command
somebody ran, but it is slower under pressure and it needs the person doing it
to be comfortable with git. Rehearse it in Phase 11 rather than learning it
during an outage.

You lose pruning. `kubectl apply` creates and updates, and it does not delete. A
resource you remove from the chart stays in the cluster indefinitely, still
running, invisible in the manifests. This is the sharper of the two problems
because nothing tells you it happened. Cover it by putting a common label on
every resource the chart renders and applying with `--prune` and a selector for
that label, so a resource that vanishes from the render vanishes from the
cluster. Verify pruning works in Phase 9 by removing a resource and confirming
it leaves.

### Tasks

- [ ] Write `deploy/helm/kanae/values.schema.json`. Helm validates values
      against this file on every `helm template`, which is every render, with no
      extra tooling. Give every key a type. Mark as `required` every key that
      has no safe default. Add a `pattern` for anything with a format, including
      `secrets.kratosSmtpUri`, which must match `^smtps?://`. Finding 4 in
      POC_FINDINGS.md is exactly this bug: a placeholder that did not look like
      a URI stopped Kratos from booting.
- [ ] Create `deploy/k8s/` and write `deploy/k8s/README.md` in it: what
      generates this directory, what applies it, and do not edit it by hand.
- [ ] Add the mise task `k8s:render`, which regenerates `deploy/k8s/` from the
      production values by running `helm template`, splitting output into one
      file per resource, with a generated-file banner at the top of each. Delete
      the target directory first, or a resource you removed from the chart
      lingers as a stale file.
- [ ] Add the mise task `k8s:render:local`, which renders the local values into
      `.k8s-local/`. Add `.k8s-local/` to `.gitignore`. A laptop render is a
      build artifact and does not belong in the repository.
- [ ] Add a `app.kubernetes.io/part-of: kanae` label to every resource the chart
      renders, through `_helpers.tpl`. Pruning needs it, and pruning is what
      stops removed resources from living forever in the cluster.
- [ ] Keep Secrets out of `deploy/k8s/`. Everything else renders into it, but a
      rendered Secret holds a base64 credential, and this directory exists to be
      read. Phase 3 decides where Secrets go instead.
- [ ] Add the mise task `k8s:render:check`, which regenerates into a temporary
      directory and fails if the result differs from what is committed. Print
      the diff and the words `run 'mise run k8s:render' and commit the result`,
      matching how `helm:check` already reports drift.
- [ ] Add the mise task `k8s:apply`, which runs `kubectl diff` against
      `deploy/k8s/`, shows you the difference, waits for you to confirm, then
      applies with `--prune` and the label selector. Never let it apply without
      showing the diff first. Add a matching `k8s:apply:local` for `.k8s-local/`
      so the two paths cannot be confused at the command line either.
- [ ] Add `k8s:render:check` to `.github/workflows/infra.yml`, and have CI also
      render the local values into a temporary directory and run `kubeconform`
      over the result. Local rendering stays checked without being committed.
- [ ] Add `kube-linter` to `[tools]` and a `k8s:policy` task that runs it over
      `deploy/k8s/`, and add the task to
      `.github/workflows/infra.yml`. Turn on the check for containers running as
      root. Finding 3 in POC_FINDINGS.md was a container that crashed because it
      ran as root under dropped privileges, and this check names that pattern.
- [ ] Leave kube-linter's resource-limit checks switched off until Phase 10, and
      write the reason in the config file next to the switch. Phase 4 collects
      real numbers and Phase 10 sets limits from them, so between here and there
      every workload would fail that check for a reason you already know about.
      A check that everybody has learned to ignore is worse than no check, which
      is the same argument this plan opens with.
- [ ] Rename `helm:lint` to `k8s:schema`. The current name reads like a quality
      gate. It checks the shape of the YAML and nothing about what the YAML
      does. Give it a name that says so.
- [ ] Move the "Decisions worth not re-litigating" section of
      `deploy/helm/HANDOFF.md` into `deploy/DECISIONS.md`, one decision per
      heading, each with the reason and the date. HANDOFF.md then becomes a
      pointer to it. A handoff document is written once. A decision log is
      appended to.

### Exit gate

Change `kanae.granianWorkers` from 2 to 3 in `deploy/helm/kanae/values.yaml`.
Run `mise run k8s:render`. Run `git diff deploy/k8s/`. The diff should touch one
file, `deploy/k8s/deployment-kanae.yaml`, and show one changed environment
variable.

Then commit only the values change, without the rendered manifests, and confirm
CI fails.

Then, against a running local cluster, run `mise run k8s:apply` and confirm it
prints the same difference `git diff` did before it applies anything. Those two
diffs agreeing is the property this whole phase exists to give you.

---

# Layer B. Platform

## Phase 3. Configuration and secrets

**What you build.** One place that owns each configuration file, and one program
that produces each generated file.

**Why this is the hardest phase.** It is the only phase that deletes more than
it adds, and deleting a working code path always feels wrong. Do it anyway. Two
programs that produce the same file will differ eventually, and the day they
differ is a day somebody spends debugging a service that reads a config nobody
wrote.

**How it goes.** This phase has three parts that are independent of each other,
so you can do them in any order, but do them one at a time and run
`mise run k8s:render` after each. The render must not change. That is your
safety net for the whole phase.

The first part removes the copies under `deploy/helm/kanae/files/`. Helm cannot
read files outside the chart directory, which is why the copies exist. The fix
is to move the originals in rather than to keep copying them out, and then point
the Docker Compose bind mounts at the new location. Compose can mount from
anywhere.

The second part cuts `seed-k8s.sh` down. Read it before you change it. It does
four things today: it generates secret values, it derives two tokens, it renders
`config.yml` with `yq`, and it pushes Secrets into the cluster with `kubectl`.
Only the first two survive. The chart does the rest.

The third part is the smaller cleanup: real age keys, the service names declared
in one place, and the image pull secret.

Secrets are the one place where the property from Phase 2 does not hold. Every
other resource is committed in `deploy/k8s/` exactly as the cluster receives it.
A Secret cannot be, because a rendered Secret is a base64 credential and that
directory exists to be read. Encrypting the rendered Secret and committing it
does not work either: SOPS generates a fresh data key on each encryption, so the
same content encrypts to different bytes every time and the drift check fails on
every run for no reason.

So Secrets take a different route, and it is worth stating exactly what it is.
`deploy/helm/secrets-prod.enc.yaml` holds the values, encrypted with SOPS, keys
in plaintext so the diff still shows which one changed. At apply time they are
decrypted in memory, rendered by the same chart that renders everything else,
and piped into `kubectl`. Nothing lands on disk in the clear and there is still
only one renderer. What you give up is that Secrets are the one part of the
deployment you cannot read out of git, which is the correct trade for a
credential.

Take the pull secret seriously even though it looks trivial. Finding 6 in
POC_FINDINGS.md is the failure it prevents, and that one is unusually nasty
because the obvious way to test it gives you the wrong answer. Running
`docker pull` on the same tag succeeds from your laptop, which has credentials
saved from a login the cluster never saw.

### Tasks

- [ ] Move the canonical Ory configs into the chart. Right now
      `docker/ory/config/**` is the source and `deploy/helm/kanae/files/` is a
      copy kept in step by `mise run helm:sync`. Reverse it: make the chart
      directory the source, and point the Docker Compose bind mounts in
      `docker/docker-compose.yml` at the chart directory. Do the same for
      `src/schema.sql`, `config.dist.yml`, and `scripts/seed/**`.
- [ ] Delete the `helm:sync` and `helm:check` tasks from `mise.toml`. Once there
      are no copies, there is nothing to sync and nothing to check.
- [ ] Cut `deploy/helm/seed-k8s.sh` down to one job: generate secret values and
      write them to a plain YAML file for SOPS to encrypt. Delete the `yq`
      config rendering at line 247 and the `kubectl create secret` calls at
      lines 310 to 334. Rename it `deploy/helm/gen-secrets.sh`, because a script
      named `seed` that creates secrets and a Job named `seed` that creates test
      members are two different things with one name.
- [ ] Delete the `secrets.create` value and the branch it controls. The chart
      now always renders the Secrets from values. There is one path, so no
      reader has to work out which one ran.
- [ ] Extend `k8s:apply` from Phase 2 with the Secret step: decrypt
      `deploy/helm/secrets-prod.enc.yaml` with SOPS, pass the result to
      `helm template --show-only templates/secrets.yaml`, and pipe that into
      `kubectl apply`. Keep it out of `deploy/k8s/` and add the file to the
      repository's list of things never to decrypt to disk.
- [ ] Keep the property that made `seed-k8s.sh` safe to re-run: if a secret
      already has a value, keep it. One of those keys encrypts user data at
      rest, and regenerating it makes existing accounts unreadable.
- [ ] Have `gen-secrets.sh` call `scripts/derive-webhook-tokens.py` rather than
      recomputing the blake3 tokens itself. One implementation.
- [ ] Replace the four placeholder age keys in `.sops.yaml`. All four currently
      read `REPLACE`.
- [ ] Declare the fixed Service names once. Add a `serviceNames` block to
      `values.yaml` holding `kanae`, `database`, `valkey`, `kratos`, and `keto`,
      and reference it through `_helpers.tpl` everywhere. The names stay fixed,
      for the reason HANDOFF.md gives, but they become a documented list in one
      file instead of strings typed into ten templates.
- [ ] Add a check to `k8s:policy` that fails if any file in
      `deploy/helm/kanae/templates/` contains a hardcoded `database:5432` or
      `kanae:8000`.
- [ ] Add `imagePullSecrets` to `values.yaml` and to every pod spec.
      `ghcr.io/ucmercedacm/kanae` is a private package, and nothing in `deploy/`
      currently mentions a pull secret. Finding 6 in POC_FINDINGS.md is what
      happens without one, and it is nasty because `docker pull` on your laptop
      succeeds using credentials the cluster does not have.

### Exit gate

Run `mise run k8s:render`. The rendered output must not change, because none of
this phase changes what the cluster gets. That is the point: a refactor with an
empty diff in `deploy/k8s/` is a refactor you can trust.

Then run `grep -r 'files/' deploy/helm/kanae/templates/` and confirm every match
reads a file that has no copy anywhere else in the repo.

---

## Phase 4. Postgres and Valkey

**What you build.** The two services that hold data. Postgres holds all three
databases. Valkey is a cache and can be thrown away.

**Why they come before everything else.** Kratos, Keto, and kanae all connect to
Postgres when they start. If Postgres is not there, none of them start, and you
cannot test any of them.

**How it goes.** Do Postgres first and completely, then Valkey, which is a much
smaller job. Get Postgres to Ready before you write anything else, because a
Postgres that is not Ready makes every later failure look like a different
problem.

Two changes in this phase reverse decisions the proof of concept made, and both
are about what happens when something goes wrong rather than when it goes right.

The readiness probe is the first. The current one runs a checksum query copied
from the Docker Compose healthcheck, and Finding 1 in POC_FINDINGS.md is that
copy failing in a way that took down the entire deployment. The lesson people
usually take from it is "escape the dollar sign correctly". The better lesson is
that a readiness probe should be the simplest thing that can answer the
question, because everything downstream depends on it being right. Corruption
checking is a good idea and belongs somewhere that cannot stop the database from
serving traffic.

The Service type is the second, and it follows from the first. A headless
Service publishes no DNS record at all while its pod is not Ready. So a probe
that wrongly reports not-Ready does not degrade the system, it makes the name
`database` stop existing, and every service in the stack fails at once with a
DNS error that points nowhere near the cause. A normal ClusterIP Service in the
same situation gives you a connection refused against a name that resolves,
which points at the right pod. One replica means headless buys nothing to offset
that.

Do not set resource requests or limits in this phase. Collect the numbers and
leave the decision to Phase 10. Guessed limits are worse than absent ones,
because a guessed memory limit gets a pod killed under load at the exact moment
you need it.

### Tasks

- [ ] Rewrite the Postgres readiness probe as `pg_isready` and nothing else.
      The current probe copies a checksum query out of the Docker Compose
      healthcheck. Finding 1 in POC_FINDINGS.md is that copy failing, and the
      failure took the whole stack down. A readiness probe answers one question,
      which is whether this pod can take traffic. Whether the data is corrupt is
      a different question and belongs in a separate CronJob that alerts. Keep
      the checksum query. Move it.
- [ ] Change the `database` Service from headless to a normal ClusterIP Service.
      A headless Service publishes no DNS record at all while the pod is not
      Ready, so a broken probe becomes `NXDOMAIN` in every service at once. With
      ClusterIP the name still resolves and you get a connection refused instead,
      which points at the right pod. There is one replica, so headless buys
      nothing here.
- [ ] Set an explicit non-root `runAsUser`, `runAsGroup`, and `fsGroup` on the
      Valkey pod. Finding 3 in POC_FINDINGS.md is Valkey crash-looping with
      `chown: .: Operation not permitted`, because its startup script tries to
      take ownership of its data directory when it starts as root, and the chart
      had removed the privilege that needs. Starting as the right user means the
      script skips that step.
- [ ] Move the Retain-policy StorageClass out of a comment. It currently lives
      as a `kubectl apply` block inside a comment in
      `deploy/helm/kanae/templates/postgres.yaml`. Put it in
      `deploy/cluster/storageclass.yaml` and add a step for it in Phase 11. It
      is cluster-wide setup, not part of a release, so it stays out of the
      chart. It also matters: the stock `scw-bssd` class deletes the underlying
      volume when you delete the claim.
- [ ] Keep `helm.sh/resource-policy: keep` on the Postgres claim.
- [ ] Add the mise task `k8s:measure`, which runs `kubectl top pod` and writes
      the result to a file. Do not set resource requests yet. You set them in
      Phase 10 from these numbers.

### Exit gate

With a cluster up and the chart installed:

```
kubectl -n kanae get pods            # database and valkey both 1/1 Running
kubectl -n kanae exec deploy/valkey -- valkey-cli ping    # PONG
kubectl -n kanae delete pod database-0                    # then wait
kubectl -n kanae exec database-0 -- psql -c '\l'          # three databases still there
```

Deleting the pod and finding the data intact is the part that matters. It is the
only proof that the volume is doing its job.

---

## Phase 5. Databases and migrations

**What you build.** The `kanae`, `kratos`, and `keto` databases, their tables,
and a way to see what a migration will do before it does it.

**Why it needs its own phase.** kanae starts fine against a database with no
tables and then fails on every request. Migrations are also the one part of this
system that can destroy data, so they get the most review.

**How it goes.** Start with the database creation Job, because the other two
kinds of migration have nothing to run against until the `kratos` and `keto`
databases exist. Then the kanae schema through Atlas, then the two Ory
migrations, which are ordinary commands the Ory images already ship.

The database creation is worth a careful look. Today it is a script mounted into
`/docker-entrypoint-initdb.d/`, and Postgres runs scripts in that directory only
when the data directory is empty. On a fresh volume it works. On an existing
volume it does nothing, silently, and you find out when Kratos cannot reach its
database. A Job that can run twice safely does not have that failure mode.

The Atlas part needs the most thought and the least code. Atlas is declarative:
you tell it the schema you want in `src/schema.sql` and it works out the SQL to
get from the current database to that. Convenient, and it means a column you
delete from that file becomes a `DROP COLUMN` that runs without anybody reading
it. The dry-run job in the task list exists to put that statement in front of a
human first. It is the cheapest safety measure in this plan.

While this phase runs you will see the kanae pod sitting in `Init:Error` with a
climbing restart count. Nothing is wrong. Its init container checks for a table
that does not exist yet, exits non-zero, and Kubernetes retries it on a growing
delay until the migration lands. Knowing that in advance saves an hour.

### Tasks

- [ ] Replace the initdb script with an idempotent Job. `files/init.sh` creates
      the `kratos` and `keto` databases and the `pg_trgm` extension, and Postgres
      only runs scripts in `/docker-entrypoint-initdb.d/` when the data directory
      is empty. On an existing volume it silently never runs. A Job that issues
      `CREATE DATABASE IF NOT EXISTS`-shaped statements runs correctly every
      time.
- [ ] Keep migrations as Jobs rather than init containers. Init containers run
      once per pod, so with more than one replica two copies of a schema
      migration race each other. Jobs run once per deploy.
- [ ] Strip the Helm hook annotations off the migration Jobs. Nothing reads them
      any more. Hooks are executed by `helm install` and `helm upgrade`, and
      neither runs in this design, so a hook annotation on an applied manifest is
      an inert comment that misleads whoever reads it next.
- [ ] Give each migration Job a name that includes a content hash of the schema
      it applies, and set `ttlSecondsAfterFinished` so finished Jobs clean
      themselves up. A Job's pod template is immutable, so re-applying an
      unchanged Job name fails, and applying the same name with new contents
      fails too. A name that changes when the schema changes gets you a new Job
      exactly when there is new work, and a harmless no-op when there is not.
- [ ] Adopt a forward-only migration policy and write it in
      `deploy/DECISIONS.md`. Rolling the manifests back with `git revert` returns
      the code to the previous version and leaves the database migrated, because
      nothing un-runs a migration. Since Atlas applies a declarative diff that
      can drop a column, a rollback after a destructive migration does not bring
      the column back. The dry-run review below is where destructive changes get
      caught, and it is the only place.
- [ ] Add a CI job that runs `atlas schema apply --dry-run` against a scratch
      Postgres on any pull request touching `src/schema.sql`, and posts the DDL
      as a comment. Atlas compares the declarative schema against the database
      and writes the difference, which can include `DROP COLUMN`. A reviewer
      should read that statement before it runs, not after.
- [ ] Keep passing arguments straight to the atlas entrypoint. Do not wrap the
      command in `sh -c`. Finding 2 in POC_FINDINGS.md is a container image that
      ships no shell, and the chart cannot check whether an image has one.
- [ ] Keep every startup gate single-shot. No `until` loops and no
      `for i in $(seq ...)` inside a container. Kubernetes already retries a
      failed init container with a backoff, so a loop inside duplicates it. An
      earlier unbounded `until` loop in these Jobs could never exit non-zero, so
      `backoffLimit` never tripped and a stuck Postgres hung the whole upgrade.
- [ ] Add the Ory migration Jobs: `kratos migrate sql` and `keto migrate up`.

### Exit gate

Apply to an empty cluster. All migration Jobs reach `Complete`. Then run
`mise run k8s:apply` again with nothing changed, and confirm it is a no-op
rather than an error: the Job names have not changed, so there is no new work.
Then:

```
kubectl -n kanae exec database-0 -- psql -d kanae -c '\dt'   # kanae tables
kubectl -n kanae exec database-0 -- psql -d kratos -c '\dt'  # kratos tables
kubectl -n kanae exec database-0 -- psql -d keto -c '\dt'    # keto tables
```

While the migration Jobs are running, expect the kanae pod to show `Init:Error`
with a climbing restart count. That is the design. Its init container checks for
a table that does not exist yet, fails, and Kubernetes retries it with a growing
delay until the migration lands.

---

# Layer C. Services

Phases 6 and 7 touch different files and different people can work on them at
the same time. Phase 8 can be written alongside them, but it cannot be finished
until Phase 7 is, because its exit gate sends a request through the Ingress to a
running API. None of the three can finish before Layer B does.

## Phase 6. Ory Kratos and Ory Keto

**What you build.** The two services that answer "who is this person" (Kratos)
and "what is this person allowed to do" (Keto).

**Why they come before kanae.** They do not, strictly. Neither one is contacted
by kanae at startup. They are first in this layer because Kratos is the fussier
of the two about its configuration, and it is easier to get it right on its own
than while also debugging the API.

**How it goes.** Keto is close to mechanical: mount two config files, run the
migration from Phase 5, check it answers. Budget your time for Kratos.

Kratos validates its whole configuration at startup and refuses to boot if any
part of it is wrong, including parts nothing will use. Finding 4 in
POC_FINDINGS.md is exactly that. A local run has no mail server, so the setup
script filled the mail server setting with a throwaway string, and Kratos
rejected it because it was not shaped like a URI and stopped. The value did not
have to work. It had to parse.

The other thing that will cost you time is cookies, and it is worth understanding
before you hit it rather than after. Kratos issues its session and CSRF cookies
with the Secure flag unless it is told otherwise, and a Secure cookie is dropped
on a plain `http://` connection. Locally there is no TLS, so the cookie
disappears, the CSRF check on the next request fails because the token that
should have come back in a cookie did not, and login fails with an error about
CSRF that has nothing to do with CSRF being misconfigured. The `insecureCookies`
value exists for that and must stay off in production.

Test that from inside the cluster, not through a port-forward. `curl` treats
`127.0.0.1` as a secure context and will keep a Secure cookie there, so a
port-forwarded test can pass while the real in-cluster path fails.

### Tasks

- [ ] Mount `kratos.prod.yml`, `identity.schema.json`, `keto.yml`, and
      `namespaces.keto.ts` as ConfigMaps rendered from the canonical files
      established in Phase 3.
- [ ] Keep probes on `wget`. The Ory images ship it and do not ship `curl`.
      Check which binary an image has before you write a probe for it. This bug
      appeared three times while writing the proof of concept.
- [ ] Test the cookie setting against a running Kratos. `ory.insecureCookies`
      exists because Kratos issues Secure cookies unless it runs with `--dev`,
      and a Secure cookie is dropped on a plain `http://` request to a
      non-localhost host, which breaks every browser self-service flow at the
      CSRF check. HANDOFF.md says this was worked out from reading the config
      schema and never observed. Observe it.
- [ ] Watch out for one trap when you test that. `curl` treats `127.0.0.1` as a
      secure context, so a probe through `kubectl port-forward` can succeed
      while the same request from inside the cluster to `http://kratos:4433`
      fails. Test from inside the cluster.
- [ ] Lower `max_conns` in the Kratos and Keto database connection strings from
      20 to 5. Kratos at 20, Keto at 20, and kanae's asyncpg pool at its
      default of 10 is up to 50 connections against a Postgres sized for a 4 GB
      node, and stock Postgres allows 100. Write the arithmetic in
      `deploy/DECISIONS.md`.
- [ ] Note that the chart mounts `kratos.prod.yml` while the Compose stack seeds
      against `kratos.yml`. A local Kubernetes run therefore exercises a
      combination the Compose stack never has. Decide whether that is what you
      want, and write down the answer.

### Exit gate

Both pods `1/1 Running`. From a throwaway pod inside the cluster:

```
wget -qO- http://kratos:4433/health/ready         # {"status":"ok"}
wget -qO- http://keto:4466/health/ready           # {"status":"ok"}
```

The webhook from Kratos into kanae cannot be tested here, because kanae does not
exist yet. Phase 9 tests it.

---

## Phase 7. The kanae API

**What you build.** The API itself. Everything in Layers B and C exists to
support this one service.

**How it goes.** Most of this phase is configuration rather than Kubernetes. The
pod spec is the simplest in the chart: one container, one init container, no
storage. What takes the time is getting `config.yml` right and getting the
process to behave like a container process.

The config is rendered as an overlay on `config.dist.yml` rather than as a
second copy of it. That is worth keeping. A key added to `config.dist.yml`
arrives with its documented default instead of quietly going missing, which is
what a second copy would do. The pod template also carries a checksum of the
rendered config so that changing the config restarts the pod. Compute that
checksum from the same bytes the ConfigMap holds, or it stops matching the first
time the overlay grows a key, and then config changes stop restarting anything.

The behaviour fix is `_is_docker()` in `src/core.py:166`. It decides whether
kanae writes logs to standard output or to files, by checking for `/.dockerenv`
and for the string `docker` in `/proc/self/cgroup`. Kubernetes runs containers
under containerd, where neither is true, so kanae writes log files. The chart
currently works around it by mounting a writable directory at `/kanae/logs` for
files nothing ever reads, while `kubectl logs` shows almost nothing. Fix the
check, then delete the mount. This is the one task in the phase that changes
application code rather than deployment code.

Two settings are easy to leave wrong because both defaults are correct for a
laptop. `allowedOrigins` defaults to the Vite dev server, so with the default
the browser refuses every request coming from `ucmacm.dev`. The rate limiter
should stay on in production and off for local seeded runs, for the reason in
Finding 5 of POC_FINDINGS.md.

### Tasks

- [ ] Render `config.yml` as an overlay on `config.dist.yml` rather than
      maintaining a second copy. This is how the proof of concept does it and it
      is right: a key added to `config.dist.yml` arrives with its documented
      default instead of being missing.
- [ ] Keep the `checksum/config` annotation on the pod template so that changing
      the config restarts the pod. Compute it from the same bytes the ConfigMap
      holds. A checksum computed from anything else stops matching the moment
      the overlay grows a key.
- [ ] Keep the single init container that checks the schema exists. One query,
      one attempt, exit non-zero if the table is missing.
- [ ] Change the readiness probe from `exec` to `httpGet` on `/`, the route
      `src/routes/index.py` already serves. It currently runs
      `sh -c "curl -fsS --max-time 2 http://127.0.0.1:8000"`, which depends on
      the image shipping both a shell and `curl`, neither of which the chart can
      check for. The kubelet performs an `httpGet` probe itself and needs
      neither. No new route is required.
- [ ] Fix `_is_docker()` at `src/core.py:166`. It checks for `/.dockerenv` and
      for the string `docker` in `/proc/self/cgroup`, and neither holds under
      containerd, which is what Kubernetes uses. As a result kanae writes log
      files instead of writing to standard output, and the chart mounts an
      `emptyDir` at `/kanae/logs` purely so it has somewhere to write. Nothing
      reads those files. Fix the check, then delete the mount.
- [ ] Set `kanae.allowedOrigins` to the real frontend origin. The default in
      `config.dist.yml` is the Vite dev server, which is right on a laptop and
      wrong in a deployment: with it, the browser refuses every request from
      `ucmacm.dev`.
- [ ] Leave the rate limiter on in production and off for local seeded runs.
      Finding 5 in POC_FINDINGS.md is the seed script hitting the 10 requests
      per minute limit on `GET /members/me` at member 11, and reporting it as
      `did not resolve an identity`, which says nothing about rate limiting.

### Exit gate

From a throwaway pod inside the cluster:

```
wget -qO- http://kanae:8000/          # 200
```

Then `kubectl -n kanae logs deploy/kanae` shows that request. If the log is
empty, `_is_docker()` is still wrong and the lines went into a file instead.
That check matters more than the 200 does, because a 200 with no logs is a
service you cannot debug once it is in production.

---

## Phase 8. Ingress and TLS

**What you build.** The route from the public internet to the right service.
Requests to `/auth` go to Kratos with the prefix stripped. Everything else goes
to kanae.

**When it can finish.** Write it whenever. Finish it after Phase 7, because its
exit gate sends a request all the way through to a running API.

**How it goes.** The routing is two Ingress objects and the reason for two is
the whole difficulty of the phase. HAProxy's path-rewrite setting applies to
every path in the object it is attached to, and only the Kratos route may have
`/auth` removed from it. Kratos generates URLs that carry the `/auth` prefix but
serves its own routes at the root, so without the rewrite every login and signup
flow returns 404, and with the rewrite applied too broadly the API loses the
first segment of every path. One object per rewrite rule is the only arrangement
that works.

Test it from outside the cluster. A `kubectl port-forward` opens a tunnel
straight to the pod and never touches the Ingress controller, so it cannot tell
you anything about whether the rewrite is right. This is the same shape of
mistake as the `docker pull` trap in Finding 6: a convenient check that answers
a different question than the one you asked.

The TLS task changes an existing decision, so read it as a proposal rather than
an instruction. Certificates today come from certbot on a server, assembled into
a file that HAProxy reads. That works. What it does not do is tell anybody when
the certificate expires, and renewal depends on a job on a machine that a
graduating student set up. cert-manager keeps the certificate in the cluster as
a Secret and renews it on its own, and `kubectl get certificate` answers the
expiry question in one command. Decide it deliberately and write down which way
you went.

### Tasks

- [ ] Keep two Ingress objects rather than one. The
      `haproxy.org/path-rewrite` annotation applies to every path in the object
      it is attached to, and only the Kratos route may have `/auth` removed.
      Kratos generates URLs carrying that prefix but serves its routes at the
      root, so without the rewrite every self-service flow returns 404.
- [ ] Move TLS into the cluster with cert-manager. Certificates currently come
      from certbot assembled into a combined PEM file that the HAProxy config
      references, which means renewal is a task on somebody's machine and the
      expiry date is not visible anywhere you would look. cert-manager stores the
      certificate as a Secret and renews it on its own, and `kubectl get
      certificate` tells you when it expires. This changes an existing decision,
      so record the change in `deploy/DECISIONS.md`.
- [ ] Test through the Ingress, never through `kubectl port-forward`. A
      port-forward connects straight to the pod and skips the Ingress
      controller, so it cannot catch a broken path rewrite.

### Exit gate

From outside the cluster, against the local hostname you configured in
`deploy/k3d/cluster.yaml`:

```
curl -sk https://<host>/                                        # 200 from kanae
curl -sk https://<host>/auth/self-service/login/browser         # a login flow, not 404
```

A 404 on the second command means the rewrite is wrong.

---

# Layer D. Proof and operations

## Phase 9. The end-to-end test

**What you build.** One script that starts from nothing, brings up the whole
stack, signs a user up, and checks the user exists. Then CI runs it.

**Why this is the most valuable phase in the plan.** Signup crosses four
services: the browser talks to Kratos, Kratos creates the identity, Kratos calls
a webhook back into kanae, and kanae writes a member row. A break anywhere in
that chain looks like "signup is broken" with no clue where. This test is the
only thing that exercises the whole chain, and no amount of schema validation
substitutes for it.

**How it goes.** Build the script in two passes. The first pass gets the
mechanics working: create a cluster, render, apply, wait for everything, tear
down,
and always tear down even when it failed. Get that reliable before you write a
single assertion, because a test harness that leaves clusters lying around when
it fails will waste more of your time than the bugs it finds.

The second pass adds the assertions, and this is where the phase earns its
place. Waiting for pods to be Ready is not a test. Every pod was Ready in the
proof of concept while the stack was unusable. The assertions have to follow the
signup chain: send a signup request to Kratos, confirm Kratos created an
identity, confirm the webhook reached kanae, and confirm the new member is
readable through the API. Four services, one request path, one test.

Then break it on purpose. Install with the wrong database password and confirm
the script fails. A test that has never failed is a test you have no reason to
believe, and this one is going to be the gate on every infrastructure change
from here on.

Spend real effort on the failure output. POC_FINDINGS.md found that failures in
this system surface a long way from their cause, with a bad health check
presenting as total DNS failure and a rate limit presenting as an authentication
error. A test that fails with only "timed out waiting for pods" hands the next
person the same puzzle. Dump the events and the logs of everything that is not
Ready.

The seed script is the loose end. It gets partway through fifteen members and
stalls, and turning off the rate limiter moved it further without finishing it.
Find the actual cause. Removing one more limit until it passes is how the first
version of this got into trouble.

### Tasks

- [ ] Write `deploy/test/e2e.sh`. It creates a k3d cluster, builds and imports
      the images, renders the local values with `k8s:render:local` and applies
      them, waits for every
      workload to be Ready with a timeout, runs the assertions below, and
      deletes the cluster whether it passed or failed.
- [ ] Assert more than "the pods are Ready". Ready pods were true in the proof of
      concept while the stack was unusable. Assert that a signup request to
      Kratos mints an identity, that kanae received the webhook, and that
      `GET /members/me` returns the new member.
- [ ] Fix the seed script so it completes all fifteen members. It currently gets
      partway through, fails, retries, and gets a little further. Turning off the
      rate limiter moved it past one blockage but did not finish it. Find the
      real cause rather than removing another limit.
- [ ] Add a negative test. Apply with a deliberately wrong database password and
      confirm `e2e.sh` fails. A test that has never failed proves nothing about
      the thing it tests.
- [ ] Test pruning. Remove a resource from the chart, re-render, apply, and
      confirm the resource leaves the cluster. This is the failure mode the
      rendered manifests pattern introduces, per Phase 2, and it is silent
      without a test.
- [ ] Add `e2e.sh` to `.github/workflows/infra.yml`, on pull requests touching
      `deploy/**` and on a nightly schedule. GitHub runners can run k3d.
- [ ] Have the script print, on failure, the output of
      `kubectl get events --sort-by=.lastTimestamp` and the logs of every pod
      that is not Ready. The proof of concept found that failures surface far
      from their cause, so the failure output has to carry enough to find the
      cause.

### Exit gate

`bash deploy/test/e2e.sh` goes from no cluster to a signed-up member and exits
0. Break the database password on purpose, run it again, and it exits non-zero
with the Postgres authentication error in its output.

---

## Phase 10. Backups, limits, and runbooks

**What you build.** The operational parts. None of them are needed to make the
stack work, and all of them are needed before you trust it with real data.

**How it goes.** Backups first, because they are the only item here that
protects something you cannot get back.

Start by checking what the backup image can actually do, before writing any
config. Borg 1.x cannot write to S3-compatible storage at all. Only Borg 2.x
can, through a component called borgstore. The chart currently schedules a
backup against a repository setting that may be impossible for the image it
runs, and nobody has checked which version is in there. The credential variable
names are a guess too, recorded as one in HANDOFF.md. Both are one command to
resolve and neither has been run.

Then restore from a backup. Not "confirm the backup Job succeeded", restore it
into a scratch database and compare row counts against the source. A backup
nobody has restored from is a file of unknown contents. Do it by hand once so
you understand the steps, then write it as a script so it can be done again
under pressure.

Resource limits come from the numbers Phase 4 collected. Set requests near the
steady state you measured and limits with room above the peak. Resist the urge
to round to memorable numbers.

The runbook is the last item and the one most likely to be skipped. Write it
anyway, keyed on the exact text of the error somebody will see, because that is
what they will paste into a search box at the moment they need it. The six
findings in POC_FINDINGS.md are six real error messages that will happen again,
and each of them looked like a different problem than it was.

### Tasks

- [ ] Check which Borg version the backup image ships. Borg 1.x cannot write to
      S3-compatible storage at all. Only Borg 2.x can, through `borgstore`.
      `deploy/helm/kanae/templates/backup-borgmatic.yaml` schedules a backup
      today against a repository setting that may be impossible for the image.
- [ ] Write the borgmatic config ConfigMap. The chart expects a ConfigMap named
      by `backup.configMap` and the config itself does not exist yet.
- [ ] Confirm the backup credential environment variable names against the
      image. HANDOFF.md records that `AWS_ACCESS_KEY_ID` and
      `AWS_SECRET_ACCESS_KEY` are a guess, based on what rclone, borgstore, and
      boto read.
- [ ] Restore from a backup into a scratch database and compare row counts
      against the source. A backup you have never restored from is not a backup.
      Do this once by hand, then write it as a script.
- [ ] Set resource requests and limits from the numbers `k8s:measure` collected
      in Phase 4, not from guesses. Set requests near the observed steady state
      and limits with headroom above the observed peak.
- [ ] Switch on kube-linter's resource-limit checks, which Phase 2 left off
      until there were numbers to satisfy them.
- [ ] Write `deploy/RUNBOOK.md`, keyed on exact error strings. Start with the
      six findings in POC_FINDINGS.md, since each one is a real error message
      somebody will see again: `Init:Error`, `ImagePullBackOff`,
      `chown: .: Operation not permitted`, `did not resolve an identity`, a
      Kratos boot failure on a malformed SMTP URI, and a name that does not
      resolve.
- [ ] Document that restart counts climbing during startup are normal here.
      Somebody reading `kubectl get pods` needs to know that before they can
      debug anything.

### Exit gate

A scheduled backup Job completes on its own. Restore from it into a scratch
database, and the row counts match the source.

---

## Phase 11. Production

**What you build.** The real cluster, and the first deploy onto it.

**Why it is last.** Everything above is rehearsal for this, and every step here
is easier to debug on a laptop first.

**How it goes.** The order matters more here than anywhere else, because some of
these steps are hard to undo once data exists.

Cluster-wide setup comes before the first install: the storage class, the
ingress controller, cert-manager, and the image pull secret. The storage class
in particular has to exist before you install anything, because the Postgres
claim names it and a claim that names a class which does not exist waits
forever without a useful error. It also has to be the Retain variant. The stock
Scaleway class deletes the underlying volume when the claim goes away, which
turns a routine mistake into data loss.

Then secrets, then the install. Generate the production secrets, encrypt them,
commit the encrypted file, and put the CI key in a repository secret. Keep the
property that re-running the generator preserves existing values. One of those
keys encrypts user data at rest, and regenerating it makes every existing
account unreadable, with no way back.

Once it is installed and before anyone depends on it, do a rollback on purpose.
Upgrade to something harmless, roll back, roll forward. The first rollback you
ever perform should not be during an outage at 2am, and the forward-only
migration policy from Phase 5 is the thing you are really testing: you want to
find out now what a rollback does and does not undo.

Keep whatever serves the API today running until signup works against the new
cluster. Cutting over is a DNS change, which means it is also a DNS change back.

### Tasks

- [ ] Decide between Scaleway Kapsule and k3s on a rented server. The proof of
      concept targets Kapsule with the free Mutualized control plane, at roughly
      €21 a month for a DEV1-M node, block storage, and an IPv4 address. Write
      the decision and its cost in `deploy/DECISIONS.md`.
- [ ] Create the cluster with its own ingress controller turned off, so it does
      not install nginx or traefik alongside HAProxy.
- [ ] Apply `deploy/cluster/storageclass.yaml` from Phase 4. Do this before the
      first install, because the Postgres claim names that class.
- [ ] Install the HAProxy ingress controller.
- [ ] Install cert-manager and create the issuer.
- [ ] Create the image pull secret for `ghcr.io/ucmercedacm/kanae`.
- [ ] Publish the `kanae-seed` image. `docker/Dockerfile.seed` exists and
      `mise run seed:image` builds it locally, but nothing pushes it to ghcr.
- [ ] Generate the production secrets with `gen-secrets.sh`, encrypt with SOPS,
      commit the encrypted file, and put the CI age key in a GitHub Actions
      repository secret. Apply them before the first `k8s:apply`, or every pod
      that mounts them stays pending.
- [ ] Point DNS at the cluster.
- [ ] Apply `deploy/k8s/` with `mise run k8s:apply`. Read the
      `kubectl diff` it prints before you confirm. On a first install that diff
      is every resource, which is the one time it is not worth reading closely.
- [ ] Rehearse a rollback while nobody is using it. Change something harmless,
      render, apply, then `git revert` the commit, re-render, and apply again.
      The first rollback you ever perform should not be during an outage, and
      this one is a git operation rather than a single Helm command, so it is
      worth having done once with time to spare.
- [ ] Cut over from whatever serves the API today, and keep the old thing
      running until signup works against the new one.

### Exit gate

Sign up through the real frontend at `ucmacm.dev`, against the real API domain.
The new member is readable through the API. Then roll back one release and roll
forward again, and confirm signup still works.

---

# Checklist by phase

Tick a phase only when its exit gate has passed on a real cluster.

**Layer A. Foundation**

- [ ] Phase 1. Tools pinned, dprint and yamllint wired up, `k8s:up` and
      `k8s:down` work, CI runs both checks
- [ ] Phase 2. `values.schema.json` written, `deploy/k8s/` committed and
      applyable, local renders gitignored, CI fails on a stale render

**Layer B. Platform**

- [ ] Phase 3. No file in the repo is a copy of another, one program renders
      each generated file, real age keys in `.sops.yaml`
- [ ] Phase 4. Postgres and Valkey Ready, data survives deleting the Postgres
      pod
- [ ] Phase 5. Three databases with their tables, a written forward-only
      migration policy, schema changes reviewed as DDL before they run

**Layer C. Services**

- [ ] Phase 6. Kratos and Keto Ready, cookie behaviour observed rather than
      assumed
- [ ] Phase 7. kanae Ready, the readiness probe needs no shell, logs appear in
      `kubectl logs`
- [ ] Phase 8. Both Ingress routes work from outside the cluster, TLS renews
      without a human

**Layer D. Proof and operations**

- [ ] Phase 9. `e2e.sh` signs a user up from an empty cluster, and fails when
      you break something on purpose
- [ ] Phase 10. A restore from a real backup matches the source, resource limits
      set from measurements, runbook written
- [ ] Phase 11. Signup works through the real domain, and a git revert rollback
      has been rehearsed

# What this plan deliberately leaves out

**Argo CD, Flux, and GitOps generally.** These watch the repository and apply it
to the cluster continuously, so the cluster cannot drift from what is committed
without something noticing. That is the strongest auditability available, and
Phase 2 puts you most of the way there already: rendered manifests in git is the
input format both tools want, so adopting one later is a configuration change
rather than a rewrite.

The reason to wait is that each is another system to run, upgrade, and debug, on
one node, for one application, maintained by students who graduate. The reason
to revisit is pruning. `kubectl apply --prune` with a label selector works, and
it is the weakest part of this plan: it depends on every resource carrying the
label and on nobody applying without the flag. Argo tracks what it created and
removes what left the repository, without depending on either. If pruning bites
somebody after Phase 11, that is the signal to reconsider rather than to add
more discipline.

**Kustomize instead of Helm.** Helm is already pinned in `mise.toml`, the chart
already exists, and the templating engine was never what made the proof of
concept hard to review. It matters even less now that Helm is a build step
rather than the installer: it runs during `mise run k8s:render` and takes no part
in a deploy. Switching engines would cost a rewrite and change nothing a
reviewer sees.

**More than one replica of anything.** One node, one Postgres, one API process
with two workers. High availability needs more nodes, and more nodes cost money
the club does not currently spend. Phase 10's measurements tell you when that
changes.

**Metrics, tracing, and a dashboard.** `kubectl logs` and `kubectl top` are
enough at this size. Add them when somebody has a question those two cannot
answer.
