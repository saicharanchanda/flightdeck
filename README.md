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
