# SWARM Messenger staging registration stub

A ~200-line gRPC service that implements `org.signal.registration.rpc.RegistrationService`
and issues **one fixed verification code** (default `123456`) for every phone number.

It replaces the real [registration-service](https://github.com/signalapp/registration-service),
which requires an SMS provider account (Twilio, Infobip, …). Nothing here sends an SMS, looks a
number up, or contacts any network outside the Docker network.

## Why it exists

`POST /v1/registration` on the chat server requires a *verified* registration session. Getting
one requires the registration service to have sent a code and accepted it. Without an SMS
account there is no way to complete registration, so a staging stack cannot create a single
account — which means it cannot be tested at all.

## Fail closed

Two independent guards, both demanding the same environment variable:

| Guard | Where | Behaviour when unset |
|---|---|---|
| The stub itself | `registration_stub.py` → `_require_staging()` | exits **78** with a message; never serves a request |
| The chat server | `SwarmStagingRegistrationServiceConfiguration.build()` | throws at startup; the server does not come up |

Both require `SWARM_STAGING_FIXED_CODE=true` *exactly*. There is no config-file switch, no
command-line flag and no default. The chat server additionally has to name
`registrationService.type: swarm-staging` in its configuration; the upstream `default` type
still requires a real Google Cloud identity token and is untouched.

## Wire contract

`RegistrationService.proto` in this directory is a byte-for-byte copy of
`service/src/main/proto/RegistrationService.proto`. The Dockerfile regenerates the Python
stubs from it at build time, so a change upstream shows up as a build-time mismatch rather
than a silent runtime error. Keep the copy in sync when rebasing onto a newer upstream.

TLS is mandatory: upstream's `RegistrationServiceClient` always opens a TLS channel and pins
the CA certificate given in `registrationCaCertificate`. Generate the material with
`../certs/make-certs.sh`; the certificate's SAN must contain the hostname the chat server
dials (`registration-stub` inside the compose network, `reg.chat.swarm.green` from outside).

No bearer token is checked. Access control is the Docker network — the stub is never
published on a host port.

## Behaviour

| RPC | Behaviour |
|---|---|
| `CreateSession` | 32 random bytes as session id, 10 minute TTL, in memory |
| `SendVerificationCode` | marks the session "code sent" and logs the fixed code (this is how the operator learns it) |
| `CheckVerificationCode` | constant-time compare against the fixed code; sets `verified` on a match |
| `GetSessionMetadata` | returns the session, or `NOT_FOUND` once it expires |

Sessions live in memory only, so restarting the stub abandons in-flight registrations. That
is the right trade for staging.

## Running it outside compose

```sh
SWARM_STAGING_FIXED_CODE=true \
SWARM_STAGING_VERIFICATION_CODE=123456 \
SWARM_STUB_TLS_CERT=../certs/registration-stub.crt \
SWARM_STUB_TLS_KEY=../certs/registration-stub.key \
python registration_stub.py
```

(after `python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. RegistrationService.proto`)
