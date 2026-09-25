# Kratos memory under signup load

Measured 2026-09-25 against Kratos v26.2.0 with the production hasher settings.
The question was how large a memory limit the Kratos pod can be given on the
3 vCPU, 4 GB node the infra plan budgets against, with tolerance, under heavy
signup load such as 75 signups per second.

## The answer

**1536Mi request and limit, with `GOMEMLIMIT=1400MiB` in the container's
environment.** That configuration survived every verification trial (0 OOM
kills in 12), including 8 simultaneous signups and a sustained Poisson arrival
rate of 4 signups per second, which is above what 3 CPUs can hash. The 1Gi limit
in use today was OOM-killed in 11 of 12 trials with Go's default collector, two
of them at only 2 signups per second. 1Gi with `GOMEMLIMIT=900MiB` holds 4
simultaneous signups and 2 signups per second, and nothing more.

**75 signups per second is not a memory-limit question on this node.** Kratos
sustained at most 6 signups per second on the 3 CPUs used here, and the
production node's own hash time is unknown: the 504 ms `DECISIONS.md` recorded
in-cluster came from a calibrate command that adds about half a second of its
own overhead to every hash (see "Calibrating the hasher" below). Above capacity, in-flight hashes pile up and the cgroup grows at 221 MiB/s
(SD 16, n = 15) until whatever limit is set kills the container: 3 s at 1Gi,
5 s at 1.5Gi, 16 s at 4Gi, which is the whole node. A larger limit only buys
seconds. Every rate of 10 signups per second or more was OOM-killed at 4Gi
within a 20 s trial (5 of 6 trials at 10 and 15/s, 12 of 12 at 20 to 75/s). What
makes 75/s survivable is admission control in front of Kratos, not memory.

## Why Kratos behaves this way

- Every password operation calls `argon2.IDKey` directly. `Generate` in
  [`hash/hasher_argon2.go` at v26.2.0](https://github.com/ory/kratos/blob/v26.2.0/hash/hasher_argon2.go)
  has no semaphore, mutex, channel or queue around it. `DECISIONS.md`
  ("Kratos is sized at 512Mi against argon2, because nothing else bounds it")
  already records this.
- Each call allocates its own block array, `B := make([]block, memory)`, in
  `initBlocks` of
  [`golang.org/x/crypto/argon2/argon2.go`](https://github.com/golang/crypto/blob/master/argon2/argon2.go).
  With `hashers.argon2.memory: 128MB` in
  `docker/ory/config/kratos/kratos.prod.yml` lines 179 to 189, that is 128MB of
  live heap per concurrent signup.
- Go's collector sizes the heap from the live heap. With the default `GOGC=100`
  the target is live heap plus 100% of it, so freed hash blocks are not
  reclaimed until the heap has doubled, and the runtime returns freed pages to
  the kernel lazily. `GOMEMLIMIT` makes the collector work harder as total
  runtime memory approaches the limit, and the [Go GC guide](https://github.com/golang/website/blob/master/_content/doc/gc-guide.html)
  suggests leaving 5 to 10% of headroom under a container limit for memory the
  runtime does not account for. The guide also warns the GC caps itself at 50%
  CPU, so a limit below the live set thrashes rather than helps.
- Exceeding the container limit invokes the kernel OOM killer, which stops the
  process and restarts the container
  ([Kubernetes: resource management](https://github.com/kubernetes/website/blob/main/content/en/docs/concepts/configuration/manage-resources-containers.md)).
  A restart drops every in-flight signup.

Both measured slopes below match this arithmetic: about 231Mi per concurrent
signup with defaults, which is two 128MB blocks, and about 113Mi with
`GOMEMLIMIT` binding, which is one block.

## Method

**Where.** A 4-CPU, 16 GB sandbox with no Docker daemon, so not the k3d cluster.
Kratos v26.2.0 (the release binary, build 9d70859) ran from
`docker/ory/config/kratos/kratos.prod.yml` with only environment-specific keys
changed: DSN, base URLs, the webhook target, `haveibeenpwned_enabled` (needs
egress) and the SMTP host. The `hashers`, `session`, flow and hook blocks were
verified identical by diff. The DSN was Postgres 16 with the production
`max_conns=20&max_idle_conns=4` (production runs Postgres 18). kanae's
registration webhook was a stub answering 200 after 10 ms, since
`response.ignore: false` makes Kratos block on it; the courier delivered each
verification mail to a local SMTP sink, so the background work Kratos does after
a signup ran too.

**CPU.** Kratos was pinned to CPUs 0 to 2 with `taskset`, the node's 3 vCPU.
Locust, Postgres and the stubs ran on CPU 3. In production Postgres competes
with Kratos for the same three cores, so Kratos would be slower there than
measured here, on top of the slower CPU.

**Memory.** Each trial ran Kratos in a fresh cgroup with an enforced
`memory.limit_in_bytes`, and read `memory.max_usage_in_bytes` afterwards. That
is the cgroup-v1 name for the `memory.peak` that
`deploy/kubernetes/scripts/measure.sh` reads, so the numbers here are the
numbers `mise run k8s:measure` would show. OOM kills were read from
`memory.oom_control`. The high-water mark was reset after Kratos reported ready,
so startup is excluded and idle is 445Mi.

**Load.** `tests/load/locustfile.py`, driving the same browser registration
flow the Chapter-Website and the hurl scenarios use. Two arrival models:

- closed: C users each signing up back-to-back, so C is the number of hashes
  in flight;
- open: Poisson arrivals at a target rate, with exponential gaps so there is
  no start-up burst, and a user cap of 6 × rate so pile-up is bounded.

**Design and bias control.** 159 trials in three phases:

| phase | factors | levels | reps | trials |
| --- | --- | --- | --- | --- |
| 1 | concurrency, Go defaults, 12Gi cgroup | C ∈ {1, 2, 3, 4, 6, 8, 12, 16, 24, 32} | 3 | 30 |
| 1 | Poisson rate, 4Gi cgroup (the node) | 1, 2, 4, 6, 8, 10, 15, 20, 30, 50, 75 /s | 3 | 33 |
| 1 | concurrency × `GOMEMLIMIT` | C ∈ {1, 2, 4, 8, 16, 32} × {768MiB, 1536MiB} | 3 | 36 |
| 2 | plateau check, 60 s instead of 20 s | C ∈ {4, 6, 8} | 2 | 6 |
| 2 | `hashers.argon2.parallelism` 3 vs 16 | C ∈ {2, 4} | 3 | 6 |
| 3 | verification: limit × `GOMEMLIMIT` × load | {1Gi, 1Gi+900MiB, 1.5Gi+1400MiB, 2Gi+1850MiB} × {C=4, C=8, 2/s, 4/s} | 3 | 48 |

Within each phase the trial order was shuffled with a recorded seed
(20260925, 7, 11) so drift in the machine could not line up with a factor
level. Every trial started a new Kratos process, a new cgroup and a new
database cloned from the migrated template, so heap retention and table growth
could not carry over. Arrival gaps used a per-replicate seed so replicates
differ by design, not by accident. Trials lasted 20 s unless stated; the 60 s
check found the 20 s peaks 3% low at C=4, 13% low at C=6 and 10% low at C=8,
so the 20 s peaks at C ≥ 6 are slightly censored and the models below include
the 60 s points. Intervals are 95% two-sided t intervals; regressions are
ordinary least squares with prediction intervals. The trial data is in
`kratos-memory-trials.csv` beside this file.

## Results

### A. Peak memory against concurrent signups, Go defaults

| in flight | n | peak Mi, mean [95% CI] | signups/s | p50 ms | p95 ms |
| --- | --- | --- | --- | --- | --- |
| 1 | 3 | 446 [442, 451] | 5.30 ± 0.03 | 170 | 193 |
| 2 | 3 | 634 [297, 970] | 6.03 ± 0.39 | 283 | 737 |
| 3 | 3 | 1090 [914, 1267] | 5.16 ± 0.40 | 397 | 1600 |
| 4 | 3 | 1281 [1269, 1293] | 4.95 ± 0.22 | 560 | 2067 |
| 4, 60 s | 2 | 1316 [1283, 1349] | 5.14 ± 0.04 | 570 | 1650 |
| 6 | 3 | 1604 [1465, 1742] | 4.60 ± 0.24 | 823 | 3467 |
| 6, 60 s | 2 | 1807 [1271, 2343] | 5.15 ± 0.17 | 900 | 2250 |
| 8 | 3 | 1995 [1768, 2223] | 3.91 ± 0.38 | 1333 | 4767 |
| 8, 60 s | 2 | 2206 [1899, 2512] | 4.98 ± 0.08 | 1200 | 3750 |
| 12 | 3 | 2169 [2136, 2202] | 3.84 ± 0.30 | 1900 | 7867 |
| 16 | 3 | 3320 [2463, 4177] | 1.82 ± 1.16 | 8733 | 13000 |
| 24 | 3 | 4131 [3461, 4800] | 1.17 ± 0.16 | 15667 | 17333 |
| 32 | 3 | 4227 [3896, 4558] | 0.08 ± 0.03 | 17500 | 17500 |

Throughput peaks at 2 in flight and falls from there; at 16 and above the
median signup takes longer than 8 s and the peak was still climbing when the
trial ended. No trial in this series was killed (12Gi cgroup).

Model on the sustainable regime, C ≤ 8 including the 60 s trials (n = 24):

    peak_Mi = 285 (±53) + 231.2 (±10.4) × C      residual SE 121 Mi, R² 0.958
    slope 95% CI [210, 253] Mi per concurrent signup

A consistency check, not a fit: `hurl --test` runs files in parallel with one
job per CPU by default ([Hurl 8.0.1 manual, `--jobs`](https://github.com/Orange-OpenSource/hurl/blob/8.0.1/docs/manual.md)),
and 81 of the scenarios in `tests/integration/scenarios/` log in through the
password flow. The 2.3Gi observed during the hurl run is what this model gives
for 8 to 9 concurrent logins, which is a machine with 8 or more CPUs.

### B. Poisson arrivals, 4Gi limit enforced

| signups/s offered | n | peak Mi | OOM-killed | completed /s | mean ms | p95 ms | in flight (Little) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 3 | 871 [525, 1217] | 0/3 | 1.07 | 417 | 1100 | 0.4 |
| 2 | 3 | 1278 [595, 1960] | 0/3 | 1.87 | 947 | 2200 | 1.9 |
| 4 | 3 | 2382 [1224, 3540] | 0/3 | 2.84 | 3446 | 8967 | 13.8 |
| 6 | 3 | 3397 [2227, 4567] | 0/3 | 1.26 | 9506 | 16000 | 57 |
| 8 | 3 | 3931 [3763, 4099] | 0/3 | 0.48 | 12994 | 17000 | 104 |
| 10 | 3 | 4052 [3865, 4240] | 2/3 | 0.23 | 11737 | 14433 | 117 |
| 15 | 3 | 4096 | 3/3 | 1.38 | 12179 | 16333 | 183 |
| 20 | 3 | 4096 | 3/3 | 3.31 | 9713 | 14300 | 194 |
| 30 | 3 | 4096 | 3/3 | 7.46 | 11178 | 18333 | 335 |
| 50 | 3 | 4096 | 3/3 | 10.66 | 10814 | 17667 | 541 |
| 75 | 3 | 4096 | 3/3 | 13.19 | 10903 | 17667 | 818 |

The knee is between 2 and 4 signups per second: at 4/s the mean latency is
already 3.4 s and 14 hashes are in flight, and the wide intervals there are the
queue going unstable in some replicates and not others. "Completed /s" above
6/s counts submissions that returned before the kill and is not a capacity.
The 6/s and 8/s rows did not hit the kernel limit in 20 s only because the
ramp had not reached it yet.

### C. `GOMEMLIMIT` separates live memory from collector slack

| in flight | defaults | `GOMEMLIMIT=1536MiB` | `GOMEMLIMIT=768MiB` |
| --- | --- | --- | --- |
| 1 | 446 [442, 451] | 446 [439, 453] | 447 [442, 452] |
| 2 | 634 [297, 970] | 642 [279, 1005] | 724 [697, 752] |
| 4 | 1281 [1269, 1293] | 1248 [1241, 1256] | 880 [846, 913] |
| 8 | 1995 [1768, 2223] | 1616 [1496, 1736] | 1049 [1042, 1056] |
| 16 | 3320 [2463, 4177] | 2075 [2057, 2093] | 2043 [1969, 2118] |

Where the limit binds (`GOMEMLIMIT=768MiB`, peak above 845Mi, n = 12):

    peak_Mi = 278 + 113.5 (±3.4) × C      residual SE 127 Mi, R² 0.991

Throughput is unchanged up to C = 4 (5.67 ± 0.26 /s against 4.95 ± 0.22 /s
with defaults) and drops at C = 8 (2.15 ± 0.54 /s), where 8 × 128MB of live
blocks exceed the 768MiB limit and the collector runs continuously. That is the
thrashing the Go GC guide describes, and it is why `GOMEMLIMIT` must sit above
the live set the limit is meant to hold, not just under the container limit.

### D. `hashers.argon2.parallelism` does not matter on 3 CPUs

`DECISIONS.md` left `parallelism: 16` against a 100m CPU request unresolved.
At C = 2, 16 lanes gave 6.03 ± 0.39 signups/s and 3 lanes 5.67 ± 0.06
(Welch t = 1.59, p = 0.25); at C = 4, 4.95 ± 0.22 against 4.96 ± 0.18
(p = 0.95). Peaks were 634 against 731 Mi and 1281 against 1344 Mi (p = 0.34
and 0.39). The setting can stay; it changes nothing measurable here.

### E. Verification at candidate limits, 3 trials each

| limit | `GOMEMLIMIT` | C = 4 | C = 8 | 2 signups/s | 4 signups/s |
| --- | --- | --- | --- | --- | --- |
| 1Gi | unset | killed 3/3 | killed 3/3 | killed 2/3 | killed 3/3 |
| 1Gi | 900MiB | 0/3, peak 1011, 5.05 /s | killed 3/3 | 0/3, peak 932 | killed 2/3 |
| 1.5Gi | 1400MiB | 0/3, peak 1261, 4.58 /s | 0/3, peak 1503, 4.38 /s | 0/3, peak 1172 | 0/3, peak 1461, 3.18 /s |
| 2Gi | 1850MiB | 0/3, peak 1265, 4.65 /s | 0/3, peak 1789, 4.18 /s | 0/3, peak 1167 | 0/3, peak 1776, 2.42 /s |

Zero kills in 3 trials only bounds the per-trial kill probability below 63% at
95% confidence (rule of three), so the verification confirms the models rather
than standing alone. Across all 24 trials at 1.5Gi and 2Gi there were no kills,
which bounds the probability below 12%. The 1.5Gi row at C = 8 peaked at
1503Mi against a 1536Mi limit: it held because `GOMEMLIMIT` kept the collector
ahead of the limit, and 8 in flight is the edge of what 1.5Gi holds.

## What a limit buys

From the two models, the largest concurrency whose upper 95% prediction bound
stays under each limit:

| limit | Go defaults | with `GOMEMLIMIT` at ~90% of the limit |
| --- | --- | --- |
| 1024Mi | 2 | 3 |
| 1280Mi | 3 | 6 |
| 1536Mi | 4 | 8 |
| 1792Mi | 5 | 10 |
| 2048Mi | 6 | 12 |

And what concurrency means in production. Here one signup took 170 ms at C = 1
and capacity was 6 /s. Those are this CPU's numbers. The production node's
per-hash time has not been validly measured: the 504 ms median `DECISIONS.md`
records came from `kratos hashers argon2 calibrate`, which in v26.2.0 adds
0.4 to 1.3 s of its own overhead to every hash it times (see "Calibrating the
hasher"). Measure it by running `tests/load/locustfile.py` at `-u 1` against
the cluster: the ratio of its median to 170 ms is the factor to divide every
rate in this document by. Under Little's law in flight equals rate times
latency, and latency rises with contention, so the scaled rates are
optimistic at the top end.

Against the node budget in `KANAE_INFRA_PLAN.md`, using the templates as they
are today: kanae 512Mi, Postgres 1Gi (`postgres.yml` line 190, not the 512Mi
the plan's table assumes), Keto 256Mi, Valkey 256Mi, Envoy proxy 64Mi, Envoy
control plane 64Mi, cert-manager 224Mi. Everything except Kratos reserves
2400Mi at steady state, plus a 256Mi migration Job at deploy time. The plan
says to write the node's real `Allocatable` beside its table and it has not
been written yet; k3s on 4 GB typically reports about 3.7Gi, of which the OS
and k3s itself consume some. With 1.5Gi for Kratos the steady-state total is
3.9Gi, which does not fit. It fits only if Postgres returns to the 512Mi the
plan budgets, giving 3.4Gi steady state and 3.65Gi during a migration wave, or
if the node grows.

`deploy/kubernetes/src/templates/kratos.yml` lines 146 to 153 currently
request and limit 4Gi, set in the Phase 9 commit (6ea3574). That reserves the
whole node for one pod and cannot schedule beside the rest.

## Recommendation

1. Kratos: `requests.memory: 1536Mi`, `limits.memory: 1536Mi`, and add
   `GOMEMLIMIT=1400MiB` to the container `env` in
   `deploy/kubernetes/src/templates/kratos.yml`. 1400MiB is 91% of the limit,
   inside the Go guide's 5 to 10% headroom, and above the 8-hash live set
   (278 + 113.5 × 8 = 1186Mi) so the collector does not thrash at the
   concurrency the limit is sized for. Record it in `DECISIONS.md` next to the
   512Mi entry, which this supersedes.
2. If 1.5Gi cannot be found on the node, 1Gi with `GOMEMLIMIT=900MiB` is the
   floor: it holds 4 simultaneous signups and 2 signups per second on this
   CPU, less on a slower one. Plain 1Gi without `GOMEMLIMIT` should not be
   run; it died at 2 signups per second.
3. Bound concurrency in front of Kratos, because no limit survives sustained
   overload. Envoy Gateway's `BackendTrafficPolicy` with `rateLimit.local` can
   target the HTTPRoute for `/auth/self-service/registration` and
   `/auth/self-service/login`
   ([Envoy Gateway: local rate limit](https://github.com/envoyproxy/gateway/blob/main/site/content/en/latest/tasks/traffic/local-rate-limit.md)).
   The number to set is below the production capacity, which the `-u 1`
   measurement above gives, with a burst that keeps in flight under the 8 the
   limit holds. A 429 at the
   gateway is a retry for one person; an OOM kill is a failed signup for
   everyone in flight.
4. Do not size for 75 signups per second on this node. It needs either the
   argon2 memory parameter lowered, which `DECISIONS.md` rejected on security
   grounds, or a node with roughly 75 × 0.5 s × 128MB ≈ 4.7 GB of headroom for
   Kratos alone plus the CPU to hash 75 times per second. Three cores here
   completed 6 signups per second, 0.5 core-seconds each, so 75 per second is
   about 40 cores at this machine's speed.
5. When running the hurl suite against a limited Kratos, pass `--jobs 4` or
   lower; the default is one job per CPU and each job is a login.

## Calibrating the hasher

`DECISIONS.md` rejected lowering `hashers.argon2.memory` because "the point of
argon2 is the memory". That holds while the node can afford 1.5Gi for Kratos.
If it cannot, the hasher is the remaining knob, and Ory ships a tool for it:
`kratos hashers argon2 calibrate <requests-per-minute>`
([CLI reference](https://www.ory.com/docs/kratos/cli/kratos-hashers-argon2)).

### What calibrate does

From [`cmd/hashers/argon2/calibrate.go` at v26.2.0](https://github.com/ory/kratos/blob/v26.2.0/cmd/hashers/argon2/calibrate.go):
it hashes one password at a time, raising memory in `--adjust-memory-by` steps
until a hash takes longer than `--min-duration` (500 ms), lowering it back
under, then doing the same with iterations. It then runs up to five load tests
([`loadtest.go`](https://github.com/ory/kratos/blob/v26.2.0/cmd/hashers/argon2/loadtest.go)),
each firing `requests-per-minute / 3` hashes over a 20 s window and sampling
`runtime.MemStats.HeapAlloc` once a second, and nudges memory or iterations by
64MB or 1 until the median is over the target, the maximum under target plus
deviation, and the heap under `--dedicated-memory`. At 15 requests per minute
that is five hashes 4 s apart: they never overlap, so the "memory used" it
reports is one hash plus the runtime, not a peak under concurrency. The
concurrency argument is `--max-concurrent` and it is not read anywhere on the
serving path.

### Why its timings cannot be used in v26.2.0

Every probe was run on this machine pinned to 3 CPUs, and every probe took
between 0.4 and 1.3 s regardless of the parameters:

| what calibrate or load-test timed | it reported | raw `argon2.IDKey` at the same parameters |
| --- | --- | --- |
| probe, 8MB, 1 iteration | 623 ms | 4 ms |
| probes while it halved memory down to 64 bytes | 870 to 1006 ms each | under 1 ms |
| load-test 60/min at 8MB, 1 iteration, 20 s | median 762 ms, min 425 ms, max 1281 ms | 4 ms |

The cause is in [`cmd/hashers/argon2/root.go`](https://github.com/ory/kratos/blob/v26.2.0/cmd/hashers/argon2/root.go):
the CLI wraps the hasher in an `argon2Config` whose `Config()` method writes
all eight argon2 keys into the live configuration store with `config.Set`, and
`Generate` in `hash/hasher_argon2.go` calls `h.c.Config().HasherArgon2(ctx)` on
every hash. The half second is that round-trip, and `strace -c` on a probe
shows it as `futex`, `epoll_pwait` and `nanosleep`, not CPU. Two consequences:

- The calibration loop does not terminate when the first probe is already
  over the target: it halves memory forever, and the step size reaches zero.
  The matrix run for this study (4 memory ceilings × 3 request rates) had to
  be killed after its first cell had spent 129 probes descending to 64 bytes.
- The 504 ms median that `DECISIONS.md` records from the in-cluster
  calibration on 2026-09-14 is this overhead plus a hash. It says nothing
  about the node's hash speed, and its memory choice of 128MB with 3
  iterations is the tool's starting default (`Argon2DefaultMemory` is 128MB
  in `driver/config/config.go`) bounded by `--dedicated-memory`, not a
  measurement.

So the calibration below follows the algorithm's rule by hand, with two
instruments that measure what they claim to: raw `argon2.IDKey` timings for
the duration constraint, and the Locust swarm against a real Kratos for the
memory constraint, which is what the tool's load test approximates.

### Hash time on 3 CPUs, raw argon2id

<!-- ARGON2_GRID -->

### Swarm against the recalibrated configs

<!-- PHASE4 -->

## Threats to validity

- **CPU speed and contention.** The production node's hash speed is unknown
  (the one in-cluster figure is unusable, see "Calibrating the hasher"), and
  Postgres did not compete for Kratos's cores here. Both make the rates here
  optimistic; the per-concurrency memory slopes do not depend on CPU speed.
- **Storage.** Postgres 16 with `fsync=off`, not Postgres 18 on a block
  volume. Slower commits would lengthen each signup slightly and raise in
  flight at a given rate.
- **Censoring.** 20 s trials under-read the peak by up to 13% at C = 6 to 8,
  and by more at C ≥ 16 where the peak was still rising. The recommendation
  uses the 60 s points and the models, and its verification ran at C = 8.
- **Small replicate counts.** Three replicates per cell give wide intervals at
  the knee (open loop, 4 to 6 /s) where queueing is unstable. The conclusions
  do not rest on those cells.
- **Cgroup v1 versus v2.** `memory.max_usage_in_bytes` and `memory.peak`
  measure the same charged bytes, page cache included. The database is remote,
  so Kratos's own page cache is small.
- **The webhook stub.** kanae's real webhook does a database insert and a
  Keto write. A slower webhook holds the flow open longer but the hash block
  is already freed by then, so its effect on peak memory is second order.

## Reproducing it

Against the k3d cluster, port-forward `svc/kratos` and run
`tests/load/locustfile.py` as its README shows, then `mise run k8s:measure`.
The sandbox harness (cgroup wrapper, webhook and SMTP stubs, trial
randomisation) is not committed because it assumes cgroup v1 and a local
Postgres; the CSV beside this file has every trial's inputs and outputs.
