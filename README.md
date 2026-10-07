# sample-infra

## Cloud
Chose Azure because I have already used up my free-tier in AWS.
For a 3 node K3S cluster with 1 vCPU each, should stay within the free tier for this project.

## Terraform
* Lock in the versions to allow minor updates
* Resources in East US because it is the most flexible for the free tier
* The free tier requires Premium Storage of 64GB disks
* The source image is the latest, Ubuntu server 26.04 LTS. I didn't lock it down to a specific minor version, because I'm willing to get minor updates.

## Argo CD
Terraform bootstraps Argo CD into the cluster and stops there. Add apps as Argo CD `Application` manifests in git; do not declare them in this module.

After apply, the UI is served by Traefik at `https://argocd.<load-balancer-ip>.sslip.io` (see the `argocd_access` output). The browser warns on Traefik's default certificate. Log in as `admin`. The initial password is in the `argocd-initial-admin-secret` secret. Port-forward remains a fallback. `k3s.yaml` stays on the machine that ran apply and is not committed.
