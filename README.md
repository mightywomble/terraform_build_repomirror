# Cudo Ubuntu Mirror Infrastructure (Terraform)

This repository contains Terraform code that provisions a single Cudo VM named "cudo-ubuntu-mirror" in the Bournemouth data center, with:
- CPU-only machine type (no GPUs)
- 2 vCPUs and 4 GiB RAM
- 200 GiB boot disk running Ubuntu 24.04
- An additional 1 TiB storage disk attached to the VM

It is written for absolute beginners to Terraform. Follow the steps below to install Terraform, configure your variables, and create the infrastructure safely.

---

## Prerequisites

- A Linux Mint machine (Ubuntu-based). Commands below use bash.
- A Cudo API key with access to your project.
- Git installed.
- SSH keys available in your Cudo account (we use `ssh_key_source = "user"`).

Important: Never commit secrets to Git. Use environment variables or a local, ignored `terraform.tfvars` file.

---

## Install Terraform (Linux Mint / Ubuntu)

Use HashiCorp's official apt repository.

```bash path=null start=null
# 1) Install required packages
sudo apt-get update -y
sudo apt-get install -y gnupg software-properties-common curl

# 2) Add HashiCorp's GPG key and repo
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

# 3) Install terraform
sudo apt-get update -y
sudo apt-get install -y terraform

# Verify
terraform -version
```

---

## Repository layout

- `cudo/cudo_terraform.tf` — Main Terraform configuration:
  - Declares the Cudo provider and version
  - Creates a 1 TiB storage disk resource
  - Creates the VM resource and attaches the storage disk
  - References variables like `var.api_key`, `var.project_id`, `var.data_center_id`, etc.
- `cudo/terraform.tfvars` — Variable values for this environment (example values). You may override these locally or via environment variables.
- `cudo/variables.tf` — Variable declarations (types, names). In this repository it is encrypted; for public use you can declare variables yourself (see below) and provide values via env vars or tfvars.

Tip: For GitHub/public use, keep secrets out of version control. Prefer environment variables or a local `terraform.tfvars` in `.gitignore`.

---

## How variables are provided and used

This configuration expects the following inputs (among others):
- `api_key` (string): Your Cudo API key
- `project_id` (string): Cudo project ID
- `data_center_id` (string): Data center (e.g., `gb-bournemouth-1`)
- `image_id` (string): OS image identifier (e.g., `ubuntu-24-04`)
- `vcpus` (number): CPU count (currently 2)
- `memory_gib` (number): RAM in GiB (currently 4)
- `boot_disk_size` (number or string): Boot disk size in GiB (200)
- `ssh_key_source` (string): Where to pull SSH keys from (`user` or `project` or `custom`)

The values flow like this:
- You supply values via environment variables (recommended) or `terraform.tfvars`.
- The main config (`cudo_terraform.tf`) reads them as `var.<name>` and configures the provider and resources accordingly.

### Option A: Use environment variables (recommended for secrets)

```bash path=null start=null
# Do NOT print your secret to the terminal.
# Store it as an environment variable for Terraform to pick up.
export TF_VAR_api_key={{CUDO_API_KEY}}

# Non-secret values can also be provided via env vars (optional):
export TF_VAR_project_id=cudos-public-testnet
export TF_VAR_data_center_id=gb-bournemouth-1
export TF_VAR_image_id=ubuntu-24-04
export TF_VAR_vcpus=2
export TF_VAR_memory_gib=4
export TF_VAR_boot_disk_size=200
export TF_VAR_ssh_key_source=user
```

### Option B: Use a local terraform.tfvars (never commit secrets)

Create `cudo/terraform.tfvars` with your values. Example template:

```hcl path=null start=null
# cudo/terraform.tfvars (example template)
project_id       = "cudos-public-testnet"
cudo_platform    = "public-testnet"
boot_disk_size   = "200"
vcpus            = 2
memory_gib       = 4
data_center_id   = "gb-bournemouth-1"
api_key          = "{{CUDO_API_KEY}}"  # replace with your key; do not commit
ssh_key_source   = "user"
image_id         = "ubuntu-24-04"
```

### If you need variable declarations (variables.tf)

If your `variables.tf` is not available or is encrypted, you can create a simple one like this so Terraform knows the variables' names and types:

```hcl path=null start=null
variable "api_key" {}
variable "project_id" {}
variable "data_center_id" {}
variable "image_id" {}
variable "vcpus" { type = number }
variable "memory_gib" { type = number }
variable "boot_disk_size" {}
variable "ssh_key_source" {}
variable "cudo_platform" {}
```

---

## What this Terraform code does

- Creates a storage disk resource of 1024 GiB in `gb-bournemouth-1`.
- Creates a VM resource named `cudo-ubuntu-mirror`:
  - CPU-only machine type (e.g., `intel-broadwell`)
  - 2 vCPUs, 4 GiB RAM
  - 200 GiB boot disk from the `ubuntu-24-04` image
  - Attaches the 1 TiB storage disk to the VM
- Uses your SSH keys (according to `ssh_key_source`) so you can log in after provisioning.

---

## Initialize, plan, and apply

Run all commands from the `cudo/` directory.

```bash path=null start=null
cd cudo

# Initialize providers and modules
terraform init

# Optional but recommended: format and validate
terraform fmt -recursive
terraform validate

# Create a plan and save it to a file
terraform plan --out plan.out

# Apply exactly what was planned ("terraform run" is not a Terraform command)
terraform apply plan.out
```

### Verifying the deployment

```bash path=null start=null
# List resources in state
terraform state list

# Show detailed state, including attributes like IP addresses
terraform show
```

You can also verify the VM and disk in the Cudo portal.

---

## Making changes later

- Edit values in your environment variables or `terraform.tfvars` (e.g., RAM, boot disk size, image, data center).
- Run `terraform plan` to see proposed changes, then `terraform apply` to make them.

---

## Destroying the resources

When you're done and want to clean up:

```bash path=null start=null
cd cudo
terraform destroy
```

Terraform will prompt you for confirmation and then tear down the resources it created.

---

## Debugging and troubleshooting

- Syntax issues: run `terraform validate` to catch common mistakes.
- Provider/auth errors (e.g., 401/403): ensure `TF_VAR_api_key` is set and correct, and that your project ID is valid.
- Invalid IDs: double-check `data_center_id` (e.g., `gb-bournemouth-1`) and `image_id` (e.g., `ubuntu-24-04`).
- Plan/apply errors: re-run with logging enabled to capture more detail.

Enable logs:
```bash path=null start=null
# Options: TRACE, DEBUG, INFO, WARN, ERROR
export TF_LOG=DEBUG
# Optionally write logs to a file
export TF_LOG_PATH=./terraform-debug.log

terraform plan --out plan.out
terraform apply plan.out
```

Inspect state and attributes:
```bash path=null start=null
terraform state list
terraform state show <resource_address>
# Example:
# terraform state show cudo_vm.instance
```

If a run gets stuck or a resource drifts, try:
- `terraform refresh` or `terraform apply -refresh-only` to sync state
- `terraform taint <resource_address>` to force recreation on next apply (use cautiously)

---

## Notes on security

- Do not commit API keys or sensitive data. Prefer environment variables (`TF_VAR_*`).
- If you use a local `terraform.tfvars`, add it to `.gitignore`.
- If `variables.tf` is encrypted or unavailable, create your own variable declarations as shown above.