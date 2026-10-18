# NotifierQueueBacklog

**Severity:** warning · **Metric:** `notification_queue_depth` (LLEN of the
Redis list `notifications`, sampled every 5s by the notifier) ·
**Rule:** [`observability/rules/slo.yaml`](../../observability/rules/slo.yaml)

## Symptom

More than 100 subscription jobs have been waiting for 5 minutes.
Subscriptions are still accepted (the gateway returns 202), but notifications
go out late.

## Likely causes

- The notifier is down or crash-looping, so nothing consumes the list.
- Throughput ceiling: one notifier replica processes about 2–5 jobs/s
  (200–500ms simulated delivery each, one at a time); a subscribe burst outruns it.
- Injected latency on the notifier (`/chaos/latency?ms=`) slowing every delivery.
- Redis trouble: BLPOP erroring (look for "blpop failed" in the notifier logs).

## First three diagnostic commands

```bash
kubectl -n flightdeck get pods -l app.kubernetes.io/name=notifier
```
```bash
kubectl -n flightdeck logs deploy/flightdeck-notifier --since=10m | tail -20
```
```bash
kubectl -n flightdeck port-forward svc/flightdeck-notifier 8082:8082
```

Then `curl localhost:8082/metrics | grep notification` gives the queue depth
and `notifications_processed_total{result=...}`. If `delivered` isn't
increasing, the worker is stuck.

## Remediation

- Notifier down: fix it (see the pod-crashlooping runbook); the backlog
  drains on its own once it's back.
- Throughput: scale the worker, e.g.
  `--set services.notifier.replicas=3` (BLPOP lets replicas share the list
  safely).
- Chaos on: `curl localhost:8082/chaos/reset`.
