#!/bin/bash
set -euo pipefail

KUBECONFIG_PATH=$1
MANIFEST_URL=$2

export KUBECONFIG="$KUBECONFIG_PATH"

# Helm --wait on the Argo install returns before the application controller
# is ready to accept a sync. The CRD must exist before apply.
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s

MANIFEST=$(mktemp)
trap 'rm -f "$MANIFEST"' EXIT
curl -fsSL "$MANIFEST_URL" -o "$MANIFEST"
kubectl apply -f "$MANIFEST"
