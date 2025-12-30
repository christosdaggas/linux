#!/bin/bash
set -eo pipefail
shopt -s extglob

# =========================
# Debian 13 (Trixie) Workstation Setup
# =========================

# ------------ Colors ---------------
info() { echo -e "\e[36m[INFO]\e[0m $1"; }
warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
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

# --------- Detect OS ---------------
get_codename() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "${VERSION_CODENAME:-}"
  fi
}
CODENAME="$(get_codename)"
if [[ -z "$CODENAME" ]]; then
  warn "Could not detect Debian codename from /etc/os-release. Proceeding anyway."
fi

# --------- Sudo Keepalive ----------
sudo_keepalive() {
  sudo -v
  while true; do sudo -v; sleep 60; done & SUDO_PID=$!
  trap 'kill $SUDO_PID 2>/dev/null || true' EXIT
}

# --------- Apt helpers -------------
apt_update() {
  info "Updating apt package lists..."
  sudo apt-get update -y
}

pkg_installed() {
  dpkg -s "$1" &>/dev/null
}

pkg_available() {
  apt-cache show "$1" &>/dev/null
}

install_if_missing() {
  local packages=("$@")
  local to_install=()
  for pkg in "${packages[@]}"; do
    if pkg_installed "$pkg"; then
      info "$pkg already installed."
      continue
    fi
    if pkg_available "$pkg"; then
      to_install+=("$pkg")
    else
      warn "Package not found in apt: $pkg (skipping)"
    fi
  done

  if ((${#to_install[@]} > 0)); then
    info "Installing: ${to_install[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}" || warn "Some packages failed to install."
  fi
}

# ---------- Safe gsettings Set ----------
safe_gsettings_set() {
  local schema="$1"
  local key="$2"
  local value="$3"
  if command -v gsettings &>/dev/null && gsettings writable "$schema" "$key" &>/dev/null; then
    gsettings set "$schema" "$key" "$value"
    info "Set $schema::$key to $value"
  else
    warn "gsettings key $schema::$key not found or not writable – skipped"
  fi
}

# ----------- Optimize APT ----------
optimize_apt() {
  info "Optimizing APT..."
  sudo tee /etc/apt/apt.conf.d/99workstation-tuning >/dev/null <<'EOL'
Acquire::Retries "3";
Dpkg::Lock::Timeout "60";
APT::Install-Recommends "true";
APT::Install-Suggests "false";
EOL
}

# ----------- Enable SSD TRIM -------
enable_ssd_trim() {
  info "Enabling SSD trim..."
  if systemctl list-unit-files | grep -q '^fstrim\.timer'; then
    sudo systemctl enable --now fstrim.timer
  else
    warn "fstrim.timer not found (util-linux may be missing?)"
  fi
}

# ---------- Change Hostname --------
change_hostname() {
  read -rp "$(echo -e "\e[44m\e[1mEnter new hostname:\e[0m ")" NEW_HOSTNAME
  if [[ -n "$NEW_HOSTNAME" ]]; then
    info "Changing hostname to $NEW_HOSTNAME..."
    sudo hostnamectl set-hostname "$NEW_HOSTNAME"
    sudo sed -i "s/127.0.1.1.*/127.0.1.1   $NEW_HOSTNAME/" /etc/hosts 2>/dev/null || true
  else
    warn "Empty hostname entered; skipping."
  fi
}

# -------- Enable contrib/non-free (needed for ttf-mscorefonts-installer) -----
enable_contrib_nonfree() {
  info "Ensuring Debian components include: main contrib non-free non-free-firmware"

  # deb822 style
  if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    sudo cp -a /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/debian.sources.bak.$(date +%s)
    sudo sed -i -E \
      's/^(Components:\s*)(.*)$/\1\2 contrib non-free non-free-firmware/' \
      /etc/apt/sources.list.d/debian.sources
    # De-duplicate components tokens
    sudo awk '
      BEGIN{FS=": "; OFS=": "}
      /^Components: /{
        n=split($2,a," ");
        delete seen; out="";
        for(i=1;i<=n;i++){
          if(a[i]!="" && !seen[a[i]]++){ out=out (out==""?a[i]:" "a[i]) }
        }
        $2=out
      }
      {print}
    ' /etc/apt/sources.list.d/debian.sources | sudo tee /etc/apt/sources.list.d/debian.sources >/dev/null
  fi

  # classic sources.list
  if [[ -f /etc/apt/sources.list ]]; then
    sudo cp -a /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s)
    sudo sed -i -E \
      's/^(deb\s+\S+\s+\S+\s+)(main)(\s*)$/\1main contrib non-free non-free-firmware/' \
      /etc/apt/sources.list
  fi
}

# -------- Greek Keyboard (GNOME user-level) ----------
add_greek_keyboard_userlevel() {
  info "Configuring GNOME user-level keyboard layouts (adding Greek)..."
  if ! command -v gsettings &>/dev/null; then
    warn "gsettings not found; skipping Greek keyboard."
    return 0
  fi

  local schema="org.gnome.desktop.input-sources"
  local key="sources"

  local cur
  cur="$(gsettings get "$schema" "$key" 2>/dev/null || true)"
  if [[ -z "$cur" ]]; then
    warn "Could not read current GNOME input sources; skipping."
    return 0
  fi

  if echo "$cur" | grep -q "('xkb', 'gr')"; then
    info "Greek layout already present."
    return 0
  fi

  # Append Greek layout while preserving existing list
  # Example format: [('xkb', 'us'), ('xkb', 'de')]
  local new
  new="$(echo "$cur" | sed -E "s/\]\s*$/, ('xkb', 'gr')]/")"
  if [[ "$new" == "$cur" ]]; then
    warn "Failed to construct new input sources list; skipping."
    return 0
  fi

  gsettings set "$schema" "$key" "$new" && info "Greek keyboard added." || warn "Failed to set GNOME keyboard layouts."
}

# -------- GRUB: boot last selected OS ----------
set_grub_last_booted() {
  info "Configuring GRUB to boot the last selected entry..."
  if [[ ! -f /etc/default/grub ]]; then
    warn "/etc/default/grub not found; skipping GRUB config."
    return 0
  fi

  sudo cp -a /etc/default/grub /etc/default/grub.bak.$(date +%s)

  # Set GRUB_DEFAULT=saved
  if grep -qE '^GRUB_DEFAULT=' /etc/default/grub; then
    sudo sed -i -E 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
  else
    echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub >/dev/null
  fi

  # Enable save default
  if grep -qE '^GRUB_SAVEDEFAULT=' /etc/default/grub; then
    sudo sed -i -E 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub
  else
    echo 'GRUB_SAVEDEFAULT=true' | sudo tee -a /etc/default/grub >/dev/null
  fi

  if command -v update-grub &>/dev/null; then
    sudo update-grub
  elif command -v grub-mkconfig &>/dev/null; then
    sudo grub-mkconfig -o /boot/grub/grub.cfg
  else
    warn "Neither update-grub nor grub-mkconfig found; cannot regenerate GRUB config."
  fi
}

# -------- Keep only current kernel + 1 back ----------
purge_old_kernels_keep2() {
  info "Purging old kernels (keeping the running kernel and one previous)..."

  local running
  running="$(uname -r)"

  # List installed versioned linux-image packages (exclude meta packages)
  mapfile -t imgs < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | sort -V || true)

  if ((${#imgs[@]} <= 2)); then
    info "2 or fewer kernel images installed; nothing to purge."
    return 0
  fi

  # Identify the running kernel package (best-effort match)
  local keep_running=""
  for p in "${imgs[@]}"; do
    if echo "$p" | grep -q "${running}"; then
      keep_running="$p"
      break
    fi
  done

  # Choose an additional kernel to keep: newest one that is not the running kernel
  local keep_other=""
  for ((i=${#imgs[@]}-1; i>=0; i--)); do
    if [[ "${imgs[$i]}" != "$keep_running" ]]; then
      keep_other="${imgs[$i]}"
      break
    fi
  done

  info "Keeping kernel packages: ${keep_running:-<unknown running pkg>} and ${keep_other:-<none>}"

  local to_purge=()
  for p in "${imgs[@]}"; do
    [[ "$p" == "$keep_running" ]] && continue
    [[ "$p" == "$keep_other" ]] && continue
    to_purge+=("$p")
  done

  if ((${#to_purge[@]} > 0)); then
    info "Purging old kernels: ${to_purge[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y "${to_purge[@]}" || warn "Kernel purge had issues."
    sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
  else
    info "No old kernels to purge."
  fi
}

# -------- Tailscale repo + install ----------
install_tailscale_repo() {
  info "Installing Tailscale from official repo..."
  install_if_missing curl ca-certificates gnupg
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg" | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list" | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt_update
  install_if_missing tailscale
  sudo systemctl enable --now tailscaled || true
}

# -------- Trayscale install (non-Flatpak) ----------
install_trayscale_noflatpak() {
  info "Installing Trayscale (build from source via Go, no Flatpak)..."
  install_if_missing git build-essential pkg-config golang-go libgtk-4-dev libadwaita-1-dev
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/go"

  export GOPATH="$HOME/.local/share/go"
  export GOBIN="$HOME/.local/bin"

  # Build/install
  "$HOME/.local/bin/go" version >/dev/null 2>&1 || true
  go install github.com/DeedleFake/trayscale@latest

  if [[ -x "$HOME/.local/bin/trayscale" ]]; then
    info "Trayscale installed to $HOME/.local/bin/trayscale"
    cat > "$HOME/.local/share/applications/trayscale.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Trayscale
Exec=$HOME/.local/bin/trayscale
Terminal=false
Categories=Network;Utility;
EOF
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
  else
    warn "Trayscale build did not produce an executable; check Go/GTK build dependencies."
  fi
}

# -------- VSCodium repo + install ----------
install_vscodium_repo() {
  info "Installing VSCodium (repo-based)..."
  install_if_missing wget ca-certificates gnupg
  sudo mkdir -p /usr/share/keyrings
  wget -qO- https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/vscodium-archive-keyring.gpg >/dev/null

  echo "deb [ signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg ] https://download.vscodium.com/debs vscodium main" \
    | sudo tee /etc/apt/sources.list.d/vscodium.list >/dev/null

  apt_update
  install_if_missing codium
}

# -------- VS Code install (official .deb endpoint) ----------
install_vscode_deb() {
  info "Installing Visual Studio Code (official .deb)..."
  install_if_missing curl gpg
  local tmp="/tmp/vscode.deb"

  # Primary endpoint
  if ! curl -fL "https://update.code.visualstudio.com/latest/linux-deb-x64/stable" -o "$tmp"; then
    warn "Primary VS Code download failed; trying fallback URL..."
    curl -fL "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64" -o "$tmp"
  fi

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp" || sudo dpkg -i "$tmp" || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y || true
}

# -------- Google Chrome repo + install ----------
install_chrome_repo() {
  info "Installing Google Chrome (repo-based)..."
  install_if_missing curl ca-certificates gnupg
  sudo mkdir -p /usr/share/keyrings
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
    | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
  apt_update
  install_if_missing google-chrome-stable
}

# -------- Docker repo + install (fallback if trixie not present) ----------
install_docker_and_whaler() {
  info "Installing Docker Engine..."
  install_if_missing ca-certificates curl gnupg

  sudo install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  local arch suite
  arch="$(dpkg --print-architecture)"
  suite="${CODENAME:-trixie}"

  # If Docker repo doesn't publish this suite yet, fall back to bookworm
  if ! curl -fsI "https://download.docker.com/linux/debian/dists/${suite}/Release" >/dev/null; then
    warn "Docker repo does not appear to publish '${suite}' yet. Falling back to 'bookworm' suite."
    suite="bookworm"
  fi

  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${suite} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt_update

  install_if_missing docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo systemctl enable --now docker || true
  sudo usermod -aG docker "$USER" || true
  info "User '$USER' added to docker group (log out/in to take effect)."

  if ask_user "Install Whaler (Flatpak) GUI for Docker?"; then
    install_if_missing flatpak
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    flatpak install -y flathub com.github.sdv43.whaler || warn "Failed to install Whaler Flatpak."
  fi
}

# -------- ROCm (latest production per AMD docs; currently 7.1.1) ----------
install_rocm_latest_prod() {
  info "Installing ROCm (AMD repo; production version as per AMD docs)..."
  install_if_missing wget gpg ca-certificates

  sudo mkdir --parents --mode=0755 /etc/apt/keyrings
  wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg >/dev/null

  # Per AMD docs for Debian 13: ROCm apt + graphics repo (Ubuntu noble) and pinning
  sudo tee /etc/apt/sources.list.d/rocm.list >/dev/null <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.1.1 noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/7.1.1/ubuntu noble main
EOF

  sudo tee /etc/apt/preferences.d/rocm-pin-600 >/dev/null <<'EOF'
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

  apt_update
  install_if_missing rocm

  # Common permissions
  sudo usermod -aG render,video "$USER" || true
  info "User '$USER' added to render/video groups (log out/in to take effect)."
}

# -------- Microsoft core fonts (Debian way) ----------
install_microsoft_core_fonts() {
  info "Installing Microsoft core fonts (ttf-mscorefonts-installer)..."
  enable_contrib_nonfree
  apt_update

  install_if_missing debconf-utils
  echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | sudo debconf-set-selections

  install_if_missing ttf-mscorefonts-installer fontconfig
  sudo fc-cache -f -v || true
}

# -------- Extra fonts (Debian package names) ----------
install_extra_fonts() {
  info "Installing extra fonts..."
  local FONT_PACKAGES=(
    fonts-firacode
    fonts-jetbrains-mono
    fonts-roboto
    fonts-inter
    fonts-noto-core
    fonts-noto-mono
    fonts-noto-color-emoji
    fonts-liberation2
    fonts-dejavu
  )
  install_if_missing "${FONT_PACKAGES[@]}"

  # MesloLGS NF (powerlevel10k)
  sudo install -d /usr/local/share/fonts/meslo
  sudo wget -q -P /usr/local/share/fonts/meslo \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf || true

  sudo fc-cache -fv || true

  # Optional font rendering tweaks (user-level)
  mkdir -p "$HOME/.config/fontconfig"
  cat > "$HOME/.config/fontconfig/fonts.conf" <<'EOL'
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
}

# --------- Media codecs (Debian) ----------
install_media_codecs() {
  info "Installing media codecs..."
  enable_contrib_nonfree
  apt_update
  install_if_missing ffmpeg gstreamer1.0-libav gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly
}

# --------- Ollama (no Alpaca) ----------
install_ollama_only() {
  info "Installing Ollama..."
  local OLLAMA_BIN="/usr/local/bin/ollama"
  if [[ ! -x "$OLLAMA_BIN" ]]; then
    curl -fsSL https://ollama.com/install.sh -o /tmp/ollama-install.sh
    bash /tmp/ollama-install.sh || warn "Ollama installation failed"
  else
    info "Ollama already installed. Skipping..."
  fi
}

# --------- Flatpak bundle ----------
install_flatpaks() {
  info "Installing Flatpak apps from Flathub..."
  install_if_missing flatpak
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

  local FLATPAK_APPS=(
    com.mattjakeman.ExtensionManager
    io.github.realmazharhussain.GdmSettings
    io.github.flattool.Warehouse
    io.github.flattool.Ignition
    com.usebottles.bottles
    org.signal.Signal
    org.gnome.Firmware
    org.gnome.World.PikaBackup
    com.rustdesk.RustDesk
  )

  for app in "${FLATPAK_APPS[@]}"; do
    flatpak install -y flathub "$app" || warn "Failed to install $app"
  done
}

# --------- GNOME extensions (same logic as your script) ----------
install_gnome_extensions() {
  info "Installing GNOME Shell extensions..."
  install_if_missing jq unzip curl gnome-shell-extension-prefs gnome-shell-extensions

  # gnome-extensions CLI may be provided by gnome-shell-extension-prefs/gnome-shell
  if ! command -v gnome-extensions &>/dev/null; then
    warn "gnome-extensions CLI not found; skipping extension automation."
    return 0
  fi

  declare -A EXTENSIONS=(
    [6]="applications-menu@gnome-shell-extensions.gcampax.github.com"
    [19]="user-theme@gnome-shell-extensions.gcampax.github.com"
    [3628]="arcmenu@arcmenu.com"
    [3193]="blur-my-shell@aunetx"
    [6807]="system-monitor@paradoxxx.zero.gmail.com"
    [7]="drive-menu@gnome-shell-extensions.gcampax.github.com"
    [779]="clipboard-indicator@tudmotu.com"
    [1460]="Vitals@CoreCoding.com"
    [8]="places-menu@gnome-shell-extensions.gcampax.github.com"
    [1401]="bluetooth-quick-connect@bjarosze.gmail.com"
    [307]="dash-to-dock@micxgx.gmail.com"
    [2087]="ding@rastersoft.com"
  )

  local EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
  mkdir -p "$EXT_DIR"

  local SHELL_VERSION
  SHELL_VERSION="$(gnome-shell --version 2>/dev/null | awk '{print $3}')"
  if [[ -z "$SHELL_VERSION" ]]; then
    warn "Could not detect GNOME Shell version; skipping."
    return 0
  fi

  for ID in "${!EXTENSIONS[@]}"; do
    local UUID="${EXTENSIONS[$ID]}"
    info "Installing Extension ID $ID ($UUID)..."

    local EXT_INFO EXT_URL TMP_ZIP EXT_PATH
    EXT_INFO="$(curl -s "https://extensions.gnome.org/extension-info/?pk=$ID&shell_version=$SHELL_VERSION")"
    EXT_URL="$(echo "$EXT_INFO" | jq -r '.download_url')"

    if [[ -z "$EXT_URL" || "$EXT_URL" == "null" ]]; then
      warn "Skipping $UUID (not compatible or not found)."
      continue
    fi

    TMP_ZIP="/tmp/$UUID.zip"
    EXT_PATH="$EXT_DIR/$UUID"

    curl -L -o "$TMP_ZIP" "https://extensions.gnome.org$EXT_URL" || { warn "Download failed for $UUID"; continue; }
    unzip -o "$TMP_ZIP" -d "$EXT_PATH" >/dev/null || { warn "Unzip failed for $UUID"; rm -f "$TMP_ZIP"; continue; }
    rm -f "$TMP_ZIP"

    if [[ -d "$EXT_PATH/schemas" ]]; then
      glib-compile-schemas "$EXT_PATH/schemas" || true
    fi

    gnome-extensions enable "$UUID" || warn "Could not enable $UUID"
    info "Installed $UUID"
  done
}

# =========================
# Main
# =========================

clear
info "Starting Debian Workstation Setup (Debian 13 recommended)"
read -n1 -s -rp "Press any key to continue..."

sudo_keepalive

optimize_apt
enable_ssd_trim
change_hostname

info "Removing unwanted preinstalled applications (best-effort)..."
UNWANTED_PACKAGES=(evince rhythmbox gnome-tour simple-scan)
sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y "${UNWANTED_PACKAGES[@]}" 2>/dev/null || true
sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true

info "Updating system packages..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y

# Base packages
CORE_PACKAGES=(openssl curl ca-certificates fontconfig xfonts-utils gnupg lsb-release)
SECURITY_PACKAGES=(unattended-upgrades fail2ban rkhunter lynis)
TWEAK_PACKAGES=(gnome-color-manager)
PRODUCTIVITY_APPS=(filezilla dconf-editor)

install_if_missing "${CORE_PACKAGES[@]}"
install_if_missing "${SECURITY_PACKAGES[@]}"
install_if_missing "${TWEAK_PACKAGES[@]}"
install_if_missing "${PRODUCTIVITY_APPS[@]}"

# Firmware tools
if ask_user "Update firmware (fwupd)?"; then
  install_if_missing fwupd
  sudo fwupdmgr refresh --force || true
  sudo fwupdmgr get-updates || true
  sudo fwupdmgr update || true
fi

# Cockpit
if ask_user "Install Cockpit (web-based system manager)?"; then
  install_if_missing cockpit
  sudo systemctl enable --now cockpit.socket || true
  info "Cockpit enabled. Access: https://localhost:9090"
fi

# GNOME Tweaks + UI
if ask_user "Install GNOME Tweaks and configure UI?"; then
  install_if_missing gnome-tweaks gnome-usage
  safe_gsettings_set org.gnome.desktop.interface enable-animations false
  safe_gsettings_set org.gtk.gtk4.Settings.FileChooser sort-directories-first true
  safe_gsettings_set org.gnome.desktop.wm.preferences button-layout ":minimize,maximize,close"
  safe_gsettings_set org.gnome.desktop.wm.keybindings switch-windows "['<Alt>Tab']"
  safe_gsettings_set org.gnome.desktop.wm.keybindings switch-applications "['<Super>Tab']"
  safe_gsettings_set org.gnome.nautilus.preferences show-hidden-files true
fi

# Greek keyboard user-level
if ask_user "Add Greek keyboard layout (GNOME user-level)?"; then
  add_greek_keyboard_userlevel
fi

# Enhance GNOME experience
if ask_user "Enhance GNOME experience (zsh, fzf, bat, ripgrep, etc.)?"; then
  install_if_missing zsh fzf bat ripgrep
fi

# LibreOffice languages
if ask_user "Install LibreOffice with English and Greek support?"; then
  install_if_missing libreoffice libreoffice-l10n-en-gb libreoffice-l10n-el
fi

# Design apps
if ask_user "Install design applications (GIMP, Inkscape)?"; then
  install_if_missing gimp inkscape
fi

# Flatpaks
if ask_user "Install Flatpak applications from Flathub?"; then
  install_flatpaks
fi

# GNOME extensions
if ask_user "Install GNOME Shell extensions (auto-download)?"; then
  install_gnome_extensions
fi

# Git + Gitg
if ask_user "Install Git and Gitg (apt)?"; then
  install_if_missing git gitg
fi

# VS Code
if ask_user "Install VS Code?"; then
  install_vscode_deb
fi

# VSCodium
if ask_user "Install VSCodium (repo-based)?"; then
  install_vscodium_repo
fi

# Google Chrome (separate)
if ask_user "Install Google Chrome (repo-based)?"; then
  install_chrome_repo
fi

# Tailscale + Trayscale (single option)
if ask_user "Install Tailscale + Trayscale (NO Flatpak for Trayscale)?"; then
  install_tailscale_repo
  install_trayscale_noflatpak

  # Optional: make user operator for safer non-root use
  if command -v tailscale &>/dev/null; then
    sudo tailscale set --operator="$USER" || true
    info "Tailscale operator set for $USER (if supported by your version)."
  fi
fi

# Docker + Whaler
if ask_user "Install Docker + (optional) Whaler GUI?"; then
  install_docker_and_whaler
fi

# Microsoft fonts + extra fonts (single “fonts” decision)
if ask_user "Install fonts (Microsoft core fonts + extra font stack)?"; then
  install_microsoft_core_fonts
  install_extra_fonts
fi

# Media codecs
if ask_user "Install media codecs (ffmpeg + gstreamer plugins)?"; then
  install_media_codecs
fi

# Ollama only (Alpaca removed)
if ask_user "Install Ollama (no Alpaca)?"; then
  install_ollama_only
fi

# ROCm latest production (per AMD docs)
if ask_user "Install ROCm (AMD repo; latest production per AMD docs)?"; then
  install_rocm_latest_prod
fi

# GRUB last booted OS
if ask_user "Configure GRUB to boot the last selected OS (GRUB_DEFAULT=saved)?"; then
  set_grub_last_booted
fi

# Keep only current kernel + 1 back
if ask_user "Purge old kernels and keep only current + 1 back?"; then
  purge_old_kernels_keep2
fi

# Final prompt
if ask_user "Setup completed. Reboot now?"; then
  info "Rebooting..."
  sleep 2
  reboot
else
  info "Reboot skipped."
fi
