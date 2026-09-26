# SWARM Messenger staging — registration stub (fixed verification code).
#
# Generates its Python gRPC stubs from RegistrationService.proto at image build time, so the
# wire contract can never drift from the copy in service/src/main/proto/.
FROM python:3.13-slim

ARG REGISTRATION_PROTO=RegistrationService.proto

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY ${REGISTRATION_PROTO} /app/RegistrationService.proto
RUN python -m grpc_tools.protoc -I/app \
      --python_out=/app --pyi_out=/app --grpc_python_out=/app \
      /app/RegistrationService.proto

COPY registration_stub.py healthcheck.py /app/

ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

# No default for SWARM_STAGING_FIXED_CODE: the process exits 78 unless it is set to "true".
EXPOSE 8443

ENTRYPOINT ["python", "/app/registration_stub.py"]
