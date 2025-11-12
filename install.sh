#!/bin/bash

#############################################
# Installation script for vpcctl
# Installs vpcctl and all its dependencies
#############################################

set -e

echo "============================================"
echo "vpcctl Installation"
echo "============================================"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Check for required commands
echo "[1/6] Checking dependencies..."
MISSING_DEPS=""

for cmd in ip iptables jq; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_DEPS="$MISSING_DEPS $cmd"
    fi
done

if [[ -n "$MISSING_DEPS" ]]; then
    echo "Error: Missing required dependencies:$MISSING_DEPS"
    echo ""
    echo "Please install them first:"
    echo "  Ubuntu/Debian: sudo apt-get install iproute2 iptables jq"
    echo "  RHEL/CentOS:   sudo yum install iproute iptables jq"
    exit 1
fi

echo "  ✓ All dependencies found"
echo ""

# Create directories
echo "[2/6] Creating directories..."
mkdir -p /usr/lib/vpcctl
mkdir -p /var/lib/vpcctl
echo "  ✓ Created /usr/lib/vpcctl"
echo "  ✓ Created /var/lib/vpcctl"
echo ""

# Copy main executable
echo "[3/6] Installing vpcctl executable..."
if [[ ! -f "vpcctl" ]]; then
    echo "Error: vpcctl file not found in current directory"
    exit 1
fi

cp vpcctl /usr/local/bin/vpcctl
chmod +x /usr/local/bin/vpcctl
echo "  ✓ Installed to /usr/local/bin/vpcctl"
echo ""

# Copy library files
echo "[4/6] Installing library files..."
for lib_file in utils.sh state.sh core.sh subnet.sh nat.sh peering.sh security.sh; do
    if [[ ! -f "$lib_file" ]]; then
        echo "Error: $lib_file not found in current directory"
        exit 1
    fi
    cp "$lib_file" /usr/lib/vpcctl/
    echo "  ✓ Installed $lib_file"
done
echo ""

# Initialize state file
echo "[5/6] Initializing state..."
if [[ ! -f /var/lib/vpcctl/state.json ]]; then
    echo '{"vpcs":{}}' > /var/lib/vpcctl/state.json
    echo "  ✓ Created /var/lib/vpcctl/state.json"
else
    echo "  ✓ State file already exists"
fi

touch /var/lib/vpcctl/vpcctl.log
echo "  ✓ Created /var/lib/vpcctl/vpcctl.log"
echo ""

# Create example rules file
echo "[6/6] Creating example security rules..."
cat > /var/lib/vpcctl/example-rules.json << 'EOF'
{
  "subnet": "10.0.1.0/24",
  "ingress": [
    {"port": 80, "protocol": "tcp", "action": "allow"},
    {"port": 443, "protocol": "tcp", "action": "allow"},
    {"port": 22, "protocol": "tcp", "action": "deny"}
  ],
  "egress": [
    {"port": 53, "protocol": "udp", "action": "allow"},
    {"port": 80, "protocol": "tcp", "action": "allow"},
    {"port": 443, "protocol": "tcp", "action": "allow"}
  ]
}
EOF
echo "  ✓ Created /var/lib/vpcctl/example-rules.json"
echo ""

echo "============================================"
echo "Installation Complete!"
echo "============================================"
echo ""
echo "Usage: vpcctl <command> [options]"
echo ""
echo "Quick start:"
echo "  1. Create a VPC:"
echo "     vpcctl create --name my-vpc --cidr 10.0.0.0/16 --subnets public,private --enable-nat"
echo ""
echo "  2. List VPCs:"
echo "     vpcctl list"
echo ""
echo "  3. Validate VPC:"
echo "     vpcctl validate --vpc my-vpc"
echo ""
echo "  4. Get help:"
echo "     vpcctl --help"
echo ""
echo "Example security rules file:"
echo "  /var/lib/vpcctl/example-rules.json"
echo ""