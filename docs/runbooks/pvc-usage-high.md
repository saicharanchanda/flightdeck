# FlightdeckPVCUsageHigh

**Severity:** warning · **Scope:** PVCs in `flightdeck` and `monitoring` ·
**Rule:** [`observability/rules/slo.yaml`](../../observability/rules/slo.yaml)

## Symptom

A persistent volume has been more than 80% full for 10 minutes. When it hits
100%, the workload on it fails writes: Postgres stops accepting transactions,
Prometheus or Loki stop ingesting.

## Likely causes

- **Prometheus (10Gi)**: more series than expected (a high-cardinality label)
  filling the TSDB faster than 3d retention frees it. `retentionSize: 8GB`
  should cap it; if not, check cardinality.
- **Loki (10Gi)**: log volume spike, or the compactor isn't deleting
  (retention is enforced by the compactor).
- **Postgres / Redis (2Gi)**: table or AOF growth.
- **Grafana (5Gi)**: rarely; plugin or image-render caches.

## First three diagnostic commands

```bash
kubectl get pvc -A
```
```bash
kubectl -n <namespace> exec <pod> -- df -h
```
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Then, in Prometheus, for TSDB growth: `topk(10, count by (__name__) ({__name__=~".+"}))`.

## Remediation

- **Expand online.** The `gp3` StorageClass has `allowVolumeExpansion: true`:
  `kubectl -n <ns> patch pvc <pvc> -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'`.
  Then update the size in the matching values file, so the next upgrade
  doesn't conflict with the live object.
- Prometheus: lower `retention` or `retentionSize`, or drop the high-cardinality series.
- Loki: confirm `compactor.retention_enabled: true` and check the compactor logs.
