# How to run the signup load test

`locustfile.py` in this folder is a [Locust](https://locust.io) scenario that
registers fresh identities through Kratos's browser flow, the same path the
Chapter-Website and the hurl scenarios take. It measures Kratos memory
against a candidate limit, because every password operation in Kratos
allocates a full `hashers.argon2.memory` block and nothing in Kratos bounds
how many run at once. `KRATOS_MEMORY_LOAD_STUDY.md` beside it has the
measurements the script was built for and what they mean for the node
budget.

## Run it against the cluster

Locust is not a project dependency. Run it with `uvx`, which fetches it into
a throwaway environment. The paths below are relative to the repository
root.

```sh
kubectl -n kanae port-forward svc/kratos 4433:4433 &

# 4 signups in flight at all times for 60 s. This is what `hurl --test` on a
# 4-CPU machine does to Kratos, because --test runs files in parallel, one
# job per CPU.
LOAD_MODE=closed uvx locust -f deploy/kubernetes/docs/kratos-load-study/locustfile.py \
    --headless -u 4 -r 4 -t 60s -H http://127.0.0.1:4433 --csv /tmp/closed4

# Poisson arrivals at 2 signups/s for 60 s. -u only caps the pile-up.
LOAD_MODE=open LOAD_RATE=2 uvx locust -f deploy/kubernetes/docs/kratos-load-study/locustfile.py \
    --headless -u 20 -r 20 -t 60s -H http://127.0.0.1:4433 --csv /tmp/open2

mise run k8s:measure   # PEAK (Mi) against LIMIT (Mi) for the kratos container
```

`--csv` writes `<prefix>_stats.csv` with the request count, failures, and
latency percentiles for `init flow` and `submit password`. A failed
`submit password` row means the registration did not return a session.

Every signup creates an identity, a verification message for the courier,
and a webhook call into kanae. Run it against a throwaway database, or delete
the `load-*@ucmerced.edu` identities afterwards.

## Run it through the Gateway

To measure the Envoy proxy as well as Kratos, point `-H` at the Gateway's
`/auth` prefix and trust the local issuer's certificate:

```sh
LOAD_MODE=closed LOAD_CA_BUNDLE=/path/to/local-ca.pem \
    uvx locust -f deploy/kubernetes/docs/kratos-load-study/locustfile.py \
    --headless -u 4 -r 4 -t 60s -H https://kanae/auth --csv /tmp/gateway4

mise run k8s:measure --namespace envoy-gateway-system
```

The rate limit on the registration POST applies on this path. Above
`gateway.authRateLimit.requestsPerSecond`, `submit password` rows fail with
429, which is the limiter working, not Kratos failing.

## Measure the node's capacity

The study's rate limit rests on the slowest signup capacity it measured, 5.1
per second. To find the production node's own number, run the closed mode at
`-u 4` for 60 s and read `submit password` requests per second from the
stats CSV. If it is under 5, re-solve the limit as the study's "Rate limit"
section shows.

## Variables

| variable | default | meaning |
| --- | --- | --- |
| `LOAD_MODE` | `closed` | `closed`: `-u` users sign up back-to-back, so `-u` is the concurrency. `open`: Poisson arrivals at `LOAD_RATE` per second. |
| `LOAD_RATE` | `1` | Aggregate signups per second in `open` mode. |
| `LOAD_SEED` | `1` | Seed for the arrival gaps, so a run can be repeated. |
| `LOAD_EMAIL_DOMAIN` | `ucmerced.edu` | Domain of the generated addresses. |
| `LOAD_CA_BUNDLE` | unset | Path of a CA certificate to trust for an HTTPS host, such as the self-signed one the local Gateway serves. Locust ignores `REQUESTS_CA_BUNDLE`. |

## Read the result

- In `closed` mode the peak that `k8s:measure` reports is the cost of that
  many simultaneous hashes. The study found about 230 Mi per concurrent
  signup with Go's default collector and the 128MB hasher, about 115 Mi
  with `GOMEMLIMIT` set, and about 50 Mi with the 64MB hasher this branch
  ships.
- In `open` mode compare `submit password` requests per second with
  `LOAD_RATE`. If it falls short and the median latency climbs across the
  run, Kratos is behind the arrivals and memory grows until the limit kills
  it. That is a capacity result, not a memory-limit result, and no limit
  under the node size changes it.
