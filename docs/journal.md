# Engineering journal

Terse, dated, in build order. Times are IST (UTC+5:30) unless marked Z.
Commit hashes link the entry to the code.

## 2026-10-18

**12:12** — EKS `eks-practice` created: Kubernetes 1.36, us-east-1, default VPC.

**13:35** — Node group `ng-public`: 2 × m7i-flex.large, on-demand, AL2023, 20 GiB gp3 roots.
- *Decision — m7i-flex.large.* The account's free plan restricts which
  instance types can be launched (the restriction reported by the account
  owner; I didn't hit it myself). m7i-flex.large is allowed, and its 2 vCPU /
  8 GiB per node is the smallest size that fits the app plus
  Prometheus/Grafana/Loki. Budget written into `CLAUDE.md`: ~12 GiB usable,
  app requests < 2 GiB.
- *Decision — default VPC, public subnets, no NAT gateway.* Saves $0.045/h
  plus data processing (~$33/month); nodes get public IPs. Accepted for a lab;
  listed in the README under production changes.

**~17:00** — Workstation tooling into `C:\tools`, versions resolved from the
official endpoints, checksums verified: Go 1.27.2, Helm 4.3.1, gh 2.102.0,
later kubeconform 0.8.0.
- *Broke:* `C:\tools` was assumed to be on the machine PATH; it wasn't. Added it to the User PATH.

**17:22** `eef2fd5` — Three Go services plus `libs/svckit` (request IDs, slog
JSON, RED metrics, chaos, probes, 10s graceful drain).
- *Decision — shared module, not three copies.* ~250 lines would have
  diverged. Cost: the Docker build context is the repo root.

**17:24** `97780b7` — CI: vet/test, then a matrix image build to GHCR.
- *Decision — GHCR over ECR.* The AWS account closes 2026-10-22, and ECR
  images go with it; GHCR images outlive the account and the repo is public.
  `GITHUB_TOKEN` with `packages: write`, no PAT. Tags: short SHA, plus `main`
  on main; never `latest`.
- *Broke:* `gh auth login` didn't land (no `hosts.yml`); redone from the
  app's terminal. `git push` then had no credential helper; pushed via
  `gh auth git-credential` until `gh auth setup-git` was run.

**17:45** `a0c7c1b` — IAM OIDC provider registered (for later IRSA). EBS CSI
driver add-on with **EKS Pod Identity**; gp3 made the default StorageClass;
proven with a 1Gi PVC that bound, appeared in EC2 and was deleted.
- *Decision — Pod Identity for EBS CSI, IRSA for the Load Balancer Controller.*
  EBS CSI is an EKS add-on with first-class Pod Identity: the role trusts
  `pods.eks.amazonaws.com` and never embeds this cluster's OIDC ID. The LB
  Controller comes from its own Helm chart, where IRSA is the documented path,
  and it exercises the OIDC provider. Using both made the comparison
  concrete: [identity.md](identity.md).

**17:55** `926d392` — App Helm chart: HPA, PDBs, NetworkPolicies,
ServiceMonitors, a db-init post-install hook, Bitnami Postgres and Redis.
- *Broke:* Docker Hub's `bitnami/*` only publishes `latest` now. Pinned by digest.
- Budget: 450m CPU / 800Mi requested at HPA min, 600m / 992Mi at max.

**18:03** `a508dba` — First deploy. No failures. `test-api` 16/16 through a port-forward; one request ID traced through all three services.

**18:15** `e7e79bd` — AWS Load Balancer Controller via IRSA; internet-facing
ALB with `target-type: ip`; cluster subnets tagged `kubernetes.io/role/elb`.
- *Decision — the ALB admits one /32,* passed at deploy time. The IP is never
  committed: the repo is public. The chart refuses to render without it.

**18:56** `b0fccfd` — kube-prometheus-stack 92.10.1; etcd, scheduler and
controller-manager scraping off (EKS hides them).
- *Broke:* Grafana's sidecars OOMKilled at 96Mi.
- *Broke:* Helm's release record (526 KB) failed to write from this machine,
  5 times in a row. Reproduced with plain `kubectl create` of the same bytes;
  same-size random payloads succeeded. Root cause not proven. Workaround:
  run Helm from a temporary in-cluster pod (needs a temporary cluster-admin
  binding, applied by hand and deleted afterwards).
- *Broke:* `serve_from_sub_path` made Grafana's `/metrics` 302 to `localhost`; the ServiceMonitor now scrapes `/grafana/metrics`.
- Sharing the ALB with Grafana (IngressGroup) replaced it; new hostname.

**19:03** `dcd8474` — Grafana idles at ~360Mi; it was OOMKilled at 384Mi. Resized to 384Mi / 768Mi.

**19:20** `65b0837` — Loki (SingleBinary, 72h) and Alloy (DaemonSet);
`request_id` as structured metadata, not a label; Loki provisioned in Grafana.
- The Loki chart's defaults would have reserved ~9 GiB for caches plus 9 pods. All turned off.
- Dropped Alloy's automatic `filename` label (changes on every restart).

**19:53** `a657cd4` — `honorLabels: true` on ServiceMonitors.
- *Broke:* the operator's `service` target label overrode ours, which
  Prometheus renamed `exported_service`.
- *Process note:* the upgrade that applied this ran although the request was
  rejected in the UI; caught from `helm history` and reported.

**20:37** `14e3097` — Console scripts open every URL.
- *Broke:* PowerShell 5.1 array bug in `close-consoles.ps1` (`ConvertFrom-Json` emits an array as one object).

**~20:45** — SLOs: 99% availability, 95% under 300ms, 7d window;
multiwindow burn-rate alerts; RED and Platform dashboards as code; 7 runbooks.
- *Broke:* no 300ms histogram bucket, so latency is measured at 250ms.
- *Broke:* 0/0 recorded as NaN with no traffic. Denominators changed to `> 0`.
- Prometheus keeps 3d, so the "7d" budget sees at most 3 days.

**21:02–21:30** (15:32–16:00Z) — [Game day 01](gameday-01-error-spike.md): 30% errors.
- Paged in 9m26s.
- *Broke:* alert `$value` named the wrong window. Fixed live.
- Ticket fired 5 min after the fix.

**21:32–22:16** (16:02–16:46Z) — [Game day 02](gameday-02-latency.md): 800ms latency.
- HPA wanted to scale in.
- A forced pod got no keep-alive traffic.
- The latency page can't fire in under ~43 min.

**Showcase** — README rewritten, GitHub Pages site, this journal, game-day
charts rendered from recorded Prometheus data.

**23:17–23:58** (17:47–18:28Z) — [Game day 03](gameday-03-oom.md): OOMKill.
- The notifier's 13:49Z "restart" checked first: a rolling replacement (rev 6), graceful SIGTERM exit, not an OOM.
- Go unaware of the limit (`go_gc_gomemlimit_bytes` = MaxInt64).
- 32Mi and a 150 req/s spike never killed it; 8Mi once; 6Mi crash-looped.
- *Broke (my prediction):* the gateway hung for 5s instead of 502-ing.
- *Shipped:* `GOMEMLIMIT` = 90% of the limit, from the chart.
- Paused before Step C (the A/B with `GOMEMLIMIT`) to start game day 04.

**23:59–00:20** (18:29–18:50Z) — [Game day 04](gameday-04-dependency.md): Postgres to 0.
- Honest `/readyz` emptied the Service.
- 100% errors, mostly 5s hangs.
- No alert named Postgres.
- Recovery 30.5s, no restarts.
- Open question: why the gateway kept hanging after flights left the Service.

## 2026-10-19

**~11:13** (05:43Z) — *Broke:* the workstation clock had drifted **606s behind**
overnight; AWS rejected signed requests ("Signature expired"). Times below and
in game day 03 Step C use the server/Kubernetes clock. The Prometheus
port-forward had also died with the console windows; restarted.

**11:24–11:35** (05:54–06:05Z) — Game day 03 **Step C**: 6Mi **with** `GOMEMLIMIT`.
- **0 restarts in 10 min vs 12 without.**
- Heap 1.4Mi, peak working set 4.9Mi.
- Cost: up to 4,778 GC/min and 76m CPU on one pod; latency 0.7 → 1.5ms.
- *Broke (my prediction):* "can't help at 6Mi". It did; the "floor" was GC slack.
  Writeup corrected with a dated note.

**Repo finish** — eksctl `infra/cluster.yaml` (dry-run clean), `docs/teardown.md`,
MIT license, account and OIDC IDs redacted to placeholders, Trivy scan job,
Dependabot.

**~14:53–16:00** (09:23–10:30Z) — [Teardown](teardown.md).
- *Broke:* the workstation clock was off again (604s); the Windows Time service was stopped. Started it and set it to Automatic.
- Ingresses first; the controller removed the ALB, target groups and SGs in ~2 min.
- 3 of 5 PVCs survived `helm uninstall`. Grafana's and Loki's didn't: one is a plain manifest PVC, the other has a Delete retention policy.
- The node role needed its instance profile removed before `delete-role`.
- Sweep of us-east-1 and ap-south-1: empty apart from the subnet ELB tags.
- Cost ≈ $8.30 of usage, $0 billed.

## Not done yet

- Game day 04's open question (httptrace + conntrack on a repeat).
- None of the README's "what I'd change at production scale" items is implemented; they're the backlog.

## Resource budget (requests, measured 2026-10-18 after game day 02)

| Scope | CPU | Memory |
|---|---|---|
| flightdeck release (steady state) | 425m | 768Mi |
| kube-prometheus-stack | ~460m | ~1344Mi |
| Loki + Alloy (2 pods) | ~220m | ~576Mi |
| AWS Load Balancer Controller (2) | 100m | 192Mi |
| kube-system and the rest | ~900m | ~1270Mi |
| **Cluster total** | **~2.1 of 3.86 CPU** | **~4.1 of 13.9 GiB** |

Node-loss game days don't fit. One node's requests can't reschedule onto the
other: there's only ~820m CPU free there. And the Postgres, Redis, Grafana and
Loki volumes are pinned to us-east-1d, while the other node is in us-east-1b.
