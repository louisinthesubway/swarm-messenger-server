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

echo "[minio-bootstrap] configuring alias"
mc alias set local http://minio:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

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
