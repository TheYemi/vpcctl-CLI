#!/bin/bash

#############################################
# security.sh - Security group operations
# Implements firewall rules using iptables
#############################################

#############################################
# Apply Security Rules
# Applies iptables rules from JSON file to subnet
# This follows your manual iptables commands
#############################################
apply_security_rules() {
    local vpc_name="$1"
    local subnet_type="$2"
    local rules_file="$3"
    
    # Get namespace
    local namespace=$(get_subnet_namespace "$vpc_name" "$subnet_type")
    
    if ! namespace_exists "$namespace"; then
        log_error "Subnet $subnet_type does not exist in VPC $vpc_name"
        exit 1
    fi
    
    # Validate JSON file
    if ! jq empty "$rules_file" 2>/dev/null; then
        log_error "Invalid JSON file: $rules_file"
        exit 1
    fi
    
    log_info "  Applying security rules to $namespace"
    
    # Step 1: Set default policies (DROP for INPUT and FORWARD, ACCEPT for OUTPUT)
    log_info "    Setting default policies"
    ip netns exec "$namespace" iptables -P INPUT DROP
    ip netns exec "$namespace" iptables -P FORWARD DROP
    ip netns exec "$namespace" iptables -P OUTPUT ACCEPT
    
    # Step 2: Allow established connections
    log_info "    Allowing established/related connections"
    ip netns exec "$namespace" iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Step 3: Allow loopback
    log_info "    Allowing loopback traffic"
    ip netns exec "$namespace" iptables -A INPUT -i lo -j ACCEPT
    
    # Step 4: Allow ICMP (for testing with ping)
    log_info "    Allowing ICMP"
    ip netns exec "$namespace" iptables -A INPUT -p icmp -j ACCEPT
    
    # Step 5: Parse and apply ingress rules from JSON
    log_info "    Applying ingress rules from JSON"
    
    # Read ingress rules
    local ingress_count=$(jq '.ingress | length' "$rules_file")
    
    for ((i=0; i<ingress_count; i++)); do
        local port=$(jq -r ".ingress[$i].port" "$rules_file")
        local protocol=$(jq -r ".ingress[$i].protocol" "$rules_file")
        local action=$(jq -r ".ingress[$i].action" "$rules_file")
        
        # Convert action to iptables target
        local target
        if [[ "$action" == "allow" ]]; then
            target="ACCEPT"
        elif [[ "$action" == "deny" ]]; then
            target="DROP"
        else
            log_warning "Unknown action '$action' for port $port, skipping"
            continue
        fi
        
        log_info "      Rule: $protocol/$port -> $action"
        ip netns exec "$namespace" iptables -A INPUT -p "$protocol" --dport "$port" -j "$target"
    done
    
    # Step 6: Parse and apply egress rules if present
    if jq -e '.egress' "$rules_file" > /dev/null 2>&1; then
        log_info "    Applying egress rules from JSON"
        
        local egress_count=$(jq '.egress | length' "$rules_file")
        
        for ((i=0; i<egress_count; i++)); do
            local port=$(jq -r ".egress[$i].port" "$rules_file")
            local protocol=$(jq -r ".egress[$i].protocol" "$rules_file")
            local action=$(jq -r ".egress[$i].action" "$rules_file")
            
            local target
            if [[ "$action" == "allow" ]]; then
                target="ACCEPT"
            elif [[ "$action" == "deny" ]]; then
                target="DROP"
            else
                log_warning "Unknown action '$action' for port $port, skipping"
                continue
            fi
            
            log_info "      Rule: $protocol/$port -> $action"
            ip netns exec "$namespace" iptables -A OUTPUT -p "$protocol" --dport "$port" -j "$target"
        done
    fi
    
    log_success "  Security rules applied to $subnet_type subnet"
    
    # Show applied rules
    echo ""
    echo "Applied iptables rules in $namespace:"
    echo "---"
    ip netns exec "$namespace" iptables -L -n -v
    echo ""
}

#############################################
# Clear Security Rules
# Resets iptables in namespace to default
#############################################
clear_security_rules() {
    local vpc_name="$1"
    local subnet_type="$2"
    
    local namespace=$(get_subnet_namespace "$vpc_name" "$subnet_type")
    
    if ! namespace_exists "$namespace"; then
        log_error "Subnet $subnet_type does not exist in VPC $vpc_name"
        exit 1
    fi
    
    log_info "  Clearing security rules from $namespace"
    
    # Flush all rules
    ip netns exec "$namespace" iptables -F
    ip netns exec "$namespace" iptables -X
    
    # Reset policies to ACCEPT
    ip netns exec "$namespace" iptables -P INPUT ACCEPT
    ip netns exec "$namespace" iptables -P FORWARD ACCEPT
    ip netns exec "$namespace" iptables -P OUTPUT ACCEPT
    
    log_success "  Security rules cleared"
}

#############################################
# Show Security Rules
# Displays current iptables rules in namespace
#############################################
show_security_rules() {
    local vpc_name="$1"
    local subnet_type="$2"
    
    local namespace=$(get_subnet_namespace "$vpc_name" "$subnet_type")
    
    if ! namespace_exists "$namespace"; then
        log_error "Subnet $subnet_type does not exist in VPC $vpc_name"
        exit 1
    fi
    
    echo ""
    echo "============================================"
    echo "Security Rules for $subnet_type in VPC $vpc_name"
    echo "============================================"
    echo ""
    ip netns exec "$namespace" iptables -L -n -v
    echo ""
}