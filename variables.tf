variable "count_qty" {
  type        = number
  description = "qty of sets of resources to create"
  default     = 3
}

variable "admin_user" {
  type        = string
  description = "username for admin user"
  default     = "k3s-admin"
}

variable "k3s_version" {
  type        = string
  description = "Pinned k3s release"
  default     = "v1.37.1+k3s1"
}

variable "argocd_chart_version" {
  type        = string
  description = "Pinned argo-cd Helm chart version"
  default     = "10.9.6"
}

variable "master_app_manifest_url" {
  type        = string
  description = "Raw URL of the Argo CD master Application manifest in the GitOps repo. Fetched at apply time; child apps live in the git path that manifest watches."
  default     = "https://raw.githubusercontent.com/simzacks/sample-nodejs/main/gitops/bootstrap/master-app.yaml"
}
