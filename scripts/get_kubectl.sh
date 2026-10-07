#!/bin/bash
set -euo pipefail

SSH_USER=$1
SSH_IP=$2
MY_PATH=$3
LB_IP=$4

# Loop until the control plane completes setting up the file
TIMEOUT_SECONDS=600
START=$(date +%s)
SSH=(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 -i ~/.ssh/id_rsa "$SSH_USER@$SSH_IP")

until "${SSH[@]}" "sudo test -f /etc/rancher/k3s/k3s.yaml" 2>/dev/null; do
  now=$(date +%s)
  if (( now - START > TIMEOUT_SECONDS )); then
    echo "k3s.yaml not found after ${TIMEOUT_SECONDS}s on $SSH_IP" >&2
    "${SSH[@]}" "sudo journalctl -u k3s --no-pager -n 50; cloud-init status" >&2 || true
    exit 1
  fi
  sleep 5
done

# Fetch kubeconfig over SSH, then point the API server at the load balancer
ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa $SSH_USER@$SSH_IP "sudo cat /etc/rancher/k3s/k3s.yaml" > $MY_PATH/k3s.yaml

sed -i "s/127.0.0.1/$LB_IP/g" $MY_PATH/k3s.yaml
