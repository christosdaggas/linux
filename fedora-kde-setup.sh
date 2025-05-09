
#!/bin/bash
set -x

# -------------------------------------------------
# Fedora Setup Script
# -------------------------------------------------

# -------------------------
# Sudo Credential Caching
# -------------------------
echo -e "\e[44m\e[1mPlease enter your sudo password to start the setup:\e[0m"
sudo -v || { echo "Error: Failed to obtain sudo privileges"; exit 1; }

while true; do
    sudo -v
    sleep 60
done &
SUDO_PID=$!
trap 'kill $SUDO_PID' EXIT

# -------------------------
# System Preparation
# -------------------------
sudo tee -a /etc/dnf/dnf.conf <<EOL
fastestmirror=True
max_parallel_downloads=10
deltarpm=True
keepcache=True
EOL

# -------------------------
# Change hostname
# -------------------------
echo -e "\e[44m\e[1mEnter new hostname:\e[0m"
read -r NEW_HOSTNAME
echo "Changing hostname to $NEW_HOSTNAME..."
sudo hostnamectl set-hostname "$NEW_HOSTNAME"
sudo sed -i "s/127.0.1.1.*/127.0.1.1   $NEW_HOSTNAME/" /etc/hosts
echo "Done! New hostname is $NEW_HOSTNAME"

# -------------------------
# Cleanup Unwanted Defaults
# -------------------------
sudo dnf update -y

# Enable RPM Fusion repositories
sudo dnf install -y \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Firmware updates
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update

# -------------------------
# System Utilities
# -------------------------
sudo dnf install -y openssl curl cabextract xorg-x11-font-utils fontconfig dnf5 dnf5-plugins glib2

# -------------------------
# Optional: Install Cockpit Web Console
# -------------------------
echo -e "\e[44m\e[1mDo you want to install Cockpit (web-based system manager)? [y/N]:\e[0m"
read -r INSTALL_COCKPIT
if [[ "$INSTALL_COCKPIT" =~ ^[Yy]$ ]]; then
  echo "Installing Cockpit..."
  sudo dnf install -y cockpit
  sudo systemctl enable --now cockpit.socket
  if systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --add-service=cockpit --permanent
    sudo firewall-cmd --reload
  fi
else
  echo "Skipping Cockpit installation."
fi

# -------------------------
# Optional: LibreOffice Suite
# -------------------------
echo -e "\e[44m\e[1mDo you want to install LibreOffice with English and Greek language support? [y/N]:\e[0m"
read -r INSTALL_LIBREOFFICE
if [[ "$INSTALL_LIBREOFFICE" =~ ^[Yy]$ ]]; then
  sudo dnf install -y libreoffice libreoffice-langpack-el libreoffice-langpack-en
else
  echo "Skipping LibreOffice installation."
fi

# -------------------------
# Optional: Media Applications
# -------------------------
echo -e "\e[44m\e[1mDo you want to install media applications (VLC, GIMP, Inkscape, Krita)? [y/N]:\e[0m"
read -r INSTALL_MEDIA_APPS
if [[ "$INSTALL_MEDIA_APPS" =~ ^[Yy]$ ]]; then
  sudo dnf install -y vlc gimp inkscape krita
else
  echo "Skipping media applications installation."
fi

# -------------------------
# KDE Animation Removal (if KDE is detected)
# -------------------------
if [[ "$XDG_CURRENT_DESKTOP" =~ KDE|PLASMA ]]; then
  echo -e "\e[42mDetected KDE Plasma environment. Disabling all animations...\e[0m"

  CONFIG_FILE="$HOME/.config/kwinrc"
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)"

  kwriteconfig5 --file kwinrc --group Compositing --key AnimationSpeed "0.0"
  kwriteconfig5 --file kwinrc --group Compositing --key Enabled "false"
  kwriteconfig5 --file kwinrc --group Plugins --key kwin4_effect_maximizeEnabled false
  kwriteconfig5 --file kwinrc --group Plugins --key kwin4_effect_fadeEnabled false
  kwriteconfig5 --file kwinrc --group Plugins --key kwin4_effect_dialogparentEnabled false
  kwriteconfig5 --file kwinrc --group Plugins --key kwin4_effect_loginEnabled false
  kwriteconfig5 --file kwinrc --group Plugins --key kwin4_effect_logoutEnabled false
  kwriteconfig5 --file kwinrc --group Plugins --key kwin4_effect_minimizeanimationEnabled false
  kwriteconfig5 --file kdeglobals --group KDE --key GraphicEffectsLevel "0"

  qdbus org.kde.KWin /KWin reconfigure
  kwin_x11 --replace & disown

  echo "✅ KDE animations disabled. Log out and back in for full effect."

  echo -e "\e[44m\e[1mApplying KDE advanced tweaks...\e[0m"
  kwriteconfig5 --file kwinrc --group Compositing --key LatencyPolicy "LowLatency"
  kwriteconfig5 --file kwinrc --group Plugins --key kwin4_effect_blurEnabled false
  kwriteconfig5 --file baloofilerc --group Basic\ Settings --key IndexingEnabled false
  balooctl disable
  kwriteconfig5 --file kdeglobals --group KDE --key SingleClick true
  kwriteconfig5 --file kwinrc --group Compositing --key AnimationSpeed "0.1"
  kwriteconfig5 --file kdeglobals --group General --key TerminalApplication alacritty
  kwriteconfig5 --file kscreenlockerrc --group NightColor --key Active true
  kwriteconfig5 --file kdeglobals --group RecentDocuments --key UseRecent false
  kwriteconfig5 --file klipperrc --group General --key SaveHistory false
  kwriteconfig5 --file klipperrc --group General --key KeepClipboardContents false
  lookandfeeltool -a org.kde.breezedark.desktop || echo "Breeze Dark not available"
  qdbus org.kde.KWin /KWin reconfigure
else
  echo "Skipping KDE tweaks (non-KDE environment)."
fi

# -------------------------
# Optional: AI Tools - Ollama
# -------------------------
echo -e "\e[44m\e[1mDo you want to install Ollama (Alpaca GUI will be installed automatically)? [y/N]:\e[0m"
read -r INSTALL_OLLAMA_CHOICE
if [[ "$INSTALL_OLLAMA_CHOICE" =~ ^[Yy]$ ]]; then
  curl -fsSL https://ollama.com/install.sh | sh
  flatpak install -y flathub com.jeffser.Alpaca
else
  echo "Skipping Ollama and Alpaca installation."
fi

# -------------------------
# Web & Code Tools
# -------------------------
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo tee /etc/yum.repos.d/vscode.repo <<EOL
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOL

sudo dnf check-update
sudo dnf install -y code
sudo dnf install -y fedora-workstation-repositories
sudo dnf config-manager --set-enabled google-chrome
sudo dnf install -y google-chrome-stable

# -------------------------
# Visual Enhancements
# -------------------------
sudo dnf install -y powerline-fonts
wget -P /usr/share/fonts/ \
  https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf \
  https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf \
  https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf \
  https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf
sudo fc-cache -vf

# -------------------------
# Media Codecs
# -------------------------
sudo dnf install -y libavcodec-freeworld

# -------------------------
# Fonts & Font Config
# -------------------------
sudo dnf copr enable --assumeyes atim/ubuntu-fonts
sudo dnf install -y \
  rsms-inter-fonts ubuntu-family-fonts \
  dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts \
  liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts \
  google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts \
  fira-code-fonts mozilla-fira-sans-fonts google-roboto-fonts jetbrains-mono-fonts

wget https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm -O /tmp/msfonts.rpm
sudo dnf install -y /tmp/msfonts.rpm

mkdir -p ~/.config/fontconfig
cat <<EOL > ~/.config/fontconfig/fonts.conf
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


# -------------------------
# KDE Panel Tweaks
# -------------------------
if [[ "$XDG_CURRENT_DESKTOP" =~ KDE|PLASMA ]]; then
  echo -e "\e[44m\e[1mTweaking KDE Panel (navigation bar)...\e[0m"

  PANEL_CONFIG="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"

  # Backup current config
  cp "$PANEL_CONFIG" "$PANEL_CONFIG.bak.$(date +%s)"

  # Force panel to bottom, no margin, always visible
  sed -i '/\[Containments\]\[.*\]\[General\]/,/^$/ {
    /location=/d
    /panelVisibility=/d
    a location=bottom\npanelVisibility=0
  }' "$PANEL_CONFIG"

  # Force margin to 0 and restore height to 35 for clean layout
  sed -i '/\[Containments\]\[.*\]\[General\]/,/^$/ {
    /thickness=/d
    a thickness=35
  }' "$PANEL_CONFIG"

  echo "KDE panel configured to bottom position, always visible, with no margin."

  # Restart plasmashell to apply changes
  killall plasmashell && kstart5 plasmashell &
else
  echo "Skipping KDE panel tweaks (non-KDE environment)."
fi

# -------------------------
# Final Reboot
# -------------------------
echo -e "\e[44m\e[1m✅ Fedora 41 setup completed. Reboot recommended. Reboot now? [y/N]:\e[0m"
read -r RESPONSE
if [[ "$RESPONSE" =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    sleep 2
    reboot
else
    echo "Reboot skipped."
fi
