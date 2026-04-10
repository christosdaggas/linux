#!/usr/bin/env bash
# Kubuntu Setup Script v2
# Target: Kubuntu 24.04 LTS+ (should also work on newer Ubuntu/Kubuntu releases)
# Run:
#   cd ~/Downloads && chmod +x Kubuntu-Setup-v2.sh && ./Kubuntu-Setup-v2.sh

set -uo pipefail

# ====== Colors & Banners ======
RESET="\e[0m"
INFO="\e[30;103;1m"
WARN="\e[30;103;1m"
ERROR="\e[97;101;1m"

info()  { echo -e "${INFO}$*${RESET}"; }
warn()  { echo -e "${WARN}$*${RESET}"; }
error() { echo -e "${ERROR}$*${RESET}"; }
title() { echo; echo "==== $* ===="; }

# ====== Hard guard: do NOT run as root ======
if (( EUID == 0 )); then
  error "Run this script as your normal user (not root). It will sudo when needed."
  exit 1
fi

# ====== Defaults / Tweaks ======
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

# ====== Helpers ======
need_sudo() {
  info "Please enter your sudo password to start the setup:"
  sudo -v || { error "sudo is not available."; exit 1; }
  while true; do sudo -n true; sleep 60; done 2>/dev/null &
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

  if ! command -v plasma-discover >/dev/null 2>&1 && ! dpkg -s kubuntu-desktop >/dev/null 2>&1; then
    warn "Kubuntu desktop packages were not clearly detected."
    warn "The script will continue because this is an Ubuntu-based system."
  fi
}

ensure_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    info "Installing whiptail..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail || {
      error "Failed to install whiptail."
      exit 1
    }
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

apt_install_existing() {
  local pkg
  local to_install=()

  (( APT_UPDATED == 0 )) && refresh_apt

  for pkg in "$@"; do
    if apt_has_pkg "$pkg"; then
      to_install+=("$pkg")
    else
      warn "Package not available on this release: $pkg"
    fi
  done

  if (( ${#to_install[@]} == 0 )); then
    warn "Nothing to install in this step."
    return 0
  fi

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}"
}

is_sel() {
  local tag="$1"
  [[ " $CURRENT_CHOICES " == *"\"$tag\""* ]]
}

run_step() {
  local label="$1"; shift
  title "$label"
  ( set -e; "$@" )
  local rc=$?
  (( rc != 0 )) && warn "⚠ '$label' failed with code $rc — continuing..."
  return 0
}

# ====== System sections ======
sys_enable_repos() {
  sudo DEBIAN_FRONTEND=noninteractive apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common

  sudo add-apt-repository -y restricted || true
  sudo add-apt-repository -y universe   || true
  sudo add-apt-repository -y multiverse || true

  mark_apt_stale
  refresh_apt
}

sys_hostname() {
  local new_hostname
  read -rp "Enter new hostname: " new_hostname
  [[ -z "${new_hostname// }" ]] && { warn "Hostname is empty; skipping."; return 0; }

  sudo hostnamectl set-hostname "$new_hostname"

  if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sudo sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${new_hostname}/" /etc/hosts
  else
    echo -e "127.0.1.1\t${new_hostname}" | sudo tee -a /etc/hosts >/dev/null
  fi
}

sys_update() {
  refresh_apt
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade
}

sys_fwupd() {
  apt_install_existing fwupd
  sudo fwupdmgr refresh --force || true
  sudo fwupdmgr get-updates || true
  sudo fwupdmgr update || true
}

sys_base_utils() {
  apt_install_existing \
    ca-certificates curl wget gpg cabextract fontconfig \
    software-properties-common x11-xserver-utils \
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
  sudo localectl set-x11-keymap "us,gr" "" "" "$XKB_OPTIONS" || true

  mkdir -p "$HOME/.config"
  cat > "$HOME/.config/kxkbrc" <<EOF
[Layout]
LayoutList=$XKB_LAYOUTS
Options=$XKB_OPTIONS
ResetOldOptions=true
SwitchMode=Global
Use=true
EOF
}

sys_fontconfig() {
  mkdir -p "$HOME/.config/fontconfig"
  cat > "$HOME/.config/fontconfig/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
 <match target="font">
  <edit name="hinting" mode="assign"><bool>true</bool></edit>
  <edit name="antialias" mode="assign"><bool>true</bool></edit>
  <edit name="rgba" mode="assign"><const>rgb</const></edit>
  <edit name="hintstyle" mode="assign"><const>hintfull</const></edit>
 </match>
</fontconfig>
EOF
  fc-cache -f >/dev/null 2>&1 || true
}

sys_security() {
  apt_install_existing \
    ufw unattended-upgrades apparmor-profiles \
    lynis rkhunter apt-listchanges fail2ban

  sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true

  sudo ufw default deny incoming || true
  sudo ufw default allow outgoing || true

  if dpkg -s openssh-server >/dev/null 2>&1; then
    sudo ufw allow OpenSSH || true
    sudo systemctl enable --now fail2ban || true
  else
    warn "openssh-server is not installed; skipping OpenSSH/Fail2Ban activation."
  fi

  sudo ufw --force enable || true
}

sys_perf() {
  echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
  sudo sysctl --system || true

  if apt_has_pkg systemd-zram-generator; then
    apt_install_existing systemd-zram-generator

    sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

    sudo systemctl daemon-reload || true
    sudo systemctl start systemd-zram-setup@zram0.service || true
  elif apt_has_pkg zram-tools; then
    apt_install_existing zram-tools
  else
    warn "No zram package found for this release; skipping zram setup."
  fi

  sudo systemctl enable --now fstrim.timer || true
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
    curl vim htop ncdu unzip p7zip-full unrar-free \
    fwupd bash-completion flatpak
}

# ====== Applications ======
cockpit_install() {
  apt_install_existing cockpit cockpit-system
  sudo systemctl enable --now cockpit.socket || true

  if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
    sudo ufw allow 9090/tcp || true
  fi
}

developer_tools_install() {
  apt_install_existing wget gpg apt-transport-https ca-certificates

  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/microsoft.gpg >/dev/null

  sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64 arm64 armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF

  mark_apt_stale
  apt_install_existing code meld filezilla git git-cola
}

chrome_install() {
  local arch tmpdir debfile

  arch="$(dpkg --print-architecture)"
  if [[ "$arch" != "amd64" ]]; then
    warn "Official Google Chrome .deb install here is only handled for amd64. Current arch: $arch"
    return 0
  fi

  apt_install_existing wget ca-certificates

  tmpdir="$(mktemp -d)"
  debfile="${tmpdir}/google-chrome-stable_current_amd64.deb"

  wget -O "$debfile" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$debfile" || true

  rm -rf "$tmpdir"
}

firefox_mozilla_install() {
  local fpr
  apt_install_existing wget ca-certificates gnupg

  sudo install -d -m 0755 /etc/apt/keyrings

  wget -qO- https://packages.mozilla.org/apt/repo-signing-key.gpg \
    | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null

  if command -v gpg >/dev/null 2>&1; then
    fpr="$(
      gpg -n -q --import --import-options import-show /etc/apt/keyrings/packages.mozilla.org.asc 2>/dev/null \
        | awk '/pub/{getline; gsub(/^ +| +$/,""); print}' \
        | tr -d '[:space:]'
    )"
    if [[ "$fpr" != "35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3" ]]; then
      warn "Mozilla repo key fingerprint check did not match the expected value."
      warn "Expected: 35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
    fi
  else
    warn "gpg not found; skipping Mozilla key fingerprint verification."
  fi

  sudo tee /etc/apt/sources.list.d/mozilla.list >/dev/null <<'EOF'
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main
EOF

  sudo tee /etc/apt/preferences.d/mozilla >/dev/null <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

  mark_apt_stale
  refresh_apt

  if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
    warn "Removing existing Firefox Snap package..."
    sudo snap remove firefox || true
  fi

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y firefox firefox-l10n-el

  if command -v xdg-settings >/dev/null 2>&1 && [[ -f /usr/share/applications/firefox.desktop ]]; then
    xdg-settings set default-web-browser firefox.desktop || true
  fi
}

ollama_install() {
  curl -fsSL https://ollama.com/install.sh | sh
}

mediaapps_install() {
  apt_install_existing vlc gimp inkscape krita
}

libreoffice_install() {
  apt_install_existing \
    libreoffice libreoffice-l10n-el libreoffice-help-el hunspell-el
}

# ====== KDE / Plasma extras ======
kde_extras_install() {
  apt_install_existing \
    kio-admin \
    kde-gtk-config \
    kde-config-gtk-style \
    breeze-gtk-theme \
    xdg-desktop-portal-kde

  if apt_has_pkg plasma-browser-integration; then
    apt_install_existing plasma-browser-integration
  else
    warn "plasma-browser-integration is not available on this release/repository set; skipping."
  fi

  mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"

  cat > "$HOME/.config/gtk-3.0/settings.ini" <<EOF
[Settings]
gtk-theme-name=$GTK_THEME_NAME
gtk-icon-theme-name=$GTK_ICON_THEME
gtk-font-name=$GTK_FONT_NAME
gtk-cursor-theme-name=$GTK_CURSOR_THEME
gtk-application-prefer-dark-theme=1
EOF

  cat > "$HOME/.config/gtk-4.0/settings.ini" <<EOF
[Settings]
gtk-theme-name=$GTK_THEME_NAME
gtk-icon-theme-name=$GTK_ICON_THEME
gtk-font-name=$GTK_FONT_NAME
gtk-cursor-theme-name=$GTK_CURSOR_THEME
gtk-application-prefer-dark-theme=1
EOF

  cat > "$HOME/.gtkrc-2.0" <<EOF
gtk-theme-name="$GTK_THEME_NAME"
gtk-icon-theme-name="$GTK_ICON_THEME"
gtk-font-name="$GTK_FONT_NAME"
gtk-cursor-theme-name="$GTK_CURSOR_THEME"
EOF
}

# ====== KDE Tweaks ======
tweaks_run() {
  local KWRITE
  KWRITE="$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)"

  if [[ -z "$KWRITE" ]]; then
    warn "kwriteconfig5/6 not found — skipping KDE tweaks."
    return 0
  fi

  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "General" --key "ColorScheme" "$COLOR_SCHEME"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "Icons"   --key "Theme"       "$ICON_THEME"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "General" --key "font"        "$UI_FONT"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "General" --key "fixed"       "$MONO_FONT"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "KDE"     --key "SingleClick" "true"

  "$KWRITE" --file "$HOME/.config/dolphinrc"  --group "General" --key "ShowFullPathInTitlebar" "true"
  "$KWRITE" --file "$HOME/.config/dolphinrc"  --group "General" --key "ShowHiddenFiles"        "true"
  "$KWRITE" --file "$HOME/.config/dolphinrc"  --group "General" --key "PreviewsShown"          "false"

  "$KWRITE" --file "$HOME/.config/kwinrc"     --group "Plugins"     --key "blurEnabled" "true"
  "$KWRITE" --file "$HOME/.config/kwinrc"     --group "NightColor"  --key "Active"      "true"
  "$KWRITE" --file "$HOME/.config/kwinrc"     --group "NightColor"  --key "Mode"        "Automatic"
  "$KWRITE" --file "$HOME/.config/kwinrc"     --group "Compositing" --key "AnimationsEnabled" "false"
  "$KWRITE" --file "$HOME/.config/kdeglobals" --group "KDE"         --key "GraphicEffectsLevel" "0"

  mkdir -p "$HOME/Pictures/Screenshots"
  "$KWRITE" --file "$HOME/.config/spectaclerc" --group "General" --key "defaultSaveLocation" "$HOME/Pictures/Screenshots"
  "$KWRITE" --file "$HOME/.config/spectaclerc" --group "General" --key "autoSaveImage" "true"
  "$KWRITE" --file "$HOME/.config/spectaclerc" --group "General" --key "copyImageToClipboard" "true"

  if command -v balooctl >/dev/null 2>&1; then
    balooctl disable || true
    "$KWRITE" --file "$HOME/.config/baloofilerc" --group "Basic Settings" --key "Indexing-Enabled" "false"
  fi

  mkdir -p "$HOME/Desktop"

  cat > "$HOME/Desktop/Home.desktop" <<EOF
[Desktop Entry]
Name=Home
Type=Link
URL=file://$HOME
Icon=user-home
EOF

  cat > "$HOME/Desktop/User.desktop" <<EOF
[Desktop Entry]
Name=User
Type=Link
URL=file:///usr
Icon=folder
EOF

  chmod +x "$HOME"/Desktop/*.desktop
}

# ====== Menu flow ======
main() {
  detect_os
  need_sudo
  ensure_whiptail

  SYS_CHOICES=$(whiptail --title "Kubuntu Setup v2" --checklist "Select items to configure/install" 30 98 22 \
    "REPOS"             "Enable restricted / universe / multiverse"                        ON \
    "HOSTNAME"          "Change hostname"                                                  OFF \
    "UPDATE"            "Update system packages"                                           ON \
    "FWUPD"             "Firmware updates"                                                 ON \
    "BASE UTILS"        "Base utilities + Flatpak + Discover backend"                      ON \
    "GREEK"             "Greek language, keyboard, dictionaries"                           ON \
    "FONTCONFIG"        "Fontconfig optimizations"                                         ON \
    "SECURITY"          "UFW, AppArmor profiles, unattended-upgrades, Lynis..."            ON \
    "PERF"              "Swappiness, zram, fstrim"                                         ON \
    "MULTIMEDIA"        "FFmpeg + extra codecs + GStreamer plugins"                        ON \
    "CORE TOOLS"        "Core CLI tools (curl, vim, htop, unzip, p7zip...)"                ON \
    "COCKPIT"           "Cockpit (web system manager)"                                     OFF \
    "DEVELOPER TOOLS"   "VS Code, Meld, FileZilla, Git, Git Cola"                          ON \
    "OLLAMA"            "Ollama"                                                           OFF \
    "CHROME"            "Google Chrome Stable (.deb)"                                      OFF \
    "FIREFOX MOZILLA"   "Firefox (.deb) from Mozilla APT repo, not Snap"                   OFF \
    "MEDIAAPPS"         "VLC, GIMP, Inkscape, Krita"                                       ON \
    "LIBREOFFICE"       "LibreOffice (Greek language pack)"                                ON \
    "KDE EXTRAS"        "kio-admin + GTK/Breeze consistency + portal/browser integration"  ON \
    "TWEAKS"            "Apply KDE UI / speed tweaks + desktop shortcuts"                  OFF \
    3>&1 1>&2 2>&3) || true

  CURRENT_CHOICES="$SYS_CHOICES"

  is_sel "REPOS"            && run_step "Enable Ubuntu repositories"       sys_enable_repos
  is_sel "HOSTNAME"         && run_step "Hostname"                         sys_hostname
  is_sel "UPDATE"           && run_step "Update packages"                  sys_update
  is_sel "FWUPD"            && run_step "Firmware updates"                 sys_fwupd
  is_sel "BASE UTILS"       && run_step "Base utilities"                   sys_base_utils
  is_sel "GREEK"            && run_step "Greek language support"           sys_greek
  is_sel "FONTCONFIG"       && run_step "Fontconfig"                       sys_fontconfig
  is_sel "SECURITY"         && run_step "Security tools"                   sys_security
  is_sel "PERF"             && run_step "Performance tuning"               sys_perf
  is_sel "MULTIMEDIA"       && run_step "Multimedia codecs"                sys_multimedia
  is_sel "CORE TOOLS"       && run_step "Core CLI tools"                   sys_core_tools

  is_sel "COCKPIT"          && run_step "Cockpit"                          cockpit_install
  is_sel "DEVELOPER TOOLS"  && run_step "Developer tools"                  developer_tools_install
  is_sel "OLLAMA"           && run_step "Ollama"                           ollama_install
  is_sel "CHROME"           && run_step "Google Chrome"                    chrome_install
  is_sel "FIREFOX MOZILLA"  && run_step "Firefox from Mozilla APT repo"    firefox_mozilla_install
  is_sel "MEDIAAPPS"        && run_step "Media apps"                       mediaapps_install
  is_sel "LIBREOFFICE"      && run_step "LibreOffice"                      libreoffice_install
  is_sel "KDE EXTRAS"       && run_step "KDE extras"                       kde_extras_install
  is_sel "TWEAKS"           && run_step "KDE tweaks"                       tweaks_run

  echo -e "\n✅ All selected tasks finished."
  if whiptail --yesno "Reboot now to finish updates and system tweaks?" 8 58; then
    sudo reboot
  fi
}

main "$@"
