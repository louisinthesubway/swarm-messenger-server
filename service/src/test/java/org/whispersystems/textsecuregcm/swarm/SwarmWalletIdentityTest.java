/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - wallet sign-in
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.swarm;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.google.i18n.phonenumbers.PhoneNumberUtil;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Base64;
import java.util.HashSet;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.signal.libsignal.protocol.IdentityKey;
import org.signal.libsignal.protocol.IdentityKeyPair;
import org.signal.libsignal.protocol.InvalidKeyException;
import org.signal.libsignal.protocol.ecc.ECPrivateKey;
import org.whispersystems.textsecuregcm.util.Util;

class SwarmWalletIdentityTest {

  /**
   * The desktop client derives the same identity key from the same recovery phrase, and the same
   * account identifier from that key. These vectors are the contract: the identical values appear in
   * the desktop's own test (ts/test-node/swarm/walletIdentity_test.node.ts). If a change here makes
   * this test fail, it makes every existing account unreachable.
   */
  private static final String IDENTITY_KEY_ALL_ZERO_ENTROPY =
      "BdUup/KTUWFdGc1rkQy8qqoAXARjDuW2b32p1STJMl5Y";
  private static final String E164_ALL_ZERO_ENTROPY = "+88810866442360";

  private static final String IDENTITY_KEY_COUNTING_ENTROPY =
      "BUOazbfLOeK5YwjvL8ASlC5sCw/d+FZZ+q6SUesG1kJw";
  private static final String E164_COUNTING_ENTROPY = "+88844571413476";

  private static final String IDENTITY_KEY_ALL_ONES_ENTROPY =
      "BQ6Pzj4KiojM/8GeHWZRfKPSaPVN6SDYaala/FDHmvUL";
  private static final String E164_ALL_ONES_ENTROPY = "+88834279664637";

  @Test
  void derivationMatchesTheClientsVectors() throws InvalidKeyException {
    assertEquals(E164_ALL_ZERO_ENTROPY, e164For(IDENTITY_KEY_ALL_ZERO_ENTROPY));
    assertEquals(E164_COUNTING_ENTROPY, e164For(IDENTITY_KEY_COUNTING_ENTROPY));
    assertEquals(E164_ALL_ONES_ENTROPY, e164For(IDENTITY_KEY_ALL_ONES_ENTROPY));
  }

  private static String e164For(final String base64IdentityKey) throws InvalidKeyException {
    return SwarmWalletIdentity.e164For(new IdentityKey(Base64.getDecoder().decode(base64IdentityKey)));
  }

  @Test
  void derivationIsAFunctionOfTheKeyAlone() {
    final IdentityKeyPair keyPair = IdentityKeyPair.generate();

    assertEquals(SwarmWalletIdentity.e164For(keyPair.getPublicKey()),
        SwarmWalletIdentity.e164For(keyPair.getPublicKey()));
    assertNotEquals(SwarmWalletIdentity.e164For(keyPair.getPublicKey()),
        SwarmWalletIdentity.e164For(IdentityKeyPair.generate().getPublicKey()));
  }

  /**
   * The point of the whole +888 choice: the server's own normalization has to accept what we derive.
   * {@link Util#requireNormalizedNumber} is what every registration number passes through.
   */
  @Test
  void derivedNumbersSurviveTheServersOwnValidation() {
    for (int i = 0; i < 256; i++) {
      final String number = SwarmWalletIdentity.e164For(IdentityKeyPair.generate().getPublicKey());

      assertDoesNotThrow(() -> Util.requireNormalizedNumber(number), number + " must be a normalized E.164");
      assertTrue(PhoneNumberUtil.getInstance().isPossibleNumber(number, null), number + " must be possible");
      assertTrue(SwarmWalletIdentity.isSwarmWalletNumber(number));
      assertEquals(SwarmWalletIdentity.E164_PREFIX.length() + SwarmWalletIdentity.NATIONAL_DIGITS, number.length());
      assertNotEquals('0', number.charAt(SwarmWalletIdentity.E164_PREFIX.length()),
          "a leading zero would not survive E.164 normalization");
    }
  }

  @Test
  void derivedNumbersAreSpreadOverTheWholeSpace() {
    final Set<String> numbers = new HashSet<>();

    for (int i = 0; i < 512; i++) {
      numbers.add(SwarmWalletIdentity.e164For(IdentityKeyPair.generate().getPublicKey()));
    }

    assertEquals(512, numbers.size(), "512 keys must derive 512 identifiers");
  }

  @ParameterizedTest
  @ValueSource(strings = {
      "+14155550123",         // an ordinary phone number
      "+8881854292138",       // ten digits: one short
      "+888185429213820",     // twelve digits: one long
      "+88808542921382",      // a leading zero
      "+8881854292138a",      // not a digit
      "888185429213820",      // no plus
      "+889185429213820",     // the wrong country code
      "",
  })
  void refusesWhatIsNotASwarmIdentifier(final String number) {
    assertFalse(SwarmWalletIdentity.isSwarmWalletNumber(number));
  }

  @Test
  void refusesNullAsAnIdentifier() {
    assertFalse(SwarmWalletIdentity.isSwarmWalletNumber(null));
  }

  @Test
  void signatureOverTheChallengeVerifies() {
    final IdentityKeyPair keyPair = IdentityKeyPair.generate();
    final byte[] challenge = challenge((byte) 0x11);

    final byte[] signature = keyPair.getPrivateKey()
        .calculateSignature(SwarmWalletIdentity.challengeMessage(keyPair.getPublicKey().serialize(), challenge));

    assertTrue(SwarmWalletIdentity.verifyChallengeSignature(keyPair.getPublicKey(), challenge, signature));
  }

  @Test
  void aSignatureForOneChallengeDoesNotAnswerAnother() {
    final IdentityKeyPair keyPair = IdentityKeyPair.generate();

    final byte[] signature = keyPair.getPrivateKey()
        .calculateSignature(SwarmWalletIdentity.challengeMessage(keyPair.getPublicKey().serialize(), challenge((byte) 0x11)));

    assertFalse(SwarmWalletIdentity.verifyChallengeSignature(keyPair.getPublicKey(), challenge((byte) 0x12), signature));
  }

  /**
   * The identity key is inside the signed message, so a signature harvested for one key cannot be
   * presented as a signature by another key - even one whose holder signed the same challenge bytes.
   */
  @Test
  void aSignatureForOneKeyDoesNotAnswerForAnother() {
    final byte[] challenge = challenge((byte) 0x11);
    final IdentityKeyPair victim = IdentityKeyPair.generate();
    final ECPrivateKey attackerPrivateKey = IdentityKeyPair.generate().getPrivateKey();

    // The attacker signs the message that names the victim's key, with their own key.
    final byte[] signature =
        attackerPrivateKey.calculateSignature(SwarmWalletIdentity.challengeMessage(victim.getPublicKey().serialize(), challenge));

    assertFalse(SwarmWalletIdentity.verifyChallengeSignature(victim.getPublicKey(), challenge, signature));
  }

  @Test
  void refusesAnEmptyOrAbsentSignature() {
    final IdentityKeyPair keyPair = IdentityKeyPair.generate();
    final byte[] challenge = challenge((byte) 0x11);

    assertFalse(SwarmWalletIdentity.verifyChallengeSignature(keyPair.getPublicKey(), challenge, null));
    assertFalse(SwarmWalletIdentity.verifyChallengeSignature(keyPair.getPublicKey(), challenge, new byte[0]));
    assertFalse(SwarmWalletIdentity.verifyChallengeSignature(keyPair.getPublicKey(), challenge, new byte[64]));
  }

  @Test
  void theSignedMessageIsExactlyWhatItSaysItIs() {
    final IdentityKeyPair keyPair = IdentityKeyPair.generate();
    final byte[] identityKey = keyPair.getPublicKey().serialize();
    final byte[] challenge = challenge((byte) 0x11);

    final byte[] prefix = "SWARM-Messenger-wallet-registration-v1".getBytes(StandardCharsets.UTF_8);
    final byte[] expected = new byte[prefix.length + identityKey.length + challenge.length];
    System.arraycopy(prefix, 0, expected, 0, prefix.length);
    System.arraycopy(identityKey, 0, expected, prefix.length, identityKey.length);
    System.arraycopy(challenge, 0, expected, prefix.length + identityKey.length, challenge.length);

    assertArrayEqualsAsBase64(expected, SwarmWalletIdentity.challengeMessage(identityKey, challenge));
  }

  @Test
  void refusesAMalformedChallengeOrKey() {
    final byte[] identityKey = IdentityKeyPair.generate().getPublicKey().serialize();

    assertThrows(IllegalArgumentException.class,
        () -> SwarmWalletIdentity.challengeMessage(identityKey, new byte[31]));
    assertThrows(IllegalArgumentException.class,
        () -> SwarmWalletIdentity.challengeMessage(identityKey, null));
    assertThrows(IllegalArgumentException.class,
        () -> SwarmWalletIdentity.challengeMessage(new byte[32], challenge((byte) 0x11)));
    assertThrows(IllegalArgumentException.class,
        () -> SwarmWalletIdentity.e164ForIdentityKeyBytes(new byte[32]));
  }

  @Test
  void aSwarmNumberOnlyBelongsToTheKeyThatDerivesIt() {
    final IdentityKey identityKey = IdentityKeyPair.generate().getPublicKey();
    final IdentityKey otherKey = IdentityKeyPair.generate().getPublicKey();

    assertDoesNotThrow(() ->
        SwarmWalletIdentity.requireIdentityMatchesNumber(SwarmWalletIdentity.e164For(identityKey), identityKey));

    assertThrows(MismatchedSwarmWalletIdentityException.class, () ->
        SwarmWalletIdentity.requireIdentityMatchesNumber(SwarmWalletIdentity.e164For(identityKey), otherKey));

    assertThrows(MismatchedSwarmWalletIdentityException.class, () ->
        SwarmWalletIdentity.requireIdentityMatchesNumber(SwarmWalletIdentity.e164For(identityKey), null));
  }

  @Test
  void anOrdinaryNumberIsNoneOfThisCheckSBusiness() {
    assertDoesNotThrow(() -> SwarmWalletIdentity.requireIdentityMatchesNumber("+14155550123",
        IdentityKeyPair.generate().getPublicKey()));
    assertDoesNotThrow(() -> SwarmWalletIdentity.requireIdentityMatchesNumber("+14155550123", null));
  }

  @Test
  void theStorageKeyIsDerivedAndHashTagged() {
    final byte[] identityKey = IdentityKeyPair.generate().getPublicKey().serialize();
    final String key = new String(SwarmWalletIdentity.challengeStorageKey(identityKey), StandardCharsets.UTF_8);

    assertTrue(key.startsWith("swarm_wallet_registration_challenge::{"), key);
    assertTrue(key.endsWith("}"), key);
    assertFalse(key.contains(Base64.getEncoder().encodeToString(identityKey)),
        "the identity key itself must not be the storage key");
    assertEquals(key, new String(SwarmWalletIdentity.challengeStorageKey(identityKey), StandardCharsets.UTF_8));
  }

  /**
   * A guard on the derivation itself, written out by hand rather than by calling the code under test:
   * +888, then the high eight bytes of SHA-256("SWARM-Messenger-e164-v1" || key) reduced into
   * [10^10, 10^11).
   */
  @Test
  void theDerivationIsTheOneDocumented() throws NoSuchAlgorithmException {
    final byte[] identityKey = IdentityKeyPair.generate().getPublicKey().serialize();

    final MessageDigest digest = MessageDigest.getInstance("SHA-256");
    digest.update("SWARM-Messenger-e164-v1".getBytes(StandardCharsets.UTF_8));
    digest.update(identityKey);
    final byte[] hash = digest.digest();

    long high = 0;
    for (int i = 0; i < 8; i++) {
      high = (high << 8) | (hash[i] & 0xFFL);
    }
    // Unsigned remainder, because the top bit of the first byte makes `high` negative half the time.
    final long national = Long.remainderUnsigned(high, 90_000_000_000L) + 10_000_000_000L;

    assertEquals("+888" + national, SwarmWalletIdentity.e164ForIdentityKeyBytes(identityKey));
  }

  private static byte[] challenge(final byte fill) {
    final byte[] challenge = new byte[SwarmWalletIdentity.CHALLENGE_LENGTH];
    java.util.Arrays.fill(challenge, fill);
    return challenge;
  }

  private static void assertArrayEqualsAsBase64(final byte[] expected, final byte[] actual) {
    assertEquals(Base64.getEncoder().encodeToString(expected), Base64.getEncoder().encodeToString(actual));
  }
}
