#!/bin/bash

# subnet.sh - Subnet management operations
# Subnet-specific functions

# List subnets for a VPC

list_subnets() {
    local vpc_name="$1"
    
    if ! vpc_exists "$vpc_name"; then
        log_error "VPC '$vpc_name' does not exist"
        exit 1
    fi
    
    echo "============================================"
    echo "Subnets in VPC: $vpc_name"
    echo "============================================"
    echo ""
    
    local subnet_types=$(get_vpc_subnet_types "$vpc_name")
    
    if [[ -z "$subnet_types" ]]; then
        echo "No subnets found"
        return
    fi
    
    for subnet_type in $subnet_types; do
        local subnet_cidr=$(get_subnet_cidr "$vpc_name" "$subnet_type")
        local namespace=$(get_subnet_namespace "$vpc_name" "$subnet_type")
        local host_ip=$(get_subnet_host_ip "$vpc_name" "$subnet_type")
        
        echo "Type:      $subnet_type"
        echo "CIDR:      $subnet_cidr"
        echo "Namespace: $namespace"
        echo "Host IP:   $host_ip"
        echo ""
    done
}

# Test subnet connectivity
# Pings all other subnets in the VPC
test_subnet_connectivity() {
    local vpc_name="$1"
    local subnet_type="$2"
    
    local namespace=$(get_namespace_name "$vpc_name" "$subnet_type")
    
    echo "Testing connectivity from $subnet_type subnet $namespace..."
    echo ""
    
    # Test connectivity to all other subnets
    local all_subnet_types=$(get_vpc_subnet_types "$vpc_name")
    
    for target_subnet in $all_subnet_types; do
        if [[ "$target_subnet" == "$subnet_type" ]]; then
            continue
        fi
        
        local target_ip=$(get_subnet_host_ip "$vpc_name" "$target_subnet")
        
        echo -n "  Pinging $target_subnet ($target_ip)... "
        
        if ip netns exec "$namespace" ping -c 3 -W 2 "$target_ip" > /dev/null 2>&1; then
            echo "SUCCESS"
        else
            echo "FAILED"
        fi
    done
    
    # Test internet connectivity
    echo -n "  Pinging internet (8.8.8.8)... "
    if ip netns exec "$namespace" ping -c 3 -W 2 8.8.8.8 > /dev/null 2>&1; then
        echo "SUCCESS"
    else
        echo "FAILED (may be expected for private subnets)"
    fi
    
    echo ""
}

# Show subnet routing table
show_subnet_routes() {
    local vpc_name="$1"
    local subnet_type="$2"
    
    local namespace=$(get_subnet_namespace "$vpc_name" "$subnet_type")
    
    echo ""
    echo "============================================"
    echo "Routing table for $subnet_type in VPC $vpc_name"
    echo "============================================"
    echo ""
    ip netns exec "$namespace" ip route show
    echo ""
}

# Show subnet interfaces
show_subnet_interfaces() {
    local vpc_name="$1"
    local subnet_type="$2"
 
    local namespace=$(get_subnet_namespace "$vpc_name" "$subnet_type")

    echo ""
    echo "============================================"
    echo "Network interfaces for $subnet_type in VPC $vpc_name"
    echo "============================================"
    echo ""
    ip netns exec "$namespace" ip addr show
    echo ""
}