/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - staging additions
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.configuration;

import com.fasterxml.jackson.annotation.JsonTypeName;
import io.dropwizard.core.setup.Environment;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.io.IOException;
import java.util.concurrent.ScheduledExecutorService;
import org.whispersystems.textsecuregcm.configuration.secrets.SecretBytes;
import org.whispersystems.textsecuregcm.registration.RegistrationServiceClient;

/// SWARM addition. A registration-service client factory for the self-hosted SWARM Messenger **staging** stack.
///
/// It differs from [RegistrationServiceConfiguration] in exactly one way: it does not obtain a Google Cloud identity
/// token for the gRPC call, because a self-hosted stack has no Google Cloud project. Everything else - the TLS channel,
/// the CA certificate pinning, the collation-key salt, the wire protocol - is upstream's
/// [RegistrationServiceClient], untouched.
///
/// It is deliberately impossible to enable by accident:
///
///   * the configuration must name `type: swarm-staging` explicitly, and
///   * the environment variable `SWARM_STAGING_FIXED_CODE` must be exactly `true` when the server starts.
///
/// If the environment variable is absent or has any other value the server refuses to start, so a production profile
/// that inherits this block by mistake fails closed instead of running with an unauthenticated registration channel.
///
/// See `docs/SWARM-CHANGES.md` and `deploy/staging/registration-stub/`.
@JsonTypeName(SwarmStagingRegistrationServiceConfiguration.TYPE_NAME)
public record SwarmStagingRegistrationServiceConfiguration(@NotBlank String host,
                                                           int port,
                                                           @NotBlank String registrationCaCertificate,
                                                           @NotNull SecretBytes collationKeySalt) implements
    RegistrationServiceClientFactory {

  static final String TYPE_NAME = "swarm-staging";

  static final String STAGING_ENV_VAR = "SWARM_STAGING_FIXED_CODE";

  @Override
  public RegistrationServiceClient build(final Environment environment,
      final ScheduledExecutorService identityRefreshExecutor) {

    if (!"true".equals(System.getenv(STAGING_ENV_VAR))) {
      throw new IllegalStateException("registrationService type \"" + TYPE_NAME + "\" is a staging-only, "
          + "no-identity-token registration channel and must never be used in production. To use it, set the "
          + "environment variable " + STAGING_ENV_VAR + "=true. Refusing to start.");
    }

    try {
      // No CallCredentials: the staging registration stub does not verify a bearer identity token. The channel is
      // still TLS and still pins registrationCaCertificate.
      return new RegistrationServiceClient(host, port, null, registrationCaCertificate, collationKeySalt.value());
    } catch (final IOException e) {
      throw new RuntimeException(e);
    }
  }
}
