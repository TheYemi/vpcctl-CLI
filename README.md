# vpcctl - VPC Network Simulator

A CLI tool to simulate AWS VPC-like networking using Linux namespaces, bridges, and iptables.

## Features

- Create isolated VPCs with custom CIDR ranges
- Automatic subnet creation with dynamic IP allocation
- NAT gateway simulation for internet access
- VPC peering for inter-VPC communication
- Security groups using iptables
- JSON-based security policy files
- Complete lifecycle management
- Built-in validation and testing
- Idempotent operations

## Installation

### Prerequisites

- Linux system with kernel namespace support
- Root/sudo access
- Required packages: `iproute2`, `iptables`, `jq`

### Install Dependencies

```bash
# Ubuntu/Debian
sudo apt update
sudo apt-get install iproute2 iptables jq

# RHEL/CentOS
sudo yum install iproute iptables jq

# Install git
sudo apt update
sudo apt install git -y
```

### Install vpcctl

```bash
# Clone the vpcctl repo
git clone git@github.com:TheYemi/vpcctl-CLI.git
# Go to the scripts folder
cd vpcctl
# Make scripts executionable
sudo chmod +x *.sh 
# Run the installation script
sudo bash install.sh
```

This will:
- Install `vpcctl` to `/usr/local/bin/`
- Copy library files to `/usr/lib/vpcctl/`
- Create state directory at `/var/lib/vpcctl/`
- Initialize state and log files

## Quick Start

### 1. Create a VPC

```bash
# Create VPC with public and private subnets
sudo vpcctl create \
  --name my-vpc \
  --cidr 10.0.0.0/16 \
  --subnets public,private \
  --enable-nat
```

This creates:
- VPC with CIDR 10.0.0.0/16
- Public subnet: 10.0.1.0/24 (with internet access)
- Private subnet: 10.0.2.0/24 (isolated)
- NAT gateway for public subnet

### 2. List VPCs

```bash
sudo vpcctl list
```

### 3. Validate Connectivity

```bash
sudo vpcctl validate --vpc my-vpc
```

### 4. Execute Commands in Subnet

```bash
# Start a web server in public subnet
sudo vpcctl exec --vpc my-vpc --subnet public -- python3 -m http.server 80

# Open a shell in private subnet
sudo vpcctl exec --vpc my-vpc --subnet private -- bash
```

### 5. Peer VPCs

```bash
# Create second VPC
sudo vpcctl create \
  --name vpc-2 \
  --cidr 172.16.0.0/16 \
  --subnets public,private

# Peer the VPCs
sudo vpcctl peer --vpc1 my-vpc --vpc2 vpc-2
```

### 6. Apply Security Rules

```bash
# Create rules file (see example-rules.json)
sudo vpcctl security \
  --vpc my-vpc \
  --subnet public \
  --rules-file /var/lib/vpcctl/example-rules.json
```

### 7. Delete VPC

```bash
sudo vpcctl delete --name my-vpc
```

## Commands

### `create` - Create a new VPC

```bash
vpcctl create --name NAME --cidr CIDR --subnets TYPES [--enable-nat]
```

Options:
- `--name`: VPC name (required)
- `--cidr`: VPC CIDR block, e.g., 10.0.0.0/16 (required)
- `--subnets`: Comma-separated subnet types, e.g., public,private (required)
- `--enable-nat`: Enable NAT gateway for internet access (optional)

### `list` - List all VPCs

```bash
vpcctl list
```

### `describe` - Show VPC details

```bash
vpcctl describe --vpc NAME
```

### `delete` - Delete a VPC

```bash
vpcctl delete --name NAME
```

### `peer` - Peer two VPCs

```bash
vpcctl peer --vpc1 NAME1 --vpc2 NAME2
```

### `unpeer` - Remove VPC peering

```bash
vpcctl unpeer --vpc1 NAME1 --vpc2 NAME2
```

### `security` - Apply security rules

```bash
vpcctl security --vpc NAME --subnet TYPE --rules-file FILE
```

### `exec` - Execute command in subnet

```bash
vpcctl exec --vpc NAME --subnet TYPE -- COMMAND [ARGS...]
```

### `validate` - Validate VPC configuration

```bash
vpcctl validate --vpc NAME
```

### `cleanup` - Delete all VPCs

```bash
vpcctl cleanup --all
```

## Security Rules Format

Security rules are defined in JSON format:

```json
{
  "subnet": "10.0.1.0/24",
  "ingress": [
    {"port": 80, "protocol": "tcp", "action": "allow"},
    {"port": 22, "protocol": "tcp", "action": "deny"}
  ],
  "egress": [
    {"port": 53, "protocol": "udp", "action": "allow"}
  ]
}
```

## How It Works

### VPC Creation
1. Creates a Linux bridge as the VPC router
2. Creates network namespaces for each subnet
3. Connects subnets to bridge using veth pairs
4. Configures IP addressing and routing
5. Optionally configures NAT for internet access

### NAT Gateway
- Creates veth pair connecting bridge to host
- Configures MASQUERADE iptables rule
- Enables IP forwarding
- Private subnets remain isolated

### VPC Peering
- Creates veth pair between VPC bridges
- Adds static routes for cross-VPC communication
- Updates NAT rules to exclude peer traffic
- Configures iptables FORWARD rules

### Security Groups
- Applies iptables rules inside namespaces
- Default-deny with explicit allows
- Supports ingress and egress rules
- Allows established connections

## Files and Directories

```
/usr/local/bin/vpcctl          # Main executable
/usr/lib/vpcctl/               # Library files
  ├── utils.sh                 # Utility functions
  ├── state.sh                 # State management
  ├── core.sh                  # Core VPC operations
  ├── subnet.sh                # Subnet management
  ├── nat.sh                   # NAT gateway
  ├── peering.sh               # VPC peering
  └── security.sh              # Security groups
/var/lib/vpcctl/               # State and logs
  ├── state.json               # VPC state database
  ├── vpcctl.log               # Operation logs
  └── example-rules.json       # Example security rules
```

## Examples

### Example 1: Simple VPC

```bash
# Create VPC with two subnets
sudo vpcctl create \
  --name simple-vpc \
  --cidr 10.0.0.0/16 \
  --subnets public,private

# Validate connectivity
sudo vpcctl validate --vpc simple-vpc
```

### Example 2: VPC with Internet Access

```bash
# Create VPC with NAT
sudo vpcctl create \
  --name internet-vpc \
  --cidr 10.1.0.0/16 \
  --subnets public,private \
  --enable-nat

# Test internet from public subnet
sudo vpcctl exec --vpc internet-vpc --subnet public -- ping -c 3 8.8.8.8

# Verify private subnet has no internet
sudo vpcctl exec --vpc internet-vpc --subnet private -- ping -c 3 8.8.8.8
```

### Example 3: Peered VPCs

```bash
# Create two VPCs
sudo vpcctl create --name vpc-a --cidr 10.0.0.0/16 --subnets public,private
sudo vpcctl create --name vpc-b --cidr 172.16.0.0/16 --subnets public,private

# Peer them
sudo vpcctl peer --vpc1 vpc-a --vpc2 vpc-b

# Test cross-VPC connectivity
sudo vpcctl exec --vpc vpc-a --subnet public -- ping -c 3 172.16.1.10
```

### Example 4: Security Groups

```bash
# Create VPC
sudo vpcctl create \
  --name secure-vpc \
  --cidr 10.2.0.0/16 \
  --subnets public,private \
  --enable-nat

# Apply security rules
sudo vpcctl security \
  --vpc secure-vpc \
  --subnet public \
  --rules-file /var/lib/vpcctl/example-rules.json

# Start HTTP server
sudo vpcctl exec --vpc secure-vpc --subnet public -- python3 -m http.server 80 &

# Test from private subnet (should work - HTTP allowed)
sudo vpcctl exec --vpc secure-vpc --subnet private -- curl http://10.2.1.10

# Test SSH (should fail - SSH denied)
sudo vpcctl exec --vpc secure-vpc --subnet private -- nc -zv 10.2.1.10 22
```

## Troubleshooting

### Check VPC state
```bash
cat /var/lib/vpcctl/state.json | jq .
```

### View logs
```bash
tail -f /var/lib/vpcctl/vpcctl.log
```

### Check namespaces
```bash
sudo ip netns list
```

### Check bridges
```bash
sudo ip link show type bridge
```

### Check iptables rules
```bash
sudo iptables -t nat -L -n -v
sudo iptables -L FORWARD -n -v
```

### Manual cleanup (if needed)
```bash
# Delete all namespaces
for ns in $(ip netns list | awk '{print $1}'); do
  sudo ip netns del $ns
done

# Delete all bridges
for br in $(ip link show type bridge | grep '^[0-9]' | awk -F': ' '{print $2}'); do
  sudo ip link del $br
done

# Flush iptables
sudo iptables -t nat -F
sudo iptables -F FORWARD
```