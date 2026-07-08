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

import java.lang.management.ManagementFactory;
import java.lang.management.ThreadMXBean;
import java.util.Map;

import org.springframework.context.annotation.Profile;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * HTTP surface for the virtual-thread (Project Loom) benchmark. Every endpoint runs the
 * same code regardless of thread mode; the mode is chosen by
 * {@code spring.threads.virtual.enabled} at startup.
 *
 * <ul>
 * <li>{@code GET /api/slow?ms=200} &mdash; blocking downstream call (clean thread story).</li>
 * <li>{@code GET /api/slow-db?ms=200} &mdash; blocking call while holding a pooled DB
 * connection (connection-pool bottleneck story).</li>
 * <li>{@code GET /api/cpu?iters=...} &mdash; CPU-bound work (Loom-does-not-help story).</li>
 * <li>{@code GET /api/threadstats} &mdash; live <em>platform</em> thread count. In platform
 * mode this climbs to Tomcat's max (~200) under load; in virtual mode it stays near the
 * carrier count (~#CPUs) because virtual threads are not counted here. Sample it during a
 * run to show saturation.</li>
 * </ul>
 */
@RestController
@Profile("loom")
class LoomBenchmarkController {

	private final LoomBenchmarkService service;

	LoomBenchmarkController(LoomBenchmarkService service) {
		this.service = service;
	}

	@GetMapping("/api/slow")
	public @ResponseBody String slow(@RequestParam(defaultValue = "200") int ms) {
		return this.service.slow(ms);
	}

	@GetMapping("/api/slow-db")
	public @ResponseBody String slowDb(@RequestParam(defaultValue = "200") int ms) {
		return this.service.slowDb(ms);
	}

	@GetMapping("/api/cpu")
	public @ResponseBody String cpu(@RequestParam(defaultValue = "500000") int iters) {
		return Long.toString(this.service.cpu(iters));
	}

	@GetMapping("/api/threadstats")
	public @ResponseBody Map<String, Object> threadStats() {
		ThreadMXBean bean = ManagementFactory.getThreadMXBean();
		return Map.of("platformThreadCount", bean.getThreadCount(), "peakPlatformThreadCount",
				bean.getPeakThreadCount(), "availableProcessors", Runtime.getRuntime().availableProcessors(),
				"virtualEnabled", Thread.currentThread().isVirtual());
	}

}
