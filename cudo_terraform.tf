terraform {
  required_providers {
    cudo = {
      source  = "CudoVentures/cudo"
      version = "0.11.1"
    }
  }
}

provider "cudo" {
  api_key    = var.api_key
  project_id = var.project_id
}

# 1TB storage disk to attach to the VM
resource "cudo_storage_disk" "ubuntu_mirror_storage" {
  data_center_id = var.data_center_id
  id             = "cudo-ubuntu-mirror-disk1"
  size_gib       = 1024
}

# Single VM for the Ubuntu mirror
resource "cudo_vm" "instance" {
  depends_on     = [cudo_storage_disk.ubuntu_mirror_storage]
  id             = "cudo-ubuntu-mirror"
  machine_type   = "intel-broadwell"
  data_center_id = var.data_center_id
  memory_gib     = var.memory_gib
  vcpus          = var.vcpus
  boot_disk = {
    image_id = var.image_id
    size_gib = var.boot_disk_size
  }
  storage_disks = [
    {
      disk_id = cudo_storage_disk.ubuntu_mirror_storage.id
    }
  ]
  max_price_hr   = 10.000
  ssh_key_source = var.ssh_key_source
}
