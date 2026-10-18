# GatewayAvailabilitySlowBurn

**Severity:** ticket · **SLO:** 99% of gateway requests succeed (7 days) ·
**Rule:** [`observability/rules/slo.yaml`](../../observability/rules/slo.yaml)

## Symptom

More than 6% of gateway API requests returned 5xx over both the last 6 hours
and the last 30 minutes. Not an outage, but at this rate the week's error
budget is gone in about 28 hours. Handle during working hours.

## Likely causes

- One of two replicas unhealthy (half the traffic failing intermittently).
- A specific route failing, e.g. subscribe returning 502 for some flights.
- Slow-building dependency trouble: Postgres connection pool exhaustion,
  Redis memory pressure.
- A partial chaos error rate (e.g. `rate=0.1`) left in place.

## First three diagnostic commands

```bash
kubectl -n flightdeck get pods -o wide
```
```bash
kubectl -n flightdeck logs deploy/flightdeck-gateway --since=1h | grep '"level":"ERROR"' | grep -o '"route":"[^"]*","path":"[^"]*","status":[0-9]*' | sort | uniq -c | sort -rn | head
```
```bash
kubectl -n flightdeck top pods
```

In Prometheus:
`sum by (route, status) (rate(http_requests_total{service="gateway", status=~"5.."}[30m]))`
shows which route is failing.

## Remediation

- Isolate the failing route or replica from the queries above; restart a
  single bad pod with `kubectl -n flightdeck delete pod <pod>`.
- Fix the dependency it points to (flights → Postgres, subscribe → Redis).
- If it's a code regression, roll back the release and open an issue.
