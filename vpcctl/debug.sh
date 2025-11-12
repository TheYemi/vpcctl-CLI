#!/bin/bash

# Quick debug script - run this when you get the namespace error
# Usage: sudo bash debug-namespace.sh my-vpc public

VPC_NAME="$1"
SUBNET_TYPE="$2"

if [[ -z "$VPC_NAME" ]] || [[ -z "$SUBNET_TYPE" ]]; then
    echo "Usage: sudo bash debug-namespace.sh VPC_NAME SUBNET_TYPE"
    echo "Example: sudo bash debug-namespace.sh my-vpc public"
    exit 1
fi

STATE_FILE="/var/lib/vpcctl/state.json"

echo "=========================================="
echo "Namespace Debug Report"
echo "=========================================="
echo ""

echo "1. What the state file says:"
echo "---"
STORED_NS=$(jq -r ".vpcs.\"$VPC_NAME\".subnets.\"$SUBNET_TYPE\".namespace // \"NOT_IN_STATE\"" "$STATE_FILE")
echo "   Namespace in state: $STORED_NS"
echo ""

echo "2. What get_namespace_name() would generate:"
echo "---"
GENERATED_NS="${VPC_NAME}-${SUBNET_TYPE}-subnet"
echo "   Generated name: $GENERATED_NS"
echo ""

echo "3. Do they match?"
echo "---"
if [[ "$STORED_NS" == "$GENERATED_NS" ]]; then
    echo "   ✓ YES - Names match"
else
    echo "   ✗ NO - MISMATCH FOUND!"
    echo "   This is your problem!"
fi
echo ""

echo "4. What namespaces actually exist in the system:"
echo "---"
ip netns list
echo ""

echo "5. Does the stored namespace exist?"
echo "---"
if ip netns list | grep -q "^${STORED_NS}$"; then
    echo "   ✓ YES - $STORED_NS exists"
else
    echo "   ✗ NO - $STORED_NS does NOT exist"
fi
echo ""

echo "6. Does the generated namespace exist?"
echo "---"
if ip netns list | grep -q "^${GENERATED_NS}$"; then
    echo "   ✓ YES - $GENERATED_NS exists"
else
    echo "   ✗ NO - $GENERATED_NS does NOT exist"
fi
echo ""

echo "7. Full subnet data from state:"
echo "---"
jq ".vpcs.\"$VPC_NAME\".subnets.\"$SUBNET_TYPE\"" "$STATE_FILE"
echo ""

echo "=========================================="
echo "Diagnosis:"
echo "=========================================="
if [[ "$STORED_NS" == "NOT_IN_STATE" ]]; then
    echo "Problem: Subnet not found in state file"
    echo "Solution: The subnet was never created or state is corrupted"
elif [[ "$STORED_NS" != "$GENERATED_NS" ]]; then
    echo "Problem: Name mismatch between state and generator function"
    echo "Solution: Fix the get_namespace_name() function or state"
elif ! ip netns list | grep -q "^${STORED_NS}$"; then
    echo "Problem: Namespace in state but doesn't exist in system"
    echo "Solution: State is out of sync. Recreate VPC or fix manually"
else
    echo "Everything looks correct! The error might be elsewhere."
fi
echo ""