#!/bin/bash
set -euo pipefail

KUBECONFIG_PATH=$1
MANIFEST_URL=$2

export KUBECONFIG="$KUBECONFIG_PATH"

# Helm --wait on the Argo install returns before the application controller
# is ready to accept a sync. The CRD must exist before apply.
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s

# curl gives a clearer error message if the download fails rather than directly calling kubectl apply -f $MANIFEST_URL
curl -fsSL "$MANIFEST_URL" | kubectl apply -f -
