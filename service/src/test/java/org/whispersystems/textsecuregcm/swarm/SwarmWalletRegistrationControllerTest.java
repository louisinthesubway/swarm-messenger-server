/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - wallet sign-in
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.swarm;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import io.dropwizard.testing.junit5.DropwizardExtensionsSupport;
import io.dropwizard.testing.junit5.ResourceExtension;
import jakarta.ws.rs.client.Entity;
import jakarta.ws.rs.core.Response;
import java.time.Duration;
import java.util.Arrays;
import java.util.Base64;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import org.glassfish.jersey.test.grizzly.GrizzlyWebTestContainerFactory;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.signal.libsignal.protocol.IdentityKeyPair;
import org.whispersystems.textsecuregcm.controllers.RateLimitExceededException;
import org.whispersystems.textsecuregcm.limits.RateLimiter;
import org.whispersystems.textsecuregcm.limits.RateLimiters;
import org.whispersystems.textsecuregcm.mappers.RateLimitExceededExceptionMapper;
import org.whispersystems.textsecuregcm.storage.Account;
import org.whispersystems.textsecuregcm.storage.AccountsManager;
import org.whispersystems.textsecuregcm.storage.PhoneNumberIdentifiers;
import org.whispersystems.textsecuregcm.storage.PhoneNumberRecoveryPasswordsManager;
import org.whispersystems.textsecuregcm.util.SystemMapper;

@ExtendWith(DropwizardExtensionsSupport.class)
class SwarmWalletRegistrationControllerTest {

  private static final UUID PNI = UUID.randomUUID();

  private final SwarmWalletChallengeStore challengeStore = mock(SwarmWalletChallengeStore.class);
  private final PhoneNumberIdentifiers phoneNumberIdentifiers = mock(PhoneNumberIdentifiers.class);
  private final PhoneNumberRecoveryPasswordsManager phoneNumberRecoveryPasswordsManager =
      mock(PhoneNumberRecoveryPasswordsManager.class);
  private final AccountsManager accountsManager = mock(AccountsManager.class);
  private final RateLimiters rateLimiters = mock(RateLimiters.class);
  private final RateLimiter registrationLimiter = mock(RateLimiter.class);

  private final ResourceExtension resources = ResourceExtension.builder()
      .addProvider(new RateLimitExceededExceptionMapper())
      .setMapper(SystemMapper.jsonMapper())
      .setTestContainerFactory(new GrizzlyWebTestContainerFactory())
      .addResource(new SwarmWalletRegistrationController(challengeStore, phoneNumberIdentifiers,
          phoneNumberRecoveryPasswordsManager, accountsManager, rateLimiters))
      .build();

  private final IdentityKeyPair keyPair = IdentityKeyPair.generate();
  private final byte[] challenge = challengeBytes((byte) 0x2a);

  @BeforeEach
  void setUp() {
    when(rateLimiters.getRegistrationLimiter()).thenReturn(registrationLimiter);
    when(challengeStore.challengeTtl()).thenReturn(Duration.ofMinutes(2));
    when(challengeStore.issue(any())).thenReturn(challenge);
    when(challengeStore.consume(any())).thenReturn(Optional.of(challenge));
    when(phoneNumberIdentifiers.getPhoneNumberIdentifier(any()))
        .thenReturn(CompletableFuture.completedFuture(PNI));
    when(accountsManager.getByE164(any())).thenReturn(Optional.empty());
  }

  @Test
  void issuesAChallengeForAnIdentityKey() {
    try (final Response response = resources.getJerseyTest()
        .target("/v1/swarm/registration/challenge")
        .request()
        .post(Entity.json(Map.of("identityKey", base64(keyPair.getPublicKey().serialize()))))) {

      assertEquals(200, response.getStatus());

      final SwarmWalletChallengeResponse body = response.readEntity(SwarmWalletChallengeResponse.class);
      assertArrayEquals(challenge, body.challenge());
      assertEquals(120, body.ttlSeconds());
    }

    verify(challengeStore).issue(keyPair.getPublicKey().serialize());
  }

  @Test
  void refusesAChallengeRequestWithoutAKey() {
    try (final Response response = resources.getJerseyTest()
        .target("/v1/swarm/registration/challenge")
        .request()
        .post(Entity.json(Map.of()))) {

      assertEquals(422, response.getStatus());
    }

    verify(challengeStore, never()).issue(any());
  }

  @Test
  void refusesAChallengeRequestWithAMalformedKey() {
    try (final Response response = resources.getJerseyTest()
        .target("/v1/swarm/registration/challenge")
        .request()
        .post(Entity.json(Map.of("identityKey", base64(new byte[32]))))) {

      assertEquals(400, response.getStatus());
    }

    verify(challengeStore, never()).issue(any());
  }

  @Test
  void handsOutARegistrationPasswordForAGoodSignature() throws RateLimitExceededException {
    final byte[] registrationPassword;

    try (final Response response = postVerify(signature(challenge))) {
      assertEquals(200, response.getStatus());

      final SwarmWalletVerificationResponse body = response.readEntity(SwarmWalletVerificationResponse.class);

      assertEquals(SwarmWalletIdentity.e164For(keyPair.getPublicKey()), body.number(),
          "the number the client is told must be the number its key derives");
      assertEquals(32, body.registrationPassword().length);
      registrationPassword = body.registrationPassword();
    }

    verify(challengeStore).consume(keyPair.getPublicKey().serialize());
    verify(phoneNumberIdentifiers).getPhoneNumberIdentifier(SwarmWalletIdentity.e164For(keyPair.getPublicKey()));
    verify(phoneNumberRecoveryPasswordsManager).store(eq(PNI), eq(registrationPassword));
    verify(registrationLimiter).validate(SwarmWalletIdentity.e164For(keyPair.getPublicKey()));
  }

  @Test
  void refusesASignatureWhenNoChallengeIsPending() {
    when(challengeStore.consume(any())).thenReturn(Optional.empty());

    try (final Response response = postVerify(signature(challenge))) {
      assertEquals(404, response.getStatus());
    }

    verify(phoneNumberRecoveryPasswordsManager, never()).store(any(), any());
  }

  @Test
  void refusesASignatureOverTheWrongChallenge() {
    try (final Response response = postVerify(signature(challengeBytes((byte) 0x2b)))) {
      assertEquals(403, response.getStatus());
    }

    verify(phoneNumberRecoveryPasswordsManager, never()).store(any(), any());
  }

  @Test
  void refusesASignatureFromAnotherKey() {
    final IdentityKeyPair otherKeyPair = IdentityKeyPair.generate();

    final byte[] forged = otherKeyPair.getPrivateKey().calculateSignature(
        SwarmWalletIdentity.challengeMessage(keyPair.getPublicKey().serialize(), challenge));

    try (final Response response = postVerify(forged)) {
      assertEquals(403, response.getStatus());
    }

    verify(phoneNumberRecoveryPasswordsManager, never()).store(any(), any());
  }

  @Test
  void refusesAVerificationWithoutASignature() {
    try (final Response response = resources.getJerseyTest()
        .target("/v1/swarm/registration/verify")
        .request()
        .post(Entity.json(Map.of("identityKey", base64(keyPair.getPublicKey().serialize()))))) {

      assertEquals(422, response.getStatus());
    }

    verify(challengeStore, never()).consume(any());
  }

  /** Re-registering the same wallet on a new machine: the account is its own, so this is allowed. */
  @Test
  void allowsTheSameIdentityKeyToClaimItsOwnExistingAccount() {
    final Account account = mock(Account.class);
    when(account.getAccountIdentityKey()).thenReturn(keyPair.getPublicKey());
    when(accountsManager.getByE164(any())).thenReturn(Optional.of(account));

    try (final Response response = postVerify(signature(challenge))) {
      assertEquals(200, response.getStatus());
    }

    verify(phoneNumberRecoveryPasswordsManager).store(eq(PNI), any());
  }

  /** Two wallets deriving one identifier. The second one is refused rather than served. */
  @Test
  void refusesAnIdentifierThatBelongsToAnotherIdentityKey() {
    final Account account = mock(Account.class);
    when(account.getAccountIdentityKey()).thenReturn(IdentityKeyPair.generate().getPublicKey());
    when(accountsManager.getByE164(any())).thenReturn(Optional.of(account));

    try (final Response response = postVerify(signature(challenge))) {
      assertEquals(409, response.getStatus());
    }

    verify(phoneNumberRecoveryPasswordsManager, never()).store(any(), any());
  }

  private Response postVerify(final byte[] signature) {
    return resources.getJerseyTest()
        .target("/v1/swarm/registration/verify")
        .request()
        .post(Entity.json(Map.of(
            "identityKey", base64(keyPair.getPublicKey().serialize()),
            "signature", base64(signature))));
  }

  private byte[] signature(final byte[] overChallenge) {
    return keyPair.getPrivateKey().calculateSignature(
        SwarmWalletIdentity.challengeMessage(keyPair.getPublicKey().serialize(), overChallenge));
  }

  private static byte[] challengeBytes(final byte fill) {
    final byte[] bytes = new byte[SwarmWalletIdentity.CHALLENGE_LENGTH];
    Arrays.fill(bytes, fill);
    return bytes;
  }

  private static String base64(final byte[] bytes) {
    return Base64.getEncoder().encodeToString(bytes);
  }
}
