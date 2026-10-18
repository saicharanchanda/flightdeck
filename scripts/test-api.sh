#!/usr/bin/env bash
# Smoke-test the gateway API end to end (gateway -> flights -> Postgres, and
# gateway -> Redis for subscriptions). Needs only bash and curl.
#
#   BASE_URL=http://localhost:8080 scripts/test-api.sh
#
# Against the cluster: kubectl -n flightdeck port-forward svc/flightdeck-gateway 8080:8080
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
EXPECTED_FLIGHTS="${EXPECTED_FLIGHTS:-40}"

pass=0
fail=0
body=""
status=""
headers=""

# req METHOD PATH [JSON_BODY] -> sets $status, $body, $headers
req() {
  local method=$1 path=$2 data=${3:-}
  local tmp_h tmp_b
  tmp_h=$(mktemp) tmp_b=$(mktemp)
  local args=(-s -X "$method" -D "$tmp_h" -o "$tmp_b" -w '%{http_code}' --max-time 10)
  if [[ -n $data ]]; then
    args+=(-H 'Content-Type: application/json' --data "$data")
  fi
  status=$(curl "${args[@]}" -H "X-Request-ID: client-supplied-id" "$BASE_URL$path") || status="000"
  body=$(cat "$tmp_b")
  headers=$(tr -d '\r' <"$tmp_h")
  rm -f "$tmp_h" "$tmp_b"
}

check() { # check NAME CONDITION...
  local name=$1
  shift
  if "$@"; then
    printf '  \033[32mPASS\033[0m %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m %s (status=%s body=%.200s)\n' "$name" "$status" "$body"
    fail=$((fail + 1))
  fi
}

is_status() { [[ $status == "$1" ]]; }
body_has() { [[ $body == *"$1"* ]]; }
json_count() { sed -n 's/.*"count":\([0-9]*\).*/\1/p' <<<"$body"; }
request_id() { sed -n 's/^x-request-id: //Ip' <<<"$headers"; }

echo "Testing $BASE_URL"

echo "probes and metrics"
req GET /healthz
check "GET /healthz -> 200" is_status 200
req GET /readyz
check "GET /readyz -> 200 (Redis reachable)" is_status 200
req GET /metrics
check "GET /metrics exposes http_requests_total" body_has 'http_requests_total{'
check "GET /metrics exposes http_request_duration_seconds" body_has 'http_request_duration_seconds_bucket{'

echo "flights"
req GET /api/flights
check "GET /api/flights -> 200" is_status 200
check "GET /api/flights returns $EXPECTED_FLIGHTS seeded flights" test "$(json_count)" = "$EXPECTED_FLIGHTS"
rid=$(request_id)
check "gateway mints its own X-Request-ID" test -n "$rid" -a "$rid" != "client-supplied-id"
req GET '/api/flights?origin=hyd'
check "GET /api/flights?origin=hyd filters to HYD departures" test "$(json_count)" = "8"
req GET /api/flights/1
check "GET /api/flights/1 -> 200 with flight_no" bash -c '[[ $0 == 200 && $1 == *"\"flight_no\""* ]]' "$status" "$body"
req GET /api/flights/99999
check "GET /api/flights/99999 -> 404" is_status 404
req GET /api/flights/abc
check "GET /api/flights/abc -> 400" is_status 400

echo "subscriptions"
req POST /api/flights/1/subscribe '{"channel":"sms","recipient":"+91-90000-00000"}'
check "POST /api/flights/1/subscribe -> 202 queued" bash -c '[[ $0 == 202 && $1 == *"\"queued\""* ]]' "$status" "$body"
req POST /api/flights/1/subscribe
check "POST subscribe with empty body defaults to email -> 202" bash -c '[[ $0 == 202 && $1 == *"\"email\""* ]]' "$status" "$body"
req POST /api/flights/1/subscribe '{"channel":"pigeon"}'
check "POST subscribe with unknown channel -> 400" is_status 400
req POST /api/flights/99999/subscribe '{"channel":"email"}'
check "POST subscribe to missing flight -> 404" is_status 404

echo "chaos"
req GET /chaos/reset
if is_status 404; then
  check "chaos endpoints absent while CHAOS_ENABLED=false" is_status 404
else
  check "GET /chaos/reset -> 200 (CHAOS_ENABLED=true)" is_status 200
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
