#!/usr/bin/env bash
set -eo pipefail
shopt -s extglob

# ============================================================
# UI / HELPERS
# ============================================================
info(){ echo -e "\e[36m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
error(){ echo -e "\e[31m[ERROR]\e[0m $*"; }

ask_user(){
  local p="$1" r
  while true; do
    read -rp "$(echo -e "\e[44m\e[1m$p [y/n]:\e[0m ")" r
    case "$r" in [Yy]) return 0;; [Nn]) return 1;; *) echo "y/n only";; esac
  done
}

pause(){ read -n1 -s -rp "Press any key to continue..."; echo; }

backup_file(){ [[ -f "$1" ]] && sudo cp -a "$1" "$1.bak.$(date +%F_%T)"; }

install_if_missing(){
  local miss=()
  for p in "$@"; do rpm -q "$p" &>/dev/null || miss+=("$p"); done
  (( ${#miss[@]}==0 )) && return 0
  info "Installing: ${miss[*]}"
  sudo dnf install "${miss[@]}"
}

safe_gsettings_set(){
  gsettings writable "$1" "$2" &>/dev/null || return 0
  gsettings set "$1" "$2" "$3"
}

# ============================================================
# PRIVILEGES
# ============================================================
clear
info "Fedora FULL Interactive Workstation Setup"
pause
sudo -v
while true; do sudo -v; sleep 60; done & SUDO_PID=$!
trap 'kill $SUDO_PID' EXIT

# ============================================================
# BASIC SYSTEM
# ============================================================
if ask_user "Optimize DNF configuration?"; then
  backup_file /etc/dnf/dnf.conf
  sudo touch /etc/dnf/dnf.conf
  sudo grep -q '^fastestmirror=' /etc/dnf/dnf.conf || sudo tee -a /etc/dnf/dnf.conf >/dev/null <<'EOF'
fastestmirror=True
max_parallel_downloads=10
deltarpm=True
keepcache=True
installonly_limit=2
EOF
fi

if ask_user "Enable periodic SSD TRIM (fstrim.timer)?"; then
  sudo systemctl enable --now fstrim.timer
fi

if ask_user "Change hostname?"; then
  read -rp "New hostname: " H
  sudo hostnamectl set-hostname "$H"
fi

if ask_user "Add Greek keyboard (GNOME user-level)?"; then
  cur="$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || echo '')"
  if ! grep -q "('xkb', 'gr')" <<<"$cur"; then
    if [[ "$cur" == "[]" || "$cur" == "@a(ss) []" || -z "$cur" ]]; then
      gsettings set org.gnome.desktop.input-sources sources "[('xkb','us'),('xkb','gr')]"
    else
      gsettings set org.gnome.desktop.input-sources sources "${cur%]*}, ('xkb','gr')]"
    fi
  fi
fi

# ============================================================
# REMOVE DEFAULT APPS
# ============================================================
UNWANTED=(evince rhythmbox abrt gnome-tour mediawriter)
if ask_user "Remove preinstalled Fedora apps (${UNWANTED[*]})?"; then
  sudo dnf remove "${UNWANTED[@]}"
fi

# ============================================================
# SYSTEM UPDATE
# ============================================================
if ask_user "Run full system update (dnf update)?"; then
  sudo dnf update
fi

# ============================================================
# PACKAGE GROUPS
# ============================================================
CORE_PACKAGES=(openssl curl fontconfig xorg-x11-font-utils dnf5 dnf5-plugins glib2 dnf-plugins-core fuse fuse-libs)
SECURITY_PACKAGES=(dnf-automatic fail2ban rkhunter lynis)
TWEAK_PACKAGES=(gnome-color-manager zram-generator-defaults)
PRODUCTIVITY_APPS=(filezilla flatseal decibels dconf-editor papers)

ask_user "Install CORE packages?" && install_if_missing "${CORE_PACKAGES[@]}"
ask_user "Install SECURITY packages?" && install_if_missing "${SECURITY_PACKAGES[@]}"
ask_user "Install TWEAK packages?" && install_if_missing "${TWEAK_PACKAGES[@]}"
ask_user "Install PRODUCTIVITY apps?" && install_if_missing "${PRODUCTIVITY_APPS[@]}"

# ============================================================
# SPEED & PERFORMANCE OPTIMIZATIONS (ONE-CLICK)
# ============================================================
if ask_user "Apply system-wide speed & performance optimizations?"; then
  info "Applying speed and performance optimizations..."

  # --- Faster boot & shutdown ---
  sudo mkdir -p /etc/systemd/system.conf.d
  sudo tee /etc/systemd/system.conf.d/timeout.conf >/dev/null <<'EOF'
[Manager]
DefaultTimeoutStartSec=10s
DefaultTimeoutStopSec=10s
EOF

  # --- Reduce swap aggressiveness ---
  sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null <<'EOF'
vm.swappiness=10
EOF

  # --- Increase file watcher limits (dev / IDE friendly) ---
  sudo tee /etc/sysctl.d/99-inotify.conf >/dev/null <<'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
EOF

  sudo sysctl --system

  # --- Disable GNOME Tracker (huge IO + CPU win) ---
  systemctl --user mask \
    tracker-miner-fs-3.service \
    tracker-extract-3.service \
    tracker-miner-rss-3.service 2>/dev/null || true

  # --- Disable PackageKit background activity ---
  sudo systemctl disable --now packagekit.service packagekit.socket 2>/dev/null || true

  # --- Disable GNOME Software autostart ---
  mkdir -p ~/.config/autostart
  if [ -f /etc/xdg/autostart/org.gnome.Software.desktop ]; then
    cp /etc/xdg/autostart/org.gnome.Software.desktop ~/.config/autostart/
    sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' \
      ~/.config/autostart/org.gnome.Software.desktop
  fi

  # --- Disable UI animations (snappier feel) ---
  gsettings set org.gnome.desktop.interface enable-animations false

  # --- GNOME usability speed wins ---
  gsettings set org.gnome.desktop.interface clock-show-seconds true
  gsettings set org.gnome.desktop.interface show-battery-percentage true

  # --- Ensure zram is enabled (Fedora default, but enforce) ---
  sudo systemctl enable --now zram-generator-defaults 2>/dev/null || true

  # --- Enable persistent system logs (helps debugging slow boots) ---
  sudo mkdir -p /var/log/journal
  sudo systemctl restart systemd-journald

  info "Speed & performance optimizations applied"
fi


# ============================================================
# FIREWALL / SNAPD
# ============================================================
ask_user "Set firewall default zone to home?" && sudo firewall-cmd --set-default-zone=home || true
if ask_user "Enable snapd support?"; then
  install_if_missing snapd
  sudo ln -sf /var/lib/snapd/snap /snap
fi

# ============================================================
# BTRFS / SNAPPER
# ============================================================
if mount | grep -q ' on / type btrfs'; then
  if ask_user "Enable Snapper for Btrfs root?"; then
    install_if_missing snapper
    sudo snapper -c root create-config / || true
    sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
  fi
fi

# ============================================================
# SELINUX INFO
# ============================================================
getenforce | grep -q Enforcing || warn "SELinux not enforcing"

# ============================================================
# REPOS (RPM FUSION + OTHERS)
# ============================================================
ensure_rpmfusion(){
  rpm -q rpmfusion-free-release rpmfusion-nonfree-release &>/dev/null && return 0
  sudo dnf install \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
}

if ask_user "Enable RPM Fusion (free + nonfree)?"; then
  ensure_rpmfusion
fi

# ============================================================
# SOFTWARE BLOCKS
# ============================================================

# --- Tailscale ---
if ask_user "Install Tailscale & Trayscale?"; then
  sudo tee /etc/yum.repos.d/tailscale.repo >/dev/null <<'EOF'
[tailscale-stable]
name=Tailscale stable
baseurl=https://pkgs.tailscale.com/stable/fedora/$basearch
enabled=1
gpgcheck=1
gpgkey=https://pkgs.tailscale.com/stable/fedora/repo.gpg
EOF
  install_if_missing tailscale trayscale
  ask_user "Enable tailscaled service?" && sudo systemctl enable --now tailscaled
fi

# --- VS Code / VSCodium ---
if ask_user "Install VS Code + VSCodium?"; then
  sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc || true
  sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
  sudo tee /etc/yum.repos.d/vscodium.repo >/dev/null <<'EOF'
[vscodium]
name=VSCodium
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
EOF
  install_if_missing code codium
fi

# --- Chrome ---
if ask_user "Install Google Chrome?"; then
  sudo tee /etc/yum.repos.d/google-chrome.repo >/dev/null <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
  install_if_missing google-chrome-stable
fi

# --- Git ---
ask_user "Install Git & Gitg?" && install_if_missing git gitg

# --- Docker + Whaler ---
if ask_user "Install Docker & Whaler?"; then
  # Ensure dnf5 plugins
  install_if_missing dnf5-plugins

  # Add Docker repository (dnf5 syntax)
  sudo dnf5 config-manager addrepo \
    --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo

  # Install Docker packages
  install_if_missing \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  # Enable Docker
  ask_user "Enable Docker service?" && sudo systemctl enable --now docker

  # Docker group
  sudo getent group docker >/dev/null || sudo groupadd docker
  sudo usermod -aG docker "${SUDO_USER:-$USER}"

  # Whaler (Flatpak)
  install_if_missing flatpak
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak install -y flathub com.github.sdv43.whaler
fi


# --- Microsoft Fonts (LPF) ---
if ask_user "Install Microsoft Fonts via LPF?"; then
  ensure_rpmfusion
  install_if_missing lpf lpf-mscore-fonts lpf-cleartype-fonts fontconfig
  sudo -u "${SUDO_USER:-$USER}" -H lpf update || warn "LPF failed"
  sudo fc-cache -rv
fi

# --- Microsoft Fonts (Legacy RPM) ---
if ask_user "Install Microsoft Core Fonts via legacy RPM?"; then
  cd /tmp
  install_if_missing curl cabextract fontconfig
  curl -L -o msttcore-fonts-installer.rpm \
    https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm
  sudo rpm -ivh --nodigest --nofiledigest msttcore-fonts-installer.rpm
  sudo fc-cache -rv
fi

# --- LibreOffice ---
ask_user "Install LibreOffice (EN + EL)?" && install_if_missing libreoffice libreoffice-langpack-en libreoffice-langpack-el

# --- Design Apps ---
ask_user "Install GIMP & Inkscape?" && install_if_missing gimp inkscape

# --- Cockpit ---
if ask_user "Install Cockpit?"; then
  install_if_missing cockpit
  sudo systemctl enable --now cockpit.socket
  sudo firewall-cmd --add-service=cockpit --permanent && sudo firewall-cmd --reload || true
fi

# ============================================================
# GNOME TWEAKS / UI
# ============================================================
if ask_user "Apply GNOME UI tweaks?"; then
  install_if_missing gnome-tweaks gnome-extensions-app gnome-usage
  safe_gsettings_set org.gnome.desktop.interface enable-animations false
  safe_gsettings_set org.gnome.desktop.wm.preferences button-layout ":minimize,maximize,close"
  safe_gsettings_set org.gnome.settings-daemon.plugins.color night-light-enabled true
  safe_gsettings_set org.gnome.nautilus.preferences show-hidden-files true
  safe_gsettings_set org.gnome.nautilus.preferences show-image-thumbnails 'always'
  safe_gsettings_set org.gnome.nautilus.preferences always-use-location-entry true
  safe_gsettings_set org.gnome.nautilus.preferences recursive-search 'never'
  safe_gsettings_set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
  safe_gsettings_set org.gnome.desktop.interface clock-show-seconds true
  safe_gsettings_set org.gnome.desktop.interface show-battery-percentage true
  safe_gsettings_set org.gnome.desktop.peripherals.touchpad tap-to-click true
  safe_gsettings_set org.gnome.desktop.peripherals.touchpad natural-scroll true
fi

# ============================================================
# GNOME EXTENSIONS
# ============================================================
if ask_user "Install GNOME Shell extensions?"; then
  install_if_missing jq unzip gnome-extensions gnome-shell-extension-prefs
  EXT_DIR="$HOME/.local/share/gnome-shell/extensions"; mkdir -p "$EXT_DIR"
  declare -A EXT=(
    [307]="dash-to-dock@micxgx.gmail.com"
    [1160]="dash-to-panel@jderose9.github.com"
    [3628]="arcmenu@arcmenu.com"
    [779]="clipboard-indicator@tudmotu.com"
    [1460]="Vitals@CoreCoding.com"
    [3193]="blur-my-shell@aunetx"
    [2087]="ding@rastersoft.com"
    [19]="user-theme@gnome-shell-extensions.gcampax.github.com"
  )
  SHELL_VERSION=$(gnome-shell --version | awk '{print $3}')
  for ID in "${!EXT[@]}"; do
    UUID="${EXT[$ID]}"
    INFO=$(curl -s "https://extensions.gnome.org/extension-info/?pk=$ID&shell_version=$SHELL_VERSION")
    URL=$(jq -r '.download_url' <<<"$INFO")
    [[ "$URL" == "null" ]] && continue
    ZIP="/tmp/$UUID.zip"
    curl -L -o "$ZIP" "https://extensions.gnome.org$URL"
    unzip -o "$ZIP" -d "$EXT_DIR/$UUID"
    rm -f "$ZIP"
    [[ -d "$EXT_DIR/$UUID/schemas" ]] && glib-compile-schemas "$EXT_DIR/$UUID/schemas"
    gnome-extensions enable "$UUID" || true
  done
fi

# ============================================================
# GNOME TEMPLATES (Right-click → New Document)
# ============================================================
if ask_user "Add GNOME Templates (Text, Markdown, HTML)?"; then
  TEMPLATES_DIR="$HOME/Templates"

  info "Creating GNOME Templates in $TEMPLATES_DIR"
  mkdir -p "$TEMPLATES_DIR"

  # Text template
  touch "$TEMPLATES_DIR/Text Document.txt"

  # Markdown template with starter content
  cat <<'EOF' > "$TEMPLATES_DIR/Markdown.md"
# Title

Write here...
EOF

  # HTML template with boilerplate
  cat <<'EOF' > "$TEMPLATES_DIR/HTML Document.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Document</title>
</head>
<body>

</body>
</html>
EOF

  # Restart Nautilus so templates appear immediately
  nautilus -q || true

  info "GNOME New Document templates added"
fi


# ============================================================
# FLATPAK APPS
# ============================================================
if ask_user "Install Flatpak user applications?"; then
  install_if_missing flatpak
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  APPS=(
    org.signal.Signal
    io.missioncenter.MissionCenter
    io.gitlab.news_flash.NewsFlash
    com.mattjakeman.ExtensionManager
    it.mijorus.gearlever
    org.gustavoperedo.FontDownloader
    io.github.flattool.Ignition
  )
  for a in "${APPS[@]}"; do flatpak install flathub "$a" || true; done
fi

if ask_user "Enable automatic Flatpak updates?"; then
  systemctl --user enable --now flatpak-system-helper.timer
fi


# ============================================================
# CLI /  SECURITY
# ============================================================
ask_user "Install CLI tools (fzf, bat, ripgrep)?" && install_if_missing fzf bat ripgrep
if ask_user "Install USBGuard?"; then install_if_missing usbguard; sudo systemctl enable --now usbguard; fi

# ============================================================
# DEV Options
# ============================================================
if ask_user "Increase file watcher limits (dev-friendly)?"; then
  sudo tee /etc/sysctl.d/99-dev.conf >/dev/null <<'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
EOF
  sudo sysctl --system
fi

if ask_user "Improve Bash defaults (history, colors, completion)?"; then
  grep -q "HISTSIZE=10000" ~/.bashrc || cat >> ~/.bashrc <<'EOF'
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'
EOF
fi

# ============================================================
# FONTS (EXTRA + NERD + FONTCONFIG)
# ============================================================
if ask_user "Install extra fonts (Noto, Roboto, JetBrains Mono, etc.)?"; then
  install_if_missing \
    fira-code-fonts jetbrains-mono-fonts google-roboto-fonts \
    google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts \
    liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts rsms-inter-fonts
fi

if ask_user "Install MesloLGS Nerd Fonts (Powerlevel10k)?"; then
  sudo wget -q -P /usr/share/fonts/ \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf || true
  sudo fc-cache -fv
fi

if ask_user "Apply font rendering tweaks (fontconfig)?"; then
  mkdir -p ~/.config/fontconfig
  cat > ~/.config/fontconfig/fonts.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintfull</const></edit>
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
</fontconfig>
EOF
fi

# ============================================================
# MEDIA CODECS
# ============================================================
if ask_user "Install media codecs (libavcodec-freeworld)?"; then
  ensure_rpmfusion
  install_if_missing libavcodec-freeworld
fi

# ============================================================
# ADVANCED: GRUB / KERNEL / FIRMWARE
# ============================================================
if ask_user "Advanced: GRUB remember last entry?"; then
  backup_file /etc/default/grub
  sudo sed -i \
    -e 's/^#\?GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \
    -e 's/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' \
    -e 's/^#\?GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' \
    -e 's/^#\?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
  sudo grub2-editenv /boot/grub2/grubenv create || true
  sudo grub2-mkconfig -o /boot/grub2/grub.cfg
fi

if ask_user "Advanced: keep only 2 kernels?"; then
  backup_file /etc/dnf/dnf.conf
  sudo sed -i '/^installonly_limit=/d' /etc/dnf/dnf.conf
  echo "installonly_limit=2" | sudo tee -a /etc/dnf/dnf.conf
  sudo dnf repoquery --installonly --latest-limit=-2
  ask_user "Remove older kernels now?" && sudo dnf repoquery --installonly --latest-limit=-2 -q | sudo xargs -r dnf remove
fi

if ask_user "Advanced: apply AMD kernel args?"; then
  sudo grubby --update-kernel=ALL --args="amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856"
  sudo grubby --info=DEFAULT | grep '^args='
fi

if ask_user "Check firmware updates (fwupd)?"; then
  sudo fwupdmgr refresh
  sudo fwupdmgr get-updates
  ask_user "Apply firmware updates?" && sudo fwupdmgr update
fi

if ask_user "Setup a second internal disk (Mount/BitLocker)?"; then
  setup_secondary_disk
fi

# ============================================================
# ΝΕΑ ΣΥΝΑΡΤΗΣΗ ΓΙΑ ΔΙΣΚΟ (BITLOCKER & NVMe SUPPORT)
# - Επιλογή ΔΙΣΚΟΥ και μετά ΕΠΙΛΟΓΗ PARTITION (όχι υπόθεση p1/1)
# - Αποφυγή διπλών fstab entries
# ============================================================
setup_secondary_disk() {
  info "Starting Disk Setup..."

  local USERNAME USERID GROUPID
  USERNAME="${SUDO_USER:-$(logname 2>/dev/null || true)}"
  [ -z "$USERNAME" ] && USERNAME="$USER"
  USERID="$(id -u "$USERNAME")"
  GROUPID="$(id -g "$USERNAME")"

  echo "=== Available Disks ==="
  mapfile -t DISKS < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')
  if [ ${#DISKS[@]} -eq 0 ]; then
    error "No disks found."
    return 1
  fi

  local i=1 DISK SIZE
  for DISK in "${DISKS[@]}"; do
    SIZE="$(lsblk -dnbo SIZE "$DISK" | numfmt --to=iec-i --suffix=B)"
    echo "[$i] $DISK ($SIZE)"
    i=$((i+1))
  done

  local DISK_NUMBER SELECTED_DISK
  while true; do
    read -rp "Select disk number: " DISK_NUMBER
    if [[ "$DISK_NUMBER" =~ ^[0-9]+$ ]] && [ "$DISK_NUMBER" -ge 1 ] && [ "$DISK_NUMBER" -le "${#DISKS[@]}" ]; then
      SELECTED_DISK="${DISKS[$((DISK_NUMBER-1))]}"
      break
    fi
    warn "Invalid selection. Try again."
  done

  echo "=== Partitions on $SELECTED_DISK ==="
  # Format: NAME|SIZE|FSTYPE|MOUNTPOINT
  mapfile -t PART_INFO < <(lsblk -nrpo NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE "$SELECTED_DISK" | awk '$5=="part"{print $1 "|" $2 "|" $3 "|" $4}')
  if [ ${#PART_INFO[@]} -eq 0 ]; then
    error "No partitions found on $SELECTED_DISK. Create a partition first."
    return 1
  fi

  i=1
  local LINE PNAME PSIZE PFSTYPE PMOUNT
  for LINE in "${PART_INFO[@]}"; do
    IFS="|" read -r PNAME PSIZE PFSTYPE PMOUNT <<< "$LINE"
    [ -z "$PFSTYPE" ] && PFSTYPE="unknown"
    [ -z "$PMOUNT" ] && PMOUNT="-"
    echo "[$i] $PNAME ($PSIZE) fstype=$PFSTYPE mount=$PMOUNT"
    i=$((i+1))
  done

  local PART_NUMBER PARTITION
  while true; do
    read -rp "Select partition number: " PART_NUMBER
    if [[ "$PART_NUMBER" =~ ^[0-9]+$ ]] && [ "$PART_NUMBER" -ge 1 ] && [ "$PART_NUMBER" -le "${#PART_INFO[@]}" ]; then
      IFS="|" read -r PARTITION _ <<< "${PART_INFO[$((PART_NUMBER-1))]}"
      break
    fi
    warn "Invalid selection. Try again."
  done

  if findmnt -rn --source "$PARTITION" >/dev/null 2>&1; then
    warn "Partition $PARTITION is already mounted. Skipping."
    findmnt --source "$PARTITION" || true
    return 0
  fi

  # BitLocker detection
  if sudo blkid "$PARTITION" 2>/dev/null | grep -iq "bitlocker"; then
    warn "BitLocker detected on $PARTITION!"
    install_if_missing dislocker fuse-dislocker

    sudo mkdir -p /mnt/bitlocker /mnt/data

    read -rsp "Enter BitLocker Password: " BL_PASS
    echo

    # Unlock
    sudo dislocker -V "$PARTITION" -u"$BL_PASS" -- /mnt/bitlocker
    sudo mount -o loop,uid="$USERID",gid="$GROUPID" /mnt/bitlocker/dislocker-file /mnt/data

    info "Disk unlocked and mounted at /mnt/data"
    warn "Note: BitLocker mounts usually require manual unlock after reboot."
    return 0
  fi

  # Non-BitLocker: mount permanently via fstab
  local FS_TYPE UUID MOUNT_NAME MOUNT_DIR OPTS FSTAB_TYPE

  FS_TYPE="$(sudo blkid -s TYPE -o value "$PARTITION" 2>/dev/null || true)"
  if [ -z "$FS_TYPE" ]; then
    error "Could not detect filesystem type for $PARTITION."
    return 1
  fi

  read -rp "Enter mount folder name (e.g. storage): " MOUNT_NAME
  # Basic sanitization: keep only safe chars
  MOUNT_NAME="$(echo "$MOUNT_NAME" | tr -cd '[:alnum:]_.-')"
  if [ -z "$MOUNT_NAME" ]; then
    error "Invalid mount folder name."
    return 1
  fi

  MOUNT_DIR="/mnt/$MOUNT_NAME"
  sudo mkdir -p "$MOUNT_DIR"

  UUID="$(sudo blkid -s UUID -o value "$PARTITION")"
  if [ -z "$UUID" ]; then
    error "Could not read UUID for $PARTITION."
    return 1
  fi

  # fstab type/opts
  FSTAB_TYPE="$FS_TYPE"
  if [[ "$FS_TYPE" == "ntfs" ]]; then
    # Fedora uses kernel ntfs3 driver by default
    FSTAB_TYPE="ntfs3"
    OPTS="defaults,uid=$USERID,gid=$GROUPID,umask=000"
  elif [[ "$FS_TYPE" == "vfat" || "$FS_TYPE" == "fat" || "$FS_TYPE" == "exfat" ]]; then
    OPTS="defaults,uid=$USERID,gid=$GROUPID,umask=000"
  else
    OPTS="defaults"
  fi

  # Avoid duplicate fstab entries
  if sudo grep -qE "^[^#].*UUID=$UUID" /etc/fstab; then
    warn "An fstab entry for UUID=$UUID already exists. Skipping fstab append."
  else
    echo "UUID=$UUID $MOUNT_DIR $FSTAB_TYPE $OPTS 0 2" | sudo tee -a /etc/fstab >/dev/null
    info "Added fstab entry for $PARTITION -> $MOUNT_DIR"
  fi

  sudo mount -a

  # Ownership only makes sense on POSIX filesystems (not ntfs/vfat)
  case "$FS_TYPE" in
    ext2|ext3|ext4|xfs|btrfs)
      sudo chown -R "$USERNAME:$USERNAME" "$MOUNT_DIR"
      ;;
    *)
      ;;
  esac

  info "Disk $PARTITION mounted at $MOUNT_DIR"
}


# ============================================================
# FINAL
# ============================================================
ask_user "Reboot now?" && reboot || info "Reboot skipped"
