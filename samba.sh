#!/bin/bash

# =================================================================
# Samba Unified Setup Script (Server & Client)
# Υποστηρίζει: Fedora, RHEL, CentOS
# =================================================================

set -e

# --- Συνάρτηση για τον Χρήστη και το Workgroup ---
setup_common_vars() {
    echo "--- Ρυθμίσεις Χρήστη ---"
    CURRENT_USER=$(whoami)
    read -p "Δώστε το όνομα χρήστη Samba [Enter για $CURRENT_USER]: " SMB_USER
    SMB_USER=${SMB_USER:-$CURRENT_USER}

    read -p "Δώστε το Workgroup [Enter για WORKGROUP]: " WORKGROUP
    WORKGROUP=${WORKGROUP:-WORKGROUP}

    read -s -p "Δώστε τον κωδικό Samba για τον χρήστη $SMB_USER: " SMB_PASS
    echo ""
}

echo "Τι θέλετε να εγκαταστήσετε;"
echo "1) Samba Server (Κοινή χρήση φακέλων από αυτό το PC)"
echo "2) Samba Client (Σύνδεση σε φακέλους άλλου PC)"
read -p "Επιλογή (1 ή 2): " MODE

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

    echo "--- Εγκατάσταση πακέτων Server ---"
    sudo dnf install -y samba samba-common-tools policycoreutils-python-utils

    echo "--- Δημιουργία φακέλων και δικαιωμάτων ---"
    for DIR in "${DIRS[@]}"; do
        mkdir -p "$DIR"
        sudo chown -R "$SMB_USER:$SMB_USER" "$DIR"
        chmod 755 "$DIR"
    done

    echo "--- Ρύθμιση SELinux & Firewall ---"
    sudo setsebool -P samba_export_all_rw 1
    # Χωρίζουμε τις εντολές του firewall για να μην χτυπάει σφάλμα
    sudo firewall-cmd --permanent --add-service=samba
    sudo firewall-cmd --reload

    echo "--- Ορισμός κωδικού Samba ---"
    # Προσθέτουμε πρώτα τον χρήστη στο σύστημα αν δεν υπάρχει (για σιγουριά)
    # και μετά τρέχουμε το smbpasswd
    (echo "$SMB_PASS"; echo "$SMB_PASS") | sudo smbpasswd -a "$SMB_USER" -s

    echo "--- Παραμετροποίηση /etc/samba/smb.conf ---"
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true
    
    # Δημιουργία νέου smb.conf
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
    echo "✅ Ο SERVER ΕΙΝΑΙ ΕΤΟΙΜΟΣ!"
    echo "IP Διεύθυνση: $(hostname -I | awk '{print $1}')"

elif [ "$MODE" == "2" ]; then
    # ================= SETTING UP CLIENT =================
    read -p "Δώστε την IP του Server: " SERVER_IP
    setup_common_vars

    echo "--- Εγκατάσταση cifs-utils ---"
    sudo dnf install -y cifs-utils

    # Αποθήκευση κωδικών σε ασφαλές αρχείο
    CRED_FILE="$HOME/.smbcredentials"
    echo "username=$SMB_USER" > "$CRED_FILE"
    echo "password=$SMB_PASS" >> "$CRED_FILE"
    echo "domain=$WORKGROUP" >> "$CRED_FILE"
    chmod 600 "$CRED_FILE"

    MOUNT_ROOT="/mnt/samba"
    SHARES=("Development" "Share" "Backups" "Docker" "VMs")

    echo "--- Ρύθμιση αυτόματης προσάρτησης (fstab) ---"
    for SHARE in "${SHARES[@]}"; do
        LOCAL_PATH="$MOUNT_ROOT/$SHARE"
        sudo mkdir -p "$LOCAL_PATH"
        
        # Προσθήκη στο fstab με netdev και nofail για ασφάλεια στο boot
        LINE="//$SERVER_IP/$SHARE $LOCAL_PATH cifs credentials=$CRED_FILE,iocharset=utf8,uid=$(id -u),gid=$(id -g),_netdev,nofail 0 0"
        
        if ! sudo grep -q "$LOCAL_PATH" /etc/fstab; then
            echo "$LINE" | sudo tee -a /etc/fstab
        fi
    done

    sudo mount -a
    echo "✅ Ο CLIENT ΣΥΝΔΕΘΗΚΕ!"
    echo "Οι φάκελοι βρίσκονται στο: $MOUNT_ROOT"

else
    echo "Άκυρη επιλογή."
    exit 1
fi
