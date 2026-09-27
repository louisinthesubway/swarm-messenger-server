/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - wallet sign-in
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.swarm;

import io.lettuce.core.SetArgs;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.Optional;
import javax.annotation.Nullable;
import org.whispersystems.textsecuregcm.redis.FaultTolerantRedisClusterClient;
import org.whispersystems.textsecuregcm.util.ResilienceUtil;

/**
 * The pending registration challenges, one per wallet identity key, in Redis.
 * <p>
 * Redis and not DynamoDB on purpose: a challenge lives for a minute or two, so a table with a TTL
 * sweeper would be the wrong instrument, and a new table would mean a new deployment step. This is
 * the same shape as {@code WebAuthnCeremonyManager}'s challenge storage, deliberately.
 * <p>
 * {@link #consume} is a {@code GETDEL}: a challenge answers exactly once, on exactly one server,
 * even if two requests race. {@link #issue} overwrites any challenge already pending for the same
 * identity key, so an abandoned attempt cannot be resumed once the client asks again.
 */
public class SwarmWalletChallengeStore {

  private static final SecureRandom SECURE_RANDOM = new SecureRandom();
  private static final String RETRY_NAME = ResilienceUtil.name(SwarmWalletChallengeStore.class);

  private final FaultTolerantRedisClusterClient challengeStorageCluster;
  private final Duration challengeTtl;

  public SwarmWalletChallengeStore(final FaultTolerantRedisClusterClient challengeStorageCluster,
      final Duration challengeTtl) {

    this.challengeStorageCluster = challengeStorageCluster;
    this.challengeTtl = challengeTtl;
  }

  /** How long an issued challenge stays answerable. */
  public Duration challengeTtl() {
    return challengeTtl;
  }

  /** A fresh challenge for this identity key, replacing any challenge it already had. */
  public byte[] issue(final byte[] serializedIdentityKey) {
    final byte[] challenge = new byte[SwarmWalletIdentity.CHALLENGE_LENGTH];
    SECURE_RANDOM.nextBytes(challenge);

    final byte[] key = SwarmWalletIdentity.challengeStorageKey(serializedIdentityKey);

    ResilienceUtil.getGeneralRedisRetry(RETRY_NAME)
        .executeRunnable(() -> challengeStorageCluster.withBinaryCluster(
            cluster -> cluster.sync().set(key, challenge, SetArgs.Builder.ex(challengeTtl.toSeconds()))));

    return challenge;
  }

  /**
   * The challenge pending for this identity key, removing it in the same operation.
   *
   * @return the challenge, or empty when none is pending - which is what an expired, already
   *         answered, or never issued challenge looks like. The caller must not tell them apart for
   *         the client.
   */
  public Optional<byte[]> consume(final byte[] serializedIdentityKey) {
    final byte[] key = SwarmWalletIdentity.challengeStorageKey(serializedIdentityKey);

    @Nullable final byte[] challenge = ResilienceUtil.getGeneralRedisRetry(RETRY_NAME)
        .executeSupplier(() -> challengeStorageCluster.withBinaryCluster(cluster -> cluster.sync().getdel(key)));

    return Optional.ofNullable(challenge);
  }
}
