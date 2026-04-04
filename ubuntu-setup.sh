#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s extglob

# ============================================================
# UBUNTU INTERACTIVE WORKSTATION SETUP
# Rebuilt from a Fedora-oriented script for Ubuntu GNOME systems.
# Designed for Ubuntu 22.04+ and 24.04+ with defensive checks.
# ============================================================

# -----------------------------
# UI / HELPERS
# -----------------------------
info(){ echo -e "\e[36m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
error(){ echo -e "\e[31m[ERROR]\e[0m $*"; }

ask_user(){
  local p="$1" r
  while true; do
    read -rp "$(echo -e "\e[44m\e[1m$p [y/n]:\e[0m ")" r
    case "$r" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo "y/n only" ;;
    esac
  done
}

pause(){ read -n1 -s -rp "Press any key to continue..."; echo; }
backup_file(){ [[ -f "$1" ]] && sudo cp -a "$1" "$1.bak.$(date +%F_%T)"; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }

safe_gsettings_set(){
  command_exists gsettings || return 0
  gsettings writable "$1" "$2" &>/dev/null || return 0
  gsettings set "$1" "$2" "$3" || true
}

# -----------------------------
# DISTRO / ENV VALIDATION
# -----------------------------
require_ubuntu(){
  [[ -r /etc/os-release ]] || { error "/etc/os-release not found"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    error "This script is intended for Ubuntu. Detected: ${PRETTY_NAME:-unknown}"
    exit 1
  fi
  UBUNTU_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  UBUNTU_VERSION_ID="${VERSION_ID:-}"
  export UBUNTU_CODENAME UBUNTU_VERSION_ID
}

# -----------------------------
# APT / DPKG HELPERS
# -----------------------------
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_UPDATED=0

wait_for_apt(){
  local locks=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/cache/apt/archives/lock
    /var/lib/apt/lists/lock
  )

  while true; do
    local busy=0 lock
    for lock in "${locks[@]}"; do
      if sudo fuser "$lock" >/dev/null 2>&1; then
        busy=1
        break
      fi
    done
    (( busy == 0 )) && break
    warn "Waiting for other package manager activity to finish..."
    sleep 3
  done
}

refresh_apt(){
  wait_for_apt
  sudo apt-get update
  APT_UPDATED=1
}

pkg_installed(){
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

pkg_available(){
  apt-cache show "$1" >/dev/null 2>&1
}

install_if_missing(){
  local miss=() unavailable=() p
  (( APT_UPDATED == 1 )) || refresh_apt
  for p in "$@"; do
    pkg_installed "$p" && continue
    if pkg_available "$p"; then
      miss+=("$p")
    else
      unavailable+=("$p")
    fi
  done

  if (( ${#unavailable[@]} > 0 )); then
    warn "Skipping unavailable package(s): ${unavailable[*]}"
  fi

  (( ${#miss[@]} == 0 )) && return 0
  info "Installing: ${miss[*]}"
  wait_for_apt
  sudo apt-get install -y "${miss[@]}"
}

remove_if_installed(){
  local rmv=() p
  for p in "$@"; do
    pkg_installed "$p" && rmv+=("$p")
  done
  (( ${#rmv[@]} == 0 )) && return 0
  info "Removing: ${rmv[*]}"
  wait_for_apt
  sudo apt-get remove -y "${rmv[@]}"
}

apt_cleanup(){
  wait_for_apt
  sudo apt-get autoremove -y
  sudo apt-get autoclean -y
}

fix_ubuntu_packages(){
  wait_for_apt
  sudo dpkg --configure -a || true
  sudo apt-get install -f -y || true
}

preseed_mscorefonts_eula(){
  command_exists debconf-set-selections || return 0
  printf '%s\n' \
    'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' \
    'ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note' | \
    sudo debconf-set-selections
}

ensure_base_apt_tools(){
  install_if_missing software-properties-common ca-certificates curl wget gpg gpg-agent lsb-release apt-transport-https debconf-utils
}

add_apt_component(){
  local component="$1"
  ensure_base_apt_tools
  sudo add-apt-repository -y "$component"
}

ensure_directory(){
  sudo install -d -m 0755 "$1"
}

# -----------------------------
# THIRD-PARTY REPOSITORIES / INSTALLERS
# -----------------------------
setup_vscode_repo(){
  ensure_base_apt_tools
  ensure_directory /usr/share/keyrings
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /usr/share/keyrings/microsoft.gpg >/dev/null
  sudo chmod 0644 /usr/share/keyrings/microsoft.gpg
  sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<EOFVS
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64 arm64 armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOFVS
  refresh_apt
}

setup_vscodium_repo(){
  ensure_base_apt_tools
  ensure_directory /usr/share/keyrings
  wget -qO- https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg | \
    gpg --dearmor | sudo tee /usr/share/keyrings/vscodium-archive-keyring.gpg >/dev/null
  sudo chmod 0644 /usr/share/keyrings/vscodium-archive-keyring.gpg

  if dpkg --compare-versions "$UBUNTU_VERSION_ID" ge "24.04"; then
    sudo tee /etc/apt/sources.list.d/vscodium.sources >/dev/null <<EOFVSC
Types: deb
URIs: https://download.vscodium.com/debs
Suites: vscodium
Components: main
Architectures: amd64 arm64
Signed-By: /usr/share/keyrings/vscodium-archive-keyring.gpg
EOFVSC
  else
    echo 'deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg] https://download.vscodium.com/debs vscodium main' | \
      sudo tee /etc/apt/sources.list.d/vscodium.list >/dev/null
  fi
  refresh_apt
}

setup_docker_repo(){
  ensure_base_apt_tools
  ensure_directory /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOFDK
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOFDK
  refresh_apt
}

install_chrome_from_deb(){
  local arch tmpdeb
  arch="$(dpkg --print-architecture)"
  if [[ "$arch" != "amd64" ]]; then
    warn "Google Chrome is only offered as an official .deb for amd64. Skipping."
    return 0
  fi

  if pkg_installed google-chrome-stable; then
    info "Google Chrome is already installed"
    return 0
  fi

  ensure_base_apt_tools
  tmpdeb="/tmp/google-chrome-stable_current_amd64.deb"
  wget -O "$tmpdeb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  wait_for_apt
  sudo apt-get install -y "$tmpdeb"
}

install_tailscale(){
  ensure_base_apt_tools
  curl -fsSL https://tailscale.com/install.sh | sh
}

install_cockpit_from_backports_or_main(){
  refresh_apt
  if apt-cache policy | grep -q "${UBUNTU_CODENAME}-backports"; then
    wait_for_apt
    sudo apt-get install -y -t "${UBUNTU_CODENAME}-backports" cockpit cockpit-networkmanager cockpit-packagekit cockpit-storaged || \
      sudo apt-get install -y -t "${UBUNTU_CODENAME}-backports" cockpit
  else
    install_if_missing cockpit cockpit-networkmanager cockpit-packagekit cockpit-storaged
  fi
}

configure_ufw(){
  install_if_missing ufw
  sudo ufw default deny incoming || true
  sudo ufw default allow outgoing || true
  sudo ufw allow OpenSSH || true
  sudo ufw --force enable || true
}

ensure_flathub(){
  install_if_missing flatpak
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
}

# -----------------------------
# GRUB HELPERS
# -----------------------------
set_grub_cmdline_append(){
  local args=("$@") current new arg escaped
  backup_file /etc/default/grub
  current="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="?(.*)"?$/\1/' || true)"
  new="$current"
  for arg in "${args[@]}"; do
    [[ " $new " == *" $arg "* ]] || new="${new:+$new }$arg"
  done
  escaped="$(printf '%s' "$new" | sed 's/[\\&/]/\\&/g')"
  if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
    sudo sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"$escaped\"/" /etc/default/grub
  else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"" | sudo tee -a /etc/default/grub >/dev/null
  fi
  sudo update-grub
}

# -----------------------------
# SECONDARY DISK SETUP
# -----------------------------
setup_secondary_disk(){
  info "Starting Disk Setup..."
  install_if_missing ntfs-3g exfatprogs dislocker fuse3

  local USERNAME USERID GROUPID
  USERNAME="${SUDO_USER:-$(logname 2>/dev/null || true)}"
  [[ -z "$USERNAME" ]] && USERNAME="$USER"
  USERID="$(id -u "$USERNAME")"
  GROUPID="$(id -g "$USERNAME")"

  echo "=== Available Disks ==="
  mapfile -t DISKS < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')
  if (( ${#DISKS[@]} == 0 )); then
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
    if [[ "$DISK_NUMBER" =~ ^[0-9]+$ ]] && (( DISK_NUMBER >= 1 && DISK_NUMBER <= ${#DISKS[@]} )); then
      SELECTED_DISK="${DISKS[$((DISK_NUMBER-1))]}"
      break
    fi
    warn "Invalid selection. Try again."
  done

  echo "=== Partitions on $SELECTED_DISK ==="
  mapfile -t PART_INFO < <(
    lsblk -nrpo NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE "$SELECTED_DISK" |
    awk '$5=="part"{print $1 "|" $2 "|" $3 "|" $4}'
  )

  if (( ${#PART_INFO[@]} == 0 )); then
    warn "No partitions found on $SELECTED_DISK."

    if ! ask_user "Do you want to create a new partition on $SELECTED_DISK? THIS WILL ERASE DATA"; then
      warn "Partition creation skipped."
      return 1
    fi

    echo "Choose filesystem for the new partition:"
    select FS_CHOICE in ext4 xfs btrfs ntfs exfat; do
      case "$FS_CHOICE" in
        ext4|xfs|btrfs|ntfs|exfat) break ;;
        *) echo "Invalid choice" ;;
      esac
    done

    info "Creating GPT partition table on $SELECTED_DISK"
    sudo parted -s "$SELECTED_DISK" mklabel gpt
    sudo parted -s "$SELECTED_DISK" mkpart primary 0% 100%

    info "Informing kernel of partition changes"
    sudo partprobe "$SELECTED_DISK"
    sleep 2

    PARTITION="${SELECTED_DISK}1"

    info "Formatting $PARTITION as $FS_CHOICE"
    case "$FS_CHOICE" in
      ext4) sudo mkfs.ext4 -F "$PARTITION" ;;
      xfs) sudo mkfs.xfs -f "$PARTITION" ;;
      btrfs) sudo mkfs.btrfs -f "$PARTITION" ;;
      ntfs) sudo mkfs.ntfs -f "$PARTITION" ;;
      exfat) sudo mkfs.exfat "$PARTITION" ;;
    esac

    PART_INFO=("$PARTITION|$(lsblk -dnbo SIZE "$PARTITION")|$FS_CHOICE|")
  fi

  i=1
  local LINE PNAME PSIZE PFSTYPE PMOUNT
  for LINE in "${PART_INFO[@]}"; do
    IFS='|' read -r PNAME PSIZE PFSTYPE PMOUNT <<< "$LINE"
    [[ -z "$PFSTYPE" ]] && PFSTYPE="unknown"
    [[ -z "$PMOUNT" ]] && PMOUNT="-"
    echo "[$i] $PNAME ($PSIZE) fstype=$PFSTYPE mount=$PMOUNT"
    i=$((i+1))
  done

  local PART_NUMBER PARTITION
  while true; do
    read -rp "Select partition number: " PART_NUMBER
    if [[ "$PART_NUMBER" =~ ^[0-9]+$ ]] && (( PART_NUMBER >= 1 && PART_NUMBER <= ${#PART_INFO[@]} )); then
      IFS='|' read -r PARTITION _ <<< "${PART_INFO[$((PART_NUMBER-1))]}"
      break
    fi
    warn "Invalid selection. Try again."
  done

  if findmnt -rn --source "$PARTITION" >/dev/null 2>&1; then
    warn "Partition already mounted."
    return 0
  fi

  if sudo blkid "$PARTITION" | grep -iq bitlocker; then
    warn "BitLocker detected!"
    sudo mkdir -p /mnt/bitlocker /mnt/data
    read -rsp "Enter BitLocker password: " BL_PASS
    echo
    sudo dislocker -V "$PARTITION" -u"$BL_PASS" -- /mnt/bitlocker
    sudo mount -o loop,uid="$USERID",gid="$GROUPID" /mnt/bitlocker/dislocker-file /mnt/data
    info "Mounted BitLocker volume at /mnt/data"
    return 0
  fi

  local FS_TYPE UUID MOUNT_NAME MOUNT_DIR OPTS FSTAB_TYPE
  FS_TYPE="$(blkid -s TYPE -o value "$PARTITION")"

  read -rp "Enter mount folder name (e.g. storage): " MOUNT_NAME
  MOUNT_NAME="$(echo "$MOUNT_NAME" | tr -cd '[:alnum:]_.-')"
  MOUNT_DIR="/mnt/$MOUNT_NAME"
  sudo mkdir -p "$MOUNT_DIR"

  UUID="$(blkid -s UUID -o value "$PARTITION")"

  case "$FS_TYPE" in
    ntfs)
      if grep -qw ntfs3 /proc/filesystems; then
        FSTAB_TYPE="ntfs3"
      else
        FSTAB_TYPE="ntfs-3g"
      fi
      OPTS="defaults,uid=$USERID,gid=$GROUPID,umask=000"
      ;;
    vfat|fat|exfat)
      FSTAB_TYPE="$FS_TYPE"
      OPTS="defaults,uid=$USERID,gid=$GROUPID,umask=000"
      ;;
    *)
      FSTAB_TYPE="$FS_TYPE"
      OPTS="defaults"
      ;;
  esac

  if ! sudo grep -q "UUID=$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNT_DIR $FSTAB_TYPE $OPTS 0 2" | sudo tee -a /etc/fstab >/dev/null
  fi

  sudo mount -a
  info "Disk mounted at $MOUNT_DIR"
}

# -----------------------------
# START
# -----------------------------
require_ubuntu
clear
info "Ubuntu FULL Interactive Workstation Setup"
info "Detected: $(. /etc/os-release && echo "$PRETTY_NAME")"
pause
sudo -v
while true; do sudo -v; sleep 60; done & SUDO_PID=$!
trap 'kill "$SUDO_PID" 2>/dev/null || true' EXIT

# -----------------------------
# UBUNTU BASE SYSTEM
# -----------------------------
if ask_user "Prepare Ubuntu base system (APT tools, repo components, update/upgrade)?"; then
  ensure_base_apt_tools
  add_apt_component restricted
  add_apt_component universe
  add_apt_component multiverse
  refresh_apt
  wait_for_apt
  sudo apt-get upgrade -y
fi

if ask_user "Run Ubuntu package repair tools now?"; then
  fix_ubuntu_packages
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

# -----------------------------
# REMOVE DEFAULT APPS
# -----------------------------
UNWANTED=(rhythmbox totem cheese aisleriot gnome-mahjongg gnome-mines gnome-sudoku)
if ask_user "Remove preinstalled Ubuntu apps (${UNWANTED[*]})?"; then
  remove_if_installed "${UNWANTED[@]}"
fi

# -----------------------------
# SYSTEM UPDATE
# -----------------------------
if ask_user "Run full system update (apt upgrade)?"; then
  refresh_apt
  wait_for_apt
  sudo apt-get upgrade -y
fi

# -----------------------------
# PACKAGE GROUPS
# -----------------------------
CORE_PACKAGES=(
  openssl curl wget fontconfig xfonts-utils ca-certificates gpg gpg-agent lsb-release
  software-properties-common apt-transport-https command-not-found ubuntu-drivers-common
)
SECURITY_PACKAGES=(
  unattended-upgrades fail2ban rkhunter lynis apparmor apparmor-utils
)
TWEAK_PACKAGES=(
  gnome-color-manager zram-tools
)
PRODUCTIVITY_APPS=(
  filezilla flatpak dconf-editor gnome-software-plugin-flatpak
)

ask_user "Install CORE packages?" && install_if_missing "${CORE_PACKAGES[@]}"
ask_user "Install SECURITY packages?" && install_if_missing "${SECURITY_PACKAGES[@]}"
ask_user "Install TWEAK packages?" && install_if_missing "${TWEAK_PACKAGES[@]}"
ask_user "Install PRODUCTIVITY apps?" && install_if_missing "${PRODUCTIVITY_APPS[@]}"

# -----------------------------
# UBUNTU / DESKTOP FIXES
# -----------------------------
if ask_user "Enable Flatpak + Flathub support?"; then
  install_if_missing flatpak gnome-software-plugin-flatpak
  ensure_flathub
fi

if ask_user "Configure UFW firewall with sane defaults?"; then
  configure_ufw
fi

if ask_user "Install media codecs and extras (ubuntu-restricted-extras, ffmpeg)?"; then
  preseed_mscorefonts_eula
  install_if_missing ubuntu-restricted-extras ffmpeg libavcodec-extra
fi

if ask_user "Install filesystem support tools (ntfs-3g, exfatprogs, dislocker)?"; then
  install_if_missing ntfs-3g exfatprogs dislocker fuse3
fi

if ask_user "Check AppArmor status / install its tools?"; then
  install_if_missing apparmor apparmor-utils
  command_exists aa-status && sudo aa-status || warn "AppArmor tools are not available"
fi

# -----------------------------
# SPEED & PERFORMANCE OPTIMIZATIONS
# -----------------------------
if ask_user "Apply system-wide speed & performance optimizations?"; then
  info "Applying speed and performance optimizations..."

  sudo mkdir -p /etc/systemd/system.conf.d
  sudo tee /etc/systemd/system.conf.d/timeout.conf >/dev/null <<'EOFTIMEOUT'
[Manager]
DefaultTimeoutStartSec=10s
DefaultTimeoutStopSec=10s
EOFTIMEOUT

  sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null <<'EOFSWAP'
vm.swappiness=10
EOFSWAP

  sudo tee /etc/sysctl.d/99-inotify.conf >/dev/null <<'EOFINO'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
EOFINO

  sudo sysctl --system

  systemctl --user mask \
    tracker-miner-fs-3.service \
    tracker-extract-3.service \
    tracker-miner-rss-3.service 2>/dev/null || true

  sudo systemctl disable --now packagekit.service packagekit.socket 2>/dev/null || true

  mkdir -p ~/.config/autostart
  if [[ -f /etc/xdg/autostart/org.gnome.Software.desktop ]]; then
    cp /etc/xdg/autostart/org.gnome.Software.desktop ~/.config/autostart/
    if grep -q '^X-GNOME-Autostart-enabled=' ~/.config/autostart/org.gnome.Software.desktop; then
      sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' ~/.config/autostart/org.gnome.Software.desktop
    else
      echo 'X-GNOME-Autostart-enabled=false' >> ~/.config/autostart/org.gnome.Software.desktop
    fi
  fi

  safe_gsettings_set org.gnome.desktop.interface enable-animations false
  safe_gsettings_set org.gnome.desktop.interface clock-show-seconds true
  safe_gsettings_set org.gnome.desktop.interface show-battery-percentage true

  if systemctl list-unit-files | grep -q '^zramswap.service'; then
    sudo systemctl enable --now zramswap.service 2>/dev/null || true
  fi

  sudo mkdir -p /var/log/journal
  sudo systemctl restart systemd-journald

  info "Speed & performance optimizations applied"
fi

# -----------------------------
# SNAP / BTRFS / APPARMOR INFO
# -----------------------------
if ask_user "Enable snapd support?"; then
  install_if_missing snapd
  sudo systemctl enable --now snapd.socket
  sudo ln -sf /var/lib/snapd/snap /snap
fi

if ask_user "Remove unwanted Snap apps?"; then
  if command_exists snap; then
    snap list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r s; do
      case "$s" in
        firefox|snap-store|bare|core|core18|core20|core22|core24|snapd)
          ;;
        *)
          sudo snap remove "$s" || true
          ;;
      esac
    done
  else
    warn "snap is not installed"
  fi
fi

if mount | grep -q ' on / type btrfs'; then
  if ask_user "Enable Snapper for Btrfs root?"; then
    install_if_missing snapper
    sudo snapper -c root create-config / || true
    sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
  fi
fi

command_exists aa-status && sudo aa-status >/dev/null 2>&1 || warn "AppArmor status unavailable"

# -----------------------------
# SOFTWARE BLOCKS
# -----------------------------
if ask_user "Install Tailscale?"; then
  install_tailscale
  ask_user "Enable tailscaled service?" && sudo systemctl enable --now tailscaled
  if ask_user "Try installing Trayscale if available in APT?"; then
    install_if_missing trayscale
  fi
fi

if ask_user "Install VS Code + VSCodium?"; then
  setup_vscode_repo
  install_if_missing code

  if [[ "$(dpkg --print-architecture)" =~ ^(amd64|arm64)$ ]]; then
    setup_vscodium_repo
    install_if_missing codium
  else
    warn "VSCodium repo only targets amd64/arm64. Skipping on $(dpkg --print-architecture)."
  fi
fi

if ask_user "Install Google Chrome?"; then
  install_chrome_from_deb
fi

ask_user "Install Git & Gitg?" && install_if_missing git gitg

if ask_user "Install Docker Engine?"; then
  # Per Docker docs, remove conflicting distro packages first.
  remove_if_installed docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc
  setup_docker_repo
  install_if_missing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ask_user "Enable Docker service?" && sudo systemctl enable --now docker
  sudo getent group docker >/dev/null || sudo groupadd docker
  sudo usermod -aG docker "${SUDO_USER:-$USER}"

  if ask_user "Install Whaler (Flatpak)?"; then
    ensure_flathub
    flatpak install -y flathub com.github.sdv43.whaler || true
  fi
fi

if ask_user "Install Microsoft Core Fonts (ttf-mscorefonts-installer)?"; then
  preseed_mscorefonts_eula
  install_if_missing ttf-mscorefonts-installer cabextract
  sudo fc-cache -rv
fi

if ask_user "Install LibreOffice (with Greek localization if available)?"; then
  install_if_missing libreoffice libreoffice-l10n-el myspell-el hyphen-el hunspell-el
fi

ask_user "Install GIMP & Inkscape?" && install_if_missing gimp inkscape

if ask_user "Install Cockpit?"; then
  install_cockpit_from_backports_or_main
  sudo systemctl enable --now cockpit.socket
  if command_exists ufw; then
    sudo ufw allow 9090/tcp || true
  fi
fi

# -----------------------------
# GNOME TWEAKS / UI
# -----------------------------
if ask_user "Apply GNOME UI tweaks?"; then
  install_if_missing gnome-tweaks gnome-shell-extensions gnome-shell-extension-prefs gnome-browser-connector gnome-usage
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

# -----------------------------
# GNOME EXTENSIONS
# -----------------------------
if ask_user "Install GNOME Shell extensions?"; then
  install_if_missing jq unzip gnome-shell-extensions gnome-shell-extension-prefs

  EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
  mkdir -p "$EXT_DIR"

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

  RAW_VERSION="$(gnome-shell --version | awk '{print $3}')"
  MAJOR_VERSION="${RAW_VERSION%%.*}"

  if (( MAJOR_VERSION >= 49 )); then
    SHELL_VERSION=48
  else
    SHELL_VERSION="$MAJOR_VERSION"
  fi

  info "Detected GNOME $RAW_VERSION → querying extensions as GNOME $SHELL_VERSION"

  for ID in "${!EXT[@]}"; do
    UUID="${EXT[$ID]}"
    INFO_JSON="$(curl -fsSL "https://extensions.gnome.org/extension-info/?pk=$ID&shell_version=$SHELL_VERSION" || true)"
    URL="$(jq -r '.download_url // empty' <<<"$INFO_JSON")"

    if [[ -z "$URL" ]]; then
      warn "Skipping $UUID (no compatible release reported)"
      continue
    fi

    ZIP="/tmp/$UUID.zip"
    curl -fsSL -o "$ZIP" "https://extensions.gnome.org$URL"
    unzip -oq "$ZIP" -d "$EXT_DIR/$UUID"
    rm -f "$ZIP"

    if [[ -d "$EXT_DIR/$UUID/schemas" ]]; then
      glib-compile-schemas "$EXT_DIR/$UUID/schemas"
    fi

    gnome-extensions enable "$UUID" || warn "Could not enable $UUID (login/restart may be required)"
  done
fi

# -----------------------------
# GNOME TEMPLATES
# -----------------------------
if ask_user "Add GNOME Templates (Text, Markdown, HTML)?"; then
  TEMPLATES_DIR="$HOME/Templates"
  info "Creating GNOME Templates in $TEMPLATES_DIR"
  mkdir -p "$TEMPLATES_DIR"

  touch "$TEMPLATES_DIR/Text Document.txt"

  cat <<'EOFMARKDOWN' > "$TEMPLATES_DIR/Markdown.md"
# Title

Write here...
EOFMARKDOWN

  cat <<'EOFHTML' > "$TEMPLATES_DIR/HTML Document.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Document</title>
</head>
<body>

</body>
</html>
EOFHTML

  nautilus -q || true
  info "GNOME New Document templates added"
fi

# -----------------------------
# FLATPAK APPS
# -----------------------------
if ask_user "Install Flatpak user applications?"; then
  ensure_flathub

  APPS=(
    org.signal.Signal
    io.missioncenter.MissionCenter
    io.gitlab.news_flash.NewsFlash
    com.mattjakeman.ExtensionManager
    it.mijorus.gearlever
    org.gustavoperedo.FontDownloader
    io.github.flattool.Ignition
  )

  for a in "${APPS[@]}"; do
    flatpak install -y --noninteractive flathub "$a" || true
  done
fi

# -----------------------------
# CLI / SECURITY
# -----------------------------
ask_user "Install CLI tools (fzf, bat, ripgrep)?" && install_if_missing fzf bat ripgrep
if ask_user "Install USBGuard?"; then
  install_if_missing usbguard
  sudo systemctl enable --now usbguard
fi

# -----------------------------
# DEV OPTIONS
# -----------------------------
if ask_user "Increase file watcher limits (dev-friendly)?"; then
  sudo tee /etc/sysctl.d/99-dev.conf >/dev/null <<'EOFDEV'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
EOFDEV
  sudo sysctl --system
fi

if ask_user "Improve Bash defaults (history, colors, completion)?"; then
  grep -q "HISTSIZE=10000" ~/.bashrc || cat >> ~/.bashrc <<'EOFBASH'
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'
EOFBASH
fi

# -----------------------------
# FONTS (EXTRA + NERD + FONTCONFIG)
# -----------------------------
if ask_user "Install extra fonts (Noto, Roboto, JetBrains Mono, etc.)?"; then
  install_if_missing \
    fonts-firacode fonts-jetbrains-mono fonts-roboto fonts-noto-core fonts-noto-mono \
    fonts-liberation2 fonts-inter
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
  cat > ~/.config/fontconfig/fonts.conf <<'EOFFONTS'
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
EOFFONTS
fi

# -----------------------------
# ADVANCED: GRUB / KERNEL / FIRMWARE
# -----------------------------
if ask_user "Advanced: GRUB remember last entry?"; then
  backup_file /etc/default/grub
  sudo sed -i \
    -e 's/^#\?GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \
    -e 's/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' \
    -e 's/^#\?GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' \
    -e 's/^#\?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
  grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub || echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub >/dev/null
  sudo update-grub
fi

if ask_user "Advanced: keep only 2 kernels?"; then
  install_if_missing byobu
  if command_exists purge-old-kernels; then
    ask_user "Remove older kernels now (keep 2 newest)?" && sudo purge-old-kernels -qy --keep 2
  else
    warn "purge-old-kernels is unavailable even after installing byobu"
  fi
fi

if ask_user "Advanced: apply AMD kernel args?"; then
  set_grub_cmdline_append amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
  grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || true
fi

if ask_user "Check firmware updates (fwupd)?"; then
  install_if_missing fwupd
  sudo fwupdmgr refresh
  sudo fwupdmgr get-updates
  ask_user "Apply firmware updates?" && sudo fwupdmgr update
fi

# -----------------------------
# EXTRA DISKS (BITLOCKER & NVMe SUPPORT)
# -----------------------------
if ask_user "Setup a second internal disk (Mount/BitLocker)?"; then
  setup_secondary_disk
fi

# -----------------------------
# FINAL CLEANUP / REBOOT
# -----------------------------
if ask_user "Run apt cleanup (autoremove + autoclean)?"; then
  apt_cleanup
fi

ask_user "Reboot now?" && sudo reboot || info "Reboot skipped"
