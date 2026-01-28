#!/bin/bash
# Enable Thunderbolt Networking on Fedora 43
# Connect two PCs with Thunderbolt cable FIRST, then run this script

set -e

echo "🔥 Enabling Thunderbolt Networking on Fedora 43..."

# 1. Install and enable bolt (Thunderbolt device manager)
sudo dnf install -y bolt
sudo systemctl enable --now bolt

echo "✅ Bolt service enabled"
echo "📡 Connect Thunderbolt cable between PCs and authorize devices..."

# 2. Wait for Thunderbolt devices and auto-authorize
sleep 3
boltctl list
echo "🔑 Authorizing ALL Thunderbolt devices (run as sudo)..."
sudo boltctl authorize $(boltctl list | grep UUID | awk '{print $2}')

# 3. Load Thunderbolt networking module
sudo modprobe thunderbolt_net

# 4. Make module load on boot
echo "thunderbolt_net" | sudo tee /etc/modules-load.d/thunderbolt_net.conf

# 5. Configure network interface (usually enp0s20f0u1 or eno3)
echo "🌐 Waiting for Thunderbolt network interface..."
sleep 5

# Find Thunderbolt interface
TB_IFACE=$(ip link show | grep -i thunderbolt | awk '{print $2}' | sed 's/:$//' | head -1)
if [ -z "$TB_IFACE" ]; then
    TB_IFACE=$(ip link | grep -E 'en[x01]?\w+' | tail -1 | awk '{print $2}' | sed 's/:$//')
fi

if [ -n "$TB_IFACE" ]; then
    echo "📶 Found Thunderbolt interface: $TB_IFACE"
    
    # Bring up interface
    sudo ip link set "$TB_IFACE" up
    
    # Configure static IP for direct PC-PC connection (10Gbps!)
    sudo ip addr add 192.168.100.1/24 dev "$TB_IFACE"
    
    echo "✅ Interface $TB_IFACE configured: 192.168.100.1/24"
else
    echo "⚠️  No Thunderbolt interface found. Check cable connection."
    echo "    Run 'boltctl list' and 'ip link' to troubleshoot."
fi

# 6. Enable IP forwarding for advanced networking (optional)
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.d/99-thunderbolt.conf

# 7. Firewall: Allow Thunderbolt traffic
sudo firewall-cmd --permanent --add-interface="$TB_IFACE" --zone=internal
sudo firewall-cmd --reload

echo "🎉 THUNDERBOLT NETWORKING ENABLED!"
echo ""
echo "📋 STATUS:"
echo "   Interface: $TB_IFACE"
echo "   IP:        192.168.100.1/24"
echo "   Speed:     Up to 40Gbps!"
echo ""
echo "🔍 VERIFY:"
echo "   ping 192.168.100.2          # Other PC"
echo "   iperf3 -s                   # Speed test server"
echo "   boltctl list                # Thunderbolt status"
echo "   ip link show $TB_IFACE      # Interface status"
echo ""
echo "💡 On OTHER PC, run: ip addr add 192.168.100.2/24 dev [interface]"
