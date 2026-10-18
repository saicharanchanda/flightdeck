# GatewayAvailabilityFastBurn

**Severity:** page · **SLO:** 99% of gateway requests succeed (7 days) ·
**Rule:** [`observability/rules/slo.yaml`](../../observability/rules/slo.yaml)

## Symptom

More than 14.4% of gateway API requests (probes excluded) returned 5xx over
both the last hour and the last 5 minutes. At this rate the week's error
budget is gone in about 12 hours. Users are seeing failures now.

## Likely causes

- flights is failing or unreachable: the gateway proxies its 5xx (500) or
  reports it as 502/504 when it can't connect or times out.
- Postgres is down or rejecting connections (flights returns 503).
- Redis is down: subscriptions return 503.
- A bad deploy (new image tag) or a chaos experiment left switched on.

## First three diagnostic commands

```bash
kubectl -n flightdeck get pods -o wide
```
```bash
kubectl -n flightdeck logs deploy/flightdeck-gateway --since=15m | grep '"level":"ERROR"' | tail -20
```
```bash
helm history flightdeck -n flightdeck --max 3
```

In Grafana: **Flightdeck — RED** (error rate by service), then Explore → Loki:
`{namespace="flightdeck", service="gateway", level="error"}`. Follow a
`request_id` link to see which downstream call failed.

## Remediation

- A deploy in the last hour: `helm rollback flightdeck <previous> -n flightdeck`.
- Chaos left on: `curl <service>/chaos/reset`, then redeploy with `config.chaosEnabled=false`.
- flights or Postgres down: see their pod events (`kubectl -n flightdeck describe pod …`) and fix the dependency first; the gateway recovers on its own.
- The alert clears within minutes of the fix: the 5m window must stop burning.
