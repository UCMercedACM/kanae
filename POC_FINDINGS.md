# Kanae on Kubernetes — proof-of-concept findings

Written for someone comfortable with normal web development — HTTP, a server
process, a database, maybe Docker — and with **no Kubernetes background at all**.
Every term is explained the first time it shows up.

The short version: we took the stack that already runs under Docker Compose and
made it run on Kubernetes, first on a laptop and eventually on a rented server.
The configuration passed every automated check while being completely broken,
and only actually running it found the real problems. That gap is the main
finding.

---

## Part 1 — The vocabulary, in web-dev terms

Skip this if you already know Kubernetes. Otherwise it is worth five minutes,
because the findings below don't make sense without it.

### The problem Kubernetes solves

With Docker Compose you write a file that says "run these five containers, wire
them together" and it runs them on **one machine**. If a container dies, Compose
can restart it. If the machine dies, everything is gone.

Kubernetes ("k8s") is the same idea scaled up and made self-healing. You don't
tell it *"start this container"*. You tell it *"I want one copy of this container
running, always"*, and a control loop continuously compares reality against that
statement and fixes the difference. Container crashed? It starts a new one.
Machine died? It moves the work elsewhere.

That shift — **describing the desired end state instead of issuing commands** —
is the single biggest conceptual difference, and it explains most of the odd
behaviour further down.

### The pieces

| Kubernetes term | What it actually is |
| --- | --- |
| **Pod** | One running instance of your app. Usually one container. The smallest thing k8s manages. |
| **Deployment** | "Keep N pods of this image running." Handles restarts and rolling updates. Use for stateless things — the API, Kratos, Keto. |
| **StatefulSet** | Same, but for things with a disk and an identity that must survive restarts. Used here for Postgres. |
| **Service** | A stable internal hostname + load balancer. Pods come and go with changing IPs; the Service name doesn't. `database:5432` works because of a Service called `database`. |
| **PersistentVolumeClaim (PVC)** | "I need a 20 GB disk." Survives the pod being destroyed. |
| **ConfigMap** | A config file, injected into a container as a file or env var. |
| **Secret** | The same, for passwords and keys. |
| **Job** | Run this container **once**, to completion, then stop. Used for database migrations. |
| **Init container** | Runs *before* the main container in a pod, and must exit successfully first. A gate. |
| **Readiness probe** | A health check k8s runs repeatedly. Failing means "don't send this pod traffic yet." |
| **Namespace** | A folder to group all of the above. Everything here lives in one called `kanae`. |

### Two more you need for the findings

**Helm** is a templating layer on top of all this. Kubernetes configuration is
YAML, and you'd otherwise copy-paste near-identical YAML for dev and production.
Helm turns it into a template plus a values file — much like an HTML template
rendered with different data. A rendered bundle is called a **chart**, and
installing one is `helm install`.

**k3s** is a stripped-down Kubernetes that runs comfortably on a small server.
**k3d** runs k3s inside Docker on your laptop, so you can test the real thing
locally. Same API, one command to create, one to delete.

---

## Part 2 — What the system looks like

Five services. This is unchanged from Docker Compose — that was deliberate.

```
                    browser / frontend (ucmacm.dev, hosted elsewhere)
                                    │
                              ┌─────┴─────┐
                              │  Ingress  │   routes by URL path
                              └─────┬─────┘
                    /auth ──────────┤──────────── everything else
                        │                              │
                  ┌─────▼─────┐                 ┌──────▼──────┐
                  │  kratos   │◄────webhook────►│    kanae    │
                  │  :4433    │                 │    :8000    │
                  │  :4434    │                 │   the API   │
                  └─────┬─────┘                 └──┬───────┬──┘
                        │                          │       │
                        │        ┌─────────────────┘       │
                        │        │                         │
                  ┌─────▼────────▼─────┐            ┌──────▼──────┐
                  │     database       │            │   valkey    │
                  │   postgres :5432   │            │   :6379     │
                  │  kanae/kratos/keto │            │   cache     │
                  └────────▲───────────┘            └─────────────┘
                           │
                     ┌─────┴─────┐
                     │   keto    │  :4466 read / :4467 write
                     │permissions│
                     └───────────┘
```

| Service | Job |
| --- | --- |
| **kanae** | The actual API. Python, FastAPI-shaped. Everything else exists to support it. |
| **database** | One Postgres holding **three** logical databases: `kanae`, `kratos`, `keto`. |
| **valkey** | A Redis-compatible cache. Presigned upload URLs and rate-limit counters. Pure cache — safe to lose. |
| **kratos** | Ory Kratos. Owns *who you are*: signup, login, sessions, password resets. |
| **keto** | Ory Keto. Owns *what you may do*: "user X is a lead on project Y". |

### The bit that surprises people

Authentication is not in the API. When someone signs up, they talk to **Kratos**,
not to kanae. Kratos creates the identity, then makes an HTTP call *back* into
kanae — a **webhook** — saying "a new person exists, here they are". Kanae
creates its own member row in response.

That means signup touches four services in sequence, and a break anywhere in the
chain looks like "signup is broken" with no indication of where. It's also why
the seed script is valuable: it's the only thing that exercises that whole path.

### Why the service names are hardcoded

Normally a Helm chart prefixes every name with the release name. This one
deliberately doesn't. Kratos's config file contains
`http://kanae:8000/member/webhooks/registration`, and the database connection
strings say `database:5432`. Keeping the Kubernetes Service names identical to
the Compose service names means **those config files need zero changes** between
the two environments. The cost is that everything must live in one namespace,
since these short names only resolve within one.

### Startup ordering, and why it's strange

Docker Compose has `depends_on`: "don't start B until A is healthy". **Kubernetes
has no equivalent across pods.** Its position is that pods are not a workflow
engine — everything starts at once and is expected to cope.

Mostly that's fine here, because the code already fails fast: kanae's database
and cache clients connect eagerly at startup, so if Postgres isn't there the
process exits and Kubernetes restarts it a moment later, backing off a little
each time. That retry loop *is* the dependency management.

One case doesn't fail fast: if the database is up but the **tables** don't exist
yet, kanae starts happily and then errors on every request. So kanae has exactly
one init container that runs a single query and exits non-zero if the table is
missing.

Note *single*. There are no retry loops inside these containers, on purpose —
Kubernetes already retries a failed init container with exponential backoff, so a
loop inside would just duplicate that and hide failures. **A pod showing
`Init:Error` with a climbing restart count during startup is the system working
as designed**, which is deeply counterintuitive if you're used to reading any
error as a problem.

Migrations run as **Jobs** rather than init containers so they run once per
deploy rather than once per pod — two copies of a schema migration racing each
other on a tool that can drop columns is a bad afternoon. Helm orders them with
"hooks" and numeric weights: migrations at weight 0, seeding at weight 10.

---

## Part 3 — What we actually found

The chart was written without ever being run. Then it was run.

### The headline: passing every check meant nothing

Before running anything, the configuration was validated two ways:

- `helm lint` — is the chart structurally valid?
- `kubeconform` — does the generated YAML match the official Kubernetes schemas?

Both passed cleanly, on all configurations, first try. **The stack was still
completely non-functional.** Not degraded — nothing would have started at all.

The reason is that these tools check *shape*, not *meaning*. They confirm that a
health check is a list of strings in the right place. They cannot tell you the
command in that list can never succeed.

### Finding 1 — A health check that could never pass

The single worst bug, and a good illustration of how failures compound.

Postgres's health check was copied from the Docker Compose file, including this:

```sh
Chksum="$$(psql ... )"
```

In Compose, `$$` is an escape — Compose processes the file first and turns `$$`
into a single `$` before the shell ever sees it. **Kubernetes does no such
processing on health check commands.** The shell received a literal `$$`, which
in every shell means "the process ID of this shell". So instead of running
`psql`, it assigned something like `1234(psql ...)` to the variable, compared it
against `0`, and failed. Every time. Forever.

Now the compounding. A failing health check normally just means "don't send this
pod traffic". But the `database` Service is **headless** — a variant that skips
load balancing and publishes DNS records pointing straight at the pod. Headless
Services only publish records for pods that are *passing* their health check.

So: broken check → Postgres never marked healthy → no DNS record for the name
`database` → every connection string in the system fails to resolve →
**nothing in the entire deployment starts**. From one `$` too many.

*Fixed, and confirmed by watching Postgres go healthy and every migration
complete.*

### Finding 2 — Assuming a shell exists

The migration Job ran its command through `sh -c`. Container images are often
minimal and many ship no shell at all. The Compose version never needed one — it
passes arguments straight to the tool. Rewritten to do the same, which also
stopped the migration container from being handed every secret in the system
just to build two connection strings.

### Finding 3 — Security hardening that stopped a container from starting

Valkey crashed immediately:

```
chown: .: Operation not permitted
```

Containers can be stripped of specific privileges. This chart drops all of them,
which is good practice. But Valkey's startup script, *when it starts as the root
user*, tries to take ownership of its data directory — and that requires exactly
one of the privileges that had been removed. Crash loop before the cache ever
started.

The fix is not to hand the privilege back: run the container as its own
non-root user from the start, and the startup script skips that step entirely.
Compose never hit this because its hardening was only applied to the Ory
services, not to Valkey.

**The general lesson:** hardening changes the environment a container starts in,
and images make assumptions about that environment. Applying a security setting
more broadly than before is a behavioural change, not a free win.

### Finding 4 — A fake value that wasn't fake-shaped

For local runs, the setup script fills in credentials it can't know with
throwaway placeholders — for the mail server it produced
`local-dev-kratos-smtp-uri`.

Kratos validates its configuration at startup, and requires that field to look
like a URI (`smtp://...`). It doesn't, so Kratos refused to boot — taking login
and signup with it.

Nothing sends mail locally. The value only has to *parse*. **A placeholder still
has to obey the format of the thing it stands in for.**

### Finding 5 — Two correct features that are mutually exclusive

The API rate-limits `GET /members/me` to 10 requests per minute — sensible.

The seed script creates 15 test members one at a time and calls that endpoint
once per member — also sensible.

Together: member 11 gets rejected, the script reads no user ID from the
rejection, and it fails with `did not resolve an identity` — a message that
says nothing about rate limiting. It fails at the same point every run.

Neither component is wrong. The interaction is. The rate limiter is now off for
local runs only.

### Finding 6 — The private image trap

The local configuration pointed at the published API image. A fresh cluster
can't pull it: the package is private and the cluster has no credentials, so
pods sat in `ImagePullBackOff`.

What makes this nasty: running `docker pull` on the same tag **works** — your
laptop has credentials saved from a past login that the cluster doesn't share.
So the obvious way to check whether the image is reachable gives you the wrong
answer with total confidence.

Local runs now build the image and load it directly into the cluster, with the
tag marked never-pull so nothing reaches for a registry.

### One more, about process

Partway through, a stale install command from an earlier step was still running
in the background. The cluster got deleted and recreated underneath it, and that
old process happily re-created its deployment in the *new* cluster, colliding
with the clean run. Ten minutes went into debugging a "bug" that was two
commands overlapping.

**With declarative systems, a command isn't finished when it returns — it's
finished when the cluster stops changing.** Check what's still running before
concluding anything.

---

## Part 4 — Where it stands

Verified working, by running it:

- All five services start and pass health checks
- All three database migrations complete
- The startup gates behave correctly — they fail, retry, and then succeed once
  their dependency lands
- The secret-provisioning script works and is safe to re-run (it keeps existing
  values rather than regenerating them, which matters: one of those keys encrypts
  user data at rest, and regenerating it makes existing accounts unreadable)
- Signup works end to end — creating an account mints an identity in Kratos,
  fires the webhook into kanae, and the new member is immediately readable
  through the API. That's the four-service chain from Part 2, working.

Not working:

- **The seed script doesn't finish.** It gets partway through the 15-member
  roster and fails, retries, gets a bit further. Turning off the rate limiter
  moved it past the point it was stuck at but didn't complete it. Everything
  except the bulk test data is usable.

Not attempted:

- Deploying to the real server. Nothing has run anywhere but a laptop.
- Backups. Scheduled, but the backup tool's own configuration doesn't exist yet,
  and it's unconfirmed whether the version in use can even write to the intended
  storage.
- Resource limits. Deliberately absent until there are real measurements.

---

## Part 5 — What to take away

**Schema validation is not verification.** Every check passed on a configuration
where nothing could start. Useful for catching typos, worthless for catching
meaning. Budget for running the thing.

**Translating between orchestrators is not copying.** Four of the six findings
are the same shape: something carried over from Docker Compose that Kubernetes
interprets differently — escaping rules, dependency ordering, privileges,
image resolution. Any line copied across deserves the question *"does the
receiving system read this the same way?"*

**Failures surface far from their cause.** One extra `$` presented as total DNS
failure. A rate limit presented as an authentication error. Reading the error
message literally would have sent you the wrong way every single time.

**Errors during startup are often normal here.** Restart counts climbing while
things converge is the design, not a symptom. You have to know that before you
can debug anything.

---

*Files: the chart lives in `deploy/helm/`, with `HANDOFF.md` for design
decisions and `README.md` for the chart specifically. `RUNNING.md` at the repo
root is the practical guide — how to start it, and a troubleshooting table keyed
on the exact errors above.*
