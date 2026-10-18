# FlightdeckPodCrashLooping

**Severity:** warning · **Scope:** namespaces `flightdeck` and `monitoring` ·
**Rule:** [`observability/rules/slo.yaml`](../../observability/rules/slo.yaml)

## Symptom

A container has been in `CrashLoopBackOff` for at least 10 minutes: it starts,
exits, and Kubernetes waits longer before each retry. The alert labels name
the namespace, pod and container.

## Likely causes

- **OOMKilled**: the container exceeded its memory limit (seen here before
  with Grafana and its sidecars at too-small limits).
- A dependency is unreachable at startup and the process exits instead of
  retrying (bad config, missing Secret key).
- A bad image, or a bad config or env var after an upgrade.
- A liveness probe failing repeatedly (`/healthz`), so the kubelet restarts it.

## First three diagnostic commands

```bash
kubectl -n <namespace> describe pod <pod>
```
```bash
kubectl -n <namespace> logs <pod> -c <container> --previous --tail=50
```
```bash
kubectl -n <namespace> get pod <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}{" "}{.lastState.terminated.reason}{" exit="}{.lastState.terminated.exitCode}{"\n"}{end}'
```

`describe` shows recent events and the last termination reason; `--previous`
shows the logs of the run that crashed.

## Remediation

- `OOMKilled` (exit 137): raise the memory limit in the chart or values file
  (size requests to observed usage, limits with ~2x headroom), then redeploy.
- Config or Secret error: fix the values or Secret and redeploy; the pod
  restarts on its own once it can start.
- Bad release: `helm rollback <release> -n <namespace>`.
