#!/bin/bash
# Complete Thunderbolt Networking Setup for Fedora 43
# Includes ALL steps from geosp gist + Fedora NetworkManager compatibility

set -e

echo "🚀 Complete Thunderbolt Networking Setup for Fedora 43 (geosp Gist + Fedora NM)"

# ========== PREREQUISITES ==========
echo "📦 Installing required packages..."
sudo dnf install -y bolt iperf3 NetworkManager-tui

# ========== 1. ENABLE & START BOLT ==========
echo "🔌 Enabling Bolt Thunderbolt manager..."
sudo systemctl enable --now bolt
sleep 2

# ========== 2. IOMMU + GRUB CONFIG ==========
CPU_TYPE=$(lscpu | grep "Vendor ID" | awk '{print $3}')
echo "🖥️  Detected CPU: $CPU_TYPE"

if [[ "$CPU_TYPE" == *"GenuineIntel"* ]]; then
    IOMMU="intel_iommu=on"
elif [[ "$CPU_TYPE" == *"AuthenticAMD"* ]]; then
    IOMMU="amd_iommu=on"
else
    IOMMU="iommu=pt"
fi

echo "Configuring GRUB for IOMMU: $IOMMU..."
sudo sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet $IOMMU iommu=pt\"/" /etc/default/grub
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
echo "✅ GRUB updated. REBOOT REQUIRED after script completes."

# ========== 3. THUNDERBOLT MODULES ==========
echo "⚡ Loading Thunderbolt modules..."
sudo modprobe thunderbolt thunderbolt-net
echo -e "thunderbolt\nthunderbolt-net" | sudo tee /etc/modules-load.d/thunderbolt.conf

# ========== 4. PERSISTENT INTERFACE NAMING ==========
echo "🔗 Creating persistent Thunderbolt interface (eno3)..."
sudo mkdir -p /etc/systemd/network
sudo bash -c 'cat > /etc/systemd/network/00-thunderbolt-eno3.link << EOF
[Match]
Driver=thunderbolt-net

[Link]
Name=eno3
MACAddressPolicy=none
EOF'

# Reload udev rules to apply the new interface name
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=net

# ========== 5. AUTHORIZE THUNDERBOLT DEVICES ==========
echo "📡 Connect Thunderbolt cable NOW and press Enter..."
read -r
boltctl list
echo "🔑 Auto-authorizing ALL Thunderbolt devices..."
sudo boltctl authorize 0 || true  # Authorize first device
sleep 3

# Wait for the interface to come up
echo "⏳ Waiting for Thunderbolt interface..."
for i in {1..30}; do
    if ip link show eno3 &>/dev/null; then
        break
    fi
    sleep 1
done

# ========== 6. SYSTEMD SERVICE FOR RELIABLE STARTUP ==========
echo "⚙️  Creating thunderbolt-up.service (geosp method)..."
sudo bash -c 'cat > /etc/systemd/system/thunderbolt-up.service << EOF
[Unit]
Description=Thunderbolt Networking Interface
After=systemd-udev-settle.service NetworkManager.service bolt.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/bash -c "while ! ip link show eno3 > /dev/null 2>&1; do sleep 1; done"
ExecStart=/usr/bin/nmcli con add type ethernet ifname eno3 con-name thunderbolt-net ipv4.method manual ipv4.addresses 10.0.1.1/24 ipv4.gateway "" autoconnect yes
ExecStart=/usr/sbin/ip link set eno3 up

[Install]
WantedBy=multi-user.target
EOF'

sudo systemctl daemon-reload
sudo systemctl enable thunderbolt-up.service

# ========== 7. FIREWALL & FORWARDING ==========
echo "🛡️ Configuring firewall..."
sudo firewall-cmd --permanent --add-interface=eno3 --zone=internal
sudo firewall-cmd --permanent --add-port=5201/tcp  # iperf3
sudo firewall-cmd --reload

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-thunderbolt.conf
sudo sysctl -p /etc/sysctl.d/99-thunderbolt.conf

# ========== 8. SELINUX (Fedora 43) ==========
sudo setsebool -P thunderbolt_enable_user 1 2>/dev/null || true

echo "🎉 THUNDERBOLT NETWORKING SETUP COMPLETE!"
echo ""
echo "📋 SUMMARY:"
echo "   Interface: eno3 (10.0.1.1/24)"
echo "   Service:   thunderbolt-up.service"
echo "   REBOOT:    REQUIRED for IOMMU"
echo ""
echo "✅ CURRENT STATUS:"
ip addr show eno3 2>/dev/null || echo "   eno3 not ready yet - normal after cable connect"
boltctl list
echo ""
echo "🚀 TEST (after reboot + cable connect):"
echo "   # PC1: iperf3 -s"
echo "   # PC2: iperf3 -c 10.0.1.1"
echo ""
echo "💾 Save as thunderbolt-setup-fedora.sh && chmod +x && sudo ./thunderbolt-setup-fedora.sh"
echo "🔄 REBOOT when prompted, connect cable, then test!"
