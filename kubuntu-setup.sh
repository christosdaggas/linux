#!/usr/bin/env bash
# ============================================================
# Kubuntu 26.04+ Interactive Workstation Setup
# Optimized for Kubuntu 26.04 LTS / Plasma 6 / Wayland
#
# Run:
#   cd ~/Downloads
#   chmod +x Kubuntu-Setup-26.sh
#   ./Kubuntu-Setup-26.sh
# ============================================================

set -Eeuo pipefail
shopt -s extglob

# -------------------- UI --------------------
RESET="\e[0m"
INFO="\e[36m"
WARN="\e[33m"
ERROR="\e[31m"
BOLD="\e[1m"

info()  { echo -e "${INFO}[INFO]${RESET} $*"; }
warn()  { echo -e "${WARN}[WARN]${RESET} $*"; }
error() { echo -e "${ERROR}[ERROR]${RESET} $*"; }
title() { echo; echo -e "${BOLD}==== $* ====${RESET}"; }

on_error() {
  local line="$1" cmd="$2"
  warn "Non-fatal command error at line ${line}: ${cmd}"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# -------------------- Defaults --------------------
DEFAULT_LANG="en_US.UTF-8"
XKB_LAYOUTS="us,gr"
XKB_OPTIONS="grp:alt_shift_toggle"

COLOR_SCHEME="BreezeDark"
ICON_THEME="breeze-dark"
UI_FONT="Noto Sans,10,-1,5,50,0,0,0,0,0"
MONO_FONT="JetBrains Mono,10,-1,5,50,0,0,0,0,0"

GTK_THEME_NAME="Breeze-Dark"
GTK_ICON_THEME="breeze"
GTK_FONT_NAME="Noto Sans 10"
GTK_CURSOR_THEME="breeze_cursors"

APT_UPDATED=0
CURRENT_CHOICES=""

# -------------------- Generic helpers --------------------
real_user() {
  printf '%s\n' "${SUDO_USER:-${USER:-$(id -un)}}"
}

real_home() {
  getent passwd "$(real_user)" | cut -d: -f6
}

ask_user() {
  local prompt="$1" reply
  while true; do
    read -rp "$(echo -e "${BOLD}${prompt} [y/n]: ${RESET}")" reply
    case "$reply" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sudo cp -a "$file" "$file.bak.$(date +%F_%H-%M-%S)"
}

need_sudo() {
  info "Please enter your sudo password to start the setup:"
  sudo -v || {
    error "sudo is not available or authentication failed."
    exit 1
  }

  while true; do
    sudo -n true
    sleep 60
  done 2>/dev/null &

  SUDO_PID=$!
  trap 'kill "${SUDO_PID:-0}" 2>/dev/null || true' EXIT
}

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    error "/etc/os-release not found. Cannot verify distribution."
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *ubuntu* ]]; then
    error "This script targets Kubuntu / Ubuntu-based systems."
    exit 1
  fi

  if [[ "${VERSION_ID:-}" != "26.04" ]]; then
    warn "This script is tuned for Kubuntu/Ubuntu 26.04."
    warn "Detected: ${PRETTY_NAME:-unknown}"
    ask_user "Continue anyway?" || exit 1
  fi

  if ! command -v plasmashell >/dev/null 2>&1 && ! dpkg -s kubuntu-desktop >/dev/null 2>&1; then
    warn "KDE Plasma/Kubuntu desktop was not clearly detected."
    ask_user "Continue on this Ubuntu-based system anyway?" || exit 1
  fi
}

ensure_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    info "Installing whiptail..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail
    APT_UPDATED=1
  fi
}

refresh_apt() {
  sudo DEBIAN_FRONTEND=noninteractive apt-get update
  APT_UPDATED=1
}

mark_apt_stale() {
  APT_UPDATED=0
}

apt_has_pkg() {
  local pkg="$1"
  apt-cache show "$pkg" >/dev/null 2>&1
}

apt_is_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
}

apt_install_existing() {
  local pkg
  local to_install=()
  local unavailable=()

  (( APT_UPDATED == 0 )) && refresh_apt

  for pkg in "$@"; do
    if apt_is_installed "$pkg"; then
      continue
    elif apt_has_pkg "$pkg"; then
      to_install+=("$pkg")
    else
      unavailable+=("$pkg")
    fi
  done

  for pkg in "${unavailable[@]}"; do
    warn "Package not available on this release/repository set: $pkg"
  done

  (( ${#to_install[@]} == 0 )) && {
    info "Nothing new to install in this step."
    return 0
  }

  info "Installing: ${to_install[*]}"

  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}"; then
    warn "Bulk install failed. Retrying one package at a time."
    for pkg in "${to_install[@]}"; do
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || \
        warn "Skipped unavailable or failed package: $pkg"
    done
  fi
}

apt_remove_if_installed() {
  local pkg
  local installed=()

  for pkg in "$@"; do
    apt_is_installed "$pkg" && installed+=("$pkg")
  done

  (( ${#installed[@]} == 0 )) && {
    info "None of the selected packages are installed."
    return 0
  }

  info "Removing: ${installed[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y "${installed[@]}" || \
    warn "Some packages could not be removed."
}

download_to() {
  local url="$1"
  local out="$2"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$out" "$url"
}

is_sel() {
  local tag="$1"
  [[ " $CURRENT_CHOICES " == *"\"$tag\""* || " $CURRENT_CHOICES " == *" $tag "* ]]
}

run_step() {
  local label="$1"
  shift

  title "$label"

  set +e
  "$@"
  local rc=$?
  set -e

  if (( rc != 0 )); then
    warn "'$label' failed with code $rc — continuing."
  fi

  return 0
}

# -------------------- System sections --------------------
sys_enable_repos() {
  apt_install_existing software-properties-common

  sudo add-apt-repository -y restricted || true
  sudo add-apt-repository -y universe || true
  sudo add-apt-repository -y multiverse || true

  mark_apt_stale
  refresh_apt
}

sys_hostname() {
  local new_hostname
  read -rp "Enter new hostname: " new_hostname
  new_hostname="${new_hostname// /}"

  [[ -z "$new_hostname" ]] && {
    warn "Hostname is empty; skipping."
    return 0
  }

  sudo hostnamectl set-hostname "$new_hostname"

  backup_file /etc/hosts

  if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sudo sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${new_hostname}/" /etc/hosts
  else
    echo -e "127.0.1.1\t${new_hostname}" | sudo tee -a /etc/hosts >/dev/null
  fi
}

sys_update() {
  refresh_apt
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y autoremove
}

sys_fwupd() {
  apt_install_existing fwupd

  sudo systemctl start fwupd.service 2>/dev/null || true

  info "Detected fwupd devices:"
  fwupdmgr get-devices || warn "fwupd could not list devices. Firmware may not be supported on this hardware."

  info "Configured fwupd remotes:"
  fwupdmgr get-remotes || true

  if ask_user "Enable LVFS firmware remote if available?"; then
    sudo fwupdmgr enable-remote lvfs || warn "Could not enable LVFS remote; it may already be enabled or unavailable."
  fi

  sudo fwupdmgr refresh --force || {
    warn "Firmware metadata refresh failed. This is not fatal."
    return 0
  }

  fwupdmgr get-updates || {
    warn "No firmware updates found, or hardware is unsupported by LVFS."
    return 0
  }

  if ask_user "Apply available firmware updates now?"; then
    sudo fwupdmgr update || warn "Firmware update failed or was cancelled."
  fi
}

sys_base_utils() {
  apt_install_existing \
    ca-certificates curl wget gnupg gpg lsb-release pciutils \
    software-properties-common apt-transport-https \
    x11-xserver-utils xdg-user-dirs xdg-utils \
    flatpak plasma-discover-backend-flatpak

  sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
}

sys_greek() {
  apt_install_existing \
    locales language-pack-el language-pack-gnome-el \
    fonts-noto-core fonts-noto-mono \
    hunspell-el hyphen-el mythes-el

  sudo locale-gen en_US.UTF-8 el_GR.UTF-8 || true
  sudo update-locale LANG="$DEFAULT_LANG" || true
  sudo localectl set-locale "LANG=$DEFAULT_LANG" || true

  # Useful for XKB config, even though Kubuntu 26.04 defaults to Plasma Wayland.
  sudo localectl set-x11-keymap "us,gr" "" "" "$XKB_OPTIONS" || true

  mkdir -p "$HOME/.config"

  cat > "$HOME/.config/kxkbrc" <<EOF_KXKB
[Layout]
LayoutList=$XKB_LAYOUTS
Options=$XKB_OPTIONS
ResetOldOptions=true
SwitchMode=Global
Use=true
EOF_KXKB
}

sys_fonts() {
  apt_install_existing \
    fontconfig cabextract \
    fonts-noto fonts-noto-core fonts-noto-extra fonts-noto-color-emoji fonts-noto-mono \
    fonts-liberation fonts-roboto fonts-firacode fonts-inter fonts-jetbrains-mono

  fc-cache -f >/dev/null 2>&1 || true
}

microsoft_fonts_install() {
  warn "Microsoft Core Fonts are proprietary and require accepting Microsoft's EULA."
  ask_user "Accept the Microsoft Core Fonts EULA and install them?" || {
    warn "Microsoft Core Fonts installation skipped."
    return 0
  }

  apt_install_existing software-properties-common fontconfig cabextract

  # ttf-mscorefonts-installer is in Ubuntu/Kubuntu multiverse.
  sudo add-apt-repository -y multiverse || true
  mark_apt_stale
  refresh_apt

  if ! apt_has_pkg ttf-mscorefonts-installer; then
    warn "ttf-mscorefonts-installer was not found. Make sure multiverse is enabled."
    return 0
  fi

  # Pre-accept the EULA for noninteractive installation.
  echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | sudo debconf-set-selections
  echo "ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note" | sudo debconf-set-selections

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall ttf-mscorefonts-installer || {
    warn "Microsoft Core Fonts installer failed. It downloads fonts during post-install; network/source availability can affect this."
    return 0
  }

  sudo fc-cache -f >/dev/null 2>&1 || true

  info "Checking Microsoft Core Fonts through fontconfig:"
  fc-match -f 'Arial -> %{file}\n' Arial || true
  fc-match -f 'Times New Roman -> %{file}\n' "Times New Roman" || true
  fc-match -f 'Verdana -> %{file}\n' Verdana || true

  if fc-match -f '%{file}\n' Arial | grep -qi 'msttcorefonts'; then
    info "Microsoft Core Fonts appear to be installed."
  else
    warn "Arial did not resolve to msttcorefonts. The installer may not have completed its font download."
    warn "Try: sudo apt-get install --reinstall ttf-mscorefonts-installer"
  fi
}

install_meslo_nerd_fonts() {
  apt_install_existing curl fontconfig

  local dest base font encoded failed=0
  dest="$HOME/.local/share/fonts/MesloLGS-NF"
  base="https://github.com/romkatv/powerlevel10k-media/raw/master"

  mkdir -p "$dest"

  local fonts=(
    "MesloLGS NF Regular.ttf"
    "MesloLGS NF Bold.ttf"
    "MesloLGS NF Italic.ttf"
    "MesloLGS NF Bold Italic.ttf"
  )

  for font in "${fonts[@]}"; do
    encoded="${font// /%20}"
    info "Downloading $font"
    if ! download_to "$base/$encoded" "$dest/$font"; then
      warn "Failed to download $font"
      failed=1
    fi
  done

  fc-cache -f "$dest" || true

  (( failed == 0 )) && \
    info "MesloLGS Nerd Fonts installed in $dest" || \
    warn "Some MesloLGS font files failed to download."
}

sys_fontconfig() {
  mkdir -p "$HOME/.config/fontconfig"

  cat > "$HOME/.config/fontconfig/fonts.conf" <<'EOF_FONTCONFIG'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
</fontconfig>
EOF_FONTCONFIG

  fc-cache -f >/dev/null 2>&1 || true
}

sys_security() {
  apt_install_existing \
    ufw unattended-upgrades apparmor-profiles apparmor-utils \
    lynis rkhunter apt-listchanges fail2ban

  sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true

  sudo ufw default deny incoming || true
  sudo ufw default allow outgoing || true

  if dpkg -s openssh-server >/dev/null 2>&1; then
    sudo ufw allow OpenSSH || true
    sudo systemctl enable --now fail2ban || warn "fail2ban failed to start. Check: journalctl -u fail2ban"
  else
    warn "openssh-server is not installed; skipping OpenSSH/Fail2Ban activation."
  fi

  sudo ufw --force enable || true
}

sys_perf() {
  info "Applying conservative performance/developer-friendly settings."

  backup_file /etc/sysctl.d/99-swappiness.conf
  echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null

  sudo tee /etc/sysctl.d/99-inotify.conf >/dev/null <<'EOF_INOTIFY'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=1024
EOF_INOTIFY

  sudo sysctl --system || true

  if apt_has_pkg systemd-zram-generator; then
    apt_install_existing systemd-zram-generator

    sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF_ZRAM'
[zram0]
zram-size = min(ram / 2, 8G)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF_ZRAM

    sudo systemctl daemon-reload || true
    sudo systemctl restart systemd-zram-setup@zram0.service || true

  elif apt_has_pkg zram-tools; then
    apt_install_existing zram-tools
    sudo systemctl enable --now zramswap.service || true
  else
    warn "No zram package found; skipping zram setup."
  fi

  sudo systemctl enable --now fstrim.timer || true

  sudo mkdir -p /var/log/journal
  sudo systemctl restart systemd-journald || true
}

sys_multimedia() {
  apt_install_existing \
    ffmpeg libavcodec-extra \
    gstreamer1.0-libav \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly
}

sys_core_tools() {
  apt_install_existing \
    curl wget jq vim nano htop btop ncdu tree unzip zip tar \
    p7zip-full unrar-free fzf ripgrep fd-find bat \
    git git-lfs bash-completion rsync openssl net-tools \
    dnsutils whois traceroute lsof
}

sys_bash_defaults() {
  local bashrc="$HOME/.bashrc"

  if ! grep -q "KUBUNTU_SETUP_BASH_DEFAULTS" "$bashrc" 2>/dev/null; then
    cat >> "$bashrc" <<'EOF_BASH'

# KUBUNTU_SETUP_BASH_DEFAULTS
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend
bind '"\e[A": history-search-backward'
bind '"\e[B": history-search-forward'

alias ll='ls -alF'
alias la='ls -A'
alias grep='grep --color=auto'

if command -v batcat >/dev/null 2>&1; then
  alias bat='batcat'
fi

if command -v fdfind >/dev/null 2>&1; then
  alias fd='fdfind'
fi
EOF_BASH
  else
    info "Bash defaults already present."
  fi
}

sys_btrfs_snapper() {
  if ! findmnt -no FSTYPE / | grep -qx btrfs; then
    warn "Root filesystem is not Btrfs; skipping Snapper."
    return 0
  fi

  apt_install_existing snapper

  sudo snapper -c root create-config / || true
  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer || true
}

# -------------------- Applications --------------------
cockpit_install() {
  apt_install_existing cockpit cockpit-system
  sudo systemctl enable --now cockpit.socket || true

  if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
    sudo ufw allow 9090/tcp || true
  fi
}

developer_tools_install() {
  apt_install_existing wget curl gnupg apt-transport-https ca-certificates git git-cola meld filezilla

  sudo install -d -m 0755 /etc/apt/keyrings

  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null

  sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOF_VSCODE'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64 arm64 armhf
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF_VSCODE

  mark_apt_stale
  apt_install_existing code
}

docker_install() {
  apt_install_existing ca-certificates curl gnupg lsb-release

  # shellcheck disable=SC1091
  . /etc/os-release

  local codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || true)}"
  local arch
  arch="$(dpkg --print-architecture)"

  if [[ -z "$codename" ]]; then
    warn "Could not detect Ubuntu codename; trying Ubuntu docker.io fallback."
    apt_install_existing docker.io docker-compose-v2
    return 0
  fi

  if ! curl -fsI --retry 2 --connect-timeout 15 "https://download.docker.com/linux/ubuntu/dists/${codename}/Release" >/dev/null 2>&1; then
    warn "Docker CE repository does not appear to support Ubuntu codename '${codename}' yet."
    if ask_user "Install Ubuntu repository Docker fallback instead?"; then
      apt_install_existing docker.io docker-compose-v2
      sudo systemctl enable --now docker || true
      sudo getent group docker >/dev/null || sudo groupadd docker
      sudo usermod -aG docker "$(real_user)"
    fi
    return 0
  fi

  sudo install -m 0755 -d /etc/apt/keyrings

  rm -f /tmp/docker.gpg
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF_DOCKER
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.gpg
EOF_DOCKER

  mark_apt_stale
  refresh_apt

  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    warn "Docker CE install failed."
    if ask_user "Install Ubuntu repository Docker fallback instead?"; then
      apt_install_existing docker.io docker-compose-v2
    fi
  fi

  sudo systemctl enable --now docker || true
  sudo getent group docker >/dev/null || sudo groupadd docker
  sudo usermod -aG docker "$(real_user)"

  warn "Docker group permission requires logout/login or reboot."
}

tailscale_install() {
  apt_install_existing curl ca-certificates gnupg lsb-release

  # shellcheck disable=SC1091
  . /etc/os-release

  local codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || true)}"

  if [[ -z "$codename" ]]; then
    warn "Could not detect Ubuntu codename; falling back to Tailscale install script."
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    sudo install -d -m 0755 /usr/share/keyrings

    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
      | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" \
      | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null

    mark_apt_stale
    apt_install_existing tailscale
  fi

  sudo systemctl enable --now tailscaled || true

  if ask_user "Run 'sudo tailscale up' now for authentication?"; then
    sudo tailscale up || warn "tailscale up failed or was cancelled."
  fi
}

virtualization_install() {
  info "Installing KVM/QEMU/libvirt virtualization stack."

  if grep -Eq '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
    info "CPU virtualization extensions detected."
  else
    warn "CPU virtualization extensions were not detected. Enable Intel VT-x or AMD-V/SVM in firmware if VMs fail."
  fi

  apt_install_existing \
    virt-manager virt-viewer virtinst \
    qemu-kvm qemu-utils \
    libvirt-daemon-system libvirt-clients \
    bridge-utils dnsmasq-base \
    ovmf swtpm swtpm-tools \
    libosinfo-bin osinfo-db-tools \
    guestfs-tools virt-top

  local enabled_modular=0 unit

  for unit in \
    virtqemud.socket \
    virtnetworkd.socket \
    virtstoraged.socket \
    virtsecretd.socket \
    virtnodedevd.socket \
    virtinterfaced.socket \
    virtnwfilterd.socket \
    virtproxyd.socket; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"; then
      sudo systemctl enable --now "$unit" || warn "Could not enable $unit"
      enabled_modular=1
    fi
  done

  if (( enabled_modular == 0 )) && \
     systemctl list-unit-files libvirtd.service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq 'libvirtd.service'; then
    sudo systemctl enable --now libvirtd.service || warn "Could not enable libvirtd.service"
  fi

  sudo getent group libvirt >/dev/null && sudo usermod -aG libvirt "$(real_user)" || true
  sudo getent group kvm >/dev/null && sudo usermod -aG kvm "$(real_user)" || true

  if command -v virsh >/dev/null 2>&1; then
    if sudo virsh net-info default >/dev/null 2>&1; then
      sudo virsh net-autostart default || true
      sudo virsh net-start default || true
    else
      warn "Libvirt default NAT network was not found. virt-manager can create it later."
    fi
  fi

  warn "Virtualization group permissions require logout/login or reboot."
}

rocm_install() {
  local arch ubuntu_ver rocm_choice

  arch="$(dpkg --print-architecture)"

  # shellcheck disable=SC1091
  . /etc/os-release
  ubuntu_ver="${VERSION_ID:-unknown}"

  if [[ "$arch" != "amd64" ]]; then
    warn "ROCm native Ubuntu packages are expected mainly on amd64. Current arch: $arch"
    ask_user "Try installing ROCm anyway?" || return 0
  fi

  apt_install_existing pciutils software-properties-common

  if command -v lspci >/dev/null 2>&1; then
    if ! lspci | grep -Ei 'VGA|3D|Display' | grep -qi 'AMD\|ATI'; then
      warn "No AMD GPU was detected by lspci."
      ask_user "Continue installing ROCm anyway?" || return 0
    fi
  fi

  if [[ "$ubuntu_ver" != "26.04" ]]; then
    warn "This ROCm block is tuned for Ubuntu/Kubuntu 26.04 native archive packages."
    warn "Detected Ubuntu version: $ubuntu_ver"
    ask_user "Try native APT ROCm install anyway?" || return 0
  fi

  sudo add-apt-repository -y universe || true
  mark_apt_stale
  refresh_apt

  if ! apt_has_pkg rocm; then
    warn "Package 'rocm' was not found in the enabled repositories."
    warn "Make sure you are on Kubuntu/Ubuntu 26.04+ with Universe enabled."
    return 0
  fi

  echo "Choose ROCm install profile:"
  select rocm_choice in "full-rocm" "dev-only" "runtime-libraries" "cancel"; do
    case "$rocm_choice" in
      full-rocm)
        apt_install_existing rocm
        break
        ;;
      dev-only)
        apt_install_existing rocm-dev
        break
        ;;
      runtime-libraries)
        apt_install_existing rocm-hip-runtime rocm-hip-libraries rocm-ml-libraries rocm-opencl-runtime
        break
        ;;
      cancel)
        warn "ROCm install cancelled."
        return 0
        ;;
      *) echo "Invalid choice." ;;
    esac
  done

  apt_install_existing rocminfo rocm-smi || true

  sudo getent group render >/dev/null && sudo usermod -aG render "$(real_user)" || true
  sudo getent group video  >/dev/null && sudo usermod -aG video  "$(real_user)" || true

  warn "ROCm group permissions require logout/login or reboot."

  if command -v rocminfo >/dev/null 2>&1; then
    info "Testing rocminfo:"
    rocminfo | head -80 || warn "rocminfo did not run successfully yet. Reboot may be required."
  fi
}

chrome_install() {
  local arch tmpdir debfile

  arch="$(dpkg --print-architecture)"

  if [[ "$arch" != "amd64" ]]; then
    warn "Official Google Chrome .deb install here is only handled for amd64. Current arch: $arch"
    return 0
  fi

  apt_install_existing wget curl ca-certificates

  tmpdir="$(mktemp -d)"
  debfile="${tmpdir}/google-chrome-stable_current_amd64.deb"

  download_to https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb "$debfile"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$debfile" || true

  rm -rf "$tmpdir"
}

firefox_mozilla_install() {
  local fpr

  apt_install_existing wget ca-certificates gnupg

  sudo install -d -m 0755 /etc/apt/keyrings

  wget -qO- https://packages.mozilla.org/apt/repo-signing-key.gpg \
    | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null

  fpr="$(
    gpg -n -q --import --import-options import-show /etc/apt/keyrings/packages.mozilla.org.asc 2>/dev/null \
      | awk '/pub/{getline; gsub(/^ +| +$/,"",$0); print}' \
      | tr -d '[:space:]'
  )"

  if [[ "$fpr" != "35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3" ]]; then
    warn "Mozilla repo key fingerprint did not match expected value."
    warn "Expected: 35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
    warn "Actual:   ${fpr:-unknown}"
    ask_user "Continue Firefox Mozilla repo setup anyway?" || return 0
  fi

  sudo tee /etc/apt/sources.list.d/mozilla.list >/dev/null <<'EOF_MOZILLA_REPO'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
EOF_MOZILLA_REPO

  sudo tee /etc/apt/preferences.d/mozilla >/dev/null <<'EOF_MOZILLA_PREF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF_MOZILLA_PREF

  mark_apt_stale
  refresh_apt

  if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
    warn "Removing existing Firefox Snap package."
    sudo snap remove firefox || true
  fi

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y firefox firefox-l10n-el

  if command -v xdg-settings >/dev/null 2>&1 && [[ -f /usr/share/applications/firefox.desktop ]]; then
    xdg-settings set default-web-browser firefox.desktop || true
  fi
}

ollama_install() {
  apt_install_existing curl

  local tmp
  tmp="$(mktemp)"

  download_to https://ollama.com/install.sh "$tmp"
  chmod +x "$tmp"
  sh "$tmp"
  rm -f "$tmp"

  sudo systemctl enable --now ollama 2>/dev/null || true
}

lmstudio_install() {
  local arch lm_arch tmpdeb url

  arch="$(dpkg --print-architecture)"

  case "$arch" in
    amd64)
      lm_arch="x64"
      ;;
    arm64)
      lm_arch="arm64"
      ;;
    *)
      warn "LM Studio Linux .deb is expected for x64/arm64. Current arch: $arch"
      return 0
      ;;
  esac

  apt_install_existing curl ca-certificates

  tmpdeb="$(mktemp --suffix=.deb)"
  url="https://lmstudio.ai/download/latest/linux/${lm_arch}?format=deb"

  info "Downloading LM Studio .deb from official latest URL."
  if ! download_to "$url" "$tmpdeb"; then
    rm -f "$tmpdeb"
    warn "LM Studio .deb download failed."
    warn "Manual download page: https://lmstudio.ai/download"
    return 0
  fi

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmpdeb" || {
    warn "LM Studio .deb install failed."
    rm -f "$tmpdeb"
    return 0
  }

  rm -f "$tmpdeb"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  fi

  info "LM Studio installed. Launch it from the application menu or run: lm-studio"
}

mediaapps_install() {
  apt_install_existing vlc gimp inkscape krita kdenlive obs-studio
}

libreoffice_install() {
  apt_install_existing \
    libreoffice libreoffice-l10n-el libreoffice-help-el \
    hunspell-el hyphen-el mythes-el
}

flatpak_apps_install() {
  apt_install_existing flatpak

  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

  local apps=(
    com.github.tchx84.Flatseal
    io.missioncenter.MissionCenter
    org.signal.Signal
    it.mijorus.gearlever
    org.gustavoperedo.FontDownloader
  )

  local app
  for app in "${apps[@]}"; do
    flatpak install -y --noninteractive flathub "$app" || warn "Flatpak failed: $app"
  done
}

# -------------------- KDE / Plasma --------------------
kde_extras_install() {
  apt_install_existing \
    kio-admin \
    kde-config-gtk-style \
    kde-gtk-config \
    breeze-gtk-theme \
    xdg-desktop-portal-kde \
    plasma-browser-integration

  mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"

  cat > "$HOME/.config/gtk-3.0/settings.ini" <<EOF_GTK3
[Settings]
gtk-theme-name=$GTK_THEME_NAME
gtk-icon-theme-name=$GTK_ICON_THEME
gtk-font-name=$GTK_FONT_NAME
gtk-cursor-theme-name=$GTK_CURSOR_THEME
gtk-application-prefer-dark-theme=1
EOF_GTK3

  cat > "$HOME/.config/gtk-4.0/settings.ini" <<EOF_GTK4
[Settings]
gtk-theme-name=$GTK_THEME_NAME
gtk-icon-theme-name=$GTK_ICON_THEME
gtk-font-name=$GTK_FONT_NAME
gtk-cursor-theme-name=$GTK_CURSOR_THEME
gtk-application-prefer-dark-theme=1
EOF_GTK4

  cat > "$HOME/.gtkrc-2.0" <<EOF_GTK2
gtk-theme-name="$GTK_THEME_NAME"
gtk-icon-theme-name="$GTK_ICON_THEME"
gtk-font-name="$GTK_FONT_NAME"
gtk-cursor-theme-name="$GTK_CURSOR_THEME"
EOF_GTK2
}

kde_tweaks_run() {
  local KWRITE BALOO DESKTOP_DIR

  KWRITE="$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)"
  BALOO="$(command -v balooctl6 || command -v balooctl || true)"

  if [[ -z "$KWRITE" ]]; then
    warn "kwriteconfig5/6 not found — skipping KDE tweaks."
    return 0
  fi

  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "General" --key "ColorScheme" "$COLOR_SCHEME"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "Icons"   --key "Theme" "$ICON_THEME"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "General" --key "font" "$UI_FONT"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "General" --key "fixed" "$MONO_FONT"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "KDE"     --key "SingleClick" "true"

  "$KWRITE" --file "$HOME/.config/dolphinrc" --group "General" --key "ShowFullPathInTitlebar" "true"
  "$KWRITE" --file "$HOME/.config/dolphinrc" --group "General" --key "ShowHiddenFiles" "true"
  "$KWRITE" --file "$HOME/.config/dolphinrc" --group "General" --key "PreviewsShown" "false"

  "$KWRITE" --file "$HOME/.config/kwinrc" --group "Plugins"     --key "blurEnabled" "true"
  "$KWRITE" --file "$HOME/.config/kwinrc" --group "NightColor"  --key "Active" "true"
  "$KWRITE" --file "$HOME/.config/kwinrc" --group "NightColor"  --key "Mode" "Automatic"
  "$KWRITE" --file "$HOME/.config/kwinrc" --group "Compositing" --key "AnimationsEnabled" "false"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "KDE"     --key "GraphicEffectsLevel" "0"

  mkdir -p "$HOME/Pictures/Screenshots"
  "$KWRITE" --file "$HOME/.config/spectaclerc" --group "General" --key "defaultSaveLocation" "$HOME/Pictures/Screenshots"
  "$KWRITE" --file "$HOME/.config/spectaclerc" --group "General" --key "autoSaveImage" "true"
  "$KWRITE" --file "$HOME/.config/spectaclerc" --group "General" --key "copyImageToClipboard" "true"

  if [[ -n "$BALOO" ]]; then
    "$BALOO" disable || true
    "$KWRITE" --file "$HOME/.config/baloofilerc" --group "Basic Settings" --key "Indexing-Enabled" "false"
  fi

  DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
  mkdir -p "$DESKTOP_DIR"

  cat > "$DESKTOP_DIR/Home.desktop" <<EOF_HOME_DESKTOP
[Desktop Entry]
Name=Home
Type=Link
URL=file://$HOME
Icon=user-home
EOF_HOME_DESKTOP

  cat > "$DESKTOP_DIR/Usr.desktop" <<'EOF_USR_DESKTOP'
[Desktop Entry]
Name=Usr
Type=Link
URL=file:///usr
Icon=folder
EOF_USR_DESKTOP

  chmod +x "$DESKTOP_DIR"/*.desktop

  command -v qdbus6 >/dev/null 2>&1 && qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
  command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1 || true

  warn "Some Plasma settings require logout/login to fully apply."
}

# -------------------- Secondary disk setup --------------------
setup_secondary_disk() {
  info "Starting secondary disk setup."
  warn "This section can modify disks. Read every prompt carefully."

  apt_install_existing util-linux parted ntfs-3g exfatprogs

  local USERNAME USERID GROUPID
  USERNAME="$(real_user)"
  USERID="$(id -u "$USERNAME")"
  GROUPID="$(id -g "$USERNAME")"

  echo "=== Available disks ==="

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
    warn "Invalid selection."
  done

  echo "=== Partitions on $SELECTED_DISK ==="

  mapfile -t PART_INFO < <(
    lsblk -nrpo NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE "$SELECTED_DISK" |
      awk '$5=="part"{print $1 "|" $2 "|" $3 "|" $4}'
  )

  if (( ${#PART_INFO[@]} == 0 )); then
    warn "No partitions found on $SELECTED_DISK."
    if ! ask_user "Create a new full-disk partition on $SELECTED_DISK? THIS WILL ERASE DATA"; then
      warn "Partition creation skipped."
      return 1
    fi

    echo "Choose filesystem for the new partition:"
    select FS_CHOICE in ext4 xfs btrfs ntfs exfat; do
      case "$FS_CHOICE" in
        ext4|xfs|btrfs|ntfs|exfat) break ;;
        *) echo "Invalid choice." ;;
      esac
    done

    case "$FS_CHOICE" in
      xfs) apt_install_existing xfsprogs ;;
      btrfs) apt_install_existing btrfs-progs ;;
      ntfs) apt_install_existing ntfs-3g ;;
      exfat) apt_install_existing exfatprogs ;;
    esac

    info "Creating GPT partition table on $SELECTED_DISK."
    sudo parted -s "$SELECTED_DISK" mklabel gpt
    sudo parted -s "$SELECTED_DISK" mkpart primary 1MiB 100%
    sudo partprobe "$SELECTED_DISK" || true
    sleep 2

    local PARTITION
    PARTITION="$(lsblk -nrpo NAME,TYPE "$SELECTED_DISK" | awk '$2=="part"{print $1; exit}')"

    [[ -n "${PARTITION:-}" ]] || {
      error "Could not detect new partition."
      return 1
    }

    info "Formatting $PARTITION as $FS_CHOICE."

    case "$FS_CHOICE" in
      ext4) sudo mkfs.ext4 -F "$PARTITION" ;;
      xfs) sudo mkfs.xfs -f "$PARTITION" ;;
      btrfs) sudo mkfs.btrfs -f "$PARTITION" ;;
      ntfs) sudo mkfs.ntfs -f "$PARTITION" ;;
      exfat) sudo mkfs.exfat "$PARTITION" ;;
    esac

    mapfile -t PART_INFO < <(
      lsblk -nrpo NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE "$SELECTED_DISK" |
        awk '$5=="part"{print $1 "|" $2 "|" $3 "|" $4}'
    )
  fi

  i=1
  local LINE PNAME PSIZE PFSTYPE PMOUNT

  for LINE in "${PART_INFO[@]}"; do
    IFS="|" read -r PNAME PSIZE PFSTYPE PMOUNT <<< "$LINE"
    [[ -z "$PFSTYPE" ]] && PFSTYPE="unknown"
    [[ -z "$PMOUNT" ]] && PMOUNT="-"
    echo "[$i] $PNAME ($PSIZE) fstype=$PFSTYPE mount=$PMOUNT"
    i=$((i+1))
  done

  local PART_NUMBER PARTITION

  while true; do
    read -rp "Select partition number: " PART_NUMBER
    if [[ "$PART_NUMBER" =~ ^[0-9]+$ ]] && (( PART_NUMBER >= 1 && PART_NUMBER <= ${#PART_INFO[@]} )); then
      IFS="|" read -r PARTITION _ <<< "${PART_INFO[$((PART_NUMBER-1))]}"
      break
    fi
    warn "Invalid selection."
  done

  if findmnt -rn --source "$PARTITION" >/dev/null 2>&1; then
    warn "Partition is already mounted."
    return 0
  fi

  if sudo blkid "$PARTITION" | grep -iq bitlocker; then
    warn "BitLocker detected."
    apt_install_existing dislocker fuse3 ntfs-3g
    sudo mkdir -p /mnt/bitlocker /mnt/data

    read -rsp "Enter BitLocker password: " BL_PASS
    echo

    sudo dislocker -V "$PARTITION" -u"$BL_PASS" -- /mnt/bitlocker
    sudo mount -o loop,uid="$USERID",gid="$GROUPID" /mnt/bitlocker/dislocker-file /mnt/data

    info "Mounted BitLocker volume at /mnt/data."
    return 0
  fi

  local FS_TYPE UUID MOUNT_NAME MOUNT_DIR OPTS FSTAB_TYPE

  FS_TYPE="$(blkid -s TYPE -o value "$PARTITION")"
  UUID="$(blkid -s UUID -o value "$PARTITION")"

  [[ -n "$UUID" ]] || {
    error "No UUID found for $PARTITION."
    return 1
  }

  read -rp "Enter mount folder name under /mnt, e.g. storage: " MOUNT_NAME
  MOUNT_NAME="$(echo "$MOUNT_NAME" | tr -cd '[:alnum:]_.-')"

  [[ -n "$MOUNT_NAME" ]] || {
    error "Invalid mount name."
    return 1
  }

  MOUNT_DIR="/mnt/$MOUNT_NAME"
  sudo mkdir -p "$MOUNT_DIR"

  case "$FS_TYPE" in
    ntfs)
      FSTAB_TYPE="ntfs3"
      OPTS="defaults,uid=$USERID,gid=$GROUPID,umask=000"
      ;;
    vfat|fat|exfat)
      FSTAB_TYPE="$FS_TYPE"
      OPTS="defaults,uid=$USERID,gid=$GROUPID,umask=000"
      ;;
    btrfs)
      FSTAB_TYPE="btrfs"
      OPTS="defaults,compress=zstd:1"
      ;;
    *)
      FSTAB_TYPE="$FS_TYPE"
      OPTS="defaults"
      ;;
  esac

  backup_file /etc/fstab

  if ! sudo grep -q "UUID=$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNT_DIR $FSTAB_TYPE $OPTS 0 2" | sudo tee -a /etc/fstab >/dev/null
  else
    warn "An fstab entry for UUID=$UUID already exists."
  fi

  sudo mount -a
  info "Disk mounted at $MOUNT_DIR."
}

# -------------------- Menu flow --------------------
main() {
  if (( EUID == 0 )); then
    error "Run this script as your normal user, not root. It will sudo when needed."
    exit 1
  fi

  detect_os
  need_sudo
  ensure_whiptail

  local SYS_CHOICES

  if ! SYS_CHOICES=$(whiptail --title "Kubuntu 26.04+ Setup" --checklist "Select items to configure/install" 36 112 28 \
    "REPOS"             "Enable restricted / universe / multiverse"                        ON \
    "HOSTNAME"          "Change hostname"                                                  OFF \
    "UPDATE"            "Update system packages"                                           ON \
    "FWUPD"             "Firmware updates via fwupd/LVFS"                                  ON \
    "BASE_UTILS"        "Base utilities + Flatpak + Discover backend"                      ON \
    "GREEK"             "Greek language, keyboard, dictionaries"                           ON \
    "FONTS"             "Noto, Roboto, Inter, JetBrains Mono, Fira Code"                    ON \
    "MS_FONTS"          "Microsoft Core Fonts via ttf-mscorefonts-installer"                OFF \
    "MESLO_NERD"        "MesloLGS Nerd Fonts for terminal themes"                          OFF \
    "FONTCONFIG"        "User font rendering tweaks"                                       ON \
    "SECURITY"          "UFW, unattended upgrades, AppArmor tools, Lynis, rkhunter"         ON \
    "PERF"              "Swappiness, zram, fstrim, inotify, persistent journal"            ON \
    "MULTIMEDIA"        "FFmpeg + extra codecs + GStreamer plugins"                        ON \
    "CORE_TOOLS"        "CLI tools: jq, vim, htop, btop, fzf, ripgrep, bat, fd..."          ON \
    "BASH_DEFAULTS"     "Better Bash history/search/aliases"                               ON \
    "COCKPIT"           "Cockpit web system manager"                                       OFF \
    "DEVELOPER_TOOLS"   "VS Code, Meld, FileZilla, Git, Git Cola"                          ON \
    "DOCKER"            "Docker Engine / fallback to Ubuntu Docker if needed"              OFF \
    "VIRTUALIZATION"    "KVM/QEMU/libvirt/virt-manager stack"                              OFF \
    "TAILSCALE"         "Tailscale VPN"                                                    OFF \
    "ROCM"              "AMD ROCm from Ubuntu/Kubuntu native APT packages"                  OFF \
    "OLLAMA"            "Ollama local LLM runtime"                                         OFF \
    "LMSTUDIO"          "LM Studio desktop app from official Linux .deb"                    OFF \
    "CHROME"            "Google Chrome Stable .deb"                                        OFF \
    "FIREFOX_MOZILLA"   "Firefox .deb from Mozilla APT repo, remove Snap Firefox"          OFF \
    "MEDIAAPPS"         "VLC, GIMP, Inkscape, Krita, Kdenlive, OBS"                        ON \
    "LIBREOFFICE"       "LibreOffice with Greek language/help packages"                    ON \
    "FLATPAK_APPS"      "Flatpak apps: Flatseal, Mission Center, Signal, Gear Lever"       OFF \
    "KDE_EXTRAS"        "kio-admin + GTK/Breeze consistency + KDE portal/integration"      ON \
    "KDE_TWEAKS"        "Apply KDE UI/speed tweaks + desktop shortcuts"                    OFF \
    "BTRFS_SNAPPER"     "Enable Snapper if root filesystem is Btrfs"                       OFF \
    "SECONDARY_DISK"    "Advanced: mount/setup secondary disk or BitLocker volume"         OFF \
    3>&1 1>&2 2>&3); then
    warn "Setup cancelled."
    exit 0
  fi

  CURRENT_CHOICES="$SYS_CHOICES"

  is_sel "REPOS"             && run_step "Enable Ubuntu repositories"       sys_enable_repos
  is_sel "HOSTNAME"          && run_step "Hostname"                         sys_hostname
  is_sel "UPDATE"            && run_step "Update packages"                  sys_update
  is_sel "FWUPD"             && run_step "Firmware updates"                 sys_fwupd
  is_sel "BASE_UTILS"        && run_step "Base utilities"                   sys_base_utils
  is_sel "GREEK"             && run_step "Greek language support"           sys_greek
  is_sel "FONTS"             && run_step "Fonts"                            sys_fonts
  is_sel "MS_FONTS"          && run_step "Microsoft Core Fonts"             microsoft_fonts_install
  is_sel "MESLO_NERD"        && run_step "MesloLGS Nerd Fonts"              install_meslo_nerd_fonts
  is_sel "FONTCONFIG"        && run_step "Fontconfig"                       sys_fontconfig
  is_sel "SECURITY"          && run_step "Security tools"                   sys_security
  is_sel "PERF"              && run_step "Performance tuning"               sys_perf
  is_sel "MULTIMEDIA"        && run_step "Multimedia codecs"                sys_multimedia
  is_sel "CORE_TOOLS"        && run_step "Core CLI tools"                   sys_core_tools
  is_sel "BASH_DEFAULTS"     && run_step "Bash defaults"                    sys_bash_defaults

  is_sel "COCKPIT"           && run_step "Cockpit"                          cockpit_install
  is_sel "DEVELOPER_TOOLS"   && run_step "Developer tools"                  developer_tools_install
  is_sel "DOCKER"            && run_step "Docker"                           docker_install
  is_sel "VIRTUALIZATION"    && run_step "Virtualization"                   virtualization_install
  is_sel "TAILSCALE"         && run_step "Tailscale"                        tailscale_install
  is_sel "ROCM"              && run_step "AMD ROCm"                         rocm_install
  is_sel "OLLAMA"            && run_step "Ollama"                           ollama_install
  is_sel "LMSTUDIO"          && run_step "LM Studio"                        lmstudio_install
  is_sel "CHROME"            && run_step "Google Chrome"                    chrome_install
  is_sel "FIREFOX_MOZILLA"   && run_step "Firefox from Mozilla APT repo"    firefox_mozilla_install
  is_sel "MEDIAAPPS"         && run_step "Media apps"                       mediaapps_install
  is_sel "LIBREOFFICE"       && run_step "LibreOffice"                      libreoffice_install
  is_sel "FLATPAK_APPS"      && run_step "Flatpak apps"                     flatpak_apps_install
  is_sel "KDE_EXTRAS"        && run_step "KDE extras"                       kde_extras_install
  is_sel "KDE_TWEAKS"        && run_step "KDE tweaks"                       kde_tweaks_run
  is_sel "BTRFS_SNAPPER"     && run_step "Btrfs Snapper"                    sys_btrfs_snapper
  is_sel "SECONDARY_DISK"    && run_step "Secondary disk setup"             setup_secondary_disk

  echo
  info "All selected tasks finished."

  warn "A reboot is recommended if you changed kernel/system services, firmware, Docker, virtualization, zram, fonts, ROCm, or Plasma settings."

  if whiptail --yesno "Reboot now?" 8 58; then
    sudo reboot
  else
    info "Reboot skipped."
  fi
}

main "$@"
