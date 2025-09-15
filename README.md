
# CUDOS Ubuntu APT Mirror on Cudo (Terraform)

This repository provisions a single VM on Cudo, prepares a 1 TiB data disk for an Ubuntu APT mirror, configures UFW and Nginx, and integrates with Cloudflare for DNS and TLS. It is written to be approachable for absolute beginners while remaining robust and idempotent for repeatable operations.

If you are new to Terraform, start with the quick start. Then read the detailed sections to understand every moving piece, how secrets are handled, and how to verify the deployment end-to-end.

## some Information

[What is Terraform](https://www.theknowledgeacademy.com/blog/what-is-terraform/)

[Terraform for Beginners](https://www.youtube.com/watch?v=-ArZE3I24eU)

[Terraform in 15 Mins (Love this series)](https://www.youtube.com/watch?v=l5k1ai_GBDE)

[Terraform Provider - Cudo](https://registry.terraform.io/providers/CudoVentures/cudo/latest)

[What is a Terraform Provider?](https://www.youtube.com/watch?v=mvtEgID9AaM)




## Table of contents

- [Quick start (beginner-friendly)](#quick-start-beginner-friendly)
- [What this deploys](#what-this-deploys)
- [Repository tour (what each file does)](#repository-tour-what-each-file-does)
- [Variables and secrets (and how we keep them safe)](#variables-and-secrets-and-how-we-keep-them-safe)
- [Secrets management and 1Password](#secrets-management-and-1password)
- [Cloudflare DNS and certificates](#cloudflare-dns-and-certificates)
- [Why bootstrap.sh is downloaded at boot (16 KB limit)](#why-bootstrapsh-is-downloaded-at-boot-16-kb-limit)
- [Install Terraform (Linux, macOS, Windows)](#install-terraform-linux-macos-windows)
- [Terraform workflow explained](#terraform-workflow-explained)
- [State, plans, and files Terraform creates](#state-plans-and-files-terraform-creates)
- [Run it: commands and what to expect](#run-it-commands-and-what-to-expect)
- [Verify on the server (logs, screen, UFW, Nginx, certs, mounts)](#verify-on-the-server-logs-screen-ufw-nginx-certs-mounts)
- [Idempotence: what it means and why it matters here](#idempotence-what-it-means-and-why-it-matters-here)
- [Listing available images (optional)](#listing-available-images-optional)
- [Troubleshooting](#troubleshooting)

---

## Quick start (beginner-friendly)

Follow these steps. You don’t need prior Terraform experience.

1) Install Terraform
- Linux (Ubuntu/Debian-like): see [Install Terraform](#install-terraform-linux-macos-windows)
- macOS (Homebrew): see [Install Terraform](#install-terraform-linux-macos-windows)
- Windows (winget or Chocolatey): see [Install Terraform](#install-terraform-linux-macos-windows)

2) Get the repository
```bash path=null start=null
git clone https://github.com/mightywomble/terraform_build_repomirror.git
cd terraform_build_repomirror
```

3) Fetch secrets.auto.tfvars from 1Password (or create it)
- We store a pre-filled secrets file in 1Password: “Patching Terraform secrets.auto” in the “service” vault.
- Place the file at the repository root as secrets.auto.tfvars. It is gitignored.
- If you need to create it manually, it should include at least:
```hcl path=null start=null
api_key       = "{{CUDO_API_KEY}}"                  # required for Cudo provider
cf_api_token  = "{{CLOUDFLARE_API_TOKEN}}"         # required for Cloudflare API
bootstrap_url = "https://raw.githubusercontent.com/<org>/<repo>/main/bootstrap.sh"

# Optional but recommended if you already have a Cloudflare Origin cert/key
cf_origin_cert_pem = <<EOF
-----BEGIN CERTIFICATE-----
...your certificate...
-----END CERTIFICATE-----
EOF

cf_origin_key_pem = <<EOF
-----BEGIN PRIVATE KEY-----
...your private key...
-----END PRIVATE KEY-----
EOF
```

4) Set non-secret values in terraform.tfvars
- Open terraform.tfvars and set values like project_id, data_center_id, image_id, vcpus, memory_gib, boot_disk_size, ssh_key_source.
- Change
-- project_id to match the project name you want to deploy into cudo compute
-- data_center_id to match the DC (bournmouth should be ok no GPU needed) 
-- ssh_key_source to project to use all the ssh keys in the cudo project (leave as user while testing)

- Example:
```hcl path=null start=null
project_id       = "cudos-public-testnet"
cudo_platform    = "public-testnet"
boot_disk_size   = "200"   # GiB
vcpus            = 2
memory_gib       = 4
data_center_id   = "gb-bournemouth-1"
ssh_key_source   = "user"
image_id         = "ubuntu-2404"
```

5) Initialize and validate
```bash path=null start=null
terraform init -upgrade
terraform fmt -recursive
terraform validate
```

6) Plan and apply
```bash path=null start=null
terraform plan --out plan.out
terraform apply plan.out
```

7) After apply: first boot and logs
- The VM boots and runs a tiny wrapper that downloads and executes bootstrap.sh.
- SSH might not be immediately available while the firewall and packages are being configured.
- See [Verify on the server](#verify-on-the-server-logs-screen-ufw-nginx-certs-mounts) for commands to check progress.

---

## What this deploys

- A VM (CPU-only) in the specified Cudo data center, with:
  - 2 vCPUs, 4 GiB RAM (configurable)
  - 200 GiB boot disk (configurable)
  - 1 TiB secondary storage disk for the APT mirror
- A startup process that:
  - Partitions, formats, and mounts /dev/sdb at /opt/apt
  - Installs and configures UFW, Nginx, curl, jq, screen, and apt-mirror
  - Configures apt-mirror to sync Ubuntu 24.04 (noble) repositories
  - Integrates with Cloudflare: creates/updates DNS A record and configures TLS
  - Configures an Nginx site that serves the mirror content over HTTPS
  - Starts apt-mirror in the background via screen (doesn’t block provisioning)

---

## Repository tour (what each file does)

- cudo_terraform.tf
  - Declares the Cudo provider and creates two resources:
    - cudo_storage_disk.ubuntu_mirror_storage (1 TiB data disk)
    - cudo_vm.instance (the VM)
  - Uses start_script to run a tiny wrapper rendered from a template.

- variables.tf
  - Declares all Terraform input variables used in this config, including Cudo settings, Cloudflare settings, and bootstrap_url.

- templates/start_script.sh.tpl
  - A minimal shell script rendered by Terraform on apply. It:
    - Exports CF_API_TOKEN into the environment
    - Writes CF_API_TOKEN and optional cert/key PEMs into /etc/bootstrap-secrets/ (root-only)
    - Downloads bootstrap.sh from bootstrap_url and executes it
  - This keeps the start script tiny and avoids the provider’s 16 KB limit.

- bootstrap.sh
  - The main automation script that runs on the VM. It:
    - Logs a configuration summary (with secrets masked)
    - Prepares and mounts the data disk at /opt/apt
    - Installs UFW, Nginx, curl, jq, screen, apt-mirror
    - Writes /etc/apt/mirror.list for Ubuntu 24.04
    - Resolves public IP, ensures Cloudflare Zone ID, and creates/updates the A record for SUBDOMAIN.DOMAIN
    - Installs a Cloudflare Origin certificate for Nginx from provided PEMs if available; otherwise attempts API creation once
    - Writes an Nginx server config for HTTPS, tests, and reloads Nginx
    - Starts apt-mirror in a screen session
  - The script is designed to be idempotent: safe to re-run without breaking existing setup.

- images_lookup.tf (optional helper)
  - Lets you list available images from the provider (read-only data source). Useful when choosing image_id.

- terraform.tfvars
  - Non-secret values for this environment.

- secrets.auto.tfvars
  - Secret values (gitignored). Terraform auto-loads *.auto.tfvars files.

- .gitignore
  - Ignores Terraform state/local artifacts and local secrets files.

---

## Variables and secrets (and how we keep them safe)

Key variables
- api_key (sensitive): Cudo API key for the provider.
- project_id, data_center_id, image_id, vcpus, memory_gib, boot_disk_size, ssh_key_source: VM configuration.
- cf_api_token (sensitive): Cloudflare API token used by bootstrap.sh.
- bootstrap_url: Public URL where the VM can download bootstrap.sh on first boot.
- cf_origin_cert_pem, cf_origin_key_pem (sensitive, optional): Provide these if you already have a Cloudflare Origin certificate and private key; the VM will install them and skip API creation.

Where secrets live
- Locally: secrets.auto.tfvars at the repo root.
  - This file is ignored by Git and should never be committed.
- On the VM (at boot): the wrapper writes secrets to /etc/bootstrap-secrets/ with root-only permissions.
  - CF token: /etc/bootstrap-secrets/cf_api_token
  - Origin cert/key (if provided): /etc/bootstrap-secrets/cf_origin_certificate.pem and ..._private_key.pem
- bootstrap.sh loads CF_API_TOKEN from env or from these files and logs only a masked preview, never the full value.

Why this matters
- Cloud API keys and TLS private keys grant powerful access. Leaking them can compromise infrastructure and traffic.
- By keeping secrets out of Git, out of the command history, and only on the VM with strict permissions, we reduce risk.

---

## Secrets management and 1Password

- We maintain a 1Password entry named “Patching Terraform secrets.auto” in the “service” vault.
- Use it to retrieve or patch your local secrets.auto.tfvars.
- Place secrets.auto.tfvars in the repository root. Terraform will auto-load it.
- Never commit secrets. If a secret is ever exposed, rotate/revoke it immediately.

---

## Cloudflare DNS and certificates

- DNS A record: bootstrap.sh fetches your public IP and:
  - Looks up the Zone ID for DOMAIN via the Cloudflare API
  - Creates or updates the A record for SUBDOMAIN.DOMAIN (proxied = true)
- Origin certificate for Nginx TLS:
  - Preferred: provide cf_origin_cert_pem and cf_origin_key_pem in secrets.auto.tfvars. The VM installs them to /etc/nginx/ssl and skips the API call.
  - If not provided but the files already exist on the VM, it reuses them.
  - Otherwise, it attempts to create a new origin cert via the Cloudflare API. Note: the private key is only returned on creation and cannot be retrieved later.
- The script also sets Cloudflare’s SSL/TLS mode to “Full (Strict)” for the zone (best effort).

---

## Why bootstrap.sh is downloaded at boot (16 KB limit)

Some providers enforce a small size on the start_script. To keep things maintainable and pass larger logic:
- We render a tiny wrapper as the start_script (templates/start_script.sh.tpl)
- The wrapper exports secrets, writes PEMs, and downloads bootstrap.sh from bootstrap_url
- This avoids size limits and keeps your logic centralized in bootstrap.sh under version control

---

## Install Terraform (Linux, macOS, Windows)

Linux (Ubuntu/Debian)
```bash path=null start=null
sudo apt-get update -y
sudo apt-get install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update -y
sudo apt-get install -y terraform
terraform -version
```

macOS (Homebrew)
```bash path=null start=null
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform -version
```

Windows
```powershell path=null start=null
# winget (Windows 10/11)
winget install HashiCorp.Terraform

# or Chocolatey
choco install terraform -y

terraform -version
```

---

## Terraform workflow explained

- terraform init: downloads providers and sets up the working directory. Run after cloning or when providers change.
- terraform fmt -recursive: formats .tf files for readability.
- terraform validate: checks config syntax and catches many common mistakes.
- terraform plan --out plan.out: produces a precise execution plan and writes it to plan.out.
- terraform apply plan.out: applies exactly what you reviewed in plan.out.
- terraform destroy: tears down resources created by the current configuration (use with care).
- terraform state list/show: inspects what is currently tracked in state and its attributes.

Tip: Always create and apply from a saved plan (plan.out) so what you execute is exactly what you reviewed.

---

## State, plans, and files Terraform creates

- terraform.tfstate and terraform.tfstate.backup
  - The real-time record of what was created and its attributes. Contains sensitive data; treat as secret.
  - In this repo, state is local (not remote). Do not commit these files.
- .terraform/ directory
  - Provider plugins and modules cache. Do not commit.
- .terraform.lock.hcl
  - Provider dependency locks. In this project it’s gitignored; many teams commit it. We follow the project’s current ignore rules.
- plan.out
  - A binary plan produced by terraform plan --out. You can keep it locally for the immediate apply; it’s not meant to be committed.

Our .gitignore is configured to keep all these out of version control, along with your secrets files.

---

## Run it: commands and what to expect

1) Prepare
```bash path=null start=null
terraform init -upgrade
terraform fmt -recursive
terraform validate
```

2) Plan and apply
```bash path=null start=null
terraform plan --out plan.out
terraform apply plan.out
```

3) Getting the VM’s IP
- Use the Cudo portal, or inspect state:
```bash path=null start=null
terraform state show cudo_vm.instance | sed -n '1,200p'
```
- Look for network/addresses fields provided by the provider.

4) First SSH attempt
- SSH may be blocked briefly while UFW is configured. Try again after a minute or two.
- If you see a host key mismatch (reused IP), clear the old known_hosts entry:
```bash path=null start=null
ssh-keygen -R <VM_PUBLIC_IP>
```

---

## Verify on the server (logs, screen, UFW, Nginx, certs, mounts)

SSH to the VM when it’s ready.

Logs and config summary
```bash path=null start=null
sudo tail -n 200 /root/postinstall.log
```
- Near the top you’ll see lines like NAME: value; secrets are masked. You should see:
  - CF_API_TOKEN: abcd****wxyz
  - CF_API_TOKEN_SOURCE: /etc/bootstrap-secrets/cf_api_token

apt-mirror background job (screen)
```bash path=null start=null
screen -ls            # should show a session named "aptmirror"
screen -r aptmirror   # attach; Ctrl+A then D to detach
```

Disk and mount
```bash path=null start=null
df -h | grep /opt/apt
ls -l /opt/apt
```

UFW
```bash path=null start=null
sudo ufw status numbered
```

Nginx
```bash path=null start=null
sudo nginx -t
sudo systemctl status nginx --no-pager
ls -l /etc/nginx/ssl
```
- Expect to see ${SUBDOMAIN}.${DOMAIN}.pem and .key present.
- Test HTTPS locally on the VM:
```bash path=null start=null
curl -Ik https://<SUBDOMAIN>.<DOMAIN>/
```

Cloudflare DNS
- The A record for <SUBDOMAIN>.<DOMAIN> should exist and be proxied. Check the Cloudflare dashboard.

Reboot safety
- After a reboot, the mount, UFW rules, certificates, and Nginx config should persist. The design is idempotent (see next section).

---

## Idempotence: what it means and why it matters here

Idempotence means you can run the same script multiple times and, after the first successful run, nothing breaks or regresses. Only missing bits are added; existing correct settings are left alone.

bootstrap.sh uses checks before actions, for example:
- Disk: only partitions/formats/mounts if needed, and writes /etc/fstab for persistence.
- UFW: installs/enables and opens the required ports if not already configured.
- apt-mirror: writes the config if needed and launches a background sync; re-runs don’t spawn duplicates.
- Cloudflare DNS: creates the A record if missing; updates it only if the IP changed.
- TLS: if cert/key files exist on disk, reuse them; otherwise install from Terraform-provided PEMs; only if neither exists does it attempt API creation.
- Nginx: writes the site config, tests it, and reloads; subsequent runs won’t duplicate.

Idempotence is crucial for safe re-runs after partial failures, for upgrades, and for predictable recoveries.

---

## Listing available images (optional)

We include a helper to list VM images exposed by the provider.
```bash path=null start=null
terraform apply -target=data.cudo_vm_images.available -auto-approve
terraform output -json available_images | jq -r '.[] | "\(.id)\t\(.name)\t\(.description)"' | head -n 50
```
Pick the image_id you want (e.g., ubuntu-2404) and set it in terraform.tfvars.

---

## Troubleshooting

- start_script too large: We already solved this by downloading bootstrap.sh at boot.
- CF_API_TOKEN not set: Make sure secrets.auto.tfvars includes cf_api_token and that bootstrap_url is reachable. The log shows CF_API_TOKEN_SOURCE when loaded.
- Origin certificate creation failed: If a cert already exists in Cloudflare, the API won’t return its private key. Either provide cf_origin_cert_pem/key via secrets.auto.tfvars, or revoke and recreate.
- SSH errors or timeouts: UFW may block briefly; retry. For host key mismatch: ssh-keygen -R <IP>.
- Nothing seems to happen: tail -f /root/postinstall.log and check for errors. Verify network access to bootstrap_url and to Cloudflare APIs.
- apt-mirror takes hours: That’s expected on first sync. Use screen -r aptmirror to watch progress.

---


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
- Invalid IDs: double-check `data_center_id` (e.g., `gb-bournemouth-1`) and `image_id` (e.g., `ubuntu-2404`).
- VM bootstrap logs: check /root/postinstall.log (created by bootstrap.sh) for any setup errors.
- apt-mirror run: use screen -ls and screen -r aptmirror to view the ongoing mirror sync; it can take hours.
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
