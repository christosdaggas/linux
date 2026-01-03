#!/usr/bin/env bash
set -eo pipefail
shopt -s extglob

# ------------ Colors ---------------
info()  { echo -e "\e[36m[INFO]\e[0m $1"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1"; }

# ------------ Prompt y/n -----------
ask_user() {
  local prompt="$1"
  while true; do
    read -rp "$(echo -e "\e[44m\e[1m$prompt [y/n]:\e[0m ")" reply
    case "$reply" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

# --------- Install if Missing ------
install_if_missing() {
  local packages=("$@")
  local to_install=()
  for pkg in "${packages[@]}"; do
    if ! rpm -q "$pkg" &>/dev/null; then
      to_install+=("$pkg")
    else
      info "$pkg already installed."
    fi
  done

  if [ ${#to_install[@]} -gt 0 ]; then
    info "Installing: ${to_install[*]}"
    if ! sudo dnf install -y --skip-broken "${to_install[@]}"; then
      warn "Some packages could not be installed and were skipped."
    fi
  fi
}

# ---------- Safe gsettings Set ----------
safe_gsettings_set() {
  local schema="$1"
  local key="$2"
  local value="$3"
  if gsettings writable "$schema" "$key" &>/dev/null; then
    gsettings set "$schema" "$key" "$value"
    info "Set $schema::$key to $value"
  else
    warn "gsettings key $schema::$key not found – skipped"
  fi
}

# ----------- Optimize DNF ----------
optimize_dnf() {
  info "Optimizing DNF..."
  sudo touch /etc/dnf/dnf.conf
  # Avoid endlessly appending duplicates
  if ! grep -q '^fastestmirror=' /etc/dnf/dnf.conf; then
    sudo tee -a /etc/dnf/dnf.conf > /dev/null <<'EOL'
fastestmirror=True
max_parallel_downloads=10
deltarpm=True
keepcache=True
EOL
  else
    info "DNF already optimized (fastestmirror entry exists)."
  fi
}

# ----------- Enable SSD TRIM -------
enable_ssd_trim() {
  info "Enabling SSD trim..."
  sudo systemctl enable --now fstrim.timer
}

# ---------- Change Hostname --------
change_hostname() {
  read -rp "$(echo -e "\e[44m\e[1mEnter new hostname:\e[0m ")" NEW_HOSTNAME
  info "Changing hostname to $NEW_HOSTNAME..."
  sudo hostnamectl set-hostname "$NEW_HOSTNAME"
  sudo sed -i "s/127.0.1.1.*/127.0.1.1   $NEW_HOSTNAME/" /etc/hosts || true
}

# ---------- RPM Fusion (idempotent) ----------
ensure_rpmfusion() {
  if rpm -q rpmfusion-free-release rpmfusion-nonfree-release &>/dev/null; then
    info "RPM Fusion already enabled."
    return 0
  fi
  info "Enabling RPM Fusion Repositories..."
  sudo dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm || true
}

# ---------- Repo writers ----------
add_tailscale_repo() {
  if [[ -f /etc/yum.repos.d/tailscale.repo ]]; then
    info "Tailscale repo already exists. Skipping."
    return 0
  fi
  info "Adding Tailscale repo..."
  sudo tee /etc/yum.repos.d/tailscale.repo >/dev/null <<'EOF'
[tailscale-stable]
name=Tailscale stable
baseurl=https://pkgs.tailscale.com/stable/fedora/$basearch
enabled=1
gpgcheck=1
gpgkey=https://pkgs.tailscale.com/stable/fedora/repo.gpg
EOF
}

add_vscodium_repo() {
  if [[ -f /etc/yum.repos.d/vscodium.repo ]]; then
    info "VSCodium repo already exists. Skipping."
    return 0
  fi
  info "Adding VSCodium repo..."
  sudo tee /etc/yum.repos.d/vscodium.repo >/dev/null <<'EOF'
[gitlab.com_paulcarroty_vscodium_repo]
name=gitlab.com_paulcarroty_vscodium_repo
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
metadata_expire=1h
EOF
}

add_vscode_repo() {
  if [[ -f /etc/yum.repos.d/vscode.repo ]]; then
    info "VS Code repo already exists. Skipping."
    return 0
  fi
  info "Adding VS Code repo..."
  sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc || true
  sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
}

add_chrome_repo() {
  if [[ -f /etc/yum.repos.d/google-chrome.repo ]]; then
    info "Google Chrome repo already exists. Skipping."
    return 0
  fi
  info "Adding Google Chrome repo..."
  sudo tee /etc/yum.repos.d/google-chrome.repo >/dev/null <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
}

add_docker_repo() {
  local repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"

  if [[ -f /etc/yum.repos.d/docker-ce.repo ]]; then
    info "Docker repo already exists. Skipping."
    return 0
  fi

  info "Adding Docker repo..."
  install_if_missing curl dnf-plugins-core dnf5 dnf5-plugins || true

  # DNF5 syntax
  if sudo dnf config-manager addrepo --from-repofile "$repo_url" >/dev/null 2>&1; then
    info "Docker repo added via dnf5 config-manager addrepo."
    return 0
  fi

  # DNF4 fallback (older systems)
  if sudo dnf config-manager --add-repo "$repo_url" >/dev/null 2>&1; then
    info "Docker repo added via dnf4 config-manager --add-repo."
    return 0
  fi

  # Last resort: write repo file directly
  warn "dnf config-manager failed; writing repo file directly."
  sudo curl -fsSL "$repo_url" -o /etc/yum.repos.d/docker-ce.repo
}

# ---------- Requested feature installers ----------
install_tailscale_trayscale() {
  info "Installing Tailscale & Trayscale..."
  add_tailscale_repo
  install_if_missing tailscale trayscale
  sudo systemctl enable --now tailscaled
}

install_dev_tools_vscodium_vscode() {
  info "Installing Developer tools (VSCodium + VS Code)..."
  add_vscodium_repo
  add_vscode_repo
  sudo dnf check-update || true
  install_if_missing codium code
}

install_google_chrome() {
  info "Installing Google Chrome..."
  add_chrome_repo
  sudo dnf check-update || true
  install_if_missing google-chrome-stable
}

install_git_gitg() {
  info "Installing Git & Gitg..."
  install_if_missing git gitg
}

install_docker_whaler() {
  info "Installing Docker..."
  add_docker_repo
  sudo dnf check-update || true
  install_if_missing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker

  if ! getent group docker >/dev/null; then
    sudo groupadd docker
  fi
  sudo usermod -aG docker "${SUDO_USER:-$USER}"
  info "User added to docker group. Logout/login recommended if your shell/session does not pick it up."

  info "Installing Whaler (Flatpak)..."
  if ! command -v flatpak &>/dev/null; then
    info "Flatpak not found. Installing..."
    sudo dnf install -y flatpak
  fi
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak install -y flathub com.github.sdv43.whaler || warn "Failed to install Whaler Flatpak."
}

install_microsoft_fonts_lpf() {
  info "Installing Microsoft Fonts (Core + ClearType) via LPF..."
  ensure_rpmfusion
  install_if_missing lpf lpf-mscore-fonts lpf-cleartype-fonts fontconfig

  local target_user="${SUDO_USER:-$USER}"

  # Ensure pkg-build group exists (LPF expects it)
  if ! getent group pkg-build >/dev/null; then
    sudo groupadd -r pkg-build || true
  fi

  # Add user to pkg-build (idempotent)
  sudo usermod -aG pkg-build "$target_user" || true

  # Run lpf update as the real user (not root)
  info "Running 'lpf update' as user: $target_user"
  sudo -u "$target_user" -H lpf update || {
    warn "LPF failed. If it complains about 'pkg-build', log out/in (or reboot) and run the fonts option again."
    return 0
  }

  sudo fc-cache -rv
}

# ---------- Greek keyboard (user-level, automatic) ----------
add_greek_keyboard_userlevel() {
  if ! command -v gsettings &>/dev/null; then
    warn "gsettings not found – skipping Greek keyboard."
    return
  fi

  local current
  if ! current="$(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null)"; then
    warn "Could not read GNOME input sources (no session bus?). Skipping Greek keyboard."
    return
  fi

  if echo "$current" | grep -q "('xkb', 'gr')"; then
    info "Greek keyboard already present."
    return
  fi

  if [[ "$current" == "[]" || "$current" == "@a(ss) []" ]]; then
    gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'gr')]"
  else
    gsettings set org.gnome.desktop.input-sources sources "${current%]*}, ('xkb', 'gr')]"
  fi

  info "Greek keyboard added (user-level)."
}

# ---------- Initial Setup ----------
clear
info "Starting Fedora Workstation Setup"
read -n1 -s -rp "Press any key to continue..."

sudo -v
while true; do sudo -v; sleep 60; done & SUDO_PID=$!
trap 'kill $SUDO_PID' EXIT

optimize_dnf
enable_ssd_trim
change_hostname

# Auto add Greek keyboard user-level
add_greek_keyboard_userlevel

# -------- Cleanup Unwanted Defaults --------
info "Removing unwanted preinstalled applications..."
UNWANTED_PACKAGES=(evince rhythmbox abrt gnome-tour mediawriter)
sudo dnf remove -y "${UNWANTED_PACKAGES[@]}" || true

info "Updating system packages..."
sudo dnf update -y

# ----------- Group Installs --------
CORE_PACKAGES=(openssl curl fontconfig xorg-x11-font-utils dnf5 dnf5-plugins glib2 dnf-plugins-core)
SECURITY_PACKAGES=(dnf-automatic fail2ban rkhunter lynis)
TWEAK_PACKAGES=(gnome-color-manager zram-generator-defaults)
PRODUCTIVITY_APPS=(filezilla flatseal decibels dconf-editor papers)

# -------- Security Enhancements --------
info "Installing security-related tools..."
# sudo systemctl enable --now dnf-automatic.timer
sudo firewall-cmd --set-default-zone=home || warn "Could not set firewall default zone"

# Enable snapper if on btrfs root
if mount | grep -q ' on / type btrfs'; then
  info "Detected Btrfs root – enabling Snapper..."
  install_if_missing snapper
  if [ ! -e /etc/snapper/configs/root ]; then
    sudo snapper -c root create-config /
  else
    info "Snapper config for root already exists. Skipping creation."
  fi
  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
fi

# SELinux status warning
if [[ "$(getenforce)" != "Enforcing" ]]; then
  warn "SELinux is not in enforcing mode. Consider enabling it for better security."
fi

install_if_missing "${CORE_PACKAGES[@]}"
install_if_missing "${SECURITY_PACKAGES[@]}"
install_if_missing "${TWEAK_PACKAGES[@]}"
install_if_missing "${PRODUCTIVITY_APPS[@]}"

# ---------- RPM Fusion -------------
ensure_rpmfusion

# ---------- Enable snap support -------------
sudo dnf install -y snapd
sudo ln -s /var/lib/snapd/snap /snap 2>/dev/null || true

# ---------- Firmware Update --------
info "Updating firmware..."
sudo fwupdmgr refresh --force || true
sudo fwupdmgr get-updates || true
sudo fwupdmgr update || true

# ============================================================
# NEW OPTIONS (as requested)
# ============================================================
if ask_user "Install Tailscale & Trayscale (dnf + repo)?"; then
  install_tailscale_trayscale
fi

if ask_user "Install Developer tools (VSCodium + VS Code, dnf + repos)?"; then
  install_dev_tools_vscodium_vscode
fi

if ask_user "Install Google Chrome (dnf + repo)?"; then
  install_google_chrome
fi

if ask_user "Install Git & Gitg (dnf)?"; then
  install_git_gitg
fi

if ask_user "Install Docker & Whaler (Docker via dnf, Whaler via Flatpak)?"; then
  install_docker_whaler
fi

if ask_user "Install Microsoft Fonts (Core + ClearType via LPF)?"; then
  install_microsoft_fonts_lpf
fi

# --------- Cockpit (web-based system manager) ----------
if ask_user "Install Cockpit (web-based system manager)?"; then
  install_if_missing cockpit
  sudo systemctl enable --now cockpit.socket
  if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --add-service=cockpit --permanent
    sudo firewall-cmd --reload
  fi
  echo "Cockpit installation complete. You can access it at https://localhost:9090"
fi

# --------- GNOME Tweaks ----------
if ask_user "Install GNOME Tweaks and configure UI?"; then
  install_if_missing gnome-tweaks gnome-extensions-app gnome-usage
  safe_gsettings_set org.gnome.desktop.interface enable-animations false
  safe_gsettings_set org.gtk.gtk4.Settings.FileChooser sort-directories-first true
  safe_gsettings_set org.gnome.desktop.wm.preferences button-layout ":minimize,maximize,close"
  safe_gsettings_set org.gnome.desktop.wm.keybindings switch-windows "['<Alt>Tab']"
  safe_gsettings_set org.gnome.desktop.wm.keybindings switch-applications "['<Super>Tab']"
  safe_gsettings_set org.gnome.desktop.wm.keybindings switch-windows-backward "['<Shift><Alt>Tab']"
  safe_gsettings_set org.gnome.desktop.wm.keybindings switch-applications-backward "['<Shift><Super>Tab']"
  safe_gsettings_set org.gnome.nautilus.preferences recursive-search 'never'
  safe_gsettings_set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
  safe_gsettings_set org.gnome.settings-daemon.plugins.color night-light-enabled true
  safe_gsettings_set org.gtk.Settings.FileChooser show-recent false
  safe_gsettings_set org.gnome.desktop.wm.preferences resize-with-right-button true
  safe_gsettings_set org.gnome.shell enable-hot-corner true
  safe_gsettings_set org.gnome.nautilus.preferences show-image-thumbnails 'always'
  safe_gsettings_set org.gnome.nautilus.preferences show-hidden-files true
  safe_gsettings_set org.gnome.nautilus.preferences always-use-location-entry true
fi

# -------- Fedora GNOME User Experience Enhancements --------
if ask_user "Enhance Fedora GNOME experience (ZSH, Dark mode, Clipboard, AppImage support, etc.)?"; then
  info "Enhancing GNOME user experience..."
  install_if_missing fzf bat ripgrep
  systemctl --user enable --now flatpak-system-update.timer || true

  if gnome-extensions list 2>/dev/null | grep -q Vitals@CoreCoding.com; then
    gnome-extensions enable Vitals@CoreCoding.com || true
  fi

  if ask_user "Install USBGuard to protect against unauthorized USB devices?"; then
    install_if_missing usbguard
    sudo systemctl enable --now usbguard.service
  fi
fi

# -------- LibreOffice Suite --------
if ask_user "Install LibreOffice with English and Greek support?"; then
  install_if_missing libreoffice libreoffice-langpack-en libreoffice-langpack-el
fi

# -------- Design Applications -------
if ask_user "Install design applications (GIMP, Inkscape)?"; then
  MEDIA_APPS=(gimp inkscape)
  install_if_missing "${MEDIA_APPS[@]}"
fi

# --------- Flatpak Applications ----------
if ask_user "Install Flatpak applications from Flathub?"; then
  if ! command -v flatpak &>/dev/null; then
    info "Flatpak not found. Installing..."
    sudo dnf install -y flatpak
  fi
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  FLATPAK_APPS=(
    com.mattjakeman.ExtensionManager
    io.github.realmazharhussain.GdmSettings
    io.missioncenter.MissionCenter
    org.gustavoperedo.FontDownloader
    io.github.flattool.Ignition
    io.gitlab.news_flash.NewsFlash
    io.github.nate_xyz.Paleta
    org.signal.Signal
    org.gnome.Papers
    org.gnome.Firmware
  )
  for app in "${FLATPAK_APPS[@]}"; do
    flatpak install -y flathub "$app" || echo "⚠️ Failed to install $app"
  done
fi

# --------- GNOME Shell extensions ----------
if ask_user "Install GNOME Shell extensions?"; then
  install_if_missing jq unzip gnome-extensions gnome-shell-extension-prefs || true
  declare -A EXTENSIONS=(
    [6]="applications-menu@gnome-shell-extensions.gcampax.github.com"
    [19]="user-theme@gnome-shell-extensions.gcampax.github.com"
    [3628]="arcmenu@arcmenu.com"
    [3193]="blur-my-shell@aunetx"
    [6807]="system-monitor@paradoxxx.zero.gmail.com"
    [7]="drive-menu@gnome-shell-extensions.gcampax.github.com"
    [779]="clipboard-indicator@tudmotu.com"
    [1460]="Vitals@CoreCoding.com"
    [1160]="dash-to-panel@jderose9.github.com"
    [8]="places-menu@gnome-shell-extensions.gcampax.github.com"
    [1401]="bluetooth-quick-connect@bjarosze.gmail.com"
    [307]="dash-to-dock@micxgx.gmail.com"
    [2087]="ding@rastersoft.com"
  )
  EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
  mkdir -p "$EXT_DIR"
  SHELL_VERSION=$(gnome-shell --version | awk '{print $3}')
  for ID in "${!EXTENSIONS[@]}"; do
    UUID="${EXTENSIONS[$ID]}"
    info "Installing Extension ID $ID ($UUID)..."
    EXT_INFO=$(curl -s "https://extensions.gnome.org/extension-info/?pk=$ID&shell_version=$SHELL_VERSION")
    EXT_URL=$(echo "$EXT_INFO" | jq -r '.download_url')
    if [[ -z "$EXT_URL" || "$EXT_URL" == "null" ]]; then
      warn "Skipping $UUID (not compatible or not found)."
      continue
    fi
    TMP_ZIP="/tmp/$UUID.zip"
    EXT_PATH="$EXT_DIR/$UUID"
    curl -L -o "$TMP_ZIP" "https://extensions.gnome.org$EXT_URL"
    unzip -o "$TMP_ZIP" -d "$EXT_PATH"
    rm "$TMP_ZIP"
    if [ -d "$EXT_PATH/schemas" ]; then
      glib-compile-schemas "$EXT_PATH/schemas"
    fi
    gnome-extensions enable "$UUID" || warn "Could not enable $UUID"
    info "Installed and enabled $UUID"
  done
fi

# --------- Android Studio ----------
if ask_user "Install Android Studio?"; then
  flatpak install -y flathub com.google.AndroidStudio
fi

# --------- AI Tools: Ollama ONLY (Alpaca removed) ----------
if ask_user "Install Ollama?"; then
  OLLAMA_BIN="/usr/local/bin/ollama"
  if [[ ! -x "$OLLAMA_BIN" ]]; then
    install_if_missing curl
    curl -fsSL https://ollama.com/install.sh -o /tmp/ollama-install.sh
    bash /tmp/ollama-install.sh || echo "⚠️ Ollama installation failed"
  else
    info "Ollama already installed. Skipping..."
  fi
fi

# --------- Extra Fonts ----------
install_msttcore_fonts() {
  # Legacy fallback kept from your script (not used by default).
  local MSCORE_RPM="/tmp/msttcore-fonts-installer-2.6-1.noarch.rpm"
  local MAX_RETRIES=5
  local attempt=1

  install_if_missing cabextract wget

  while (( attempt <= MAX_RETRIES )); do
    info "Downloading msttcore fonts installer (attempt $attempt)..."
    wget -q https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm -O "$MSCORE_RPM"
    if [[ -f "$MSCORE_RPM" ]]; then
      if sudo rpm -i --nosignature "$MSCORE_RPM"; then
        info "msttcore fonts installed successfully."
        break
      else
        warn "msttcore fonts installation failed on attempt $attempt."
      fi
    else
      warn "Could not download msttcore fonts installer on attempt $attempt."
    fi
    ((attempt++))
    sleep 5
  done

  if (( attempt > MAX_RETRIES )); then
    warn "Failed to install msttcore fonts after $MAX_RETRIES attempts. Skipping."
  fi
}

if ask_user "Install extra fonts?"; then
  FONT_PACKAGES=(
    powerline-fonts fira-code-fonts mozilla-fira-sans-fonts
    liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts
    google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts
    google-roboto-fonts jetbrains-mono-fonts rsms-inter-fonts
  )
  install_if_missing "${FONT_PACKAGES[@]}"

  install_if_missing wget
  sudo wget -q -P /usr/share/fonts/ \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf || true

  sudo fc-cache -fv || true

  mkdir -p ~/.config/fontconfig
  cat <<'EOL' > ~/.config/fontconfig/fonts.conf
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
EOL
fi

# --------- Media Codecs ------------
if ask_user "Install media codecs (libavcodec-freeworld)?"; then
  ensure_rpmfusion
  install_if_missing libavcodec-freeworld
fi

# -------- Antivirus Tools ----------
# Removed per your requirement (ClamAV/ClamTk prompts deleted).

# ------------ Final Prompt ---------
if ask_user "Fedora setup completed. Reboot now?"; then
  info "Rebooting..."
  sleep 2
  reboot
else
  info "Reboot skipped."
fi
