#!/bin/bash
#
# NRC Server Kernel Parameter Optimization
# Run as root: sudo ./setup-kernel-params.sh
#

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

NRC_USER="${1:-$SUDO_USER}"

echo "=== NRC Server Kernel Optimization ==="
echo "Configuring for user: $NRC_USER"

# Create sysctl configuration
cat > /etc/sysctl.d/99-nrc-server.conf << 'EOF'
# NRC Server - io_uring optimized WebSocket server

# io_uring specific
vm.max_map_count = 2097152
kernel.io_uring_disabled = 0

# Network - connection handling capacity
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# File descriptors
fs.file-max = 2097152

# TCP memory and buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Faster connection recycling
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Ephemeral ports
net.ipv4.ip_local_port_range = 1024 65535

# Keepalive for dead connection detection
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF

echo "[+] Created /etc/sysctl.d/99-nrc-server.conf"

# Apply sysctl settings
sysctl --system > /dev/null 2>&1
echo "[+] Applied sysctl settings"

# Create limits configuration
cat > /etc/security/limits.d/99-nrc-server.conf << EOF
# NRC Server limits
$NRC_USER  soft  nofile   1048576
$NRC_USER  hard  nofile   1048576
$NRC_USER  soft  memlock  unlimited
$NRC_USER  hard  memlock  unlimited
EOF

echo "[+] Created /etc/security/limits.d/99-nrc-server.conf"

# For systemd services, create override
mkdir -p /etc/systemd/system/nrc.service.d
cat > /etc/systemd/system/nrc.service.d/limits.conf << 'EOF'
[Service]
LimitNOFILE=1048576
LimitMEMLOCK=infinity
EOF

echo "[+] Created systemd service limits override"

echo ""
echo "=== Done ==="
echo "NOTE: Log out and back in (or reboot) for limits to take effect."
echo "Verify with: ulimit -n && ulimit -l"
