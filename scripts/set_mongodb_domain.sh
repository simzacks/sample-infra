#!/bin/bash
# Runs during terraform apply, immediately after the master Application is applied.
# Child Applications do not exist yet; Argo creates them later. This only stores the
# hostname and tells the master app to keep the Helm parameter the PostSync hook sets.
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

python3 - <<'PY' | kubectl apply -f -
import json, subprocess, sys

raw = subprocess.check_output(
    ["kubectl", "get", "application", "master", "-n", "default", "-o", "json"],
    text=True,
)
app = json.loads(raw)
policy = app["spec"].setdefault("syncPolicy", {})
options = policy.setdefault("syncOptions", [])
if "RespectIgnoreDifferences=true" not in options:
    options.append("RespectIgnoreDifferences=true")
ignored = app["spec"].setdefault("ignoreDifferences", [])
pointer = "/spec/sources/2/helm/parameters"
if not any(
    item.get("kind") == "Application" and pointer in (item.get("jsonPointers") or [])
    for item in ignored
):
    ignored.append(
        {
            "group": "argoproj.io",
            "kind": "Application",
            "jsonPointers": [pointer],
        }
    )
meta = app["metadata"]
json.dump(
    {
        "apiVersion": app["apiVersion"],
        "kind": app["kind"],
        "metadata": {"name": meta["name"], "namespace": meta["namespace"]},
        "spec": app["spec"],
    },
    sys.stdout,
)
sys.stdout.write("\n")
PY
