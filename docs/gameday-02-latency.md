# Game day 02 — Latency injection

**Date:** 2026-10-18 · **Cluster:** eks-practice (us-east-1) ·
**Fault:** gateway `/chaos/latency?ms=800` on every gateway pod ·
**Load:** k6 `loadtest/k6/baseline.js`, 20 iterations/s, constant arrival
rate, from inside the cluster against the `flightdeck-gateway` Service

## Outcome in one paragraph

The gateway became 320× slower (2.5ms → 800ms) for 24 minutes, and
**the HPA did nothing**: its CPU signal moved from 12% to 15% of a 70% target,
and by its own arithmetic it wanted *fewer* replicas. The latency **page never
fired** (it can't, for a total latency outage, in under ~43 minutes); the
**ticket went pending after 16½ minutes** and was set to fire after the fix.
Diagnosis was quick: mean latency per service put the delay inside the
gateway, zero CPU throttling ruled out saturation, and Loki's per-pod
`duration_ms` showed a pod-local fault. Forcing a third pod proved that chaos
state is per-pod — and exposed something I hadn't predicted: **the new pod got
no traffic at all from the in-cluster client**, because a ClusterIP Service
balances connections, not requests.

## Predictions vs what happened

| # | Prediction (made before injecting) | Outcome | Verdict |
|---|---|---|---|
| 1 | The HPA will **not** scale out: it scales on CPU, and a request sleeping 800ms burns almost no CPU. | CPU 12–13% at baseline, **13–15% during the fault** (target 70%). Replicas 2 → 2 for 24 minutes. HPA condition: `ScalingLimited / TooFewReplicas — the desired replica count is less than the minimum`, i.e. it would have scaled **in** to 1 if `minReplicas` allowed. | ✅ Held — and stronger than predicted |
| 2 | A pod added by scale-out starts **clean**: chaos state lives in each pod's memory. | Forced a 3rd pod (16:25:52). Added latency per pod, measured against a `/healthz` control: old pods **+0.790s / +0.789s**, new pod **−0.047s** (≈ 0). Loki: new pod 1.7ms average vs 801ms. | ✅ Held |
| 3 | *(not predicted)* | The new pod received **0%** of the k6 traffic for 6+ minutes; the two old pods split 11 + 9 req/s. Through the **ALB** it got **30%** (expected 33%) once registered as a target. | ❗ New finding |
| 4 | *(not predicted)* | Dashboard p50 **0.75s**, p99 **0.995s**; true latency **0.80s** (sum/count, and Loki `duration_ms` 801ms). | ❗ Histogram artifact |
| 5 | *(not predicted)* | The latency fast-burn page never fired; slow-burn ticket pending at 16:26:33, firing after the fix. | ❗ See "what didn't go as expected" |

## Timeline (UTC)

| Time | Event |
|---|---|
| 16:02:50 | GD2 start. HPA: min 2, max 5, target 70% CPU of the 50m request (limit 250m) |
| 16:03:29 | k6 load starts: 20 iterations/s for 40m |
| 16:04–16:09 | **Baseline:** 20 req/s, gateway p50 2.5ms / p99 5ms, flights p99 5ms, latency burn 0, **HPA CPU 12–13%**, 2 replicas, gateway CPU ≈ 0.010 cores total |
| 16:09:48 | **Inject** `/chaos/latency?ms=800` (pod `…7brn9` 16:09:59, pod `…c8cl9` 16:10:06) |
| 16:10:26 | k6 now holds **16 VUs in flight** (was < 1): 20 req/s × 0.8s |
| 16:11:48 | Gateway p50 0.75s / p99 0.995s; flights p99 still 5ms; latency burn 5m 3.2; **HPA CPU 15%** |
| 16:14:26 | Latency burn 5m 16.6 (above 14.4); 1h only 1.9 |
| 16:15:43 | Latency burn 5m pinned at **20.0** — the maximum possible (100% slow ÷ 5% budget) |
| 16:17–16:18 | (GD1's availability ticket resolves, ≈ 25 min after GD1's fix, as estimated) |
| 16:24:53 | 15 min into the fault: burn 5m 20, 30m 9.7, **1h 5.7**, 6h 5.7. HPA CPU 14%, replicas 2. No latency alert yet |
| 16:25:39 | **Force scale-out:** `kubectl patch hpa … minReplicas: 3` (temporary drift from Helm) |
| 16:25:52 | New pod `…xczgm` Ready — logs `chaos_enabled: true` at start, but never received a latency call |
| 16:26:33 | `GatewayLatencySlowBurn` **pending** (6h and 30m burn > 6) |
| 16:27:52 | Per-pod traffic over 1m: `…7brn9` 11 req/s, `…c8cl9` 9 req/s, **`…xczgm` none**. Latency SLI good ratio (1m) = 0 |
| 16:28:35 | Port-forward timing looked like the new pod was slow too (0.78s) — **misleading**: see below |
| 16:28:52 | ALB test: only 2/30 fast — the new pod wasn't a registered ALB target yet |
| 16:30:17–16:31:12 | Controlled measurement (api − healthz per pod): old pods +0.790s, +0.789s; **new pod −0.047s** |
| 16:31:50 | ALB test with a healthz baseline: **30%** of requests fast (served by the clean pod), expected 33% |
| ~16:32 | Diagnosis (below) |
| 16:34:03 | Before fix: latency burn 5m 19.9, 30m 15.7, **1h 7.9**, 6h 7.9. **Fast burn never fired.** Slow burn pending since 16:26:33 |
| 16:34:11–16:34:23 | **Remediate:** `/chaos/reset` on all three gateway pods |
| 16:34:26 | HPA `minReplicas` back to 2 (matches Helm values) |
| 16:34:53 | k6 back to < 1 VU in flight; the 3rd pod is gone (HPA back at 2 — its CPU math wanted fewer anyway) |
| 16:36:14 | Gateway p50 2.5ms / p99 5ms — recovered in < 2 minutes. Latency burn 5m 15.8, 30m 16.4 |
| 16:40:16 | Latency burn 5m **0**; 30m still 16.5; ticket still pending |
| 16:41:38 | `GatewayLatencySlowBurn` **fires — 7m27s after the fix**, with p99 back at 5ms. Description: "6.994x burn over 6h … the 7-day budget is gone in 1d 0h 1m" |
| 16:43:30 | k6 run ends (40m elapsed); request rate falls to 0 — the end of the test, not a new fault |
| 16:45:53 | Ticket still firing (30m burn 13.5); it clears once the 30m window drops below 6× |

📸 **Screenshot:** *Flightdeck — RED*, "Latency p50 / p95 / p99 by service", 16:00–16:40: gateway jumps to ~0.75–1.0s, flights stays flat at ~5ms.

📸 **Screenshot:** *Flightdeck — RED* "Latency burn rate · 1h" gauge (~5–8) next to the 5m burn pinned at 20.

📸 **Screenshot:** `kubectl -n flightdeck describe hpa flightdeck-gateway` during the fault — `13% (6m) / 70%` and `ScalingLimited  True  TooFewReplicas`.

📸 **Screenshot:** *Flightdeck — Platform* node CPU during the fault: flat.

## Diagnosis — as if I didn't know the cause

### PromQL

1. **Where is the time spent?** Mean latency per service. `sum/count` avoids
   histogram interpolation, see below.
   ```promql
   sum by (service) (rate(http_request_duration_seconds_sum{namespace="flightdeck", route!~"/healthz|/readyz|/metrics"}[5m]))
     / sum by (service) (rate(http_request_duration_seconds_count{namespace="flightdeck", route!~"/healthz|/readyz|/metrics"}[5m]))
   ```
   → gateway **0.796s**, flights **0.00032s**. The delay is added inside the
   gateway, not in flights or Postgres.

2. **Saturation?** CPU and throttling per gateway pod:
   ```promql
   sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="flightdeck", container="gateway"}[5m]))
   sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="flightdeck", container="gateway"}[5m]))
   ```
   → 6–7 millicores per pod (limit 250m), **0 throttled periods**. The
   gateway is not busy; it's waiting.

3. **Errors or timeouts?**
   ```promql
   sum by (service) (rate(http_requests_total{namespace="flightdeck", route!~"/healthz|/readyz|/metrics", status=~"5.."}[5m]))
   ```
   → 0. Pure latency.

4. **What the autoscaler sees:**
   ```promql
   kube_horizontalpodautoscaler_status_current_replicas{namespace="flightdeck"}
   sum(rate(container_cpu_usage_seconds_total{namespace="flightdeck", container="gateway"}[5m]))
     / sum(kube_pod_container_resource_requests{namespace="flightdeck", container="gateway", resource="cpu"})
   ```
   → ~0.13–0.15 of request; replicas flat.

### LogQL

5. **Per pod, from the access logs:**
   ```logql
   avg by (pod) (avg_over_time({namespace="flightdeck", service="gateway"} | json | route=~"/api/.*" | unwrap duration_ms [5m]))
   ```
   → `…7brn9` 801ms, `…c8cl9` 801ms, `…xczgm` **1.7ms**. A fixed ~800ms,
   per pod, absent on the pod that started later: **pod-local state**.

6. **What changed on those pods?**
   ```logql
   {namespace="flightdeck", service="gateway"} |= "chaos"
   ```
   ```json
   {"time":"2026-10-18T16:09:59.66Z","level":"WARN","msg":"chaos latency set","service":"gateway","latency_ms":800}
   {"time":"2026-10-18T16:10:07.36Z","level":"WARN","msg":"chaos latency set","service":"gateway","latency_ms":800}
   ```
   One per old pod; none for the new one.

📸 **Screenshot:** Loki Explore with query 5 as a time series (two lines at ~800, one near 0 from 16:26).

## Root cause

Chaos latency of 800ms was set in the gateway middleware on the two pods that
existed at 16:10. Every API request slept 800ms before routing. No CPU was
consumed, so nothing in the autoscaling path noticed.

## Remediation

`loadtest/chaos.sh gateway /chaos/reset` on all three pods, then `minReplicas`
back to 2. Latency returned to baseline within **two minutes**. The ticket then
fired **7m27s after the fix**.

📸 **Screenshot:** *Flightdeck — RED* p99 panel 16:30–16:45 showing the drop
back to ~5ms at 16:34, and Alertmanager showing `GatewayLatencySlowBurn` active
at 16:42 with nothing wrong.

## Why CPU-based autoscaling is blind to latency

The HPA's CPU target answers *"are the pods busy?"* An 800ms sleep in a
goroutine is **waiting**, not work: the pod holds 16 concurrent requests and
uses ~6 millicores. Slow downstreams, lock contention, connection-pool
exhaustion, slow disks and injected latency all look like this. Users see a
slow service; the autoscaler sees an idle one. In this run it actually
concluded the gateway was **over**-provisioned.

Adding replicas wouldn't have fixed *this* fault (each pod sleeps). But in the
common real case (a saturated connection pool, or a queue in front of a worker)
more replicas would help, and CPU still wouldn't ask for them.

### Signals that would work

| Signal | What it measures | How to feed the HPA |
|---|---|---|
| **In-flight requests per pod** (concurrency) | Little's law: in-flight = rate × latency. It rose from <1 to 16 here while CPU didn't move. | Export a gauge (`http_requests_in_flight`); **prometheus-adapter** exposes it as a Pods metric; HPA `type: Pods`, target e.g. 5 per pod |
| **Request rate per pod** | Throughput per replica | Same path, from `rate(http_requests_total[2m])` |
| **p95 latency** | The user-facing symptom | Possible via the adapter or **KEDA**'s Prometheus scaler, but scaling on latency alone can feed back badly (more pods don't help if the dependency is slow) — use with a cap |
| **Queue depth** (notifier) | Backlog | **KEDA** has a native Redis list scaler; `notification_queue_depth` via KEDA's Prometheus scaler also works |

What I'd do here: add an **in-flight gauge** to `svckit`'s middleware, install
**KEDA** (lighter than prometheus-adapter for one or two metrics), and scale
the gateway on in-flight requests per pod with CPU as a second metric. KEDA's
Redis scaler also fits the notifier.

## Per-pod state in a horizontally scaled service

Chaos settings live in a struct in each process, so:

- **A new pod starts with defaults.** Shown above: `…xczgm` added ~0 latency.
  The same applies to rolling updates, rescheduling after a node failure,
  and OOM restarts.
- **"Turn it on everywhere" has no single place to do it.** It took a script
  that port-forwards to every pod (`loadtest/chaos.sh`), and it's racy: a pod
  created a second after the loop is missed.
- **Different replicas can disagree.** During this run, 2 of 3 pods were
  slow; a user's experience depended on which pod they hit.

In real systems, the things that get this wrong are feature flags, rate-limit
counters, caches and circuit-breaker state. Options: keep per-pod state but
make its value come from shared config (a ConfigMap/Secret the pod reads at
start and watches); put it in a shared store (Redis); or accept it as local
and **expose it as a metric** (e.g. `chaos_latency_ms` per pod) so divergence
is visible. For chaos specifically I'd do the first: set chaos from a
ConfigMap, watched, so all current and future pods agree.

## What didn't go as expected

1. **New pods behind a Service didn't get traffic from existing clients.**
   k6 reuses its connections (HTTP keep-alive), and a ClusterIP Service
   (kube-proxy, L4) picks a backend **per connection**. The 16 open
   connections stayed pinned to the old pods, and the new pod received
   **nothing** from k6. The ALB (L7) balances **per request** and sent it
   ~30% once it was registered. So *even a correct scale-out* wouldn't help
   in-cluster clients with long-lived connections. Fixes: client-side
   connection max-age / max-requests, an L7 mesh or gRPC-aware balancing, or
   the server closing idle keep-alive connections periodically
   (`http.Server` has no max-age; it would need middleware or `SetKeepAlivesEnabled` toggling).
2. **The latency page cannot fire quickly for a total outage.** The latency
   budget is 5%, so the burn rate maxes out at **20** (100% slow). The page
   needs the 1h burn above 14.4, meaning **72% of the last hour** was slow.
   After 24 minutes of 100% slow requests the 1h burn was only 7.9; it would
   have paged at ~43 minutes. With a 95% SLO, the fast-burn factor should be
   lower, or the page should use a shorter long window (e.g. 30m), or a
   separate "everything is slow" alert (`slo:gateway_latency_good:ratio_rate5m < 0.5` for 5m).
3. **The dashboard lied about the magnitude.** p50 0.75s and p99 0.995s were
   the midpoint and upper edge of the `0.5–1.0s` bucket; the true latency was
   0.80s for everything. With buckets this coarse, use `sum/count` for "how
   slow", and quantiles only to compare against bucket boundaries. More
   buckets between 0.25 and 1s would help (and add the missing 0.3).
4. **My first per-pod measurement was wrong.** Through `kubectl port-forward`
   from India to us-east-1, *every* request costs ~0.8s of network, so the
   clean pod looked slow (0.78s). Only subtracting a `/healthz` control (which
   chaos skips) gave the real answer. Lesson: always measure a control on the
   same path.
5. **The ALB took ~3 minutes to register the new pod.** A Ready pod isn't an
   ALB target until registration plus two healthy checks (10s interval); the
   first ALB test (16:28:52) still showed only 2/30 fast. The ALB
   pod-readiness gate (`elbv2.k8s.aws/pod-readiness-gate-inject`) would keep
   the pod unready until the ALB considers it healthy, which also makes
   rollouts safer.
6. **The ticket fires after the fix, again.** Same mechanism as game day 01:
   pending since 16:26:33 with `for: 15m`, and its 30m window still full of
   slow requests at 16:41. Observed: **fired 16:41:38, 7m27s after the fix**,
   while the gateway was back to p99 5ms. In two game days the ticket was
   never useful during the incident and always arrived after it. That argues
   for inhibiting the ticket when the page for the same SLO fired recently,
   and for routing tickets to a queue rather than to a person.

## What I'd change

- **Scale on concurrency, not just CPU:** in-flight gauge in `svckit`, KEDA
  ScaledObject on in-flight per pod (CPU kept as a second trigger).
- **Fix the latency alerting:** add an "all slow" alert on the 5m SLI, and
  retune the latency fast-burn tier for a 5% budget (max burn 20).
- **Better histogram buckets:** add 0.3, 0.4, 0.75 between 0.25 and 1.0.
- **ALB pod readiness gate** on the `flightdeck` namespace.
- **Chaos from a watched ConfigMap,** plus a `chaos_*` gauge per pod.
- **Client connection lifetime** for in-cluster callers, so new replicas get
  traffic from existing clients.
