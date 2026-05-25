import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 50 },   // warmup
    { duration: '30s', target: 50 },   // ramp
    { duration: '10m', target: 50 },   // sustained
    { duration: '1m', target: 0 },     // cool down
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export default function () {
  const res = http.get(`${BASE_URL}/owners?lastName=Davis`);
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(0.1);
}
