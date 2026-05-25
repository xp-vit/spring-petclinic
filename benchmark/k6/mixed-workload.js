import http from 'k6/http';
import { check, sleep } from 'k6';

// Tunable via env vars (DURATION, VUS_TOTAL). Defaults match the standard profile.
// VU mix is 40% read_owners, 20% read_detail, 20% read_vets, 20% write_owner.
const DURATION = __ENV.DURATION || '10m';
const VUS_TOTAL = parseInt(__ENV.VUS_TOTAL || '50', 10);
const vusReadOwners = Math.max(1, Math.round(VUS_TOTAL * 0.4));
const vusReadDetail = Math.max(1, Math.round(VUS_TOTAL * 0.2));
const vusReadVets = Math.max(1, Math.round(VUS_TOTAL * 0.2));
const vusWriteOwner = Math.max(1, VUS_TOTAL - vusReadOwners - vusReadDetail - vusReadVets);

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  scenarios: {
    read_owners: { executor: 'constant-vus', vus: vusReadOwners, duration: DURATION, exec: 'readOwners' },
    read_detail: { executor: 'constant-vus', vus: vusReadDetail, duration: DURATION, exec: 'readDetail' },
    read_vets:   { executor: 'constant-vus', vus: vusReadVets,   duration: DURATION, exec: 'readVets' },
    write_owner: { executor: 'constant-vus', vus: vusWriteOwner, duration: DURATION, exec: 'writeOwner' },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export function readOwners() {
  const res = http.get(`${BASE_URL}/owners?lastName=Davis`);
  check(res, { 'owners 200': (r) => r.status === 200 });
  sleep(0.1);
}

export function readDetail() {
  const id = Math.floor(Math.random() * 10) + 1;
  const res = http.get(`${BASE_URL}/owners/${id}`);
  check(res, { 'detail 200': (r) => r.status === 200 });
  sleep(0.1);
}

export function readVets() {
  const res = http.get(`${BASE_URL}/vets`, {
    headers: { Accept: 'application/json' },
  });
  check(res, { 'vets 200': (r) => r.status === 200 });
  sleep(0.1);
}

const firstNames = ['Alice', 'Bob', 'Charlie', 'Diana', 'Eve', 'Frank', 'Grace', 'Hank', 'Ivy', 'Jack'];
const lastNames = ['Smith', 'Jones', 'Brown', 'Wilson', 'Taylor', 'Clark', 'Hall', 'Allen', 'Young', 'King'];

export function writeOwner() {
  const payload = {
    firstName: firstNames[Math.floor(Math.random() * firstNames.length)],
    lastName: lastNames[Math.floor(Math.random() * lastNames.length)],
    address: `${Math.floor(Math.random() * 9999)} Main St`,
    city: 'Springfield',
    telephone: `${Math.floor(1000000000 + Math.random() * 9000000000)}`,
  };
  const res = http.post(`${BASE_URL}/owners/new`, payload);
  check(res, { 'write 200/302': (r) => r.status === 200 || r.status === 302 });
  sleep(0.2);
}
