#!/bin/bash

# core.sh - Core VPC operations
# Creates, deletes, and manages VPCs

# Create VPC
# Main function that orchestrates VPC creation
create_vpc() {
    local vpc_name="$1"
    local vpc_cidr="$2"
    local subnets="$3"         # Comma-separated list: public,private
    local enable_nat="$4"      # true or false
    
    # Parse subnet types from comma-separated list
    IFS=',' read -ra subnet_array <<< "$subnets"
    
    # Generate bridge name
    local bridge_name=$(get_bridge_name "$vpc_name")
    
    # Step 1: Create the VPC bridge (router)
    log_info "Creating VPC bridge: $bridge_name"
    create_vpc_bridge "$bridge_name" "$vpc_cidr"
    
    # Step 2: Save VPC to state
    save_vpc_state "$vpc_name" "$vpc_cidr" "$bridge_name" "$enable_nat"
    
    # Step 3: Create each subnet
    local subnet_index=1
    for subnet_type in "${subnet_array[@]}"; do
        log_info "Creating $subnet_type subnet (index $subnet_index)"
        create_subnet "$vpc_name" "$vpc_cidr" "$subnet_type" "$subnet_index" "$bridge_name"
        subnet_index=$((subnet_index + 1))
    done
    
    # Step 4: Configure bridge routing between subnets
    log_info "Configuring bridge routing"
    configure_bridge_routing "$bridge_name" "$vpc_name"
    
    # Step 5: Enable NAT if requested
    if [[ "$enable_nat" == "true" ]]; then
        log_info "Configuring NAT gateway for internet access"
        configure_nat_gateway "$vpc_name" "$vpc_cidr" "$bridge_name"
        
        # Remove default route from private subnets (they should not have internet)
        for subnet_type in "${subnet_array[@]}"; do
            if [[ "$subnet_type" == "private" ]]; then
                remove_private_subnet_internet "$vpc_name" "$subnet_type" "$vpc_cidr"
            fi
        done
    fi
    
    log_success "VPC '$vpc_name' created with ${#subnet_array[@]} subnet(s)"
}

# Create VPC Bridge
# Creates the central bridge that acts as a router
create_vpc_bridge() {
    local bridge_name="$1"
    local vpc_cidr="$2"
    
    local base_network=$(get_base_network "$vpc_cidr")
    local bridge_ip="${base_network}.0.1"
    local prefix="${vpc_cidr#*/}"
    
    # Create the bridge
    log_info "  Creating bridge: $bridge_name"
    ip link add "$bridge_name" type bridge
    
    # Turn on the bridge
    log_info "  Bringing up bridge"
    ip link set "$bridge_name" up
    
    # Add VPC-wide CIDR to the bridge
    log_info "  Assigning IP ${bridge_ip}/${prefix} to bridge"
    ip addr add "${bridge_ip}/${prefix}" dev "$bridge_name"
}

# Create Subnet
# Creates a subnet namespace and connects it to the bridge
create_subnet() {
    local vpc_name="$1"
    local vpc_cidr="$2"
    local subnet_type="$3"      
    local subnet_index="$4"     
    local bridge_name="$5"
    

    local subnet_cidr=$(generate_subnet_cidr "$vpc_cidr" "$subnet_index")
    local namespace=$(get_namespace_name "$vpc_name" "$subnet_type")
    read veth_name veth_br_name <<< $(get_veth_names "$vpc_name" "$subnet_type")
    local host_ip=$(get_host_ip "$subnet_cidr")
    local gateway_ip=$(get_gateway_ip "$subnet_cidr")
    local subnet_prefix="${subnet_cidr#*/}"
    
    # Step 1: Create the namespace
    log_info "  Creating namespace: $namespace"
    ip netns add "$namespace"
    
    # Step 2: Create veth pair connecting namespace to bridge
    log_info "  Creating veth pair: $veth_name <-> $veth_br_name"
    ip link add "$veth_name" type veth peer name "$veth_br_name"
    
    # Step 3: Attach bridge end of veth pair to bridge
    log_info "  Attaching $veth_br_name to bridge $bridge_name"
    ip link set "$veth_br_name" master "$bridge_name"
    
    # Step 4: Turn on the bridge end
    log_info "  Bringing up $veth_br_name"
    ip link set "$veth_br_name" up
    
    # Step 5: Move namespace end into the namespace
    log_info "  Moving $veth_name into namespace $namespace"
    ip link set "$veth_name" netns "$namespace"
    
    # Step 6: Assign IP address inside namespace
    log_info "  Assigning IP ${host_ip}/${subnet_prefix} inside namespace"
    ip netns exec "$namespace" ip addr add "${host_ip}/${subnet_prefix}" dev "$veth_name"
    
    # Step 7: Turn on the namespace end of veth pair
    log_info "  Bringing up $veth_name inside namespace"
    ip netns exec "$namespace" ip link set "$veth_name" up
    
    # Step 8: Turn on loopback interface in namespace
    log_info "  Bringing up loopback interface"
    ip netns exec "$namespace" ip link set lo up
    
    # Step 9: Set default route pointing to gateway
    log_info "  Setting default route via $gateway_ip"
    ip netns exec "$namespace" ip route add default via "$gateway_ip"
    
    # Save subnet to state
    add_subnet_to_state "$vpc_name" "$subnet_type" "$subnet_cidr" "$namespace" \
                        "$veth_name" "$veth_br_name" "$host_ip" "$gateway_ip"
    
    log_success "  Subnet $subnet_type ($subnet_cidr) created"
}

# Configure Bridge Routing
# Adds gateway IPs for each subnet on the bridge
# Enables IP forwarding
configure_bridge_routing() {
    local bridge_name="$1"
    local vpc_name="$2"
    
    local subnet_types=$(get_vpc_subnet_types "$vpc_name")
    
    # Add gateway IP for each subnet on the bridge
    for subnet_type in $subnet_types; do
        local subnet_cidr=$(get_subnet_cidr "$vpc_name" "$subnet_type")
        local gateway_ip=$(get_gateway_ip "$subnet_cidr")
        local subnet_prefix="${subnet_cidr#*/}"
        
        log_info "  Adding gateway IP ${gateway_ip}/${subnet_prefix} to bridge"
        ip addr add "${gateway_ip}/${subnet_prefix}" dev "$bridge_name"
    done
    
    # Enable IP forwarding on the bridge
    log_info "  Enabling IP forwarding"
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
}

# Delete VPC
# Removes all VPC resources
delete_vpc() {
    local vpc_name="$1"
    
    # Get VPC data
    local bridge_name=$(get_vpc_bridge "$vpc_name")
    local vpc_cidr=$(get_vpc_cidr "$vpc_name")
    local nat_enabled=$(is_nat_enabled "$vpc_name")
    
    # Step 1: Delete all peerings first
    log_info "  Checking for peerings"
    local peerings=$(get_vpc_peerings "$vpc_name")
    for peer_vpc in $peerings; do
        log_info "  Removing peering with $peer_vpc"
        unpeer_vpcs "$vpc_name" "$peer_vpc"
    done
    
    # Step 2: Delete namespaces
    log_info "  Deleting namespaces"
    local subnet_types=$(get_vpc_subnet_types "$vpc_name")
    for subnet_type in $subnet_types; do
        local namespace=$(get_subnet_namespace "$vpc_name" "$subnet_type")
        if namespace_exists "$namespace"; then
            log_info "    Deleting namespace: $namespace"
            ip netns del "$namespace"
        fi
    done
    
    # Step 3: Delete veth pairs in host
    log_info "  Deleting veth pairs"
    for subnet_type in $subnet_types; do
        read veth_name veth_br_name <<< $(get_veth_names "$vpc_name" "$subnet_type")
        
        # Delete veth-br (this also deletes the pair)
        ip link del "$veth_br_name" 2>/dev/null || true
    done
    
    # Step 4: Delete host veth if NAT was enabled
    if [[ "$nat_enabled" == "true" ]]; then
        log_info "  Deleting NAT veth pair"
        ip link del "veth-${vpc_name}-host" 2>/dev/null || true
    fi
    
    # Step 5: Delete bridge
    log_info "  Deleting bridge: $bridge_name"
    if bridge_exists "$bridge_name"; then
        ip link set "$bridge_name" down 2>/dev/null || true
        ip link del "$bridge_name" 2>/dev/null || true
    fi
    
    # Step 6: Clean up iptables rules if NAT was enabled
    if [[ "$nat_enabled" == "true" ]]; then
        log_info "  Cleaning up NAT iptables rules"
        cleanup_nat_rules "$vpc_cidr"
    fi
    
    # Step 7: Remove from state
    delete_vpc_from_state "$vpc_name"
    
    log_success "  VPC '$vpc_name' deleted"
}

# Cleanup All VPCs
# Deletes all VPCs in the system
cleanup_all_vpcs() {
    local vpc_names=$(get_all_vpc_names)
    
    if [[ -z "$vpc_names" ]]; then
        log_info "No VPCs to clean up"
        return
    fi
    
    for vpc_name in $vpc_names; do
        log_info "Deleting VPC: $vpc_name"
        delete_vpc "$vpc_name"
    done
    
    log_success "All VPCs cleaned up"
}

# Validate VPC
# Tests connectivity and configuration
validate_vpc() {
    local vpc_name="$1"
    
    echo ""
    echo "============================================"
    echo "Validating VPC: $vpc_name"
    echo "============================================"
    echo ""
    
    local tests_passed=0
    local tests_failed=0
    
    # Get subnet types
    local subnet_types=$(get_vpc_subnet_types "$vpc_name")
    local subnet_array=($subnet_types)
    
    # Test 1: Inter-subnet connectivity
    echo "[TEST] Inter-subnet connectivity"
    if [[ ${#subnet_array[@]} -ge 2 ]]; then
        local subnet1="${subnet_array[0]}"
        local subnet2="${subnet_array[1]}"
        
        local ns1=$(get_subnet_namespace "$vpc_name" "$subnet1")
        local ip2=$(get_subnet_host_ip "$vpc_name" "$subnet2")
        
        if ip netns exec "$ns1" ping -c 3 -W 2 "$ip2" > /dev/null 2>&1; then
            echo "  ✓ $subnet1 can reach $subnet2"
            tests_passed=$((tests_passed + 1))
        else
            echo "  ✗ $subnet1 CANNOT reach $subnet2"
            tests_failed=$((tests_failed + 1))
        fi
    else
        echo "  - Skipped (need at least 2 subnets)"
    fi
    echo ""
    
    # Test 2: Internet access (if NAT enabled)
    echo "[TEST] Internet access"
    if is_nat_enabled "$vpc_name"; then
        # Test public subnet has internet
        for subnet_type in $subnet_types; do
            if [[ "$subnet_type" == "public" ]]; then
                local ns=$(get_subnet_namespace "$vpc_name" "$subnet_type")
                if ip netns exec "$ns" ping -c 3 -W 2 8.8.8.8 > /dev/null 2>&1; then
                    echo "  ✓ $subnet_type subnet has internet access"
                    tests_passed=$((tests_passed + 1))
                else
                    echo "  ✗ $subnet_type subnet has NO internet access"
                    tests_failed=$((tests_failed + 1))
                fi
            fi
        done
        
        # Test private subnet has NO internet
        for subnet_type in $subnet_types; do
            if [[ "$subnet_type" == "private" ]]; then
                local ns=$(get_subnet_namespace "$vpc_name" "$subnet_type")
                if ! ip netns exec "$ns" ping -c 2 -W 2 8.8.8.8 > /dev/null 2>&1; then
                    echo "  ✓ $subnet_type subnet correctly isolated (no internet)"
                    tests_passed=$((tests_passed + 1))
                else
                    echo "  ✗ $subnet_type subnet has internet (should be isolated)"
                    tests_failed=$((tests_failed + 1))
                fi
            fi
        done
    else
        echo "  - Skipped (NAT not enabled)"
    fi
    echo ""
    
    # Test 3: Routing tables
    echo "[TEST] Routing configuration"
    for subnet_type in $subnet_types; do
        local ns=$(get_subnet_namespace "$vpc_name" "$subnet_type")
        local routes=$(ip netns exec "$ns" ip route show | wc -l)
        if [[ $routes -gt 0 ]]; then
            echo "  ✓ $subnet_type subnet has routing configured"
            tests_passed=$((tests_passed + 1))
        else
            echo "  ✗ $subnet_type subnet has NO routes"
            tests_failed=$((tests_failed + 1))
        fi
    done
    echo ""
    
    # Summary
    echo "============================================"
    echo "Validation Summary"
    echo "============================================"
    echo "Tests Passed: $tests_passed"
    echo "Tests Failed: $tests_failed"
    echo ""
    
    if [[ $tests_failed -eq 0 ]]; then
        log_success "All validation tests passed!"
        return 0
    else
        log_error "Some validation tests failed"
        return 1
    fi
}

# Execute command in subnet
# Runs a command inside a subnet namespace
exec_in_subnet() {
    local vpc_name="$1"
    local subnet_type="$2"
    shift 2
    local command=("$@")
    
    # Check if VPC exists first
    if ! vpc_exists "$vpc_name"; then
        log_error "VPC '$vpc_name' does not exist"
        exit 1
    fi
    
    # Get namespace - TRY BOTH METHODS
    local namespace
    
    # Method 1: Try to get from state
    namespace=$(jq -r ".vpcs.\"$vpc_name\".subnets.\"$subnet_type\".namespace // empty" "$VPCCTL_STATE_FILE" 2>/dev/null)
    
    # ADDED: If empty or null, show better error
    if [[ -z "$namespace" ]] || [[ "$namespace" == "null" ]]; then
        log_error "Subnet '$subnet_type' does not exist in VPC '$vpc_name'"
        log_info "Available subnets in state:"
        jq -r ".vpcs.\"$vpc_name\".subnets | keys[]" "$VPCCTL_STATE_FILE" 2>/dev/null | while read -r st; do
            echo "  - $st"
        done
        exit 1
    fi
    
    # ADDED: Verify namespace actually exists
    if ! namespace_exists "$namespace"; then
        log_error "Namespace '$namespace' found in state but does not exist in system"
        log_info "This means state is out of sync. Try recreating the VPC."
        log_info "Namespaces that exist:"
        ip netns list | sed 's/^/  - /'
        exit 1
    fi
    
    log_info "Executing command in $subnet_type subnet of VPC $vpc_name (namespace: $namespace)"
    
    # Execute command in namespace
    ip netns exec "$namespace" "${command[@]}"
}