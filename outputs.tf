output "public_ip" {
  description = "Public IP of vm-app. Connect with the ssh_command output."
  value       = azurerm_public_ip.app.ip_address
}

output "private_ip" {
  value = azurerm_network_interface.app.private_ip_address
}

output "resource_group" {
  value = azurerm_resource_group.lab.name
}

output "ssh_command" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.app.ip_address}"
}
