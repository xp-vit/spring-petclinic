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
package org.springframework.samples.petclinic.vet;

import org.springframework.cache.annotation.CacheEvict;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.dao.DataAccessException;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.repository.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collection;

/**
 * Repository class for <code>Vet</code> domain objects All method names are compliant
 * with Spring Data naming conventions so this interface can easily be extended for Spring
 * Data. See:
 * https://docs.spring.io/spring-data/jpa/docs/current/reference/html/#repositories.query-methods.query-creation
 *
 * @author Ken Krebs
 * @author Juergen Hoeller
 * @author Sam Brannen
 * @author Michael Isvy
 */
public interface VetRepository extends Repository<Vet, Integer> {

	/**
	 * Retrieve all <code>Vet</code>s from the data store.
	 * @return a <code>Collection</code> of <code>Vet</code>s
	 */
	@Transactional(readOnly = true)
	@Cacheable("vets")
	Collection<Vet> findAll() throws DataAccessException;

	/**
	 * Retrieve all <code>Vet</code>s from data store in Pages
	 * @param pageable
	 * @return
	 * @throws DataAccessException
	 */
	@Transactional(readOnly = true)
	@Cacheable("vets")
	Page<Vet> findAll(Pageable pageable) throws DataAccessException;

	/**
	 * Retrieve a single <code>Vet</code> by id. Used by the benchmark write path to load
	 * a row before re-saving it. Not cached.
	 * @param id the vet id
	 * @return the <code>Vet</code>, or {@code null} if none
	 */
	@Transactional(readOnly = true)
	Vet findById(Integer id);

	/**
	 * Persist a <code>Vet</code> and evict the whole {@code vets} cache. This is the
	 * benchmark's write/invalidation path: a DB write plus a cache eviction, so the next
	 * read is a miss that repopulates the cache. The eviction cost differs sharply by
	 * backend (in-heap map removal for Caffeine vs a network round-trip for Redis), which
	 * is exactly what the read+write workload measures.
	 * @param vet the vet to persist
	 * @return the persisted vet
	 */
	@Transactional
	@CacheEvict(value = "vets", allEntries = true)
	Vet save(Vet vet);

}
