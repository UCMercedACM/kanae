# Do not edit anything in this folder by hand

`mise run k8s:render` generates it from the chart in `deploy/kubernetes/src/`,
one file per resource, and `mise run k8s:apply` hands it to kapp. This is what
runs in production.

`mise run k8s:render:check` fails on any difference between this folder and what
the chart renders today, so a hand edit is reverted by the next render and
reported by CI before that.

## Windows

`deploy/kubernetes/src/files/` holds symlinks to files elsewhere in the
repository, and a Windows checkout writes each one as a plain text file holding
the link's path unless `core.symlinks` is on. Git cannot fix this from inside
the repository. The setting lives in `.git/config`, which `clone` creates and
never fetches, and there is no `.gitattributes` equivalent. Clone with
`git clone -c core.symlinks=true`, or run `git config core.symlinks true` and
check out again. `mise run helm:files` fails on such a checkout and says so,
and nothing renders until it passes.

Such a checkout cannot damage the repository. Git keeps recording those entries
as symlinks: `git status` reads clean and `git add -A` leaves each one at mode
`120000`.
