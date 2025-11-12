#!/bin/bash

# utils.sh - Utility functions for vpcctl

# Logging functions
log_info() {
    echo "[INFO] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$VPCCTL_LOG_FILE"
}

log_success() {
    echo "✓ $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $1" >> "$VPCCTL_LOG_FILE"
}

log_error() {
    echo "✗ $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$VPCCTL_LOG_FILE"
}

# Validate CIDR format
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

# Get network address from CIDR
get_network_prefix() {
    local cidr="$1"
    local ip="${cidr%/*}"
    
    echo "$ip" | cut -d'.' -f1-3
}

# Get base network from CIDR
get_base_network() {
    local cidr="$1"
    local ip="${cidr%/*}"
    
    # Get first two octets
    echo "$ip" | cut -d'.' -f1-2
}

# Get gateway IP for subnet
get_gateway_ip() {
    local subnet_cidr="$1"
    local network_prefix=$(get_network_prefix "$subnet_cidr")
    
    echo "${network_prefix}.1"
}

# Get host IP for subnet
get_host_ip() {
    local subnet_cidr="$1"
    local network_prefix=$(get_network_prefix "$subnet_cidr")
    
    echo "${network_prefix}.0"
}

# Generate subnet CIDR from VPC CIDR
generate_subnet_cidr() {
    local vpc_cidr="$1"
    local subnet_index="$2"
    
    local base_network=$(get_base_network "$vpc_cidr")
    echo "${base_network}.${subnet_index}.0/24"
}


# Auto-detect default network interface
# Returns the interface used for default route (internet access)
get_internet_interface() {
    ip route | grep default | awk '{print $5}' | head -n1
}

# Generate bridge name for VPC
# Example: my-vpc -> my-vpc-bridge
get_bridge_name() {
    local vpc_name="$1"
    echo "${vpc_name}-bridge"
}

# Generate namespace name for subnet
get_namespace_name() {
    local vpc_name="$1"
    local subnet_type="$2"
    echo "${vpc_name}-${subnet_type}-subnet"
}

# Generate veth pair names for subnet
# Returns: veth_name veth_br_name
get_veth_names() {
    local vpc_name="$1"
    local subnet_type="$2"
    
    # Shorten subnet type for veth names (public->pub, private->pri)
    local short_type="${subnet_type:0:3}"
    
    local veth_name="v${vpc_name}${short_type}"
    local veth_br_name="${vpc_name}${short_type}br"
    
    echo "$veth_name $veth_br_name"
}

# Generate peering veth pair names
# Returns: veth-peer-vpc1-vpc2-1 veth-peer-vpc1-vpc2-2
get_peering_veth_names() {
    local vpc1="$1"
    local vpc2="$2"

    # Generate compact veth names
    local veth1="vp${vpc1}${vpc2}-1"
    local veth2="vp${vpc1}${vpc2}-2"
    
    echo "$veth1 $veth2"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if namespace exists
namespace_exists() {
    local ns_name="$1"
    ip netns list | grep -q "^${ns_name}$"
}


# Check if bridge exists
bridge_exists() {
    local bridge_name="$1"
    ip link show "$bridge_name" >/dev/null 2>&1
}

# Initialize state directory
# Creates /var/lib/vpcctl if it doesn't exist
init_state_dir() {
    if [[ ! -d "$VPCCTL_STATE_DIR" ]]; then
        mkdir -p "$VPCCTL_STATE_DIR"
        log_info "Created state directory: $VPCCTL_STATE_DIR"
    fi
    
    if [[ ! -f "$VPCCTL_STATE_FILE" ]]; then
        echo '{"vpcs":{}}' > "$VPCCTL_STATE_FILE"
        log_info "Initialized state file: $VPCCTL_STATE_FILE"
    fi
    
    if [[ ! -f "$VPCCTL_LOG_FILE" ]]; then
        touch "$VPCCTL_LOG_FILE"
    fi
}

# Check if IP forwarding is enabled
is_ip_forward_enabled() {
    [[ $(cat /proc/sys/net/ipv4/ip_forward) -eq 1 ]]
}

# Enable IP forwarding
enable_ip_forward() {
    if ! is_ip_forward_enabled; then
        log_info "Enabling IP forwarding"
        echo 1 | tee /proc/sys/net/ipv4/ip_forward > /dev/null
        sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    fi
}