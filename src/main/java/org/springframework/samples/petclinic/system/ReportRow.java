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
 * A single row of the synthetic cache-benchmark report.
 *
 * <p>
 * Used only by the cache benchmark ({@link CacheBenchmarkService}) to produce a cached
 * payload whose size is tunable, so the serialization + transfer cost of an external cache
 * (Redis) can be compared against an in-heap cache (Caffeine) that stores only a
 * reference. Implements {@link Serializable} so it round-trips through the default
 * (JDK-serialization) Redis cache.
 */
public class ReportRow implements Serializable {

	private static final long serialVersionUID = 1L;

	private int id;

	private String name;

	private String category;

	private String description;

	private double value;

	private boolean active;

	public ReportRow() {
	}

	public ReportRow(int id, String name, String category, String description, double value, boolean active) {
		this.id = id;
		this.name = name;
		this.category = category;
		this.description = description;
		this.value = value;
		this.active = active;
	}

	public int getId() {
		return id;
	}

	public void setId(int id) {
		this.id = id;
	}

	public String getName() {
		return name;
	}

	public void setName(String name) {
		this.name = name;
	}

	public String getCategory() {
		return category;
	}

	public void setCategory(String category) {
		this.category = category;
	}

	public String getDescription() {
		return description;
	}

	public void setDescription(String description) {
		this.description = description;
	}

	public double getValue() {
		return value;
	}

	public void setValue(double value) {
		this.value = value;
	}

	public boolean isActive() {
		return active;
	}

	public void setActive(boolean active) {
		this.active = active;
	}

}
