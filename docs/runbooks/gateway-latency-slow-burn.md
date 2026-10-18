# GatewayLatencySlowBurn

**Severity:** ticket · **SLO:** 95% of gateway requests complete under 300ms
(7 days; measured at the 250ms histogram bucket) ·
**Rule:** [`observability/rules/slo.yaml`](../../observability/rules/slo.yaml)

## Symptom

Over both the last 6 hours and the last 30 minutes, more than 30% of gateway
API requests (6 × the 5% budget) took longer than 250ms. The API is
noticeably slower than it should be; the week's budget lasts about 28 hours
at this rate.

## Likely causes

- Steady growth in traffic with no headroom: the HPA sits at max replicas.
- The flights table or query plan degraded (seed reloads, missing index).
- A slow route: e.g. subscribe does a flights lookup plus a Redis push.
- Sustained CPU throttling from limits sized for idle load.

## First three diagnostic commands

```bash
kubectl -n flightdeck get hpa flightdeck-gateway
```
```bash
kubectl -n flightdeck top pods
```
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Then, in Prometheus:
`histogram_quantile(0.95, sum by (route, le) (rate(http_request_duration_seconds_bucket{service="gateway"}[30m])))`
to find the slow route.

## Remediation

- Scale: raise HPA `maxReplicas` or the per-pod CPU limit, within the node budget.
- Fix the slow route or query; add an index if the flights query is the cause.
- Re-check the SLO threshold if the workload legitimately changed.
