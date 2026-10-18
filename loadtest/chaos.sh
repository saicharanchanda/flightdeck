#!/usr/bin/env bash
# Apply a chaos call to EVERY pod of a flightdeck service. Chaos state lives
# in each pod's memory, so a call through the Service would only reach one
# replica — and pods created later (rollouts, HPA scale-out) start clean.
#
#   loadtest/chaos.sh gateway '/chaos/errors?rate=0.3'
#   loadtest/chaos.sh gateway '/chaos/latency?ms=800'
#   loadtest/chaos.sh gateway /chaos/reset
#
# Needs the release deployed with config.chaosEnabled=true.
set -euo pipefail
svc=${1:?service: gateway|flights|notifier}
path=${2:?chaos path, e.g. /chaos/reset}
ns=${NAMESPACE:-flightdeck}
declare -A port=([gateway]=8080 [flights]=8081 [notifier]=8082)
p=${port[$svc]:?unknown service $svc}
local_port=$((19000 + RANDOM % 900))

for pod in $(kubectl -n "$ns" get pods -l "app.kubernetes.io/name=$svc" --field-selector=status.phase=Running -o name); do
  kubectl -n "$ns" port-forward "$pod" "$local_port:$p" >/dev/null 2>&1 &
  pf=$!
  for _ in $(seq 1 40); do curl -s -o /dev/null "localhost:$local_port/healthz" && break; sleep 0.25; done
  printf '%s %s %s -> %s\n' "$(date -u +%H:%M:%SZ)" "$pod" "$path" "$(curl -s "localhost:$local_port$path")"
  kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null || true
  local_port=$((local_port + 1))
done
