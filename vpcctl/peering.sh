#!/bin/bash

#############################################
# peering.sh - VPC Peering operations
# Connects two VPCs together
#############################################

#############################################
# Peer VPCs
# Creates peering connection between two VPCs
# This follows your manual commands exactly
#############################################
peer_vpcs() {
    local vpc1="$1"
    local vpc2="$2"
    
    # Get VPC data
    local vpc1_cidr=$(get_vpc_cidr "$vpc1")
    local vpc2_cidr=$(get_vpc_cidr "$vpc2")
    local vpc1_bridge=$(get_vpc_bridge "$vpc1")
    local vpc2_bridge=$(get_vpc_bridge "$vpc2")
    local vpc1_nat=$(is_nat_enabled "$vpc1")
    local vpc2_nat=$(is_nat_enabled "$vpc2")
    
    # Check if peering already exists
    local existing_peerings=$(get_vpc_peerings "$vpc1")
    if echo "$existing_peerings" | grep -q "^${vpc2}$"; then
        log_warning "VPCs '$vpc1' and '$vpc2' are already peered"
        return 0
    fi
    
    # Step 1: Update NAT rules if either VPC has NAT enabled
    if [[ "$vpc1_nat" == "true" ]]; then
        log_info "  Updating NAT rules for VPC '$vpc1'"
        update_nat_rules_for_peering "$vpc1" "$vpc2_cidr"
    fi
    
    if [[ "$vpc2_nat" == "true" ]]; then
        log_info "  Updating NAT rules for VPC '$vpc2'"
        update_nat_rules_for_peering "$vpc2" "$vpc1_cidr"
    fi
    
    # Step 2: Create veth pair for peering
    read veth_peer1 veth_peer2 <<< $(get_peering_veth_names "$vpc1" "$vpc2")
    
    log_info "  Creating peering veth pair: $veth_peer1 <-> $veth_peer2"
    ip link add "$veth_peer1" type veth peer name "$veth_peer2"
    
    # Step 3: Attach one end to vpc1 bridge
    log_info "  Attaching $veth_peer1 to $vpc1_bridge"
    ip link set "$veth_peer1" master "$vpc1_bridge"
    
    # Step 4: Attach other end to vpc2 bridge
    log_info "  Attaching $veth_peer2 to $vpc2_bridge"
    ip link set "$veth_peer2" master "$vpc2_bridge"
    
    # Step 5: Bring up both ends
    log_info "  Bringing up peering interfaces"
    ip link set "$veth_peer1" up
    ip link set "$veth_peer2" up
    
    # Step 6: Add static routes for cross-VPC communication
    log_info "  Adding static routes for cross-VPC communication"
    
    # VPC1 learns about VPC2's network
    log_info "    Route: $vpc2_cidr via $vpc1_bridge"
    ip route add "$vpc2_cidr" dev "$vpc1_bridge" 2>/dev/null || true
    
    # VPC2 learns about VPC1's network
    log_info "    Route: $vpc1_cidr via $vpc2_bridge"
    ip route add "$vpc1_cidr" dev "$vpc2_bridge" 2>/dev/null || true
    
    # Step 7: Configure FORWARD rules for inter-VPC traffic
    log_info "  Configuring iptables FORWARD rules"
    
    # Allow traffic from VPC1 to VPC2
    iptables -A FORWARD -s "$vpc1_cidr" -d "$vpc2_cidr" -j ACCEPT
    
    # Allow traffic from VPC2 to VPC1
    iptables -A FORWARD -s "$vpc2_cidr" -d "$vpc1_cidr" -j ACCEPT
    
    # Allow traffic between the peering veth interfaces
    iptables -A FORWARD -i "$veth_peer1" -o "$veth_peer2" -j ACCEPT
    iptables -A FORWARD -i "$veth_peer2" -o "$veth_peer1" -j ACCEPT
    
    # Step 8: Update state
    add_peering_to_state "$vpc1" "$vpc2"
    
    log_success "  VPCs '$vpc1' and '$vpc2' peered successfully"
}

#############################################
# Unpeer VPCs
# Removes peering connection between two VPCs
#############################################
unpeer_vpcs() {
    local vpc1="$1"
    local vpc2="$2"
    
    # Check if peering exists
    local existing_peerings=$(get_vpc_peerings "$vpc1")
    if ! echo "$existing_peerings" | grep -q "^${vpc2}$"; then
        log_warning "VPCs '$vpc1' and '$vpc2' are not peered"
        return 0
    fi
    
    # Get VPC data
    local vpc1_cidr=$(get_vpc_cidr "$vpc1")
    local vpc2_cidr=$(get_vpc_cidr "$vpc2")
    local vpc1_bridge=$(get_vpc_bridge "$vpc1")
    local vpc2_bridge=$(get_vpc_bridge "$vpc2")
    local vpc1_nat=$(is_nat_enabled "$vpc1")
    local vpc2_nat=$(is_nat_enabled "$vpc2")
    
    # Step 1: Remove veth pair
    read veth_peer1 veth_peer2 <<< $(get_peering_veth_names "$vpc1" "$vpc2")
    
    log_info "  Removing peering veth pair"
    ip link del "$veth_peer1" 2>/dev/null || true
    
    # Step 2: Remove static routes
    log_info "  Removing static routes"
    ip route del "$vpc2_cidr" dev "$vpc1_bridge" 2>/dev/null || true
    ip route del "$vpc1_cidr" dev "$vpc2_bridge" 2>/dev/null || true
    
    # Step 3: Remove FORWARD rules
    log_info "  Removing iptables FORWARD rules"
    iptables -D FORWARD -s "$vpc1_cidr" -d "$vpc2_cidr" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -s "$vpc2_cidr" -d "$vpc1_cidr" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$veth_peer1" -o "$veth_peer2" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$veth_peer2" -o "$veth_peer1" -j ACCEPT 2>/dev/null || true
    
    # Step 4: Update state first (remove peering)
    remove_peering_from_state "$vpc1" "$vpc2"
    
    # Step 5: Restore NAT rules if needed
    if [[ "$vpc1_nat" == "true" ]]; then
        log_info "  Restoring NAT rules for VPC '$vpc1'"
        
        # Remove ALL NAT rules for vpc1
        local nat_lines=$(iptables -t nat -L POSTROUTING -n --line-numbers | grep "$vpc1_cidr" | awk '{print $1}' | sort -rn)
        for line_num in $nat_lines; do
            iptables -t nat -D POSTROUTING "$line_num" 2>/dev/null || true
        done
        
        # Get remaining peerings after removal
        local remaining_peerings=$(get_vpc_peerings "$vpc1")
        local internet_iface=$(get_internet_interface)
    
    if [[ -z "$remaining_peerings" ]]; then
            # No more peerings, use simple NAT rule
            log_info "    Adding simple NAT rule (no more peerings)"
            iptables -t nat -A POSTROUTING -s "$vpc1_cidr" -o "$internet_iface" -j MASQUERADE
        else
            # Still have peerings, rebuild with exclusions
            local exclusions=""
            for peer in $remaining_peerings; do
                local peer_cidr=$(get_vpc_cidr "$peer")
                exclusions="$exclusions ! -d $peer_cidr"
            done
            log_info "    Adding NAT rule with exclusions for remaining peers"
            iptables -t nat -A POSTROUTING -s "$vpc1_cidr" $exclusions -o "$internet_iface" -j MASQUERADE
        fi
    fi
    
    if [[ "$vpc2_nat" == "true" ]]; then
        log_info "  Restoring NAT rules for VPC '$vpc2'"
        
        # Remove ALL NAT rules for vpc2
        local nat_lines=$(iptables -t nat -L POSTROUTING -n --line-numbers | grep "$vpc2_cidr" | awk '{print $1}' | sort -rn)
        for line_num in $nat_lines; do
            iptables -t nat -D POSTROUTING "$line_num" 2>/dev/null || true
        done
    
    # Get remaining peerings after removal
        local remaining_peerings=$(get_vpc_peerings "$vpc2")
        local internet_iface=$(get_internet_interface)
        
        if [[ -z "$remaining_peerings" ]]; then
            # No more peerings, use simple NAT rule
            log_info "    Adding simple NAT rule (no more peerings)"
            iptables -t nat -A POSTROUTING -s "$vpc2_cidr" -o "$internet_iface" -j MASQUERADE
        else
            # Still have peerings, rebuild with exclusions
            local exclusions=""
            for peer in $remaining_peerings; do
                local peer_cidr=$(get_vpc_cidr "$peer")
                exclusions="$exclusions ! -d $peer_cidr"
            done
            log_info "    Adding NAT rule with exclusions for remaining peers"
            iptables -t nat -A POSTROUTING -s "$vpc2_cidr" $exclusions -o "$internet_iface" -j MASQUERADE
        fi
    fi
    
    log_success "  Peering removed between '$vpc1' and '$vpc2'"
}
