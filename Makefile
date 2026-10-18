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

.PHONY: help tidy fmt build vet test check clean db-schema db-seed $(addprefix run-,$(SERVICES))

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

clean: ## Remove build output
	rm -rf $(BIN)
