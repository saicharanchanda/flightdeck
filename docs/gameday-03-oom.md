# Game day 03 — OOMKill

**Date:** 2026-10-18, Step C on 2026-10-19 · **Cluster:** eks-practice (us-east-1) ·
**Fault:** lower the flights container memory limit until it is OOMKilled ·
**Load:** k6 `loadtest/k6/baseline.js`, 20 iterations/s (150/s during the spike step)

## Outcome in one paragraph

The Go runtime doesn't see the container's memory limit:
`go_gc_gomemlimit_bytes` read `math.MaxInt64`. At a 32Mi limit that didn't
matter. flights' memory is small and flat (≈ 8Mi, and **unchanged at 7.5× the
traffic**), so it never got close, not even under a 150 req/s spike. Tighter
limits killed it: 8Mi once, 6Mi in a crash loop within a minute (back-off
doubling to the 5-minute cap). The crash-loop alert fired **10 minutes into the
loop, before the SLO page**, and the gateway mostly **hung for its 5s timeout**
(504). Then the A/B: **the same 6Mi limit with `GOMEMLIMIT` set ran 10 minutes
with 0 restarts, against 12 without it.** The ~8Mi "floor" was mostly heap the
unaware GC chose to keep; told the limit, the GC held the heap at 1.4Mi. The
price was ~17× the CPU on the busier pod and 2× the latency. The chart now
sets `GOMEMLIMIT` to 90% of every container's limit.

> **Correction (2026-10-19).** Until Step C, this writeup said Go's
> unawareness of the limit "wasn't what killed flights", because I assumed
> the ~8Mi working set was a floor. Step C disproved that: at 6Mi, the
> unaware GC is exactly what killed it.

## Prerequisite: the notifier "restart" at 13:49Z

Checked before injecting anything, so this game day starts from a clean baseline.

**It wasn't a restart — it was a rolling replacement during a deploy, with a clean exit. Not an OOM.**

| Evidence | What it shows |
|---|---|
| kube-state-metrics over 6h, all four notifier pods ever created | `kube_pod_container_status_restarts_total` = **0** for each, and **no** `kube_pod_container_status_last_terminated_reason` series at all |
| `helm history flightdeck` | Revision **6** at **13:49:23Z**: the upgrade that switched chaos back off after the Loki demo, so the ConfigMap checksum changed |
| Pod lineage | `…5948d4fddf-jlfv6` (chaos-on template, created 13:45:33Z) was replaced by `…567c86467-4lxsj` (chaos-off, created **13:49:39Z**) |
| Loki — old pod | 13:49:44.95 `shutdown started` (SIGTERM, 10s drain) → 13:49:46.31 `worker draining complete` → `worker stopped`: a graceful exit, ~1.4s, as the in-flight BLPOP timed out |
| Loki — new pod | 13:49:39.88 `starting` (`chaos_enabled: false`): up 5s before the old one was told to stop (`maxUnavailable: 0`) |

There is no exit code or previous-container log to show: the pod was deleted,
not restarted, so the kubelet never recorded a terminated state. Loki's copy
of its logs is the only record, which is an argument for centralised logs in itself.

## Prediction vs outcome

Prediction written 17:47:38Z, before inspecting flights' memory or changing anything.

| # | Prediction | Outcome | Verdict |
|---|---|---|---|
| P1 | Go is **not** aware of the cgroup limit: `go_gc_gomemlimit_bytes` = `math.MaxInt64`; GC paces on `GOGC=100` only. | `go_gc_gomemlimit_bytes` = **9223372036854776000** on both pods; `go_gc_gogc_percent` = 100; no `GOMEMLIMIT`/`GOGC` in the pod spec. | ✅ |
| P2 | 32Mi may **not** kill flights at 20 req/s: it used ~6Mi. If it survives, that's the finding; escalate and say so. | 32Mi: **no kill** in 5 min (6.4–7.4Mi). Spike to **150 req/s** for 4 min: peak **8.2Mi**, 0 errors. | ✅ |
| P3 | The request must drop too (64Mi request > 32Mi limit is invalid). | Request and limit both set; scheduling changed accordingly. | ✅ |
| P4 | `maxUnavailable: 0`: if new pods die before Ready, the rollout stalls with old pods serving; if later, the old pods are gone. | New pods started at ~2.5Mi (below every limit tried), became Ready, and the rollout **completed**; they died afterwards. | ✅ (the "later" case) |
| P5 | `OOMKilled`, exit 137, no Go stack trace; back-off 10s, 20s, 40s … capped at 5m. | Exactly: `Reason: OOMKilled`, `Exit Code: 137`; `--previous` logs end in an ordinary request line. Restart gaps 30, 30, 60, 90, 180, **300s**. | ✅ |
| P6 | Gateway returns **502** for requests in flight to a dying pod, **not hangs** (5s client timeout). | One isolated kill (8Mi): exactly 2 × 502 `connection reset by peer`, 598 OK in the same 30s. **During the crash loop: 9,725 × 504 vs 1,109 × 502** — it mostly **hung for 5s**. | ❌ for the crash loop |
| P7 | `FlightdeckPodCrashLooping` fires ~10–12 min after the first back-off. | Pending 18:13:28 → **firing 18:23:28**; first back-off 18:13:00. | ✅ |
| P8 | Readiness won't help; the process dies, it doesn't go unready. | Partly wrong: between kills the pods were briefly **Ready** and received traffic they couldn't serve. | ⚠️ |

## Timeline (UTC)

| Time | Event |
|---|---|
| 17:47:38 | Prediction written |
| 17:47:55 | flights resources: requests 50m / 64Mi, limits 250m / 128Mi. No `GOMEMLIMIT`, no `GOGC` |
| 17:48:12 | k6 20 iterations/s for 40m |
| 17:49–17:52 | **Baseline:** working set 7.6–8.9Mi, heap in use 3.5–4.4Mi, `go_gc_gomemlimit_bytes` = MaxInt64, GOGC 100, GOMAXPROCS 2 |
| 17:52:51 | **Step A1:** request + limit → **32Mi** (revision 9) |
| 17:53:50 | Rollout complete, 2/2 Ready |
| 17:54–17:59 | Working set 6.4–7.4Mi, 0 restarts, 0 errors |
| 17:59:24 | **Step A2:** k6 **150 req/s** for 4m, still 32Mi |
| 18:03:21 | Spike peak working set **8.2Mi**; gateway CPU 55% of request (HPA target 70%, replicas 2) |
| 18:04:08 | k6 back to 20 req/s |
| 18:04:09 | **Step B:** request + limit → **8Mi** (revision 10) |
| 18:05:55 | **First OOMKill:** `…swfs4`, exit 137, after 73s running; restarted 1s later. Gateway: 2 × 502 at 18:05:55.54 (in flight, `connection reset by peer`, 56ms and 206ms — slow just before death) |
| 18:06–18:10 | No further kills; the other pod hovered at 7.3–7.4Mi of 8Mi and survived |
| 18:10:37 | **Step B2:** request + limit → **6Mi**, `goMemLimit.enabled=false` (revision 11) |
| 18:11:34 | Both new pods Ready at 2.7Mi |
| 18:12:15 | **Both OOMKilled** (restart 1) |
| 18:13:00 | First `CrashLoopBackOff` |
| 18:13:28 | `FlightdeckPodCrashLooping` **pending** (also `KubePodCrashLooping`, then `KubePodNotReady`) |
| 18:13:43 | Both pods in back-off; gateway 502 1.8/s, **p99 5s** |
| 18:14:24 | Gateway **504 5.8/s** + 502 1.3/s |
| 18:18–18:22 | **Successful reads 0/s** — complete flights outage; 504 at ~18.5/s |
| 18:23:28 | `FlightdeckPodCrashLooping` **firing** (in Alertmanager: "flightdeck/flightdeck-flights-…-ws4s6 (flights) is crash-looping") |
| 18:23:45 | `…bxv86` restart #7, at the 300s back-off cap |
| 18:24 | Availability burn 5m 96.6, **1h 14.1** — the fast-burn page still hadn't fired |
| 18:25:47 | **Restore:** committed defaults (64Mi / 128Mi) **plus the new `GOMEMLIMIT` = 90% of limit**, chaos off (revision 12) |
| 18:26:43 | All five app pods new, 0 restarts |
| 18:27 | `GatewayAvailabilityFastBurn` **fires — after the fix**: the 1h window crossed 14.4× only once the outage was over |
| 18:27:29 | `go_gc_gomemlimit_bytes` now 120795955 (flights, gateway), 60397977 (notifier) |
| 18:28:30 | flights 7.4–7.6Mi of 128Mi, gateway 0 errors |
| *2026-10-19* | **Step C** (times are server/Kubernetes clock — the workstation clock had drifted 606s behind overnight) |
| 05:53:19 | k6 20 iterations/s for 20m |
| 05:54:42 | **Step C:** flights request + limit **6Mi** with `GOMEMLIMIT` = **5662310** (90%, chart default), chaos enabled exactly as in B2 (revision 13). Runtime confirms `go_gc_gomemlimit_bytes` = 5662310 |
| 05:54:42–06:04:42 | **0 restarts on either pod.** Peak working set **4.2Mi / 4.9Mi** of 6Mi; heap in use 1.3–1.4Mi; gateway 10,656 × 200, 1,222 × 202, **0 × 5xx** |
| 06:05 | Restore: committed defaults with `GOMEMLIMIT` (revision 14), k6 stopped |

### Step C — A/B with and without `GOMEMLIMIT`

Same limit (6Mi request and limit), same load (k6 20 req/s), same chaos
setting, both counted over the 10 minutes from pod creation with
`max_over_time(kube_pod_container_status_restarts_total[10m])`:

| | **B2** — no `GOMEMLIMIT` (2026-10-18 18:11:21Z) | **C** — `GOMEMLIMIT=5662310` (2026-10-19 05:54:42Z) |
|---|---|---|
| Restarts (2 pods, 10 min) | **12** (6 + 6) | **0** (0 + 0) |
| Peak working set | above 6Mi (killed; 30s scrapes saw 5.1–5.6Mi) | **4.2 / 4.9Mi** |
| Heap in use | 2–4Mi before each kill | **1.3–1.4Mi** |
| GC cycles per minute | ~1.6 (as at 32Mi) | **4,778** / 128 |
| flights CPU per pod | ~4.5m | **76m** / 1.7m (limit 250m; throttling negligible) |
| flights mean latency | 0.70ms | **1.47ms** |
| Gateway p99 | 5ms → 5s once crash-looping | **14.7ms** |
| Gateway 5xx | 1,109 × 502 + 9,725 × 504 | **0** |

The asymmetry between the two pods (4,778 vs 128 GC/min) follows their share
of traffic: the gateway's keep-alive connections spread unevenly across
replicas (game day 02). That's inferred, not measured here.

**What it shows:** without the limit, the GC paces on `GOGC=100` alone and
lets the heap grow to ~2× live plus overhead, which at 6Mi is fatal. With
`GOMEMLIMIT` the GC collects as often as needed to stay under the limit:
here up to ~80 times a second, for a few percent of a core. At this tight a
limit that's a soft degradation instead of a crash loop. At a sane limit
(128Mi) `GOMEMLIMIT` costs nothing until memory actually approaches it.

📸 **Screenshot:** *Flightdeck — Platform*, "Pod restarts (per 15m)" bars 18:10–18:26.

📸 **Screenshot:** Grafana Explore, Prometheus:
`container_memory_working_set_bytes{namespace="flightdeck", container="flights"}` with
`kube_pod_container_resource_limits{namespace="flightdeck", container="flights", resource="memory"}`
overlaid, 17:45–18:30 — the limit stepping down 128 → 32 → 8 → 6Mi while usage stays at ~7–8Mi.

📸 **Screenshot:** `kubectl -n flightdeck describe pod <flights pod>` showing `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`.

📸 **Screenshot:** Alertmanager with `FlightdeckPodCrashLooping` active.

## Queries used

```promql
# Is Go aware of the limit? 9.22e18 = math.MaxInt64 = no.
go_gc_gomemlimit_bytes{namespace="flightdeck", job="flightdeck-flights"}

# Usage vs limit
container_memory_working_set_bytes{namespace="flightdeck", container="flights"}
kube_pod_container_resource_limits{namespace="flightdeck", container="flights", resource="memory"}
go_memstats_heap_inuse_bytes{namespace="flightdeck", job="flightdeck-flights"}

# Restart history (back-off gaps are the steps in this series)
kube_pod_container_status_restarts_total{namespace="flightdeck", container="flights"}

# What the gateway returned while flights flapped
sum by (status) (rate(http_requests_total{namespace="flightdeck", service="gateway", route!~"/healthz|/readyz|/metrics", status=~"5.."}[1m]))
```

```logql
# The gateway's view of the failures, grouped by error text
{namespace="flightdeck", service="gateway"} |= "flights service unreachable"
# → 1,422+ "context deadline exceeded (Client.Timeout exceeded while awaiting headers)"; 174 "connect: connection refused"
```

## Root cause

The memory limit was set below the working set that an **unaware** Go GC
lets flights reach (~7–8Mi: runtime, binary, pgx pool, and a 3–4Mi heap paced
by `GOGC=100` alone). The kernel killed the container (SIGKILL, exit 137) each
time usage reached the limit, typically within a minute of starting. With
`GOMEMLIMIT` the same process fits in ~4–5Mi (Step C), so at 6–8Mi the missing
`GOMEMLIMIT` was the cause, and the tight limit the trigger.

## Remediation

Revert the limit (committed values, 64Mi / 128Mi) and deploy. Also shipped:
the chart now sets **`GOMEMLIMIT` to 90% of each container's memory limit**
(`goMemLimit.percent`), so the Go GC targets the cgroup limit instead of
pacing on `GOGC` alone. Verified in the runtime after deploy:
`go_gc_gomemlimit_bytes` = 120795955 for a 128Mi limit.

## What didn't go as expected

1. **The obvious fault didn't happen.** 32Mi was 4× flights' usage and
   survived both normal load and a 7.5× spike. flights' memory doesn't scale
   with traffic: each request is a ~1ms read allocating a few KB, so few are
   in flight at once. The hypothesis that the GC, unaware of the limit, grows
   the heap past it needs a workload whose heap actually grows (a cache,
   large responses, a batch) — this one doesn't.
2. **My expectation for Step C was wrong.** Before running it I wrote that
   `GOMEMLIMIT` would help at 8Mi but "can't help at 6Mi (below the runtime's
   own floor)". It did help at 6Mi: 12 restarts → 0. I had read the observed
   ~8Mi working set as a fixed floor; it was mostly heap the unaware GC
   allowed. Told the limit, the GC held the heap at 1.4Mi and the process at
   4–5Mi. The lesson for sizing: a Go service's *observed* memory without
   `GOMEMLIMIT` tells you what the GC chose, not what it needs.
3. **The gateway hung instead of failing fast** (P6 wrong). During the crash
   loop, 90% of the gateway's errors were 5s timeouts, `awaiting headers`:
   the TCP connection to a flights pod succeeded, but no response came. Most
   likely the pods were briefly Ready between kills while stalled at the
   memory limit (the kernel reclaiming pages), which fits the 206ms
   requests seen just before the first kill. That's inferred, not measured.
4. **The 30s scrape interval can't see the peak that kills.** Recorded peaks
   were 5.6Mi and 5.1Mi against a 6Mi limit: the moment of death falls
   between scrapes. `container_oom_events_total` returned nothing here, and
   the kubelet emitted no `OOMKilling` event — the evidence is only in the
   container status (`lastState.terminated.reason`) and kube-state-metrics.
5. **The SLO page lost to the cause alert again.** With 84% errors from 18:13,
   the 1h burn only reached 14.4× at ~18:24 (the window held ~25 minutes of
   clean traffic) and the page fired at ~18:27, after the fix. The
   crash-loop alert, pointing at the right component, fired at 18:23:28.
6. **GOMAXPROCS = 2 proves nothing.** The node has 2 vCPUs, so a runtime that
   honours the 250m CPU limit and one that doesn't would both pick 2.

## What I'd change

- **`GOMEMLIMIT` from the limit, always** — done in the chart (90%).
- **Size from measurement:** flights needs ~8Mi; 64Mi request / 128Mi limit
  is generous. A VPA in recommendation mode would track this.
- **Alert on memory approaching the limit, not only on the kill:**
  `container_memory_working_set_bytes / kube_pod_container_resource_limits{resource="memory"} > 0.9 for 5m`.
- **Gateway: fail fast when flights is flapping** — a shorter
  `ResponseHeaderTimeout` (e.g. 1s for a ~1ms read) and a circuit breaker
  (see game day 04).
- **Faster SLO page for total outages** — a 30×/30m + 5m tier.
- **Watch the GC, not only memory,** once `GOMEMLIMIT` is in place: a service
  pinned at its limit doesn't die any more, it burns CPU collecting.
  `rate(go_gc_duration_seconds_count[5m])` far above baseline, or
  `go_gc_gomemlimit_bytes - go_memstats_heap_inuse_bytes` near zero, is the new
  early warning that the limit is too low.
