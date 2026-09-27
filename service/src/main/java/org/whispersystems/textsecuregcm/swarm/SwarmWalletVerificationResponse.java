/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - wallet sign-in
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.swarm;

import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import io.swagger.v3.oas.annotations.media.Schema;
import org.whispersystems.textsecuregcm.util.ByteArrayAdapter;

/**
 * The account identifier the identity key derives, and the password to register it with.
 * <p>
 * The client sends the password straight back as {@code POST /v1/registration}'s
 * {@code recoveryPassword} - which is what libsignal's own "re-register" call does with it - and then
 * forgets it. It is not a credential for anything else: it authorizes creating this one account, and
 * only together with prekeys signed by the identity key it was issued to.
 */
public record SwarmWalletVerificationResponse(
    @Schema(description = """
        The synthetic, non-dialable E.164-shaped account identifier derived from the identity key.
        Never shown to a user; the client uses it as the `number` for registration.
        """)
    String number,

    @Schema(description = "A base64-encoded, single-use registration password for that identifier.")
    @JsonSerialize(using = ByteArrayAdapter.Serializing.class)
    @JsonDeserialize(using = ByteArrayAdapter.Deserializing.class)
    byte[] registrationPassword) {
}
