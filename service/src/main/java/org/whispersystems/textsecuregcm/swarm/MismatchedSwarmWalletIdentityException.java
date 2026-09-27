/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - wallet sign-in
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.swarm;

/**
 * Thrown when a registration presents a SWARM account identifier together with an ACI identity key
 * that does not derive it. Checked, not runtime, so that every call site has to decide what to do.
 */
public class MismatchedSwarmWalletIdentityException extends Exception {

  public MismatchedSwarmWalletIdentityException(final String message) {
    super(message);
  }
}
