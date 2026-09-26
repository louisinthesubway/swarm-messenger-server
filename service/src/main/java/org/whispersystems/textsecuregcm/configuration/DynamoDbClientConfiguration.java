/*
 * Copyright 2021 Signal Messenger, LLC
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.configuration;

import com.fasterxml.jackson.annotation.JsonTypeName;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import java.net.URI;
import java.time.Duration;
import javax.annotation.Nullable;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.http.crt.AwsCrtHttpClient;
import software.amazon.awssdk.http.nio.netty.NettyNioAsyncHttpClient;
import software.amazon.awssdk.metrics.MetricPublisher;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.dynamodb.DynamoDbAsyncClient;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;

@JsonTypeName("default")
public record DynamoDbClientConfiguration(@NotBlank String region,
                                          @NotNull Duration clientExecutionTimeout,
                                          @NotNull Duration clientRequestTimeout,
                                          @Positive int maxConnections,
                                          // SWARM: optional endpoint override so a self-hosted staging stack can point
                                          // the DynamoDB clients at a local DynamoDB Local instance. Null (the default,
                                          // and the only value used in production) keeps upstream behaviour exactly:
                                          // the region's real AWS endpoint. See docs/SWARM-CHANGES.md.
                                          @Nullable URI endpointOverride) implements DynamoDbClientFactory {

  public DynamoDbClientConfiguration {
    if (clientExecutionTimeout == null) {
      clientExecutionTimeout = Duration.ofSeconds(30);
    }

    if (clientRequestTimeout == null) {
      clientRequestTimeout = Duration.ofSeconds(10);
    }

    if (maxConnections == 0) {
      maxConnections = 50;
    }
  }

  @Override
  public DynamoDbClient buildSyncClient(final AwsCredentialsProvider credentialsProvider, final MetricPublisher metricPublisher) {
    return DynamoDbClient.builder()
        .region(Region.of(region()))
        .endpointOverride(endpointOverride())
        .credentialsProvider(credentialsProvider)
        .overrideConfiguration(ClientOverrideConfiguration.builder()
            .apiCallTimeout(clientExecutionTimeout())
            .apiCallAttemptTimeout(clientRequestTimeout())
            .addMetricPublisher(metricPublisher)
            .build())
        .httpClientBuilder(AwsCrtHttpClient.builder()
            .maxConcurrency(maxConnections()))
        .build();
  }

  @Override
  public DynamoDbAsyncClient buildAsyncClient(final AwsCredentialsProvider credentialsProvider, final MetricPublisher metricPublisher) {
    return DynamoDbAsyncClient.builder()
        .region(Region.of(region()))
        .endpointOverride(endpointOverride())
        .credentialsProvider(credentialsProvider)
        .overrideConfiguration(ClientOverrideConfiguration.builder()
            .apiCallTimeout(clientExecutionTimeout())
            .apiCallAttemptTimeout(clientRequestTimeout())
            .addMetricPublisher(metricPublisher)
            .build())
        .httpClientBuilder(NettyNioAsyncHttpClient.builder()
            .maxConcurrency(maxConnections()))
        .build();
  }
}
