# Kratos memory under signup load

Measured 2026-09-25 against Kratos v26.2.0 with the production hasher settings.
The question was how large a memory limit the Kratos pod can be given on the
3 vCPU, 4 GB node the infra plan budgets against, with tolerance, under heavy
signup load such as 75 signups per second.

## The answer

**1536Mi request and limit, with `GOMEMLIMIT=1300MiB` in the container's
environment.** That limit survived every verification trial (0 OOM kills in 12 at
`GOMEMLIMIT=1400MiB`, 0 in 9 at `1300MiB`), including 10 simultaneous signups
and a sustained Poisson arrival rate of 4 signups per second, which is above
what 3 CPUs can hash. 1300MiB rather than 1400MiB because the collector
overshoots its soft target by about one 128MB block under a burst: at
1400MiB, 8 in flight peaked 33 Mi under the limit; at 1300MiB, 135 Mi under,
with the same throughput (table I). The 1Gi limit
in use today was OOM-killed in 11 of 12 trials with Go's default collector, two
of them at only 2 signups per second. 1Gi with `GOMEMLIMIT=900MiB` holds 4
simultaneous signups and 2 signups per second, and nothing more.

**The better answer for a 4 GB node is 1024Mi with the hasher halved:
`memory: 64MB`, `iterations: 6`, `parallelism: 3`, `GOMEMLIMIT=750MiB`.**
Doubling the iterations keeps $m \cdot t = 384$, so an attacker's time per guess
is unchanged, and the paired comparison (table J) found this hasher at 1Gi
holds the same 10 in flight as today's hasher at 1.5Gi, at equal or higher
throughput, with 0 kills in 18 trials, while taking 512Mi off the node budget.
750MiB rather than the 85% rule's 870MiB because 60 s trials on a faster
CPU (table L) found 870MiB left 2 Mi at 8 in flight and was killed once in
three at 10, while 750MiB held 8 with 121 Mi to spare at the same throughput.
The budget:
3.56Gi at steady state with the templates as they are, against 4.06Gi with
Kratos at 1.5Gi ("The full memory state"). What is given
up is memory hardness against a parallel (GPU) attacker, halved; 64MB is still
3.4 times OWASP's Argon2id floor.

**If the hasher stays at 128MB, change it rather than run 1Gi as it is.** At 1Gi with `GOMEMLIMIT=900MiB`, `hashers.argon2.memory: 64MB` with
`iterations: 6` keeps today's cost per guess, halves the memory per signup and
survived 8 in flight and 4 signups per second where today's 128MB hasher was
killed; the OWASP Argon2id floor (19MiB, 2 iterations, parallelism 1) removes
memory as the constraint and lifted capacity here from 6 to 36 signups per
second. Ory's `calibrate` command cannot be used to choose between them in
v26.2.0: it adds half a second of its own overhead to every hash it times.
The "Calibrating the hasher" section has the measurements.

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

**The Envoy proxy in front of it needs nothing beyond the 64Mi it has.** The
same swarm sent through Envoy v1.39.1, configured as Envoy Gateway v1.9.1
renders it, peaked at 21.6 Mi with 100 connections held open against a
saturated Kratos, and the fit is $15.0 + 0.068\,C$ Mi per open connection
($R^2 = 0.995$, table K). Envoy Gateway caps Envoy's heap at 80% of the memory
limit and stops accepting requests at 98% of that cap, so a 64Mi limit turns
into a 50 Mi ceiling, which the fit puts at about 500 open connections, five
times what any trial held and fifty times what Kratos can serve. The row that
is wrong in the budget is the control plane: the chart reserves 256Mi for a
process the repository measured at 61 Mi, and that reservation, not the proxy,
is what makes 1.5Gi for Kratos not fit. See "The Envoy Gateway defaults and
the node budget".

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

Both measured slopes below match this arithmetic: $b \approx 231$ Mi per
concurrent signup with defaults, which is $2 \times 128$ MB, two blocks, and
$b \approx 113$ Mi with `GOMEMLIMIT` binding, one block.

## Notation

| symbol | meaning |
| --- | --- |
| $C$ | signups in flight at once; in closed-loop trials the Locust user count, so also the number of live argon2 blocks |
| $B$ | intercept of the memory model: live memory with no signup in flight (runtime, config, pool, servers) |
| $b$ | slope of the memory model: memory each additional in-flight signup costs, one argon2 block |
| $G$ | `GOMEMLIMIT`, the soft ceiling the Go collector works to hold |
| $m, t, p$ | argon2id memory, iterations and parallelism (`hashers.argon2` in `kratos.prod.yml`) |
| $\lambda, W$ | arrival rate of signups and latency per signup |

The relations the study rests on:

$$L(C) = B + bC \qquad\text{(live memory under a binding } G\text{)}$$

$$\widehat{\text{peak}}(C) \approx B' + 2bC \qquad\text{(Go defaults, GOGC = 100 lets the heap double)}$$

$$C_{\max} = \left\lfloor \frac{G - B}{b} \right\rfloor \qquad\text{(in-flight signups a pod holds)}$$

$$C = \lambda W \qquad\text{(Little's law)} \qquad\qquad \text{cost per hash} \propto m \cdot t$$

Statistics: every cell mean is reported with a 95% two-sided interval
$\bar{x} \pm t_{n-1,\,0.975}\, s/\sqrt{n}$; models are ordinary least squares
$\hat{y} = \beta_0 + \beta_1 C$ with residual standard error $s_{\text{res}}$,
coefficient of determination $R^2$, and 95% prediction intervals for a single
future trial; two-group comparisons use Welch's $t$; zero OOM kills in $n$
trials bounds the per-trial kill probability by $p_{\text{kill}} < 3/n$ at 95%
confidence (rule of three).

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

**Design and bias control.** 393 trials in nine phases:

| phase | factors | levels | reps | trials |
| --- | --- | --- | --- | --- |
| 1 | concurrency, Go defaults, 12Gi cgroup | C ∈ {1, 2, 3, 4, 6, 8, 12, 16, 24, 32} | 3 | 30 |
| 1 | Poisson rate, 4Gi cgroup (the node) | 1, 2, 4, 6, 8, 10, 15, 20, 30, 50, 75 /s | 3 | 33 |
| 1 | concurrency × `GOMEMLIMIT` | C ∈ {1, 2, 4, 8, 16, 32} × {768MiB, 1536MiB} | 3 | 36 |
| 2 | plateau check, 60 s instead of 20 s | C ∈ {4, 6, 8} | 2 | 6 |
| 2 | `hashers.argon2.parallelism` 3 vs 16 | C ∈ {2, 4} | 3 | 6 |
| 3 | verification: limit × `GOMEMLIMIT` × load | {1Gi, 1Gi+900MiB, 1.5Gi+1400MiB, 2Gi+1850MiB} × {C=4, C=8, 2/s, 4/s} | 3 | 48 |
| 4 | recalibrated hashers at 1Gi + `GOMEMLIMIT=900MiB` | {64MB/6 it, 64MB/3 it, 19MiB/2 it/p1} × {C=4, C=8, C=16, 2/s, 4/s} | 3 | 45 |
| 5 | calibrate's proposal, 224MB/5 it | {1.5Gi+1400MiB, 1Gi+900MiB} × {C=4, C=8, 2/s, 4/s} | 3 | 24 |
| 6 | `GOMEMLIMIT` at 85% | 1.5Gi+1306MiB × {C=8, C=10, 4/s}; 1Gi+870MiB × {C=4, 2/s} | 3 | 15 |
| 7 | paired hashers | {128MB/3/p16 at 1.5Gi, 64MB/6/p3 at 1Gi, 64MB/6/p3 at 1.5Gi} × {C=4, 8, 10, 16, 2/s, 4/s} | 3 | 54 |
| 8 | Envoy proxy limit × load, through TLS | {no limit, 64Mi, 128Mi} × {C=4, 8, 16, 32, 64, 75/s, 75/s rate-limited} | 3 | 63 |
| 9 | 64MB/6 at 1Gi, 60 s: parallelism paired, then `GOMEMLIMIT` | {p16, p3} × {C=4, 8, 10} at 870MiB; p3 × {C=6, 4/s} at 870MiB, C=8 at {800, 750}MiB, C=10 at 800MiB | 3 | 33 |

Within each phase the trial order was shuffled with a recorded seed
(20260925, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41) so drift in the machine could not line up with a factor
level. Every trial started a new Kratos process, a new cgroup and a new
database cloned from the migrated template, so heap retention and table growth
could not carry over. Arrival gaps used a per-replicate seed so replicates
differ by design, not by accident. Trials lasted 20 s unless stated; the 60 s
check found the 20 s peaks 3% low at C=4, 13% low at C=6 and 10% low at C=8,
so the 20 s peaks at C ≥ 6 are slightly censored and the models below include
the 60 s points. Intervals are 95% two-sided t intervals; regressions are
ordinary least squares with prediction intervals. The trial data is in
`kratos-memory-trials.csv` beside this file; phase 8's is in
`envoy-memory-trials.csv`.

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

Model on the sustainable regime, $C \le 8$ including the 60 s trials ($n = 24$):

$$\widehat{\text{peak}} = 285\,(\pm 53) + 231.2\,(\pm 10.4)\,C \ \text{Mi}, \qquad s_{\text{res}} = 121\ \text{Mi}, \quad R^2 = 0.958$$

Slope 95% CI: $[210,\ 253]$ Mi per concurrent signup.

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

Where the limit binds (`GOMEMLIMIT=768MiB`, peak above 845Mi, $n = 12$):

$$L(C) = 278 + 113.5\,(\pm 3.4)\,C \ \text{Mi}, \qquad s_{\text{res}} = 127\ \text{Mi}, \quad R^2 = 0.991$$

so $B = 278$ Mi and $b = 113.5$ Mi, which is $0.93$ of the 122 MiB block.

Throughput is unchanged up to $C = 4$ ($5.67 \pm 0.26$ /s against $4.95 \pm 0.22$ /s
with defaults) and drops at $C = 8$ ($2.15 \pm 0.54$ /s), where $8 \times 128$ MB of live
blocks exceed the 768MiB limit and the collector runs continuously. That is the
thrashing the Go GC guide describes, and it is why `GOMEMLIMIT` must sit above
the live set the limit is meant to hold, not just under the container limit.

### D. `hashers.argon2.parallelism` does not matter on 3 CPUs

`DECISIONS.md` left `parallelism: 16` against a 100m CPU request unresolved.
At $C = 2$, 16 lanes gave $6.03 \pm 0.39$ signups/s and 3 lanes $5.67 \pm 0.06$
(Welch $t = 1.59$, $p = 0.25$); at $C = 4$, $4.95 \pm 0.22$ against $4.96 \pm 0.18$
($p = 0.95$). Peaks were 634 against 731 Mi and 1281 against 1344 Mi ($p = 0.34$
and $0.39$). The setting can stay; it changes nothing measurable here.

### E. Verification at candidate limits, 3 trials each

| limit | `GOMEMLIMIT` | C = 4 | C = 8 | 2 signups/s | 4 signups/s |
| --- | --- | --- | --- | --- | --- |
| 1Gi | unset | killed 3/3 | killed 3/3 | killed 2/3 | killed 3/3 |
| 1Gi | 900MiB | 0/3, peak 1011, 5.05 /s | killed 3/3 | 0/3, peak 932 | killed 2/3 |
| 1.5Gi | 1400MiB | 0/3, peak 1261, 4.58 /s | 0/3, peak 1503, 4.38 /s | 0/3, peak 1172 | 0/3, peak 1461, 3.18 /s |
| 2Gi | 1850MiB | 0/3, peak 1265, 4.65 /s | 0/3, peak 1789, 4.18 /s | 0/3, peak 1167 | 0/3, peak 1776, 2.42 /s |

Zero kills in $n$ trials bounds the per-trial kill probability by
$p_{\text{kill}} < 1 - 0.05^{1/n}$ at 95% confidence, which is $3/n$ for large
$n$ (the rule of three) and only 63% for $n = 3$, so the verification confirms the models rather
than standing alone. Across all 24 trials at 1.5Gi and 2Gi there were no kills,
which bounds the probability below 12%. The 1.5Gi row at C = 8 peaked at
1503Mi against a 1536Mi limit: it held because `GOMEMLIMIT` kept the collector
ahead of the limit, and 8 in flight is the edge of what 1.5Gi holds.

### I. How much `GOMEMLIMIT` headroom, 9% or 15%

`GOMEMLIMIT` is a soft target: when a burst of signups allocates blocks faster
than the collector frees them, total memory overshoots it. The verification at
1400MiB (91%) left only 33 Mi between the 8-in-flight peak and the limit. The
same swarm at 85%, 15 trials, 3 replicates, shuffled:

| pod | load | `GOMEMLIMIT` | peak Mi | margin to limit | completed /s | killed |
| --- | --- | --- | --- | --- | --- | --- |
| 1.5Gi | C = 8 | 1400MiB (91%) | 1503 [1473, 1533] | 33 | 4.38 ± 0.08 | 0/3 |
| 1.5Gi | C = 8 | 1306MiB (85%) | 1385 [1349, 1421] | 135 | 4.32 ± 0.30 | 0/3 |
| 1.5Gi | C = 10 | 1306MiB (85%) | 1393 [1383, 1404] | 139 | 4.03 ± 0.23 | 0/3 |
| 1.5Gi | 4 /s | 1400MiB (91%) | 1461 [1333, 1590] | 75 | 3.18 ± 0.08 | 0/3 |
| 1.5Gi | 4 /s | 1306MiB (85%) | 1350 [1327, 1372] | 176 | 3.37 ± 0.06 | 0/3 |
| 1Gi | C = 4 | 900MiB (88%) | 1011 [982, 1040] | 13 | 5.05 ± 0.56 | 0/3 |
| 1Gi | C = 4 | 870MiB (85%) | 1020 [1008, 1031] | 0 | 4.33 ± 1.11 | 0/3 |
| 1Gi | 2 /s | 900MiB (88%) | 932 [859, 1006] | 92 | 1.62 ± 0.28 | 0/3 |
| 1Gi | 2 /s | 870MiB (85%) | 851 [572, 1129] | 78 | 1.95 ± 0.20 | 0/3 |

At 1.5Gi the extra headroom costs nothing and buys a block of margin: the
peak sits 80 to 100 Mi above $G$ either way, so lowering $G$ by 94 Mi moved the
peak down by the same amount, throughput is unchanged within its interval,
and 10 in flight held where the 91% setting was only verified to 8. At 1Gi
with the 128MB hasher the headroom does not help: the overshoot is the size
of the headroom, one trial at C = 4 touched the limit without being killed,
and throughput fell as the collector worked harder. That is one more reason
the 1Gi pod needs the 64MB hasher rather than a different `GOMEMLIMIT`.

### J. Paired comparison: today's hasher at 1.5Gi against a halved hasher at 1Gi

The question was whether lowering `hashers.argon2.memory` to 64MB, with its
"relative values" (iterations doubled to 6 so $m \cdot t$ is unchanged,
parallelism 3 to match the core count), lets Kratos run in 1Gi and give the
node its 512Mi back. Each hasher ran at the pod it would ship with, 85%
headroom, the same six loads, 3 replicates, 54 trials shuffled with seed 23.
The halved hasher was also run at 1.5Gi to see the difference at an equal pod.

| load | 128MB/3/p16 at 1.5Gi + 1300MiB | 64MB/6/p3 at 1Gi + 870MiB | 64MB/6/p3 at 1.5Gi + 1300MiB |
| --- | --- | --- | --- |
| C = 4 | 1306 Mi, margin 174, 4.00 /s | 698 Mi, margin 291, 5.37 /s | 677 Mi, margin 843, 5.47 /s |
| C = 8 | 1384 Mi, margin 142, 4.13 /s | 944 Mi, margin 67, 4.93 /s | 1090 Mi, margin 388, 4.80 /s |
| C = 10 | 1409 Mi, margin 117, 3.67 /s | 968 Mi, margin 46, 4.82 /s | 1300 Mi, margin 156, 4.90 /s |
| C = 16 | killed 3/3 | killed 3/3 | 1348 Mi, margin 157, 4.53 /s |
| 2 /s | 1099 Mi, 1.80 /s, p50 560 ms | 477 Mi, 1.93 /s, p50 310 ms | 607 Mi, 1.88 /s, p50 343 ms |
| 4 /s | 1341 Mi, 3.02 /s, p50 980 ms | 765 Mi, 3.13 /s, p50 697 ms | 799 Mi, 3.42 /s, p50 543 ms |

At an equal pod the halved hasher takes 294 Mi less at 8 in flight and 109 Mi
less at 10, and survives 16 where today's is killed. Its per-signup slope is
$b = 54.1\,(\pm 9.6)$ Mi at 1.5Gi and $47.3\,(\pm 5.5)$ Mi at 1Gi against 113.5 Mi
for the 128MB block; today's hasher shows no slope at 1.5Gi ($17.5 \pm 3.7$,
$R^2 = 0.76$) because from 4 in flight upward the collector is already holding
the line at $G$. Throughput is equal or better with the halved hasher at every
load (Welch $p = 0.001$ at C = 4 and C = 16, $p = 0.09$ at 8 and 10), which is
the 3-lane hash fitting 3 CPUs and the smaller block fitting cache. Latency at
2 and 4 signups per second is lower for the same reason.

The halved hasher at 1Gi and today's hasher at 1.5Gi hold the same 10 in
flight and die at the same 16. The difference is 512Mi of node budget. The 1Gi
margins at 8 and 10 in flight (67 and 46 Mi) are thinner than the 1.5Gi ones
(142 and 117 Mi), which is the price of the smaller pod and why the rate
limit's burst should be 8, not 10.

### K. The Envoy proxy under the same swarm

Phase 8 put Envoy v1.39.1 between Locust and Kratos, because that is the
image Envoy Gateway v1.9.1 pins
(`api/v1alpha1/shared_types.go`, `DefaultEnvoyProxyImage`, [envoyproxy/gateway v1.9.1](https://github.com/envoyproxy/gateway/blob/v1.9.1/api/v1alpha1/shared_types.go)),
with a static configuration copied from what the controller renders for
`deploy/kubernetes/src/templates/routing.yml`: an HTTPS listener terminating
TLS, an HTTP listener that answers 308, `/auth` prefix-rewritten to Kratos
with the route's 45 s request timeout, `/` to a kanae stub, 32 KiB
per-connection buffers (`tcpListenerPerConnectionBufferLimitBytes` in
`internal/xds/translator/listener.go`), and the bootstrap's overload manager
(`internal/xds/bootstrap/bootstrap.yaml.tpl`). Locust spoke TLS to Envoy on
CPUs 0 to 2, which Envoy shared with Kratos as they share the node's 3 vCPU.
Kratos ran the halved hasher with `GOMEMLIMIT=1300MiB` in a cgroup large
enough that it never died, so every Envoy number below is Envoy holding
connections against a live but saturated backend, not against a crashed one.
Envoy ran with `--concurrency 3`, the worker count it would pick on a 3 vCPU
node with no CPU limit.

Loads: 4, 8, 16, 32 and 64 users signing up back to back; 75 signups per
second Poisson with the pile-up capped at 100 connections; and the same 75
per second with the study's recommended local rate limit on the registration
POST (4 per second, burst 8). The 75/s loads are the overload case the rate
limit exists for: 100 connections open, most of them waiting up to 45 s for
a hash that will not come.

| limit | load | n | peak Mi | 95% CI | max | heap Mi | connections | overload actions | 5xx | 429 | OOM | signups/s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| none | C=4 | 3 | 15.2 | [14.9, 15.6] | 15.4 | 10 | 4 | 0 | 0 | 0 | 0 | 5.52 |
| none | C=8 | 3 | 15.6 | [15.2, 15.9] | 15.6 | 12 | 8 | 0 | 0 | 0 | 0 | 5.29 |
| none | C=16 | 3 | 16.1 | [15.7, 16.4] | 16.1 | 12 | 16 | 0 | 0 | 0 | 0 | 5.30 |
| none | C=32 | 3 | 17.1 | [17.1, 17.1] | 17.1 | 12 | 32 | 0 | 0 | 0 | 0 | 2.12 |
| none | C=64 | 3 | 19.3 | [19.0, 19.7] | 19.4 | 16 | 64 | 0 | 0 | 0 | 0 | 1.75 |
| none | 75/s | 3 | 21.1 | [20.7, 21.4] | 21.1 | 16 | 100 | 0 | 0 | 0 | 0 | 1.68 |
| none | 75/s, rate limit | 3 | 21.4 | [21.4, 21.4] | 21.4 | 16 | 100 | 0 | 0 | 976 | 0 | 6.89 |
| 64Mi | C=4 | 3 | 15.2 | [14.9, 15.6] | 15.4 | 12 | 4 | 0 | 0 | 0 | 0 | 5.55 |
| 64Mi | C=8 | 3 | 15.6 | [15.6, 15.6] | 15.6 | 12 | 8 | 0 | 0 | 0 | 0 | 5.46 |
| 64Mi | C=16 | 3 | 16.3 | [16.0, 16.7] | 16.4 | 12 | 16 | 0 | 0 | 0 | 0 | 5.45 |
| 64Mi | C=32 | 3 | 17.2 | [16.9, 17.6] | 17.4 | 12 | 32 | 0 | 0 | 0 | 0 | 2.17 |
| 64Mi | C=64 | 3 | 19.1 | [18.7, 19.4] | 19.1 | 16 | 64 | 0 | 0 | 0 | 0 | 1.51 |
| 64Mi | 75/s | 3 | 21.1 | [20.7, 21.4] | 21.1 | 16 | 100 | 0 | 0 | 0 | 0 | 1.66 |
| 64Mi | 75/s, rate limit | 3 | 21.5 | [21.1, 21.8] | 21.6 | 16 | 100 | 0 | 0 | 1084 | 0 | 7.67 |
| 128Mi | C=4 | 3 | 15.5 | [15.1, 15.8] | 15.6 | 12 | 4 | 0 | 0 | 0 | 0 | 5.62 |
| 128Mi | C=8 | 3 | 15.6 | [15.6, 15.6] | 15.6 | 12 | 8 | 0 | 0 | 0 | 0 | 5.33 |
| 128Mi | C=16 | 3 | 16.1 | [16.1, 16.2] | 16.1 | 12 | 16 | 0 | 0 | 0 | 0 | 5.40 |
| 128Mi | C=32 | 3 | 17.2 | [16.8, 17.6] | 17.4 | 12 | 32 | 0 | 0 | 0 | 0 | 2.19 |
| 128Mi | C=64 | 3 | 19.2 | [18.9, 19.6] | 19.4 | 16 | 64 | 0 | 0 | 0 | 0 | 1.82 |
| 128Mi | 75/s | 3 | 21.1 | [21.1, 21.1] | 21.1 | 16 | 100 | 0 | 0 | 0 | 0 | 1.64 |
| 128Mi | 75/s, rate limit | 3 | 21.5 | [21.2, 21.9] | 21.6 | 16 | 100 | 0 | 0 | 1020 | 0 | 7.24 |

Peak is the cgroup's high-water mark, as in every other table; "heap" is the
largest `server.memory_heap_size` Envoy's admin endpoint reported, which
tcmalloc grows in 4 Mi steps; "overload actions" counts trials in which
`stop_accepting_requests` ever became active; "signups/s" is what Kratos
completed behind the proxy, and at 75/s the rate-limited run completed more
than the unlimited one because the limiter kept Kratos at a concurrency where
it still finishes hashes (table J found the same knee).

The limit made no difference to anything, as expected while the heap sat far
under its cap. Across the 15 closed-loop trials with no limit, ordinary least
squares gives

$$P(C) = 15.0 + 0.068\,C\ \text{Mi},\qquad R^2 = 0.995,\qquad \text{residual SE } 0.1\ \text{Mi},$$

with $b \in [0.065, 0.070]$ Mi per open connection and $B \in [14.9, 15.1]$
Mi (95% CI), where $C$ here counts open client connections rather than
in-flight hashes. Prediction intervals: 21.4 to 22.1 Mi at 100 connections,
which the 75/s trials confirmed at 21.1 to 21.6; 27.9 to 29.1 Mi at 200. The
cost per connection is what the 32 KiB read and write buffers and the TLS
session amount to, and a saturated backend does not raise it: the 45 s
timeouts in the 75/s trials (89 to 99 per trial) came back as 504s without
moving the peak.

Envoy Gateway derives an overload-manager heap cap from the limit:
`calculateMaxHeapSizeBytes` in
`internal/infrastructure/kubernetes/proxy/resource.go` returns 80% of
`limits.memory`, and the bootstrap template triggers `shrink_heap` at 95% of
that and `stop_accepting_requests` at 98%
([envoyproxy/gateway#3082](https://github.com/envoyproxy/gateway/commit/07f8a472), April 2024).
Without a limit no cap is set. So the number a limit $M$ actually
enforces on the proxy is

$$H_{\text{stop}}(M) = 0.98 \times 0.8 \times M = 0.784\,M,$$

and the connections that reach it are $C_{\text{stop}} = (H_{\text{stop}} - B)/b$:

| limit $M$ | heap cap | stops accepting at | $C_{\text{stop}}$ |
| --- | --- | --- | --- |
| 48Mi | 38.4 Mi | 37.6 Mi | 330 |
| 64Mi | 51.2 Mi | 50.2 Mi | 520 |
| 128Mi | 102.4 Mi | 100.4 Mi | 1260 |

The `fixed_heap` monitor reported 25% pressure at the worst load under the
64Mi cap, and neither overload action fired in any of the 63 trials. Past
$C_{\text{stop}}$ the proxy refuses new requests, which is the graceful
failure; it is never OOM-killed first because the cap sits under the limit.

### L. Parallelism 16 against 3 at 64MB, and how much `GOMEMLIMIT` headroom 1Gi needs over 60 s

Phase 9 answered whether `parallelism` matters once the block is 64MB, with
a design that phases 4 and 7 had not given: both lane counts at the same
limit (1Gi), the same `GOMEMLIMIT` (870MiB), the same three loads, 60 s
trials, three replicates with shared arrival seeds, all 18 shuffled with
seed 31 so the two sides ran interleaved. Differences are paired by
replicate; intervals are 95% $t$.

| C | metric | p=16 | p=3 | paired difference, p16 minus p3 | Welch $t$ |
| --- | --- | --- | --- | --- | --- |
| 4 | peak Mi | 767 ± 47 | 777 ± 121 | −11 [−174, +153] | −0.35 |
| 4 | signups/s | 7.62 ± 0.27 | 7.90 ± 0.18 | −0.28 [−0.71, +0.16] | −3.77 |
| 4 | p50 ms | 450 ± 25 | 427 ± 14 | +23 [−15, +61] | 3.50 |
| 8 | peak Mi | 1001 ± 39 | 1015 ± 22 | −14 [−63, +36] | −1.32 |
| 8 | signups/s | 7.36 ± 0.50 | 7.56 ± 0.30 | −0.20 [−0.43, +0.03] | −1.57 |
| 8 | p50 ms | 953 ± 52 | 893 ± 29 | +60 [+35, +85] | 4.37 |
| 10 | peak Mi | 1013 ± 24 | 1012 ± 27 | +1 [−5, +6] | 0.07 |
| 10 | signups/s | 7.16 ± 1.13 | 6.62 ± 3.90 | +0.5 [−2.3, +3.4] | 0.57 |
| 10 | p50 ms | 1233 ± 143 | 1133 ± 143 | +100 [+100, +100] | 2.12 |

Memory does not move: every paired interval for peak includes zero, as it
must when the block allocated per hash is the same size and the lanes only
share it. Throughput ties: the paired intervals include zero at all three
loads, and the one Welch statistic past 3 (C = 4) is a 4% edge to 3 lanes,
not to 16. Latency favours 3 lanes at every load, by 60 ms [35, 85] at
C = 8, which is the cost of scheduling 16 goroutines per hash onto 3 cores.
So 3 lanes: equal memory, equal throughput, lower latency, and the higher
time-area cost to an attacker from "What halving the hasher costs in
security". One trial was OOM-killed, at p3, C = 10.

That kill is the second result of the phase. This machine hashed at 7.6
signups per second in phase 9 against 5.1 in phase 7 (a faster host, not a
change in Kratos), and 60 s trials rather than phase 7's 20 s. At 1Gi with
`GOMEMLIMIT=870MiB` that left almost nothing:

| load, `GOMEMLIMIT` | peak Mi [95% CI] | max | margin to 1024 | kills | signups/s | p50 ms | time above `GOMEMLIMIT` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C = 4, 870MiB | 777 [656, 898] | 827 | 197 | 0/3 | 7.90 | 427 | 0% |
| C = 6, 870MiB | 954 [841, 1068] | 985 | 39 | 0/3 | 7.71 | 673 | 9% |
| C = 8, 870MiB | 1015 [993, 1037] | 1022 | 2 | 0/3 | 7.56 | 893 | 41% |
| C = 8, 800MiB | 929 [891, 967] | 945 | 79 | 0/3 | 7.92 | 837 | 57% |
| C = 8, 750MiB | 896 [870, 922] | 903 | 121 | 0/3 | 7.66 | 893 | 72% |
| C = 10, 870MiB | 1012 [985, 1040] | 1024 | 0 | 1/3 | 6.62 | 1133 | 56% |
| C = 10, 800MiB | 962 [947, 976] | 968 | 56 | 0/3 | 7.40 | 1100 | 78% |
| 4 /s, 870MiB | 812 [525, 1099] | 887 | 137 | 0/3 | 3.64 | 267 | 1% |

"Time above `GOMEMLIMIT`" is the share of 0.1 s samples in which the cgroup
exceeded the soft limit. At C = 8 and 870MiB the process sat above its
target 41% of the run: the collector was already running as hard as it is
allowed to and the live set plus one collection's garbage still cleared
1000 Mi. Lowering the target does what a lower target should: at 800MiB the
peak fell 86 Mi, at 750MiB 119 Mi, and throughput did not move (7.56, 7.92,
7.66 per second), because hashing is what the CPUs are doing and the
collector's extra work fits beside it. At C = 10 the same drop to 800MiB
turned a kill in three into 56 Mi of margin and raised throughput from 6.62
to 7.40, since a collector that is not fighting the cgroup wastes less.
750MiB is $278 + 8 \times 50 = 678$ Mi of live set plus 72 Mi, about one
block, so it is the lowest target that does not make the collector thrash at
the concurrency the limit is sized for; below it the collector would be
chasing a live set it cannot shrink.

The 4 /s row is the production case with the rate limit in place: 137 Mi of
margin over 60 s, and the cgroup above the soft target 1% of the time.

What this changes. The 85% headroom that table I found sufficient at 1.5Gi
is not sufficient at 1Gi on a CPU this fast, because the overshoot is a
fixed number of blocks of garbage, not a percentage of the pod, and on the
smaller pod the same overshoot is a larger share. `GOMEMLIMIT=750MiB` (73%)
is the number for a 1Gi pod. The 1.5Gi alternative's 1300MiB was verified
in 20 s trials at 5 signups per second and has not been re-run at 60 s on
this faster host; if that alternative is used, run it.

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
rate in this document by. Under Little's law, $C = \lambda W$, in-flight work is arrival rate times
latency, and $W$ rises with contention, so the scaled rates are optimistic at
the top end.

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

1. On a 4 GB node: `requests.memory: 1024Mi`, `limits.memory: 1024Mi`,
   `GOMEMLIMIT=750MiB`, and in `kratos.prod.yml` `memory: 64MB`,
   `iterations: 6`, `parallelism: 3` (tables J and L). 750MiB is 73% of the
   limit, not the 85% used at 1.5Gi: over 60 s on a fast CPU, 870MiB left
   2 Mi at 8 in flight and was killed once at 10, and 750MiB held 8 with
   121 Mi and 10 with 56 Mi at 800MiB, at the same throughput (table L).
   Size the rate limit so in-flight stays at or under 6, where the
   margin is 39 Mi even at 870MiB. Record in `DECISIONS.md` that
   $m \cdot t$ is unchanged and memory hardness is halved, superseding "the
   point of argon2 is the memory". If the node grows or Postgres returns to
   512Mi, the alternative below keeps today's hasher.
1. (alternative) Kratos: `requests.memory: 1536Mi`, `limits.memory: 1536Mi`,
   and add `GOMEMLIMIT=1300MiB` to the container `env` in
   `deploy/kubernetes/src/templates/kratos.yml`. 1300MiB is 85% of the limit:
   more headroom than the Go guide's 5 to 10%, because the collector
   overshoots the soft target by about one block (table I measured the
   overshoot at 80 to 100 Mi), so the headroom has to hold a block and some
   change. It is still above the 8-hash live set
   ($L(8) = 278 + 113.5 \times 8 = 1186$ Mi) so the collector does not thrash at the
   concurrency the limit is sized for, and it held 10 in flight in the
   verification. Record it in `DECISIONS.md` next to the
   512Mi entry, which this supersedes.
2. If 1.5Gi cannot be found on the node, 1Gi with `GOMEMLIMIT` at 85% is the
   floor: it holds 4 simultaneous signups and 2 signups per second on this
   CPU, less on a slower one. Plain 1Gi without `GOMEMLIMIT` should not be
   run; it died at 2 signups per second.
3. Bound concurrency in front of Kratos, because no limit survives sustained
   overload. The object is in "The rate limit, derived" below: one
   `BackendTrafficPolicy` on the existing HTTPRoute whose two local rules
   select the password-hashing POSTs by method and path, `requests: 2,
   unit: Second` each. A 429 at the gateway is a retry for one person;
   an OOM kill is a failed signup for everyone in flight.
4. If the node cannot give Kratos 1.5Gi, keep 1Gi with `GOMEMLIMIT=900MiB` and
   set `hashers.argon2.memory: 64MB`, `iterations: 6` in `kratos.prod.yml`,
   which the Compose production stack also loads. That keeps the time an
   attacker spends per guess equal to today's and holds 8 in flight. Going to
   the OWASP floor (`19MB`, `iterations: 2`, `parallelism: 1`) is a security
   decision to record in `DECISIONS.md` against its current "the point of
   argon2 is the memory" entry; the numbers say it is what makes this node
   comfortable, and 19MiB is what OWASP calls the minimum, not a weak setting.
   Existing hashes keep their own parameters in the `$argon2id$` string and
   verify unchanged; new registrations and password changes take the new ones.
   Do not use `kratos hashers argon2 calibrate` to pick these until the
   overhead in its CLI wrapper is fixed upstream; time the hash with
   `tests/load/locustfile.py` at `-u 1` on the node instead.
5. Do not size for 75 signups per second on this node. It needs either the
   argon2 memory parameter lowered, which `DECISIONS.md` rejected on security
   grounds, or a node with roughly $\lambda W m = 75\ \text{s}^{-1} \times 0.5\ \text{s} \times 128\ \text{MB} \approx 4.7$ GB
   of headroom for Kratos alone plus the CPU to hash 75 times per second.
   Three cores here completed 6 signups per second, $0.5$ core-seconds each,
   so 75 per second is $75 \times 0.5 \approx 40$ cores at this machine's speed.
6. When running the hurl suite against a limited Kratos, pass `--jobs 4` or
   lower; the default is one job per CPU and each job is a login.
7. Leave the Envoy proxy at `64Mi` request and limit in `envoy.yml`; table K
   measured it at 22 Mi with 100 connections open and the controller's heap
   cap makes it refuse rather than die past about 500. Count the pod as 96Mi
   in the budget for the `shutdown-manager` sidecar the controller adds.
8. Lower the Envoy Gateway control plane to `128Mi` request and limit with
   `GOMEMLIMIT=110MiB` in `helmfile.yaml`, on the strength of the 61 Mi
   reading in `DECISIONS.md`, and check it with `k8s:measure` in
   `envoy-gateway-system` after e2e. That is the 128Mi that decides whether
   the node has room.

## The Envoy Gateway defaults and the node budget

### Where the numbers in the chart come from

`deploy/kubernetes/envoy.yml` already sets the proxy container to 64Mi
request and limit with a 100m CPU request, so the proxy does not run on the
controller's defaults. What it would run on is `requests.memory: 512Mi`,
`requests.cpu: 100m` and no limits, from `DefaultDeploymentMemoryResourceRequests`
in `api/v1alpha1/shared_types.go`, introduced with the first support for
setting the proxy's resources at all
([envoyproxy/gateway#1197](https://github.com/envoyproxy/gateway/commit/666bf2aae), March 2023).
The commit adds the constants without a measurement or a comment on how they
were chosen. The upstream task page reads the same way: its example sets
`requests: 150m / 640Mi, limits: 500m / 1Gi` as an illustration of the
`envoyDeployment.container.resources` field, not as guidance
(`site/content/en/v1.9/tasks/operations/customize-envoyproxy.md`, "Customize
EnvoyProxy Deployment Resources"). Table K says why none of those figures
matter here: this Gateway's proxy peaks at 22 Mi with 100 connections open.

The proxy pod also carries a second container the budget has never counted.
`resource.go` appends a `shutdown-manager` container to every proxy pod, with
`requests: 10m / 32Mi` from `DefaultShutdownManagerContainerResourceRequirements`
and no limit, and `EnvoyProxy` has no field to change those. The pod the
scheduler reserves for is therefore 96Mi, not 64Mi.

The control plane's `requests.memory: 256Mi` and `limits.memory: 1024Mi` in
`charts/gateway-helm/values.tmpl.yaml` were `64Mi` and `128Mi` (with a 10m
CPU request) until
[envoyproxy/gateway#1617](https://github.com/envoyproxy/gateway/commit/005b5b3c)
("bump resource limits for Envoy Gateway deployment", July 2023) raised all
three, citing issue #1613. The issue's text is not reachable from the network
this study ran on; what the commit shows is that the numbers are a response
to a reported problem in general use, sized for whatever cluster reported it,
and have not moved since. `DECISIONS.md` chose to keep them until a
measurement under load replaced them, and measured 36 Mi idle and 61 Mi with
one Gateway and one HTTPRoute.

### What the swarm can and cannot size

The swarm sizes the proxy, because every byte the proxy holds is a
connection or a buffer, and table K measures those directly. It does not size
the control plane, because the control plane carries no traffic: it watches
the API server and pushes an xDS snapshot to the proxy when a Gateway, route,
Secret or Service changes. Its memory is a function of how many of those
objects exist, and in this repository that number is fixed at one Gateway,
two HTTPRoutes and, during an ACME challenge, one more. No signup rate
changes it, so no load test can bound it; only a reading with those objects
present can, which is the 61 Mi `DECISIONS.md` took. This study ran in a
sandbox with no API server, so it adds no reading of its own.

### The proxy: 64Mi stays, now measured

The worst load's mean peak has a 95% upper confidence bound of 21.9 Mi and
the regression's 95% prediction bound is 29.1 Mi at 200 open connections,
twice the pile-up any trial reached and twenty times what Kratos can hash at
once. The limit that matters is the heap cap Envoy Gateway derives from it;
at 64Mi the proxy stops accepting at 50.2 Mi, which is 520 connections by the
fit, and it is never killed. Lowering to 48Mi would save 16Mi and cut
$C_{\text{stop}}$ to 330 for no reason the budget needs; raising it buys
nothing the proxy will use. So:

```yaml
# deploy/kubernetes/envoy.yml (unchanged)
requests: { cpu: 100m, memory: 64Mi }
limits: { memory: 64Mi }
```

with the budget row corrected to 96Mi for the pod.

### The control plane: 128Mi, from the repository's own reading

The chart's 256Mi request reserves four times the 61 Mi the repository
measured with this cluster's objects present, and it is the single largest
reservation on the node that no measurement supports. The reading is a
working set, not idle: 61 Mi is the controller holding and having translated
the objects it will ever hold here. Twice that, 128Mi as request and limit,
keeps the plan's rule 7 and leaves a 67 Mi margin over the reading for
informer resyncs and a leader-election renewal. The controller is a Go
process, so the same soft limit that held Kratos applies: `GOMEMLIMIT` at 85%
of the limit, 110MiB, through the chart's `deployment.envoyGateway.extraEnv`
list (`charts/gateway-helm/values.tmpl.yaml`, "Additional environment
variables for the envoy-gateway container"):

```yaml
# deploy/kubernetes/helmfile.yaml, envoy-gateway release values
deployment:
  envoyGateway:
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits: { memory: 128Mi }
    extraEnv:
      - name: GOMEMLIMIT
        value: 110MiB
```

This is the one recommendation in the study that rests on a reading rather
than on trials, and it is checkable in the place the reading came from:
`mise run k8s:measure --namespace envoy-gateway-system` after the e2e suite
has driven cert-manager's challenge route through the controller. If the
peak there is over 100 Mi, the number is wrong and 256Mi stands.

### The full memory state

Requests are what the scheduler reserves, so requests are what has to fit;
every row is request = limit unless the row says otherwise. "Today" is what
the templates and charts set on this branch; "proposed" is this study's
recommendation.

| Pod, container | today | proposed | source |
| --- | --- | --- | --- |
| kanae | 512Mi | 512Mi | `templates/kanae.yml` |
| postgres | 1024Mi | 1024Mi (the plan's table says 512Mi) | `templates/postgres.yml`; its 64Mi `check-version` init container adds nothing |
| kratos | 4096Mi | 1024Mi, `GOMEMLIMIT=750MiB`, hasher 64MB/6/p3 | `templates/kratos.yml` since Phase 9 (6ea3574); tables J and L |
| keto | 256Mi | 256Mi | `templates/keto.yml` |
| valkey | 256Mi | 256Mi | `templates/valkey.yml` |
| envoy proxy, `envoy` container | 64Mi | 64Mi | `envoy.yml`; table K |
| envoy proxy, `shutdown-manager` sidecar | 32Mi request, no limit | 32Mi request, no limit | `resource.go`, not settable through `EnvoyProxy` |
| envoy gateway control plane | 256Mi request, 1024Mi limit | 128Mi, `GOMEMLIMIT=110MiB` | chart default; the 61 Mi reading in `DECISIONS.md` |
| cert-manager controller | 64Mi | 64Mi | `helmfile.yaml` |
| cert-manager cainjector | 128Mi | 128Mi | `helmfile.yaml` |
| cert-manager webhook | 32Mi | 32Mi | `helmfile.yaml` |
| **kanae and controllers, steady state** | **6720Mi (6.56Gi)** | **3520Mi (3.44Gi)** | |
| CoreDNS | 70Mi request, 170Mi limit | same | k3s `manifests/coredns.yaml` |
| metrics-server | 70Mi request | same | k3s `manifests/metrics-server/metrics-server-deployment.yaml` |
| Cilium agent and operator | no request, about 200Mi in use | same | `helmfile.yaml` sets none; `DECISIONS.md` |
| local-path-provisioner | no request | same | k3s packaged |
| **everything the scheduler counts** | **6860Mi** | **3660Mi (3.57Gi)** | |

Today's column cannot schedule at all: the 4Gi Kratos placeholder from Phase
9 alone is the node. With the plan's 1Gi in that row instead, today's
steady state is 3648Mi for the namespace and 3788Mi with `kube-system`.

Deploy time adds one migration Job at a time, 256Mi each
(`templates/jobs-migrate.yml`), because the apply order finishes each Job
before app pods schedule and `strategy: Recreate` on kanae removes the
rolling surge (plan, "Deploy-time peak"):

| | proposed steady | proposed with one migration Job | Kratos at 1.5Gi instead |
| --- | --- | --- | --- |
| scheduler's total | 3660Mi | 3916Mi | 4172Mi |

What the node offers is the number the plan's rule says to copy from
`kubectl describe node` and nobody has yet. Two bounds, with the kubelet's
default hard eviction threshold of `memory.available<100Mi`
([Kubernetes: node-pressure eviction](https://github.com/kubernetes/website/blob/main/content/en/docs/concepts/scheduling-eviction/node-pressure-eviction.md))
and no other reservation, which is k3s's default:

| node | allocatable | headroom, proposed steady | during a migration Job | Kratos at 1.5Gi |
| --- | --- | --- | --- | --- |
| 4 GiB (4096Mi) | 3996Mi | 336Mi | 80Mi | 176Mi short, Pending |
| 4 GB decimal (3815Mi) | 3715Mi | 55Mi | 201Mi short, Pending at deploy | 457Mi short |

Headroom here is scheduler headroom. Physical headroom is smaller by what
runs outside every request: Cilium's roughly 200 Mi, the `shutdown-manager`
sidecar's use above its 32Mi, and the k3s server process itself (API server,
scheduler, controller manager, kubelet in one binary), which no row counts
and the plan's "k3s and the kubelet take their cut first" refers to. On the
4 GiB bound that leaves the node with about 100 Mi of physical slack at
steady state; on the decimal bound, none.

Two levers move it. Postgres back at the plan's 512Mi takes 512Mi off every
cell: 848Mi and 592Mi of headroom on the 4 GiB node at steady state and
during a migration, and Kratos at 1.5Gi would then fit with 336Mi to spare.
The control plane at 128Mi instead of 256Mi is already in the proposed
column; it is what turns "does not fit" into "fits" for the 1Gi Kratos on
the decimal-4GB bound. The proxy is not a lever: it is 64Mi in both columns,
and moving it to 128Mi while dropping the control plane to 64Mi sums to the
same 192Mi and puts the tight limit on the one process whose reading (61 Mi)
is within 3 Mi of it.

### What halving the hasher costs in security

The question is whether `memory: 64MB`, `iterations: 6`, `parallelism: 3`
leaves an attacker with an easier job than `128MB`, `3`, `16`. There are
three standard ways to count an attacker's cost, and the halved hasher is
equal or better on each.

**Time per guess on hardware like ours.** The raw hash, timed on the same
three idle CPUs the swarm used (median of 5 warm calls, `argonbench`):

| setting | median | cold first call |
| --- | --- | --- |
| 128MB, 3 it, p=16 (today) | 187 ms | 574 ms |
| 128MB, 3 it, p=3 | 187 ms | 560 ms |
| 64MB, 6 it, p=3 (proposed) | 178 ms | 372 ms |
| 64MB, 6 it, p=16 | 176 ms | 358 ms |

An attacker with CPUs like ours makes guesses at the same rate against either
hash, because $m \cdot t = 128 \times 3 = 64 \times 6 = 384$ MB-passes and the
work is the same. The cold call is faster because the block being faulted in
is half the size, which is the same reason the swarm's latencies fell.

**Throughput on a bandwidth-bound cracker (GPU).** A GPU's rate is limited by
memory bandwidth (the Argon2 specification's §2.1 puts it at about 400 GB/s), and each
guess moves $m \cdot t$ bytes through it. Unchanged. A cracker with a fixed
amount of memory can hold twice as many 64 MiB guesses in flight as 128 MiB
ones, but each needs twice the passes, so guesses per second are unchanged
there too. What is halved is the memory per guess as an absolute; that only
helps an attacker whose platform is memory-capacity-bound rather than
bandwidth-bound, which is the reading of "the point of argon2 is the memory"
in `DECISIONS.md` that has substance.

**Time-area product (ASIC).** The Argon2 specification's own cost measure
(§2.1, [PHC Argon2 specification](https://github.com/P-H-C/phc-winner-argon2/blob/master/argon2-specs.pdf))
is $A \cdot T$: the chip area $A$ scales with the memory $m$ and the running
time $T$ with the longest sequential chain, which is $t$ passes over the
$m/p$ blocks of one lane, since the $p$ lanes run side by side. So

$$A \cdot T \propto m \times \frac{t\,m}{p}, \qquad
\text{today: } 128 \times \frac{3 \times 128}{16} = 3072, \qquad
\text{proposed: } 64 \times \frac{6 \times 64}{3} = 8192 .$$

The proposed setting costs an ASIC attacker 2.7 times more per guess than
today's, because `parallelism: 16` on a 3 vCPU node gave the defender nothing
(table D: no difference in memory or throughput between 3 and 16) while
handing an attacker 16 lanes to fill in parallel.

**Against the floor.** OWASP's minimum for Argon2id is 19 MiB, 2 iterations,
1 lane
([OWASP Password Storage Cheat Sheet](https://github.com/OWASP/CheatSheetSeries/blob/master/cheatsheets/Password_Storage_Cheat_Sheet.md), "Argon2id").
The proposal has 3.4 times the memory and, at $m \cdot t = 384$ against 38,
ten times the work per guess.

**In the context of this load.** The hash parameters govern offline cracking
of a stolen table. Online guessing against the live service is governed by
the rate limit in front of Kratos, 4 attempts per second across everyone,
which no hash parameter changes. The reason to halve is that the 128 MiB
block is what put Kratos at 113.5 Mi per in-flight signup and made 1Gi
unsafe; halving it is what lets the node hold 10 in flight at 1Gi. The
security trade is a smaller block per guess in exchange for twice the passes,
and every cost model above says the attacker pays the same or more.

## The rate limit, derived

### What the limiter is

Envoy Gateway's local rate limit is a token bucket, not a fixed window and
not a leaky bucket. `internal/xds/translator/local_ratelimit.go` (v1.9.1,
lines 155 to 161 and 242 to 248) builds Envoy's `TokenBucket` with
`max_tokens = requests`, `tokens_per_fill = requests` and
`fill_interval = unit`. So `requests: r, unit: Second` admits at most
$r$ requests in any burst and refills $r$ per second: the burst $B$ and
the sustained rate $\lambda$ are the same number, and the only way to get a
different burst is a different unit, which makes it worse (`unit: Minute`
with `requests: 120` is 2 per second sustained with a burst of 120). A
fixed-window counter would admit $2B$ across a window edge, which is why it
is the wrong choice here; a leaky bucket smooths output rather than bounding
admissions, and Envoy does not offer one.

The bucket is per Envoy route, and Envoy Gateway expands every HTTPRoute
`match` into its own route (`irRouteName(httpRoute, ruleIdx, matchIdx)` in
`internal/gatewayapi/route.go`), so registration and login each get their
own bucket. Two matches at $r$ each admit $2r$ per second in total.

What a token bucket guarantees: in any interval of length $T$ the number
admitted is at most $B + \lambda T$.

### The bound

Little's law, $C = \lambda W$, gives the in-flight count from the admitted
rate and the time each request spends in Kratos. The limiter fixes
$\lambda$; $W$ depends on how busy Kratos is. Treating the hashing stage as
one server of capacity $\mu$ (the measured signups per second at
saturation, which already includes the slowdown parallel hashes cause each
other) with Poisson arrivals, M/M/1 gives

$$\rho = \frac{\lambda}{\mu}, \qquad \bar W = \frac{1}{\mu - \lambda}, \qquad \bar C = \lambda \bar W = \frac{\rho}{1 - \rho}.$$

Exponential service is pessimistic for a hash whose time barely varies, so
$\bar W$ is an upper estimate. A burst adds its $B$ tokens on top of the
steady state, so the count to design against is

$$C_{\text{worst}} = B + \lambda \bar W = B + \frac{\lambda}{\mu - \lambda}.$$

The requirement is $C_{\text{worst}} \le C_{\text{safe}}$, where table L
puts $C_{\text{safe}} = 8$ for 1Gi at `GOMEMLIMIT=750MiB` (121 Mi of margin
over 60 s, 0 kills in 3) and 6 is the same with one spare block. The
capacity to use is the slowest one measured, $\mu = 5.1$ per second (phase
7's host); phase 9's host did 7.6. The production node's $\mu$ is unknown
and must be measured (`tests/load/locustfile.py` at `-u 4` for 60 s, read
`submit password` requests per second); if it comes out under 5, re-solve.

With two routes at $r$ each, $\lambda = B = 2r$:

| $r$ per route | $\lambda$, $B$ | $\rho$ at $\mu = 5.1$ | $\bar W$ | $C_{\text{worst}}$ at $\mu = 5.1$ | at $\mu = 7.6$ |
| --- | --- | --- | --- | --- | --- |
| 1 | 2 | 0.39 | 0.32 s | 2.6 | 2.4 |
| 2 | 4 | 0.78 | 0.91 s | 7.6 | 5.1 |
| 3 | 6 | 1.18 | unstable | unbounded | 9.8 |

$r = 2$ is the largest integer that stays under $C_{\text{safe}} = 8$ on
the slow host, and it is what the 4 per second open-loop trials ran: 137 Mi
of margin at 870MiB over 60 s (table L), 0 kills in 6 across phases 7 and
9. $r = 3$ exceeds the slow host's capacity outright, and past $\mu$ the
queue grows without bound until the 45 s route timeout, which is the
overload the study measured as a certain kill. $r = 1$ is what to set if
$C_{\text{safe}} = 6$ is the target, or if the production node measures
under 5 per second.

Why 4 per second was stated earlier without this derivation: it was read
off the open-loop trials as "the highest rate that never killed the 1Gi
pod", which is the same answer by measurement rather than by model.

### The object

The strip of `/auth` has nothing to do with the limiter. Kratos generates
URLs carrying `/auth` (`SERVE_PUBLIC_BASE_URL` in `templates/kratos.yml`)
but serves its routes at the root, so every request forwarded to it must
lose the prefix, and the existing `/auth` rule's `URLRewrite` is what does
that (plan, Phase 8). The earlier drafts here repeated that rewrite because
they gave the limiter its own rule or route, which Gateway API filters are
scoped to. Neither is needed.

A local rate limit rule can select its own traffic: `clientSelectors`
takes `methods` and `path` (Exact, PathPrefix or RegularExpression),
`RateLimitSelectCondition` in the v1.9 API. Envoy Gateway turns the path
selector into a descriptor on Envoy's `:path` header
(`buildPathMatchLocalRateLimitAction`, `internal/xds/translator/local_ratelimit.go`),
which is the path as the request arrived, before the router's rewrite, so
the selector matches the `/auth/...` form. A request that matches no rule
falls to the default bucket, and when every rule has selectors that bucket
is `math.MaxUint32` requests (`buildLocalRateLimit`,
`internal/gatewayapi/backendtrafficpolicy.go`, v1.9.1), so everything else
on the route is unlimited. So the whole change is one object attached to
the HTTPRoute as it stands, in `deploy/kubernetes/src/templates/routing.yml`:

```yaml
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: {{ .Values.serviceNames.kratos }}-password
  namespace: {{ .Values.namespace }}
  annotations:
    kapp.k14s.io/change-rule: "upsert after upserting kanae/services"
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: {{ .Values.serviceNames.kanae }}
  rateLimit:
    type: Local
    local:
      rules:
        - clientSelectors:
            - methods:
                - value: POST
              path:
                type: PathPrefix
                value: /auth/self-service/registration
          limit:
            requests: 2
            unit: Second
        - clientSelectors:
            - methods:
                - value: POST
              path:
                type: PathPrefix
                value: /auth/self-service/login
          limit:
            requests: 2
            unit: Second
```

Each rule is its own token bucket, so registration and login get 2 per
second each, which is the $2r$ the derivation counts. The flow-initialising
`GET /auth/self-service/registration/browser` matches neither rule and is
unlimited: it creates a flow row and hashes nothing. `kubeconform` needs the
`BackendTrafficPolicy` schema, which the datreeio catalog configured for
`EnvoyProxy` carries.

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

- The calibration loop misbehaves when the first probe is already over the
  target, which the overhead guarantees at a 500 ms target. With the default
  512MB step it subtracts more than it has, the unsigned byte size wraps, and
  it dies trying to allocate 64TB (`fatal error: runtime: out of memory`,
  reproduced three times with the flags `DECISIONS.md` used). With a small
  step it halves memory forever instead: the matrix run for this study had to
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

Warm medians of 7 calls after 2 warm-up calls, one hash at a time, Kratos's
production settings in bold, measured on idle CPUs (a first run overlapped the
swarm and was discarded). The cold column is the first call, which pays the
page faults for a freshly mapped block; a Kratos hash pays that whenever the
runtime has handed the previous block back to the kernel.

| memory | iterations | parallelism | warm median | cold first call |
| --- | --- | --- | --- | --- |
| 19MiB | 2 | 1 | 30 ms | 49 ms |
| 19MiB | 2 | 16 | 15 ms | 92 ms |
| 46MiB | 1 | 1 | 42 ms | 94 ms |
| 32MB | 4 | 16 | 47 ms | 149 ms |
| 64MB | 3 | 16 | 72 ms | 268 ms |
| 64MB | 6 | 16 | 140 ms | 333 ms |
| 96MB | 3 | 16 | 108 ms | 419 ms |
| **128MB** | **3** | **16** | **147 ms** | **575 ms** |
| 128MB | 3 | 3 | 141 ms | 544 ms |
| 128MB | 1 | 16 | 53 ms | 460 ms |

Two things follow. Cost scales with $m \cdot t$, so 64MB at 6 iterations
($m \cdot t = 384$) costs an attacker the same time per guess as today's 128MB
at 3 ($m \cdot t = 384$) while holding half the memory. And Ory's own target of 0.5 to 1 s per hash
(the calibrate help text) is not met by any row on this CPU, today's included;
meeting it would push memory or iterations up, against the budget. The
duration target belongs to the production node and has to be measured there.

The OWASP Password Storage Cheat Sheet lists `m=19456 (19 MiB), t=2, p=1` as
the Argon2id minimum, with `m=47104 (46 MiB), t=1, p=1` and lower-memory,
higher-iteration equivalents beside it
([OWASP CheatSheetSeries, Password_Storage_Cheat_Sheet.md](https://github.com/OWASP/CheatSheetSeries/blob/master/cheatsheets/Password_Storage_Cheat_Sheet.md)).
Today's 128MB is 6.7 times that floor.

### Swarm against the recalibrated configs

Three candidates, everything else in `kratos.prod.yml` unchanged, each run
against the constrained pod, 1Gi with `GOMEMLIMIT=900MiB`, under the loads
that killed the 128MB hasher at that limit (table E). 45 trials, 3 replicates
per cell, shuffled order; the three trials that overlapped the timing grid were
discarded and re-run. "Killed" is the kernel OOM killer; peaks are means over
the 3 trials in Mi; capacity is completed signups per second at the best
closed-loop point.

| hasher | hash here | C = 4 | C = 8 | C = 16 | 2 /s | 4 /s | capacity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 128MB, 3 it, p16 (today, from table E) | 147 ms | ok, 1011 | killed 3/3 | not run | ok, 932 | killed 2/3 | 5.7 /s |
| 64MB, 6 it, p16 | 140 ms | ok, 696 | ok, 953 | killed 3/3 | ok, 481 | ok, 751 | 5.8 /s |
| 64MB, 3 it, p16 | 72 ms | ok, 707 | ok, 974 | ok, 1010 | ok, 374 | ok, 673 | 10.1 /s |
| 19MiB, 2 it, p1 (OWASP floor) | 30 ms | ok, 385 | ok, 460 | ok, 659 | ok, 126 | ok, 162 | 35.6 /s |

Per-signup slopes over the unkilled closed trials: $b = 64.2\,(\pm 6.0)$ Mi
with 64MB at 6 iterations, $R^2 = 0.97$, which is one 64MB block, matching the
$b = 113.5$ Mi per 128MB block of table C; $b = 23.1\,(\pm 1.4)$ Mi with the
OWASP floor, $R^2 = 0.97$. The 64MB, 3-iteration row shows no slope
($b = 22 \pm 6$, $R^2 = 0.67$) because at 16 in flight
its 1010 Mi peak is the limit itself: the collector was holding the line, with
throughput still at 8 /s, and one more in flight would have killed it.

What each buys under 1Gi. Same attacker cost as today, half the memory:
64MB at 6 iterations holds 8 in flight and 4 signups per second where today's
hasher dies, and dies at 16. Half the cost: 64MB at 3 iterations holds 16 at
the edge and nearly doubles capacity. The OWASP floor takes memory off the
table (659 Mi at 16 in flight, under a 1Gi pod with room to spare) and lifts
capacity on this CPU to 35 signups per second; it is the only configuration
in this study under which 75 signups per second is within reach of a 3 CPU
node, and that still needs the webhook, Postgres and the node's own hash
speed measured before it is believed.

### Calibrate's own proposal under the swarm

Given a duration target above its overhead (`--min-duration 1500ms`, with
`--start-memory 128MB --start-iterations 3 --adjust-memory-by 32MB`, 360
requests per minute, `--dedicated-memory` and `--max-memory` 1400MB), the
command completes its probing phase and proposes **224MB with 5 iterations**.
Its load test then fails ("The hashing load test took too long ... The memory
used was 826.20MB") and it exits with status 1 and no result. With its default
512MB step it does not get that far: the first probe is over target, it
subtracts the step from 128MB, the unsigned byte size wraps, and the next
probe tries to allocate 64TB and dies with `fatal error: runtime: out of
memory`. That is what happened with the exact flags `DECISIONS.md` used, run
here three times.

The proposal is the tool's answer, so it was put under the same swarm as the
study's values, at both pods. The model's predictions were written down first:

$$b = 0.93 \times 213.6 = 199\ \text{Mi}, \qquad C_{\max} = \left\lfloor \frac{1400 - 278}{199} \right\rfloor = 5 \ \text{at 1.5Gi}, \qquad \left\lfloor \frac{900 - 278}{199} \right\rfloor = 3 \ \text{at 1Gi}$$

$$\frac{\text{cost per hash}}{\text{today's}} = \frac{224 \times 5}{128 \times 3} = 2.9$$

so capacity about 2 signups per second, which makes 2/s unstable and 4/s a
certain kill. 24 trials, 3 replicates, shuffled:

| hasher | pod | C = 4 | C = 8 | 2 /s | 4 /s |
| --- | --- | --- | --- | --- | --- |
| 128MB, 3 it (study) | 1.5Gi + 1400MiB | ok, 1261, 4.6 /s | ok, 1503, 4.4 /s | ok, 1172 | ok, 1461, 3.2 /s |
| 224MB, 5 it (calibrate) | 1.5Gi + 1400MiB | ok, 1438, 1.6 /s | killed 3/3 | killed 3/3 | killed 3/3 |
| 128MB, 3 it (study) | 1Gi + 900MiB | ok, 1011, 5.1 /s | killed 3/3 | ok, 932 | killed 2/3 |
| 224MB, 5 it (calibrate) | 1Gi + 900MiB | ok, 991, 1.7 /s | killed 3/3 | killed 3/3 | killed 3/3 |

Every prediction held: 4 in flight survives, 8 is killed, 2 signups per
second is already over capacity (0.08 completed per second before the kill),
and the one surviving cell at 1Gi peaked at 991 Mi against a 1024 Mi limit,
the "borderline" the arithmetic gave for $C_{\max} = 3$. Calibrate's proposal is
worse than today's hasher on every axis this study measures: a third of the
throughput, three times the memory per signup, and the same pod is killed at
loads the study's values survive. The reason is structural, not a bug: the
command tunes a single hash to a wall-clock target on the machine it runs on,
and this machine hashes fast, so it reaches for more memory and iterations;
nothing in it accounts for the concurrency the pod has to hold. Its load test
is the only place concurrency enters, and there it rejects the proposal
without offering another.

### The values the arithmetic gives

For `deploy/kubernetes/src/templates/kratos.yml`:

```yaml
resources:
  requests:
    memory: 1536Mi
  limits:
    memory: 1536Mi
env:
  - name: GOMEMLIMIT
    value: 1300MiB
```

with `docker/ory/config/kratos/kratos.prod.yml` unchanged:

```yaml
hashers:
  algorithm: argon2
  argon2:
    memory: 128MB
    iterations: 3
    parallelism: 16
    dedicated_memory: 1300MB   # documents the budget; not read on the serving path
```

Derivation. The headroom must cover the collector's overshoot of its soft
target, measured at 80 to 100 Mi (about one block, $b$), plus memory the Go
runtime does not account for, so $1 - G/\text{limit} \ge 2b/\text{limit} \approx 15\%$:

$$G = 0.85 \times 1536 = 1306 \approx 1300\ \text{MiB}, \qquad C_{\max} = \left\lfloor \frac{G - B}{b} \right\rfloor = \left\lfloor \frac{1300 - 278}{113.5} \right\rfloor = 9$$

on the mean line, 7 on the upper 95% prediction bound; the verification held
8 with 135 Mi to spare and 10 with 139 Mi to spare (table I), so 8 is the
number to size the rate limit on and 10 is the measured edge. `parallelism`
can stay at 16 or drop to 3; table D found no difference on 3 CPUs, and
OWASP's reference settings all use 1.

If the pod must be 1Gi, `GOMEMLIMIT=750MiB` (73%; 85% was verified at 900MiB
in 20 s trials and found 2 Mi short at 8 in flight over 60 s, table L) and

```yaml
    memory: 64MB
    iterations: 6
```

which keeps $m \cdot t = 384$ (today's cost per guess) and gives $b = 64$ Mi, so

$$C_{\max} = \left\lfloor \frac{750 - 278}{64} \right\rfloor = 7 \ \text{on the } 64 \text{ Mi bound}, \qquad 9 \ \text{on the measured } b = 50, \qquad \text{verified at } 8 \text{ with } G = 750 \text{ over 60 s}.$$

The rate limit on the registration and login routes goes below the measured
capacity, $\lambda < \min(\text{capacity},\ C_{\max}/W)$, with a burst of
$C_{\max}$; on this CPU that is under 6 per second, burst 8.

**How `memory: 64MB`, `iterations: 6`, `parallelism: 3` were arrived at, in
one paragraph.** The memory parameter was set by the pod, not by the hasher:
ordinary least squares on 30 closed-loop trials gave peak memory as
$L(C) = B + bC$ with $b = 113.5$ Mi per in-flight signup at 128MB (95% CI
from the regression's standard error), and $C_{\max} = \lfloor (G - B)/b \rfloor$
put a 1Gi pod at 5 in flight, which the verification trials confirmed by
being killed above it. Halving $m$ halves $b$ (measured 47 to 54 Mi in
table J) and doubles $C_{\max}$ to 9 on the mean line, 8 on the upper 95%
prediction bound. The iteration count then follows from holding
$m \cdot t$ constant, since an attacker's work per guess is proportional to
$m \cdot t$ under both the CPU-time and the memory-bandwidth models: $t = 384/64 = 6$.
Parallelism was set to the node's core count because table D found no
memory or throughput difference between 3 and 16 lanes on 3 CPUs (Welch's
$t$, $p = 0.25$ at C = 2), table L's paired 18 trials at 64MB found the same
on memory and throughput with 60 ms [35, 85] lower median latency at 3
lanes, and fewer lanes raise the time-area cost to an ASIC attacker. The three values were then tested as a unit rather than
assumed: a paired design, 54 trials shuffled with seed 23, ran this hasher at
1Gi against today's at 1.5Gi under the same six loads with three replicates
each, and the comparison used 95% $t$ intervals on peak memory and Welch's
$t$ on throughput ($p = 0.001$ at C = 4 and C = 16, $p = 0.09$ at 8 and 10,
all favouring or tying the halved hasher). Zero kills in 18 trials at 1Gi
bounds the per-trial kill probability below 15% at 95% confidence (rule of
three, $1 - 0.05^{1/18}$), which is why the rate limit's burst is set to 8
rather than the measured edge of 10. The raw hash was timed on the same
three idle CPUs (median of 5 warm calls) to check that the wall time per
guess had not moved: 178 ms against 187 ms.

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
- **The Envoy configuration is a copy, not the controller's output.** Phase 8
  wrote Envoy's static configuration by hand from Envoy Gateway's templates
  and translator constants. The listener, routes, buffer limit and overload
  manager match; the controller also adds access logging to stdout, a stats
  sink and an xDS connection, none of which hold per-connection memory. The
  control plane was not run at all.
- **The webhook stub.** kanae's real webhook does a database insert and a
  Keto write. A slower webhook holds the flow open longer but the hash block
  is already freed by then, so its effect on peak memory is second order.

## Reproducing it

Against the k3d cluster, port-forward `svc/kratos` and run
`tests/load/locustfile.py` as its README shows, then `mise run k8s:measure`.
Through the Gateway, point `-H` at the Gateway's `/auth` and set
`LOAD_CA_BUNDLE` to the local issuer's certificate; then
`mise run k8s:measure --namespace envoy-gateway-system` for the proxy. The
sandbox harness (cgroup wrapper, webhook and SMTP stubs, trial
randomisation, the Envoy static configuration) is not committed because it
assumes cgroup v1 and a local Postgres; the two CSVs beside this file have
every trial's inputs and outputs.
