/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - wallet sign-in
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.swarm;

import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import org.signal.libsignal.protocol.IdentityKey;
import org.whispersystems.textsecuregcm.util.ByteArrayAdapter;
import org.whispersystems.textsecuregcm.util.IdentityKeyAdapter;

/** "Here is my signature over the challenge you gave this identity key." */
public record SwarmWalletVerificationRequest(
    @Schema(requiredMode = Schema.RequiredMode.REQUIRED, description = """
        The same ACI identity public key the challenge was issued for, base64-encoded.
        """)
    @JsonSerialize(using = IdentityKeyAdapter.Serializer.class)
    @JsonDeserialize(using = IdentityKeyAdapter.Deserializer.class)
    @NotNull
    IdentityKey identityKey,

    @Schema(requiredMode = Schema.RequiredMode.REQUIRED, description = """
        The identity private key's signature, base64-encoded, over
        "SWARM-Messenger-wallet-registration-v1" || identityKey || challenge.
        """)
    @JsonSerialize(using = ByteArrayAdapter.Serializing.class)
    @JsonDeserialize(using = ByteArrayAdapter.Deserializing.class)
    @NotEmpty
    byte[] signature) {
}
