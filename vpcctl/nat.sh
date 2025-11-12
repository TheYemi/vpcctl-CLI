#!/bin/bash

#############################################
# nat.sh - NAT Gateway configuration
# Simulates Internet Gateway for VPC
#############################################

#############################################
# Configure NAT Gateway
# Enables internet access for the VPC
# This follows your manual commands exactly
#############################################
configure_nat_gateway() {
    local vpc_name="$1"
    local vpc_cidr="$2"
    local bridge_name="$3"
    
    # Get the internet-facing interface
    local internet_iface=$(get_internet_interface)
    log_info "  Detected internet interface: $internet_iface"
    
    # Generate veth pair names for host connection
    local veth_host="veth-${vpc_name}-host"
    local veth_vpc="veth-${vpc_name}-vpc"
    
    # Step 1: Create veth pair connecting bridge to host
    log_info "  Creating veth pair: $veth_host <-> $veth_vpc"
    ip link add "$veth_host" type veth peer name "$veth_vpc"
    
    # Step 2: Attach VPC end to bridge
    log_info "  Attaching $veth_vpc to bridge"
    ip link set "$veth_vpc" master "$bridge_name"
    
    # Step 3: Bring up VPC end
    log_info "  Bringing up $veth_vpc"
    ip link set "$veth_vpc" up
    
    # Step 4: Configure host end with IP in VPC range
    local base_network=$(get_base_network "$vpc_cidr")
    local prefix="${vpc_cidr#*/}"
    local host_ip="${base_network}.0.254"
    
    log_info "  Assigning IP ${host_ip}/${prefix} to $veth_host"
    ip addr add "${host_ip}/${prefix}" dev "$veth_host"
    
    # Step 5: Bring up host end
    log_info "  Bringing up $veth_host"
    ip link set "$veth_host" up
    
    # Step 6: Enable IP forwarding (if not already enabled)
    enable_ip_forward
    
    # Step 7: Add NAT rule for VPC traffic going to internet
    log_info "  Adding NAT rule (MASQUERADE) for VPC traffic"
    iptables -t nat -A POSTROUTING -s "$vpc_cidr" -o "$internet_iface" -j MASQUERADE
    
    # Step 8: Enable packet forwarding from VPC to internet
    log_info "  Allowing forwarding from VPC to internet"
    iptables -A FORWARD -i "$veth_host" -o "$internet_iface" -j ACCEPT
    
    # Step 9: Allow return traffic from internet to VPC
    log_info "  Allowing return traffic from internet to VPC"
    iptables -A FORWARD -i "$internet_iface" -o "$veth_host" -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    log_success "  NAT gateway configured for VPC '$vpc_name'"
}

#############################################
# Remove Private Subnet Internet Access
# Removes default route from private subnet
# Adds route to reach other VPC subnets only
#############################################
remove_private_subnet_internet() {
    local vpc_name="$1"
    local subnet_type="$2"
    local vpc_cidr="$3"
    
    local namespace=$(get_subnet_namespace "$vpc_name" "$subnet_type")
    local subnet_cidr=$(get_subnet_cidr "$vpc_name" "$subnet_type")
    local gateway_ip=$(get_gateway_ip "$subnet_cidr")
    
    log_info "  Isolating $subnet_type subnet from internet"
    
    # Remove default route
    log_info "    Removing default route"
    ip netns exec "$namespace" ip route del default 2>/dev/null || true
    
    # Add route to reach other VPC subnets only
    log_info "    Adding route to VPC subnets only"
    ip netns exec "$namespace" ip route add "$vpc_cidr" via "$gateway_ip"
    
    log_success "  $subnet_type subnet isolated (VPC-only access)"
}

#############################################
# Update NAT Rules for Peering
# When peering VPCs, NAT rules must exclude peer CIDR
# This prevents NAT from interfering with VPC-to-VPC traffic
#############################################
update_nat_rules_for_peering() {
    local vpc_name="$1"
    local peer_vpc_cidr="$2"
    
    local vpc_cidr=$(get_vpc_cidr "$vpc_name")
    local internet_iface=$(get_internet_interface)
    
    log_info "  Updating NAT rules to exclude peered VPC $peer_vpc_cidr"
    
    # Remove old broad NAT rule
    log_info "    Removing old NAT rule for $vpc_cidr"
    iptables -t nat -D POSTROUTING -s "$vpc_cidr" -o "$internet_iface" -j MASQUERADE 2>/dev/null || true
    
    # Get all peered VPCs and build exclusion list
    local peerings=$(get_vpc_peerings "$vpc_name")
    local exclusions=""
    
    for peer in $peerings; do
        local peer_cidr=$(get_vpc_cidr "$peer")
        if [[ -n "$exclusions" ]]; then
            exclusions="$exclusions ! -d $peer_cidr"
        else
            exclusions="! -d $peer_cidr"
        fi
    done
    
    # Add new NAT rule that excludes all peered VPC networks
    if [[ -n "$exclusions" ]]; then
        log_info "    Adding new NAT rule excluding: $exclusions"
        iptables -t nat -A POSTROUTING -s "$vpc_cidr" $exclusions -o "$internet_iface" -j MASQUERADE
    else
        # No exclusions, add back the original rule
        iptables -t nat -A POSTROUTING -s "$vpc_cidr" -o "$internet_iface" -j MASQUERADE
    fi
    
    log_success "  NAT rules updated for peering"
}

#############################################
# Cleanup NAT Rules
# Removes NAT rules for a VPC
#############################################
cleanup_nat_rules() {
    local vpc_cidr="$1"
    local internet_iface=$(get_internet_interface)
    
    # Remove NAT rule
    log_info "    Removing NAT rule"
    iptables -t nat -D POSTROUTING -s "$vpc_cidr" -o "$internet_iface" -j MASQUERADE 2>/dev/null || true
    
    # Try to remove with exclusions (in case it was peered)
    # This is a bit brute force but ensures cleanup
    local rules=$(iptables -t nat -L POSTROUTING -n --line-numbers | grep "$vpc_cidr" | awk '{print $1}' | tac)
    for rule_num in $rules; do
        iptables -t nat -D POSTROUTING "$rule_num" 2>/dev/null || true
    done
    
    # Remove FORWARD rules
    log_info "    Removing FORWARD rules"
    # This is trickier - we need to find rules matching our veth-host interface
    # For now, we'll just try common patterns
    local veth_pattern="veth-.*-host"
    
    # Get line numbers of matching FORWARD rules and delete in reverse
    local forward_rules=$(iptables -L FORWARD -n --line-numbers | grep -E "$veth_pattern" | awk '{print $1}' | tac)
    for rule_num in $forward_rules; do
        iptables -D FORWARD "$rule_num" 2>/dev/null || true
    done
}