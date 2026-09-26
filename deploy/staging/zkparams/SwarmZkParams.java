/*
 * Copyright 2026 BRS Holding (SWARM)
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * SWARM addition. Generates every set of zero-knowledge server parameters a SWARM Messenger
 * server needs, and prints both halves of each as padded base64 JSON.
 *
 * Run it with the shaded server jar on the classpath, which is where libsignal lives:
 *
 *   java -cp ../../service/target/TextSecureServer-<version>.jar SwarmZkParams.java
 *
 * WHY THIS EXISTS
 * ---------------------------------------------------------------------------------------
 * The server ships a `zkparams` command, but it only generates ServerSecretParams - the
 * zkgroup parameters that go in `groupsZkConfig`. Three other configuration blocks
 * (`chatZkConfig`, `callingZkConfig`, `callingZkConfigPreV101`) hold *GenericServerSecretParams*,
 * which is a different libsignal type with a different length; feeding them a ServerSecretParams
 * blob throws at startup, and nothing in the configuration check catches it.
 *
 * There is no upstream command for GenericServerSecretParams, so this calls
 * GenericServerSecretParams.generate() directly. It invents no cryptography: every value comes
 * from libsignal's own generator, seeded by libsignal's own RNG.
 *
 * Base64 is PADDED, unlike the server's `zkparams` command, because the server reads these
 * values as byte[] / SecretBytes and that deserializer rejects unpadded base64 with
 * "is of type: String, expected: byte[]".
 *
 * WHICH CLIENT-FACING NAME EACH SET MAPS TO
 * ---------------------------------------------------------------------------------------
 *   groups          -> the client's `serverPublicParams`        (zkgroup: groups, profiles, auth)
 *   chat            -> the client's `genericServerPublicParams` AND `backupServerPublicParams`
 *                      (in this upstream revision BackupAuthManager is constructed with
 *                      chatGenericZkSecretParams, so the two are the same value; see
 *                      WhisperServerService where backupAuthManager is built)
 *   calling         -> calling credentials, libsignal >= 0.101
 *   callingPreV101  -> calling credentials, older clients
 */

import java.security.SecureRandom;
import java.util.Base64;
import org.signal.libsignal.zkgroup.GenericServerSecretParams;
import org.signal.libsignal.zkgroup.ServerSecretParams;

public class SwarmZkParams {

  private static final Base64.Encoder B64 = Base64.getEncoder();

  public static void main(final String[] args) {
    final SecureRandom random = new SecureRandom();

    final ServerSecretParams groups = ServerSecretParams.generate(random);
    final GenericServerSecretParams chat = GenericServerSecretParams.generate(random);
    final GenericServerSecretParams calling = GenericServerSecretParams.generate(random);
    final GenericServerSecretParams callingPreV101 = GenericServerSecretParams.generate(random);

    final StringBuilder json = new StringBuilder(1024);
    json.append("{\n");
    entry(json, "groups", B64.encodeToString(groups.getPublicParams().serialize()),
        B64.encodeToString(groups.serialize()), true);
    entry(json, "chat", B64.encodeToString(chat.getPublicParams().serialize()),
        B64.encodeToString(chat.serialize()), true);
    entry(json, "calling", B64.encodeToString(calling.getPublicParams().serialize()),
        B64.encodeToString(calling.serialize()), true);
    entry(json, "callingPreV101", B64.encodeToString(callingPreV101.getPublicParams().serialize()),
        B64.encodeToString(callingPreV101.serialize()), false);
    json.append("}");

    System.out.println(json);
  }

  private static void entry(final StringBuilder json, final String name, final String publicParams,
      final String secretParams, final boolean comma) {
    json.append("  \"").append(name).append("\": {\"public\": \"").append(publicParams)
        .append("\", \"secret\": \"").append(secretParams).append("\"}")
        .append(comma ? ",\n" : "\n");
  }
}
