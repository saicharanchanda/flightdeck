# GatewayLatencyFastBurn

**Severity:** page · **SLO:** 95% of gateway requests complete under 300ms
(7 days; measured at the 250ms histogram bucket) ·
**Rule:** [`observability/rules/slo.yaml`](../../observability/rules/slo.yaml)

## Symptom

Over both the last hour and the last 5 minutes, more than 72% of gateway API
requests (14.4 × the 5% budget) took longer than 250ms. Users are seeing a
slow API now.

## Likely causes

- flights is slow: slow Postgres queries, or CPU throttling at its 250m limit.
- Gateway CPU throttling under load; the HPA (2–5 replicas at 70% CPU) hasn't
  caught up or is already at its maximum.
- Injected latency from a chaos experiment (`/chaos/latency?ms=`).
- Node pressure: noisy neighbours on a node.

## First three diagnostic commands

```bash
kubectl -n flightdeck get hpa flightdeck-gateway
```
```bash
kubectl -n flightdeck top pods
```
```bash
kubectl -n flightdeck logs deploy/flightdeck-gateway --since=10m | grep -o '"route":"[^"]*".*"duration_ms":[0-9.]*' | sort -t: -k4 -rn | head
```

In Grafana: **Flightdeck — RED** latency panel; compare the gateway p95 with
flights p95. If both are high, the cause is in flights or Postgres.

## Remediation

- Chaos latency on: `curl <service>/chaos/reset`.
- Throttling: raise the CPU limit or `services.gateway.autoscaling.maxReplicas`
  and redeploy (check the node budget in the README first).
- Postgres: check slow queries and connections in `flightdeck-postgresql-0` logs.
