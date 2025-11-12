#!/bin/bash

# state.sh - State management for vpcctl
# Handles reading/writing VPC state to JSON file

# Check if VPC exists in state
vpc_exists() {
    local vpc_name="$1"
    
    # Check if VPC exists in state file
    jq -e ".vpcs.\"$vpc_name\"" "$VPCCTL_STATE_FILE" > /dev/null 2>&1
}

# Get VPC data from state
# Returns JSON object for the VPC
get_vpc_data() {
    local vpc_name="$1"
    
    jq -r ".vpcs.\"$vpc_name\"" "$VPCCTL_STATE_FILE"
}

# Save VPC to state
# Creates a new VPC entry in state file
save_vpc_state() {
    local vpc_name="$1"
    local vpc_cidr="$2"
    local bridge_name="$3"
    local nat_enabled="$4"
    local created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Create VPC entry in state file
    local tmp_file=$(mktemp)
    jq ".vpcs.\"$vpc_name\" = {
        \"cidr\": \"$vpc_cidr\",
        \"bridge\": \"$bridge_name\",
        \"nat_enabled\": $nat_enabled,
        \"created_at\": \"$created_at\",
        \"subnets\": {},
        \"peerings\": []
    }" "$VPCCTL_STATE_FILE" > "$tmp_file"
    
    mv "$tmp_file" "$VPCCTL_STATE_FILE"
}

# Add subnet to VPC state
add_subnet_to_state() {
    local vpc_name="$1"
    local subnet_type="$2"
    local subnet_cidr="$3"
    local namespace="$4"
    local veth_name="$5"
    local veth_br_name="$6"
    local host_ip="$7"
    local gateway_ip="$8"
    
    local tmp_file=$(mktemp)
    jq ".vpcs.\"$vpc_name\".subnets.\"$subnet_type\" = {
        \"cidr\": \"$subnet_cidr\",
        \"namespace\": \"$namespace\",
        \"veth\": \"$veth_name\",
        \"veth_br\": \"$veth_br_name\",
        \"host_ip\": \"$host_ip\",
        \"gateway_ip\": \"$gateway_ip\"
    }" "$VPCCTL_STATE_FILE" > "$tmp_file"
    
    mv "$tmp_file" "$VPCCTL_STATE_FILE"
}

# Add peering to VPC state
add_peering_to_state() {
    local vpc1="$1"
    local vpc2="$2"
    
    local tmp_file=$(mktemp)
    
    # Add vpc2 to vpc1's peerings
    jq ".vpcs.\"$vpc1\".peerings += [\"$vpc2\"]" "$VPCCTL_STATE_FILE" > "$tmp_file"
    mv "$tmp_file" "$VPCCTL_STATE_FILE"
    
    # Add vpc1 to vpc2's peerings
    tmp_file=$(mktemp)
    jq ".vpcs.\"$vpc2\".peerings += [\"$vpc1\"]" "$VPCCTL_STATE_FILE" > "$tmp_file"
    mv "$tmp_file" "$VPCCTL_STATE_FILE"
}

# Remove peering from VPC state
remove_peering_from_state() {
    local vpc1="$1"
    local vpc2="$2"
    
    local tmp_file=$(mktemp)
    
    # Remove vpc2 from vpc1's peerings
    jq ".vpcs.\"$vpc1\".peerings -= [\"$vpc2\"]" "$VPCCTL_STATE_FILE" > "$tmp_file"
    mv "$tmp_file" "$VPCCTL_STATE_FILE"
    
    # Remove vpc1 from vpc2's peerings
    tmp_file=$(mktemp)
    jq ".vpcs.\"$vpc2\".peerings -= [\"$vpc1\"]" "$VPCCTL_STATE_FILE" > "$tmp_file"
    mv "$tmp_file" "$VPCCTL_STATE_FILE"
}

# Delete VPC from state
delete_vpc_from_state() {
    local vpc_name="$1"
    
    local tmp_file=$(mktemp)
    jq "del(.vpcs.\"$vpc_name\")" "$VPCCTL_STATE_FILE" > "$tmp_file"
    mv "$tmp_file" "$VPCCTL_STATE_FILE"
}

# List all VPCs
# Prints formatted list of VPCs
list_vpcs() {
    echo "============================================"
    echo "VPCs"
    echo "============================================"
    
    local vpc_count=$(jq -r '.vpcs | length' "$VPCCTL_STATE_FILE")
    
    if [[ $vpc_count -eq 0 ]]; then
        echo "No VPCs found"
        return
    fi
    
    # Iterate through each VPC
    jq -r '.vpcs | to_entries[] | "\(.key)|\(.value.cidr)|\(.value.nat_enabled)|\(.value.subnets | length)|\(.value.peerings | length)"' "$VPCCTL_STATE_FILE" | \
    while IFS='|' read -r name cidr nat_enabled subnet_count peer_count; do
        echo ""
        echo "Name:        $name"
        echo "CIDR:        $cidr"
        echo "NAT:         $nat_enabled"
        echo "Subnets:     $subnet_count"
        echo "Peerings:    $peer_count"
        echo "---"
    done
    
    echo ""
}

# Describe VPC
# Shows detailed information about a VPC
describe_vpc() {
    local vpc_name="$1"
    
    echo "============================================"
    echo "VPC: $vpc_name"
    echo "============================================"
    
    # Get VPC data
    local vpc_data=$(get_vpc_data "$vpc_name")
    
    # Basic info
    local cidr=$(echo "$vpc_data" | jq -r '.cidr')
    local bridge=$(echo "$vpc_data" | jq -r '.bridge')
    local nat_enabled=$(echo "$vpc_data" | jq -r '.nat_enabled')
    local created_at=$(echo "$vpc_data" | jq -r '.created_at')
    
    echo "CIDR:        $cidr"
    echo "Bridge:      $bridge"
    echo "NAT:         $nat_enabled"
    echo "Created:     $created_at"
    echo ""
    
    # Subnets
    echo "Subnets:"
    echo "---"
    local subnet_types=$(echo "$vpc_data" | jq -r '.subnets | keys[]')
    
    if [[ -z "$subnet_types" ]]; then
        echo "  No subnets"
    else
        for subnet_type in $subnet_types; do
            local subnet_data=$(echo "$vpc_data" | jq -r ".subnets.\"$subnet_type\"")
            local subnet_cidr=$(echo "$subnet_data" | jq -r '.cidr')
            local namespace=$(echo "$subnet_data" | jq -r '.namespace')
            local host_ip=$(echo "$subnet_data" | jq -r '.host_ip')
            local gateway_ip=$(echo "$subnet_data" | jq -r '.gateway_ip')
            
            echo "  Type:      $subnet_type"
            echo "  CIDR:      $subnet_cidr"
            echo "  Namespace: $namespace"
            echo "  Host IP:   $host_ip"
            echo "  Gateway:   $gateway_ip"
            echo ""
        done
    fi
    
    # Peerings
    echo "Peerings:"
    echo "---"
    local peerings=$(echo "$vpc_data" | jq -r '.peerings[]' 2>/dev/null)
    
    if [[ -z "$peerings" ]]; then
        echo "  No peerings"
    else
        for peer in $peerings; do
            echo "  - $peer"
        done
    fi
    echo ""
}

# Get all VPC names
get_all_vpc_names() {
    jq -r '.vpcs | keys[]' "$VPCCTL_STATE_FILE"
}

# Get VPC CIDR
get_vpc_cidr() {
    local vpc_name="$1"
    jq -r ".vpcs.\"$vpc_name\".cidr" "$VPCCTL_STATE_FILE"
}

# Get VPC bridge name
get_vpc_bridge() {
    local vpc_name="$1"
    jq -r ".vpcs.\"$vpc_name\".bridge" "$VPCCTL_STATE_FILE"
}

# Check if VPC has NAT enabled
is_nat_enabled() {
    local vpc_name="$1"
    local nat_enabled=$(jq -r ".vpcs.\"$vpc_name\".nat_enabled" "$VPCCTL_STATE_FILE")
    [[ "$nat_enabled" == "true" ]]
}

# Get VPC peerings
get_vpc_peerings() {
    local vpc_name="$1"
    jq -r ".vpcs.\"$vpc_name\".peerings[]" "$VPCCTL_STATE_FILE" 2>/dev/null
}

# Get subnet namespace name
get_subnet_namespace() {
    local vpc_name="$1"
    local subnet_type="$2"
    local result=$(jq -r ".vpcs.\"$vpc_name\".subnets.\"$subnet_type\".namespace // empty" "$VPCCTL_STATE_FILE" 2>/dev/null)
    
    if [[ -z "$result" ]] || [[ "$result" == "null" ]]; then
        return 1
    fi
    
    echo "$result"
}

# Get subnet CIDR
get_subnet_cidr() {
    local vpc_name="$1"
    local subnet_type="$2"
    jq -r ".vpcs.\"$vpc_name\".subnets.\"$subnet_type\".cidr" "$VPCCTL_STATE_FILE"
}

# Get subnet host IP
get_subnet_host_ip() {
    local vpc_name="$1"
    local subnet_type="$2"
    jq -r ".vpcs.\"$vpc_name\".subnets.\"$subnet_type\".host_ip" "$VPCCTL_STATE_FILE"
}

# Get all subnet types for VPC
get_vpc_subnet_types() {
    local vpc_name="$1"
    jq -r ".vpcs.\"$vpc_name\".subnets | keys[]" "$VPCCTL_STATE_FILE"
}