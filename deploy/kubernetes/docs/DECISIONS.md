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
