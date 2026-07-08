import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate } from 'k6/metrics';

// Virtual-thread (Project Loom) benchmark workload.
//
// Closed-loop, NO think-time: VUS === the target concurrency level. Against a blocking
// endpoint that takes ~MS ms, each VU keeps exactly one request in flight, so the number of
// concurrent in-flight requests equals VUS. We drive one CONCURRENCY level per k6 run and
// let the harness loop the levels (50/100/200/500/1000/2000). This keeps each level's
// steady-state percentiles clean instead of smearing them across a single ramping run.
//
// Env knobs:
//   BASE_URL     app base url (default http://localhost:8080)
//   ENDPOINT     slow | slow-db | cpu          (default slow)
//   MS           downstream delay ms for slow/slow-db (default 200)
//   ITERS        cpu iterations for the cpu endpoint (default 500000)
//   CONCURRENCY  number of VUs = concurrency level (default 200)
//   DURATION     steady-state window incl. warmup (default 60s)
//
// The crossover story: on platform threads, once CONCURRENCY exceeds Tomcat's worker pool
// (~200) requests queue -> latency climbs, throughput plateaus. On virtual threads the app
// keeps scaling because a blocked request costs a cheap virtual thread, not a platform one.

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const ENDPOINT = __ENV.ENDPOINT || 'slow';
const MS = __ENV.MS || '200';
const ITERS = __ENV.ITERS || '500000';
const CONCURRENCY = parseInt(__ENV.CONCURRENCY || '200', 10);
const DURATION = __ENV.DURATION || '60s';

// Latency Trend/Rate tagged so the summarizer can slice by endpoint+concurrency.
export const reqDuration = new Trend('loom_req_duration', true);
export const reqFailed = new Rate('loom_req_failed');

export const options = {
	vus: CONCURRENCY,
	duration: DURATION,
	// Do not abort the run on high latency/errors; we want to MEASURE saturation, not fail on it.
	thresholds: {},
	// Keep k6's own summary percentiles rich.
	summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
	discardResponseBodies: true,
};

function url() {
	if (ENDPOINT === 'slow') return `${BASE_URL}/api/slow?ms=${MS}`;
	if (ENDPOINT === 'slow-db') return `${BASE_URL}/api/slow-db?ms=${MS}`;
	if (ENDPOINT === 'cpu') return `${BASE_URL}/api/cpu?iters=${ITERS}`;
	throw new Error(`unknown ENDPOINT: ${ENDPOINT}`);
}

const TARGET = url();

export default function () {
	const res = http.get(TARGET, { tags: { scenario: 'read', endpoint: ENDPOINT, concurrency: String(CONCURRENCY) } });
	const ok = check(res, { 'status 200': (r) => r.status === 200 });
	reqDuration.add(res.timings.duration);
	reqFailed.add(!ok);
}
