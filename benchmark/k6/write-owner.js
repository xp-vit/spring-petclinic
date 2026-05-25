import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';

export const options = {
  stages: [
    { duration: '2m', target: 50 },
    { duration: '30s', target: 50 },
    { duration: '10m', target: 50 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

const firstNames = ['Alice', 'Bob', 'Charlie', 'Diana', 'Eve', 'Frank', 'Grace', 'Hank', 'Ivy', 'Jack'];
const lastNames = ['Smith', 'Jones', 'Brown', 'Wilson', 'Taylor', 'Clark', 'Hall', 'Allen', 'Young', 'King'];

export default function () {
  const payload = {
    firstName: firstNames[Math.floor(Math.random() * firstNames.length)],
    lastName: lastNames[Math.floor(Math.random() * lastNames.length)],
    address: `${Math.floor(Math.random() * 9999)} Main St`,
    city: 'Springfield',
    telephone: `${Math.floor(1000000000 + Math.random() * 9000000000)}`,
  };

  const res = http.post(`${BASE_URL}/owners/new`, payload);
  check(res, { 'status 200 or 302': (r) => r.status === 200 || r.status === 302 });
  sleep(0.2);
}
