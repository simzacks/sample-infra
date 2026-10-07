#!/bin/bash
set -euo pipefail

KUBECONFIG_PATH=$1
EXPECTED_NODES=$2
CHART_VERSION=$3
HOSTNAME=$4

export KUBECONFIG="$KUBECONFIG_PATH"

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

VALUES_FILE=$(mktemp)
trap 'rm -f "$VALUES_FILE"' EXIT

cat > "$VALUES_FILE" <<EOF
configs:
  params:
    server.insecure: "true"
server:
  ingress:
    enabled: true
    ingressClassName: traefik
    hostname: ${HOSTNAME}
    annotations:
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
      traefik.ingress.kubernetes.io/router.tls: "true"
EOF

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version "$CHART_VERSION" \
  --values "$VALUES_FILE" \
  --wait \
  --timeout 10m
