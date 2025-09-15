#!/bin/bash

# --- Non-Interactive Idempotent Server Setup Script ---
# This script automates the setup of a partitioned disk, system firewall,
# apt-mirror, and a secure Nginx frontend with Cloudflare integration.
# It is designed to run without user input.

# --- Configuration ---
readonly LOG_FILE="/root/postinstall.log"
# Directory containing this script (used for local, untracked secrets files)
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Disk and Mount Configuration --
readonly DISK_PATH="/dev/sdb"
readonly PARTITION_PATH="/dev/sdb1"
readonly MOUNT_POINT="/opt/apt"

# -- apt-mirror Configuration --
readonly MIRROR_CONFIG_FILE="/etc/apt/mirror.list"
readonly APT_MIRROR_BASE_PATH="${MOUNT_POINT}/mirror" # Used by Nginx config

# -- Cloudflare & Nginx Configuration --
# The domain you are configuring in Cloudflare (e.g., cudos.org)
readonly DOMAIN="cudos.org"
# The subdomain for the mirror (e.g., 'mirror' for mirror.cudos.org)
readonly SUBDOMAIN="mirror"

# --- Pre-run Checks & Logging Setup ---
# Must be run as root
if (( EUID != 0 )); then
   echo "This script must be run as root. Please use 'sudo'."
   exit 1
fi

# Redirect all output (stdout and stderr) to the log file and console
exec &> >(tee -a "$LOG_FILE")

# --- Helper Functions ---
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - INFO: $1"
}

log_success() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] - \e[32mSUCCESS\e[0m: $1"
}

log_error_exit() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] - \e[31mERROR\e[0m: $1" >&2
    exit 1
}

# Loads CF_API_TOKEN from common secret file locations if not provided in the environment.
# Precedence: existing env var > /etc/bootstrap-secrets/cf_api_token > /root/.config/bootstrap/cf_api_token > ${SCRIPT_DIR}/cudo/cf_api_token > ${SCRIPT_DIR}/.env > ${SCRIPT_DIR}/.env.cloudflare
# Supported file formats:
#  - Plain file containing only the token (first line used)
#  - .env-style files containing a line like: CF_API_TOKEN="..."
load_cf_api_token() {
    # If already set, don't override
    if [[ -n "$CF_API_TOKEN" ]]; then
        return 0
    fi

    local candidates=(
        "/etc/bootstrap-secrets/cf_api_token"
        "/root/.config/bootstrap/cf_api_token"
        "${SCRIPT_DIR}/cudo/cf_api_token"
        "${SCRIPT_DIR}/.env"
        "${SCRIPT_DIR}/.env.cloudflare"
        "${PWD}/cudo/cf_api_token"
        "${PWD}/.env"
        "${PWD}/.env.cloudflare"
    )

    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            # If the file contains an assignment, parse it; else treat the whole content as the token
            if grep -qE '^\s*CF_API_TOKEN\s*=' "$f" 2>/dev/null; then
                CF_API_TOKEN=$(grep -E '^\s*CF_API_TOKEN\s*=' "$f" | tail -n1 | cut -d= -f2- | sed -E "s/^[[:space:]]*[\"']?//; s/[\"'][[:space:]]*$//")
            else
                CF_API_TOKEN=$(head -n1 "$f" | tr -d '\n\r\t ')
            fi
            export CF_API_TOKEN
            CF_API_TOKEN_SOURCE="$f"
            export CF_API_TOKEN_SOURCE
            log_action "Loaded CF_API_TOKEN from: $f"
            return 0
        fi
    done

    return 1
}

# Helpers to print config values in 'name: value' format
print_var() {
    local name="$1"; shift
    local val="$1"
    echo "${name}: ${val}"
}

mask_value() {
    local s="$1"
    local len=${#s}
    if [[ -z "$s" ]]; then
        echo "(empty)"
        return
    fi
    if (( len <= 8 )); then
        echo "****"
    else
        local head=${s:0:4}
        local tail=${s: -4}
        echo "${head}****${tail}"
    fi
}

print_secret_var() {
    local name="$1"; shift
    local val="$1"
    if [[ -z "$val" ]]; then
        echo "${name}: (not set)"
    else
        echo "${name}: $(mask_value "$val")"
    fi
}

# --- Main Script Logic ---
main() {
    log_action "Starting fully automated server setup."
    export DEBIAN_FRONTEND=noninteractive

    # Preload CF_API_TOKEN if available so we can log it
    if [[ -z "$CF_API_TOKEN" ]]; then
        load_cf_api_token || true
    fi

    log_action "--- Effective configuration at start ---"
    print_var "LOG_FILE" "$LOG_FILE"
    print_var "SCRIPT_DIR" "$SCRIPT_DIR"
    print_var "DISK_PATH" "$DISK_PATH"
    print_var "PARTITION_PATH" "$PARTITION_PATH"
    print_var "MOUNT_POINT" "$MOUNT_POINT"
    print_var "MIRROR_CONFIG_FILE" "$MIRROR_CONFIG_FILE"
    print_var "APT_MIRROR_BASE_PATH" "$APT_MIRROR_BASE_PATH"
    print_var "DOMAIN" "$DOMAIN"
    print_var "SUBDOMAIN" "$SUBDOMAIN"
    print_var "DEBIAN_FRONTEND" "$DEBIAN_FRONTEND"
    # Derived preview values
    local __full_domain_preview="${SUBDOMAIN}.${DOMAIN}"
    print_var "FULL_DOMAIN" "$__full_domain_preview"
    # Mask secrets in logs
    print_secret_var "CF_API_TOKEN" "$CF_API_TOKEN"
    print_var "CF_API_TOKEN_SOURCE" "${CF_API_TOKEN_SOURCE:-}" 

    # --- 1. Disk Preparation ---
    log_action "--- Section 1: Disk Setup ---"

    log_action "Checking for disk at ${DISK_PATH}..."
    if [ ! -b "$DISK_PATH" ]; then
        log_error_exit "Target disk ${DISK_PATH} not found. Aborting."
    fi
    log_success "Disk ${DISK_PATH} found."

    # Check for partition, create if it doesn't exist
    if [ ! -b "$PARTITION_PATH" ]; then
        log_action "Partition ${PARTITION_PATH} not found. Creating new partition..."
        (echo g; echo n; echo; echo; echo; echo w) | fdisk "$DISK_PATH"
        partprobe "$DISK_PATH"
        sleep 2
        [ ! -b "$PARTITION_PATH" ] && log_error_exit "Failed to create partition ${PARTITION_PATH}."
        log_success "Partition ${PARTITION_PATH} created."
    else
        log_action "Partition ${PARTITION_PATH} already exists. Skipping creation."
    fi

    # Check if mounted, format and mount if not
    if mountpoint -q "$MOUNT_POINT"; then
        log_success "Drive is already mounted at ${MOUNT_POINT}."
    else
        log_action "${MOUNT_POINT} is not a mountpoint. Formatting and mounting..."
        mkfs.ext4 -F "$PARTITION_PATH"
        log_success "Formatting complete."
        mkdir -p "$MOUNT_POINT"

        log_action "Updating /etc/fstab for persistent mount..."
        local uuid
        uuid=$(blkid -s UUID -o value "$PARTITION_PATH")
        [ -z "$uuid" ] && log_error_exit "Could not get UUID for ${PARTITION_PATH}."

        local fstab_entry="UUID=${uuid}    ${MOUNT_POINT}    ext4    defaults   0 0"
        if ! grep -qF "$fstab_entry" /etc/fstab; then
            echo "$fstab_entry" >> /etc/fstab
            log_success "Added entry to /etc/fstab."
        else
            log_action "/etc/fstab entry already exists."
        fi

        mount -a
        ! mountpoint -q "$MOUNT_POINT" && log_error_exit "Failed to mount ${PARTITION_PATH}."
        log_success "Successfully mounted ${PARTITION_PATH} at ${MOUNT_POINT}."
    fi

    # --- 2. System Update & Firewall ---
    log_action "--- Section 2: System & Firewall ---"

    log_action "Updating system packages..."
    apt-get update -q
    apt-get upgrade -y -q
    log_success "System update and upgrade complete."

    log_action "Installing and configuring UFW..."
    apt-get install -y -q ufw
    ufw limit 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    systemctl enable --now ufw > /dev/null 2>&1
    echo "y" | ufw enable
    log_success "UFW enabled and configured for ports 80, 443, and rate-limited SSH."
    log_action "Current UFW Status:"; ufw status numbered

    # --- 3. apt-mirror Setup ---
    log_action "--- Section 3: apt-mirror Setup ---"

    log_action "Installing apt-mirror and other required packages..."
    apt-get install -y -q apt-mirror screen curl jq nginx
    log_success "Packages apt-mirror, screen, curl, jq, and nginx are installed."

    log_action "Configuring ${MIRROR_CONFIG_FILE}..."
    [ -f "$MIRROR_CONFIG_FILE" ] && mv "$MIRROR_CONFIG_FILE" "${MIRROR_CONFIG_FILE}.bak.$(date +%F-%T)"

    cat <<EOF > "$MIRROR_CONFIG_FILE"
############# apt-mirror config #############
set base_path    ${MOUNT_POINT}
set mirror_path  $base_path/mirror
set skel_path    $base_path/skel
set var_path     $base_path/var
set cleanscript  $var_path/clean.sh
set defaultarch  amd64
set nthreads     10
set _tilde 0
############# Repositories to Mirror ###########
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
############# Clean Instructions ##############
clean http://archive.ubuntu.com/ubuntu
clean http://security.ubuntu.com/ubuntu
##############################################
EOF
    grep -q "set base_path    ${MOUNT_POINT}" "$MIRROR_CONFIG_FILE" && log_success "Configuration file for apt-mirror created." || log_error_exit "Failed to create apt-mirror config."

    # --- 4. Nginx & Cloudflare Setup ---
    log_action "--- Section 4: Nginx & Cloudflare Automation ---"

    # Ensure CF_API_TOKEN is available: prefer existing env var, else try to load from secrets files
    if [[ -z "$CF_API_TOKEN" ]]; then
        log_action "CF_API_TOKEN not set; attempting to load from secrets files..."
        if ! load_cf_api_token; then
            log_error_exit "CF_API_TOKEN is not set. Create one of these files: /etc/bootstrap-secrets/cf_api_token, /root/.config/bootstrap/cf_api_token, ${SCRIPT_DIR}/cudo/cf_api_token, or ${SCRIPT_DIR}/.env with CF_API_TOKEN=your_token"
        fi
    fi

    local SERVER_IP
    SERVER_IP=$(curl -s https://ipv4.icanhazip.com)
    [[ -z "$SERVER_IP" ]] && log_error_exit "Could not automatically determine public IP."
    log_action "Detected public IP as: ${SERVER_IP}"

    local FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"
    log_action "Configuring for domain: ${FULL_DOMAIN}"

    local ZONE_ID
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id')
    [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]] && log_error_exit "Could not find Zone ID for domain '${DOMAIN}'."
    log_success "Found Cloudflare Zone ID."

    log_action "Checking Cloudflare DNS record for ${FULL_DOMAIN}..."
    local DNS_RECORD_INFO
    DNS_RECORD_INFO=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${FULL_DOMAIN}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
    local DNS_RECORD_ID
    DNS_RECORD_ID=$(echo "$DNS_RECORD_INFO" | jq -r '.result[0].id')

    if [[ -z "$DNS_RECORD_ID" || "$DNS_RECORD_ID" == "null" ]]; then
        log_action "No existing record found. Creating new DNS 'A' record..."
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"${SUBDOMAIN}\",\"content\":\"${SERVER_IP}\",\"ttl\":1,\"proxied\":true}" | jq -e '.success == true' > /dev/null || log_error_exit "Failed to create DNS record."
        log_success "DNS 'A' record created."
    else
        local EXISTING_IP
        EXISTING_IP=$(echo "$DNS_RECORD_INFO" | jq -r '.result[0].content')
        if [[ "$EXISTING_IP" == "$SERVER_IP" ]]; then
            log_success "DNS record is already correctly configured."
        else
            log_action "IP address is incorrect. Updating DNS 'A' record..."
            curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${DNS_RECORD_ID}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"${SUBDOMAIN}\",\"content\":\"${SERVER_IP}\",\"ttl\":1,\"proxied\":true}" | jq -e '.success == true' > /dev/null || log_error_exit "Failed to update DNS record."
            log_success "DNS 'A' record updated."
        fi
    fi

    # Prepare SSL paths and ensure directory exists
    local SSL_DIR="/etc/nginx/ssl"
    local CERT_PATH="${SSL_DIR}/${FULL_DOMAIN}.pem"
    local KEY_PATH="${SSL_DIR}/${FULL_DOMAIN}.key"
    mkdir -p "${SSL_DIR}"

    # If Terraform provided cert/key, install them
    local BOOTSTRAP_CERT_SRC="/etc/bootstrap-secrets/cf_origin_certificate.pem"
    local BOOTSTRAP_KEY_SRC="/etc/bootstrap-secrets/cf_origin_private_key.pem"
    if [[ (! -s "$CERT_PATH" || ! -s "$KEY_PATH") && -s "$BOOTSTRAP_CERT_SRC" && -s "$BOOTSTRAP_KEY_SRC" ]]; then
        cp "$BOOTSTRAP_CERT_SRC" "$CERT_PATH"
        cp "$BOOTSTRAP_KEY_SRC" "$KEY_PATH"
        chmod 600 "$KEY_PATH"
        log_success "Installed Origin certificate and key from Terraform-provided secrets."
    fi

    if [[ -s "$CERT_PATH" && -s "$KEY_PATH" ]]; then
        log_action "Found Origin certificate and key on disk; skipping certificate request."
    else
        log_action "Requesting Cloudflare Origin Certificate..."
        local CERT_DATA
        CERT_DATA=$(curl -s -X POST "https://api.cloudflare.com/client/v4/certificates" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "{\"hostnames\":[\"${FULL_DOMAIN}\",\"*.${DOMAIN}\"],\"requested_validity\":5475,\"request_type\":\"origin-rsa\"}")
        local CERTIFICATE
        CERTIFICATE=$(echo "$CERT_DATA" | jq -r '.result.certificate')
        local PRIVATE_KEY
        PRIVATE_KEY=$(echo "$CERT_DATA" | jq -r '.result.private_key')

        if [[ -z "$CERTIFICATE" || "$CERTIFICATE" == "null" || -z "$PRIVATE_KEY" || "$PRIVATE_KEY" == "null" ]]; then
            log_error_exit "Failed to create Cloudflare Origin Certificate. If an Origin cert already exists in Cloudflare, note the private key cannot be retrieved from the API. Provide existing files at $CERT_PATH and $KEY_PATH, or revoke and recreate."
        fi

        echo "${CERTIFICATE}" > "$CERT_PATH"
        echo "${PRIVATE_KEY}" > "$KEY_PATH"
        chmod 600 "$KEY_PATH"
        log_success "Origin Certificate created and placed securely in ${SSL_DIR}."
    fi
    
    log_action "Setting Cloudflare SSL/TLS mode to 'Full (Strict)'..."
    curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/settings/ssl" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data '{"value":"strict"}' | jq -e '.success == true' > /dev/null || log_action "Warning: Failed to set SSL/TLS mode. Please set to 'Full (Strict)' manually."
    log_success "Cloudflare SSL/TLS mode set."

    log_action "Creating Nginx server block configuration..."
    cat << EOF > /etc/nginx/sites-available/${FULL_DOMAIN}.conf
server {
    listen 80; server_name ${FULL_DOMAIN}; return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2; server_name ${FULL_DOMAIN};
    ssl_certificate ${SSL_DIR}/${FULL_DOMAIN}.pem;
    ssl_certificate_key ${SSL_DIR}/${FULL_DOMAIN}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    location /ubuntu/ { alias ${APT_MIRROR_BASE_PATH}/archive.ubuntu.com/ubuntu/; autoindex on; }
    location /ubuntu-security/ { alias ${APT_MIRROR_BASE_PATH}/security.ubuntu.com/ubuntu/; autoindex on; }
    location /cudo-extra/ { alias /opt/apt/cudo-extra/; autoindex on; }
    location / { return 200 "CUDOS APT Mirror - Ready\\n"; add_header Content-Type text/plain; }
}
EOF
    log_success "Nginx config created."

    ln -sf "/etc/nginx/sites-available/${FULL_DOMAIN}.conf" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default
    log_action "Enabling Nginx site and testing configuration..."
    nginx -t || log_error_exit "Nginx configuration test failed."
    systemctl restart nginx
    log_success "Nginx configured and restarted."

    # --- 5. Start Mirror Sync ---
    log_action "--- Section 5: Starting apt-mirror Synchronization ---"

    log_action "Starting apt-mirror in a detached screen session 'aptmirror'..."
    screen -dmS aptmirror bash -lc "apt-mirror"
    if [ $? -eq 0 ]; then
        log_success "apt-mirror started in background; attach with: screen -r aptmirror"
    else
        log_action "Failed to start apt-mirror in screen; attempting background run with nohup..."
        nohup apt-mirror >> "/var/log/apt-mirror-$(date +%F-%H%M%S).log" 2>&1 &
        log_action "If needed, check logs under /var/log or ${LOG_FILE}."
    fi

    log_action "--- Script Finished ---"
    log_success "All setup tasks completed. The mirror sync is running in the background."
    log_action "Monitor progress with 'screen -r aptmirror' or check ${LOG_FILE} for details."
}

# Execute the main function
main