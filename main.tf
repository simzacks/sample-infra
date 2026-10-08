locals {
  azure_location     = "denmarkeast"
  # Static private IPs for etcd peers. Must be in the subnet and cannot be .[1-3].
  # Node 0 is the bootstrap/join endpoint (Azure LB hairpin cannot be used to join).
  node_private_ips   = [for i in range(var.count_qty) : cidrhost(azurerm_subnet.subnet.address_prefixes[0], 10 + i)]
  public_key_file    = "${path.module}/scripts/id_ed25519.pub"
  private_key_file   = "${path.module}/insecure/id_ed25519"
  azure_vm           = "Standard_B2als_v2"
  control_plane_ip   = local.node_private_ips[0]
  argocd_hostname    = "argocd.${azurerm_public_ip.k3s_lb_ip.ip_address}.sslip.io"
  app_hostname       = "app.${azurerm_public_ip.k3s_lb_ip.ip_address}.sslip.io"
  # Bare IPv4. sslip.io also publishes an AAAA record that does not reach this load balancer,
  # and mongosh tries that address first. The chart uses this value as the replica set host.
  mongodb_advertised_host = azurerm_public_ip.k3s_lb_ip.ip_address
  # Must match externalAccess.service.nodePorts in sample-nodejs mongodb values.
  mongodb_node_ports = [30017, 30018, 30019]
}

resource "random_password" "k3s_token" {
  length  = 32
  special = false
}

resource "random_password" "mongodb_root_password" {
  length  = 24
  special = false
}

resource "random_password" "mongodb_password" {
  length  = 24
  special = false
}

resource "random_password" "mongodb_replica_set_key" {
  length  = 32
  special = false
}

resource "azurerm_resource_group" "rg" {
  name     = "k3s-rg"
  location = local.azure_location
}

# The global replication buffer
resource "time_sleep" "azure_api_buffer" {
  depends_on = [azurerm_resource_group.rg]

  create_duration = "30s"
}

resource "time_sleep" "subnet_destroy_buffer" {
  create_duration  = "0s"
  destroy_duration = "30s"

  triggers = {
    subnet_id     = azurerm_subnet.subnet.id
    public_ip_ids = join(",", azurerm_public_ip.public_ip[*].id)

  }
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet1"
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  depends_on          = [time_sleep.azure_api_buffer]
}

resource "azurerm_subnet" "subnet" {
  name                 = "subnet1"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

}

resource "azurerm_public_ip" "public_ip" {
  count               = var.count_qty
  name                = "public-ip${count.index}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "k3s_lb_ip" {
  name                = "k3s-lb-ip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "k3s_api_lb" {
  name                = "k3s-api-lb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "k3s-api-frontend"
    public_ip_address_id = azurerm_public_ip.k3s_lb_ip.id
  }
}

resource "azurerm_lb_backend_address_pool" "k3s_api" {
  name            = "k3s-api-backend"
  loadbalancer_id = azurerm_lb.k3s_api_lb.id
}

resource "azurerm_lb_probe" "k3s_lb_probe" {
  loadbalancer_id = azurerm_lb.k3s_api_lb.id
  name            = "k3s-lb-probe"
  protocol        = "Tcp"
  port            = 6443
}

resource "azurerm_lb_rule" "k3s_api" {
  loadbalancer_id                = azurerm_lb.k3s_api_lb.id
  name                           = "k3s-api-6443"
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "k3s-api-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.k3s_api.id]
  probe_id                       = azurerm_lb_probe.k3s_lb_probe.id
}

resource "azurerm_lb_probe" "argocd_http" {
  loadbalancer_id = azurerm_lb.k3s_api_lb.id
  name            = "argocd-http-probe"
  protocol        = "Tcp"
  port            = 80
}

resource "azurerm_lb_rule" "argocd_http" {
  loadbalancer_id                = azurerm_lb.k3s_api_lb.id
  name                           = "argocd-http-80"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "k3s-api-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.k3s_api.id]
  probe_id                       = azurerm_lb_probe.argocd_http.id
}

resource "azurerm_lb_probe" "mongodb" {
  for_each        = toset([for port in local.mongodb_node_ports : tostring(port)])
  loadbalancer_id = azurerm_lb.k3s_api_lb.id
  name            = "mongodb-${each.key}"
  protocol        = "Tcp"
  port            = tonumber(each.key)
}

resource "azurerm_lb_rule" "mongodb" {
  for_each                       = toset([for port in local.mongodb_node_ports : tostring(port)])
  loadbalancer_id                = azurerm_lb.k3s_api_lb.id
  name                           = "mongodb-${each.key}"
  protocol                       = "Tcp"
  frontend_port                  = tonumber(each.key)
  backend_port                   = tonumber(each.key)
  frontend_ip_configuration_name = "k3s-api-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.k3s_api.id]
  probe_id                       = azurerm_lb_probe.mongodb[each.key].id
}

resource "azurerm_network_interface" "nics" {
  count               = var.count_qty
  name                = "nic-${count.index}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  ip_configuration {
    name = "nic_config"
    # subnet_id         = azurerm_subnet.subnet.id
    # By reading the ID through the time_sleep trigger, Terraform is forced
    # to process this sleep resource during creation and destruction.
    subnet_id                     = time_sleep.subnet_destroy_buffer.triggers["subnet_id"]
    private_ip_address_allocation = "Static"
    private_ip_address            = local.node_private_ips[count.index]
    public_ip_address_id          = split(",", time_sleep.subnet_destroy_buffer.triggers["public_ip_ids"])[count.index]
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "k3s_api" {
  count                   = var.count_qty
  network_interface_id    = azurerm_network_interface.nics[count.index].id
  ip_configuration_name   = "nic_config"
  backend_address_pool_id = azurerm_lb_backend_address_pool.k3s_api.id
  # LB rule updates can PUT the same NIC/pool; wait until rules exist.
  depends_on = [
    azurerm_lb_rule.k3s_api,
    azurerm_lb_rule.argocd_http,
    azurerm_lb_rule.mongodb,
  ]
}

resource "azurerm_linux_virtual_machine" "vms" {
  count               = var.count_qty
  name                = "vm-${count.index}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  # Every node is control-plane + etcd + worker (2 vCPU / 4 GiB)
  size                  = local.azure_vm
  admin_username        = var.admin_user
  network_interface_ids = [azurerm_network_interface.nics[count.index].id]
  depends_on = [
    azurerm_network_interface_backend_address_pool_association.k3s_api,
    azurerm_network_interface_security_group_association.k3s_nsg_assoc,
  ]
  admin_ssh_key {
    username   = var.admin_user
    public_key = file(local.public_key_file)
  }
  os_disk {
    name                 = "osdisk-${count.index}"
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
    disk_size_gb         = 64
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-26_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = (count.index == 0 ?
    base64encode(templatefile("${path.module}/scripts/k3s_control_plane.sh",
      {
        K3S_TOKEN    = random_password.k3s_token.result
        K3S_VERSION  = var.k3s_version
        LB_PUBLIC_IP = azurerm_public_ip.k3s_lb_ip.ip_address
        PRIVATE_IP   = local.control_plane_ip
    })) :
    base64encode(templatefile("${path.module}/scripts/k3s_worker.sh",
      {
        K3S_TOKEN    = random_password.k3s_token.result
        K3S_VERSION  = var.k3s_version
        LB_PUBLIC_IP = azurerm_public_ip.k3s_lb_ip.ip_address
        PRIVATE_IP   = local.control_plane_ip
    }))
  )

}

resource "azurerm_network_security_group" "k3s_nsg" {
  name                = "k3s-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_port_range     = "22"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-k3s"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_port_range     = "6443"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-http"
    priority                   = 102
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_port_range     = "80"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-nodeports"
    priority                   = 103
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_port_range     = "30017-30019"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-k3s-metrics"
    priority                   = 104
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_port_range     = "10250"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-flannel-vxlan"
    priority                   = 105
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_address_prefix      = azurerm_subnet.subnet.address_prefixes[0]
    source_port_range          = "*"
    destination_port_range     = "8472"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-etcd"
    priority                   = 106
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = azurerm_subnet.subnet.address_prefixes[0]
    source_port_range          = "*"
    destination_port_ranges    = ["2379", "2380"]
    destination_address_prefix = "*"
  }

}

resource "azurerm_network_interface_security_group_association" "k3s_nsg_assoc" {
  count                     = var.count_qty
  network_interface_id      = azurerm_network_interface.nics[count.index].id
  network_security_group_id = azurerm_network_security_group.k3s_nsg.id

  depends_on = [azurerm_network_interface_backend_address_pool_association.k3s_api]
}

resource "null_resource" "get_kubeconfig" {
  depends_on = [azurerm_linux_virtual_machine.vms]
  triggers = {
    control_plane_id = azurerm_linux_virtual_machine.vms[0].id
    api_lb_ip        = azurerm_public_ip.k3s_lb_ip.ip_address
  }
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/get_kubectl.sh ${azurerm_linux_virtual_machine.vms[0].admin_username} ${azurerm_public_ip.public_ip[0].ip_address} ${path.module} ${azurerm_public_ip.k3s_lb_ip.ip_address}"
  }
}

resource "null_resource" "mongodb_credentials" {
  depends_on = [null_resource.get_kubeconfig]
  triggers = {
    kubeconfig_id   = null_resource.get_kubeconfig.id
    root_password   = random_password.mongodb_root_password.result
    app_password    = random_password.mongodb_password.result
    replica_set_key = random_password.mongodb_replica_set_key.result
  }
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/install_mongodb_credentials.sh ${path.module}/k3s.yaml ${random_password.mongodb_root_password.result} ${random_password.mongodb_password.result} ${random_password.mongodb_replica_set_key.result}"
  }
}

resource "null_resource" "set_mongodb_domain" {
  depends_on = [null_resource.get_kubeconfig]
  triggers = {
    bootstrap_id = null_resource.bootstrap_master_app.id
    hostname     = local.mongodb_advertised_host
  }
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/set_mongodb_domain.sh ${path.module}/k3s.yaml ${local.mongodb_advertised_host}"
  }
}

resource "null_resource" "install_argocd" {
  depends_on = [null_resource.get_kubeconfig]
  triggers = {
    kubeconfig_id = null_resource.get_kubeconfig.id
    chart_version = var.argocd_chart_version
    node_count    = var.count_qty
    hostname      = local.argocd_hostname
  }
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/install_argocd.sh ${path.module}/k3s.yaml ${var.count_qty} ${var.argocd_chart_version} ${local.argocd_hostname}"
  }
}

resource "null_resource" "bootstrap_master_app" {
  depends_on = [null_resource.install_argocd, null_resource.mongodb_credentials]
  triggers = {
    argocd_id    = null_resource.install_argocd.id
    manifest_url = var.master_app_manifest_url
  }
  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/bootstrap_master_app.sh ${path.module}/k3s.yaml ${var.master_app_manifest_url}"
  }
}




output "ssh_access" {
  value = "Use the repos private key: ssh -i $local.public_key_file $var.admin_user@{public_ip_address}
}

output "vm_public_ips" {
  value       = azurerm_public_ip.public_ip[*].ip_address
  description = "Public IPs of each of the nodes"
}

output "load_balancer_ip" {
  value       = azurerm_public_ip.k3s_lb_ip.ip_address
  description = "Public IP of the Kubernetes API load balancer"
}

output "kubeconfig_instructions" {
  value = "Run: export KUBECONFIG=./k3s.yaml && kubectl get nodes"
}

output "argocd_access" {
  description = "How to reach the Argo CD UI and read the initial admin password"
  value = [
    "http://${local.argocd_hostname}",
    "User: admin",
    "Password: kubectl -n default get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo",
  ]
}

output "mongodb_access" {
  description = "Replica set connection endpoints. Terraform stores the hostname in the mongodb-external-access ConfigMap and the generated passwords in the mongodb-credentials Secret. The app's PreSync hook copies the hostname onto the Application before MongoDB is created."
  value = [
    "mongodb://appuser:<password>@${join(",", [for port in local.mongodb_node_ports : "${local.mongodb_advertised_host}:${port}"])}/mydatabase?replicaSet=rs0",
    "App password: kubectl -n default get secret mongodb-credentials -o jsonpath='{.data.mongodb-passwords}' | base64 -d; echo",
    "Root password: kubectl -n default get secret mongodb-credentials -o jsonpath='{.data.mongodb-root-password}' | base64 -d; echo",
    "Replica set key: kubectl -n default get secret mongodb-credentials -o jsonpath='{.data.mongodb-replica-set-key}' | base64 -d; echo",
  ]
}

output "app_access" {
  description = "How to reach the Node.js app (hostless Ingress; sslip.io name is for DNS only)"
  value = [
    "http://${local.app_hostname}",
  ]
}
