// Peak-RPS sweep: ramp 100 -> 2000 RPS linearly over 5 min to find the
// point where the app saturates (latency spikes / errors rise).
//
// Uses ramping-arrival-rate so k6 holds a target RPS regardless of latency,
// spawning more VUs as needed. The CSV output gives RPS + latency over time
// for the chart.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const START_RPS = parseInt(__ENV.START_RPS || '100', 10);
const END_RPS = parseInt(__ENV.END_RPS || '2000', 10);
const DURATION = __ENV.DURATION || '5m';
const MAX_VUS = parseInt(__ENV.MAX_VUS || '500', 10);

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  discardResponseBodies: false,
  scenarios: {
    peak: {
      executor: 'ramping-arrival-rate',
      startRate: START_RPS,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: MAX_VUS,
      stages: [
        { target: END_RPS, duration: DURATION },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.5'],   // don't abort on errors -- we want to see where it breaks
  },
};

const ENDPOINTS = [
  () => http.get(`${BASE_URL}/owners?lastName=Davis`),
  () => http.get(`${BASE_URL}/owners/${(Math.floor(Math.random() * 10) + 1)}`),
  () => http.get(`${BASE_URL}/vets`, { headers: { Accept: 'application/json' } }),
];

export default function () {
  const res = ENDPOINTS[Math.floor(Math.random() * ENDPOINTS.length)]();
  check(res, { 'ok': (r) => r.status === 200 });
}
