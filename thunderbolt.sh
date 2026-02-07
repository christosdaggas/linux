#!/usr/bin/env bash
#
# Fedora 43 Thunderbolt Bonding Setup
#
# Description:
# Configures a high-performance Network Bond (Mode 0) over Thunderbolt.
# - Bonding Mode 0 (Balance-RR): Aggregates bandwidth across links.
# - Fedora Safe: Uses 'grubby' for BLS bootloader & 'nmcli' for network.
# - Bulletproof: Safe for 'set -euo pipefail' (robust error handling).
# - Pure L3: Disables IPv6 on bond/slaves to prevent auto-config conflicts.
#

set -euo pipefail

# 0. Safety Check: Ensure the script is run with sudo
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: You must run this script with sudo."
   exit 1
fi

# 1. Configuration
BOND_IF="bond0"
CON_NAME="thunderbolt-bond"
MTU_SIZE=9000

echo "Starting Fedora 43 Thunderbolt Setup (v8)..."

# Ask the user for the IP address
read -p "Enter the IP address for this machine (e.g., 10.0.1.1/24): " TB_IPV4_ADDR

if [[ -z "$TB_IPV4_ADDR" ]]; then
  echo "ERROR: No IP address provided. Exiting."
  exit 1
fi

# 2. Install Packages & Enable Services
echo "Installing necessary tools (bolt, iperf3, NetworkManager)..."
dnf install -y bolt iperf3 NetworkManager firewalld

# Explicitly start NetworkManager now to ensure nmcli commands work later
systemctl enable --now NetworkManager
systemctl enable --now bolt
systemctl enable --now firewalld

# 3. Kernel Configuration (IOMMU via Grubby)
echo "Configuring IOMMU kernel arguments..."

# Safely remove old arguments (ignoring errors if they don't exist)
grubby --update-kernel=ALL --remove-args="amd_iommu=off"   || true
grubby --update-kernel=ALL --remove-args="amd_iommu=on"    || true
grubby --update-kernel=ALL --remove-args="intel_iommu=off" || true
grubby --update-kernel=ALL --remove-args="intel_iommu=on"  || true
grubby --update-kernel=ALL --remove-args="iommu=pt"        || true

# Detect CPU Vendor and apply the correct IOMMU settings
CPU_VENDOR="$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/,"",$2); print $2}')"

if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    echo "   -> AMD CPU detected: Applying amd_iommu=on iommu=pt"
    grubby --update-kernel=ALL --args="amd_iommu=on iommu=pt"
elif [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
    echo "   -> Intel CPU detected: Applying intel_iommu=on iommu=pt"
    grubby --update-kernel=ALL --args="intel_iommu=on iommu=pt"
else
    echo "   -> Generic CPU detected: Applying iommu=pt"
    grubby --update-kernel=ALL --args="iommu=pt"
fi

# 4. Network Performance Tuning (Sysctl)
echo "Applying network performance settings..."

# Try to load congestion control modules first
modprobe tcp_bbr 2>/dev/null || echo "   Warning: Module tcp_bbr not found (skipping)"
modprobe sch_fq  2>/dev/null || echo "   Warning: Module sch_fq not found (skipping)"

# Apply settings
tee /etc/sysctl.d/99-thunderbolt-bond.conf >/dev/null <<EOF
# Use Google BBR for better throughput
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Increase memory buffers for >20Gbps
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432

# Enable IP Forwarding
net.ipv4.ip_forward=1
EOF

# Load settings (non-fatal)
sysctl -p /etc/sysctl.d/99-thunderbolt-bond.conf >/dev/null || echo "   Warning: Some sysctl values could not be applied."

# 5. Load Kernel Modules
echo "Loading critical kernel modules..."
modprobe thunderbolt      || { echo "ERROR: Failed to load: thunderbolt"; exit 1; }
modprobe thunderbolt_net  || { echo "ERROR: Failed to load: thunderbolt_net"; exit 1; }
modprobe bonding          || { echo "ERROR: Failed to load: bonding"; exit 1; }

# Persist modules
tee /etc/modules-load.d/thunderbolt.conf >/dev/null <<EOF
thunderbolt
thunderbolt_net
bonding
EOF

# 6. Authorize Thunderbolt Devices
echo "Checking for connected Thunderbolt devices..."
UUIDS=$(boltctl list 2>/dev/null | grep -Eio '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' | sort -u || true)

if [[ -n "$UUIDS" ]]; then
    for uuid in $UUIDS; do
        echo "   -> Authorizing device UUID: $uuid"
        boltctl enroll "$uuid" >/dev/null 2>&1 || boltctl authorize "$uuid" >/dev/null 2>&1 || true
    done
else
    echo "   -> No devices found currently. Plug them in and re-run this script."
fi

# 7. Configure NetworkManager (Bonding)
echo "Configuring NetworkManager..."

# Clean up old connections (Pipefail-safe method using process substitution)
while IFS= read -r con; do
    if [[ -n "$con" ]]; then
        nmcli con delete "$con" >/dev/null 2>&1 || true
    fi
done < <(nmcli -g NAME connection show 2>/dev/null | grep -F "bond-slave-" || true)

# Also delete the main bond if it exists
nmcli con delete "$CON_NAME" >/dev/null 2>&1 || true

# 7a. Create the Master Bond Interface (Pure L3: IPv6 Disabled)
echo "   -> Creating Master Bond ($CON_NAME)..."
nmcli con add type bond con-name "$CON_NAME" ifname "$BOND_IF" \
    bond.options "mode=balance-rr,miimon=100" \
    ipv4.method manual ipv4.addresses "$TB_IPV4_ADDR" \
    ipv4.never-default yes \
    ipv6.method disabled \
    802-3-ethernet.mtu "$MTU_SIZE" \
    autoconnect yes

# 7b. Scan for Available Thunderbolt Network Interfaces
echo "   -> Scanning for 'thunderbolt_net' interfaces..."
TB_INTERFACES=()

# Iterate over all network devices in /sys/class/net/
for p in /sys/class/net/*; do
    iface_name=$(basename "$p")
    [[ "$iface_name" == "lo" ]] && continue
    
    # Check if the driver is 'thunderbolt_net' (Safe readlink)
    if [[ -e "$p/device/driver/module" ]]; then
        driver_path=$(readlink -f "$p/device/driver/module" 2>/dev/null || true)
        if [[ "$(basename "$driver_path")" == "thunderbolt_net" ]]; then
            TB_INTERFACES+=("$iface_name")
        fi
    fi
done

# Safe sorting using mapfile
mapfile -t TB_INTERFACES < <(printf '%s\n' "${TB_INTERFACES[@]}" | sort)

NUM_FOUND=${#TB_INTERFACES[@]}

if (( NUM_FOUND == 0 )); then
    echo "   WARNING: No 'thunderbolt_net' interfaces found."
    echo "   The Master Bond was created. Plug in the cable(s) and run this script again."

elif (( NUM_FOUND == 1 )); then
    echo "   WARNING: Only 1 interface found (${TB_INTERFACES[0]})."
    echo "   Bonding configured, but speed won't double until a 2nd cable is added and script re-run."
    
    nmcli con add type ethernet con-name "bond-slave-${TB_INTERFACES[0]}" \
            ifname "${TB_INTERFACES[0]}" \
            master "$CON_NAME" \
            ipv4.method disabled ipv6.method disabled \
            802-3-ethernet.mtu "$MTU_SIZE"

else
    # Found 2 or more interfaces. Configure the first 2.
    echo "   -> Found $NUM_FOUND interfaces. Configuring the first 2 for bonding."
    for (( i=0; i<2; i++ )); do
        iface="${TB_INTERFACES[$i]}"
        echo "      + Adding slave interface: $iface"
        nmcli con add type ethernet con-name "bond-slave-$iface" \
            ifname "$iface" \
            master "$CON_NAME" \
            ipv4.method disabled ipv6.method disabled \
            802-3-ethernet.mtu "$MTU_SIZE"
    done
fi

# Bring up the connection (Observable: Warns instead of silencing errors)
echo "   -> Activating connection..."
nmcli con up "$CON_NAME" || echo "   ⚠️ WARNING: Could not bring up $CON_NAME yet (Check cables)."

# 8. Configure Firewall
echo "Configuring Firewall (Internal Zone)..."
firewall-cmd --permanent --zone=internal --add-interface="$BOND_IF" >/dev/null || true
firewall-cmd --permanent --zone=internal --add-port=5201/tcp >/dev/null || true
firewall-cmd --reload >/dev/null || true

# 9. Completion
echo ""
echo "SETUP COMPLETED SUCCESSFULLY!"
echo "-----------------------------------------------------"
echo "   Interface:  $BOND_IF (Balance-RR)"
echo "   IP Address: $TB_IPV4_ADDR"
echo "   MTU:        $MTU_SIZE"
echo "   IPv6:       Disabled (Clean L3)"
echo "-----------------------------------------------------"
echo "IMPORTANT: Reboot required to apply IOMMU kernel argument changes."
echo "REMINDER:  Run this on the 2nd PC with a different IP."
echo ""
