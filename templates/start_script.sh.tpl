#!/bin/bash
# Minimal wrapper rendered by Terraform to pass sensitive values into the
# first-boot script and fetch the actual bootstrap from a URL to avoid 16KB limits.

set -euo pipefail

# Export token as an environment variable for bootstrap.sh to consume
export CF_API_TOKEN="${cf_api_token}"

# Also write the token to a root-only on-disk location for consumers that expect a file
mkdir -p /etc/bootstrap-secrets
chmod 700 /etc/bootstrap-secrets
printf %s "$CF_API_TOKEN" > /etc/bootstrap-secrets/cf_api_token
chmod 600 /etc/bootstrap-secrets/cf_api_token

# Download and execute bootstrap.sh from the provided URL
BOOTSTRAP_TMP="/root/bootstrap.sh"
/usr/bin/curl -fsSL "${bootstrap_url}" -o "$BOOTSTRAP_TMP"
chmod +x "$BOOTSTRAP_TMP"

# Execute
bash "$BOOTSTRAP_TMP"
