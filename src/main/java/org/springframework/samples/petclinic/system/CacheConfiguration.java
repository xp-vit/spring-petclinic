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

import java.time.Duration;

import org.springframework.cache.CacheManager;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.cache.caffeine.CaffeineCacheManager;
import org.springframework.cache.support.NoOpCacheManager;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.data.redis.cache.RedisCacheConfiguration;
import org.springframework.data.redis.cache.RedisCacheManager;
import org.springframework.data.redis.connection.RedisConnectionFactory;

/**
 * Cache configuration for the caffeine-vs-redis benchmark.
 *
 * <p>
 * The {@code vets} cache is wired via Spring's cache abstraction
 * ({@code @Cacheable("vets")} on {@code VetRepository}). The backing
 * {@link CacheManager} is selected by Spring profile so the exact same fat JAR can be
 * benchmarked under three cache strategies without any application-code change:
 * <ul>
 * <li>{@code cache-none} &rarr; {@link NoOpCacheManager}: every lookup misses, so every
 * request hits the database (baseline).</li>
 * <li>{@code cache-caffeine} &rarr; {@link CaffeineCacheManager}: in-heap, in-process. A
 * hit is a local map lookup &mdash; no network, no serialization.</li>
 * <li>{@code cache-redis} &rarr; {@link RedisCacheManager}: out-of-process. A hit pays
 * serialization + a TCP round-trip to Redis.</li>
 * </ul>
 *
 * <p>
 * When none of these profiles is active (e.g. the test context), no {@code CacheManager}
 * bean is defined here and Spring Boot's cache auto-configuration supplies a default
 * (Caffeine, since it is on the classpath) &mdash; preserving the original behaviour the
 * integration tests rely on.
 */
@Configuration(proxyBeanMethods = false)
@EnableCaching
class CacheConfiguration {

	/** Baseline: caching is a no-op, so every {@code @Cacheable} call reaches the DB. */
	@Bean
	@Profile("cache-none")
	CacheManager noOpCacheManager() {
		return new NoOpCacheManager();
	}

	/** In-process, in-heap cache. Hit = local map lookup; no network, no serialization. */
	@Bean
	@Profile("cache-caffeine")
	CacheManager caffeineCacheManager() {
		return new CaffeineCacheManager("vets", "report", "stats");
	}

	/**
	 * Out-of-process cache. A hit pays JDK serialization + a TCP round-trip to Redis.
	 * <p>
	 * Values use the {@link RedisCacheManager} default serializer (JDK serialization).
	 * This is Spring Boot's out-of-the-box behaviour and round-trips the cached
	 * {@code Collection<Vet>} faithfully because the PetClinic domain graph
	 * ({@code BaseEntity} and its subtypes) already implements {@link java.io.Serializable}
	 * &mdash; avoiding the JSON/Hibernate-collection type-binding pitfalls that a custom
	 * JSON serializer would hit. The serialization + network cost it adds (versus
	 * Caffeine's in-heap reference) is exactly the trade-off this benchmark measures.
	 */
	@Bean
	@Profile("cache-redis")
	CacheManager redisCacheManager(RedisConnectionFactory connectionFactory) {
		RedisCacheConfiguration config = RedisCacheConfiguration.defaultCacheConfig().entryTtl(Duration.ofMinutes(10));
		return RedisCacheManager.builder(connectionFactory).cacheDefaults(config).build();
	}

}
