# Ubuntu Mirror Infrastructure (Terraform)

This repository contains Terraform code that provisions a single Cudo VM named "cudo-ubuntu-mirror" in the Bournemouth data center, with:
- CPU-only machine type (no GPUs)
- 2 vCPUs and 4 GiB RAM
- 200 GiB boot disk running Ubuntu 24.04
- An additional 1 TiB storage disk attached to the VM

It is written for absolute beginners to Terraform. Follow the steps below to install Terraform, configure your variables, and create the infrastructure safely.

---

## Prerequisites

- An Ubuntu Linux workstation machine (Ubuntu-based). Commands below use bash.
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

### Option B: Use local tfvars files (never commit secrets)

We recommend splitting secrets into a separate file which is ignored by Git.

1) Create `cudo/terraform.tfvars` with only non-secret values:

```hcl path=null start=null
# cudo/terraform.tfvars (checked in; no secrets)
project_id       = "cudos-public-testnet"
cudo_platform    = "public-testnet"
boot_disk_size   = "200"
vcpus            = 2
memory_gib       = 4
data_center_id   = "gb-bournemouth-1"
ssh_key_source   = "user"
image_id         = "ubuntu-24-04"
```

2) Create `cudo/secrets.auto.tfvars` with your secret (this file is .gitignored):

```hcl path=null start=null
# cudo/secrets.auto.tfvars (ignored by Git)
api_key = "{{CUDO_API_KEY}}"
```

Terraform automatically loads any `*.auto.tfvars` files in the working directory, so you don't need to pass `-var-file` flags.

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
# Running Terraform, what is going on..

Think of building infrastructure with Terraform like assembling a complex piece of furniture. You need to follow a clear set of steps to ensure it's built correctly and exactly as the instructions intended. These commands are those steps.

## Initialization & Validation
First, you need to prepare your workspace and check your instructions.

terraform init: This is the very first command you run in a new Terraform project. It's like opening the furniture box and laying out all the tools and parts. This command downloads the necessary plugins (called providers) that allow Terraform to communicate with your cloud provider (like AWS, Azure, or Google Cloud). It only needs to be run once at the beginning or whenever you add a new provider.

terraform fmt -recursive & terraform validate: These are your quality checks. The fmt command tidies up your code, making it neat and easy to read, which is helpful when working in a team. The validate command runs a quick check for any syntax errors or typos in your configuration files. Think of this as proofreading the instruction manual to make sure it's written correctly before you start building.

## Planning & Applying Changes
Next, you create a blueprint of what you're going to build and then execute that plan.

terraform plan --out plan.out: This is arguably the most important command. It creates an execution plan, which is a detailed preview of exactly what Terraform will do. It will show you which resources it will create, change, or destroy without actually making any changes. By using the --out plan.out flag, you save this exact plan to a file. This is like getting a final, itemized quote from a contractor before they start work, ensuring there are no surprises.

terraform apply plan.out: This command executes the plan you just saved. It takes the plan.out file and builds the infrastructure exactly as described in it. By applying a saved plan, you guarantee that the actions Terraform takes are the same ones you reviewed and approved, preventing any accidental changes. This is the "build" step where the furniture is actually assembled according to the blueprint.

## Verifying the Result
Finally, after the work is done, you inspect the final product.

terraform state list & terraform show: These commands let you see what you've built. terraform state list gives you a simple inventory of all the resources Terraform is currently managing. For a more detailed view, terraform show displays all the attributes of those resources, such as their IP addresses, IDs, and other settings. This is your way of looking at the finished piece of furniture and confirming all the parts are in the right place and it matches the design.

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
# If you chose not to use secrets.auto.tfvars, you could also provide var files explicitly, e.g.:
# terraform plan --var-file=terraform.tfvars --var-file=secrets.auto.tfvars --out plan.out

# Apply exactly what was planned ("terraform run" is not a Terraform command)
terraform apply plan.out
# Or with explicit var files (if not using auto.tfvars):
# terraform apply -var-file=terraform.tfvars -var-file=secrets.auto.tfvars plan.out
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
