#!/bin/bash

# Complete developer Samba setup for Fedora with SELinux + password "xxxxxx"

set -e
USER=$(whoami)
PASS="xxxxxx"

# Developer folders every coder needs between PCs
DIRS=(
    "/home/$USER/Development"      # Source code/projects
    "/home/$USER/Share"            # General sharing
    "/home/$USER/Backups"          # Config backups, git repos
    "/home/$USER/Docker"           # Docker images/volumes
    "/home/$USER/VMs"              # Virtual machines
)

echo "Installing Samba + SELinux tools..."
sudo dnf install -y samba samba-common-tools policycoreutils-python-utils

echo "Creating developer folders..."
for DIR in "${DIRS[@]}"; do
    echo "Creating $DIR..."
    mkdir -p "$DIR"
    sudo chown -R "$USER:$USER" "$DIR"
    chmod 755 "$DIR"
done

echo "Setting SELinux contexts RECURSIVELY for ALL shares..."
sudo setsebool -P samba_export_all_rw 1
for DIR in "${DIRS[@]}"; do
    sudo semanage fcontext -a -t samba_share_t "$DIR(/.*)?" 2>/dev/null || true
    sudo restorecon -R -v "$DIR"
done

echo "Setting Samba password for $USER (00000000)..."
echo -e "$PASS\n$PASS" | sudo smbpasswd -a "$USER" -s -e

echo "Configuring complete smb.conf for developers..."
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

sudo bash -c "cat > /etc/samba/smb.conf << EOF
[global]
   workgroup = WORKGROUP
   server string = Developer Samba Server
   security = user
   map to guest = bad user
   min protocol = SMB2

# Developer Shares - Full RW access for \$USER
[Development]
   path = /home/$USER/Development
   comment = Source code and projects
   browsable = yes
   writable = yes
   valid users = $USER
   read only = no
   guest ok = no
   force user = $USER
   force group = $USER
   create mask = 0664
   directory mask = 0775

[Share]  
   path = /home/$USER/Share
   comment = General file sharing
   browsable = yes
   writable = yes
   valid users = $USER
   read only = no
   guest ok = no
   force user = $USER
   force group = $USER

[Backups]
   path = /home/$USER/Backups
   comment = Config backups, git repos
   browsable = yes
   writable = yes
   valid users = $USER
   read only = no
   guest ok = no
   force user = $USER
   force group = $USER

[Docker]
   path = /home/$USER/Docker
   comment = Docker volumes and images
   browsable = yes
   writable = yes
   valid users = $USER
   read only = no
   guest ok = no
   force user = $USER
   force group = $USER

[VMs]
   path = /home/$USER/VMs
   comment = Virtual machines and ISOs
   browsable = yes
   writable = yes
   valid users = $USER
   read only = no
   guest ok = no
   force user = $USER
   force group = $USER
EOF"

echo "Testing config..."
sudo testparm

echo "Starting services..."
sudo systemctl enable --now smb nmb
sudo firewall-cmd --permanent --add-service=samba --reload || true

echo "✅ COMPLETE! Connect with:"
echo "Username: $USER"
echo "Password: 00000000"
echo "Server:   smb://$(hostname -I | awk '{print \$1}')"
echo ""
echo "Available shares: Development, Share, Backups, Docker, VMs"
echo "Test: smbclient -L localhost -U $USER"
