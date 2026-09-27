/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - wallet sign-in
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.swarm;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import org.signal.libsignal.protocol.IdentityKey;

/**
 * The rules that tie a SWARM Messenger account to a SWARM wallet identity key, and nothing else.
 * <p>
 * A SWARM account has no phone number. The client derives its ACI identity key pair from its wallet
 * recovery phrase (see {@code docs/WALLET-SIGN-IN.md}) and this class derives, from that identity
 * <em>public</em> key alone, the synthetic E.164-shaped identifier the account is keyed by. The
 * identifier is a pure function of the public key, so:
 * <ul>
 *   <li>restoring the recovery phrase on another machine lands on the same account, and</li>
 *   <li>the server can check, statelessly, that whoever is registering a SWARM number holds the
 *       identity key that number belongs to ({@link #requireIdentityMatchesNumber}).</li>
 * </ul>
 * Nothing here is a new cryptographic primitive: SHA-256 for the derivation, and libsignal's own
 * XEdDSA verification for the challenge signature.
 * <p>
 * <strong>No screen ever shows this number.</strong> It exists so that Signal's account model
 * (accounts, PNIs, devices, every downstream lookup) keeps working unchanged.
 */
public final class SwarmWalletIdentity {

  /**
   * ITU-T E.164 calling code 888, "Telecommunications for Disaster Relief". It is non-geographic
   * (libphonenumber reports region "001"), no operator assigns subscriber numbers under it, and
   * nothing under it is dialable from a telephone network. It was chosen because
   * {@code PhoneNumberUtil.isPossibleNumber} - the only check Signal's
   * {@code Util.requireNormalizedNumber} applies to a non-geographic code - accepts exactly
   * {@value #NATIONAL_DIGITS} national digits under it, and the E.164 formatting of such a number is
   * the number itself, so the server's own normalization refuses nothing.
   */
  public static final String COUNTRY_CODE = "888";

  /** {@code "+888"}. Every SWARM account's number starts with this and nothing else does. */
  public static final String E164_PREFIX = "+" + COUNTRY_CODE;

  /** How many digits follow {@link #E164_PREFIX}. Fixed by libphonenumber's metadata for +888. */
  public static final int NATIONAL_DIGITS = 11;

  /** The smallest national number with {@link #NATIONAL_DIGITS} digits: no leading zero, ever. */
  private static final BigInteger NATIONAL_FLOOR = BigInteger.TEN.pow(NATIONAL_DIGITS - 1);

  /** How many distinct numbers exist: 9 * 10^10, about 2^36.4. See the collision note below. */
  private static final BigInteger NATIONAL_SPACE = BigInteger.valueOf(9).multiply(NATIONAL_FLOOR);

  /** Domain separation for the number derivation. Changing this string changes every account. */
  private static final byte[] E164_INFO = "SWARM-Messenger-e164-v1".getBytes(StandardCharsets.UTF_8);

  /** Domain separation for what the client signs with its identity key. */
  private static final byte[] CHALLENGE_INFO =
      "SWARM-Messenger-wallet-registration-v1".getBytes(StandardCharsets.UTF_8);

  /** The length of a registration challenge, in bytes. */
  public static final int CHALLENGE_LENGTH = 32;

  /** A serialized Curve25519 identity public key: one type byte and 32 key bytes. */
  public static final int IDENTITY_KEY_LENGTH = 33;

  private SwarmWalletIdentity() {
  }

  /**
   * The synthetic E.164-shaped identifier for an identity key.
   * <p>
   * {@code +888} followed by {@code 10^10 + (first 8 bytes of SHA-256(info || key) mod 9*10^10)}.
   * The floor removes the leading zero that would make the result fail the server's own E.164
   * normalization; the space is therefore 9*10^10 numbers, about 2^36.4.
   * <p>
   * <strong>Collisions.</strong> Two different wallets can land on the same number. The birthday
   * bound puts that at roughly one chance in a thousand at ten thousand accounts and a few percent
   * at a hundred thousand. It is not a security problem - the identity key, not the number, is the
   * account's identity, and a colliding second wallet simply cannot register (the server refuses,
   * because the number's existing account holds a different identity key). It is a capacity problem,
   * and it is one of the reasons phase 2 removes the number entirely.
   */
  public static String e164For(final IdentityKey identityKey) {
    return e164ForIdentityKeyBytes(identityKey.serialize());
  }

  /** {@link #e164For} over the 33-byte serialized form. */
  public static String e164ForIdentityKeyBytes(final byte[] serializedIdentityKey) {
    if (serializedIdentityKey == null || serializedIdentityKey.length != IDENTITY_KEY_LENGTH) {
      throw new IllegalArgumentException("a serialized identity key is " + IDENTITY_KEY_LENGTH + " bytes");
    }

    final byte[] digest = sha256(E164_INFO, serializedIdentityKey);

    // The high 8 bytes, unsigned: the leading zero byte keeps BigInteger from reading a sign bit.
    final byte[] unsignedHigh64 = new byte[9];
    System.arraycopy(digest, 0, unsignedHigh64, 1, 8);

    final BigInteger national = new BigInteger(unsignedHigh64)
        .mod(NATIONAL_SPACE)
        .add(NATIONAL_FLOOR);

    return E164_PREFIX + national;
  }

  /**
   * Whether a number is shaped like a SWARM wallet account's number. Shape only: it says nothing
   * about which identity key the number belongs to.
   */
  public static boolean isSwarmWalletNumber(final String number) {
    if (number == null || number.length() != E164_PREFIX.length() + NATIONAL_DIGITS) {
      return false;
    }
    if (!number.startsWith(E164_PREFIX)) {
      return false;
    }
    for (int i = E164_PREFIX.length(); i < number.length(); i++) {
      if (number.charAt(i) < '0' || number.charAt(i) > '9') {
        return false;
      }
    }
    // A leading zero could never be produced by e164For and would not survive E.164 normalization.
    return number.charAt(E164_PREFIX.length()) != '0';
  }

  /**
   * What a client must sign with its ACI identity private key to prove it holds it:
   * {@code "SWARM-Messenger-wallet-registration-v1" || identityKey || challenge}.
   * <p>
   * The identity key is inside the signed message as well as outside it so that a signature
   * harvested for one key can never be replayed as a signature for another.
   */
  public static byte[] challengeMessage(final byte[] serializedIdentityKey, final byte[] challenge) {
    if (serializedIdentityKey == null || serializedIdentityKey.length != IDENTITY_KEY_LENGTH) {
      throw new IllegalArgumentException("a serialized identity key is " + IDENTITY_KEY_LENGTH + " bytes");
    }
    if (challenge == null || challenge.length != CHALLENGE_LENGTH) {
      throw new IllegalArgumentException("a challenge is " + CHALLENGE_LENGTH + " bytes");
    }

    final byte[] message = new byte[CHALLENGE_INFO.length + serializedIdentityKey.length + challenge.length];
    System.arraycopy(CHALLENGE_INFO, 0, message, 0, CHALLENGE_INFO.length);
    System.arraycopy(serializedIdentityKey, 0, message, CHALLENGE_INFO.length, serializedIdentityKey.length);
    System.arraycopy(challenge, 0, message, CHALLENGE_INFO.length + serializedIdentityKey.length, challenge.length);

    return message;
  }

  /** Whether {@code signature} is the identity key's signature over {@link #challengeMessage}. */
  public static boolean verifyChallengeSignature(final IdentityKey identityKey,
      final byte[] challenge,
      final byte[] signature) {

    if (signature == null || signature.length == 0) {
      return false;
    }

    return identityKey.getPublicKey()
        .verifySignature(challengeMessage(identityKey.serialize(), challenge), signature);
  }

  /**
   * The stateless half of the registration check: a SWARM number may only be registered by the
   * identity key it was derived from, and a SWARM identity key may only register its own number.
   *
   * @throws MismatchedSwarmWalletIdentityException if the number is a SWARM number and the key does
   *                                                not derive it
   */
  public static void requireIdentityMatchesNumber(final String number, final IdentityKey aciIdentityKey)
      throws MismatchedSwarmWalletIdentityException {

    if (!isSwarmWalletNumber(number)) {
      return;
    }
    if (aciIdentityKey == null) {
      throw new MismatchedSwarmWalletIdentityException("a SWARM account number needs an ACI identity key");
    }
    if (!number.equals(e164For(aciIdentityKey))) {
      throw new MismatchedSwarmWalletIdentityException(
          "the ACI identity key in this registration does not derive this account identifier");
    }
  }

  /** The Redis key a pending challenge for this identity key is stored under. */
  static byte[] challengeStorageKey(final byte[] serializedIdentityKey) {
    // Hashed, so the stored key material is not the identity key itself, and hash-tagged with
    // {...} so that a cluster keeps every key of one registration on one slot.
    final byte[] digest = sha256("SWARM-Messenger-challenge-key-v1".getBytes(StandardCharsets.UTF_8),
        serializedIdentityKey);

    return ("swarm_wallet_registration_challenge::{" + hex(Arrays.copyOf(digest, 16)) + "}")
        .getBytes(StandardCharsets.UTF_8);
  }

  private static byte[] sha256(final byte[] info, final byte[] body) {
    try {
      final MessageDigest digest = MessageDigest.getInstance("SHA-256");
      digest.update(info);
      digest.update(body);
      return digest.digest();
    } catch (final NoSuchAlgorithmException e) {
      throw new AssertionError("Every JVM has SHA-256", e);
    }
  }

  private static String hex(final byte[] bytes) {
    final StringBuilder builder = new StringBuilder(bytes.length * 2);
    for (final byte b : bytes) {
      builder.append(Character.forDigit((b >> 4) & 0xF, 16)).append(Character.forDigit(b & 0xF, 16));
    }
    return builder.toString();
  }
}
