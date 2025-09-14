variable "api_key" {
  description = "Cudo API key"
  type        = string
  sensitive   = true
}

variable "project_id" {
  description = "Cudo project ID"
  type        = string
}

variable "data_center_id" {
  description = "Cudo data center ID (e.g., gb-bournemouth-1)"
  type        = string
}

variable "image_id" {
  description = "OS image identifier (e.g., ubuntu-24-04)"
  type        = string
}

variable "vcpus" {
  description = "Number of vCPUs for the VM"
  type        = number
}

variable "memory_gib" {
  description = "RAM in GiB for the VM"
  type        = number
}

variable "boot_disk_size" {
  description = "Boot disk size in GiB"
  # Intentionally leaving type unspecified to accept number or string (matches current tfvars)
}

variable "ssh_key_source" {
  description = "Where to pull SSH keys from: user, project, or custom"
  type        = string
}

# Declared because it's present in terraform.tfvars
variable "cudo_platform" {
  description = "Label for platform/environment"
  type        = string
}
