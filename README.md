# sample-infra

## Definition of Done (DoD)
* Provision an unmanaged k3s 3 node cluster, in which each node is master/etcd/worker (HA)
* Deploy ArgoCD on the cluster

## Repo
* The private key for the VMs to be created is in the insecure folder. In a production environment, the private key would not be shared like this. However, this project requires that all files will be in the repo. This key was specifically generated for this project so there are no security ramifications.
  * To ssh into the vm from within the project folder: `ssh -i insecure/id_ed25519 k3s-admin@{public_ip}`


## Cloud
* I chose Azure because I have have never used it and still had a free-tier available with $200 credit for any resources I need to pay for.

* The VM image I chose is Standard_B2als_v2, which is a burstable x86 with 2vCPU and 4GB RAM, which is enough capacity for the kubernetes cluster.
  * Storage: 64GB Premium_LRS disk, which is in the free tier and meets the recommendation for 50+GB in /vars
  * OS: Ubuntu-26.04 LTS, industry standard, no additional cost. It uses `latest` to enable security patches and minor fixes, which is considered an acceptble risk for this project.
  * Being that each node is managing the same load, they all need to have the same specs.
  * Cost: $0.1128 per hour ($0.0376 per hour per machine).

* Each VM is assigned a public IP address for SSH debugging purposes. In a production environment this would generally be done with either a bastion host for a single point of entry and/or locked down to specific source IP(s).

* Each VM is assigned a static private IP. When setting up kubernetes, the secondary nodes need to know the primary nodes IP to join the cluster. The other nodes could technically be dynamic, but being that it is a small environment, there was no reason to use dynamic addressing.


* An Azure standard Load Balancer gives the cluster a single point of entry to the 3 VMs. It is assigned a public IP address.
  * Ports configured:
    * 6443 - Kubernetes API
    * 80 - HTTP (nodejs app, and argocd)
      * In production, I would recommend only using TLS with port 443
    * 30017, 30018, 30019 - NodePort (mongodb)
  * Cost: $0.025 per hour

* Security Groups - Inbound ports configured (all outbound allowed by default):
  * 22 TCP - SSH access to the world
  * 6443 TCP - K3s API access to the world
  * 80 TCP - HTTP access to the world
  * 30017-30019 TCP  - NodePort access (for planned used ports) to the world
  * 10250 TCP - Mongodb metrics access to the world
  * 8472 UDP - Flannel VXLan (k8s CNI) access to the internal network
  * 2379-2380 - etcd access to the internal network


## Terraform
* Password Generation
  * k3s requires a token for nodes to join the cluster. This token is generated as part of the terraform run, so that additional data doesn't have to be managed.
  * mongodb requires a user password, root password and replicaset-key. This is generated in the terraform and applied as a k8s secret instead of allowing the bitnami chart to generate them. Because of the argocd deployment, when there was a new mongodb sync, it would refresh the passwords and break the replicaset. This method enables it to refer to the existing secret instead of generating a new one, keeping stability.

* Sleep Buffers
  * An issue was found in both terraform apply and destroy of network resources that were caused by Azure's "eventual consistency". Azure was reporting that resources were complete but when the dependency tried to use it (or destroy it), it threw an error because it either didn't exist or still contained resources. The 30 second sleep overcame this issue.

* Deploy k3s
  * File version pinned in `variables.tf` - As the system platform, even patch upgrades need to be handled manually.
  * Uses the token mentioned above
  * Deployed via a shell script as part of the VM deployment in `custom_data`. The primary node is installed with --cluster-init and the other nodes connect to it
  * Uses a local-exec to SSH to the primary node and copy the k3s.yaml (kubeconfig) to the deploying machine. It modifies the local ip to the Load balancer IP in the file.

* Install mongodb credentials and set the domain
  * As mentioned above, this is done in Terraform so that the credentials don't get overwritten with an ArgoCD sync.
  * The mongo public domain is the load balancer IP address, which isn't available to argo, so it has to be done here.

* Install Argocd
  * ArgoCD will be used for GitOps management of deployment of anything on k3s. It is installed by terraform for a completely automated deployment
  * The ArgoCD deployment uses an App of Apps pattern, so the master app is applied in Terraform to bootstrap the process. 

* Output
  * SSH instructions
  * VM public IP addresses
  * Load balancer public IP Address
  * kubectl access
  * ArgoCD access
  * Mongodb access
  * App access