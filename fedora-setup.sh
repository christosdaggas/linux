#!/bin/bash
set -x

# -------------------------------------------------
# Fedora 41 Setup Script
# -------------------------------------------------

# -------------------------
# Introduction & Options
# -------------------------
cat <<'EOF'

This script will assist you in setting up your Fedora 41+ workstation:
  • Configure DNF for faster downloads & caching
  • Change your system hostname
  • Remove unwanted default apps and enable RPM Fusion repos
  • Update firmware
  • Install core system utilities
  • Optional installs (you will be prompted):
      – Cockpit web console
      – GNOME Tweaks & behavior settings
      – Productivity apps (Thunderbird, FileZilla, etc.)
      – LibreOffice with EN/EL support
      – Media applications (VLC, GIMP, Inkscape, Krita)
      – Flatpak applications from Flathub
      – AI tools: Ollama & Alpaca GUI
      – Web & Coding Tools (VS Code, Chrome)
      – Android Studio
      – Extra fonts (Powerline, Noto, Fira, JetBrains Mono, etc.)
      – Media codecs (libavcodec-freeworld)
      – GNOME Shell extensions (Dash to Dock, ArcMenu, etc.)
      – ClamAV antivirus & ClamTk GUI
  • Final reboot prompt

Press any key to continue or Ctrl+C to abort...
EOF
read -n1 -s

# -------------------------
# Sudo Credential Caching
# -------------------------
echo -e "\e[44m\e[1mPlease enter your sudo password to start the setup:\e[0m"
sudo -v || { echo "Error: Failed to obtain sudo privileges"; exit 1; }
while true; do sudo -v; sleep 60; done &
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
# Enable SSD trimmer
# -------------------------
sudo systemctl enable --now fstrim.timer

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
sudo dnf remove -y evince rhythmbox abrt gnome-tour mediawriter
sudo dnf update -y

# -------------------------
# Enable RPM Fusion repositories
# -------------------------
sudo dnf install -y \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# -------------------------
# Firmware updates
# -------------------------
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update

# -------------------------
# System Utilities
# -------------------------
sudo dnf install -y openssl curl cabextract xorg-x11-font-utils fontconfig dnf5 dnf5-plugins glib2

# -------------------------
# Optional: Cockpit Web Console
# -------------------------
echo -e "\e[44m\e[1mDo you want to install Cockpit (web-based system manager)? [y/N]:\e[0m"
read -r INSTALL_COCKPIT
if [[ "$INSTALL_COCKPIT" =~ ^[Yy]$ ]]; then
  echo "Installing Cockpit..."
  sudo bash <<'EOF'
dnf install -y cockpit
systemctl enable --now cockpit.socket
if systemctl is-active --quiet firewalld; then
  firewall-cmd --add-service=cockpit --permanent
  firewall-cmd --reload
fi
echo "Cockpit installation complete. Access at https://localhost:9090"
EOF
else
  echo "Skipping Cockpit installation."
fi

# -------------------------
# Optional: GNOME Tweaks & Behavior
# -------------------------
echo -e "\e[44m\e[1mDo you want to configure GNOME Tweaks & Behavior? [y/N]:\e[0m"
read -r INSTALL_GNOME_TWEAKS
if [[ "$INSTALL_GNOME_TWEAKS" =~ ^[Yy]$ ]]; then
  echo "Installing and configuring GNOME Tweaks..."
  sudo dnf install -y gnome-tweaks gnome-extensions-app gnome-calendar gnome-usage
  gsettings set org.gtk.gtk4.Settings.FileChooser sort-directories-first true
  gsettings set org.gnome.desktop.wm.preferences button-layout ":minimize,maximize,close"
  gsettings set org.gnome.desktop.wm.keybindings switch-windows "['<Alt>Tab']"
  gsettings set org.gnome.desktop.wm.keybindings switch-applications "['<Super>Tab']"
  gsettings set org.gnome.desktop.wm.keybindings switch-windows-backward "['<Shift><Alt>Tab']"
  gsettings set org.gnome.desktop.wm.keybindings switch-applications-backward "['<Shift><Super>Tab']"
  gsettings set org.gnome.nautilus.preferences recursive-search 'never'
  gsettings set org.gnome.desktop.wm.preferences resize-with-right-button true
else
  echo "Skipping GNOME Tweaks & Behavior."
fi

# -------------------------
# Productivity Applications
# -------------------------
sudo dnf install -y thunderbird filezilla flatseal decibels dconf-editor papers

# -------------------------
# Optional: LibreOffice Suite
# -------------------------
echo -e "\e[44m\e[1mDo you want to install LibreOffice with English and Greek support? [y/N]:\e[0m"
read -r INSTALL_LIBREOFFICE
if [[ "$INSTALL_LIBREOFFICE" =~ ^[Yy]$ ]]; then
  echo "Installing LibreOffice..."
  sudo dnf install -y libreoffice libreoffice-langpack-el libreoffice-langpack-en
else
  echo "Skipping LibreOffice."
fi

# -------------------------
# Optional: Media Applications
# -------------------------
echo -e "\e[44m\e[1mDo you want to install media applications (VLC, GIMP, Inkscape, Krita)? [y/N]:\e[0m"
read -r INSTALL_MEDIA_APPS
if [[ "$INSTALL_MEDIA_APPS" =~ ^[Yy]$ ]]; then
  sudo dnf install -y vlc gimp inkscape krita
else
  echo "Skipping media applications."
fi

# -------------------------
# Optional: Applications (Flatpak)
# -------------------------
echo -e "\e[44m\e[1mDo you want to install Flatpak applications from Flathub? [y/N]:\e[0m"
read -r INSTALL_FLATPAK_APPS
if [[ "$INSTALL_FLATPAK_APPS" =~ ^[Yy]$ ]]; then
  flatpak install -y flathub \
    com.mattjakeman.ExtensionManager \
    io.github.realmazharhussain.GdmSettings \
    io.github.flattool.Warehouse \
    org.gustavoperedo.FontDownloader \
    com.usebottles.bottles \
    org.gnome.Firmware \
    org.gnome.Calls \
    org.gnome.World.PikaBackup \
    io.github.nokse22.Exhibit \
    io.gitlab.news_flash.NewsFlash \
    org.nickvision.money \
    org.signal.Signal \
    md.obsidian.Obsidian \
    org.gnome.Papers
else
  echo "Skipping Flatpak applications."
fi

# -------------------------
# Optional: GNOME Shell Extensions
# -------------------------
echo -e "\e[44m\e[1mDo you want to install GNOME Shell extensions? [y/N]:\e[0m"
read -r INSTALL_EXTENSIONS
if [[ "$INSTALL_EXTENSIONS" =~ ^[Yy]$ ]]; then
  sudo dnf install -y jq curl unzip gnome-extensions gnome-shell-extension-prefs
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
  )
  EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
  mkdir -p "$EXT_DIR"
  SHELL_VERSION=$(gnome-shell --version | awk '{print $3}')
  for ID in "${!EXTENSIONS[@]}"; do
    UUID="${EXTENSIONS[$ID]}"
    echo -e "\u27A1\uFE0F Installing Extension ID $ID ($UUID)..."
    EXT_INFO=$(curl -s "https://extensions.gnome.org/extension-info/?pk=$ID&shell_version=$SHELL_VERSION")
    EXT_URL=$(echo "$EXT_INFO" | jq -r '.download_url')
    if [[ -z "$EXT_URL" || "$EXT_URL" == "null" ]]; then
      echo -e "\u274C Skipping $UUID (not compatible or not found)."
      continue
    fi
    TMP_ZIP="/tmp/$UUID.zip"
    EXT_PATH="$EXT_DIR/$UUID"
    curl -L -o "$TMP_ZIP" "https://extensions.gnome.org$EXT_URL"
    unzip -o "$TMP_ZIP" -d "$EXT_PATH"
    rm "$TMP_ZIP"
    if [ -d "$EXT_PATH/schemas" ]; then glib-compile-schemas "$EXT_PATH/schemas"; fi
    gnome-extensions enable "$UUID" || echo -e "\u26A0\uFE0F Could not enable $UUID"
    echo -e "\u2705 Installed and enabled $UUID"
  done
else
  echo "Skipping GNOME Shell extensions."
fi

# -------------------------
# Optional: AI Tools – Ollama
# -------------------------
echo -e "\e[44m\e[1mDo you want to install Ollama (and Alpaca GUI)? [y/N]:\e[0m"
read -r INSTALL_OLLAMA
if [[ "$INSTALL_OLLAMA" =~ ^[Yy]$ ]]; then
  curl -fsSL https://ollama.com/install.sh | sh
  flatpak install -y flathub com.jeffser.Alpaca
else
  echo "Skipping Ollama & Alpaca."
fi

# -------------------------
# Optional: Web & Coding Tools
# -------------------------
echo -e "\e[44m\e[1mDo you want to install Web & Coding Tools (VS Code & Chrome)? [y/N]:\e[0m"
read -r INSTALL_WEB_CODING
if [[ "$INSTALL_WEB_CODING" =~ ^[Yy]$ ]]; then
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
else
  echo "Skipping VS Code & Chrome."
fi

# -------------------------
# Optional: Android Studio
# -------------------------
echo -e "\e[44m\e[1mDo you want to install Android Studio? [y/N]:\e[0m"
read -r INSTALL_ANDROID_STUDIO
if [[ "$INSTALL_ANDROID_STUDIO" =~ ^[Yy]$ ]]; then
  flatpak install -y flathub com.google.AndroidStudio
else
  echo "Skipping Android Studio."
fi

# -------------------------
# Optional: Extra Fonts
# -------------------------
echo -e "\e[44m\e[1mDo you want to install extra fonts? [y/N]:\e[0m"
read -r INSTALL_EXTRA_FONTS
if [[ "$INSTALL_EXTRA_FONTS" =~ ^[Yy]$ ]]; then
  sudo dnf install -y powerline-fonts
  wget -P /usr/share/fonts/ \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf \
    https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf
  sudo fc-cache -fv
  sudo dnf copr enable --assumeyes atim/ubuntu-fonts
  sudo dnf install -y \
    rsms-inter-fonts \
    ubuntu-family-fonts \
    dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts \
    liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts \
    google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts \
    fira-code-fonts mozilla-fira-sans-fonts google-roboto-fonts \
    jetbrains-mono-fonts
  wget https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm \
    -O /tmp/msfonts.rpm
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
else
  echo "Skipping extra fonts."
fi

# -------------------------
# Optional: Media Codecs
# -------------------------
echo -e "\e[44m\e[1mDo you want to install media codecs? [y/N]:\e[0m"
read -r INSTALL_MEDIA_CODECS
if [[ "$INSTALL_MEDIA_CODECS" =~ ^[Yy]$ ]]; then
  sudo dnf install -y libavcodec-freeworld
else
  echo "Skipping media codecs."
fi

# -------------------------
# Optional: ClamAV Antivirus
# -------------------------
echo -e "\e[44m\e[1mDo you want to install ClamAV antivirus? [y/N]:\e[0m"
read -r INSTALL_CLAMAV
if [[ "$INSTALL_CLAMAV" =~ ^[Yy]$ ]]; then
  sudo dnf install -y clamav clamav-update
  sudo freshclam
  sudo systemctl enable --now clamav-freshclam
else
  echo "Skipping ClamAV."
fi

# -------------------------
# Optional: ClamTk GUI for ClamAV
# -------------------------
echo -e "\e[44m\e[1mDo you want to install ClamTk (GUI for ClamAV)? [y/N]:\e[0m"
read -r INSTALL_CLAMTK
if [[ "$INSTALL_CLAMTK" =~ ^[Yy]$ ]]; then
  sudo dnf install -y clamtk
else
  echo "Skipping ClamTk."
fi

# -------------------------
# Final Reboot
# -------------------------
echo -e "\e[44m\e[1m\u2705 Fedora 41 setup completed. Reboot recommended. Reboot now? [y/N]:\e[0m"
read -r RESPONSE
if [[ "$RESPONSE" =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    sleep 2
    reboot
else
    echo "Reboot skipped."
fi
