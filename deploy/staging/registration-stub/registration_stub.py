#!/usr/bin/env python3
"""SWARM Messenger staging registration stub.

Implements org.signal.registration.rpc.RegistrationService (RegistrationService.proto,
copied verbatim from service/src/main/proto/) with one behaviour: it issues and accepts a
single fixed verification code. No SMS provider, no phone network, nothing leaves the host.

It exists so that the SWARM Messenger staging server can complete
  POST /v1/verification/session  ->  PUT /v1/verification/session/{id}/code  ->  POST /v1/registration
without an SMS account. It replaces the real registration-service
(https://github.com/signalapp/registration-service), which needs Twilio/Infobip credentials.

FAIL CLOSED
-----------
The process refuses to start unless the environment variable SWARM_STAGING_FIXED_CODE is
exactly "true". There is no flag, no config file and no default that turns it on. A
production profile that starts this image without that variable gets an immediate
non-zero exit and a loud message, not a server that accepts 123456 from anyone.

The chat server has the matching guard: `registrationService.type: swarm-staging`
(SwarmStagingRegistrationServiceConfiguration) also demands SWARM_STAGING_FIXED_CODE=true.

WIRE DETAILS
------------
* TLS is mandatory: upstream's RegistrationServiceClient always builds a TLS channel and
  pins a CA certificate, so the stub serves TLS with the cert produced by
  ../certs/make-certs.sh. Hostname must match the certificate SAN.
* No bearer token is checked. Upstream's production client sends a Google Cloud identity
  token; the staging client sends none. Access control is the Docker network.
"""

from __future__ import annotations

import logging
import os
import secrets
import sys
import threading
import time
from concurrent import futures
from dataclasses import dataclass, field

import grpc

import RegistrationService_pb2 as pb
import RegistrationService_pb2_grpc as pb_grpc

LOG = logging.getLogger("swarm-registration-stub")

SESSION_TTL_SECONDS = 600
STAGING_ENV_VAR = "SWARM_STAGING_FIXED_CODE"


def _require_staging() -> str:
    """Refuse to run unless explicitly enabled. Returns the fixed verification code."""
    if os.environ.get(STAGING_ENV_VAR) != "true":
        sys.stderr.write(
            "REFUSING TO START.\n"
            "The SWARM registration stub issues one fixed verification code and verifies\n"
            "nothing. It is for the self-hosted staging stack only. To run it, set\n"
            f"  {STAGING_ENV_VAR}=true\n"
            "Do not set that variable in a production profile.\n"
        )
        raise SystemExit(78)  # EX_CONFIG

    code = os.environ.get("SWARM_STAGING_VERIFICATION_CODE", "123456")
    if not code.isdigit() or not (4 <= len(code) <= 12):
        sys.stderr.write(
            f"REFUSING TO START: SWARM_STAGING_VERIFICATION_CODE must be 4-12 digits, got {code!r}\n"
        )
        raise SystemExit(78)
    return code


@dataclass
class Session:
    session_id: bytes
    e164: int
    created_at: float = field(default_factory=time.monotonic)
    code_sent: bool = False
    verified: bool = False

    def expires_in(self) -> int:
        remaining = SESSION_TTL_SECONDS - (time.monotonic() - self.created_at)
        return max(0, int(remaining))

    def expired(self) -> bool:
        return self.expires_in() <= 0


class SessionStore:
    """In-memory sessions. Losing them on restart is correct for staging."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._sessions: dict[bytes, Session] = {}

    def create(self, e164: int) -> Session:
        session = Session(session_id=secrets.token_bytes(32), e164=e164)
        with self._lock:
            self._reap_locked()
            self._sessions[session.session_id] = session
        return session

    def get(self, session_id: bytes) -> Session | None:
        with self._lock:
            self._reap_locked()
            session = self._sessions.get(session_id)
        if session is not None and session.expired():
            return None
        return session

    def _reap_locked(self) -> None:
        for key in [k for k, v in self._sessions.items() if v.expired()]:
            del self._sessions[key]


def _metadata(session: Session) -> pb.RegistrationSessionMetadata:
    return pb.RegistrationSessionMetadata(
        session_id=session.session_id,
        verified=session.verified,
        e164=session.e164,
        may_request_sms=not session.verified,
        next_sms_seconds=0,
        may_request_voice_call=not session.verified,
        next_voice_call_seconds=0,
        may_check_code=session.code_sent and not session.verified,
        next_code_check_seconds=0,
        expiration_seconds=session.expires_in(),
    )


class RegistrationStub(pb_grpc.RegistrationServiceServicer):
    def __init__(self, fixed_code: str) -> None:
        self._fixed_code = fixed_code
        self._sessions = SessionStore()

    def CreateSession(self, request, context):
        if request.e164 == 0:
            LOG.warning("CreateSession with empty e164")
            return pb.CreateRegistrationSessionResponse(
                error=pb.CreateRegistrationSessionError(
                    error_type=pb.CREATE_REGISTRATION_SESSION_ERROR_TYPE_ILLEGAL_PHONE_NUMBER,
                    may_retry=False,
                )
            )
        session = self._sessions.create(request.e164)
        LOG.info("CreateSession +%s -> %s", request.e164, session.session_id.hex()[:16])
        return pb.CreateRegistrationSessionResponse(session_metadata=_metadata(session))

    def GetSessionMetadata(self, request, context):
        session = self._sessions.get(request.session_id)
        if session is None:
            return pb.GetRegistrationSessionMetadataResponse(
                error=pb.GetRegistrationSessionMetadataError(
                    error_type=pb.GET_REGISTRATION_SESSION_METADATA_ERROR_TYPE_NOT_FOUND
                )
            )
        return pb.GetRegistrationSessionMetadataResponse(session_metadata=_metadata(session))

    def SendVerificationCode(self, request, context):
        session = self._sessions.get(request.session_id)
        if session is None:
            return pb.SendVerificationCodeResponse(
                error=pb.SendVerificationCodeError(
                    error_type=pb.SEND_VERIFICATION_CODE_ERROR_TYPE_SESSION_NOT_FOUND,
                    may_retry=False,
                )
            )
        if session.verified:
            return pb.SendVerificationCodeResponse(
                session_metadata=_metadata(session),
                error=pb.SendVerificationCodeError(
                    error_type=pb.SEND_VERIFICATION_CODE_ERROR_TYPE_SESSION_ALREADY_VERIFIED,
                    may_retry=False,
                ),
            )
        session.code_sent = True
        # The code is logged on purpose: this is how the operator of a staging stack learns
        # it, exactly as an SMS would tell a real user. It is not a secret; it is fixed.
        LOG.info(
            "SendVerificationCode +%s transport=%s -> fixed code %s",
            session.e164,
            pb.MessageTransport.Name(request.transport),
            self._fixed_code,
        )
        return pb.SendVerificationCodeResponse(session_metadata=_metadata(session))

    def CheckVerificationCode(self, request, context):
        session = self._sessions.get(request.session_id)
        if session is None:
            return pb.CheckVerificationCodeResponse(
                error=pb.CheckVerificationCodeError(
                    error_type=pb.CHECK_VERIFICATION_CODE_ERROR_TYPE_SESSION_NOT_FOUND,
                    may_retry=False,
                )
            )
        if not session.code_sent:
            return pb.CheckVerificationCodeResponse(
                session_metadata=_metadata(session),
                error=pb.CheckVerificationCodeError(
                    error_type=pb.CHECK_VERIFICATION_CODE_ERROR_TYPE_NO_CODE_SENT,
                    may_retry=False,
                ),
            )
        if secrets.compare_digest(request.verification_code, self._fixed_code):
            session.verified = True
            LOG.info("CheckVerificationCode +%s accepted", session.e164)
        else:
            LOG.info("CheckVerificationCode +%s rejected (wrong code)", session.e164)
        # Upstream reads `verified` from the metadata; a wrong code is not an error, it is
        # simply a session that is still unverified.
        return pb.CheckVerificationCodeResponse(session_metadata=_metadata(session))


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("SWARM_STUB_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)-5s %(name)s %(message)s",
    )

    fixed_code = _require_staging()

    listen = os.environ.get("SWARM_STUB_LISTEN", "0.0.0.0:8443")
    cert_path = os.environ.get("SWARM_STUB_TLS_CERT", "/certs/registration-stub.crt")
    key_path = os.environ.get("SWARM_STUB_TLS_KEY", "/certs/registration-stub.key")

    for path in (cert_path, key_path):
        if not os.path.isfile(path):
            sys.stderr.write(
                f"REFUSING TO START: TLS material missing: {path}\n"
                "Run deploy/staging/certs/make-certs.sh first.\n"
            )
            return 78

    with open(cert_path, "rb") as fh:
        certificate_chain = fh.read()
    with open(key_path, "rb") as fh:
        private_key = fh.read()

    credentials = grpc.ssl_server_credentials([(private_key, certificate_chain)])

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    pb_grpc.add_RegistrationServiceServicer_to_server(RegistrationStub(fixed_code), server)
    server.add_secure_port(listen, credentials)
    server.start()

    LOG.warning(
        "SWARM registration STUB listening on %s (TLS). Fixed verification code: %s. "
        "STAGING ONLY - every phone number verifies with this one code.",
        listen,
        fixed_code,
    )
    server.wait_for_termination()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
