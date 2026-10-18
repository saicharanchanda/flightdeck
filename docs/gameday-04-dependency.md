# Game day 04 — Dependency failure: Postgres to zero

**Date:** 2026-10-18 · **Cluster:** eks-practice (us-east-1) ·
**Fault:** `kubectl scale statefulset flightdeck-postgresql --replicas=0` for 13 minutes ·
**Load:** k6 `loadtest/k6/baseline.js`, 20 iterations/s from inside the cluster

## Outcome in one paragraph

The readiness probe was **honest** — flights' `/readyz` pings Postgres, and
both pods went NotReady within 49 seconds. That honesty didn't help the
client. Because Postgres is shared, **every flights replica went NotReady at
once**: flights' own accurate answer ("flight data unavailable", 503) was
replaced by the gateway's generic one, and for 12 minutes **100% of API
requests failed, almost all by hanging for the gateway's full 5-second
timeout**. Inside flights, requests queued for a pool connection that would
never come (goroutines 11 → 138). The gateway piled up 432 goroutines. Four
alerts fired or went pending; **every one pointed at the gateway or at
flights, none at Postgres**. Recovery was automatic and quick: 30.5s from
scale-up to 200s, no restarts, data intact.

## Prediction vs outcome

Prediction written 18:16:02Z, before touching Postgres, from reading the code:
flights `/readyz` = `pool.Ping` (2s timeout), readiness every 5s ×
`failureThreshold` 3; liveness `/healthz` has no DB check; the gateway's
`/readyz` checks Redis only; gateway upstream timeout 5s; pgx pool
`MaxConns` 5, no `connect_timeout`.

| # | Prediction | Outcome | Verdict |
|---|---|---|---|
| P1 | The probe is **honest**: NotReady ~10–15s after Postgres goes. Liveness stays green, nothing restarts. | Both pods `ready=false`, **0 ready endpoints**, by 18:35:37 — ≤ 49s after the pod was deleted (sampling resolution ~37s). `/readyz` 503 at exactly 0.4/s (2 pods × 1/5s). **0 restarts** across the outage. | ✅ |
| P2 | Honesty cascades: both replicas NotReady together; flights' accurate 503 becomes the gateway's generic 502. | ✅ the cascade. ❌ the code: the gateway mostly returned **504**, not 502 (see P3). | ⚠️ |
| P3 | **Fast failures, not hangs**: kube-proxy rejects connections to a Service with no endpoints; the 5s timeout isn't reached. | **Hangs.** 504 at **18.3/s** vs 502 at 1.7/s; gateway mean latency **4,650ms**. A *new* connection to the flights ClusterIP is refused in **1.5ms** (iptables mode) — so the 5s waits happen on something else. | ❌ |
| P4 | **No pool exhaustion**; pgx errors read `failed to connect … connection refused`, plus `57P01` for open connections. | Errors as predicted, but **pool waiting did occur**: flights handlers ran **4,999ms** and ended in `context canceled` when the gateway gave up; flights goroutines 11 → **92 / 138**. | ⚠️ |
| P5 | No flight-board UI exists; clients get immediate errors, not a spinner. | There is no UI. API clients didn't get immediate errors — they **waited 5s per request**, so a UI would have spun for 5s and then failed. | ❌ |
| P6 | Subscribe fails too; notifier unaffected. | 202s → 0 (the gateway looks the flight up before queueing). Notifier fine, 0 restarts. | ✅ |
| P7 | Only symptom alerts; **nothing names Postgres**. | `GatewayAvailabilityFastBurn` fired; `KubePodNotReady`, `KubeDeploymentReplicasMismatch`, `KubePdbNotEnoughHealthyPods` pending — all about flights. Afterwards `GatewayLatencySlowBurn` too. No Postgres alert exists. | ✅ |
| P8 | Recovery ~1 min after scale-up, no restarts, pgx reconnects on demand. | **30.5s** to 200s; no restarts; flights Ready 4.4s after Postgres (inside one probe period). | ✅ (faster) |

## Timeline (UTC)

| Time | Event |
|---|---|
| 18:16:02 | Prediction written |
| 18:25:47–18:31:51 | Game day 03 restored; waited for its fast-burn alert to clear |
| 18:29:15 | k6 20 iterations/s for 45m |
| 18:32–18:34 | **Baseline:** Postgres 1/1, flights 2/2 Ready, 2 endpoints, gateway 20 req/s all 200/202, mean 1.9–2.4ms. Pre-existing: `GatewayAvailabilitySlowBurn` pending (game day 03's 6h window) |
| **18:34:14.964** | **Inject:** `kubectl scale statefulset flightdeck-postgresql --replicas=0` |
| 18:34:48.903 | `flightdeck-postgresql-0` deleted (34s graceful Postgres shutdown) |
| 18:35:06 | flights still **Ready**, gateway mean **340ms**, 200s down to 11.9/s — requests reaching flights now wait on the pool |
| 18:35:10 | flights goroutines 11 → **92 / 138**: handlers queued for a DB connection |
| 18:35:37 | Both flights pods **NotReady**, **0 endpoints**; gateway **504 10.7/s**, mean 3.0s |
| 18:36:08 | Steady state of the outage: **504 18.3/s, 502 1.7/s**, mean **4.65s**; subscribes 0 |
| 18:36:30 | flights goroutines back to 11–12: traffic no longer reaches it |
| 18:36:46 | `GatewayAvailabilityFastBurn` pending; `KubePodNotReady`, `KubeDeploymentReplicasMismatch`, `KubePdbNotEnoughHealthyPods` pending |
| 18:38:39 | `GatewayAvailabilityFastBurn` **firing** (~4.4 min after injection) |
| ~18:44 | Gateway goroutines peak **336 / 432** (baseline 20 / 23) |
| **18:47:33.347** | **Recover:** `--replicas=1` |
| +9.5s (18:47:42) | Postgres pod Running |
| +20.4s (18:47:53) | Postgres Ready |
| +24.8s (18:47:57) | **flights 2/2 endpoints Ready** — pgx reconnected, no restart |
| **+30.5s (18:48:03)** | **Gateway serving 200s** |
| 18:49:26 | 20 req/s, mean **1.2ms**; `/readyz` 503 at 0; gateway goroutines 54 / 67 and draining. `GatewayLatencySlowBurn` pending — the 5s hangs spent the latency budget too |
| 18:50 | Public API returns all **40** flights: data intact (PVC retained) |

Error ratio of gateway API requests 18:35–18:47: **100%**.

📸 **Screenshot:** *Flightdeck — RED*, 18:30–18:52: error rate by service (gateway at 100%), latency panel (gateway p99 pinned at 5s while flights has no data).

📸 **Screenshot:** Grafana Explore, Prometheus, `go_goroutines{namespace="flightdeck"}` 18:30–18:52 — the flights spike at 18:35 then the gateway pile-up.

📸 **Screenshot:** `kubectl -n flightdeck get endpointslices -l kubernetes.io/service-name=flightdeck-flights` during the outage (both `ready=false`).

📸 **Screenshot:** Alertmanager / Prometheus alerts page at ~18:40: every alert names gateway or flights.

## Diagnosis — the queries

```promql
# Is flights able to serve? Readiness, as Kubernetes sees it
kube_pod_container_status_ready{namespace="flightdeck", container="flights"}
# Its own view: /readyz failures (0.4/s = every probe of both pods)
sum(rate(http_requests_total{namespace="flightdeck", service="flights", route="/readyz", status="503"}[1m]))

# What clients get
sum by (status) (rate(http_requests_total{namespace="flightdeck", service="gateway", route!~"/healthz|/readyz|/metrics"}[1m]))
1000 * sum(rate(http_request_duration_seconds_sum{namespace="flightdeck", service="gateway", route!~"/healthz|/readyz|/metrics"}[1m]))
     / sum(rate(http_request_duration_seconds_count{namespace="flightdeck", service="gateway", route!~"/healthz|/readyz|/metrics"}[1m]))

# Where requests are stuck
go_goroutines{namespace="flightdeck", job=~"flightdeck-(gateway|flights)"}
```

```logql
# The gateway's errors, grouped (2,740 timeouts vs 260 refusals)
{namespace="flightdeck", service="gateway"} |= "flights service unreachable"

# flights' errors: the actual cause is in here, but rare
{namespace="flightdeck", service="flights", level="error"} |= "postgres"
```

The pgx messages, verbatim (counts over the outage):

```text
254  context canceled
 20  failed to connect to `user=flightdeck database=flightdeck`: <ip>:5432 (flightdeck-postgresql): dial error: dial tcp <ip>:5432: connect: connection refused
  1  FATAL: terminating connection due to unexpected postmaster exit (SQLSTATE 57P01)
  1  unexpected EOF
```

The precise cause (`connection refused` to `flightdeck-postgresql`) appears
**20 times**; `context canceled` — which says nothing about Postgres — appears
254 times. Someone reading the newest error lines sees the uninformative one.

## Root cause

Postgres was scaled to zero (deliberately). Everything after that is the
system's response to a missing hard dependency:

1. flights had no database timeout, so each request waited in the pgx pool until **the caller** cancelled it (5s).
2. The honest readiness probe pulled both flights replicas out of the Service at the same time, because the failure was shared.
3. The gateway, with no circuit breaker and a 5s upstream timeout, held every client request for up to 5s and answered 504.

## Remediation

`kubectl scale statefulset flightdeck-postgresql --replicas=1`. Nothing else:
pgx re-established connections on demand, flights became Ready one probe
period after Postgres, and no pod needed a restart.

## What didn't go as expected

1. **Clients hung instead of failing fast** (P3, P5 wrong). In the first ~40s
   the hang is explained: requests reached flights and waited in the pool
   (goroutine spike, 4,999ms handler durations ending in `context canceled`).
   **After** flights went NotReady, the hang is **not fully explained**: a new
   connection to the flights ClusterIP is refused in 1.5ms, flights' goroutines
   are back to baseline (so requests aren't reaching its handlers), yet the
   gateway kept timing out at 5s on ~18 req/s with "awaiting headers". Go uses
   that text for a timeout anywhere in the round trip, including while
   dialling or waiting for a pooled connection. My leading hypothesis is
   connection reuse in the gateway's `http.Transport` (established
   connections to now-unready pods, kept by conntrack), but flights' low
   goroutine count argues against requests arriving there. **Open question.**
   To settle it: `net/http/httptrace` in the gateway logging `GotConn`
   (reused?) and `WroteRequest` timings, and `conntrack -L` plus `tcpdump` on the
   node during a repeat.
2. **Readiness honesty removed the useful error.** While Ready, flights
   answers `503 {"error":"flight data unavailable"}` in milliseconds (once it
   has a DB timeout). Once all replicas are NotReady the gateway can only
   say "flights unreachable". The probe was correct about each pod and wrong
   for the service.
3. **Pool waiting looked like a flights problem, not a Postgres one.** The
   symptom (goroutines ×12, 5s handlers) points at flights' code; the cause is
   one hop further.
4. **No alert could have named Postgres.** A deliberate scale to 0 makes
   desired = ready = 0, so `KubeStatefulSetReplicasMismatch` stays quiet;
   there's no postgres_exporter; and the kubelet's probe event says
   `HTTP probe failed with statuscode: 503` without the body, which *does*
   contain `{"failed":{"postgres":"…"}}`.

## What I'd change

### Readiness probe semantics

- **Readiness = "this pod can do useful work that another pod couldn't."**
  For a dependency every replica shares, failing readiness on all of them at
  once just empties the Service. Keep flights **Ready** while Postgres is
  down, and have it **fail fast with a clear 503** (`{"error":"database unavailable","dependency":"postgres"}`, `Retry-After`).
- Keep dependency checks in readiness only for **startup** (don't take traffic
  before the pool has connected once), or gate them behind hysteresis (fail
  only after N seconds), and never in liveness — as now.
- Export each check as a metric: `readiness_check_ok{check="postgres"}` (0/1),
  so the dependency's state is queryable even when the probe body isn't.

### Timeouts — a budget, not a default

| Layer | Today | Change to |
|---|---|---|
| flights → Postgres connect | none | `connect_timeout=2` in the pgx DSN |
| flights → pool acquire + query | inherits the caller's context (5s) | per-request context of **500ms** (a lookup takes ~1ms), so flights answers 503 itself in ≤ 0.5s |
| gateway → flights | `http.Client{Timeout: 5s}` | `ResponseHeaderTimeout` ~**1s**, dial timeout ~200ms; the overall budget stays below the client's |
| ALB → gateway | idle timeout 60s | fine |

With these, the same outage gives clients a **503 in ~0.5s** instead of a
504 after 5s, and no goroutine pile-up.

### Circuit breaking

- In the gateway, around calls to flights: after e.g. 50% failures over 10s,
  **open** for 5s and answer `503 {"error":"flights unavailable"}`
  immediately; half-open with a few probe requests. This would also have cut
  the 432 parked goroutines to near zero.
- Same idea for subscribes: if flights is unavailable, either reject quickly
  or **queue the subscription without the flight lookup** and validate it in
  the notifier — so a read-path outage doesn't stop writes.

### Alerts that point at the cause

- **postgres_exporter** (Bitnami `metrics.enabled: true`) and:
  ```yaml
  - alert: FlightdeckPostgresDown
    expr: pg_up{namespace="flightdeck"} == 0 or absent(pg_up{namespace="flightdeck"})
    for: 1m
    annotations:
      summary: PostgreSQL for flightdeck is down
      description: flights can't serve reads and the gateway will return 5xx. Check the flightdeck-postgresql StatefulSet (replicas, PVC, node in us-east-1d).
  ```
- **Catch the scale-to-zero case** that `ReplicasMismatch` can't:
  `kube_statefulset_replicas{namespace="flightdeck", statefulset="flightdeck-postgresql"} < 1`.
- **flights should say why it's not ready:** alert on
  `readiness_check_ok{check="postgres"} == 0` with the text "flights is NotReady
  because its Postgres check fails", and **inhibit** `KubePodNotReady` for
  flights while it fires.
- **Pool metrics** from `pgxpool.Stat()` (`acquire_count`, `empty_acquire_count`,
  `canceled_acquire_count`, acquire duration) — `canceled_acquire_count` rising
  is the exact signature of this incident.
- The availability page should carry a **"likely cause"** line built from
  those: `{{ with query "pg_up{namespace=\"flightdeck\"} == 0" }}PostgreSQL is down{{ end }}`.
