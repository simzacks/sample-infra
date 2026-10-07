locals {
  # Static private IPs for etcd peers. Must be in the subnet and cannot be .[1-3].
  # Node 0 is the bootstrap/join endpoint (Azure LB hairpin cannot be used to join).
  node_private_ips = [for i in range(var.count_qty) : cidrhost(azurerm_subnet.subnet.address_prefixes[0], 10 + i)]
  control_plane_ip = local.node_private_ips[0]
  argocd_hostname  = "argocd.${azurerm_public_ip.k3s_lb_ip.ip_address}.sslip.io"
}

resource "random_password" "k3s_token" {
  length  = 32
  special = false
}

resource "azurerm_resource_group" "rg" {
  name = "k3s-rg"
  location = "denmarkeast"
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
    subnet_id = azurerm_subnet.subnet.id
    public_ip_ids = join(",", azurerm_public_ip.public_ip[*].id)

  }
}

resource "azurerm_virtual_network" "vnet" {
  name                 = "vnet1"
  resource_group_name  = azurerm_resource_group.rg.name
  address_space        = ["10.0.0.0/16"]
  location             = azurerm_resource_group.rg.location
  depends_on = [time_sleep.azure_api_buffer]
}

resource "azurerm_subnet" "subnet" {
  name                 = "subnet1"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

}

resource "azurerm_public_ip" "public_ip" {
  count                = var.count_qty
  name                 = "public-ip${count.index}"
  resource_group_name  = azurerm_resource_group.rg.name
  location             = azurerm_resource_group.rg.location
  allocation_method    = "Static"
  sku                  = "Standard"
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

resource "azurerm_lb_rule" "k3s_lb_router" {
  loadbalancer_id                = azurerm_lb.k3s_api_lb.id
  name                           = "k3s-api-6443"
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "k3s-api-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.k3s_api.id]
  probe_id                       = azurerm_lb_probe.k3s_lb_probe.id
}

resource "azurerm_lb_probe" "argocd_https" {
  loadbalancer_id = azurerm_lb.k3s_api_lb.id
  name            = "argocd-https-probe"
  protocol        = "Tcp"
  port            = 443
}

resource "azurerm_lb_rule" "argocd_https" {
  loadbalancer_id                = azurerm_lb.k3s_api_lb.id
  name                           = "argocd-https-443"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "k3s-api-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.k3s_api.id]
  probe_id                       = azurerm_lb_probe.argocd_https.id
}

resource "azurerm_network_interface" "nics" {
  count               = var.count_qty
  name                = "nic-${count.index}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  ip_configuration {
    name              = "nic_config"
    # subnet_id         = azurerm_subnet.subnet.id
    # By reading the ID through the time_sleep trigger, Terraform is forced
    # to process this sleep resource during creation and destruction.
    subnet_id                     = time_sleep.subnet_destroy_buffer.triggers["subnet_id"]
    private_ip_address_allocation = "Static"
    private_ip_address            = local.node_private_ips[count.index]
    public_ip_address_id = split(",", time_sleep.subnet_destroy_buffer.triggers["public_ip_ids"])[count.index]
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "k3s_api" {
  count                   = var.count_qty
  network_interface_id    = azurerm_network_interface.nics[count.index].id
  ip_configuration_name   = "nic_config"
  backend_address_pool_id = azurerm_lb_backend_address_pool.k3s_api.id
  # LB rule updates can PUT the same NIC/pool; wait until rules exist.
  depends_on = [
    azurerm_lb_rule.k3s_lb_router,
    azurerm_lb_rule.argocd_https,
  ]
}

resource "azurerm_linux_virtual_machine" "vms" {
  count               = var.count_qty
  name                = "vm-${count.index}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  # Every node is control-plane + etcd + worker (2 vCPU / 4 GiB)
  size                = "Standard_B2als_v2"
  admin_username      = var.admin_user
  network_interface_ids = [azurerm_network_interface.nics[count.index].id]
  depends_on = [
    azurerm_network_interface_backend_address_pool_association.k3s_api,
    azurerm_network_interface_security_group_association.k3s_nsg_assoc,
  ]
  admin_ssh_key {
    username          = var.admin_user
    public_key        = file("~/.ssh/id_rsa.pub")
  }
  os_disk {
    name              = "osdisk-${count.index}"
    storage_account_type = "Premium_LRS"
    caching           = "ReadWrite"
    disk_size_gb      = 64
  }
  source_image_reference {
    publisher         = "Canonical"
    offer             = "ubuntu-26_04-lts"
    sku               = "server"
    version           = "latest"
  }

  custom_data         = (count.index == 0 ?
                            base64encode(templatefile("${path.module}/scripts/k3s_control_plane.sh",
                                {
                                  K3S_TOKEN    = random_password.k3s_token.result
                                  K3S_VERSION  = var.k3s_version
                                  LB_PUBLIC_IP = azurerm_public_ip.k3s_lb_ip.ip_address
                                  PRIVATE_IP   = local.control_plane_ip
                                })) :
                            base64encode(templatefile("${path.module}/scripts/k3s_worker.sh",
                                {
                                  K3S_TOKEN        = random_password.k3s_token.result
                                  K3S_VERSION      = var.k3s_version
                                  LB_PUBLIC_IP     = azurerm_public_ip.k3s_lb_ip.ip_address
                                  PRIVATE_IP       = local.control_plane_ip
                                }))
                        )

}

resource "azurerm_network_security_group" "k3s_nsg" {
    name                = "k3s-nsg"
    location            = azurerm_resource_group.rg.location
    resource_group_name = azurerm_resource_group.rg.name
    security_rule {
        name                 = "allow-ssh"
        priority             = 100
        direction            = "Inbound"
        access               = "Allow"
        protocol             = "Tcp"
        source_address_prefix  = "*"
        source_port_range      = "*"
        destination_port_range = "22"
        destination_address_prefix = "*"
    }
    security_rule {
        name                 = "allow-k3s"
        priority             = 101
        direction            = "Inbound"
        access               = "Allow"
        protocol             = "Tcp"
        source_address_prefix  = "*"
        source_port_range      = "*"
        destination_port_range = "6443"
        destination_address_prefix = "*"
    }
    security_rule {
        name                 = "allow-flannel-vxlan"
        priority             = 102
        direction            = "Inbound"
        access               = "Allow"
        protocol             = "Udp"
        source_address_prefix  = azurerm_subnet.subnet.address_prefixes[0]
        source_port_range      = "*"
        destination_port_range = "8472"
        destination_address_prefix = "*"
    }
    security_rule {
        name                 = "allow-k3s-metrics"
        priority             = 103
        direction            = "Inbound"
        access               = "Allow"
        protocol             = "Tcp"
        source_address_prefix  = "*"
        source_port_range      = "*"
        destination_port_range = "10250"
        destination_address_prefix = "*"
    }
    security_rule {
        name                       = "allow-etcd"
        priority                   = 104
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_address_prefix      = azurerm_subnet.subnet.address_prefixes[0]
        source_port_range          = "*"
        destination_port_ranges    = ["2379", "2380"]
        destination_address_prefix = "*"
    }
    security_rule {
        name                       = "allow-https"
        priority                   = 105
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_address_prefix      = "*"
        source_port_range          = "*"
        destination_port_range     = "443"
        destination_address_prefix = "*"
    }
}    

resource "azurerm_network_interface_security_group_association" "k3s_nsg_assoc" {
    count = var.count_qty
    network_interface_id = azurerm_network_interface.nics[count.index].id
    network_security_group_id = azurerm_network_security_group.k3s_nsg.id
    # Same NIC as the backend-pool association; serialize the two PUTs.
    # depends_on cannot use count.index; waiting on the whole set is valid.
    depends_on = [azurerm_network_interface_backend_address_pool_association.k3s_api]
}

resource "null_resource" "get_kubeconfig" {
    depends_on = [ azurerm_linux_virtual_machine.vms ]
    triggers = {
      control_plane_id = azurerm_linux_virtual_machine.vms[0].id
      api_lb_ip        = azurerm_public_ip.k3s_lb_ip.ip_address
    }
    provisioner "local-exec" {
        command = "bash ${path.module}/scripts/get_kubectl.sh ${azurerm_linux_virtual_machine.vms[0].admin_username} ${azurerm_public_ip.public_ip[0].ip_address} ${path.module} ${azurerm_public_ip.k3s_lb_ip.ip_address}"
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

output "vm_public_ips" {
    value             = azurerm_public_ip.public_ip[*].ip_address
    description       = "Public IPs of each of the nodes"
}

output "k3s_lb_ip" {
    value       = azurerm_public_ip.k3s_lb_ip.ip_address
    description = "Public IP of the Kubernetes API load balancer"
}

output "kubeconfig_instructions" {
  value = "Run: export KUBECONFIG=./k3s.yaml && kubectl get nodes"
}

output "argocd_access" {
    description = "How to reach the Argo CD UI and read the initial admin password"
    value       = <<-EOT
https://${local.argocd_hostname}
The browser will warn on Traefik's default certificate.
User: admin
Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
Fallback: export KUBECONFIG=./k3s.yaml && kubectl -n argocd port-forward svc/argocd-server 8080:443
EOT
}
