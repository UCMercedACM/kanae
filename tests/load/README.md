# Signup load test

A [Locust](https://locust.io) scenario that registers fresh identities through
Kratos's browser flow, the same path the Chapter-Website and the hurl scenarios
take. It exists to measure Kratos memory against a candidate limit, because every
password operation in Kratos allocates a full `hashers.argon2.memory` block
(128MB in `docker/ory/config/kratos/kratos.prod.yml`) and nothing in Kratos
bounds how many run at once. `infra-plans/KRATOS_MEMORY_LOAD_STUDY.md` has the
measurements this was built for and what they mean for the node budget.

## Running it

Locust is not a project dependency. Run it with `uvx`, which fetches it into a
throwaway environment:

```sh
kubectl -n kanae port-forward svc/kratos 4433:4433 &

# 4 signups in flight at all times for 60 s (what `hurl --test` on a 4-CPU
# machine does to Kratos, since --test runs files in parallel, one job per CPU)
LOAD_MODE=closed uvx locust -f tests/load/locustfile.py --headless \
    -u 4 -r 4 -t 60s -H http://127.0.0.1:4433 --csv /tmp/closed4

# Poisson arrivals at 2 signups/s for 60 s; -u only caps the pile-up
LOAD_MODE=open LOAD_RATE=2 uvx locust -f tests/load/locustfile.py --headless \
    -u 20 -r 20 -t 60s -H http://127.0.0.1:4433 --csv /tmp/open2

mise run k8s:measure   # PEAK (Mi) against LIMIT (Mi) for the kratos container
```

`--csv` writes `<prefix>_stats.csv` with the request count, failures and
latency percentiles for `init flow` and `submit password`. A failed
`submit password` row means the registration did not return a session.

Every signup creates an identity, a verification message for the courier and a
webhook call into kanae. Run it against a throwaway database, or delete the
`load-*@ucmerced.edu` identities afterwards.

## Variables

| variable | default | meaning |
| --- | --- | --- |
| `LOAD_MODE` | `closed` | `closed`: `-u` users sign up back-to-back, so `-u` is the concurrency. `open`: Poisson arrivals at `LOAD_RATE`/s. |
| `LOAD_RATE` | `1` | Aggregate signups per second in `open` mode. |
| `LOAD_SEED` | `1` | Seed for the arrival gaps, so a run can be repeated. |
| `LOAD_EMAIL_DOMAIN` | `ucmerced.edu` | Domain of the generated addresses. |
| `LOAD_CA_BUNDLE` | unset | Path of a CA certificate to trust for an HTTPS host, such as the self-signed one the local Gateway serves. Locust ignores `REQUESTS_CA_BUNDLE`. |

## Reading the result

- In `closed` mode the peak `k8s:measure` reports is the cost of that many
  simultaneous hashes. The study found about 230Mi per concurrent signup with
  Go's default garbage collector and about 115Mi with `GOMEMLIMIT` set.
- In `open` mode compare `submit password` requests/s with `LOAD_RATE`. If it
  falls short and the median latency climbs across the run, Kratos is behind
  the arrivals and memory will keep growing until the limit kills it. That is
  a capacity result, not a memory-limit result, and no limit under the node
  size changes it.
