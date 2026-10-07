#!/bin/bash
# --- FIRST SERVER: cluster-init for embedded etcd HA ---

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_TOKEN="${K3S_TOKEN}" sh -s - server \
  --cluster-init \
  --tls-san="${LB_PUBLIC_IP}" \
  --tls-san="${PRIVATE_IP}"
