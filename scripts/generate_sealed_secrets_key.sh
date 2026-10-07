#!/bin/bash
# Generate a reusable Sealed Secrets controller TLS key.
# Run once, keep sealed-secrets-key.yaml next to Terraform (gitignored),
# and copy the public cert into the app repo for kubeseal --cert.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${ROOT}/sealed-secrets-key.yaml}"
CERT_OUT="${2:-}"

if [[ -f "$OUT" ]]; then
  echo "Refusing to overwrite existing key: $OUT" >&2
  echo "Pass a different path, or remove the file if you intend to rotate." >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

openssl req -x509 -days 3650 -nodes -newkey rsa:4096 \
  -keyout "${WORKDIR}/tls.key" -out "${WORKDIR}/tls.crt" \
  -subj "/CN=sealed-secrets/O=sealed-secrets"

CRT_B64=$(base64 -w0 "${WORKDIR}/tls.crt")
KEY_B64=$(base64 -w0 "${WORKDIR}/tls.key")

cat > "$OUT" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: sealed-secrets-key
  namespace: default
  labels:
    sealedsecrets.bitnami.com/sealed-secrets-key: active
type: kubernetes.io/tls
data:
  tls.crt: ${CRT_B64}
  tls.key: ${KEY_B64}
EOF
chmod 600 "$OUT"

if [[ -n "$CERT_OUT" ]]; then
  cp "${WORKDIR}/tls.crt" "$CERT_OUT"
  echo "Wrote public cert to ${CERT_OUT}"
fi

echo "Wrote controller key to ${OUT} (do not commit this file)"
echo "Fingerprint: $(openssl x509 -in "${WORKDIR}/tls.crt" -noout -fingerprint -sha256)"
