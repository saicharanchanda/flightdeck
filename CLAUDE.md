# flightdeck

Kubernetes observability demo on EKS. Flight-operations themed.
Portfolio project — the repo is the deliverable, the cluster is temporary.

## Hard constraints

- Cluster: EKS `eks-practice`, us-east-1, Kubernetes v1.36
- Nodes: 2 x m7i-flex.large (2 vCPU, 8 GB each). Max 3 via ASG.
- Total budget: ~12 GB usable RAM across the cluster. Set requests/limits
  on EVERY container. Keep the whole app under 2 GB of requests.
- VPC CNI: pods take real VPC IPs. ~29 pods per node ceiling.
- Account closes 2026-10-22. Images go to GHCR, NOT ECR — ECR dies with it.

## Stack

- Services: Go 1.23+, chi router, prometheus/client_golang, log/slog JSON
- Data: PostgreSQL + Redis (Bitnami charts, single replica, small PVCs)
- Platform: AWS Load Balancer Controller, kube-prometheus-stack, Loki + Alloy
- Packaging: one Helm chart I own at `charts/flightdeck`;
  upstream charts get a committed values.yaml under `platform/`

## Services

- `gateway`   — public HTTP API, fronts the others, emits RED metrics
- `flights`   — flight status, reads Postgres
- `notifier`  — worker, consumes a Redis list, no HTTP ingress

## Rules

- Every service exposes `/healthz`, `/readyz`, `/metrics`
- Every service has chaos endpoints: `/chaos/latency?ms=`, `/chaos/errors?rate=`
  guarded by a CHAOS_ENABLED env var
- Metric names follow Prometheus conventions: `_total`, `_seconds`, base units
- NEVER commit: kubeconfig, AWS keys, .env with real values, *.pem
- Secrets in k8s come from a Secret, never a ConfigMap, never hardcoded
- Always `helm template` and `kubeconform` before `helm install`
- No `latest` image tags. Tag with the git short SHA.

## Conventions

- Namespaces: `flightdeck` (app), `monitoring` (observability)
- Everything deployable via `make` targets; document each in the README
