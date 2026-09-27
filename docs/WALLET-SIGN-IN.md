# Wallet sign-in: registration without a telephone number (server side)

**Status: implemented, wave 1.** Written 2026-09-27 by Opus M-F against `swarm-main`. The desktop half
of the same protocol is documented in `Swarm-Official/swarm-messenger`, `docs/WALLET-SIGN-IN.md`.

The owner's decision, 2026-09-27: *"instead of a phone number make the users sign in with our
wallet."* This document is what that means on the server, why it is shaped this way, what it is safe
against, and what phase 2 removes.

---

## 1. What changed, in one paragraph

A SWARM account is not keyed by a telephone number any more. The client derives its Signal ACI
identity key pair from its SWARM wallet recovery phrase; the server derives, from that identity
*public* key, a synthetic E.164-shaped identifier in the non-dialable `+888` range and keys the
account by that. To register, the client proves it holds the identity private key — one challenge,
one signature — and receives a single-use registration password for its own identifier. It then runs
Signal's own, **unmodified** `POST /v1/registration` with that password. No SMS, no captcha, no
registration service, no new cryptography, and no change to libsignal.

---

## 2. The protocol

```
client                                                                server
  |                                                                     |
  |  identity = HKDF(bip39_seed(recovery phrase), "…ACI-identity-v1")    |
  |                                                                     |
  |-- POST /v1/swarm/registration/challenge ---------------------------->|
  |     { "identityKey": base64(33 bytes) }                             |  SET <key> <32 random bytes> EX 120
  |<-- 200 { "challenge": base64(32), "ttlSeconds": 120 } --------------|
  |                                                                     |
  |  signature = Ed25519(identityPrivate,                               |
  |      "SWARM-Messenger-wallet-registration-v1" || identityKey        |
  |                                             || challenge)           |
  |                                                                     |
  |-- POST /v1/swarm/registration/verify ------------------------------->|  GETDEL <key>   (single use)
  |     { "identityKey": …, "signature": base64 }                       |  verify signature
  |                                                                     |  number = derive(identityKey)
  |                                                                     |  store registration password for its PNI
  |<-- 200 { "number": "+888…", "registrationPassword": base64(32) } ---|
  |                                                                     |
  |-- POST /v1/registration  (Signal's own endpoint, unchanged) -------->|  recovery-password path,
  |     { "recoveryPassword": …, "aciIdentityKey": …, prekeys, … }      |  plus the SWARM binding checks
  |<-- 200 { "uuid": …, "pni": …, … } ---------------------------------|
```

The last request is the one libsignal already makes for a client re-registering with a registration
recovery password: `RegistrationService.reregisterAccount(…)` on the desktop, which sends a top-level
`recoveryPassword` instead of a `sessionId`
(`rust/net/chat/src/ws/registration/request.rs`, `SessionValidation::RecoveryPassword`). That is the
whole reason no libsignal change was needed, and why the staging gRPC registration stub is not
involved in this path at all.

### The derivations

| What | How |
|---|---|
| BIP-39 seed | PBKDF2-HMAC-SHA512(NFKD(phrase), "mnemonic", 2048, 64 bytes) — BIP-39 as specified |
| ACI identity key | `HKDF-SHA256(seed, info="SWARM-Messenger-ACI-identity-v1", 32 bytes)`, X25519-clamped |
| PNI identity key | the same with `info="SWARM-Messenger-PNI-identity-v1"` |
| account identifier | `+888` then `10^10 + (high 8 bytes of SHA-256("SWARM-Messenger-e164-v1" ‖ identityKey) mod 9·10^10)` |
| signed challenge message | `"SWARM-Messenger-wallet-registration-v1" ‖ identityKey(33) ‖ challenge(32)` |

The identifier derivation lives in
`service/src/main/java/org/whispersystems/textsecuregcm/swarm/SwarmWalletIdentity.java` and in the
desktop's `ts/util/swarm/walletIdentity.node.ts`. **The two must stay byte-for-byte equivalent**: both
test suites carry the same three vectors (derived from all-zero, counting, and all-ones entropy), so a
change on one side fails on both. Changing any label above makes every existing account unreachable.

### Why `+888`

Signal's account model wants an E.164 everywhere: accounts, PNIs, devices, change-number, every
lookup. Rather than tear that out — a change far too large to test in a day — a SWARM account gets an
identifier *shaped* like an E.164 that no telephone network can route.

ITU-T calling code 888 ("Telecommunications for Disaster Relief") is non-geographic, so
libphonenumber reports region `001`, and `Util.requireNormalizedNumber` — the only validation a
registration number passes — takes its lenient branch for `001` and never asks whether the number is
*valid for a region*, only whether it is *possible*. Eleven national digits is what libphonenumber
considers possible under `+888`; eight is what `+800` allows, twelve what `+882`/`+883` allow. The
test `derivedNumbersSurviveTheServersOwnValidation` proves 256 freshly derived identifiers pass
`requireNormalizedNumber` and `isPossibleNumber`, which is the property the whole choice rests on.

**No screen ever shows this identifier.** Users are found by username (Signal's usernames work
already) and, from wave 2, by SWARM wallet address.

### Collisions, honestly

The identifier space is 9·10^10, about 2^36.4. Two different wallets can derive the same identifier:
roughly one chance in a thousand by ten thousand accounts, a few percent by a hundred thousand. This
is not a security property — the identity key is the account's identity — but it has to be handled,
and it is, in two places:

* `/v1/swarm/registration/verify` returns **409** if an account already exists on the derived
  identifier with a different ACI identity key, and stores no password;
* `RegistrationController` refuses the same case with **409** even if a password was somehow obtained.

The loser of a collision cannot register and must create a new wallet. Phase 2 (accounts with no
number at all — the server already has `AccountsManager.create(accountAttributes, aciIdentityKey,
receiptCredentialPresentation, …)` for the no-number case) removes this entirely.

---

## 3. What stops an account being stolen

Four independent things, each of which alone is enough to make the others' failure survivable:

1. **The identifier is derived from the public key.** A signature therefore only ever buys a password
   for the signer's own account. There is no request that yields a password for somebody else's
   identifier.
2. **The challenge is random, short-lived and single-use.** 32 bytes from `SecureRandom`, TTL two
   minutes, consumed with Redis `GETDEL`, so two racing requests cannot both spend it, on one server
   or ten. Asking again replaces any pending challenge.
3. **The identity key is inside the signed message.** A signature captured for key A cannot be
   presented as a signature by key B. Tested both ways.
4. **The registration itself must be signed by the same key.** `POST /v1/registration` carries an
   `aciIdentityKey`, which must derive the identifier being registered (new check), *and* prekeys
   whose signatures Signal already verifies against that key (`PreKeySignatureValidator`). A leaked
   registration password with no private key can therefore register nothing.

Everything fails closed. A missing, malformed, expired, already-answered or unverifiable input is a
4xx that leaves no account and no stored password. Both endpoints are rate-limited by IP
(`swarmWalletChallenge`: 20/minute; `swarmWalletVerify`: 6/minute) and the verify path additionally
takes Signal's own per-number `registration` limiter.

### What the server learns, and what it does not

The server learns an account's ACI identity public key — which it learns in ordinary Signal
registration too — and nothing else about the wallet. It never sees the recovery phrase, the seed, any
spending or viewing key, any wallet address, or any balance. The wallet talks to
`lwd-main.swarm.green`, never to the chat server.

What is *new* relative to Signal: the identity key now doubles as the account's name, so the server
can link "this account" to "this wallet identity key" permanently, and two devices restored from one
phrase are, correctly, the same account. Wave 2 adds address-hash lookup, which lets the server learn
that a *queried* address hash belongs to an account; that trade-off is documented with that feature,
and phase 2's blinded lookup removes it.

---

## 4. The code

New, all under `service/src/main/java/org/whispersystems/textsecuregcm/swarm/`:

| File | What |
|---|---|
| `SwarmWalletIdentity.java` | the derivations, the shape check, the challenge message, signature verification, the binding check. Pure functions, no state, no I/O. |
| `SwarmWalletChallengeStore.java` | pending challenges in Redis (`rateLimitersCluster`), `SET … EX` / `GETDEL`, the same shape as `WebAuthnCeremonyManager` |
| `SwarmWalletRegistrationController.java` | `POST /v1/swarm/registration/challenge`, `POST /v1/swarm/registration/verify` |
| `SwarmWalletChallengeRequest/Response`, `SwarmWalletVerificationRequest/Response` | the four DTOs |
| `MismatchedSwarmWalletIdentityException.java` | thrown by the binding check |

Changed — four files, small diffs, each commented `SWARM addition (wallet sign-in)`:

| File | Change |
|---|---|
| `controllers/RegistrationController.java` | a SWARM identifier may only be registered by the key that derives it (403); an existing SWARM account may not be handed to a different key (409) |
| `controllers/VerificationController.java` | refuse a SWARM identifier in `POST /v1/verification/session` (400): no SMS can reach it |
| `limits/RateLimiters.java` | two new limiters |
| `WhisperServerService.java` | construct and register the controller; the two-minute challenge TTL |

**No new DynamoDB table**, so no change to `deploy/staging/dynamodb/bootstrap-tables.sh`. **No config
key**, so no change to `staging.yml` or `.env`. Deploying this is rebuilding the image and restarting
the `chat` container, and nothing else.

---

## 5. Tests

```
./mvnw -o -pl service -am test -Dtest='SwarmWalletIdentityTest,SwarmWalletRegistrationControllerTest'
```

* `SwarmWalletIdentityTest` — 23 tests: the client's three derivation vectors; determinism; 256
  derived identifiers passing `Util.requireNormalizedNumber` and `isPossibleNumber`; 512 distinct
  identifiers from 512 keys; eight kinds of non-identifier refused; signature verifies; a signature
  for another challenge refused; a signature by another key over the same message refused; empty,
  absent and wrong-length signatures refused; the signed message byte-for-byte; the derivation
  recomputed by hand; the storage key derived and hash-tagged.
* `SwarmWalletRegistrationControllerTest` — 10 tests over a real Jersey container: challenge issued;
  missing key 422; malformed key 400; a good signature returns the derived number and a 32-byte
  password and stores it against the right PNI; no pending challenge 404; wrong challenge 403; another
  key's signature 403; missing signature 422; the same key reclaiming its own account 200; a colliding
  different key 409.
* No regressions: `RegistrationControllerTest`, `VerificationControllerTest` and `RateLimitersTest`
  pass unchanged — 217 tests in total with the two new classes.

**Not yet proven live.** `chat.swarm.green:443` was still closed while this was written (the TLS edge
waits on the owner's Let's Encrypt contact address), so the HTTP contract above is proven by the
in-process Jersey tests and the recorded request/response shapes, not by a request over the wire.

---

## 6. What the operator has to do

1. Rebuild the chat image from this branch and restart the `chat` container. Nothing else: no table,
   no config key, no secret, no new service.
2. Nothing to enable. The channel is on as soon as the image is running.
3. To watch it: `swarm_wallet_registration_challenge*` keys in the rate-limiters Redis, and the
   metrics `SwarmWalletRegistrationController.challengeIssued` and
   `…challengeVerified{outcome=verified|no-challenge|bad-signature|identifier-collision}`.
4. The staging registration stub and `SWARM_STAGING_FIXED_CODE` stay as they are: they serve the old
   SMS path, which still works for an ordinary number and is now refused for a `+888` identifier.

## 7. Phase 2

* Accounts with no number at all, using the server's existing no-number creation path; the `+888`
  identifiers, and with them the collision space, disappear.
* Blinded address lookup, so finding someone by wallet address does not show the server an address
  hash.
* A per-device identity key rather than one derived key on every device, once multi-device linking is
  in.
