#!/bin/bash

# security.sh - Security group operations
# Implements firewall rules using iptables

# Apply Security Rules
# Applies iptables rules from JSON file to subnet
# This follows your manual iptables commands
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
        
        if [[ "$action" == "allow" ]]; then
            log_info "      Rule: $protocol/$port -> ALLOW"
            ip netns exec "$namespace" iptables -A INPUT -p "$protocol" --dport "$port" -j ACCEPT
        elif [[ "$action" == "deny" ]]; then
            log_info "      Rule: $protocol/$port -> DENY (handled by default DROP policy)"
        else
            log_info "      Unknown action '$action' for port $port, skipping"
        fi
    done
    
    # Show applied rules
    echo ""
    echo "Applied iptables rules in $namespace:"
    echo "---"
    ip netns exec "$namespace" iptables -L -n -v
    echo ""
}

# Clear Security Rules
# Resets iptables in namespace to default
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

# Show Security Rules
# Displays current iptables rules in namespace
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