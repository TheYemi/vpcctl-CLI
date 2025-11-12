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