/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - wallet sign-in
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.swarm;

import io.micrometer.core.instrument.Metrics;
import io.micrometer.core.instrument.Tag;
import io.micrometer.core.instrument.Tags;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import jakarta.validation.Valid;
import jakarta.ws.rs.ClientErrorException;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.ServiceUnavailableException;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import java.security.SecureRandom;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletionException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import org.signal.libsignal.protocol.IdentityKey;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.whispersystems.textsecuregcm.controllers.RateLimitExceededException;
import org.whispersystems.textsecuregcm.limits.RateLimitedByIp;
import org.whispersystems.textsecuregcm.limits.RateLimiters;
import org.whispersystems.textsecuregcm.metrics.MetricsUtil;
import org.whispersystems.textsecuregcm.storage.Account;
import org.whispersystems.textsecuregcm.storage.AccountsManager;
import org.whispersystems.textsecuregcm.storage.PhoneNumberIdentifiers;
import org.whispersystems.textsecuregcm.storage.PhoneNumberRecoveryPasswordsManager;

/**
 * Registration without a telephone number: the SWARM wallet sign-in channel.
 * <p>
 * Two requests. The client asks for a challenge for its ACI identity public key, signs the challenge
 * with the matching private key - which it derived from the wallet recovery phrase and which never
 * leaves the device - and sends the signature back. In return it gets the synthetic account
 * identifier its key derives and a one-shot registration password for it. It then runs Signal's own,
 * entirely unmodified {@code POST /v1/registration} with that password, exactly as a client
 * re-registering with a registration recovery password does.
 * <p>
 * What stops this from being a way to take over somebody else's account:
 * <ul>
 *   <li>the identifier is derived from the identity public key, so a signature only ever buys a
 *       password for the signer's own account;</li>
 *   <li>the challenge is random, single-use ({@code GETDEL}) and lives about a minute;</li>
 *   <li>the signed message names the identity key, so a captured signature cannot be presented for a
 *       different key;</li>
 *   <li>{@code RegistrationController} refuses a SWARM identifier whose registration does not carry
 *       the identity key that derives it, and refuses to hand an existing SWARM account to a
 *       different identity key - and the registration's prekeys must be validly signed by that same
 *       identity key, which the password alone cannot fake.</li>
 * </ul>
 * Everything fails closed: any missing, malformed, expired or unverifiable input is a 4xx and leaves
 * no account and no password behind. See {@code docs/WALLET-SIGN-IN.md}.
 */
@Path("/v1/swarm/registration")
@io.swagger.v3.oas.annotations.tags.Tag(name = "SwarmWalletRegistration")
public class SwarmWalletRegistrationController {

  private static final Logger logger = LoggerFactory.getLogger(SwarmWalletRegistrationController.class);

  private static final String CHALLENGE_COUNTER_NAME =
      MetricsUtil.name(SwarmWalletRegistrationController.class, "challengeIssued");
  private static final String VERIFY_COUNTER_NAME =
      MetricsUtil.name(SwarmWalletRegistrationController.class, "challengeVerified");
  private static final String OUTCOME_TAG_NAME = "outcome";

  /** The registration password is 32 bytes; nothing but this server and the client ever sees one. */
  private static final int REGISTRATION_PASSWORD_LENGTH = 32;

  private static final long PNI_LOOKUP_TIMEOUT_SECONDS = 15;

  private static final SecureRandom SECURE_RANDOM = new SecureRandom();

  private final SwarmWalletChallengeStore challengeStore;
  private final PhoneNumberIdentifiers phoneNumberIdentifiers;
  private final PhoneNumberRecoveryPasswordsManager phoneNumberRecoveryPasswordsManager;
  private final AccountsManager accountsManager;
  private final RateLimiters rateLimiters;

  public SwarmWalletRegistrationController(final SwarmWalletChallengeStore challengeStore,
      final PhoneNumberIdentifiers phoneNumberIdentifiers,
      final PhoneNumberRecoveryPasswordsManager phoneNumberRecoveryPasswordsManager,
      final AccountsManager accountsManager,
      final RateLimiters rateLimiters) {

    this.challengeStore = challengeStore;
    this.phoneNumberIdentifiers = phoneNumberIdentifiers;
    this.phoneNumberRecoveryPasswordsManager = phoneNumberRecoveryPasswordsManager;
    this.accountsManager = accountsManager;
    this.rateLimiters = rateLimiters;
  }

  @POST
  @Path("/challenge")
  @Consumes(MediaType.APPLICATION_JSON)
  @Produces(MediaType.APPLICATION_JSON)
  @RateLimitedByIp(RateLimiters.For.SWARM_WALLET_CHALLENGE)
  @Operation(summary = "Ask for a registration challenge for a SWARM wallet identity key")
  @ApiResponse(responseCode = "200", description = "A challenge to sign with the identity private key")
  @ApiResponse(responseCode = "422", description = "The identity key was missing or malformed")
  @ApiResponse(responseCode = "429", description = "Too many challenges from this address")
  public SwarmWalletChallengeResponse createChallenge(@Valid final SwarmWalletChallengeRequest request) {
    final byte[] challenge = challengeStore.issue(request.identityKey().serialize());

    Metrics.counter(CHALLENGE_COUNTER_NAME).increment();

    return new SwarmWalletChallengeResponse(challenge, challengeStore.challengeTtl().toSeconds());
  }

  @POST
  @Path("/verify")
  @Consumes(MediaType.APPLICATION_JSON)
  @Produces(MediaType.APPLICATION_JSON)
  @RateLimitedByIp(RateLimiters.For.SWARM_WALLET_VERIFY)
  @Operation(summary = "Answer a registration challenge and receive a one-shot registration password")
  @ApiResponse(responseCode = "200", description = "The signature was good; register with this password")
  @ApiResponse(responseCode = "404", description = "No challenge is pending for this identity key")
  @ApiResponse(responseCode = "403", description = "The signature did not verify")
  @ApiResponse(responseCode = "409", description = "This identifier already belongs to another identity key")
  @ApiResponse(responseCode = "422", description = "The identity key or signature was malformed")
  @ApiResponse(responseCode = "429", description = "Too many attempts from this address")
  public SwarmWalletVerificationResponse verifyChallenge(@Valid final SwarmWalletVerificationRequest request)
      throws RateLimitExceededException {

    final IdentityKey identityKey = request.identityKey();
    final byte[] signature = request.signature();

    final byte[] challenge = challengeStore.consume(identityKey.serialize())
        .orElseThrow(() -> {
          countVerify("no-challenge");
          // Expired, already answered, or never issued: the client cannot tell them apart, and asks
          // for a new challenge either way.
          return new NotFoundException("no challenge is pending for this identity key");
        });

    if (!SwarmWalletIdentity.verifyChallengeSignature(identityKey, challenge, signature)) {
      countVerify("bad-signature");
      throw new WebApplicationException("the signature does not verify against this identity key",
          Response.Status.FORBIDDEN);
    }

    final String number = SwarmWalletIdentity.e164For(identityKey);

    // A number derives from a key, so an account on this number whose identity key is a different
    // one is a derivation collision, not a re-registration. Refuse rather than hand the account over.
    final Optional<Account> existingAccount = accountsManager.getByE164(number);
    if (existingAccount.isPresent() && !identityKey.equals(existingAccount.get().getAccountIdentityKey())) {
      countVerify("identifier-collision");
      logger.warn("SWARM account identifier collision on {}", number);
      throw new ClientErrorException("this account identifier already belongs to another identity key", 409);
    }

    rateLimiters.getRegistrationLimiter().validate(number);

    final byte[] registrationPassword = new byte[REGISTRATION_PASSWORD_LENGTH];
    SECURE_RANDOM.nextBytes(registrationPassword);

    final UUID phoneNumberIdentifier;
    try {
      phoneNumberIdentifier = phoneNumberIdentifiers.getPhoneNumberIdentifier(number)
          .get(PNI_LOOKUP_TIMEOUT_SECONDS, TimeUnit.SECONDS);
    } catch (final InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new ServiceUnavailableException("interrupted while assigning an identifier");
    } catch (final ExecutionException | CompletionException | TimeoutException e) {
      logger.error("Could not assign a phone number identifier for a SWARM account", e);
      throw new ServiceUnavailableException("could not assign an identifier");
    }

    phoneNumberRecoveryPasswordsManager.store(phoneNumberIdentifier, registrationPassword);

    countVerify("verified");

    return new SwarmWalletVerificationResponse(number, registrationPassword);
  }

  private static void countVerify(final String outcome) {
    Metrics.counter(VERIFY_COUNTER_NAME, Tags.of(Tag.of(OUTCOME_TAG_NAME, outcome))).increment();
  }
}
