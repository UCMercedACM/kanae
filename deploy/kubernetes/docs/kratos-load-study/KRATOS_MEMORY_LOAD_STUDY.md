# Sizing Ory Kratos and its Envoy proxy on a 4 GB node: a load study of argon2 memory, the Go collector, and admission control

Measured 2026-09-25 and 2026-09-26 against Kratos v26.2.0 and Envoy v1.39.1.
The trial data is in `kratos-memory-trials.csv` (330 rows) and
`envoy-memory-trials.csv` (63 rows) beside this file. The load driver is
`locustfile.py`, and `RUN_THE_LOAD_TEST.md` says how to run it.

## Abstract

The Kratos pod in the Kanae deployment ran with a 1Gi memory limit and was
seen at 2.3Gi under the repository's own integration tests. The node the
deployment is budgeted against has 3 vCPU and 4 GB. This study asked what
memory limit the pod needs, whether any limit survives a signup rate of 75
per second, and what the proxy in front of it needs. It ran 393 trials of a
Locust signup swarm against a real Kratos, each in a fresh cgroup with an
enforced limit, in nine randomised phases with three replicates per cell,
and modelled peak memory with ordinary least squares, 95% t intervals, and
Welch's t. Peak memory is linear in signups in flight, at 231 Mi per signup
with Go's default collector and 113.5 Mi with `GOMEMLIMIT` set, because
every hash allocates a 128MB argon2 block and nothing in Kratos bounds the
count. No limit survives sustained overload: above about 5 signups per
second the cgroup grows at 221 MiB/s until the kernel kills the container.
Halving the argon2 memory to 64MB while doubling iterations to 6 keeps the
attacker's work per guess and lets a 1Gi pod hold 8 signups in flight with
121 Mi to spare, provided `GOMEMLIMIT` is 750MiB rather than the 85% rule's
870MiB. The Envoy proxy peaked at 22 Mi with 100 connections open, so its
64Mi limit stands. A token-bucket limit of 2 requests per second on each of
the registration and login routes, derived from Little's law against the
slowest measured capacity, keeps in-flight hashes under the 8 the pod holds.
Ory's `calibrate` command could not be used to choose the hasher: in v26.2.0
its wrapper adds about half a second to every hash it times.

## 1. Introduction

Kanae runs on one Kubernetes node with 3 vCPU and 4 GB of memory. Its
infrastructure plan budgets every container's memory request against that
node and makes each request equal its limit (`infra-plans/KANAE_INFRA_PLAN.md`,
"The node budget", rule 7). Identity is handled by Ory Kratos (Ory Corp,
2026a), which hashes every password with argon2id, and requests reach it
through Envoy Gateway (Envoy Gateway Authors, 2026a), which provisions one
Envoy proxy (The Envoy Project Authors, 2026a) per Gateway.

Two facts set the problem. First, Kratos's hasher calls `argon2.IDKey`
directly, with no semaphore, mutex, channel, or queue around it
(`hash/hasher_argon2.go`, Ory Corp, 2026a). The repository's decision log
already records this ("Kratos is sized at 512Mi against argon2, because
nothing else bounds it", `deploy/kubernetes/docs/DECISIONS.md`). Second,
each call allocates its own block array, `B := make([]block, memory)`, in
`initBlocks` of the Go argon2 package (The Go Authors, 2026a). With
`hashers.argon2.memory: 128MB` in `docker/ory/config/kratos/kratos.prod.yml`,
every signup or login in flight holds 128MB of live heap.

The Go runtime adds to that. With the default `GOGC=100` the collector lets
the heap grow to twice the live set before it collects, and it returns freed
pages to the kernel lazily. `GOMEMLIMIT` makes the collector work harder as
runtime memory approaches a soft limit, and the Go garbage collector guide
recommends 5 to 10% of headroom under a container limit while warning that
the collector caps itself at half the CPU, so a limit below the live set
thrashes rather than helps (The Go Authors, 2026b). When a container exceeds
its limit the kernel's OOM killer stops the process and Kubernetes restarts
the container (The Kubernetes Authors, 2026a), which drops every signup in
flight.

The pod's limit was 1Gi. During the hurl integration suite it reached 2.3Gi.
The decision log's one in-cluster figure for hash time, a 504 ms median from
`kratos hashers argon2 calibrate`, did not explain the gap. The study
therefore had five objectives:

1. Measure how Kratos's peak memory depends on the number of signups in
   flight and on the arrival rate, and fit a model that predicts it.
2. Find the memory limit and `GOMEMLIMIT` at which the pod survives the
   loads the node will see, and say what happens at 75 signups per second.
3. Decide whether lowering the argon2 memory parameter is safe, and if so
   to what, using Ory's calibration tool where it can be trusted.
4. Measure the Envoy proxy under the same load and trace where its chart
   defaults come from.
5. Derive an admission limit that keeps Kratos under the concurrency its
   pod holds.

Throughout, $C$ is the number of signups in flight, $B$ and $b$ are the
intercept and slope of the memory model, $G$ is `GOMEMLIMIT`, $m$, $t$, and
$p$ are argon2's memory, iterations, and parallelism, and $\lambda$ and $W$
are the arrival rate and the time a signup spends in Kratos. The relations
the study rests on are

$$L(C) = B + bC, \qquad C_{\max} = \left\lfloor \frac{G - B}{b} \right\rfloor, \qquad C = \lambda W \ \text{(Little, 1961)}, \qquad \text{cost per hash} \propto m \cdot t .$$

## 2. Methods

### 2.1 Environment

Trials ran in a 4-CPU, 16 GB Linux sandbox with cgroup v1 and no container
runtime, not on the k3d cluster. Kratos v26.2.0 was the release binary, run
from `kratos.prod.yml` with only environment-specific keys changed: the DSN,
base URLs, the webhook target, `haveibeenpwned_enabled` (which needs egress),
and the SMTP host. The `hashers`, `session`, flow, and hook blocks were
verified identical by diff. The database was Postgres 16 with the production
pool settings `max_conns=20&max_idle_conns=4` and `fsync=off`; production
runs Postgres 18 on a block volume. Kanae's registration webhook was a stub
answering 200 after 10 ms, because `response.ignore: false` makes Kratos
block on it. The courier delivered each verification mail to a local SMTP
sink, so the background work Kratos does after a signup ran too.

Kratos was pinned to CPUs 0 to 2 with `taskset`, the node's 3 vCPU. Locust,
Postgres, and the stubs ran on CPU 3. On the node, Postgres shares those
three cores with Kratos, so Kratos is slower there than here.

### 2.2 Instrumentation

Each trial ran Kratos in a fresh cgroup with an enforced
`memory.limit_in_bytes` and read `memory.max_usage_in_bytes` afterwards. That
is the cgroup v1 name for the `memory.peak` that
`deploy/kubernetes/scripts/measure.sh` reads, so every peak in this paper is
the number `mise run k8s:measure` would show. OOM kills were read from
`memory.oom_control`. The high-water mark was reset after Kratos reported
ready, so startup is excluded; idle was 445 Mi. A sampler recorded
`memory.usage_in_bytes` every 0.1 s.

### 2.3 Load

`locustfile.py` (Byström et al., 2026) drives the browser registration flow
the Chapter-Website and the hurl scenarios use: a GET that initialises a
flow, then a POST that submits a password. Two arrival models were used.

- Closed loop: $C$ users each sign up back to back, so $C$ is the number of
  hashes in flight.
- Open loop: Poisson arrivals at a target rate, with exponential gaps drawn
  from a recorded seed so there is no start-up burst, and a user cap so the
  pile-up is bounded.

### 2.4 Design and bias control

The 393 trials ran in nine phases (Table 1). Within each phase the trial
order was shuffled with a recorded seed (20260925, 7, 11, 13, 17, 19, 23, 29,
31, 37, 41) so drift in the machine could not line up with a factor level.
Every trial started a new Kratos process, a new cgroup, and a new database
cloned from the migrated template, so heap retention and table growth could
not carry over. Arrival gaps used a per-replicate seed so replicates differ
by design. Trials lasted 20 s unless stated. Three trials in phase 4 that
overlapped a timing run were discarded and re-run.

**Table 1.** The nine phases.

| phase | factors | levels | reps | trials |
| --- | --- | --- | --- | --- |
| 1 | concurrency, Go defaults, 12Gi cgroup | C ∈ {1, 2, 3, 4, 6, 8, 12, 16, 24, 32} | 3 | 30 |
| 1 | Poisson rate, 4Gi cgroup (the node) | 1, 2, 4, 6, 8, 10, 15, 20, 30, 50, 75 /s | 3 | 33 |
| 1 | concurrency × `GOMEMLIMIT` | C ∈ {1, 2, 4, 8, 16, 32} × {768MiB, 1536MiB} | 3 | 36 |
| 2 | plateau check, 60 s instead of 20 s | C ∈ {4, 6, 8} | 2 | 6 |
| 2 | `parallelism` 3 against 16 | C ∈ {2, 4} | 3 | 6 |
| 3 | verification: limit × `GOMEMLIMIT` × load | {1Gi, 1Gi+900MiB, 1.5Gi+1400MiB, 2Gi+1850MiB} × {C=4, C=8, 2/s, 4/s} | 3 | 48 |
| 4 | recalibrated hashers at 1Gi + 900MiB | {64MB/6, 64MB/3, 19MiB/2/p1} × {C=4, C=8, C=16, 2/s, 4/s} | 3 | 45 |
| 5 | calibrate's proposal, 224MB/5 | {1.5Gi+1400MiB, 1Gi+900MiB} × {C=4, C=8, 2/s, 4/s} | 3 | 24 |
| 6 | `GOMEMLIMIT` at 85% | 1.5Gi+1306MiB × {C=8, C=10, 4/s}; 1Gi+870MiB × {C=4, 2/s} | 3 | 15 |
| 7 | paired hashers | {128MB/3/p16 at 1.5Gi, 64MB/6/p3 at 1Gi, 64MB/6/p3 at 1.5Gi} × {C=4, 8, 10, 16, 2/s, 4/s} | 3 | 54 |
| 8 | Envoy proxy limit × load, through TLS | {no limit, 64Mi, 128Mi} × {C=4, 8, 16, 32, 64, 75/s, 75/s rate-limited} | 3 | 63 |
| 9 | 64MB/6 at 1Gi, 60 s: parallelism paired, then `GOMEMLIMIT` | {p16, p3} × {C=4, 8, 10} at 870MiB; p3 × {C=6, 4/s} at 870MiB, C=8 at {800, 750}MiB, C=10 at 800MiB | 3 | 33 |

### 2.5 Statistics

Every cell mean is reported with a 95% two-sided interval
$\bar{x} \pm t_{n-1,\,0.975}\, s/\sqrt{n}$. Models are ordinary least squares
$\hat{y} = \beta_0 + \beta_1 C$ with residual standard error, coefficient of
determination $R^2$, and 95% prediction intervals for a single future trial.
Two-group comparisons use Welch's $t$; the paired phase reports differences
by replicate. Zero OOM kills in $n$ trials bounds the per-trial kill
probability below $1 - 0.05^{1/n}$ at 95% confidence, which is about $3/n$
for large $n$ (the rule of three) and 63% for $n = 3$, so three-trial
verifications confirm the models rather than stand alone.

### 2.6 The Envoy rig

Phase 8 put Envoy v1.39.1 between Locust and Kratos, because that is the
image Envoy Gateway v1.9.1 pins (`DefaultEnvoyProxyImage` in
`api/v1alpha1/shared_types.go`, Envoy Gateway Authors, 2026a). Its static
configuration was copied from what the controller renders for
`deploy/kubernetes/src/templates/routing.yml`: an HTTPS listener that
terminates TLS, an HTTP listener that answers 308, `/auth` prefix-rewritten
to Kratos with the route's 45 s request timeout, `/` to a kanae stub, 32 KiB
per-connection buffers (`tcpListenerPerConnectionBufferLimitBytes` in
`internal/xds/translator/listener.go`), and the bootstrap's overload manager
(`internal/xds/bootstrap/bootstrap.yaml.tpl`). Envoy ran with
`--concurrency 3` on CPUs 0 to 2, shared with Kratos as on the node, in its
own cgroup with the limit under test. Kratos ran the 64MB hasher with
`GOMEMLIMIT=1300MiB` in a cgroup large enough that it never died, so every
Envoy number is Envoy holding connections against a live, saturated
backend. Envoy's admin endpoint was sampled every 0.5 s for heap size, open
connections, and overload-action state. The rate-limited load used the local
rate limit filter on the registration POST at 4 per second with a burst of
8.

### 2.7 Raw hash timing and the calibrate command

A small Go program timed `argon2.IDKey` alone, pinned to the same three
CPUs, taking the median of warm calls after two warm-up calls and recording
the cold first call. Ory's `kratos hashers argon2 calibrate` and `load-test`
commands (Ory Corp, 2026a; Ory Corp, 2026b) were run with the flags the
decision log used and with alternatives, on idle CPUs, and their source was
read to explain the timings.

### 2.8 Budget and default tracing

Envoy Gateway's chart defaults were traced through the project's git
history to the commits that set them. Node arithmetic used the templates'
current values, the k3s packaged manifests for `kube-system` requests (K3s
Contributors, 2026), and the kubelet's default eviction threshold (The
Kubernetes Authors, 2026b).

## 3. Results

### 3.1 Peak memory against signups in flight, Go defaults

**Table 2.** Closed loop, 12Gi cgroup, Go defaults, 128MB hasher.

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

Throughput peaks at 2 in flight and falls from there. At 16 and above the
median signup takes longer than 8 s and the peak was still climbing when the
trial ended. No trial in this series was killed. On the sustainable regime,
$C \le 8$ including the 60 s trials ($n = 24$):

$$\widehat{\text{peak}} = 285\,(\pm 53) + 231.2\,(\pm 10.4)\,C \ \text{Mi}, \qquad s_{\text{res}} = 121\ \text{Mi}, \quad R^2 = 0.958,$$

with a slope interval of $[210, 253]$ Mi per signup in flight. The 60 s
check found the 20 s peaks 3% low at $C = 4$, 13% low at $C = 6$, and 10%
low at $C = 8$, so 20 s peaks at $C \ge 6$ are slightly censored.

The 2.3Gi seen during the hurl suite is what this model gives for 8 to 9
concurrent logins. `hurl --test` runs files in parallel with one job per
CPU by default (Orange, 2025), and 81 of the scenarios in
`tests/integration/scenarios/` log in through the password flow, so a
machine with 8 or more CPUs produces that concurrency.

### 3.2 Poisson arrivals at the node's limit

**Table 3.** Open loop, 4Gi limit enforced, 20 s trials.

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

The knee is between 2 and 4 signups per second. At 4/s the mean latency is
already 3.4 s and 14 hashes are in flight, and the wide intervals there are
the queue going unstable in some replicates and not others. "Completed /s"
above 6/s counts submissions that returned before the kill and is not a
capacity. The 6/s and 8/s rows missed the kernel limit in 20 s only because
the ramp had not reached it. Above capacity the cgroup grew at 221 MiB/s
(SD 16, $n = 15$).

### 3.3 `GOMEMLIMIT` separates live memory from collector slack

**Table 4.** Peak Mi by `GOMEMLIMIT`, closed loop, 128MB hasher.

| in flight | defaults | `GOMEMLIMIT=1536MiB` | `GOMEMLIMIT=768MiB` |
| --- | --- | --- | --- |
| 1 | 446 [442, 451] | 446 [439, 453] | 447 [442, 452] |
| 2 | 634 [297, 970] | 642 [279, 1005] | 724 [697, 752] |
| 4 | 1281 [1269, 1293] | 1248 [1241, 1256] | 880 [846, 913] |
| 8 | 1995 [1768, 2223] | 1616 [1496, 1736] | 1049 [1042, 1056] |
| 16 | 3320 [2463, 4177] | 2075 [2057, 2093] | 2043 [1969, 2118] |

Where the limit binds (`GOMEMLIMIT=768MiB`, peak above 845 Mi, $n = 12$):

$$L(C) = 278 + 113.5\,(\pm 3.4)\,C \ \text{Mi}, \qquad s_{\text{res}} = 127\ \text{Mi}, \quad R^2 = 0.991,$$

so $B = 278$ Mi and $b = 113.5$ Mi, which is 0.93 of the 122 MiB block.
Throughput is unchanged up to $C = 4$ ($5.67 \pm 0.26$ /s against
$4.95 \pm 0.22$ /s with defaults) and drops at $C = 8$ ($2.15 \pm 0.54$ /s),
where $8 \times 128$ MB of live blocks exceed the 768MiB limit and the
collector runs continuously.

### 3.4 Parallelism 3 against 16 with the 128MB hasher

At $C = 2$, 16 lanes gave $6.03 \pm 0.39$ signups/s and 3 lanes
$5.67 \pm 0.06$ (Welch $t = 1.59$, $p = 0.25$). At $C = 4$, $4.95 \pm 0.22$
against $4.96 \pm 0.18$ ($p = 0.95$). Peaks were 634 against 731 Mi and 1281
against 1344 Mi ($p = 0.34$ and $0.39$). On 3 CPUs the setting changed
nothing measurable.

### 3.5 Verification at candidate limits

**Table 5.** Three trials per cell, 128MB hasher.

| limit | `GOMEMLIMIT` | C = 4 | C = 8 | 2 signups/s | 4 signups/s |
| --- | --- | --- | --- | --- | --- |
| 1Gi | unset | killed 3/3 | killed 3/3 | killed 2/3 | killed 3/3 |
| 1Gi | 900MiB | 0/3, peak 1011, 5.05 /s | killed 3/3 | 0/3, peak 932 | killed 2/3 |
| 1.5Gi | 1400MiB | 0/3, peak 1261, 4.58 /s | 0/3, peak 1503, 4.38 /s | 0/3, peak 1172 | 0/3, peak 1461, 3.18 /s |
| 2Gi | 1850MiB | 0/3, peak 1265, 4.65 /s | 0/3, peak 1789, 4.18 /s | 0/3, peak 1167 | 0/3, peak 1776, 2.42 /s |

Across all 24 trials at 1.5Gi and 2Gi there were no kills, which bounds the
kill probability below 12%. The 1.5Gi row at $C = 8$ peaked at 1503 Mi
against a 1536 Mi limit.

### 3.6 `GOMEMLIMIT` headroom, 9% against 15%

**Table 6.** 15 trials, 3 replicates, shuffled, 128MB hasher.

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

At 1.5Gi the peak sits 80 to 100 Mi above $G$ either way, so lowering $G$ by
94 Mi moved the peak down by the same amount at unchanged throughput. At
1Gi with the 128MB hasher the overshoot is the size of the headroom: one
trial at $C = 4$ touched the limit without being killed.

### 3.7 Raw hash time on 3 CPUs

**Table 7.** Warm median of 7 calls and the cold first call, idle CPUs.
The production setting at the time is in bold.

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

A second run on the same CPUs during phase 9, median of 5: 128MB/3/p16
187 ms, 128MB/3/p3 187 ms, 64MB/6/p3 178 ms, 64MB/6/p16 176 ms. Cost scales
with $m \cdot t$. No row meets Ory's own target of 0.5 to 1 s per hash (Ory
Corp, 2026c) on this CPU, the production row included.

### 3.8 Recalibrated hashers at 1Gi

**Table 8.** 45 trials at 1Gi with `GOMEMLIMIT=900MiB`. Peaks are means in
Mi; capacity is completed signups per second at the best closed-loop point.

| hasher | hash here | C = 4 | C = 8 | C = 16 | 2 /s | 4 /s | capacity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 128MB, 3 it, p16 (Table 5) | 147 ms | ok, 1011 | killed 3/3 | not run | ok, 932 | killed 2/3 | 5.7 /s |
| 64MB, 6 it, p16 | 140 ms | ok, 696 | ok, 953 | killed 3/3 | ok, 481 | ok, 751 | 5.8 /s |
| 64MB, 3 it, p16 | 72 ms | ok, 707 | ok, 974 | ok, 1010 | ok, 374 | ok, 673 | 10.1 /s |
| 19MiB, 2 it, p1 (OWASP floor) | 30 ms | ok, 385 | ok, 460 | ok, 659 | ok, 126 | ok, 162 | 35.6 /s |

Per-signup slopes over the unkilled closed trials: $b = 64.2\,(\pm 6.0)$ Mi
for 64MB at 6 iterations ($R^2 = 0.97$), one 64MB block; $b = 23.1\,(\pm 1.4)$
Mi for the OWASP floor ($R^2 = 0.97$). The 64MB, 3-iteration row shows no
slope ($b = 22 \pm 6$, $R^2 = 0.67$) because at 16 in flight its 1010 Mi
peak is the limit itself with the collector holding the line.

### 3.9 The calibrate command

Every probe the command ran on this machine took between 0.4 and 1.3 s,
whatever the parameters (Table 9).

**Table 9.** What `calibrate` and `load-test` timed against the raw hash.

| what the command timed | it reported | raw `argon2.IDKey` at the same parameters |
| --- | --- | --- |
| probe, 8MB, 1 iteration | 623 ms | 4 ms |
| probes while it halved memory down to 64 bytes | 870 to 1006 ms each | under 1 ms |
| load-test 60/min at 8MB, 1 iteration, 20 s | median 762 ms, min 425 ms, max 1281 ms | 4 ms |

The cause is in `cmd/hashers/argon2/root.go` (Ory Corp, 2026a): the CLI
wraps the hasher in an `argon2Config` whose `Config()` method writes all
eight argon2 keys into the live configuration store with `config.Set`, and
`Generate` in `hash/hasher_argon2.go` calls `h.c.Config().HasherArgon2(ctx)`
on every hash. `strace -c` on a probe shows the half second as `futex`,
`epoll_pwait`, and `nanosleep`, not CPU. Two consequences followed. With the
default 512MB step and a first probe already over the 500 ms target, the
command subtracts more than it has, the unsigned byte size wraps, and it
dies trying to allocate 64TB (`fatal error: runtime: out of memory`,
reproduced three times with the flags the decision log used). With a small
step it halves memory without end; the matrix run had to be killed after
its first cell spent 129 probes descending to 64 bytes.

Given a target above its overhead (`--min-duration 1500ms`,
`--start-memory 128MB --start-iterations 3 --adjust-memory-by 32MB`, 360
requests per minute, `--dedicated-memory` and `--max-memory` 1400MB), the
command proposed 224MB with 5 iterations, then its own load test failed and
it exited with status 1. That proposal was run under the swarm anyway
(Table 10), with the model's predictions written first: $b = 0.93 \times
213.6 = 199$ Mi, $C_{\max} = 5$ at 1.5Gi and 3 at 1Gi, cost per hash 2.9
times today's, so capacity near 2 signups per second.

**Table 10.** Calibrate's proposal under the swarm, 24 trials.

| hasher | pod | C = 4 | C = 8 | 2 /s | 4 /s |
| --- | --- | --- | --- | --- | --- |
| 128MB, 3 it | 1.5Gi + 1400MiB | ok, 1261, 4.6 /s | ok, 1503, 4.4 /s | ok, 1172 | ok, 1461, 3.2 /s |
| 224MB, 5 it (calibrate) | 1.5Gi + 1400MiB | ok, 1438, 1.6 /s | killed 3/3 | killed 3/3 | killed 3/3 |
| 128MB, 3 it | 1Gi + 900MiB | ok, 1011, 5.1 /s | killed 3/3 | ok, 932 | killed 2/3 |
| 224MB, 5 it (calibrate) | 1Gi + 900MiB | ok, 991, 1.7 /s | killed 3/3 | killed 3/3 | killed 3/3 |

Every prediction held. The one surviving cell at 1Gi peaked at 991 Mi
against a 1024 Mi limit, the borderline the arithmetic gave for
$C_{\max} = 3$.

### 3.10 Paired hashers: 128MB at 1.5Gi against 64MB at 1Gi

**Table 11.** 54 trials, 3 replicates, shuffled with seed 23, 20 s.

| load | 128MB/3/p16 at 1.5Gi + 1300MiB | 64MB/6/p3 at 1Gi + 870MiB | 64MB/6/p3 at 1.5Gi + 1300MiB |
| --- | --- | --- | --- |
| C = 4 | 1306 Mi, margin 174, 4.00 /s | 698 Mi, margin 291, 5.37 /s | 677 Mi, margin 843, 5.47 /s |
| C = 8 | 1384 Mi, margin 142, 4.13 /s | 944 Mi, margin 67, 4.93 /s | 1090 Mi, margin 388, 4.80 /s |
| C = 10 | 1409 Mi, margin 117, 3.67 /s | 968 Mi, margin 46, 4.82 /s | 1300 Mi, margin 156, 4.90 /s |
| C = 16 | killed 3/3 | killed 3/3 | 1348 Mi, margin 157, 4.53 /s |
| 2 /s | 1099 Mi, 1.80 /s, p50 560 ms | 477 Mi, 1.93 /s, p50 310 ms | 607 Mi, 1.88 /s, p50 343 ms |
| 4 /s | 1341 Mi, 3.02 /s, p50 980 ms | 765 Mi, 3.13 /s, p50 697 ms | 799 Mi, 3.42 /s, p50 543 ms |

At an equal pod the 64MB hasher takes 294 Mi less at 8 in flight and 109 Mi
less at 10, and survives 16 where the 128MB hasher is killed. Its slope is
$b = 54.1\,(\pm 9.6)$ Mi at 1.5Gi and $47.3\,(\pm 5.5)$ Mi at 1Gi. Throughput
is equal or better at every load (Welch $p = 0.001$ at $C = 4$ and 16,
$p = 0.09$ at 8 and 10). The 64MB hasher at 1Gi and the 128MB hasher at 1.5Gi
hold the same 10 in flight and die at the same 16.

### 3.11 Parallelism paired at 64MB, and headroom over 60 s

**Table 12.** 18 trials at 1Gi with `GOMEMLIMIT=870MiB`, 60 s, both lane
counts interleaved (seed 31). Differences are paired by replicate.

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

Every paired interval for peak and for throughput includes zero. Median
latency is lower with 3 lanes at every load, by 60 ms [35, 85] at $C = 8$.
One trial was OOM-killed, at p3, $C = 10$. This host hashed at 7.6 signups
per second in phase 9 against 5.1 in phase 7.

**Table 13.** The 1Gi pod over 60 s on the faster host, 64MB/6/p3.
"Time above $G$" is the share of 0.1 s samples with the cgroup over the
soft limit.

| load, `GOMEMLIMIT` | peak Mi [95% CI] | max | margin to 1024 | kills | signups/s | p50 ms | time above $G$ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C = 4, 870MiB | 777 [656, 898] | 827 | 197 | 0/3 | 7.90 | 427 | 0% |
| C = 6, 870MiB | 954 [841, 1068] | 985 | 39 | 0/3 | 7.71 | 673 | 9% |
| C = 8, 870MiB | 1015 [993, 1037] | 1022 | 2 | 0/3 | 7.56 | 893 | 41% |
| C = 8, 800MiB | 929 [891, 967] | 945 | 79 | 0/3 | 7.92 | 837 | 57% |
| C = 8, 750MiB | 896 [870, 922] | 903 | 121 | 0/3 | 7.66 | 893 | 72% |
| C = 10, 870MiB | 1012 [985, 1040] | 1024 | 0 | 1/3 | 6.62 | 1133 | 56% |
| C = 10, 800MiB | 962 [947, 976] | 968 | 56 | 0/3 | 7.40 | 1100 | 78% |
| 4 /s, 870MiB | 812 [525, 1099] | 887 | 137 | 0/3 | 3.64 | 267 | 1% |

Lowering $G$ from 870MiB to 800MiB and 750MiB moved the $C = 8$ peak down by
86 and 119 Mi at unchanged throughput (7.56, 7.92, 7.66 per second). At
$C = 10$ the drop to 800MiB turned one kill in three into 56 Mi of margin
and raised throughput from 6.62 to 7.40.

### 3.12 The Envoy proxy

**Table 14.** 63 trials. Peak is the cgroup high-water mark; heap is the
largest `server.memory_heap_size` reported, which tcmalloc grows in 4 Mi
steps; "overload" counts trials in which `stop_accepting_requests` became
active; signups/s is what Kratos completed behind the proxy.

| limit | load | n | peak Mi | 95% CI | max | heap Mi | connections | overload | 5xx | 429 | OOM | signups/s |
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

The limit changed nothing. Across the 15 closed-loop trials with no limit,

$$P(C) = 15.0 + 0.068\,C\ \text{Mi},\qquad R^2 = 0.995,\qquad s_{\text{res}} = 0.1\ \text{Mi},$$

with $b \in [0.065, 0.070]$ Mi per open connection and $B \in [14.9, 15.1]$
Mi, where $C$ here counts open client connections. The prediction interval
at 100 connections, 21.4 to 22.1 Mi, matched the 75/s trials at 21.1 to
21.6; at 200 connections it is 27.9 to 29.1 Mi. The 45 s timeouts in the
75/s trials (89 to 99 per trial) returned as 504s without moving the peak.
The `fixed_heap` monitor reported 25% pressure at the worst load under the
64Mi cap. Neither overload action fired in any trial.

## 4. Discussion

### 4.1 What the memory model says

Both measured slopes are the arithmetic of the hasher. With Go's defaults,
$b \approx 231$ Mi is two 128MB blocks, the live one and the one the
collector has not yet reclaimed because `GOGC=100` lets the heap double.
With `GOMEMLIMIT` binding, $b \approx 113$ Mi is one block. The intercept,
$B = 278$ Mi, is the runtime, configuration, connection pool, and servers.
So the pod's capacity in flight is $C_{\max} = \lfloor (G - B)/b \rfloor$,
and a limit is a statement about how many hashes may run at once.

That also answers the 75 signups per second question. The node's three CPUs
completed at most 6 signups per second, about 0.5 core-seconds each. Above
capacity, in-flight hashes pile up and the cgroup grows at 221 MiB/s until
the limit kills the container: 3 s at 1Gi, 5 s at 1.5Gi, 16 s at 4Gi, which
is the whole node. A larger limit buys seconds. Every offered rate of 10 per
second or more was killed at 4Gi within a 20 s trial. Serving 75 per second
would need roughly $\lambda W m = 75 \times 0.5 \times 128\ \text{MB} \approx
4.7$ GB for Kratos alone and about 40 cores at this machine's hash speed.
What makes 75 per second survivable is admission control, not memory.

### 4.2 Why the 1Gi pod needs the 64MB hasher and a 750MiB target

A 1Gi pod with the 128MB hasher holds $\lfloor (900 - 278)/113.5 \rfloor = 5$
in flight and was killed at 8 and at 4 per second (Table 5). Halving $m$
halves $b$ (47 to 54 Mi measured, Table 11) and doubles $C_{\max}$. Doubling
$t$ to 6 keeps $m \cdot t = 384$, so the work per guess is unchanged. The
paired comparison found the 64MB hasher at 1Gi holds the same 10 in flight
as the 128MB hasher at 1.5Gi, at equal or higher throughput, and the same
swarm through the proxy and over 60 s confirmed 8 in flight with 121 Mi to
spare at `GOMEMLIMIT=750MiB` (Table 13).

The headroom under `GOMEMLIMIT` has to be a number of blocks, not a
percentage. The collector overshoots its soft target by about the garbage
one collection cycle produces, which is one to two argon2 blocks. At 1.5Gi
that is 15% of the pod (Table 6). At 1Gi on a host that hashes 50% faster,
870MiB left 2 Mi at 8 in flight and was killed once in three at 10, while
750MiB held 8 with 121 Mi and 800MiB held 10 with 56 Mi, at the same
throughput (Table 13). 750MiB is the live set at 8 in flight, about 678 Mi,
plus one block, so it is the lowest target that does not make the collector
chase memory it cannot free. The general rule is
$1 - G/\text{limit} \ge 2b/\text{limit}$: 15% for a 128MB hasher at 1.5Gi,
27% for a 64MB hasher at 1Gi.

Parallelism should be 3, the core count. At 128MB, 3 and 16 lanes did not
differ (§3.4). At 64MB the paired trials found no difference in memory or
throughput and 60 ms lower median latency with 3 lanes (Table 12), which is
the cost of scheduling 16 goroutines per hash onto 3 cores. The security
argument in §4.3 points the same way.

The 20 s trials of phase 7 under-read what 60 s trials on a faster host
showed, which is the censoring §3.1 measured and the reason the final
verification ran at 60 s. The 1.5Gi alternative with the 128MB hasher and
`GOMEMLIMIT=1300MiB` was verified only in 20 s trials at 5 signups per
second. If that alternative is ever used, re-run it at 60 s first.

### 4.3 What halving the hasher costs an attacker

The question is whether `memory: 64MB`, `iterations: 6`, `parallelism: 3`
leaves an attacker with an easier job than `128MB`, `3`, `16`. Under the
three usual cost models it does not.

Time per guess on hardware like ours is the same: 178 ms against 187 ms on
the same three CPUs (§3.7), because $m \cdot t$ is the same. Throughput on
a bandwidth-bound cracker is the same: a GPU's rate is bounded by memory
bandwidth, which the Argon2 specification puts near 400 GB/s (Biryukov et
al., 2017, §2.1), and each guess moves $m \cdot t$ bytes. A cracker with
fixed memory can hold twice as many 64 MiB guesses in flight, but each needs
twice the passes, so guesses per second do not change. What is halved is the
memory per guess as an absolute, which helps only an attacker whose platform
is capacity-bound rather than bandwidth-bound. That is the reading of the
decision log's "the point of argon2 is the memory" that has substance.

On the specification's own cost measure, the time-area product, the new
setting is more expensive. Chip area $A$ scales with $m$ and running time
$T$ with the longest sequential chain, $t$ passes over the $m/p$ blocks of
one lane, since the $p$ lanes run side by side (Biryukov et al., 2017,
§2.1):

$$A \cdot T \propto m \times \frac{t\,m}{p}, \qquad \text{before: } 128 \times \frac{3 \times 128}{16} = 3072, \qquad \text{after: } 64 \times \frac{6 \times 64}{3} = 8192 .$$

`parallelism: 16` on a 3 vCPU node gave the defender nothing and handed an
attacker 16 lanes to fill in parallel. Against OWASP's Argon2id minimum of
19 MiB, 2 iterations, 1 lane (OWASP Cheat Sheet Series Team, 2026), the new
setting has 3.4 times the memory and, at $m \cdot t = 384$ against 38, ten
times the work per guess.

The hash parameters govern offline cracking of a stolen table. Online
guessing against the live service is governed by the rate limit in §4.4,
which no hash parameter changes. Existing hashes carry their own parameters
in the `$argon2id$` string and keep verifying; new registrations and
password changes take the new ones.

### 4.4 The rate limit, derived

Envoy Gateway's local rate limit is a token bucket. `local_ratelimit.go` in
the xDS translator builds Envoy's `TokenBucket` with `max_tokens =
requests`, `tokens_per_fill = requests`, and `fill_interval = unit` (Envoy
Gateway Authors, 2026a). So `requests: r, unit: Second` admits at most $r$
in any burst and refills $r$ per second: the burst $B$ and the sustained
rate $\lambda$ are the same number, and a coarser unit only makes the burst
larger. A fixed-window counter would admit $2B$ across a window edge; a
leaky bucket smooths output rather than bounding admissions, and Envoy does
not offer one. In any interval of length $T$ a token bucket admits at most
$B + \lambda T$.

Little's law gives the in-flight count from the admitted rate and the time
each request spends in Kratos, $C = \lambda W$ (Little, 1961). Treating the
hashing stage as one server of capacity $\mu$ (the measured signups per
second at saturation, which already includes the slowdown parallel hashes
cause each other) with Poisson arrivals,

$$\rho = \frac{\lambda}{\mu}, \qquad \bar W = \frac{1}{\mu - \lambda}, \qquad C_{\text{worst}} = B + \lambda \bar W = B + \frac{\lambda}{\mu - \lambda}.$$

Exponential service is pessimistic for a hash whose time barely varies, so
$\bar W$ is an upper estimate. The requirement is $C_{\text{worst}} \le
C_{\text{safe}} = 8$, from Table 13. The capacity to use is the slowest one
measured, $\mu = 5.1$ per second. Each rule of the policy is its own bucket,
so with two routes at $r$ each, $\lambda = B = 2r$:

**Table 15.** The limit against the bound.

| $r$ per route | $\lambda$, $B$ | $\rho$ at $\mu = 5.1$ | $\bar W$ | $C_{\text{worst}}$ at $\mu = 5.1$ | at $\mu = 7.6$ |
| --- | --- | --- | --- | --- | --- |
| 1 | 2 | 0.39 | 0.32 s | 2.6 | 2.4 |
| 2 | 4 | 0.78 | 0.91 s | 7.6 | 5.1 |
| 3 | 6 | 1.18 | unstable | unbounded | 9.8 |

$r = 2$ is the largest integer under 8 on the slow host, and 4 per second
is what the open-loop trials ran with 0 kills in 6 across phases 7 and 9.
$r = 3$ exceeds the slow host's capacity, and past $\mu$ the queue grows
until the 45 s route timeout, which Table 3 measured as a certain kill.

The policy selects its own traffic, so the HTTPRoute is unchanged. A local
rule's `clientSelectors` take `methods` and `path`, and the translator turns
the path selector into a descriptor on Envoy's `:path` header, the path as
it arrived before the router's rewrite (`buildPathMatchLocalRateLimitAction`,
Envoy Gateway Authors, 2026a). A request matching no rule falls to the
default bucket, which is `math.MaxUint32` when every rule has selectors
(`buildLocalRateLimit` in `backendtrafficpolicy.go`), so the flow-initialising
GET, which hashes nothing, stays unlimited. The object is
`kratos-auth-limiter` in `deploy/kubernetes/src/templates/routing.yml`,
reading `gateway.authRateLimit.requestsPerSecond` from the chart values: 2
in production, 50 locally so the parallel hurl suite never trips it.

### 4.5 The proxy and the control plane

The proxy is not where the memory goes. Every byte it holds is a connection
or a buffer, and Table 14 measured 0.068 Mi per open connection on a 15 Mi
base. Envoy Gateway derives an overload-manager heap cap from the limit:
`calculateMaxHeapSizeBytes` returns 80% of `limits.memory`, and the
bootstrap template triggers `shrink_heap` at 95% of that and
`stop_accepting_requests` at 98% (Envoy Gateway Authors, 2024). The number a
limit $M$ enforces is therefore $H_{\text{stop}} = 0.784\,M$, and the
connections that reach it are $(H_{\text{stop}} - B)/b$: 330 at 48Mi, 520 at
64Mi, 1260 at 128Mi. Past that the proxy refuses requests, which is the
graceful failure; it is never killed first because the cap sits under the
limit. The 64Mi in `deploy/kubernetes/envoy.yml` stays.

Where the chart defaults come from matters because the budget had been
trusting them. The proxy's default of `512Mi` request and no limit was
introduced with the first support for setting proxy resources at all and
carries no measurement (Envoy Gateway Authors, 2023a). The control plane's
`256Mi` request and `1024Mi` limit were `64Mi` and `128Mi` until a commit
titled "bump resource limits for Envoy Gateway deployment" raised them in
response to an issue (Envoy Gateway Authors, 2023b); the issue's text was
not reachable from this study's network. The proxy pod also carries a
`shutdown-manager` sidecar with a 32Mi request and no limit that
`EnvoyProxy` cannot change (`resource.go`, Envoy Gateway Authors, 2026a), so
the pod reserves 96Mi, not 64Mi.

The control plane carries no traffic, so no load test can size it. Its
memory tracks how many Gateway, route, Secret, and Service objects it
translates, which is fixed here at one Gateway and two HTTPRoutes. The
repository's own reading with those objects present is 61 Mi
(`DECISIONS.md`). Twice that, 128Mi as request and limit with
`GOMEMLIMIT=110MiB` through the chart's `extraEnv`, is what this branch
sets in `deploy/kubernetes/helmfile.yaml`. It is the one number in this
paper that rests on a reading rather than on trials, and
`mise run k8s:measure --namespace envoy-gateway-system` after the e2e
suite checks it.

### 4.6 The node budget

Requests are what the scheduler reserves, so requests are what has to fit.
Table 16 is the state of this branch.

**Table 16.** Memory requests as this branch sets them. Request equals
limit unless stated.

| pod, container | this branch | source |
| --- | --- | --- |
| kanae | 512Mi | `templates/kanae.yml` |
| postgres | 1024Mi (the plan's table says 512Mi) | `templates/postgres.yml` |
| kratos | 1024Mi, `GOMEMLIMIT=750MiB`, hasher 64MB/6/p3 | `templates/kratos.yml`; Tables 11 and 13 |
| keto | 256Mi | `templates/keto.yml` |
| valkey | 256Mi | `templates/valkey.yml` |
| envoy proxy, `envoy` | 64Mi | `envoy.yml`; Table 14 |
| envoy proxy, `shutdown-manager` | 32Mi request, no limit | not settable through `EnvoyProxy` |
| envoy gateway control plane | 128Mi, `GOMEMLIMIT=110MiB` | `helmfile.yaml`; the 61 Mi reading |
| cert-manager, three pods | 224Mi | `helmfile.yaml` |
| **kanae and controllers** | **3520Mi (3.44Gi)** | |
| CoreDNS | 70Mi request, 170Mi limit | k3s `manifests/coredns.yaml` |
| metrics-server | 70Mi request | k3s `manifests/metrics-server/` |
| Cilium agent and operator | no request, about 200Mi in use | `helmfile.yaml`; `DECISIONS.md` |
| **everything the scheduler counts** | **3660Mi (3.57Gi)** | |

Deploy time adds one 256Mi migration Job at a time, 3916Mi, because the
apply order finishes each Job before app pods schedule and kanae uses
`strategy: Recreate`. Kratos at 1.5Gi would total 4172Mi. What the node
offers is the `Allocatable` the plan says to copy from
`kubectl describe node`, which has not been written down. Two bounds, using
the kubelet's default eviction threshold of `memory.available<100Mi` (The
Kubernetes Authors, 2026b) and no other reservation:

| node | allocatable | headroom at steady state | during a migration Job | Kratos at 1.5Gi |
| --- | --- | --- | --- | --- |
| 4 GiB (4096Mi) | 3996Mi | 336Mi | 80Mi | 176Mi short, Pending |
| 4 GB decimal (3815Mi) | 3715Mi | 55Mi | 201Mi short, Pending at deploy | 457Mi short |

Physical headroom is smaller by what no request covers: Cilium's 200 Mi,
the sidecar's use above 32Mi, and the k3s server process. Kratos at 1.5Gi
fits on neither bound. Postgres back at the plan's 512Mi is the one lever
that adds 512Mi to every cell.

### 4.7 Threats to validity

- CPU speed and contention. The production node's hash speed is unknown,
  because the one in-cluster figure came from the calibrate command (§3.9).
  Postgres did not compete for Kratos's cores here. Both make the rates in
  this paper optimistic. The per-concurrency memory slopes do not depend on
  CPU speed, and the two hosts used here (5.1 and 7.6 signups per second)
  gave the same slopes.
- Storage. Postgres 16 with `fsync=off`, not Postgres 18 on a block
  volume. Slower commits lengthen each signup and raise in-flight at a
  given rate.
- Censoring. 20 s trials under-read the peak by up to 13% at $C = 6$ to 8
  and more above. The recommendation rests on 60 s trials.
- Replicates. Three per cell give wide intervals at the open-loop knee,
  4 to 6 per second, where queueing is unstable. No conclusion rests on
  those cells.
- Cgroup v1 against v2. `memory.max_usage_in_bytes` and `memory.peak`
  measure the same charged bytes, page cache included. The database is
  remote, so Kratos's own page cache is small.
- The Envoy configuration is a copy, not the controller's output. The
  listener, routes, buffer limit, and overload manager match; the controller
  also adds access logging, a stats sink, and an xDS connection, none of
  which hold per-connection memory. The control plane was not run.
- The webhook stub. Kanae's real webhook does a database insert and a Keto
  write. A slower webhook holds the flow open longer, but the hash block is
  already freed by then.
- One machine, two sessions. The host was faster in phase 9 than in
  phase 7. The paired designs compare within a session; the headroom
  finding is the one that depended on the faster session, and it errs on
  the safe side.

### 4.8 Recommendations

Items 1 to 6 are implemented in this branch. Items 7 and 8 are open.

1. Kratos: `requests.memory: 1Gi`, `limits.memory: 1Gi`, and
   `GOMEMLIMIT=750MiB` in the container's environment
   (`deploy/kubernetes/src/templates/kratos.yml`). 750MiB is 73% of the
   limit: the live set at 8 in flight plus one block (§4.2).
2. Hasher: `memory: 64MB`, `iterations: 6`, `parallelism: 3` in
   `docker/ory/config/kratos/kratos.prod.yml`, which the Compose production
   stack also loads. `dedicated_memory` is read only by the calibrate and
   load-test commands, never on the serving path; 512MB describes eight
   64MB hashes. Record in `DECISIONS.md` that $m \cdot t$ is unchanged and
   the time-area cost is 2.7 times higher, superseding "the point of argon2
   is the memory".
3. Admission control: the `kratos-auth-limiter` `BackendTrafficPolicy` with
   `requests: 2, unit: Second` on each of the registration and login POSTs,
   from `gateway.authRateLimit.requestsPerSecond` (§4.4). A 429 at the
   gateway is a retry for one person; an OOM kill is a failed signup for
   everyone in flight.
4. Envoy proxy: `64Mi` request and limit, unchanged. Count the pod as 96Mi
   for the sidecar.
5. Envoy Gateway control plane: `128Mi` request and limit with
   `GOMEMLIMIT=110MiB` in `helmfile.yaml`, then confirm it with
   `k8s:measure` in `envoy-gateway-system` after e2e. If the peak there is
   over 100 Mi, the number is wrong and the chart's 256Mi stands.
6. The hurl suite against a limited Kratos: `--jobs 4` or lower, because
   the default is one job per CPU and each job is a login.
7. Measure the node. Copy `Allocatable` from `kubectl describe node` into
   the plan's budget table, and run the load test at `-u 4` for 60 s to
   read the node's own capacity. If it is under 5 signups per second, set
   `requestsPerSecond` to 1 (Table 15).
8. Do not use `kratos hashers argon2 calibrate` to pick hasher values until
   the overhead in its CLI wrapper is fixed upstream. Time the hash with
   the load test at `-u 1` instead. Do not size for 75 signups per second
   on this node; it is a capacity question, and only the OWASP floor
   (Table 8) brings it within reach of three CPUs.

### 4.9 Reproducing the study

Against the k3d cluster, run `locustfile.py` as `RUN_THE_LOAD_TEST.md`
shows, then `mise run k8s:measure`. Through the Gateway, point `-H` at the
Gateway's `/auth` and set `LOAD_CA_BUNDLE` to the local issuer's
certificate. The sandbox harness (cgroup wrapper, webhook and SMTP stubs,
trial randomisation, the Envoy static configuration) is not committed
because it assumes cgroup v1 and a local Postgres; the two CSVs beside this
file have every trial's inputs and outputs.

## References

Biryukov, A., Dinu, D., & Khovratovich, D. (2017). *Argon2: The memory-hard function for password hashing and other applications* (Version 1.3, PHC release). University of Luxembourg. https://github.com/P-H-C/phc-winner-argon2/blob/f57e61e19229e23c4445b85494dbf7c07de721cb/argon2-specs.pdf

Byström, C., Heyman, J., & Holmberg, L. (2026). *Locust* (Version 2.46.6) [Computer software]. GitHub. https://github.com/locustio/locust/tree/3b926d19d990a26a8c0a8f2ad96c09815adc2c9e

Envoy Gateway Authors. (2023a). *Support envoy proxy container resources settings (#1197)* [Commit 666bf2aae]. GitHub. https://github.com/envoyproxy/gateway/commit/666bf2aae65785473a487c5d8fb519892e4df486

Envoy Gateway Authors. (2023b). *Bump resource limits for Envoy Gateway deployment (#1617)* [Commit 005b5b3c]. GitHub. https://github.com/envoyproxy/gateway/commit/005b5b3c2b7f34996add4ad2ddbaa6154fd7d61c

Envoy Gateway Authors. (2024). *Feat: configure overload manager (#3082)* [Commit 07f8a472]. GitHub. https://github.com/envoyproxy/gateway/commit/07f8a472

Envoy Gateway Authors. (2026a). *Envoy Gateway* (Version v1.9.1) [Computer software]. GitHub. https://github.com/envoyproxy/gateway/tree/c25e1cc2291b64807ea04f701513d1bbcc16cb6a. Files read: `api/v1alpha1/shared_types.go`, `api/v1alpha1/envoyproxy_helpers.go`, `internal/infrastructure/kubernetes/proxy/resource.go`, `internal/xds/bootstrap/bootstrap.yaml.tpl`, `internal/xds/translator/listener.go`, `internal/xds/translator/local_ratelimit.go`, `internal/gatewayapi/route.go`, `internal/gatewayapi/backendtrafficpolicy.go`, `charts/gateway-helm/values.tmpl.yaml`, `site/content/en/v1.9/tasks/operations/customize-envoyproxy.md`, `site/content/en/v1.9/tasks/traffic/local-rate-limit.md`, `site/content/en/v1.9/api/extension_types.md`.

K3s Contributors. (2026). *K3s* [Computer software]. GitHub. Files read: `manifests/coredns.yaml` and `manifests/metrics-server/metrics-server-deployment.yaml`. https://github.com/k3s-io/k3s/tree/bb14efb431193972879eca2077f87b3ae17970f2/manifests

Little, J. D. C. (1961). A proof for the queuing formula: L = λW. *Operations Research, 9*(3), 383–387. https://doi.org/10.1287/opre.9.3.383

Orange. (2025). *Hurl manual* (Version 8.0.1) [Documentation source, `docs/manual.md`]. GitHub. https://github.com/Orange-OpenSource/hurl/blob/59c65c4c2777f873edf8b67e4f24d9e2e5bce4f2/docs/manual.md

Ory Corp. (2026a). *Ory Kratos* (Version v26.2.0) [Computer software]. GitHub. https://github.com/ory/kratos/tree/11979ed02d86a3a540fb5fbf2e59c9af44b98ac1. Files read: `hash/hasher_argon2.go`, `cmd/hashers/argon2/calibrate.go`, `cmd/hashers/argon2/loadtest.go`, `cmd/hashers/argon2/root.go`, `driver/config/config.go`, `embedx/config.schema.json`.

Ory Corp. (2026b). *Performance problems and out of memory panics caused by password hashing* [Documentation source]. GitHub. https://github.com/ory/docs/blob/4a8e1bb690e9538235095595eabd3fa72a82d571/src/components/Shared/kratos/debug/performance-out-of-memory-password-hashing-argon2.md

Ory Corp. (2026c). *Argon2 password hashing parameters* [Documentation source]. GitHub. https://github.com/ory/docs/blob/4a8e1bb690e9538235095595eabd3fa72a82d571/docs/kratos/guides/setting-up-password-hashing-parameters.md

OWASP Cheat Sheet Series Team. (2026). *Password storage cheat sheet* [Documentation source]. GitHub. https://github.com/OWASP/CheatSheetSeries/blob/c04039adbe6f727a2198b3a3ea634fec98ac068a/cheatsheets/Password_Storage_Cheat_Sheet.md

The Envoy Project Authors. (2026a). *Envoy* (Version v1.39.1) [Computer software]. GitHub. https://github.com/envoyproxy/envoy/tree/b579d07d3ad7ee11d32b105e91a5a39ad24718d7

The Envoy Project Authors. (2026b). *Overload manager* [Documentation source, `docs/root/configuration/operations/overload_manager/overload_manager.rst`]. GitHub. https://github.com/envoyproxy/envoy/blob/726d7acb73934085cbbccc83ea47fdd78b583d7e/docs/root/configuration/operations/overload_manager/overload_manager.rst

The Go Authors. (2026a). *golang.org/x/crypto/argon2* [Computer software]. GitHub. https://github.com/golang/crypto/blob/7a4a4d6beae2222add4437a0910bd48414e19211/argon2/argon2.go

The Go Authors. (2026b). *A guide to the Go garbage collector* [Documentation source]. GitHub. https://github.com/golang/website/blob/f2661d967b28530da480f0a1da9a4279026d34ca/_content/doc/gc-guide.html

The Kubernetes Authors. (2026a). *Resource management for pods and containers* [Documentation source]. GitHub. https://github.com/kubernetes/website/blob/af194d7c84fbd2007a1d286160e60d755549c7f0/content/en/docs/concepts/configuration/manage-resources-containers.md

The Kubernetes Authors. (2026b). *Node-pressure eviction* [Documentation source]. GitHub. https://github.com/kubernetes/website/blob/af194d7c84fbd2007a1d286160e60d755549c7f0/content/en/docs/concepts/scheduling-eviction/node-pressure-eviction.md

Internal documents cited by path: `infra-plans/KANAE_INFRA_PLAN.md` (the node budget and Phase 8), `deploy/kubernetes/docs/DECISIONS.md` (the 512Mi Kratos entry, the control plane entry, and the Cilium entry).
