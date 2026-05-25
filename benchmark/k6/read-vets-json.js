import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 50 },
    { duration: '30s', target: 50 },
    { duration: '10m', target: 50 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export default function () {
  const res = http.get(`${BASE_URL}/vets`, {
    headers: { Accept: 'application/json' },
  });
  check(res, {
    'status 200': (r) => r.status === 200,
    'is json': (r) => r.headers['Content-Type'].includes('application/json'),
  });
  sleep(0.1);
}
