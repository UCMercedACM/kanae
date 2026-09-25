# Phase 9: the end-to-end test

This document supersedes the Phase 9 task list in `KANAE_INFRA_PLAN.md:1607-1690` where the
two disagree. The harness lives in `deploy/kubernetes/tests/`.

Use it to prove three things on a k3d cluster:

- A browser registration reaches a `members` row, across Envoy, Kratos, kanae and Postgres.
- A wrong app database password fails kanae's rollout with Postgres's own error.
- kapp deletes what leaves the render, and keeps the Postgres claim and its data.

## Run it

```console
$ deploy/kubernetes/tests/init.sh
$ hurl --test --insecure --resolve kanae:443:127.0.0.1 --resolve kanae:80:127.0.0.1 \
    --variables-file deploy/kubernetes/tests/vars.env \
    --secrets-file deploy/kubernetes/tests/secrets.env \
    deploy/kubernetes/tests/scenarios/*.hurl
$ bats --verbose-run deploy/kubernetes/tests/
$ k3d cluster delete --config deploy/kubernetes/k3d.yml
```

Run the four commands in this order. Run hurl before bats: `pods.bats` checks for restarts
under hurl's load, and `pvc.bats` recreates every pod.

Delete the cluster last, and only when you are done with it. Nothing tears down on failure;
look at a failed cluster before you delete it.

Run `init.sh` on a machine with no `kanae` cluster. It creates the cluster and the namespace
unconditionally, so it fails against a cluster that already exists. To get back a stack that
a test broke, run `deploy/kubernetes/scripts/apply-local.sh`.

## Layout

```
deploy/kubernetes/tests/
├── init.sh              committed   cluster up, apply, seed, then exit
├── vars.env             committed   Gateway URLs, admin ClusterIP URLs, seed emails
├── secrets.env          gitignored  PASSWORD + identity UUIDs, written by init.sh
├── scenarios/*.hurl     committed   18 HTTP scenarios
├── scripts/dump.sh      committed   cluster state for a failed CI run
└── *.bats               committed   7 cluster-internal test files
```

| File | What it does |
|---|---|
| `init.sh` | Creates the k3d cluster from `deploy/kubernetes/k3d.yml`. Installs Cilium, Envoy Gateway, cert-manager and the Gateway. Renders the chart into `.k8s-local` without Secrets. Renders the Secrets from `deploy/kubernetes/init.sh --local`. Applies both as the kapp app `kanae-local`, then waits for `certificate/kanae-tls` Ready and `gateway/kanae` Programmed. Creates six identities through the Kratos admin API, upserts their `members` rows and writes their Keto role tuples, all with `kubectl exec deploy/kanae -- curl` or `psql`. Writes `secrets.env` and prints the hurl command. |
| `vars.env` | `KANAE_URL`, `KANAE_HTTP_URL` and `KRATOS_URL` through the Gateway. `KRATOS_ADMIN_URL` and `KETO_WRITE_URL` at ClusterIP names, for `init.sh` only. The six `*_EMAIL`. |
| `secrets.env` | `PASSWORD` and `ROOT_ID` to `SCRATCH_ID`, for `hurl --secrets-file`. `init.sh` reuses `PASSWORD` if the file exists. |
| `deploy/kubernetes/secrets.local.yml` | Every chart secret, written by `deploy/kubernetes/init.sh --local`, which reads the file back and keeps its values. Postgres is initialised with these once; every later apply has to render the same values. This is the same file your local stack uses. |

## hurl scenarios

Put every HTTP assertion in hurl. Send every request through the Gateway; no scenario uses an
admin URL. Make every file re-runnable against a stack that stays up: mint emails and
passwords with `{{newUuid}}`, and delete what you create.

| File | Covers |
|---|---|
| `01_client_to_envoy` | Envoy's https and http listeners, the 308 redirect |
| `02_envoy_to_kratos_rewrite` | Kratos's public port through the `/auth` rewrite |
| `03_envoy_to_kanae` | kanae:8000 through the `/` route |
| `04_kratos_to_kanae_webhooks` | the registration and settings webhooks writing `members`; **the exit gate** |
| `05_password_change_revokes_sessions` | password change revoking other sessions |
| `06_kanae_to_kratos_sessions_logout` | kanae to Kratos whoami and admin logout |
| `07_kanae_to_valkey_cache` | the whoami cache in Valkey |
| `08_kanae_to_keto_grants` | kanae to Keto read and write |
| `09_seeded_role_matrix` | the seeded roles against the role gates |
| `10_kanae_to_postgres` | kanae's write path to Postgres |
| `11_leads_event_attendance` | the event journey for LEADS |
| `12_manager_project_journey` | the project journey for MANAGER |
| `13_kratos_to_internet_hibp_and_csrf` | Kratos's internet egress (HIBP) and CSRF |
| `14_two_factor_backup_codes` | two-factor with backup codes |
| `15_promotion_step_up_sudo` | promotion and step-up sudo |
| `16_self_delete_account` | account self-deletion |
| `17_sequential_argon2_load` | sequential argon2 load on Kratos |
| `18_one_member_start_to_finish` | one member through every flow |

## bats files

Put in bats only what hurl cannot see from outside the Gateway.

| File | Mutates | Asserts |
|---|---|---|
| `credentials.bats` | yes, restores | a poisoned `kanaePassword` fails kanae's rollout with `password authentication failed for user "kanae"` in its logs |
| `migrate.bats` | no | the three migrate Jobs succeeded with no failed pod; every table belongs to its `*_migrate` role; the `kanae` role cannot create a table |
| `netpol.bats` | no | from `envoy-gateway-system`, kanae:8000 and kratos:4433 open, and Kratos admin, both Keto ports, Valkey and Postgres closed; an unlabelled pod in `kanae` gets DNS and nothing else |
| `pods.bats` | no | no container has restarted and no pod has failed |
| `prune.bats` | yes, restores | kapp deletes the `postgres-checksum` CronJob when it is dropped from a copy of `.k8s-local` |
| `pvc.bats` | yes, restores | after `kapp delete`, the claim stays Bound; after the re-apply, the claim and the `kanae-db` Secret keep their UIDs and the `members` rows keep their count and id digest |
| `valkey-acl.bats` | no | the `default` user gets PING and nothing else; `kanae` authenticates, and is refused keys outside its patterns and admin commands |

Follow these rules when you add or change a bats file:

- Leave the stack as you found it. In a mutating test, record each step's status with `run`,
  restore, then assert.
- Keep every file runnable alone and in any order. Do not pass `--jobs`; the files share one
  cluster.
- Start every file with a `setup_file` that refuses to run unless the kube context is
  `k3d-kanae` and `deployment/kanae` exists. In files that re-apply, also refuse unless
  `secrets.local.yml` matches the live `kanae-db` Secret.
- Copy that precondition into each file. Do not add `helpers.bash` or any shared file.
- Write every `@test` out. Do not generate tests in a loop.
- Use `[[ ]]`, `run -0` and `run -N`. Do not add bats-assert or bats-support.
- Do not use `sleep`, polling loops, background processes or port-forwards. Wait with
  `kubectl wait` or `kubectl rollout status` and a timeout.
- Name the container on every `kubectl exec statefulset/database`: `-c postgres`.
- Read `valkey-cli`'s reply text. It exits 0 on an error reply.
- Probe a NetworkPolicy from a namespace that no policy selects, and repeat an open control in
  every deny test. A probe pod in `kanae` is refused by `default-deny`'s egress rule whatever
  the target's policy says.
- After a widened policy, confirm the deny tests go red before you trust them green.
- Do not edit the chart or add a policy exception to make a test pass.

## The negative test

Poison `kanaePassword`, not `dbPassword`. `_helpers.tpl` builds the app's DSN from
`kanaePassword`; `dbPassword` is only used at initdb.

In `credentials.bats`:

1. Render the Secrets with `--set secrets.kanaePassword=not-the-kanae-password`.
2. Deploy them with `kapp deploy ... --wait=false`.
3. Run `kubectl rollout restart deployment/kanae`. The pod's checksum annotation does not
   cover the Secret, so nothing else rolls it.
4. Run `kubectl rollout status` with a 120s timeout, and expect it to fail. Do not use
   `kubectl wait --for=condition=Available`.
5. Collect the current and the `--previous` container logs.
6. Restore with `apply-local.sh` at `WAIT=false`, restart again, and wait for the rollout.
7. Assert.

## CI

Run the e2e in the `Test` job of `.github/workflows/kubernetes.yml`, behind the `Changes`
paths filter. Also run it every night at 06:00 UTC on `main`, whatever changed. Install
every tool directly with a pinned `<TOOL>_VERSION` or commit; do not use mise.

Pin bats in the job's `env` and install it in the "Install BATS" step:

```yaml
env:
  BATS_COMMIT: eb7f42f8d608ac693d7a4b67474f6714ea68cfc5 # v1.14.0
```

```bash
git clone --quiet --depth 1 --revision "$BATS_COMMIT" \
  https://github.com/bats-core/bats-core.git /tmp/bats-core
sudo /tmp/bats-core/install.sh /usr/local
```

`clone --revision` needs git 2.49 or later. To bump bats, take the new commit from
`git ls-remote https://github.com/bats-core/bats-core.git 'refs/tags/v<version>^{}'`.

Run the steps in this order: "Prepare cluster" (`init.sh`), "Run tests" (hurl), "Run cluster
tests" (`bats --verbose-run deploy/kubernetes/tests/`), "Dump cluster state", "Clean up
cluster". Do not add an `if:` to the bats step; it runs only when hurl passes.

Give "Dump cluster state" `if: ${{ failure() }}` and have it run
`deploy/kubernetes/tests/scripts/dump.sh`. The script prints each section under a `log` header:
pods in every namespace, Warning events in every namespace, `describe` of `gateway/kanae` and
`certificate/kanae-tls`, then for each non-Ready pod in `kanae` its `describe`, each started
container's last 200 log lines, and the `--previous` log of each container that restarted.

## Exit gate

On a machine with no cluster:

1. `init.sh` exits 0.
2. hurl passes, including `04_kratos_to_kanae_webhooks`.
3. `bats deploy/kubernetes/tests/` passes, including `credentials.bats`.

## Measuring

Run `mise run k8s:measure` on its own, against a live cluster, when Phase 10 needs numbers.
Run it after hurl and before bats. `pvc.bats` and `credentials.bats` recreate pods, and
`memory.peak` resets with the container.

## Known issues

- `init.sh` cannot be re-run against a live cluster.
- The e2e uses `deploy/kubernetes/secrets.local.yml`, the same file as your local stack.
- `values.local.yml` pins the published `edge` image by digest, so the e2e does not test the
  checkout's own kanae code.
- If a mutating bats file is interrupted or its restore step fails, the stack stays broken.
  Its `setup_file` then reports a secrets mismatch or a missing stack. Run `apply-local.sh` to
  recover.

## Deviations from the plan's task list

| Plan task | Here |
|---|---|
| Widen `e2e.sh` to the full scenario directory | 18 scenarios in `scenarios/`, one per edge or journey |
| `vars.env` with admin URLs at ClusterIP names | Yes, used by `init.sh` only |
| Run hurl from a pod | Run it from the host through the Gateway |
| Kubernetes version of the integration `init.sh` | `init.sh`, using `kubectl exec` |
| `--secrets-file` as well as `--variables-file` | Yes |
| Garage in Docker | Not needed; no scenario touches object storage |
| Start with 01/02/22 | Superseded by the 18 scenarios |
| Negative test: `e2e.sh` fails on a wrong password | `credentials.bats` |
| Test deletion both ways | `prune.bats` and `pvc.bats` |
| Tear down whether it passed or failed | Not done; a failed run keeps its cluster |
| `k8s:measure` before the cluster is deleted | Run on its own, see Measuring |
| Print events and non-Ready pod logs on failure | The "Dump cluster state" step |
| CI job on `kubernetes.yml` | The `Test` job, plus a nightly `schedule:` |
