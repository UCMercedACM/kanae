# Phase 9 bats: how the final set was picked

Four models wrote candidates independently, each in its own worktree at
`~/GHLR/worktrees/kanae/bats-<model>/kanae/phase9-bats-scenarios/<model>/`.
The final set lives in `deploy/kubernetes/tests/*.bats`, beside the hurl
scenarios, because that is the only place its paths resolve. The full decision
trail is `.audits/phase9-e2e-scenarios/decisions.tsv`, rows `bats-*`.

## Live results

One fresh k3d cluster from `deploy/kubernetes/tests/init.sh`, one
`secrets.local.yml` symlinked into every worktree, hurl run once before any
bats. Each candidate ran file by file against the same stack.

| Candidate | Pass | Failures |
|---|---|---|
| Opus | 12/12 | none |
| Fable | 23/27 | 3 migrate ownership tests and the seeded-row count: `kubectl exec` without `-c postgres` puts `Defaulted container ...` in `$output` |
| Sonnet | 15/19 | 4 Valkey ACL refusals assert a non-zero exit; `valkey-cli` exits 0 on NOPERM |
| Haiku | 6/6 | none, but calls `mise exec -- helm`, which CI does not have |

Then the Keto NetworkPolicy was widened to `ingress: [{}]` and every
`netpol.bats` run again. Opus went red on 4466 and 4467, Fable on 4466.
Sonnet and Haiku stayed green: their probe pod sits in `kanae`, where
`default-deny` blocks its own egress, so the refusal never depended on Keto's
policy. The policy was restored with `apply-local.sh`.

## The final set

Base is Opus: the only candidate green everywhere and red under the mutation
on both Keto ports.

| File | From | Change |
|---|---|---|
| `credentials.bats` | Opus | none |
| `netpol.bats` | Opus | none |
| `pods.bats` | Opus | header notes that `credentials.bats` sorts first and replaces kanae's pod |
| `prune.bats` | Opus | none |
| `pvc.bats` | Opus | adds Fable's check that the `kanae-db` Secret keeps its UID across `kapp delete` |
| `migrate.bats` | Fable | `-c postgres` on its four psql execs; guard message matches the others |
| `valkey-acl.bats` | Fable | guard message matches the others |

## Left out

- Sonnet's and Haiku's `netpol.bats`. The mutation run showed they cannot go red.
- Fable's "keto cannot reach kanae" and "kanae cannot reach the internet". `run !` passes on any exec error, and the second passes on an offline runner.
- Sonnet's `secrets_render_gate.bats`. It only runs `helm template`, so it belongs in `validate.sh`.
- Sonnet's SET/GET/DEL test and its kanae-to-Postgres and kanae-to-Valkey `curl -v` controls. hurl 07 and 10 already prove both edges.
- Fable's `restarts.bats`. Opus's `pods.bats` covers init containers and failed pods too.
- All of Haiku. It is the draft with paths changed.

## Verification

- `bats --count`: 23. `shellcheck -s bash`: clean.
- `bats deploy/kubernetes/tests/` on the live cluster: 23 of 23 in 318s.
- `credentials.bats` twice back to back: the second run started with a
  `restartedAt` annotation on the pod template and passed.
- hurl afterwards: 16 of 18. `15` is the known `/sudo/audit` 500. `07` missed a
  3000ms bound at 3293ms with every correctness assert green; `13` missed a
  similar bound on the first run and passed on the second.

Not verified: the suite on a GitHub runner, or on a cluster where hurl
actually restarted a pod, so `pods.bats` has never been seen red.
