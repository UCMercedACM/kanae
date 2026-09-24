# Phase 9: the end-to-end test

Supersedes the Phase 9 task list in `KANAE_INFRA_PLAN.md:1607-1690` where the two disagree,
and replaces this document's earlier pytest design, which is recorded under "Rejected" below.
The code lives in `tmp-e2e-harness/` until it moves to `deploy/kubernetes/tests/`.

## Problem

Phase 9 has to prove that a browser registration reaches a `members` row across four
services, that the stack fails loudly and legibly when misconfigured, and that kapp deletes
what it should and keeps what it must. Four facts in the repository decide the shape, and
three of them contradict the plan.

**No pod in the `kanae` namespace can call the kanae API.** `networkpolicy-default-deny`
selects every pod. `networkpolicy-kanae` admits ingress only from namespace
`envoy-gateway-system` and from pods labelled `app: kratos`; Keto admits only `app: kanae`.
The plan's "run hurl from a pod inside the cluster" cannot run a single scenario without
adding a NetworkPolicy, which means certifying a policy surface that does not ship.

**Nothing exercises the registration webhook.** `tests/integration/init.sh` creates its six
identities through the Kratos *admin* API -- its own log line reads "admin-create bypasses
the registration webhook" -- and inserts the matching `members` rows with `psql`. Every one of
the 43 scenarios starts downstream of the chain this phase exists to prove. Pointing them at
the cluster does not produce the exit gate.

**`kanaePassword`, not `dbPassword`, is the app's credential.** `_helpers.tpl:14` builds the
DSN as `postgresql://kanae:{{ .Values.secrets.kanaePassword }}@database:5432/kanae`.
`dbPassword` is the Postgres superuser and never touches the `kanae` role. A negative test
that poisons `dbPassword` deploys green and never fails.

**The 43 scenarios are single-shot.** 33 hardcoded UUIDs, and nothing deletes what it
creates. CI never noticed because Compose is recreated every run; a stack that stays up
between runs walks straight into it.

## Usage

```console
$ tmp-e2e-harness/init.sh
$ hurl --test --insecure --resolve kanae:443:127.0.0.1 --resolve kanae:80:127.0.0.1 \
    --variables-file tmp-e2e-harness/vars.env --secrets-file tmp-e2e-harness/secrets.env \
    tmp-e2e-harness/scenarios/*.hurl
$ bats tmp-e2e-harness/
$ k3d cluster delete --config deploy/kubernetes/k3d.yml
```

Four commands, four jobs. CI runs them as four steps, the way `test.yml` already runs the
integration suite as prepare / run / clean up.

## Layout

```
tmp-e2e-harness/
├── init.sh                  committed   stack up + seed, then exit
├── vars.env                 committed   Gateway URLs, seed emails
├── secrets.env              gitignored  PASSWORD + identity UUIDs, written by init.sh
├── secrets.local.yml        gitignored  chart secret values, written by deploy/kubernetes/init.sh --local
├── scenarios/
│   ├── 01_gateway_tls_and_redirect.hurl
│   ├── 02_gateway_to_backend.hurl
│   ├── 03_gateway_to_kratos.hurl
│   ├── 04_login_session_and_cache.hurl
│   ├── 05_registration_webhook.hurl
│   ├── 06_backend_to_postgres.hurl
│   ├── 07_backend_to_keto.hurl
│   └── 08_logout_revokes_session.hurl
├── netpol.bats              NetworkPolicies hold (read-only)
├── prune.bats               kapp prunes a dropped resource (restores)
├── pvc.bats                 the claim and its rows survive kapp delete (restores)
├── credentials.bats         a wrong app DB password fails kanae's rollout (restores)
└── README.md
```

| File | Purpose |
|---|---|
| `init.sh` | Creates the k3d cluster (or reuses it), switches the kube context to it, installs Cilium, Envoy Gateway, cert-manager and the Gateway, generates the chart secrets into `secrets.local.yml`, renders into `.k8s-local`, applies through `apply-local.sh`, waits for Kratos, Keto and Postgres, for the `kanae-migrate` Job and for kanae, opens port-forwards to the Kratos and Keto admin APIs, seeds six identities with their `members` rows and Keto role tuples, writes `secrets.env`, and exits, printing the hurl, bats and teardown commands for the cluster it built. Safe to re-run. |
| `vars.env` | `KANAE_URL=https://kanae`, `KANAE_HTTP_URL=http://kanae`, `KRATOS_URL=https://kanae/auth`, and the six `*_EMAIL`. Committed, like `tests/integration/vars.env`. `init.sh` sources it for the emails, so there is one copy. |
| `secrets.env` | `PASSWORD`, `ROOT_ID` ... `SCRATCH_ID` for `hurl --secrets-file`. Same role as `tests/integration/secrets.env`. |
| `secrets.local.yml` | Every value `templates/secrets.yml` renders. Must survive between applies, see below. |
| `scenarios/*.hurl` | One scenario per cross-component edge, derived from the 43. |
| `*.bats` | The cluster internals hurl cannot see from outside, one file per concern. |

## Decisions and rationale

### hurl owns every HTTP assertion; nothing re-implements it

The repository already has an HTTP test framework, pinned at 8.0.1, with 43 scenarios CI runs.
hurl's `--test` mode runs files in parallel, reports per-file, and takes `--resolve`,
`--insecure`, `--variables-file` and `--secrets-file`, which is everything the cluster needs.
The Phase 9 question is HTTP-shaped -- does a request through the Gateway reach the right
service and come back right -- so it goes to the HTTP tool.

### A separate, condensed scenario set rather than the 43

The integration suite answers "given a correct stack, does the backend work", and pins API
contracts field by field. The k8s question is different: does each edge the cluster adds --
Gateway, TLS, the `/auth` rewrite, NetworkPolicies, rendered Secrets -- carry traffic.
Running all 43 through the cluster re-asks the first question at k8s cost and still misses
the webhook chain. So the e2e set derives from the 43 and condenses to one file per edge:

| File | Edge under test | Derived from |
|---|---|---|
| `01` | client → Envoy; the http→https 308 listener pair | cluster-only |
| `02` | Gateway → `kanae:8000` | 01, 05, 10 |
| `03` | Gateway → `kratos:4433` through the `/auth` rewrite | cluster-only |
| `04` | kanae → kratos whoami, kanae → valkey session cache | 02 |
| `05` | kratos → kanae webhook → postgres -- **the exit gate** | cluster-only |
| `06` | kanae → postgres, write path | 06 |
| `07` | kanae → keto permission check | 07, 12 |
| `08` | kanae → kratos admin (logout), cache invalidation | 04 |

This also dissolves three plan tasks. No scenario calls a Keto or Kratos admin URL, so hurl
never needs in-cluster placement or an admin API exposed. None needs object storage, so
Garage in Docker is not a Phase 9 dependency. And `KRATOS_URL` goes through the Gateway, so
the shared-origin cookie path gets exercised, which the Compose suite's separate Kratos origin
never does.

`05` asserts the webhook without a database client: `GET /members/me` returns
`NotFoundResponse` when there is no row, so a 200 with the registered email proves the webhook
wrote it. `response.ignore: false` on the web_hook and `- hook: session` after it make the
ordering safe -- the session cookie exists only once the row does.

The set is re-runnable, unlike the 43. `05` mints its email and password with hurl's
`{{newUuid}}` and captures the email back from Kratos; `06` deletes the tag it creates.
Re-running hurl against a stack that is already up is the inner loop, so it has to work.

### `init.sh` sets up and seeds; running and teardown are separate commands

This is the integration suite's pattern: `tests/integration/init.sh` brings Compose up and
seeds it, and `test.yml` runs hurl and tears down as separate steps. Two reasons to match it
rather than keep one script that sets up, tests and tears down:

- **The bats files need the stack too.** A single script with a teardown trap only works when
  nothing else uses the cluster. With it, bats needed a `--keep` flag and an "export the path
  I printed" handoff for the secrets file. With the stack simply staying up until the last
  command, hurl and bats run against the same cluster and both workarounds disappear.
- **Each CI step does one thing.** A failure in step 2 is a failing scenario, not "the e2e
  script exited 1".

Seeding stays inside `init.sh` rather than a `seed.sh`. A script only another script calls is
a helper, and the integration `init.sh` already does both jobs.

`init.sh` is idempotent so the loop is cheap: the cluster is reused if it exists, the
namespace is applied rather than created, Kratos 409s fall back to a lookup, the `members`
insert is `ON CONFLICT DO UPDATE`, Keto's PUT is a set-insert, and `PASSWORD` is reused from
an existing `secrets.env` -- a re-run finds the identities already there with the old
password, exactly as the integration script handles it.

`init.sh` waits for the `kanae-migrate` Job to complete before it seeds, by label because
kapp versions the Job's name, and for kanae to be Ready before it exits. `apply-local.sh`
does not wait by default, and the Kratos, Keto and Postgres rollouts say nothing about
kanae's schema: without the Job wait the `members` inserts race the migration, and without
the kanae wait the first scenarios race the pod.

### Measurement is not part of the workflow

`k8s:measure` reads `memory.peak`, `memory.max` and `cpu.stat` from every container's
cgroup: the highest memory the kernel recorded for the container's life, the limit it was
given, and its average CPU. Phase 10 sets the memory requests and limits from those numbers.
It reports rather than passes or fails, so it is not a step of the e2e run or of CI; it is
run separately, against a live cluster, when Phase 10 needs the numbers.

### Teardown is always the last command, never automatic

A failed run leaves the cluster up so it can be looked at. Nothing tears down on failure,
locally or in CI; deleting the cluster is the final step when you are done with it.

### CI and local both run on k3d

One cluster, `deploy/kubernetes/k3d.yml`, everywhere. An earlier draft ran CI on kind with
cloud-provider-kind for the `LoadBalancer`, which put the Gateway on an IP on the `kind`
network. Under Docker Desktop that network is inside Docker's VM and unreachable from WSL,
and cloud-provider-kind's proxy container published 80 on the host but not 443. k3d's loadbalancer publishes 80 and 443 on
`127.0.0.1` from the start, so the same local hurl binary and the same `--resolve kanae:443:127.0.0.1`
work on a laptop and on a runner. k3d is not yet pinned in the workflow.

### Port-forwards live only as long as the seeding

The admin APIs are reached over `kubectl port-forward` to seed, then closed by the script's
EXIT trap. Nothing afterwards needs them. Port-forward goes around the NetworkPolicies rather
than loosening them, so the cluster under test permits nothing production does not;
`netpol.bats` pays for that by asserting the policies still bite.

### `secrets.local.yml` is kept, at a fixed path, beside the harness

`deploy/kubernetes/init.sh --local` generates the chart secrets, reads `LOCAL_VALUES` back when
it exists, and writes it owner-only. The Postgres volume is initdb'd with those passwords
once, so every later apply -- an `init.sh` re-run, and the re-applies in `prune.bats`,
`pvc.bats` and `credentials.bats` -- must render the same values. A fixed path lets the bats
files find it without being told, and keeping it in `tmp-e2e-harness/` rather than the
default `deploy/kubernetes/secrets.local.yml` means a test run never overwrites a developer's
own local secrets.

`init.sh` calls it with stdout to `/dev/null`, not `>"$LOCAL_VALUES"`. The redirect would make
the shell truncate the file before `init.sh --local` read it back, and every re-run would
silently rotate every secret against a database that still has the old ones.

### bats for the internals, one file per concern

Prune, PVC survival, the negative test and the NetworkPolicy probe are about cluster state,
not HTTP, so they go to a shell test runner: they are `kubectl`, `kapp` and `helm` calls, and
bats runs shell with pass/fail per test and nothing else.

One file per concern, with every file leaving the stack as it found it. That is the property
that matters; the file split follows from it. An earlier version merged everything into one
`cluster.bats` because the credential test left the stack broken and had to run last -- and
across files, "last" meant relying on `secrets.bats` sorting after the others. Making the
credential test restore instead removes the ordering constraint, so the files are independent,
any one can run alone, and `bats tmp-e2e-harness/` runs them all. Within `pvc.bats` the two
tests are ordered on purpose: the second reads the rows the first brought back.

Each file carries its own six-line `setup_file` check rather than sharing a `helpers.bash`.
Duplicating a precondition beats a helper file only the tests source.

No `test_` prefix. pytest needs one to discover files; bats runs every `*.bats` in a
directory, so the prefix is noise.

### No bats-assert

bats-assert needs bats-support, and neither is in mise's registry -- only `bats` itself is --
so they would arrive as git submodules or a clone step: two unpinned dependencies for six
tests. What they mostly add is printing `$output` on failure, and bats-core 1.14 already does
that: `run -0` / `run -1` print the captured output when the exit code is wrong, and
`bats --verbose-run` prints every `run`'s output on failure.

### The negative test poisons `kanaePassword` and restarts the pod

`credentials.bats` renders the Secrets from `secrets.local.yml` with
`--set secrets.kanaePassword=not-the-password`, deploys them, and expects
`kubectl rollout status deployment/kanae` to fail with
`password authentication failed for user "kanae"` in the pod's logs.

It has to restart kanae itself. The DSN reaches the pod through the `kanae-config` Secret,
read at startup, and the Deployment's checksum annotation covers `kanae.config.public` only
(`kanae.yml:55`). A Secret change alone does not roll the pod, so without the restart the
poisoned deploy succeeds and the running pod keeps its good connection -- a negative test that
never goes red.

It restores before asserting: re-apply with the real values, restart, wait for the rollout.

## Rejected

- **pytest as the harness** (this document's previous design). A `harness/` package of seven
  modules -- `Toolchain`, `Cluster`, `Fitness`, `GatewayClient`, `Database`, `DisposableApp`,
  `HurlRunner` -- to drive CLIs through `subprocess`, wrap hurl in a serial per-file loop that
  `hurl --test` already does in parallel, and re-implement an HTTP client beside the HTTP test
  tool. Every class was a translation layer between two tools that already talk to each other
  through a shell. Parametrising one generated test per `.hurl` file went with it.
- **One script that sets up, runs hurl and tears down** (`e2e.sh`, then `run.sh`). Correct only
  while nothing else uses the stack. The bats files do.
- **A single `cluster.bats`.** Its only reason was ordering, which the restoring credential
  test removes.
- **hurl from a pod, as the plan specifies.** Needs a NetworkPolicy amendment on Keto and on
  kanae; the test would modify the thing it certifies.
- **Running all 43 through the cluster.** Re-asks the integration suite's question, needs
  Garage and single-shot databases, and still never touches the webhook.

## Deviations from the plan's task list

| Plan task | Here |
|---|---|
| Widen `e2e.sh` to the full scenario directory | Condensed set in `scenarios/`, see above. `deploy/kubernetes/tests/e2e.sh` is untouched until the harness moves |
| `vars.env` with admin URLs at ClusterIP names | `vars.env` has Gateway URLs only; no scenario needs an admin URL |
| Run hurl from a pod | From the host through the Gateway |
| Kubernetes version of the integration `init.sh` | `init.sh`, ported to `kubectl exec` and port-forwards |
| `--secrets-file` as well as `--variables-file` | Yes |
| Garage in Docker | Not needed; no e2e scenario touches storage |
| Start with 01/02/22 | Superseded by the condensed set |
| Negative test: `e2e.sh` fails on a wrong password | `credentials.bats` asserts the rollout fails with the Postgres error |
| Test deletion both ways | `prune.bats`, `pvc.bats` |
| Tear down whether it passed or failed | Not done, by decision: a failed run keeps its cluster |
| `k8s:measure` before the cluster is deleted | Not part of the workflow; run separately |
| Print events and non-Ready pod logs on failure | Deferred, by decision |
| CI job on `kubernetes.yml` | Not done; see below |

The exit gate changes shape accordingly: `init.sh` plus the hurl run go from no cluster to a
signed-up member (`05`) and exit 0, and `credentials.bats` goes red without its restart --
breaking the password on purpose fails the rollout with the Postgres authentication error in
the output.

## Open questions and risks

- **Which image is under test?** `values.local.yml` pins the published `edge` digest, so as
  written Phase 9 certifies a stack that does not run the checkout's code. Building and
  `k3d image import`-ing it would go in `init.sh` step 1.
- **The CI job itself.** Four steps on the existing `kubernetes.yml` behind the same
  paths-filter output -- `init.sh`, hurl against `127.0.0.1`, bats, teardown -- plus
  a nightly `schedule:`, tools installed directly with pinned `<TOOL>_VERSION`. No new
  workflow file. Not written yet. bats is not yet pinned in `mise.toml`.
- **Kratos is OOM-killed by concurrent logins -- found by the first run.** Five password POSTs
  at once (hurl runs files in parallel) killed Kratos with exit 137 at its 512Mi limit: argon2
  takes `memory: 128MB` per hash (`kratos.prod.yml:186`) and nothing bounds concurrency;
  `dedicated_memory: 384MB` is used only by calibration. Production has the same config and
  limit, so four or five simultaneous logins take production Kratos down. The fix belongs in
  the chart, not the harness: a limit sized for the concurrency wanted, or a lower argon2
  `memory`. The harness keeps hurl parallel so it stays red until then; `--jobs 1` passes.
- **Verified on k3d** (Docker Desktop, WSL2): `init.sh` from nothing in 8m48s, then the 18
  scenarios twice with the local hurl binary against `127.0.0.1`. 17 files pass both times;
  15's final `/sudo/audit` 500 is a known kanae bug.
- **Measuring against an e2e cluster.** `memory.peak` lives as long as the container, and
  `pvc.bats` and `credentials.bats` recreate pods, so a measurement taken after bats misses
  Postgres' initdb peak (138Mi in the plan). Measure before running bats, or on a cluster
  bats never touched.
- **Integration scenario 01's CORS assertion** (`http://localhost:5173` vs `https://kanae:5173`)
  is not in the e2e set, but the mismatch would bite if a CORS assertion were added.
- **`ory.publicOrigin`** is settled by the run: `04` and `05` pass, so the Kratos cookie
  survives the `https://kanae:5173` / `https://kanae` mismatch.
- **Still open:** whether the netpol probe reads as a timeout or a refusal (it passes either
  way).

## Next implementation step

Run `init.sh` against a fresh machine, then again against the stack it left, and confirm the
second run changes nothing -- same identities, same `PASSWORD`, Postgres still accepting the
`kanae` role. Everything else sits on that.
