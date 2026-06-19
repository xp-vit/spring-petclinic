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

import java.util.ArrayList;
import java.util.List;

import org.springframework.cache.annotation.CacheEvict;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * Produces a synthetic, size-tunable report for the cache benchmark.
 *
 * <p>
 * The {@code report} cache holds a {@code List<ReportRow>} keyed by row count. On a cache
 * hit, an in-heap cache (Caffeine) returns the stored reference essentially for free,
 * whereas an external cache (Redis) must deserialize and transfer the whole payload &mdash;
 * a cost that grows with the row count. Dialing the size therefore exposes the
 * Caffeine-vs-Redis gap that the tiny 6-row {@code vets} payload cannot.
 *
 * <p>
 * Building the report also does a small amount of per-row string work so that a cache miss
 * is not free, mimicking a non-trivial aggregate query.
 */
@Service
@Profile({ "cache-none", "cache-caffeine", "cache-redis" })
public class CacheBenchmarkService {

	private static final String[] CATEGORIES = { "alpha", "beta", "gamma", "delta", "epsilon" };

	/**
	 * Expensive clinic-statistics aggregation: scans + joins + groups the (large, seeded)
	 * pets/visits/owners tables. Result is tiny (one row per pet type) but the compute is
	 * costly, which is exactly what makes it worth caching. Uses {@code LEFT JOIN} so pet
	 * types with no visits still appear.
	 */
	private static final String STATS_SQL = """
			SELECT t.name AS type_name,
			       COUNT(DISTINCT p.owner_id) AS owners,
			       COUNT(DISTINCT p.id)       AS pets,
			       COUNT(v.id)                AS visits,
			       MAX(v.visit_date)          AS last_visit
			FROM types t
			JOIN pets p   ON p.type_id = t.id
			LEFT JOIN visits v ON v.pet_id = p.id
			GROUP BY t.name
			ORDER BY visits DESC
			""";

	private final JdbcTemplate jdbcTemplate;

	public CacheBenchmarkService(JdbcTemplate jdbcTemplate) {
		this.jdbcTemplate = jdbcTemplate;
	}

	/**
	 * Return a synthetic report of {@code size} rows, cached by size.
	 * @param size number of rows to generate
	 * @return the report rows (cached)
	 */
	@Cacheable(value = "report", key = "#size")
	public List<ReportRow> report(int size) {
		List<ReportRow> rows = new ArrayList<>(size);
		for (int i = 0; i < size; i++) {
			String name = "row-" + i + "-" + Integer.toHexString(i * 31 + 7);
			String category = CATEGORIES[i % CATEGORIES.length];
			String description = "Synthetic report row " + i + " in category " + category
					+ " generated for the cache benchmark payload sizing experiment.";
			rows.add(new ReportRow(i, name, category, description, i * 1.5, (i % 2) == 0));
		}
		return rows;
	}

	/** Evict the whole report cache (benchmark write/invalidation path). */
	@CacheEvict(value = "report", allEntries = true)
	public void invalidate() {
	}

	/**
	 * Run (and cache) the heavy clinic-statistics aggregation. On a cache miss this is an
	 * expensive scan/join/group over the large seeded dataset; on a hit it is served from
	 * the cache, which is where caching actually pays off (avoided DB work >> cache access).
	 * @return per-pet-type statistics (small result)
	 */
	@Cacheable("stats")
	public List<StatRow> stats() {
		return this.jdbcTemplate.query(STATS_SQL,
				(rs, i) -> new StatRow(rs.getString("type_name"), rs.getLong("owners"), rs.getLong("pets"),
						rs.getLong("visits"), String.valueOf(rs.getDate("last_visit"))));
	}

	/** Evict the stats cache (benchmark write/invalidation path). */
	@CacheEvict(value = "stats", allEntries = true)
	public void invalidateStats() {
	}

}
