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
`kapp` applies to the production cluster. Nothing runs `helm install`.

Reviewers therefore read Kubernetes rather than Go templates. Phase 2 covers the
layout and what the arrangement costs.

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
| **kapp** | A single-binary deploy tool from Carvel. Takes a directory of Kubernetes YAML, shows what will change, applies it, and deletes anything that has left the directory since last time. |
| **pruning** | Deleting cluster resources that have been removed from your manifests. `kubectl apply` does not do it; kapp does. |
| **Gateway API** | The Kubernetes routing API that replaces Ingress. A `Gateway` owns the listeners and the certificate, an `HTTPRoute` owns the rules. |
| **HTTPRoute filter** | A step applied to a matched request before it reaches the backend. This plan uses `URLRewrite` to strip `/auth` on one rule and leave every other rule alone. |
| **Envoy Gateway** | The Gateway API controller this plan runs. A control plane pod watches Gateways and HTTPRoutes, and provisions an Envoy proxy pod per Gateway to carry the traffic. |
| **dorny/paths-filter** | A GitHub Action that reports which of a named set of path patterns a pull request touched, so a workflow can decide per job whether to run. |
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
| **3-2-1** | A backup rule of thumb: three copies of the data, on two kinds of storage, one of them offsite. |

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
| C. Services | 8 | Gateway API routing, path rewriting, and TLS (finishes after Phase 7) |
| D. Proof | 9 | An automated test that boots the whole stack and signs a user up |
| D. Proof | 10 | Backups you have restored from, memory limits from measurements, runbooks |
| D. Proof | 11 | The production cluster and the first real deploy |

Layers run in order, and inside a layer phases run in order, with one exception
noted at the top of Layer C.

### What the cluster looks like when it is finished

Each box carries the phase that builds it.

```mermaid
flowchart TB
    user(["Browser at ucmacm.dev"])

    subgraph cluster["Kubernetes cluster, namespace kanae"]
        gw["Gateway, HTTPS listener<br/>Phase 8"]
        route["HTTPRoute<br/>rule 1: /auth, strip the prefix<br/>rule 2: everything else"]
        kratos["Kratos<br/>who you are<br/>Phase 6"]
        keto["Keto<br/>what you may do<br/>Phase 6"]
        api["kanae API<br/>Phase 7"]
        pg[("Postgres<br/>kanae, kratos, keto<br/>Phase 4")]
        valkey[("Valkey<br/>sessions, rate limits<br/>Phase 4")]
        migrate["Atlas migration Job<br/>Phase 5"]
        backup["borgmatic CronJob<br/>Phase 10"]
    end

    offsite[("Offsite S3 bucket<br/>Phase 10")]

    user -->|HTTPS| gw --> route
    route -->|/auth| kratos
    route -->|everything else| api
    kratos -->|webhook on signup| api
    api --> keto
    api --> pg
    api --> valkey
    kratos --> pg
    keto --> pg
    migrate --> pg
    backup --> pg
    backup --> offsite
```

### How a change reaches that cluster

```mermaid
flowchart LR
    chart["deploy/helm/kanae/<br/>templates and values.yaml<br/>edited by hand"]
    enc["deploy/helm/secrets-prod.enc.yaml<br/>SOPS encrypted"]
    render["mise run k8s:render<br/>helm template, split by yq"]
    k8s["deploy/k8s/<br/>plain YAML, committed, reviewed"]
    ci{{"infra.yml<br/>drift check, kubeconform, kube-linter"}}
    apply["mise run k8s:apply<br/>kapp deploy"]
    live[["Live cluster"]]

    chart --> render --> k8s --> apply --> live
    k8s --> ci
    enc -->|decrypted in memory at apply time| apply
```

Phase 2 builds the second diagram. Everything else builds a box in the first.

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
7. **Every container gets a memory request and a memory limit, equal to each
   other, and no container gets a CPU limit.** Phase 4 gives the reason. Each
   phase sets estimates for what it builds and Phase 10 replaces them with
   measurements.

---

# Layer A. Foundation

## Phase 1. Tools and a local cluster

**What you build.** Every tool pinned to an exact version, a formatter and a
linter for the YAML files, and a k3d cluster you create and destroy with one
command each.

**Why it comes first.** Different Helm versions produce different rendered
output, so the drift check in Phase 2 would fail for reasons unrelated to any
actual change.

**How it goes.** Pin versions, set up the formatter and linter, then write the
cluster config and its tasks. Port mapping is the fiddly part: get one port
reaching the cluster before adding the rest.

**What formats and what lints.** `dprint` with the `pretty_yaml` plugin formats.
Layout is settled once it does, so the linter only needs the rules a formatter
cannot cover. Two matter here. Duplicate keys, which YAML resolves silently as
last-one-wins and which `kubeconform` cannot catch because the first value is
already gone by the time it looks. And `truthy`, where `no` parses as boolean
false rather than the string.

`yamllint` is the tool for that, with its layout rules switched off. It is the
decided choice. It is also Python, which this plan otherwise keeps out of the
infra checks, so the reasoning is recorded here rather than left to be
re-argued:

| Tool | Language | Stars | Status |
| --- | --- | --- | --- |
| yamllint | Python | 3,447 | ten years old, what the ecosystem uses |
| ryl | Rust | 65 | active, drop-in config, one maintainer, one year old |
| yaml-lint-rs | Rust | 7 | stopped February 2026 |
| yamllint-rs | Rust | 4 | two commits |

Speed was the objection and it does not survive measurement. `yamllint` over all
39 YAML files here, 3,728 lines, takes 0.434 seconds. None of the Rust
reimplementations clears the bar this plan sets for everything else.

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
- [ ] Disable the bundled Traefik in that config with `--disable=traefik`. k3s
      installs Traefik and its Gateway API CRDs by default, and Phase 8 installs
      Envoy Gateway, which ships those same CRDs. Leaving both in place makes
      k3s's own install job fail with `invalid ownership metadata`, which was
      checked. Disabling it also keeps the local cluster honest: nothing should
      be present locally that a rented cluster would not have.
- [ ] Add the mise task `k8s:up`. It creates the cluster from that file and then
      waits until `kubectl get nodes` reports Ready.
- [ ] Add the mise task `k8s:down`. It deletes the cluster and waits for the
      deletion to finish before returning.
- [ ] Add the mise task `k8s:reset`, which runs `k8s:down` then `k8s:up`.
- [ ] Move the Kubernetes tool pins out of `mise.toml` and into
      `.config/mise/conf.d/k8s.toml`. mise layers that file over `mise.toml`
      with no extra configuration, which was checked. The point is the path:
      `mise.toml` changes every time a dependency is bumped, so while the k3d
      pin and the uv pin live in one file no CI filter can tell a cluster change
      from a routine one.
- [ ] Pin the seven tools that still read `latest`: helm, kubectl, k3d, k9s,
      kubeconform, sops, and age. `latest` lets CI and your laptop run different
      versions and disagree about a rendered manifest.
- [ ] Write `.github/workflows/infra.yml`, gated on `dorny/paths-filter` rather
      than on a `paths:` key. A job skipped by `paths:` reports no status at
      all, so a branch protection rule that requires it waits forever. A filter
      job that always runs, sets an output, and is read by the real jobs does
      not have that problem. Pin the action by commit SHA the way
      `.github/workflows/lint.yml` already pins its actions:
      `dorny/paths-filter@ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d # v4.0.3`.
      For now the gated job runs `k8s:fmt:check` and the existing
      `scripts:lint`.
- [ ] Write the filter narrowly. `deploy/**` matches too much: HANDOFF.md, the
      Compose helper scripts, and anything else that lands under `deploy/` would
      trigger a cluster build for no reason.

      ```yaml
      infra:
        - 'deploy/helm/kanae/**'
        - 'deploy/k8s/**'
        - 'deploy/k3d/**'
        - 'deploy/cluster/**'
        - 'deploy/test/**'
        - '.config/mise/conf.d/k8s.toml'
        - '.github/workflows/infra.yml'
        - 'dprint.json'
        - '.yamllint.yaml'
      ```

      On `pull_request` the action compares through the API and needs no
      history. On `push` it needs `fetch-depth: 0` on the checkout, or it has
      nothing to diff against.

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
accepts, and `deploy/k8s/`, the plain Kubernetes YAML that runs in production.

**How the pieces relate.** Two directories, one meaning each.

```
deploy/
  helm/kanae/          the chart. source. edited by hand, never applied
  k8s/                 production manifests. generated. this is what is deployed
```

Helm is a build tool here. `mise run k8s:render` turns the chart into plain
YAML, you commit it, and `kapp` applies that directory to the cluster.
Nothing runs `helm install`, so the reviewed artifact and the applied one are
the same bytes. The arrangement has a name, the rendered manifests pattern.

There is no `local/` beside it. Two near-identical directories, one disposable
and one holding the real cluster, means checking which one you are in before you
can trust anything you see. Local renders go to `.k8s-local/`, gitignored. CI
still renders and validates them on every pull request, it just leaves no file
behind.

The name is `k8s` rather than `k3s` because k3s is one distribution and Kapsule
is another, and the manifests contain nothing specific to either.

**How it goes.** Write the schema first. Doing so makes you read every value in
`values.yaml` and decide what it is for, and you will find one or two that
nothing reads. Then add the render tasks, splitting output one file per resource
so a diff names the resource in its path instead of moving 900 lines of one
blob.

**What it costs, and what applies the manifests.** No `helm rollback`. A git
revert plus re-apply replaces it, which is more auditable and slower under
pressure.

The harder problem is deletion. `kubectl apply` creates and updates and never
deletes, so a resource you remove from the chart keeps running with nothing
reporting it. Apply with **kapp** instead. It records the set of resources it owns, shows a
diff before changing anything, applies in dependency order, waits for resources
to settle, and deletes what has left the manifests:

```
kapp deploy -a kanae -f deploy/k8s/
```

This was checked against a k3d cluster rather than taken from the
documentation. kapp 0.65.4 planned and applied 22 creates from this chart's
rendered output. Deleting one manifest and redeploying reported
`0 create, 1 delete, 1 update` and the resource was gone from the cluster.
Redeploying unchanged reported `0 create, 0 delete, 0 update`, a true no-op.
`kapp deploy --diff-run` printed the pending delete and changed nothing.

kapp is a Carvel project, in the CNCF landscape, maintained since 2019. There is
no controller and nothing running in the cluster between deploys.

Argo CD or Flux remain the upgrade path if somebody later wants continuous
reconciliation rather than a command they run. Nothing here blocks that, since
rendered manifests in git is exactly their input format.

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
      production values. Do not use `helm template --output-dir`: it writes one
      file per template and appends, so `postgres.yaml` arrives holding four
      resources. Pipe through the `yq` already pinned in `mise.toml` instead,
      which was checked and produces 22 files for this chart:
      `helm template kanae deploy/helm/kanae | yq -s '(.kind | downcase) + "-" + .metadata.name'`.
      Delete the target directory first, or a resource you removed from the
      chart lingers as a stale file.
- [ ] Add the mise task `k8s:render:local`, which renders the local values into
      `.k8s-local/`. Add `.k8s-local/` to `.gitignore`. A laptop render is a
      build artifact and does not belong in the repository.
- [ ] Add `kapp = "0.65.4"` to `[tools]` in `mise.toml`.
- [ ] Keep Secrets out of `deploy/k8s/`. Everything else renders into it, but a
      rendered Secret holds a base64 credential, and this directory exists to be
      read. Phase 3 decides where Secrets go instead.
- [ ] Add the mise task `k8s:render:check`, which regenerates into a temporary
      directory and fails if the result differs from what is committed. Print
      the diff and the words `run 'mise run k8s:render' and commit the result`,
      matching how `helm:check` already reports drift.
- [ ] Add the mise task `k8s:apply`, wrapping `kapp deploy -a kanae -f
      deploy/k8s/`. kapp shows the diff and asks before it changes anything, so
      the confirmation step is built in rather than something you add. Add a
      matching `k8s:apply:local` against `.k8s-local/` under a different app
      name, so the two can never be confused at the command line.
- [ ] Add `k8s:render:check` to `.github/workflows/infra.yml`, and have CI also
      render the local values into a temporary directory and run `kubeconform`
      over the result. Local rendering stays checked without being committed.
- [ ] Add `kube-linter` to `[tools]` and a `k8s:policy` task that runs it over
      `deploy/k8s/`, and add the task to
      `.github/workflows/infra.yml`. Turn on the check for containers running as
      root. Finding 3 in POC_FINDINGS.md was a container that crashed because it
      ran as root under dropped privileges, and this check names that pattern.
- [ ] Turn on kube-linter's `unset-memory-requirements` check. Rule 7 puts a
      memory request and limit on every container from Phase 4 onward, so
      nothing needs an exemption and the check never becomes noise.
- [ ] Leave the CPU-limit check off, and write the reason in the config file
      next to the switch. This plan sets memory limits deliberately and CPU
      limits never, for the reason in Phase 4, so a check demanding CPU limits
      would only teach people to ignore the config.
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

Then, against a running local cluster, run `mise run k8s:apply` and confirm kapp
prints the same difference `git diff` did before it applies anything. Those two
diffs agreeing is the property this whole phase exists to give you.

---

# Layer B. Platform

## Phase 3. Configuration and secrets

**What you build.** One place that owns each configuration file, and one program
that renders each generated file.

**Why it is the hardest phase.** It deletes more than it adds. Two programs that
produce the same file will differ eventually, and the day they do is a day spent
debugging a service reading a config nobody wrote.

**How it goes.** Three independent parts. Run `mise run k8s:render` after each,
and the render must not change. That is the safety net for the whole phase.

First, remove the copies under `deploy/helm/kanae/files/` without moving
anything. The copies exist because `.Files.Get` refuses a path outside the chart
directory. The obvious fix is to move the originals into the chart, and that
fix is wrong here: `src/schema.sql`, `config.dist.yml`, and `docker/ory/config/`
are read by Atlas, by the application, and by every Compose file, and moving
them breaks all of it to satisfy Helm.

Helm follows symlinks, so replace each copy with a link to the real file. Helm
resolves the link, reads the target, and logs `found symbolic link in path` as
it goes. This was checked rather than assumed: it works for a linked file and
for a linked directory, the target may sit outside the chart, and `helm package`
dereferences the link into a regular file inside the tarball, so a packaged
chart carries content rather than a dangling link. Nothing moves, every existing
path keeps working, and there is one copy of each file.

The cost is Windows. Git there writes a symlink as a text file holding the
target path unless `core.symlinks` is on, which needs Developer Mode or an
administrator shell. This repo already ships `run_windows` task variants, so
somebody will hit it: a render on a Windows checkout without symlink support
produces a ConfigMap containing a path string instead of a file. Write that in
`deploy/k8s/README.md`. CI renders on Linux, so the drift check catches it.

Second, cut `seed-k8s.sh` down and rename it `deploy/helm/init.sh`, matching how
init scripts are named elsewhere in this repo. It does four things today:
generates secret values, derives two tokens, renders `config.yml` with `yq`, and
pushes Secrets with `kubectl`. Only the first two survive.

The repository holds six files called `init.sh` doing unrelated jobs, so always
write the full path. `deploy/helm/init.sh` generates secrets, and is this phase.
`docker/ory/init.sh` is the Postgres initdb script that creates the `kratos` and
`keto` databases, reached from the chart through the symlink at
`deploy/helm/kanae/files/init.sh`, and is Phase 5. Neither is ever called just
"init.sh" in this plan.

Third, the smaller cleanup: real age keys, service names declared once, and the
image pull secret. Take the pull secret seriously despite it looking trivial,
because `docker pull` succeeds from your laptop using credentials the cluster
never saw.

**Where Secrets live.** Not in `deploy/k8s/`. A rendered Secret is a base64
credential and that directory exists to be read. Committing it encrypted fails
too, because SOPS generates a fresh data key per encryption, so identical
content encrypts to different bytes every run and the drift check never passes.
Instead `deploy/helm/secrets-prod.enc.yaml` holds the values, and at apply time
they are decrypted in memory, rendered by the same chart, and piped into
`kubectl`. Secrets are the one part of the deployment you cannot read out of
git.

### Tasks

- [ ] Replace every copy under `deploy/helm/kanae/files/` with a symlink to its
      original. The `helm:sync` task in `mise.toml` names all seventeen and
      where each came from, so it is the checklist: `docker/ory/config/**`,
      `docker/ory/init.sh`, `src/schema.sql`, `config.dist.yml`, and
      `scripts/seed/**`. Nothing moves and no Compose bind mount changes.
- [ ] Delete the `helm:sync` and `helm:check` tasks from `mise.toml`. With no
      copies there is nothing to sync and nothing to check. `helm:check` only
      ever existed because the copies did.
- [ ] Cut `deploy/helm/seed-k8s.sh` down to one job: generate secret values and
      write them to a plain YAML file for SOPS to encrypt. Delete the `yq`
      config rendering at line 247 and the `kubectl create secret` calls at
      lines 310 to 334. Rename it `deploy/helm/init.sh`. The old name was also
      misleading, since a Job named `seed` already creates test members.
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
- [ ] Have `deploy/helm/init.sh` call `scripts/derive-webhook-tokens.py` rather
      than recomputing the blake3 tokens itself. One implementation.
- [ ] Replace the four placeholder age keys in `.sops.yaml`. All four currently
      read `REPLACE`.
- [ ] Declare the fixed Service names once. Add a `serviceNames` block to
      `values.yaml` holding `kanae`, `database`, `valkey`, `kratos`, and `keto`,
      and reference it through `_helpers.tpl` everywhere. The names stay fixed,
      for the reason HANDOFF.md gives, but they become a documented list in one
      file instead of strings typed into ten templates.
- [ ] Add two checks to `k8s:policy`. Fail if any file in
      `deploy/helm/kanae/templates/` contains a hardcoded `database:5432` or
      `kanae:8000`. Fail if anything under `deploy/helm/kanae/files/` is a
      regular file rather than a symlink, which is what stops the copies coming
      back.
- [ ] Add `imagePullSecrets` to `values.yaml` and to every pod spec.
      `ghcr.io/ucmercedacm/kanae` is a private package, and nothing in `deploy/`
      currently mentions a pull secret. Finding 6 in POC_FINDINGS.md is what
      happens without one, and it is nasty because `docker pull` on your laptop
      succeeds using credentials the cluster does not have.

### Exit gate

Run `mise run k8s:render`. The rendered output must not change, because none of
this phase changes what the cluster gets. That is the point: a refactor with an
empty diff in `deploy/k8s/` is a refactor you can trust.

Then run `find deploy/helm/kanae/files -type f` and confirm it prints nothing.
Every entry under that directory should be a symlink.

---

## Phase 4. Postgres and Valkey

**What you build.** The two services that hold data. Postgres holds all three
databases. Valkey is a cache and can be lost.

**Why they come first.** Kratos, Keto, and kanae all connect to Postgres at
startup. Without it none of them start and none can be tested.

**How it goes.** Postgres first and completely, then Valkey, which is small.

Two changes reverse the proof of concept, and both are about what happens when
something fails rather than when it works. The readiness probe becomes
`pg_isready` and nothing else. The current one runs a checksum query copied from
Compose, and Finding 1 is that copy failing and taking down the whole
deployment. Corruption checking is worth doing somewhere that cannot stop the
database serving traffic.

The Service type follows from it. A headless Service publishes no DNS record
while its pod is not Ready, so a wrong probe does not degrade the system, it
makes the name `database` stop existing and every service fails at once with a
DNS error pointing nowhere near the cause. ClusterIP gives you connection
refused against a name that resolves. One replica means headless buys nothing to
offset that.

Memory limits go on now, CPU limits never, which is rule 7. A container over its
memory limit is killed, so with no limit one leaking pod takes the whole node
down with it. A container over a CPU limit is throttled instead, which surfaces
as slow requests with nothing in the logs and is the harder thing to diagnose.
Set the request equal to the limit so the scheduler reserves exactly what the
pod is allowed to use. The first numbers are estimates; Phase 10 replaces them
with what `k8s:measure` recorded.

### Tasks

- [ ] Rewrite the Postgres readiness probe as `pg_isready` and nothing else.
- [ ] Move the checksum query it currently runs into a separate CronJob that
      alerts, so corruption checking cannot stop the database serving traffic.
- [ ] Change the `database` Service from headless to a normal ClusterIP Service.
- [ ] Set an explicit non-root `runAsUser`, `runAsGroup`, and `fsGroup` on the
      Valkey pod. Finding 3 is Valkey crash-looping on
      `chown: .: Operation not permitted`, because its startup script takes
      ownership of its data directory when it runs as root and the chart had
      removed the privilege that needs.
- [ ] Move the Retain-policy StorageClass out of the comment in
      `deploy/helm/kanae/templates/postgres.yaml` into
      `deploy/cluster/storageclass.yaml`, and add a step for it in Phase 11. It
      is cluster-wide setup, not part of a release.
- [ ] Keep `helm.sh/resource-policy: keep` on the Postgres claim.
- [ ] Set a memory request and limit, equal to each other, on the Postgres and
      Valkey containers. Start at 512Mi for Postgres and 256Mi for Valkey and
      correct both in Phase 10. Leave CPU limits off.
- [ ] Set Valkey's `maxmemory` below its container memory limit. Valkey evicts
      keys when it reaches `maxmemory` and grows without bound when it is
      unset, so an unset `maxmemory` under a container limit means the kernel
      kills the container instead of Valkey doing the job it is designed for.
- [ ] Add the mise task `k8s:measure`, which runs `kubectl top pod` and writes
      the result to a file for Phase 10.

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

**What you build.** The three databases, their tables, and a way to see what a
migration will do before it does it.

**Why it needs its own phase.** kanae starts fine against a database with no
tables and then fails on every request. Migrations are also the only part of
this system that can destroy data.

**How it goes.** Database creation first, since nothing else has anything to run
against until `kratos` and `keto` exist. Today that is a script in
`/docker-entrypoint-initdb.d/`, which Postgres runs only when the data directory
is empty, so on an existing volume it silently does nothing. A Job that can run
twice safely has no such mode.

Atlas needs the most thought and the least code. It compares `src/schema.sql`
against the live database and generates the difference, so a column you delete
from that file becomes a `DROP COLUMN` that nobody read. The dry-run job puts
that statement in front of a human first, and it is the cheapest safety measure
in this plan.

Expect the kanae pod in `Init:Error` with a climbing restart count while this
runs. Its init container is checking for a table that does not exist yet. That
is the design.

### Tasks

- [ ] Replace `deploy/helm/kanae/files/init.sh`, the Postgres initdb script,
      with an idempotent Job. Postgres runs scripts in
      `/docker-entrypoint-initdb.d/` only when the data directory is empty, so
      on an existing volume this one silently never runs. It creates the
      `kratos` and `keto` databases and the `pg_trgm` extension, and nothing
      else does.
- [ ] Keep migrations as Jobs rather than init containers. Init containers run
      once per pod, so two replicas race two copies of a schema migration.
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
      as a comment.
- [ ] Keep passing arguments straight to the atlas entrypoint, never through
      `sh -c`. Finding 2 is an image that ships no shell, which the chart cannot
      check for.
- [ ] Keep every startup gate single-shot. No `until` loops, no
      `for i in $(seq ...)`. Kubernetes already retries a failed init container
      with a backoff. An earlier unbounded `until` loop here could never exit
      non-zero, so `backoffLimit` never tripped and a stuck Postgres hung the
      deploy.
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

While the Jobs run, the kanae pod shows `Init:Error` with a climbing restart
count, for the reason given above.

---

# Layer C. Services

Phases 6 and 7 touch different files and different people can work on them at
the same time. Phase 8 can be written alongside them, but it cannot be finished
until Phase 7 is, because its exit gate sends a request through the Gateway to a
running API. None of the three can finish before Layer B does.

## Phase 6. Ory Kratos and Ory Keto

**What you build.** The services that answer who a person is (Kratos) and what
they may do (Keto).

**Why before kanae.** Not strictly necessary, since neither is contacted when
kanae starts. Kratos is fussy about its configuration and easier to get right on
its own than while debugging the API at the same time.

**How it goes.** Keto is close to mechanical. Budget your time for Kratos.

Kratos validates its whole configuration at startup and refuses to boot if any
part of it is wrong, including parts nothing will use. Finding 4 is exactly
that: a throwaway string in the mail server setting that was not shaped like a
URI. The value did not have to work, it had to parse.

Cookies cost the other half of your time. Kratos issues Secure cookies unless
told otherwise, and a Secure cookie is dropped over plain `http://`. Locally the
cookie vanishes, the next request fails its CSRF check, and the error names CSRF
while having nothing to do with CSRF being misconfigured. Test from inside the
cluster, because `curl` treats `127.0.0.1` as a secure context and a
port-forwarded test will pass while the real path fails.

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
- [ ] Test the cookie behaviour from inside the cluster against
      `http://kratos:4433`, not through `kubectl port-forward`.
- [ ] Lower `max_conns` in the Kratos and Keto database connection strings from
      20 to 5. Kratos at 20, Keto at 20, and kanae's asyncpg pool at its
      default of 10 is up to 50 connections against a Postgres sized for a 4 GB
      node, and stock Postgres allows 100. Write the arithmetic in
      `deploy/DECISIONS.md`.
- [ ] Note that the chart mounts `kratos.prod.yml` while the Compose stack seeds
      against `kratos.yml`. A local Kubernetes run therefore exercises a
      combination the Compose stack never has. Decide whether that is what you
      want, and write down the answer.
- [ ] Set a memory request and limit, equal to each other, on the Kratos and
      Keto containers, and on the Kratos and Keto migration containers. 256Mi
      is a starting point for each. Phase 10 corrects them.

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

**What you build.** The API. Everything in Layers B and C exists to support this
one service.

**How it goes.** Mostly configuration rather than Kubernetes. The pod spec is
the simplest in the chart: one container, one init container, no storage.

`config.yml` renders as an overlay on `config.dist.yml` rather than a second
copy, so a key added there arrives with its documented default instead of going
missing. The pod template carries a checksum of the rendered config so a change
restarts the pod. Compute that checksum from the same bytes the ConfigMap holds,
or it stops matching the first time the overlay grows a key and config changes
quietly stop restarting anything.

The behaviour fix is `_is_docker()` at `src/core.py:166`. It checks for
`/.dockerenv` and for `docker` in `/proc/self/cgroup`, neither of which holds
under containerd, so kanae writes log files. The chart works around that by
mounting `/kanae/logs` for files nothing reads while `kubectl logs` shows almost
nothing. Fix the check, then delete the mount.

Two settings are easy to leave wrong because both defaults suit a laptop.
`allowedOrigins` defaults to the Vite dev server, so the browser refuses every
request from `ucmacm.dev`. The rate limiter stays on in production and off for
local seeded runs, per Finding 5.

### Tasks

- [ ] Render `config.yml` as an overlay on `config.dist.yml`, not a second copy.
- [ ] Keep the `checksum/config` annotation, computed from the same bytes the
      ConfigMap holds.
- [ ] Keep the single init container that checks the schema exists. One query,
      one attempt, exit non-zero if the table is missing.
- [ ] Change the readiness probe from `exec` to `httpGet` on `/`, the route
      `src/routes/index.py` already serves. It currently runs
      `sh -c "curl -fsS --max-time 2 http://127.0.0.1:8000"`, which depends on
      the image shipping both a shell and `curl`, neither of which the chart can
      check for. The kubelet performs an `httpGet` probe itself and needs
      neither. No new route is required.
- [ ] Fix `_is_docker()` at `src/core.py:166` to detect containerd, then delete
      the `/kanae/logs` `emptyDir` mount it currently requires.
- [ ] Set `kanae.allowedOrigins` to the real frontend origin.
- [ ] Leave the rate limiter on in production and off for local seeded runs.
- [ ] Set a memory request and limit, equal to each other, on the kanae
      container and on the init container that checks the schema. 512Mi for the
      application and 64Mi for the init container are starting points. An init
      container without a limit is the same gap as any other container.
      Finding 5 has the detail.

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

## Phase 8. Gateway API routing and TLS

**What you build.** The route from the internet to the right service. `/auth`
goes to Kratos with the prefix stripped, everything else goes to kanae.

**When it can finish.** After Phase 7, because its exit gate reaches a running
API.

**How it goes.** Routing uses the Gateway API rather than Ingress. A `Gateway`
owns the listeners and the TLS certificate; an `HTTPRoute` attaches to it and
holds the rules.

The prefix strip is the difficulty of the phase. Kratos generates URLs carrying
`/auth` but serves its routes at the root, so without the strip every login flow
returns 404, and with the strip applied too broadly the API loses the first
segment of every path. In the Gateway API a `URLRewrite` filter attaches to a
single rule, so one route object carries both:

```yaml
rules:
  - matches: [{ path: { type: PathPrefix, value: /auth } }]
    filters:
      - type: URLRewrite
        urlRewrite:
          path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
    backendRefs: [{ name: kratos, port: 4433 }]
  - matches: [{ path: { type: PathPrefix, value: / } }]
    backendRefs: [{ name: kanae, port: 8000 }]
```

The controller is **Envoy Gateway**. It installs from one Helm chart on any
cluster, which is the property that matters: the local k3d cluster and a rented
one run the same controller installed the same way, with nothing borrowed from a
distribution's bundle. Its conformance report supports `HTTPRoutePathRewrite`,
which the route above needs, along with route-level timeouts, CORS, and
mirroring, which nothing needs yet.

It runs as two pods: a control plane that watches Gateways and HTTPRoutes, and
one Envoy proxy provisioned per Gateway. Measured idle on k3d with a single
Gateway, that was 36Mi each.

**TLS terminates at the Gateway, and nowhere else.** Every provider offers to
terminate it at their load balancer instead, and taking that offer moves the
certificate into one provider's API and makes the stack unportable. So the
load balancer in front passes TCP through, and the Gateway holds the
certificate. cert-manager issues it into a Secret the Gateway names, which makes
`kubectl get certificate` the answer to when it expires.

This reverses `deploy/helm/HANDOFF.md`, which says "No TLS in the chart.
Certificates come from certbot/letsencrypt assembled into HAProxy's combined PEM
and referenced from the HAProxy config." That works today. It reports nothing
when a certificate is about to expire, and its renewal depends on a job on a
machine some graduating student set up.

Test from outside the cluster. `kubectl port-forward` tunnels straight to the
pod and never touches the Gateway, so it cannot tell you whether the rewrite is
right.

### Tasks

- [ ] Install Envoy Gateway from its Helm chart, pinned to a version in
      `deploy/cluster/`, with the same command in `k8s:up` and in Phase 11.
      The Gateway API CRDs are not built into Kubernetes, and the chart ships
      them, so let it own them and do not apply them separately. A cluster
      missing them accepts a `Gateway` as an unknown type and routes nothing.
- [ ] Override the chart's control plane memory request. It defaults to
      `requests.memory: 256Mi` and `limits.memory: 1024Mi` against 36Mi
      measured idle. Rule 7 makes the request equal the limit, and the
      scheduler reserves the request, so the default reserves seven times what
      the pod uses on a node that has other work to do.
- [ ] Write one `Gateway` with an HTTPS listener and one `HTTPRoute` with two
      rules. Put the `URLRewrite` filter on the `/auth` rule only. Two objects,
      not two routes.
- [ ] Give `kubeconform` the Gateway API schemas through `-schema-location`. It
      validates against the built-in Kubernetes schemas by default and reports
      a `Gateway` as an unknown kind, so without this the newest manifests in
      the repository are the ones nothing checks.
- [ ] Terminate TLS on the Gateway's HTTPS listener, with cert-manager issuing
      the certificate into the Secret it names. cert-manager needs
      `--enable-gateway-api` on its controller before it will issue for a
      Gateway. Record the change in `deploy/DECISIONS.md`, since it reverses
      HANDOFF.md's "No TLS in the chart".
- [ ] Use the DNS-01 ACME solver rather than HTTP-01. HTTP-01 makes cert-manager
      create an HTTPRoute that the Gateway must already be serving, so the first
      certificate depends on the routing it is supposed to secure.
- [ ] Expose the Gateway with a `Service` of type `LoadBalancer` and no
      provider-specific settings in the chart. Any provider-specific annotation
      belongs in the values file for that environment, not in the template.
- [ ] Test through the Gateway, never through `kubectl port-forward`.

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

**What you build.** One script that starts from nothing, brings up the stack,
signs a user up, and checks the user exists. Then CI runs it.

**Why it is the most valuable phase here.** Signup crosses four services. The
browser talks to Kratos, Kratos creates the identity, Kratos calls a webhook
into kanae, and kanae writes a member row. A break anywhere in that chain looks
like "signup is broken" with no clue where.

**How it goes.** Half of this phase is already written. `tests/integration/`
holds 43 hurl scenarios that drive signup, login, the permission matrix, and the
event and project flows against the Compose stack, `mise.toml` pins hurl 8.0.1,
and `.github/workflows/test.yml` already runs them. Point them at the cluster
and they become the cluster's test suite. So this phase writes no assertions in
bash: hurl asserts status codes, JSON bodies, and captured values as declarative
lines in a `.hurl` file, and a bash `if` chain reimplementing that badly is how
an end-to-end test rots.

What is new is the harness around them: create the cluster, build and import the
images, apply, wait, run hurl through the Gateway, and tear the cluster down
whether it passed or failed. Get that reliable before adding anything else,
because a harness that leaks clusters costs more time than the bugs it finds.

Waiting for pods to be Ready is not a test. Every pod was Ready in the proof of
concept while the stack was unusable. The signup scenario is what tells you
otherwise, because it crosses Kratos, the webhook, and the kanae database in one
request chain.

Then break it on purpose with a wrong database password. A test that has never
failed is one you have no reason to believe, and this one becomes the gate on
every infrastructure change from here.

Spend real effort on the failure output. Failures here surface far from their
cause, so dump the events and the logs of everything that is not Ready.

### Tasks

- [ ] Write `deploy/test/e2e.sh`. It creates a k3d cluster, builds and imports
      the images, renders the local values with `k8s:render:local` and applies
      them, waits for every workload to be Ready with a timeout, runs hurl, and
      deletes the cluster whether it passed or failed. The script owns the
      cluster lifecycle and nothing else.
- [ ] Write `deploy/test/vars.env` with the same variable names as
      `tests/integration/vars.env` and the Gateway hostname as the base URL, so
      the existing scenarios run unchanged:
      `hurl --test --variables-file deploy/test/vars.env ...`. A scenario that
      needs editing to run against Kubernetes is testing the harness rather
      than the application, so treat any such edit as a bug in the harness.
- [ ] Start with the three scenarios that prove the wiring rather than all 43:
      `01_health_and_docs.hurl`, `02_login_admin_bootstrapped.hurl`, and
      `22_full_journey_lead.hurl`. The last one covers signup end to end, which
      is the chain this phase exists to check. Widen to the full directory once
      the harness stops being the thing that fails.
- [ ] Fix the seed script so it completes all fifteen members. It currently gets
      partway through, fails, retries, and gets a little further. Turning off the
      rate limiter moved it past one blockage but did not finish it. Find the
      real cause rather than removing another limit.
- [ ] Add a negative test. Apply with a deliberately wrong database password and
      confirm `e2e.sh` fails. A test that has never failed proves nothing about
      the thing it tests.
- [ ] Test deletion. Remove a resource from the chart, re-render, run
      `k8s:apply`, and confirm kapp removes it from the cluster. This is the
      failure mode the rendered manifests pattern introduces, and it is silent
      without a test.
- [ ] Add `e2e.sh` to `.github/workflows/infra.yml`, behind the same
      `dorny/paths-filter` output as the rest of that workflow, plus a nightly
      schedule so it still runs on the weeks nobody touches the cluster.
      GitHub runners can run k3d.
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

**How it goes.** Backups first, since they protect the only thing you cannot get
back.

Check what the backup image can actually do before writing any config. Borg 1.x
cannot write to S3-compatible storage at all, only 2.x can, through borgstore.
The chart schedules a backup against a repository setting that may be impossible
for the image it runs, and HANDOFF.md records the credential variable names as a
guess. Both are one command to resolve and neither has been run.

Aim at 3-2-1: three copies of the data, on two kinds of storage, one of them
offsite. Two thirds of that comes free here. The live Postgres volume is copy
one, a Borg repository on a separate volume is copy two, and an S3 bucket at a
different provider is copy three and the offsite one. The middle leg is the one
a single-node cluster cannot honestly meet, because the first two copies sit on
block volumes from the same provider and fail together. Write that down rather
than claiming a policy the setup does not meet, and treat the offsite copy as
the one that carries the weight.

Then restore. Not "the backup Job succeeded" but restore into a scratch database
and compare row counts against the source. A backup nobody has restored from is
a file of unknown contents.

The runbook is the item most likely to be skipped. Key it on the exact error
text somebody will paste into a search box. The six findings in POC_FINDINGS.md
are six real messages that will happen again.

### Tasks

- [ ] Check which Borg version the backup image ships, then set
      `backup.repository` in
      `deploy/helm/kanae/templates/backup-borgmatic.yaml` to match what it can
      actually write to.
- [ ] Write the borgmatic config ConfigMap. The chart expects a ConfigMap named
      by `backup.configMap` and the config itself does not exist yet.
- [ ] Confirm the backup credential environment variable names against the
      image. HANDOFF.md records that `AWS_ACCESS_KEY_ID` and
      `AWS_SECRET_ACCESS_KEY` are a guess, based on what rclone, borgstore, and
      boto read.
- [ ] Restore from a backup by hand once, then write it as a script so it can be
      done again under pressure.
- [ ] Record the backup layout against 3-2-1 in `deploy/DECISIONS.md`: which
      copy is which, and which leg this setup does not meet. A policy nobody
      has written down is a policy nobody can audit.
- [ ] Put the offsite copy somewhere that is not the cluster's provider. A
      backup held on the same account as the thing it protects survives a disk
      failure and very little else.
- [ ] Replace the memory estimates from Phases 4, 6, and 7 with the numbers
      `k8s:measure` collected. Keep request and limit equal, and set both above
      the observed peak rather than the steady state, because the limit is what
      the pod is killed for exceeding.
- [ ] Leave CPU limits unset and write the reason beside the values, so the
      next person does not read the gap as an oversight and fill it in.
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

**What you build.** The real cluster and the first deploy onto it.

**Why it is last.** Everything above is rehearsal, and every step here is easier
to debug on a laptop first.

**How it goes.** Order matters more here than anywhere else, because some of
these steps are hard to undo once data exists.

Cluster-wide setup comes before the first apply: storage class, Gateway API
CRDs, Envoy Gateway, cert-manager, image pull secret. The storage class
especially,
because the Postgres claim names it and a claim naming a class that does not
exist waits forever without a useful error. It has to be the Retain variant, as
the stock Scaleway class deletes the underlying volume when the claim goes and
turns a routine mistake into data loss.

Then secrets, then apply. The generator preserves existing values on a re-run,
per Phase 3, and that property matters most here.

Rehearse a rollback before anyone depends on it. Here that is a git revert and
re-apply rather than one Helm command, and the forward-only migration policy
from Phase 5 is what you are really testing.

### Tasks

- [ ] Decide between Scaleway Kapsule and k3s on a rented server. The proof of
      concept targets Kapsule with the free Mutualized control plane, at roughly
      €21 a month for a DEV1-M node, block storage, and an IPv4 address. Write
      the decision and its cost in `deploy/DECISIONS.md`.
- [ ] Create the cluster with the provider's managed ingress add-on turned off,
      so nothing installs a second controller alongside the one this plan
      configures.
- [ ] Apply `deploy/cluster/storageclass.yaml` from Phase 4. Do this before the
      first install, because the Postgres claim names that class.
- [ ] Install Envoy Gateway with the same pinned command `k8s:up` runs, which
      brings the Gateway API CRDs with it. Do this before the first
      `k8s:apply`: applied to a cluster without those CRDs, the Gateway and the
      HTTPRoute are unknown types and nothing routes.
- [ ] Add whatever annotations the provider's cloud controller needs to the
      Gateway's `LoadBalancer` Service, in the production values file only. On
      Scaleway that is the CCM annotations, and reserving the IP before you
      point DNS at it. Nothing provider-specific goes in the chart templates,
      so this is the one file that changes when the provider does.
- [ ] Leave TLS terminating on the Gateway rather than on the provider's load
      balancer, whatever the provider offers. Configure the load balancer to
      pass TCP through. Terminating there puts the certificate somewhere
      `kubectl` cannot see it and somewhere the next provider will not have.
- [ ] Install cert-manager and create the issuer.
- [ ] Create the image pull secret for `ghcr.io/ucmercedacm/kanae`.
- [ ] Publish the `kanae-seed` image. `docker/Dockerfile.seed` exists and
      `mise run seed:image` builds it locally, but nothing pushes it to ghcr.
- [ ] Generate the production secrets with `deploy/helm/init.sh`, encrypt with SOPS,
      commit the encrypted file, and put the CI age key in a GitHub Actions
      repository secret. Apply them before the first `k8s:apply`, or every pod
      that mounts them stays pending.
- [ ] Point DNS at the cluster.
- [ ] Apply `deploy/k8s/` with `mise run k8s:apply`. Read the diff kapp prints
      before you confirm. On a first install that diff is every resource, which
      is the one time it is not worth reading closely.
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

- [ ] Phase 1. Tools pinned and the Kubernetes ones split into their own mise
      config, dprint and yamllint wired up, `k8s:up` and `k8s:down` work, CI
      runs both checks behind a path filter
- [ ] Phase 2. `values.schema.json` written, `deploy/k8s/` committed and
      applicable, local renders gitignored, CI fails on a stale render

**Layer B. Platform**

- [ ] Phase 3. No file in the repo is a copy of another, the chart reaches its
      sources through symlinks, one program renders each generated file, real
      age keys in `.sops.yaml`
- [ ] Phase 4. Postgres and Valkey Ready, data survives deleting the Postgres
      pod
- [ ] Phase 5. Three databases with their tables, a written forward-only
      migration policy, schema changes reviewed as DDL before they run

**Layer C. Services**

- [ ] Phase 6. Kratos and Keto Ready, cookie behaviour observed rather than
      assumed
- [ ] Phase 7. kanae Ready, the readiness probe needs no shell, logs appear in
      `kubectl logs`
- [ ] Phase 8. Both HTTPRoute rules work from outside the cluster, TLS renews
      without a human

**Layer D. Proof and operations**

- [ ] Phase 9. `e2e.sh` brings up a cluster and the existing hurl scenarios
      pass against it, and fail when you break something on purpose
- [ ] Phase 10. A restore from a real backup matches the source, memory limits
      set from measurements, backup layout recorded against 3-2-1, runbook
      written
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
one node, for one application, maintained by students who graduate. kapp already
covers the deletion problem that would otherwise force the issue, and it runs
only when somebody runs it.

The reason to revisit is drift. kapp tells you what changed when you deploy;
Argo watches continuously and tells you when the cluster stops matching the
repository, including when somebody changes something by hand. If that happens
and nobody notices for a week, that is the signal.

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
