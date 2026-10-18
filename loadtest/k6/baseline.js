// flightdeck baseline load: a steady, realistic mix against the gateway.
//
//   70%  GET  /api/flights/{id}          (passengers checking a flight)
//   20%  GET  /api/flights?origin=XXX    (departure boards)
//   10%  POST /api/flights/{id}/subscribe (asking for updates)
//
// constant-arrival-rate keeps the request rate fixed even when responses slow
// down, so latency faults show up as latency rather than as less traffic.
//
// Config (env): TARGET (base URL), RATE (iterations/s), DURATION, MAX_VUS.
// Runs as a Kubernetes Job: loadtest/k6/job.yaml, `make load`.
import http from 'k6/http';
import { check } from 'k6';

const TARGET = __ENV.TARGET || 'http://flightdeck-gateway.flightdeck.svc.cluster.local:8080';
const RATE = parseInt(__ENV.RATE || '20', 10);
const DURATION = __ENV.DURATION || '10m';
const MAX_VUS = parseInt(__ENV.MAX_VUS || '100', 10);

const ORIGINS = ['HYD', 'BLR', 'DEL', 'BOM', 'MAA'];
const CHANNELS = ['email', 'sms', 'push'];
const FLIGHTS = 40; // db/seed.sql loads ids 1..40

export const options = {
  scenarios: {
    baseline: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.min(20, MAX_VUS),
      maxVUs: MAX_VUS,
    },
  },
  // The SLOs, as k6 sees them from the client side. Game days are expected to
  // break these; the summary shows by how much.
  thresholds: {
    'http_req_failed{kind:api}': ['rate<0.01'],
    'http_req_duration{kind:api}': ['p(95)<300'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
};

const pick = (xs) => xs[Math.floor(Math.random() * xs.length)];
const flightId = () => 1 + Math.floor(Math.random() * FLIGHTS);

export default function () {
  const roll = Math.random();
  let res;
  if (roll < 0.70) {
    res = http.get(`${TARGET}/api/flights/${flightId()}`, {
      tags: { kind: 'api', name: 'GET /api/flights/{id}' },
    });
    check(res, { 'lookup 200': (r) => r.status === 200 });
  } else if (roll < 0.90) {
    res = http.get(`${TARGET}/api/flights?origin=${pick(ORIGINS)}`, {
      tags: { kind: 'api', name: 'GET /api/flights?origin' },
    });
    check(res, { 'board 200': (r) => r.status === 200 });
  } else {
    res = http.post(
      `${TARGET}/api/flights/${flightId()}/subscribe`,
      JSON.stringify({ channel: pick(CHANNELS), recipient: 'loadtest@example.test' }),
      { headers: { 'Content-Type': 'application/json' }, tags: { kind: 'api', name: 'POST /api/flights/{id}/subscribe' } },
    );
    check(res, { 'subscribe 202': (r) => r.status === 202 });
  }
}
