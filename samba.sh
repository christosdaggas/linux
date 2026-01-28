#!/bin/bash

# =================================================================
# Samba Unified Setup Script (Server & Client)
# Supports: Fedora, RHEL, CentOS
# =================================================================

set -e

# --- Function for User and Workgroup Settings ---
setup_common_vars() {
    echo "--- User Settings ---"
    CURRENT_USER=$(whoami)
    read -p "Enter Samba username [Enter for $CURRENT_USER]: " SMB_USER
    SMB_USER=${SMB_USER:-$CURRENT_USER}

    read -p "Enter Workgroup [Enter for WORKGROUP]: " WORKGROUP
    WORKGROUP=${WORKGROUP:-WORKGROUP}

    read -s -p "Enter Samba password for user $SMB_USER: " SMB_PASS
    echo ""
}

echo "What would you like to set up?"
echo "1) Samba Server (Share folders from this PC)"
echo "2) Samba Client (Connect to folders on another PC)"
read -p "Choice (1 or 2): " MODE

if [ "$MODE" == "1" ]; then
    # ================= SETTING UP SERVER =================
    setup_common_vars
    
    DIRS=(
        "/home/$SMB_USER/Development"
        "/home/$SMB_USER/Share"
        "/home/$SMB_USER/Backups"
        "/home/$SMB_USER/Docker"
        "/home/$SMB_USER/VMs"
    )

    echo "--- Installing Server Packages ---"
    sudo dnf install -y samba samba-common-tools policycoreutils-python-utils

    echo "--- Creating Folders and Permissions ---"
    for DIR in "${DIRS[@]}"; do
        mkdir -p "$DIR"
        sudo chown -R "$SMB_USER:$SMB_USER" "$DIR"
        chmod 755 "$DIR"
    done

    echo "--- Configuring SELinux & Firewall ---"
    sudo setsebool -P samba_export_all_rw 1
    # Separate firewall commands to prevent errors
    sudo firewall-cmd --permanent --add-service=samba
    sudo firewall-cmd --reload

    echo "--- Setting Samba Password ---"
    # Adding the user to Samba database (using -a to add/create)
    (echo "$SMB_PASS"; echo "$SMB_PASS") | sudo smbpasswd -a "$SMB_USER" -s

    echo "--- Configuring /etc/samba/smb.conf ---"
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true
    
    # Generate new smb.conf
    sudo bash -c "cat > /etc/samba/smb.conf << EOF
[global]
    workgroup = $WORKGROUP
    server string = Developer Samba Server
    security = user
    map to guest = bad user
    min protocol = SMB2

[Development]
    path = /home/$SMB_USER/Development
    browsable = yes
    writable = yes
    valid users = $SMB_USER
    force user = $SMB_USER

[Share]
    path = /home/$SMB_USER/Share
    browsable = yes
    writable = yes
    valid users = $SMB_USER

[Backups]
    path = /home/$SMB_USER/Backups
    browsable = yes
    writable = yes
    valid users = $SMB_USER

[Docker]
    path = /home/$SMB_USER/Docker
    browsable = yes
    writable = yes
    valid users = $SMB_USER

[VMs]
    path = /home/$SMB_USER/VMs
    browsable = yes
    writable = yes
    valid users = $SMB_USER
EOF"

    sudo systemctl enable --now smb nmb
    echo "✅ SERVER SETUP COMPLETE!"
    echo "Server IP Address: $(hostname -I | awk '{print $1}')"

elif [ "$MODE" == "2" ]; then
    # ================= SETTING UP CLIENT =================
    read -p "Enter Server IP Address: " SERVER_IP
    setup_common_vars

    echo "--- Installing cifs-utils ---"
    sudo dnf install -y cifs-utils

    # Save credentials in a secure file
    CRED_FILE="$HOME/.smbcredentials"
    echo "username=$SMB_USER" > "$CRED_FILE"
    echo "password=$SMB_PASS" >> "$CRED_FILE"
    echo "domain=$WORKGROUP" >> "$CRED_FILE"
    chmod 600 "$CRED_FILE"

    MOUNT_ROOT="/mnt/samba"
    SHARES=("Development" "Share" "Backups" "Docker" "VMs")

    echo "--- Configuring Auto-mount (fstab) ---"
    for SHARE in "${SHARES[@]}"; do
        LOCAL_PATH="$MOUNT_ROOT/$SHARE"
        sudo mkdir -p "$LOCAL_PATH"
        
        # Add to fstab with netdev and nofail for boot safety
        LINE="//$SERVER_IP/$SHARE $LOCAL_PATH cifs credentials=$CRED_FILE,iocharset=utf8,uid=$(id -u),gid=$(id -g),_netdev,nofail 0 0"
        
        if ! sudo grep -q "$LOCAL_PATH" /etc/fstab; then
            echo "$LINE" | sudo tee -a /etc/fstab
        fi
    done

    sudo mount -a
    echo "✅ CLIENT CONNECTED!"
    echo "Shares are mounted at: $MOUNT_ROOT"

else
    echo "Invalid option."
    exit 1
fi
