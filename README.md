# flightdeck

Kubernetes observability demo on EKS, themed around flight operations.

> Stub — full architecture, deploy steps and `make` target docs to come.

## Layout

| Path | What |
|---|---|
| `apps/gateway` | Public HTTP API (:8080). Proxies flight reads, queues subscriptions on Redis. |
| `apps/flights` | Flight status API (:8081), reads Postgres. |
| `apps/notifier` | Worker consuming the `notifications` Redis list. Admin port :8082. |
| `libs/svckit` | Shared logging, metrics, chaos, health and shutdown code. |
| `db/` | `schema.sql` and `seed.sql` (40 departures from HYD, BLR, DEL, BOM, MAA). |

## Make targets

Run `make help` for the list. So far: `tidy`, `fmt`, `build`, `vet`, `test`,
`check`, `run-gateway`, `run-flights`, `run-notifier`, `db-schema`, `db-seed`, `clean`.

Chart (`charts/flightdeck`):

| Target | What |
|---|---|
| `chart-sql` | Copy `db/*.sql` into `charts/flightdeck/files/db/` (CI fails if they drift) |
| `helm-deps` | Fetch the pinned subcharts: bitnami/postgresql 18.12.4, bitnami/redis 28.3.1 |
| `helm-lint` | `helm lint`, with and without ServiceMonitors |
| `helm-template` | Render the release to stdout |
| `helm-validate` | Render and run `kubeconform -strict` against Kubernetes 1.36, ServiceMonitor CRDs included |
| `deploy` | `helm-validate`, then create the `flightdeck` namespace if needed and `helm upgrade --install --wait`. The ALB only admits `INGRESS_CIDR` (default: your current public IP) |
| `platform-lbc` | Validate and install the AWS Load Balancer Controller 3.6.0 (IRSA) from `platform/aws-load-balancer-controller/` |
| `port-forward` | Forward the gateway Service to `localhost:8080` |
| `test-api` | Smoke-test every gateway endpoint at `BASE_URL` (default `http://localhost:8080`) |

Deploy and test:

```bash
make deploy
make port-forward   # in another terminal
make test-api
```

## Resource budget

The release must request < 1 CPU and < 2Gi memory. Requests per pod × replicas:

| Workload | Replicas | CPU | Memory |
|---|---|---|---|
| gateway | 2 (HPA min) – 5 (max) | 50m | 64Mi |
| flights | 2 | 50m | 64Mi |
| notifier | 1 | 25m | 32Mi |
| postgresql | 1 | 150m | 384Mi |
| redis | 1 | 50m | 96Mi |
| db-init Job (hook, transient) | 1 | 25m | 32Mi |
| **Total at HPA min** | | **450m** | **800Mi** |
| **Total at HPA max** | | **600m** | **992Mi** |
