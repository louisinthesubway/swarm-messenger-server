#!/usr/bin/env python3
"""Container health check for the SWARM registration stub.

Creates a session for a throwaway number over the stub's own TLS port and checks that a
session id comes back. Exits 0 on success, 1 on any failure.
"""

import os
import sys

import grpc

import RegistrationService_pb2 as pb
import RegistrationService_pb2_grpc as pb_grpc


def main() -> int:
    listen = os.environ.get("SWARM_STUB_LISTEN", "0.0.0.0:8443")
    port = listen.rsplit(":", 1)[-1]
    cert_path = os.environ.get("SWARM_STUB_TLS_CERT", "/certs/registration-stub.crt")
    authority = os.environ.get("SWARM_STUB_HEALTHCHECK_AUTHORITY", "registration-stub")

    try:
        with open(cert_path, "rb") as fh:
            root_certificates = fh.read()
        credentials = grpc.ssl_channel_credentials(root_certificates=root_certificates)
        options = (("grpc.ssl_target_name_override", authority),)
        with grpc.secure_channel(f"127.0.0.1:{port}", credentials, options) as channel:
            stub = pb_grpc.RegistrationServiceStub(channel)
            response = stub.CreateSession(
                pb.CreateRegistrationSessionRequest(e164=15550000000), timeout=5
            )
        if response.HasField("session_metadata") and response.session_metadata.session_id:
            return 0
        sys.stderr.write(f"unexpected response: {response}\n")
        return 1
    except Exception as e:  # noqa: BLE001 - a health check reports any failure the same way
        sys.stderr.write(f"health check failed: {e}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
