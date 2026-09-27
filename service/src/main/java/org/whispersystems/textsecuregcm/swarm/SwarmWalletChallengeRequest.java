/*
 * Copyright 2026 Signal Messenger, LLC
 * Copyright 2026 BRS Holding (SWARM) - wallet sign-in
 * SPDX-License-Identifier: AGPL-3.0-only
 */

package org.whispersystems.textsecuregcm.swarm;

import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import io.swagger.v3.oas.annotations.media.Schema;
import jakarta.validation.constraints.NotNull;
import org.signal.libsignal.protocol.IdentityKey;
import org.whispersystems.textsecuregcm.util.IdentityKeyAdapter;

/** "Here is my ACI identity public key; give me something to sign with it." */
public record SwarmWalletChallengeRequest(
    @Schema(requiredMode = Schema.RequiredMode.REQUIRED, description = """
        The ACI identity public key the client derived from its SWARM wallet recovery phrase, as a
        base64-encoded, 33-byte serialized Curve25519 public key.
        """)
    @JsonSerialize(using = IdentityKeyAdapter.Serializer.class)
    @JsonDeserialize(using = IdentityKeyAdapter.Deserializer.class)
    @NotNull
    IdentityKey identityKey) {
}
