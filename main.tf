# The same network Session 2 built by hand with `az`, declared instead.
#
# The shape is the point. On Hetzner a server is one `hcloud_server`. Here the
# same idea is eight resources with their own lifecycles, and that verbosity is
# not Terraform being awkward — it is Azure genuinely modelling the network card
# and the public address as separate things you can move, keep or bill for on
# their own.

resource "azurerm_resource_group" "lab" {
  name     = "rg-tf-01"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-lab"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_network_security_group" "app" {
  name                = "nsg-app"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  # Deliberately no inline `security_rule` blocks. Rules are separate resources
  # below, and the two styles cannot be mixed: declare a rule inline AND as an
  # azurerm_network_security_rule and the two fight, each removing the other's
  # rule on alternate applies.
  #
  # Same failure as an HPA and a Deployment both owning `replicas`, and as CI
  # running `kubectl apply` into a cluster Argo CD reconciles. One writer per
  # field — the rule holds across tools.
}

resource "azurerm_network_security_rule" "ssh" {
  name                        = "allow-ssh"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.app.name

  priority  = 100
  direction = "Inbound"
  access    = "Allow"
  protocol  = "Tcp"

  source_port_range          = "*"
  destination_port_range     = "22"
  source_address_prefix      = var.allowed_ssh_source
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "https" {
  name                        = "allow-https"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.app.name

  priority  = 110
  direction = "Inbound"
  access    = "Allow"
  protocol  = "Tcp"

  source_port_range          = "*"
  destination_port_range     = "443"
  source_address_prefix      = "Internet"
  destination_address_prefix = "*"
}

# The association is its own resource rather than a field on the subnet, and
# that is the single most useful thing in this file.
#
# azurerm_subnet also accepts the NSG inline. Set it in both places and every
# `apply` flaps: one writer sets it, the other clears it, forever. Terraform
# reports a diff each run and neither side is wrong — they simply both believe
# they own the field.
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_public_ip" "app" {
  name                = "pip-app"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"

  # Matched to the VM's zone. A zonal public IP can only attach to a resource in
  # the same zone, so this is not decoration.
  zones = [var.zone]
  tags  = var.tags
}

resource "azurerm_network_interface" "app" {
  name                = "nic-app"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.app.id
  }
}

resource "azurerm_linux_virtual_machine" "app" {
  name                = "vm-app"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  size                = var.vm_size
  zone                = var.zone
  admin_username      = var.admin_username
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.app.id]

  # Password authentication is off by default on this resource, which is the
  # right default. Stated explicitly so nobody has to go and check.
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
