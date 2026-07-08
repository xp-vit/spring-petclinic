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

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.client.RestClient;

/**
 * Backend for the virtual-thread (Project Loom) benchmark.
 *
 * <p>
 * The point of this benchmark is that vanilla PetClinic shows <em>no</em> virtual-thread
 * benefit: its CRUD requests hit a fast local DB, complete in sub-millisecond time, and
 * never keep Tomcat's platform worker threads (default 200) busy long enough to exhaust
 * the pool. Virtual threads only pay off when request threads spend a long time
 * <em>blocked</em>, so we inject that condition explicitly:
 *
 * <ul>
 * <li>{@link #slow(int)} makes a blocking HTTP call to a co-located stub that sleeps for a
 * fixed delay &mdash; a stand-in for a slow external API. This is the clean thread-story
 * path (no DB, so no connection-pool confound).</li>
 * <li>{@link #slowDb(int)} additionally holds a pooled DB connection across the slow call
 * (inside a transaction). Once virtual threads make request threads cheap, the JDBC
 * connection pool becomes the new bottleneck &mdash; this path demonstrates that.</li>
 * <li>{@link #cpu(int)} does pure CPU-bound work with no blocking. Virtual threads cannot
 * help here (and may slightly regress); it is the honest "when Loom does not help"
 * case.</li>
 * </ul>
 *
 * The thread mode is toggled by configuration only ({@code spring.threads.virtual.enabled}),
 * so the exact same code path runs in both modes.
 */
@Service
@Profile("loom")
public class LoomBenchmarkService {

	private final RestClient stub;

	private final JdbcTemplate jdbcTemplate;

	LoomBenchmarkService(JdbcTemplate jdbcTemplate,
			@Value("${loom.stub.url:http://localhost:9090}") String stubUrl) {
		// Build the client directly (RestClient.Builder is not always auto-configured as a
		// bean) so the benchmark has no dependency on web-client auto-config. The default
		// JDK HttpClient request factory pools connections and blocks on socket reads, which
		// is exactly the blocking behaviour a virtual thread unmounts from.
		this.stub = RestClient.create(stubUrl);
		this.jdbcTemplate = jdbcTemplate;
	}

	/**
	 * Blocking HTTP call to the slow stub. This is what blocks a platform worker thread for
	 * the whole delay; a virtual thread instead unmounts from its carrier while the socket
	 * read blocks, so a handful of carriers can serve thousands of concurrent requests.
	 * @param ms the downstream delay in milliseconds
	 * @return the stub response body
	 */
	public String slow(int ms) {
		return this.stub.get().uri("/delay/{ms}", ms).retrieve().body(String.class);
	}

	/**
	 * Same slow downstream call, but wrapped in a transaction that first acquires a pooled
	 * JDBC connection and holds it across the blocking call. This is the classic
	 * connection-hogging anti-pattern: with cheap (virtual) threads the app is no longer
	 * thread-bound, so throughput is capped by the connection pool size divided by the
	 * hold time. Raising {@code spring.datasource.hikari.maximum-pool-size} lifts the cap.
	 * @param ms the downstream delay in milliseconds
	 * @return the stub response body
	 */
	@Transactional
	public String slowDb(int ms) {
		// Touch the DB first so the transaction's connection is bound to this thread, then
		// hold it for the duration of the slow downstream call.
		this.jdbcTemplate.queryForObject("SELECT 1", Integer.class);
		return this.stub.get().uri("/delay/{ms}", ms).retrieve().body(String.class);
	}

	/**
	 * Pure CPU-bound work: no I/O, nothing to block on. Virtual threads offer no benefit
	 * because the bottleneck is CPU cores, not thread count; the honest counter-example.
	 * @param iters number of hashing iterations
	 * @return a value derived from the work (prevents dead-code elimination)
	 */
	public long cpu(int iters) {
		long acc = 0;
		for (int i = 0; i < iters; i++) {
			acc = acc * 31 + Long.hashCode(acc ^ (i * 2654435761L));
		}
		return acc;
	}

}
