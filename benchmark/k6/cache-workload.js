import http from 'k6/http';
import { check, sleep } from 'k6';

// Cache benchmark workload: read-heavy on a cacheable endpoint + a small fraction of
// writes that evict the cache, so reads exercise cache hits and writes exercise eviction +
// repopulation -- where Caffeine (in-heap) and Redis (network) diverge.
//
// Two payload shapes (WORKLOAD):
//   vets   -> GET /vets (tiny, 6 rows) + POST /vets/{id}/touch     (default)
//   report -> GET /cache/report?size=SIZE (tunable) + POST /cache/report/evict
//
// Pacing: READ_SLEEP / WRITE_SLEEP (seconds). Set both to 0 for a peak/no-sleep run that
// measures max throughput instead of latency at a fixed arrival rate.
//
// Tunables: DURATION, VUS_TOTAL, WRITE_RATIO, WORKLOAD, SIZE, READ_SLEEP, WRITE_SLEEP, VET_COUNT.
const DURATION = __ENV.DURATION || '10m';
const VUS_TOTAL = parseInt(__ENV.VUS_TOTAL || '50', 10);
const WRITE_RATIO = parseFloat(__ENV.WRITE_RATIO || '0.1');
const WORKLOAD = __ENV.WORKLOAD || 'vets';
const SIZE = parseInt(__ENV.SIZE || '1000', 10);
const READ_SLEEP = parseFloat(__ENV.READ_SLEEP || '0.1');
const WRITE_SLEEP = parseFloat(__ENV.WRITE_SLEEP || '0.2');
const VET_COUNT = parseInt(__ENV.VET_COUNT || '6', 10);

// WRITE_RATIO=0 => no writers at all (pure cache-hit / read-warm measurement). Otherwise at
// least one writer.
const vusWrite = WRITE_RATIO <= 0 ? 0 : Math.max(1, Math.round(VUS_TOTAL * WRITE_RATIO));
const vusRead = Math.max(1, VUS_TOTAL - vusWrite);

const scenarios = {
  read_cache: { executor: 'constant-vus', vus: vusRead, duration: DURATION, exec: 'readCache' },
};
if (vusWrite > 0) {
  scenarios.write_evict = { executor: 'constant-vus', vus: vusWrite, duration: DURATION, exec: 'writeEvict' };
}

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  scenarios,
  thresholds: {
    http_req_failed: ['rate<0.05'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

// Cache-hit read path.
export function readCache() {
  let res;
  if (WORKLOAD === 'report') {
    res = http.get(`${BASE_URL}/cache/report?size=${SIZE}`, {
      headers: { Accept: 'application/json' },
      tags: { op: 'read' },
    });
  } else if (WORKLOAD === 'stats') {
    // Heavy DB aggregation (small payload, expensive compute) -- the realistic cache target.
    res = http.get(`${BASE_URL}/cache/stats`, {
      headers: { Accept: 'application/json' },
      tags: { op: 'read' },
    });
  } else {
    res = http.get(`${BASE_URL}/vets`, {
      headers: { Accept: 'application/json' },
      tags: { op: 'read' },
    });
  }
  check(res, { 'read 200': (r) => r.status === 200 });
  if (READ_SLEEP > 0) sleep(READ_SLEEP);
}

// Write/evict path: evicts the cache so the next read is a miss that repopulates it
// (in-heap for Caffeine, network round-trip for Redis).
export function writeEvict() {
  let res;
  if (WORKLOAD === 'report') {
    res = http.post(`${BASE_URL}/cache/report/evict`, null, { tags: { op: 'write' } });
  } else if (WORKLOAD === 'stats') {
    res = http.post(`${BASE_URL}/cache/stats/evict`, null, { tags: { op: 'write' } });
  } else {
    const id = Math.floor(Math.random() * VET_COUNT) + 1;
    res = http.post(`${BASE_URL}/vets/${id}/touch`, null, { tags: { op: 'write' } });
  }
  check(res, { 'write 200': (r) => r.status === 200 });
  if (WRITE_SLEEP > 0) sleep(WRITE_SLEEP);
}
