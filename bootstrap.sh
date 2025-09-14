#!/bin/bash

# --- Non-Interactive Idempotent apt-mirror Setup Script ---
# This script is designed to run without user input.
# All output is logged to /root/postinstall.log.

# --- Configuration ---
readonly LOG_FILE="/root/postinstall.log"
readonly DISK_PATH="/dev/sdb"
readonly PARTITION_PATH="/dev/sdb1"
readonly MOUNT_POINT="/opt/apt"
readonly MIRROR_CONFIG_FILE="/etc/apt/mirror.list"

# --- Pre-run Checks & Logging Setup ---
# Must be run as root
if (( EUID != 0 )); then
   echo "This script must be run as root. Please use 'sudo'."
   exit 1
fi

# Redirect all output (stdout and stderr) to the log file
exec &> >(tee -a "$LOG_FILE")

# --- Helper Functions ---
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - INFO: $1"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - SUCCESS: $1"
}

log_error_exit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - ERROR: $1" >&2
    exit 1
}

# --- Main Script Logic ---
main() {
    log_action "Starting fully automated apt-mirror setup."
    
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
        (
            echo g # New GPT partition table
            echo n # New partition
            echo   # Default partition number
            echo   # Default start sector
            echo   # Default end sector
            echo w # Write changes
        ) | fdisk "$DISK_PATH"
        
        partprobe "$DISK_PATH" # Inform OS of partition table changes
        sleep 2 # Give kernel time to register the new device
        
        if [ ! -b "$PARTITION_PATH" ]; then
            log_error_exit "Failed to create partition ${PARTITION_PATH}."
        fi
        log_success "Partition ${PARTITION_PATH} created."
    else
        log_action "Partition ${PARTITION_PATH} already exists. Skipping creation."
    fi
    
    # Check if mounted, format and mount if not
    if mountpoint -q "$MOUNT_POINT"; then
        log_success "Drive is already mounted at ${MOUNT_POINT}. Skipping format and mount."
    else
        log_action "${MOUNT_POINT} is not a mountpoint. Formatting and mounting..."
        log_action "Formatting ${PARTITION_PATH} with ext4..."
        mkfs.ext4 -F "$PARTITION_PATH"
        log_success "Formatting complete."
        
        log_action "Ensuring mount point directory ${MOUNT_POINT} exists..."
        mkdir -p "$MOUNT_POINT"
        
        log_action "Updating /etc/fstab for persistent mount..."
        local uuid
        uuid=$(blkid -s UUID -o value "$PARTITION_PATH")
        if [ -z "$uuid" ]; then
            log_error_exit "Could not get UUID for ${PARTITION_PATH}."
        fi
        
        local fstab_entry="UUID=${uuid}    ${MOUNT_POINT}    ext4    defaults   0 0"
        if ! grep -qF "$fstab_entry" /etc/fstab; then
            echo "$fstab_entry" >> /etc/fstab
            log_success "Added entry to /etc/fstab."
        else
            log_action "/etc/fstab entry already exists."
        fi
        
        log_action "Mounting all filesystems..."
        mount -a
        
        if ! mountpoint -q "$MOUNT_POINT"; then
            log_error_exit "Failed to mount ${PARTITION_PATH} at ${MOUNT_POINT}."
        fi
        log_success "Successfully mounted ${PARTITION_PATH} at ${MOUNT_POINT}."
    fi
    
    # --- 2. System Update & Firewall ---
    log_action "--- Section 2: System & Firewall ---"
    
    log_action "Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get upgrade -y -q
    log_success "System update and upgrade complete."
    
    log_action "Installing and configuring UFW..."
    apt-get install -y -q ufw
    if ! dpkg -l | grep -q "ufw"; then
        log_error_exit "UFW installation failed."
    fi

    ufw limit 22
    ufw allow 443/tcp
    ufw limit ssh
    systemctl enable --now ufw > /dev/null 2>&1
    echo "y" | ufw enable
    log_success "UFW enabled and configured with rules for ports 80, 443, and rate-limited SSH."
    log_action "Current UFW Status:"
    ufw status numbered
    
    # --- 3. apt-mirror Setup ---
    log_action "--- Section 3: apt-mirror Setup ---"
    
    log_action "Installing apt-mirror and screen..."
    apt-get install -y -q apt-mirror screen
    log_success "Packages apt-mirror and screen are installed."
    
    log_action "Configuring ${MIRROR_CONFIG_FILE}..."
    if [ -f "$MIRROR_CONFIG_FILE" ]; then
        backup_file="${MIRROR_CONFIG_FILE}.bak.$(date +%F-%T)"
        log_action "Backing up existing config to ${backup_file}."
        mv "$MIRROR_CONFIG_FILE" "$backup_file"
    fi

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
    
    log_action "Verifying new configuration file..."
    if grep -q "set base_path    ${MOUNT_POINT}" "$MIRROR_CONFIG_FILE"; then
        log_success "Configuration file ${MIRROR_CONFIG_FILE} created and verified successfully."
    else
        log_error_exit "Failed to write or verify the new ${MIRROR_CONFIG_FILE}."
    fi

    # --- Kick off a single apt-mirror run in the background (non-blocking) ---
    log_action "Starting apt-mirror in a detached screen session 'aptmirror'..."
    # Using bash -lc ensures a login shell with PATH and environment
    screen -dmS aptmirror bash -lc "apt-mirror"
    if [ $? -eq 0 ]; then
        log_success "apt-mirror started in background; attach with: screen -r aptmirror"
    else
        log_action "Failed to start apt-mirror in screen; attempting background run with nohup..."
        nohup apt-mirror >> "/var/log/apt-mirror-$(date +%F-%H%M%S).log" 2>&1 &
        log_action "If needed, check logs under /var/log or ${LOG_FILE}."
    fi
    
    log_action "--- Script Finished ---"
    log_success "All tasks completed. Check the log at ${LOG_FILE} for details."
    log_action "A reboot is recommended to ensure all changes persist correctly."
}

# Execute the main function
main
