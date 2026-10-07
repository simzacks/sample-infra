#!/bin/bash
# Additional servers join via node 0's private IP (not the public LB; Azure hairpin).

while ! curl -s -k "https://${PRIVATE_IP}:6443/cacerts" > /dev/null; do
    echo "Waiting for k3s control plane to initialize..."
    sleep 5
done

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_TOKEN="${K3S_TOKEN}" sh -s - server \
  --server "https://${PRIVATE_IP}:6443" \
  --tls-san="${LB_PUBLIC_IP}"
