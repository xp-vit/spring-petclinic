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

import java.io.Serializable;

/**
 * One row of the heavy clinic-statistics aggregation (per pet type), cached under the
 * {@code stats} cache. The payload is small (a handful of rows) but expensive to compute
 * &mdash; the point of caching a real DB aggregation. Implements {@link Serializable} so it
 * round-trips through the default (JDK-serialization) Redis cache.
 */
public class StatRow implements Serializable {

	private static final long serialVersionUID = 1L;

	private String typeName;

	private long owners;

	private long pets;

	private long visits;

	private String lastVisit;

	public StatRow() {
	}

	public StatRow(String typeName, long owners, long pets, long visits, String lastVisit) {
		this.typeName = typeName;
		this.owners = owners;
		this.pets = pets;
		this.visits = visits;
		this.lastVisit = lastVisit;
	}

	public String getTypeName() {
		return typeName;
	}

	public void setTypeName(String typeName) {
		this.typeName = typeName;
	}

	public long getOwners() {
		return owners;
	}

	public void setOwners(long owners) {
		this.owners = owners;
	}

	public long getPets() {
		return pets;
	}

	public void setPets(long pets) {
		this.pets = pets;
	}

	public long getVisits() {
		return visits;
	}

	public void setVisits(long visits) {
		this.visits = visits;
	}

	public String getLastVisit() {
		return lastVisit;
	}

	public void setLastVisit(String lastVisit) {
		this.lastVisit = lastVisit;
	}

}
