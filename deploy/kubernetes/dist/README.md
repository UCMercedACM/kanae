# Do not edit anything in this folder by hand

`mise run k8s:render` generates it from the chart in `deploy/kubernetes/src/`,
one file per resource, and `mise run k8s:apply` hands it to kapp. This is what
runs in production.

`mise run k8s:render:check` fails on any difference between this folder and what
the chart renders today, so a hand edit is reverted by the next render and
reported by CI before that.
