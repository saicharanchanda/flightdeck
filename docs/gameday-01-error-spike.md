# Game day 01 — Error spike

**Date:** 2026-10-18 · **Cluster:** eks-practice (us-east-1) ·
**Fault:** gateway `/chaos/errors?rate=0.3` on every gateway pod ·
**Load:** k6 `loadtest/k6/baseline.js`, 20 iterations/s from inside the cluster
(70% flight lookups, 20% departure boards, 10% subscribes)

## Outcome in one paragraph

The fast-burn SLO alert (`GatewayAvailabilityFastBurn`, severity page) fired
**9m26s after injection**. The PromQL and LogQL below led to the root cause in a
few minutes without prior knowledge, mostly thanks to two clues: every error
had `route="unmatched"`, and every failing request ended in ~25µs without
reaching flights. Remediation was one call per pod. The exercise also exposed a
detection-time trap and two bugs in my own alerting, written up below.

## Timeline (UTC)

| Time | Event |
|---|---|
| 15:32:15 | `helm upgrade --set config.chaosEnabled=true` (revision 8). **Restarts every app pod**; chaos can't be enabled on a live system without a deploy. |
| 15:33:20 | 5 app pods Ready; chaos reset on both gateway pods |
| 15:34:04 | k6 load starts: 20 iterations/s for 35m against `flightdeck-gateway:8080` |
| 15:34–15:39 | **Baseline:** 20 req/s, 0 errors, p99 ≈ 5ms, availability burn 0 (1h and 5m), 2 gateway replicas, no alerts |
| 15:40:07 | **Inject** `/chaos/errors?rate=0.3` (pod `…7brn9` at 15:40:18, pod `…c8cl9` at 15:40:26) |
| 15:41:39 | Error ratio 29.6% (1m); burn 5m 1.06, 1h 0.73 — windows still filling |
| 15:43:03 | `GatewayAvailabilitySlowBurn` **pending** (6h and 30m burn > 6) |
| 15:43:43 | 5m burn crosses 14.4 (15.2); 1h burn 8.2 |
| 15:47:33 | 1h burn crosses 14.4 → `GatewayAvailabilityFastBurn` **pending** |
| 15:49:33 | `GatewayAvailabilityFastBurn` **firing**; in Alertmanager as `severity=page` |
| ~15:50 | Diagnosis starts from the page |
| ~15:52 | Root cause identified: gateway chaos middleware at error_rate 0.3 |
| 15:52:37 | **Remediate:** `/chaos/reset` on both gateway pods (15:52:37, 15:52:43) |
| 15:53:54 | Error ratio 0 (1m). Burn 5m 25.3, 1h 18.7: the windows are still full of errors |
| 15:55:49 | `GatewayAvailabilityFastBurn` **resolved**, 3m12s after the fix: the 5m burn fell below 14.4 (9.1 at 15:56:20) |
| 15:58:03 | `GatewayAvailabilitySlowBurn` **fired, 5m26s after the fix**, with 0 errors flowing. Pending since 15:43:03 (`for: 15m`), and its 30m window still held ~12 min of 30% errors (burn ≈ 12–15) |
| 16:00:37 | Slow burn still firing; by arithmetic it stays until the 30m window drops below 6× (≈ 16:17) — see game day 02 for the actual resolution time |

📸 **Screenshot:** *Flightdeck — RED*, last 30 min: the burn-rate gauges and the
"Availability burn rate by window" panel showing 5m rising first and 1h lagging.

📸 **Screenshot:** Alertmanager (<http://localhost:9093>) with
`GatewayAvailabilityFastBurn` active.

## Diagnosis — as if I didn't know the cause

### PromQL

1. **Which service is failing?** (RED dashboard, *Error rate by service*)
   ```promql
   sum by (service) (rate(http_requests_total{namespace="flightdeck", route!~"/healthz|/readyz|/metrics", status=~"5.."}[5m]))
     / sum by (service) (rate(http_requests_total{namespace="flightdeck", route!~"/healthz|/readyz|/metrics"}[5m]))
   ```
   → `gateway = 0.30`. flights and notifier: no 5xx. **Not a downstream failure.**

2. **Which routes and codes?**
   ```promql
   sum by (route, status) (rate(http_requests_total{namespace="flightdeck", service="gateway", status=~"5.."}[5m]))
   ```
   → only `route="unmatched", status="500"` (6 req/s). A real handler error
   would carry its route (`/api/flights/{id}`). "unmatched" means the request
   was rejected **before chi routed it**: middleware.

3. **One pod or all?**
   ```promql
   sum by (pod) (rate(http_requests_total{namespace="flightdeck", service="gateway", status=~"5.."}[5m]))
     / sum by (pod) (rate(http_requests_total{namespace="flightdeck", service="gateway"}[5m]))
   ```
   → 0.27 and 0.28. **Both replicas equally**: config or code, not a sick pod.

4. **Latency involved?**
   ```promql
   histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="flightdeck", service="gateway", route!~"/healthz|/readyz|/metrics"}[5m])))
   ```
   → 5ms, unchanged. Not timeouts, not overload.

📸 **Screenshot:** Prometheus graph of query 2 (one series: `unmatched` / `500`).

### LogQL (Grafana → Explore → Loki)

5. **The failing requests:**
   ```logql
   {namespace="flightdeck", service="gateway", level="error"}
   ```
   ```json
   {"level":"ERROR","msg":"request","service":"gateway","method":"GET","route":"unmatched","path":"/api/flights/10","status":500,"duration_ms":0.025,"request_id":"75c90381ef0ab0abcb988f72567472d9"}
   ```
   `duration_ms` 0.023–0.025: about **200× faster than a normal request**
   (~5ms). These requests do no work at all.

6. **Spread across paths?**
   ```logql
   sum by (path, status) (count_over_time({namespace="flightdeck", service="gateway", level="error"} | json [10m]))
   ```
   → every path, lookups and subscribes alike, in proportion to traffic. Not a
   bad route or a bad record.

7. **Anyone else erroring?**
   ```logql
   sum by (service) (count_over_time({namespace="flightdeck", level="error"}[10m]))
   ```
   → `gateway: 3557`. Nothing from flights or notifier.

8. **Follow one request** (the derived-field link in Grafana does this in one click):
   ```logql
   {namespace="flightdeck"} | json | request_id="75c90381ef0ab0abcb988f72567472d9"
   ```
   → **1 line, gateway only.** For contrast, a successful lookup
   (`f6125e55…`) has 2 lines: gateway **and** flights. The failing request never
   left the gateway.

9. **What changed?** Warnings around the start of the errors:
   ```logql
   {namespace="flightdeck", service="gateway", level="warn"}
   ```
   ```json
   {"time":"2026-10-18T15:40:18.81Z","level":"WARN","msg":"chaos error rate set","service":"gateway","error_rate":0.3}
   {"time":"2026-10-18T15:40:26.58Z","level":"WARN","msg":"chaos error rate set","service":"gateway","error_rate":0.3}
   ```
   One per pod, exactly when the errors began. That's the cause.

📸 **Screenshot:** Loki Explore with query 5, showing `route":"unmatched"` and `duration_ms` ~0.02.

📸 **Screenshot:** Loki Explore with query 9, showing the two `chaos error rate set` lines.

## Root cause

The gateway's chaos middleware was set to fail 30% of requests on both
replicas. It runs before routing, so the failures carried no route and never
reached a handler or flights.

In a real incident, the analogue is any middleware that rejects requests
before routing: auth, rate limiting, a bad body-size limit.

## Remediation

`loadtest/chaos.sh gateway /chaos/reset` (calls every gateway pod). Error rate
dropped to 0 within one scrape. The **page resolved 3m12s later**; the **ticket
fired 5m26s after the fix** and stayed firing for roughly 25 more minutes.

📸 **Screenshot:** *Flightdeck — RED* "Availability burn rate by window" after
the fix: 5m drops to 0 within 5 minutes while 30m, 1h and 6h decay slowly.

## What didn't go as expected

1. **Detection was 9.5 minutes, and in production it would be ~29.** The fast-burn
   rule needs the **1h** burn above 14.4 as well as the 5m one. The 1h window
   only held about 6 minutes of clean traffic (load started at 15:34), so the
   30% error rate dominated it quickly. With a full hour of steady clean
   traffic, the 1h error ratio after *t* minutes is 0.3·t/60, which crosses
   0.144 only at **t ≈ 29 min**. That's the multiwindow design trading
   detection speed for precision; the workbook's answer is that a 30× burn
   should also trip a shorter page window. I'd add a 3rd tier (e.g. 30× over
   30m and 5m) if a ~30-minute page is unacceptable.
2. **My alert description was wrong.** It said "17.67x burn over 5m". In
   `A and B` the value comes from **A**, the 1h window; the 5m burn was ~30× at
   that moment. It also claimed "gone in about 12 hours", which is only true at
   exactly 14.4×; at the real ~30× the budget lasts ~5.6h. **Fixed in
   `observability/rules/slo.yaml`:** the descriptions now name the long window and
   compute time-to-exhaustion with a template query (`604800 / burnrate`).
3. **Chaos errors lose their route.** Useful as a diagnostic clue here, but a
   real middleware failure would be just as anonymous in the RED-by-route view.
   Keeping `path` in the logs saved the diagnosis.
4. **p99 had no resolution at baseline.** It read 4.95–4.97ms in every sample:
   nearly all requests fall in the first histogram bucket (≤5ms), so the
   quantile is interpolation inside one bucket. Fine for SLOs at 250ms, useless
   for spotting a 1ms → 3ms regression.
5. **Enabling chaos is itself a deploy** (it restarts every app pod), so a
   chaos experiment can't start on an untouched system. Chaos stays enabled
   for the next game days.
6. **The ticket fired after the incident was over.** Predicted, then observed:
   `GatewayAvailabilitySlowBurn` had been pending since 15:43 with `for: 15m`,
   so it fired at 15:58 although errors had stopped at 15:52. Its *short*
   window is 30m, which still contained ~12 minutes of 30% errors. The page
   reset in 3 minutes because its short window is 5m; the ticket can't reset
   faster than ~30 minutes. Acceptable for a ticket (the budget really was
   spent), but on-call should expect a ticket to arrive *after* the page clears.
7. **My own sampler missed the alert.** Its regex for the alerts API assumed no
   nested objects; the `annotations` object broke it, so it logged
   `alerts=[]` while the alert was pending and firing. I read the alert
   states directly from Prometheus and Alertmanager instead.

## What I'd change to prevent it

- **Faster paging for severe burns:** add a 30×/30m+5m tier so a 30% error
  rate pages in minutes, not half an hour.
- **Log the rejection reason in middleware:** any middleware that writes a 5xx
  should log *why* (`reason="chaos"`, `reason="rate_limited"`), so the error
  logs say it directly instead of needing a WARN line from 10 minutes earlier.
- **Guard chaos in production:** keep `CHAOS_ENABLED=false` by default (as
  now), and expose the current chaos state as a metric (`chaos_error_rate`) so
  a forgotten experiment is visible on the dashboard.
- **Alert-text review:** check every `$value` in an `and` expression refers to
  the series the text claims.
- **Inhibit the ticket while (or right after) the page fires** for the same
  SLO (Alertmanager `inhibit_rules` on matching `slo` labels), so one incident
  produces one notification stream.
