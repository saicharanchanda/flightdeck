SHELL := bash
.DEFAULT_GOAL := help

SERVICES := gateway flights notifier
MODULES  := libs/svckit $(addprefix apps/,$(SERVICES))
BIN      := bin

# Local Postgres connection for db-* targets (psql reads PGPASSWORD from env).
PGHOST ?= localhost
PGPORT ?= 5432
PGUSER ?= flightdeck
PGDATABASE ?= flightdeck
PSQL := psql -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d $(PGDATABASE) -v ON_ERROR_STOP=1

# Helm chart
CHART     := charts/flightdeck
RELEASE   ?= flightdeck
NAMESPACE ?= flightdeck
KUBE_VERSION ?= 1.36.0
CRD_SCHEMAS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
KUBECONFORM := kubeconform -strict -summary -kubernetes-version $(KUBE_VERSION) -schema-location default -schema-location '$(CRD_SCHEMAS)'

# Only this source may reach the ALB. Defaults to your current public IP;
# override with INGRESS_CIDR=a.b.c.d/32. Never committed: the repo is public.
INGRESS_CIDR ?= $(shell curl -fsS https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')/32
# lint/template/validate render with a documentation-range placeholder.
RENDER_SET := --set 'ingress.inboundCIDRs={203.0.113.10/32}'

.PHONY: help tidy fmt build vet test check clean db-schema db-seed $(addprefix run-,$(SERVICES)) \
	chart-sql helm-deps helm-lint helm-template helm-validate deploy platform-lbc platform-monitoring platform-logging observability load load-stop prometheus-ui grafana-ui port-forward test-api

help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

tidy: ## go mod tidy in every module
	@for m in $(MODULES); do echo "==> $$m"; go -C $$m mod tidy || exit 1; done

fmt: ## gofmt every module
	@for m in $(MODULES); do gofmt -l -w $$m; done

build: ## Build service binaries into bin/
	@mkdir -p $(BIN)
	@for s in $(SERVICES); do echo "==> $$s"; go -C apps/$$s build -o $(CURDIR)/$(BIN)/$$s . || exit 1; done

vet: ## go vet every module
	@for m in $(MODULES); do echo "==> $$m"; go -C $$m vet ./... || exit 1; done

test: ## go test every module
	@for m in $(MODULES); do echo "==> $$m"; go -C $$m test ./... || exit 1; done

check: vet build test ## vet + build + test

run-gateway: ## Run gateway locally on :8080
	go -C apps/gateway run .

run-flights: ## Run flights locally on :8081
	go -C apps/flights run .

run-notifier: ## Run notifier locally (admin port :8082)
	go -C apps/notifier run .

db-schema: ## Apply db/schema.sql to $(PGHOST)
	$(PSQL) -f db/schema.sql

db-seed: db-schema ## Apply schema, then (re)load seed data
	$(PSQL) -f db/seed.sql

chart-sql: ## Copy db/*.sql into the chart (the db-init Job reads them from there)
	mkdir -p $(CHART)/files/db && cp db/*.sql $(CHART)/files/db/

helm-deps: ## Fetch the pinned postgresql/redis subcharts
	helm dependency update $(CHART)

helm-lint: chart-sql ## helm lint, with and without ServiceMonitors
	helm lint $(CHART) $(RENDER_SET)
	helm lint $(CHART) $(RENDER_SET) --set serviceMonitor.enabled=true

helm-template: chart-sql ## Render the chart to stdout
	@helm template $(RELEASE) $(CHART) -n $(NAMESPACE) $(RENDER_SET)

helm-validate: helm-lint ## Render and validate with kubeconform (strict), incl. ServiceMonitor CRDs
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) $(RENDER_SET) | $(KUBECONFORM)
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) $(RENDER_SET) --set serviceMonitor.enabled=true | $(KUBECONFORM)

deploy: helm-validate ## Validate, then install/upgrade into $(NAMESPACE); ALB restricted to INGRESS_CIDR
	@case "$(INGRESS_CIDR)" in /32) echo "Could not detect your public IP; pass INGRESS_CIDR=a.b.c.d/32" >&2; exit 1;; esac
	@echo "ALB inbound restricted to $(INGRESS_CIDR)"
	helm dependency build $(CHART)
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) --wait --timeout 10m \
		--set 'ingress.inboundCIDRs={$(INGRESS_CIDR)}'
	kubectl -n $(NAMESPACE) get pods,ingress

LBC_VERSION := 3.6.0
LBC_DIR     := platform/aws-load-balancer-controller

platform-lbc: ## Validate, then install/upgrade the AWS Load Balancer Controller (IRSA) in kube-system
	helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
	kubeconform -strict -summary -kubernetes-version $(KUBE_VERSION) $(LBC_DIR)/serviceaccount.yaml
	helm template aws-load-balancer-controller eks/aws-load-balancer-controller --version $(LBC_VERSION) \
		-n kube-system -f $(LBC_DIR)/values.yaml --include-crds | $(KUBECONFORM) -skip CustomResourceDefinition
	kubectl apply -f $(LBC_DIR)/serviceaccount.yaml
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version $(LBC_VERSION) \
		-n kube-system -f $(LBC_DIR)/values.yaml --wait --timeout 5m

KPS_VERSION := 92.10.1
KPS_VALUES  := platform/kube-prometheus-stack-values.yaml
# The Grafana Ingress shares the flightdeck ALB; it must carry the same
# inbound CIDR or the group's security group opens to 0.0.0.0/0.
KPS_SET = --set-string 'grafana.ingress.annotations.alb\.ingress\.kubernetes\.io/inbound-cidrs=$(INGRESS_CIDR)'

platform-monitoring: ## Validate, then install/upgrade kube-prometheus-stack in monitoring (needs Secret grafana-admin)
	@case "$(INGRESS_CIDR)" in /32) echo "Could not detect your public IP; pass INGRESS_CIDR=a.b.c.d/32" >&2; exit 1;; esac
	@kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1 || { echo "Create the grafana-admin Secret first (see $(KPS_VALUES))" >&2; exit 1; }
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
	helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --version $(KPS_VERSION) \
		-n monitoring -f $(KPS_VALUES) $(KPS_SET) | $(KUBECONFORM) -skip CustomResourceDefinition
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version $(KPS_VERSION) \
		-n monitoring -f $(KPS_VALUES) $(KPS_SET) --wait --timeout 10m

LOKI_VERSION  := 7.3.0
ALLOY_VERSION := 1.13.1
# ServiceMonitors only render when the CRD API is present; tell offline templates it is.
SM_API := --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor

platform-logging: ## Validate, then install/upgrade Loki (SingleBinary) and Alloy (DaemonSet) in monitoring
	helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
	helm template loki grafana/loki --version $(LOKI_VERSION) -n monitoring -f platform/loki-values.yaml $(SM_API) | $(KUBECONFORM)
	helm template alloy grafana/alloy --version $(ALLOY_VERSION) -n monitoring -f platform/alloy-values.yaml $(SM_API) | $(KUBECONFORM)
	helm upgrade --install loki grafana/loki --version $(LOKI_VERSION) -n monitoring -f platform/loki-values.yaml --wait --timeout 10m
	helm upgrade --install alloy grafana/alloy --version $(ALLOY_VERSION) -n monitoring -f platform/alloy-values.yaml --wait --timeout 10m

PROM_POD := prometheus-kube-prometheus-stack-prometheus-0
DASHBOARDS := $(wildcard observability/dashboards/*.json)

observability: ## Validate and apply SLO rules (PrometheusRule) and Grafana dashboards (ConfigMaps)
	$(KUBECONFORM) observability/rules/*.yaml
	@for f in observability/rules/*.yaml; do \
		echo "promtool check rules $$f"; \
		awk '/^spec:/{f=1; next} f{sub(/^  /,""); print}' $$f | \
			kubectl -n monitoring exec -i $(PROM_POD) -c prometheus -- promtool check rules /dev/stdin || exit 1; \
	done
	@for f in $(DASHBOARDS); do python3 -m json.tool $$f >/dev/null || { echo "invalid JSON: $$f"; exit 1; }; done
	kubectl apply -f observability/rules/
	@# One ConfigMap per dashboard; the Grafana sidecar loads anything labelled grafana_dashboard=1.
	@for f in $(DASHBOARDS); do \
		name=dashboard-$$(basename $$f .json); \
		kubectl -n monitoring create configmap $$name --from-file=$$f --dry-run=client -o yaml | \
			kubectl label --local -f - grafana_dashboard=1 app.kubernetes.io/part-of=flightdeck -o yaml | \
			kubectl apply -f -; \
	done

RATE     ?= 20
DURATION ?= 10m

load: ## Run k6 (loadtest/k6/baseline.js) as a Job in-cluster: make load RATE=20 DURATION=10m
	kubectl create namespace loadtest --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n loadtest create configmap k6-scripts --from-file=loadtest/k6/baseline.js --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n loadtest delete job k6-baseline --ignore-not-found
	sed -e 's/__RATE__/$(RATE)/' -e 's/__DURATION__/$(DURATION)/' loadtest/k6/job.yaml | $(KUBECONFORM)
	sed -e 's/__RATE__/$(RATE)/' -e 's/__DURATION__/$(DURATION)/' loadtest/k6/job.yaml | kubectl apply -f -
	@echo "Follow: kubectl -n loadtest logs -f job/k6-baseline"

load-stop: ## Stop a running load test
	kubectl -n loadtest delete job k6-baseline --ignore-not-found

prometheus-ui: ## Port-forward Prometheus to http://localhost:9090
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

grafana-ui: ## Port-forward Grafana to http://localhost:3000/grafana/
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

port-forward: ## Forward the gateway Service to localhost:8080 (for test-api)
	kubectl -n $(NAMESPACE) port-forward svc/$(RELEASE)-gateway 8080:8080

test-api: ## Smoke-test the gateway at BASE_URL (default http://localhost:8080)
	BASE_URL=$${BASE_URL:-http://localhost:8080} bash scripts/test-api.sh

clean: ## Remove build output
	rm -rf $(BIN)
