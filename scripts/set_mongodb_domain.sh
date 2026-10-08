#!/bin/bash
# Runs during terraform apply.
# Child Applications do not exist yet; Argo creates them later.
# This stores the hostname (lb ip address) which isn't available from within argo.
set -euo pipefail

KUBECONFIG_PATH=$1
DOMAIN=$2

export KUBECONFIG="$KUBECONFIG_PATH"

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-external-access
  namespace: default
data:
  domain: ${DOMAIN}
EOF
