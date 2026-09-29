#!/bin/sh
# SWARM Messenger staging — create the S3 buckets the chat server expects, and a
# scoped access key for the CDN bucket.
#
# Buckets (names must match staging.yml):
#   swarm-cdn      cdn.bucket                        attachments / CDN objects
#   swarm-prekeys  pagedSingleUseKEMPreKeyStore      paged single-use KEM (post-quantum) prekeys
#   swarm-config   dynamicConfig + asnTable          objects the server POLLS, not writes
#
# The swarm-config objects are not optional: DynamicConfigurationManager.getConfiguration()
# blocks until the first successful read, so a missing dynamic-config.yaml hangs startup.
#
# MinIO is reached virtual-host style (<bucket>.minio.swarm.local) by the server, which is
# why MINIO_DOMAIN is set on the minio service and why the compose network gives it the
# matching aliases. `mc` itself uses the plain host.
set -eu

# MinIO itself has no compose healthcheck (that would mean assuming which shell utilities its
# image ships). Readiness is waited for here instead, in an image that certainly has `mc`.
echo "[minio-bootstrap] waiting for MinIO"
i=0
until mc alias set local http://minio:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "${i}" -ge 60 ]; then
    echo "[minio-bootstrap] FAILED: MinIO did not become reachable in 120s" >&2
    mc alias set local http://minio:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" || true
    exit 1
  fi
  sleep 2
done
mc ready local >/dev/null 2>&1 || true
echo "[minio-bootstrap] MinIO is up"

for bucket in swarm-cdn swarm-prekeys swarm-config; do
  if mc ls "local/${bucket}" >/dev/null 2>&1; then
    echo "[minio-bootstrap] = ${bucket} (exists)"
  else
    mc mb "local/${bucket}"
    echo "[minio-bootstrap] + ${bucket}"
  fi
done

# The chat server uses two different credentials: the global `awsCredentialsProvider`
# (for DynamoDB and the prekey bucket) and `cdn.credentials` (for the CDN bucket).
# Give the CDN one its own key so a leaked client-facing credential cannot read accounts.
if mc admin user info local "${SWARM_CDN_ACCESS_KEY}" >/dev/null 2>&1; then
  echo "[minio-bootstrap] = user ${SWARM_CDN_ACCESS_KEY} (exists)"
else
  mc admin user add local "${SWARM_CDN_ACCESS_KEY}" "${SWARM_CDN_SECRET_KEY}"
  echo "[minio-bootstrap] + user ${SWARM_CDN_ACCESS_KEY}"
fi

cat > /tmp/swarm-cdn-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
                 "s3:AbortMultipartUpload", "s3:ListBucketMultipartUploads", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::swarm-cdn", "arn:aws:s3:::swarm-cdn/*"]
    }
  ]
}
JSON

mc admin policy create local swarm-cdn-rw /tmp/swarm-cdn-policy.json 2>/dev/null || true
mc admin policy attach local swarm-cdn-rw --user "${SWARM_CDN_ACCESS_KEY}" 2>/dev/null || true

# The server's GLOBAL credentials (awsCredentialsProvider: prekey bucket, the polled
# swarm-config objects) must also be a MinIO user. 2026-09-27, first real host: without this
# every S3ObjectMonitor read answered 403 and the server never became healthy.
if [ -n "${SWARM_AWS_ACCESS_KEY_ID:-}" ]; then
  if mc admin user info local "${SWARM_AWS_ACCESS_KEY_ID}" >/dev/null 2>&1; then
    echo "[minio-bootstrap] = user (global aws credentials) exists"
  else
    mc admin user add local "${SWARM_AWS_ACCESS_KEY_ID}" "${SWARM_AWS_SECRET_ACCESS_KEY}"
    echo "[minio-bootstrap] + user (global aws credentials)"
  fi
  mc admin policy attach local readwrite --user "${SWARM_AWS_ACCESS_KEY_ID}" 2>/dev/null || true
else
  echo "[minio-bootstrap] WARNING: SWARM_AWS_ACCESS_KEY_ID not set; the chat server will get 403s" >&2
fi

# Reads from the CDN are anonymous, as on Signal's own CDNs: an object name is 120 or more random
# bits and every object is end-to-end-encrypted ciphertext. Anonymous access is s3:GetObject on
# exactly the three prefixes clients read: attachments/ (CDN3 uploads, 15 random bytes per key),
# profiles/ (profile photos, 16 random bytes) and groups/ (group photos,
# groups/<group id>/<16 random bytes>, encrypted with the group's key, from which the id is
# derived; only the members hold that key). No listing, nothing else. Caddy publishes only
# GET/HEAD on those three paths. set-json replaces the whole bucket policy, so running this
# again is harmless. See docs/STAGING.md, sections 5c and 8a.
cat > /tmp/swarm-cdn-anonymous.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": ["*"]},
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::swarm-cdn/attachments/*", "arn:aws:s3:::swarm-cdn/profiles/*",
                   "arn:aws:s3:::swarm-cdn/groups/*"]
    }
  ]
}
JSON
mc anonymous set-json /tmp/swarm-cdn-anonymous.json local/swarm-cdn
echo "[minio-bootstrap] anonymous GetObject on swarm-cdn/attachments/*, swarm-cdn/profiles/* and swarm-cdn/groups/*"

# The CDN3 upload service (tus/) writes finished attachments with its own key, which may put and
# get objects under attachments/ and nothing else. Its credentials come from tus.env.
if [ -n "${SWARM_TUS_S3_ACCESS_KEY:-}" ] && [ -n "${SWARM_TUS_S3_SECRET_KEY:-}" ]; then
  if mc admin user info local "${SWARM_TUS_S3_ACCESS_KEY}" >/dev/null 2>&1; then
    echo "[minio-bootstrap] = user ${SWARM_TUS_S3_ACCESS_KEY} (exists)"
  else
    mc admin user add local "${SWARM_TUS_S3_ACCESS_KEY}" "${SWARM_TUS_S3_SECRET_KEY}" >/dev/null
    echo "[minio-bootstrap] + user ${SWARM_TUS_S3_ACCESS_KEY}"
  fi
  cat > /tmp/swarm-tus-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": ["arn:aws:s3:::swarm-cdn/attachments/*"]
    }
  ]
}
JSON
  mc admin policy create local swarm-tus-attachments /tmp/swarm-tus-policy.json >/dev/null 2>&1 || true
  mc admin policy attach local swarm-tus-attachments --user "${SWARM_TUS_S3_ACCESS_KEY}" >/dev/null 2>&1 || true
  echo "[minio-bootstrap] policy swarm-tus-attachments -> ${SWARM_TUS_S3_ACCESS_KEY}"
else
  echo "[minio-bootstrap] WARNING: SWARM_TUS_S3_* not set (tus/make-tus-env.sh); attachment uploads will fail" >&2
fi

# The two polled objects. Always re-uploaded, so editing minio/dynamic-config.yaml and
# re-running this service is how staging's dynamic configuration is changed.
echo "[minio-bootstrap] uploading dynamic-config.yaml"
mc cp /in/dynamic-config.yaml local/swarm-config/dynamic-config.yaml

echo "[minio-bootstrap] uploading asn.tsv.gz (gzipped: AsnInfoProviderImpl.fromTsvGz)"
gzip -c /in/asn.tsv > /tmp/asn.tsv.gz
mc cp /tmp/asn.tsv.gz local/swarm-config/asn.tsv.gz

echo "[minio-bootstrap] buckets:"
mc ls local | sed 's/^/  /'
echo "[minio-bootstrap] swarm-config:"
mc ls local/swarm-config | sed 's/^/  /'
echo "[minio-bootstrap] done"
