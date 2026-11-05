/*
 * Copyright 2012-2026 the original author or authors.
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

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.concurrent.atomic.AtomicReference;

import javax.sql.DataSource;

import com.zaxxer.hikari.HikariConfigMXBean;
import com.zaxxer.hikari.HikariDataSource;
import org.crac.Context;
import org.crac.Core;
import org.crac.Resource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * CRaC (Coordinated Restore at Checkpoint) support demonstrating the
 * <b>secrets-safe</b> checkpoint/restore pattern for the benchmark blog post.
 * <p>
 * The whole footgun of CRaC on Kubernetes: a checkpoint is a full dump of JVM
 * memory, so any secret loaded <em>before</em> the checkpoint is baked into the
 * resulting image layer. The mitigation, per the Spring docs, is the CRaC
 * Resource API: release secret-holding resources in {@link #beforeCheckpoint}
 * and re-read the secrets from the environment in {@link #afterRestore}.
 * <p>
 * We warm + checkpoint the image at build time with a <b>placeholder</b> secret,
 * then every pod restores and re-reads the real secret post-restore. The
 * {@code /crac/secret-status} endpoint proves it works: it exposes only a SHA-256
 * prefix of the current secret plus its source, so you can see the value change
 * from the build-time placeholder to the runtime secret without ever leaking it.
 * <p>
 * Activated only when {@code petclinic.crac.enabled=true} so the jvm and native
 * benchmark variants are byte-for-byte unaffected.
 *
 * @author patotski (CRaC vs GraalVM benchmark)
 */
@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty(name = "petclinic.crac.enabled", havingValue = "true")
class CracSupport {

	@Bean
	SecretsSafeResource secretsSafeResource(ObjectProvider<DataSource> dataSource) {
		return new SecretsSafeResource(dataSource);
	}

	/**
	 * A {@link Resource} that participates in the checkpoint/restore lifecycle to
	 * keep secrets out of the checkpoint image and re-hydrate them on restore.
	 */
	static class SecretsSafeResource implements Resource {

		private static final Logger log = LoggerFactory.getLogger(SecretsSafeResource.class);

		/** Name of the env var the real secret is read from at restore time. */
		private static final String SECRET_ENV = "PETCLINIC_API_SECRET";

		/** Name of the env var the real DB password is read from at restore time. */
		private static final String DB_PASS_ENV = "POSTGRES_PASS";

		private final ObjectProvider<DataSource> dataSource;

		/** Held in memory; cleared before checkpoint, re-read after restore. */
		private final AtomicReference<String> apiSecret = new AtomicReference<>();

		/** "build-placeholder" | "restored-env" | "absent" — for the status endpoint. */
		private final AtomicReference<String> secretSource = new AtomicReference<>("unset");

		SecretsSafeResource(ObjectProvider<DataSource> dataSource) {
			this.dataSource = dataSource;
			// Register with the global CRaC context so the engine calls us back.
			Core.getGlobalContext().register(this);
			// Initial load (at build-time warmup this is the placeholder value).
			loadSecret("startup");
		}

		private void loadSecret(String phase) {
			String v = System.getenv(SECRET_ENV);
			if (v == null || v.isBlank()) {
				this.apiSecret.set(null);
				this.secretSource.set("absent");
				log.info("[CRaC] {}: no {} in env", phase, SECRET_ENV);
			}
			else {
				this.apiSecret.set(v);
				this.secretSource.set("restored".equals(phase) ? "restored-env" : "build-placeholder");
				log.info("[CRaC] {}: loaded secret sha256={} source={}", phase, sha256Prefix(v),
						this.secretSource.get());
			}
		}

		@Override
		public void beforeCheckpoint(Context<? extends Resource> context) {
			// Scrub the secret from memory so it is NOT captured in the image dump.
			log.info("[CRaC] beforeCheckpoint: scrubbing in-memory secret before dump");
			this.apiSecret.set(null);
			this.secretSource.set("scrubbed-for-checkpoint");
			// Spring Boot closes the Hikari pool for us via its managed Lifecycle;
			// nothing to do for the pool here. Non-Spring resources would close now.
		}

		@Override
		public void afterRestore(Context<? extends Resource> context) {
			// Re-read secrets from the (fresh) runtime environment. This is what
			// makes the baked-in placeholder irrelevant and the real secret safe.
			log.info("[CRaC] afterRestore: re-reading secrets from runtime env");
			loadSecret("restored");
			reapplyDbPassword();
		}

		/**
		 * Re-apply the DB password to the live Hikari pool from the runtime env, so
		 * the real credential is used post-restore rather than any build-time value
		 * captured in the checkpoint. Spring Boot restarts the pool on restore; we
		 * additionally push the current env password in case it rotated.
		 */
		private void reapplyDbPassword() {
			String pass = System.getenv(DB_PASS_ENV);
			if (pass == null || pass.isBlank()) {
				return;
			}
			DataSource ds = this.dataSource.getIfAvailable();
			if (ds instanceof HikariDataSource hikari) {
				try {
					HikariConfigMXBean cfg = hikari.getHikariConfigMXBean();
					cfg.setPassword(pass);
					// The pool MXBean only exists once the pool has started. With a
					// warmed checkpoint it has (evict stale conns so new creds take
					// effect); with onRefresh the pool is still lazy, so the fresh
					// password is simply picked up on first connect — nothing to evict.
					if (hikari.getHikariPoolMXBean() != null) {
						hikari.getHikariPoolMXBean().softEvictConnections();
						log.info("[CRaC] afterRestore: re-applied DB password from {} and evicted stale connections",
								DB_PASS_ENV);
					}
					else {
						log.info("[CRaC] afterRestore: staged DB password from {} for lazy pool", DB_PASS_ENV);
					}
				}
				catch (RuntimeException ex) {
					log.warn("[CRaC] afterRestore: could not re-apply DB password: {}", ex.getMessage());
				}
			}
		}

		String secretSha256Prefix() {
			String v = this.apiSecret.get();
			return v == null ? "none" : sha256Prefix(v);
		}

		String secretSource() {
			return this.secretSource.get();
		}

		private static String sha256Prefix(String value) {
			try {
				MessageDigest md = MessageDigest.getInstance("SHA-256");
				byte[] d = md.digest(value.getBytes(StandardCharsets.UTF_8));
				return HexFormat.of().formatHex(d).substring(0, 12);
			}
			catch (Exception ex) {
				return "err";
			}
		}

	}

	/**
	 * Read-only endpoint proving the secrets-safe pattern: returns the source and a
	 * SHA-256 prefix of the current secret (never the secret itself). Before
	 * checkpoint it reflects the build placeholder; after restore it reflects the
	 * real runtime secret — demonstrating the value was not baked into the image.
	 */
	@RestController
	@ConditionalOnProperty(name = "petclinic.crac.enabled", havingValue = "true")
	static class CracSecretStatusController {

		private final SecretsSafeResource resource;

		CracSecretStatusController(SecretsSafeResource resource) {
			this.resource = resource;
		}

		@GetMapping("/crac/secret-status")
		String status() {
			return "{\"source\":\"" + this.resource.secretSource() + "\",\"sha256\":\""
					+ this.resource.secretSha256Prefix() + "\"}";
		}

	}

}
