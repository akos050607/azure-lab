variable "subscription_id" {
  description = "Azure subscription to deploy into. Not defaulted on purpose — see providers.tf."
  type        = string
}

variable "location" {
  description = "Azure region. Frankfurt: closest to Budapest, and cheap."
  type        = string
  default     = "germanywestcentral"
}

variable "zone" {
  description = <<-EOT
    Availability zone. Not cosmetic on this subscription: several VM sizes are
    restricted per zone rather than per region, so the zone is what decides
    whether a size is usable at all. See FAILURES.md.
  EOT
  type        = string
  default     = "1"
}

variable "vm_size" {
  description = <<-EOT
    Standard_B1s is what the plan called for and what this subscription cannot
    have — it carries a Location-scoped restriction in this region. D2als_v7 is
    restricted only in zone 2, so it works in zone 1.
  EOT
  type        = string
  default     = "Standard_D2als_v7"
}

variable "admin_username" {
  type    = string
  default = "akos"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_source" {
  description = "CIDR permitted to reach port 22. A single address, never 0.0.0.0/0."
  type        = string

  validation {
    condition     = var.allowed_ssh_source != "0.0.0.0/0"
    error_message = "Refusing to open SSH to the whole internet."
  }
}

variable "vnet_cidr" {
  description = <<-EOT
    Chosen against a written list rather than picked because it looked free:
      10.42.0.0/16   k3s pod CIDR      (homelab)
      10.43.0.0/16   k3s service CIDR  (homelab)
      100.64.0.0/10  Tailscale
    An evening was already lost to a 10.42.0.0/24 collision at home.
  EOT
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.10.1.0/24"
}

variable "tags" {
  type = map(string)
  default = {
    owner   = "akos"
    purpose = "interview-lab"
    session = "B3-S3"
  }
}
