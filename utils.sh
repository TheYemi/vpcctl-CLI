#!/bin/bash

#############################################
# utils.sh - Utility functions for vpcctl
#############################################

#############################################
# Logging functions
# Logs messages to both console and log file
#############################################

log_info() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[INFO] $message"
    echo "[$timestamp] [INFO] $message" >> "$VPCCTL_LOG_FILE"
}

log_success() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[SUCCESS] $message"
    echo "[$timestamp] [SUCCESS] $message" >> "$VPCCTL_LOG_FILE"
}

log_warning() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[WARNING] $message"
    echo "[$timestamp] [WARNING] $message" >> "$VPCCTL_LOG_FILE"
}

log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[ERROR] $message" >&2
    echo "[$timestamp] [ERROR] $message" >> "$VPCCTL_LOG_FILE"
}

#############################################
# Validate CIDR format
# Checks if CIDR is in valid format (e.g., 10.0.0.0/16)
#############################################
validate_cidr() {
    local cidr="$1"

    # Check basic format: x.x.x.x/y
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        return 1
    fi

    # Extract IP and prefix
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"

    # Validate each octet
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 ]]; then
            return 1
        fi
    done

    # Validate prefix length
    if [[ $prefix -lt 0 ]] || [[ $prefix -gt 32 ]]; then
        return 1
    fi

    return 0
}

#############################################
# Get network address from CIDR
# Example: 10.0.1.10/24 -> 10.0.1
#############################################
get_network_prefix() {
    local cidr="$1"
    local ip="${cidr%/*}"

    # Get first three octets (for /16 and /24 networks)
    echo "$ip" | cut -d'.' -f1-3
}


