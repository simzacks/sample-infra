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
Terraform installs Argo CD, then downloads the master Application from `master_app_manifest_url` (default `https://raw.githubusercontent.com/simzacks/sample-nodejs/main/gitops/master-app.yaml`) and applies it. That master app is the only Application this module creates. It watches `gitops/apps` in the app repo and syncs every child Application there. Add workloads as manifests in that directory; do not declare them in this module. The manifest must be on `main` before apply.

Re-applying the master app without a full Terraform run:

```
export KUBECONFIG=./k3s.yaml
bash scripts/bootstrap_master_app.sh ./k3s.yaml https://raw.githubusercontent.com/simzacks/sample-nodejs/main/gitops/master-app.yaml
```

After apply, the UI is served by Traefik at `https://argocd.<load-balancer-ip>.sslip.io` (see the `argocd_access` output). The Node.js app is `https://app.<load-balancer-ip>.sslip.io` (`app_access`). The app Ingress has no Host, so it does not need that IP in git. The browser warns on Traefik's default certificate. Log in to Argo CD as `admin`. The initial password is in the `argocd-initial-admin-secret` secret in the `default` namespace. Port-forward remains a fallback. `k3s.yaml` stays on the machine that ran apply and is not committed.

Argo CD, Sealed Secrets, and every GitOps workload — including external Helm charts — install into the `default` namespace. Do not pass another namespace to those charts.

## Sealed Secrets
Terraform also installs the Sealed Secrets controller so GitOps apps can decrypt credentials on a fresh cluster. The controller TLS private key is `sealed-secrets-key.yaml` in this directory. It is gitignored, same as `k3s.yaml`.

Generate the key once (`scripts/generate_sealed_secrets_key.sh`) and reuse that file on every `terraform apply`. Copy `sealed-secrets-key.yaml` onto any machine that will recreate the cluster. Without the same private key, committed SealedSecrets will not decrypt.

The matching public certificate lives in the app repo (`sample-nodejs/gitops/sealed-secrets-cert.pem`) and is used with `kubeseal --cert`. Key renewal is disabled so the controller does not mint a new key after install.

Plaintext MongoDB passwords used to seal the GitOps secret are in `mongodb-credentials.env` on this machine (gitignored). Keep that file with the private key if you need to log in after a rebuild.

Normally these 2 files would be in gitignore, but for this exercise where every file must be in the repo, they are added.
sealed-secrets-key.yaml
mongodb-credentials.env

