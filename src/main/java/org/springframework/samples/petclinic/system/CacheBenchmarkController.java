/*
 * Copyright 2012-2025 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.springframework.samples.petclinic.system;

import java.util.List;

import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * HTTP surface for the heavy-payload cache benchmark.
 *
 * <ul>
 * <li>{@code GET /cache/report?size=N} &mdash; cache-read path; returns an {@code N}-row
 * synthetic report served from the {@code report} cache (a cache hit on Redis pays
 * deserialization + transfer proportional to {@code N}; on Caffeine it is a reference
 * lookup).</li>
 * <li>{@code POST /cache/report/evict} &mdash; cache-write/invalidation path; evicts the
 * report cache so the next read repopulates it.</li>
 * </ul>
 */
@RestController
@Profile({ "cache-none", "cache-caffeine", "cache-redis" })
class CacheBenchmarkController {

	private final CacheBenchmarkService service;

	CacheBenchmarkController(CacheBenchmarkService service) {
		this.service = service;
	}

	@GetMapping("/cache/report")
	public @ResponseBody List<ReportRow> report(@RequestParam(defaultValue = "1000") int size) {
		return this.service.report(size);
	}

	@PostMapping("/cache/report/evict")
	public @ResponseBody String evict() {
		this.service.invalidate();
		return "ok";
	}

	@GetMapping("/cache/stats")
	public @ResponseBody List<StatRow> stats() {
		return this.service.stats();
	}

	@PostMapping("/cache/stats/evict")
	public @ResponseBody String evictStats() {
		this.service.invalidateStats();
		return "ok";
	}

}
