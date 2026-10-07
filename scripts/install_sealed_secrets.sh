#!/bin/bash
set -euo pipefail

KUBECONFIG_PATH=$1
EXPECTED_NODES=$2
CHART_VERSION=$3
KEY_FILE=$4

export KUBECONFIG="$KUBECONFIG_PATH"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "Missing Sealed Secrets private key: ${KEY_FILE}" >&2
  echo "Copy sealed-secrets-key.yaml onto this machine (same file used to seal MongoDB credentials)," >&2
  echo "or generate one with scripts/generate_sealed_secrets_key.sh and re-seal secrets with the new cert." >&2
  exit 1
fi

TIMEOUT_SECONDS=600
START=$(date +%s)

ready_count() {
  kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" { c++ } END { print c+0 }'
}

until [[ "$(ready_count)" -ge "$EXPECTED_NODES" ]]; do
  now=$(date +%s)
  if (( now - START > TIMEOUT_SECONDS )); then
    echo "Timed out waiting for ${EXPECTED_NODES} Ready nodes" >&2
    kubectl get nodes >&2 || true
    exit 1
  fi
  sleep 5
done

kubectl apply -f "$KEY_FILE"

VALUES_FILE=$(mktemp)
trap 'rm -f "$VALUES_FILE"' EXIT

cat > "$VALUES_FILE" <<EOF
fullnameOverride: sealed-secrets-controller
secretName: sealed-secrets-key
keyrenewperiod: "0"
EOF

helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets --force-update
helm repo update sealed-secrets
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace default \
  --version "$CHART_VERSION" \
  --values "$VALUES_FILE" \
  --wait \
  --timeout 10m
