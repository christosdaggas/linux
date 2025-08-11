#!/usr/bin/env bash
# Fedora setup with main checklist (system + apps). KDE tweaks removed.
# cd ~/Downloads && chmod +x Fedora-Setup.sh && ./Fedora-Setup.sh

set -uo pipefail

# ====== Colors & Banners ======
RESET="\e[0m"
INFO="\e[30;103;1m"   # black on bright yellow (bold)
WARN="\e[30;103;1m"
ERROR="\e[97;101;1m"  # white on bright red (bold)
info()  { echo -e "${INFO}$*${RESET}"; }
warn()  { echo -e "${WARN}$*${RESET}"; }
error() { echo -e "${ERROR}$*${RESET}"; }

# ====== Hard guard: do NOT run as root ======
if (( EUID == 0 )); then
  error "Run this script as your normal user (not root). It will sudo when needed."
  exit 1
fi

# ====== Helpers ======
title() { echo; echo "==== $* ===="; }
need_sudo() {
  info "Please enter your sudo password to start the setup:"
  sudo -v || { error "Error: sudo not available"; exit 1; }
  while true; do sudo -v; sleep 60; done & SUDO_PID=$!; trap 'kill $SUDO_PID' EXIT
}
ensure_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    info "Installing whiptail (newt)…"
    sudo dnf install -y newt >/dev/null 2>&1 || true
  fi
  command -v whiptail >/dev/null 2>&1 || { error "whiptail missing; install 'newt' and re-run."; exit 1; }
}
# Selection checker that supports tags WITH spaces
is_sel() { local tag="$1"; [[ " $CURRENT_CHOICES " == *"\"$tag\""* ]]; }
# Run a step; on failure, warn and continue
run_step() {
  local label="$1"; shift
  title "$label"
  ( set -e; "$@" )
  local rc=$?
  (( rc != 0 )) && warn "⚠  '$label' failed with code $rc — continuing..."
  return 0
}

# ====== Config (used by language/fonts + tweaks) ======
DEFAULT_LANG="en_US.UTF-8"
XKB_LAYOUTS="us,gr"
XKB_OPTIONS="grp:alt_shift_toggle"
COLOR_SCHEME="BreezeDark"
ICON_THEME="breeze-dark"
UI_FONT="Noto Sans,10,-1,5,50,0,0,0,0,0"
MONO_FONT="JetBrains Mono,10,-1,5,50,0,0,0,0,0"

# ====== System sections ======
sys_dnf_tweaks() {
  sudo awk 'BEGIN{a=0} /fastestmirror=/{a=1} END{exit a}' /etc/dnf/dnf.conf || \
  sudo tee -a /etc/dnf/dnf.conf >/dev/null <<EOL
fastestmirror=True
max_parallel_downloads=10
deltarpm=True
keepcache=True
EOL
}
sys_hostname() {
  read -rp "Enter new hostname: " NEW_HOSTNAME
  sudo hostnamectl set-hostname "$NEW_HOSTNAME"
  sudo sed -i "s/127\.0\.1\.1.*/127.0.1.1   $NEW_HOSTNAME/" /etc/hosts || true
}
sys_update() { sudo dnf update -y; }
sys_rpmfusion() {
  sudo dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
}
sys_fwupd() {
  sudo fwupdmgr refresh --force || true
  sudo fwupdmgr get-updates || true
  sudo fwupdmgr update || true
}
sys_base_utils() {
  sudo dnf install -y openssl curl cabextract xorg-x11-font-utils fontconfig dnf5 dnf5-plugins glib2 flatpak
  sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
}
sys_greek() {
  sudo dnf install -y glibc-langpack-el langpacks-el google-noto-{sans,serif,mono}-fonts ibus ibus-gtk ibus-qt || true
  mkdir -p "$HOME/.config"
  cat > "$HOME/.config/kxkbrc" <<EOF
[Layout]
LayoutList=$XKB_LAYOUTS
Options=$XKB_OPTIONS
ResetOldOptions=true
SwitchMode=Global
Use=true
EOF
  sudo localectl set-x11-keymap "$(echo "$XKB_LAYOUTS" | cut -d, -f1)","$(echo "$XKB_LAYOUTS" | cut -d, -f2)" "" "" "$XKB_OPTIONS" || true
  sudo localectl set-locale "LANG=$DEFAULT_LANG" || true
}
sys_fontconfig() {
  mkdir -p ~/.config/fontconfig
  cat > ~/.config/fontconfig/fonts.conf <<'EOF'
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
}
sys_security() {
  sudo dnf install -y fail2ban rkhunter lynis setools-console policycoreutils-python-utils dnf-automatic
  sudo systemctl enable --now firewalld
  sudo systemctl enable --now dnf-automatic.timer
}
sys_perf() {
  echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
  sudo sysctl --system || true
  sudo dnf install -y zram-generator-defaults
  sudo systemctl enable --now systemd-zram-setup@zram0
  sudo systemctl enable --now fstrim.timer
}
sys_multimedia() {
  sudo dnf groupinstall -y "Multimedia" "Sound and Video" || true
  sudo dnf install -y ffmpeg-libs libavcodec-freeworld || true
}
sys_core_tools() {
  sudo dnf install -y curl vim htop ncdu unzip p7zip p7zip-plugins unrar fwupd bash-completion flatpak
}
sys_remove_kde_apps() {
  local REMOVE_PKGS=(
    akregator dragon juk kaddressbook kalarm kamera kcalc kcharselect kcolorchooser
    kdenlive khelpcenter kmail kmousetool knotes kolourpaint konversation korganizer
    krdc krfb ktnef skanlite sweeper gwenview elisa-player elisa okular kwrite
    kmahjongg kmines kpat plasma-welcome neochat kamoso qrca mediawriter evince
  )
  sudo dnf remove -y --noautoremove "${REMOVE_PKGS[@]}" 2>/dev/null || true
  sudo dnf autoremove -y || true
}

# ====== Applications ======
cockpit_install() {
  sudo dnf install -y cockpit
  sudo systemctl enable --now cockpit.socket
  if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --add-service=cockpit --permanent
    sudo firewall-cmd --reload
  fi
}
developer_tools_install() {
  sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
  sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<EOL
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOL
  sudo dnf -y install code meld filezilla git git-cola || true
}
chrome_install() {
  sudo dnf -y install fedora-workstation-repositories dnf-plugins-core dnf5-plugins || true
  if command -v dnf5 >/dev/null 2>&1; then CM=(dnf5 config-manager); else CM=(dnf config-manager); fi
  if ! sudo "${CM[@]}" setopt google-chrome.enabled=1; then
    warn "Repo not found or couldn't be enabled. Falling back to Google's RPM…"
    sudo dnf -y install https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm || true
  fi
  sudo dnf -y install google-chrome-stable || {
    warn "Retrying: reinstalling fedora-workstation-repositories and enabling repo…"
    sudo dnf -y reinstall fedora-workstation-repositories || true
    sudo "${CM[@]}" setopt google-chrome.enabled=1 || true
    sudo dnf -y install google-chrome-stable || true
  }
}
ollama_install() { curl -fsSL https://ollama.com/install.sh | sh; }
mediaapps_install()  { sudo dnf install -y vlc gimp inkscape krita; }
libreoffice_install(){ sudo dnf install -y libreoffice libreoffice-langpack-el libreoffice-langpack-en; }

# ====== NEW: Tweaks ======
tweaks_run() {
  local KWRITE
  KWRITE="$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)"

  echo "[5] Applying KDE UI tweaks..."
  if [[ -n "$KWRITE" ]]; then
    # UI theme/fonts/single click
    "$KWRITE" --file "$HOME/.config/kdeglobals" --group "General" --key "ColorScheme" "$COLOR_SCHEME"
    "$KWRITE" --file "$HOME/.config/kdeglobals" --group "Icons"   --key "Theme"       "$ICON_THEME"
    "$KWRITE" --file "$HOME/.config/kdeglobals" --group "General" --key "font"        "$UI_FONT"
    "$KWRITE" --file "$HOME/.config/kdeglobals" --group "General" --key "fixed"       "$MONO_FONT"
    "$KWRITE" --file "$HOME/.config/kdeglobals" --group "KDE"     --key "SingleClick" "true"

    # Dolphin prefs
    "$KWRITE" --file "$HOME/.config/dolphinrc"  --group "General" --key "ShowFullPathInTitlebar" "true"
    "$KWRITE" --file "$HOME/.config/dolphinrc"  --group "General" --key "ShowHiddenFiles"        "true"
    "$KWRITE" --file "$HOME/.config/dolphinrc"  --group "General" --key "PreviewsShown"          "false"

    # KWin / Night Color / Spectacle
    "$KWRITE" --file "$HOME/.config/kwinrc"     --group "Plugins"     --key "blurEnabled" "true"
    "$KWRITE" --file "$HOME/.config/kwinrc"     --group "NightColor"  --key "Active"      "true"
    "$KWRITE" --file "$HOME/.config/kwinrc"     --group "NightColor"  --key "Mode"        "Automatic"
    mkdir -p "$HOME/Pictures/Screenshots"
    "$KWRITE" --file "$HOME/.config/spectaclerc" --group "General" --key "defaultSaveLocation" "$HOME/Pictures/Screenshots"
    "$KWRITE" --file "$HOME/.config/spectaclerc" --group "General" --key "autoSaveImage" "true"
    "$KWRITE" --file "$HOME/.config/spectaclerc" --group "General" --key "copyImageToClipboard" "true"

    echo "[7] Disabling animations & indexing..."
    "$KWRITE" --file "$HOME/.config/kwinrc"      --group "Compositing"   --key "AnimationsEnabled" "false"
    "$KWRITE" --file "$HOME/.config/kdeglobals"  --group "KDE"           --key "GraphicEffectsLevel" "0"
    balooctl disable || true
    "$KWRITE" --file "$HOME/.config/baloofilerc" --group "Basic Settings" --key "Indexing-Enabled" "false"
  else
    warn "kwriteconfig5/6 not found — skipping KDE UI/Speed tweaks."
  fi

  echo "[13] Creating desktop shortcuts..."
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
  need_sudo
  ensure_whiptail

  SYS_CHOICES=$(whiptail --title "System & Apps" --checklist "Select items to configure/install" 28 84 26 \
    "DNF TWEAKS"       "DNF speed tweaks"                                ON \
    "HOSTNAME"         "Change hostname"                                  ON \
    "UPDATE"           "Update system packages"                           ON \
    "RPMFUSION"        "Enable RPM Fusion"                                ON \
    "FWUPD"            "Firmware updates"                                 ON \
    "BASE UTILS"       "Base utils + Flathub"                             ON \
    "GREEK"            "Greek language & keyboard"                        ON \
    "FONTCONFIG"       "Fontconfig optimizations"                         ON \
    "SECURITY"         "Security tools"                                   ON \
    "PERF"             "Performance tuning"                               ON \
    "MULTIMEDIA"       "Multimedia & codecs"                              ON \
    "CORE TOOLS"       "Core CLI tools (curl, vim, htop, unzip, p7zip etc.)" ON \
    "REMOVE KDE APPS"  "Uninstall KDE default apps (Akregator, Okular etc.)" ON \
    "COCKPIT"          "Cockpit (web system manager)"                     ON \
    "DEVELOPER TOOLS"  "Developer Tools (VS Code, Meld, FileZilla, Git)"  ON \
    "OLLAMA"           "Ollama"                                           ON \
    "CHROME"           "Google Chrome Stable"                             ON \
    "MEDIAAPPS"        "VLC, GIMP, Inkscape, Krita"                       ON \
    "LIBREOFFICE"      "LibreOffice (EN/EL)"                              ON \
    "TWEAKS"           "Apply KDE UI & Speed tweaks + create desktop shortcuts" OFF \
    3>&1 1>&2 2>&3) || true

  CURRENT_CHOICES="$SYS_CHOICES"

  # System items
  is_sel "DNF TWEAKS"       && run_step "DNF Tweaks"                sys_dnf_tweaks
  is_sel "HOSTNAME"         && run_step "Hostname"                  sys_hostname
  is_sel "UPDATE"           && run_step "Update"                    sys_update
  is_sel "RPMFUSION"        && run_step "RPM Fusion"                sys_rpmfusion
  is_sel "FWUPD"            && run_step "Firmware Updates"          sys_fwupd
  is_sel "BASE UTILS"       && run_step "Base Utilities"            sys_base_utils
  is_sel "GREEK"            && run_step "Greek Language"            sys_greek
  is_sel "FONTCONFIG"       && run_step "Fontconfig"                sys_fontconfig
  is_sel "SECURITY"         && run_step "Security Tools"            sys_security
  is_sel "PERF"             && run_step "Performance Tuning"        sys_perf
  is_sel "MULTIMEDIA"       && run_step "Multimedia & Codecs"       sys_multimedia
  is_sel "CORE TOOLS"       && run_step "Core CLI tools"            sys_core_tools
  is_sel "REMOVE KDE APPS"  && run_step "Remove KDE default apps"   sys_remove_kde_apps

  # App items
  is_sel "COCKPIT"          && run_step "Cockpit"                   cockpit_install
  is_sel "DEVELOPER TOOLS"  && run_step "Developer Tools"           developer_tools_install
  is_sel "OLLAMA"           && run_step "Ollama"                    ollama_install
  is_sel "CHROME"           && run_step "Chrome"                    chrome_install
  is_sel "MEDIAAPPS"        && run_step "Media Apps"                mediaapps_install
  is_sel "LIBREOFFICE"      && run_step "LibreOffice"               libreoffice_install

  # Tweaks
  is_sel "TWEAKS"           && run_step "Tweaks"                    tweaks_run

  echo -e "\n✅ All selected tasks finished."
  if whiptail --yesno "Reboot now to finish updates?" 8 50; then sudo reboot; fi
}

main "$@"
