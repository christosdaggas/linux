#!/bin/bash
set -x

# -------------------------------------------------
# Fedora Setup Script
# -------------------------------------------------

#
# -------------------------
# System Preparation
# -------------------------

# Configure DNF for performance and caching
sudo tee -a /etc/dnf/dnf.conf <<EOL
fastestmirror=True
max_parallel_downloads=10
deltarpm=True
keepcache=True
EOL

# -------------------------
# Change hostname
# -------------------------
read -p "Enter new hostname: " NEW_HOSTNAME
echo "Changing hostname to $NEW_HOSTNAME..."
sudo hostnamectl set-hostname "$NEW_HOSTNAME"
sudo sed -i "s/127.0.1.1.*/127.0.1.1   $NEW_HOSTNAME/" /etc/hosts
echo "Done! New hostname is $NEW_HOSTNAME"

# -------------------------
# Cleanup Unwanted Defaults
# -------------------------
sudo dnf remove -y evince rhythmbox abrt gnome-tour mediawriter
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
sudo dnf install -y openssl curl cabextract xorg-x11-font-utils fontconfig dnf5 dnf5-plugins

# Enable snap support
# sudo dnf install -y snapd
# sudo ln -s /var/lib/snapd/snap /snap

# -------------------------
# Optional: Install Cockpit Web Console
# -------------------------
read -p "Do you want to install Cockpit (web-based system manager)? [y/N]: " INSTALL_COCKPIT

if [[ "$INSTALL_COCKPIT" =~ ^[Yy]$ ]]; then
  echo "Installing Cockpit..."
  sudo bash <<'EOF'
  dnf install -y cockpit
  systemctl enable --now cockpit.socket
  # Check if firewalld is active and allow Cockpit through it
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --add-service=cockpit --permanent
    firewall-cmd --reload
  fi
  echo "Cockpit installation complete. You can access it at https://localhost:9090"
EOF
else
  echo "Skipping Cockpit installation."
fi


# -------------------------
# GNOME Tweaks & Behavior
# -------------------------
sudo dnf install -y gnome-tweaks gnome-extensions-app gnome-calendar gnome-usage
# GTK4 file chooser tweak and behavior tweaks
gsettings set org.gtk.gtk4.Settings.FileChooser sort-directories-first true
gsettings set org.gnome.desktop.wm.preferences button-layout ":minimize,maximize,close"
gsettings set org.gnome.desktop.wm.keybindings switch-windows "['<Alt>Tab']"
gsettings set org.gnome.desktop.wm.keybindings switch-applications "['<Super>Tab']"
gsettings set org.gnome.desktop.wm.keybindings switch-windows-backward "['<Shift><Alt>Tab']"
gsettings set org.gnome.desktop.wm.keybindings switch-applications-backward "['<Shift><Super>Tab']"
gsettings set org.gnome.nautilus.preferences recursive-search 'never'
gsettings set org.gnome.desktop.wm.preferences resize-with-right-button true

# -------------------------
# Productivity Applications
# -------------------------
sudo dnf install -y thunderbird filezilla flatseal decibels dconf-editor meld

# -------------------------
# Optional: LibreOffice Suite (with Greek language support)
# -------------------------
read -p "Do you want to install LibreOffice with English and Greek language support? [y/N]: " INSTALL_LIBREOFFICE
if [[ "$INSTALL_LIBREOFFICE" =~ ^[Yy]$ ]]; then
  echo "Installing LibreOffice and Greek language pack..."
  sudo dnf install -y libreoffice libreoffice-langpack-el libreoffice-langpack-en
else
  echo "Skipping LibreOffice installation."
fi

# -------------------------
# Optional: Media Applications
# -------------------------
read -p "Do you want to install media applications (VLC, GIMP, Inkscape, Krita)? [y/N]: " INSTALL_MEDIA_APPS
if [[ "$INSTALL_MEDIA_APPS" =~ ^[Yy]$ ]]; then
  sudo dnf install -y vlc gimp inkscape krita
else
  echo "Skipping media applications installation."
fi

# -------------------------
# Optional: Applications
# -------------------------
flatpak install -y flathub com.mattjakeman.ExtensionManager
flatpak install -y flathub io.github.realmazharhussain.GdmSettings
flatpak install -y flathub work.openpaper.Paperwork
flatpak install -y flathub org.gnome.World.PikaBackup
flatpak install -y flathub com.rafaelmardojai.Blanket
flatpak install -y flathub io.github.nokse22.Exhibit
flatpak install -y flathub io.gitlab.news_flash.NewsFlash
flatpak install -y flathub nl.emphisia.icon
flatpak install -y flathub org.nickvision.money
flatpak install -y flathub org.signal.Signal

# -------------------------
# Optional: AI Tools - Ollama (installs Alpaca GUI automatically)
# -------------------------
read -p "Do you want to install Ollama (Alpaca GUI will be installed automatically)? [y/N]: " INSTALL_OLLAMA_CHOICE
if [[ "$INSTALL_OLLAMA_CHOICE" =~ ^[Yy]$ ]]; then
  echo "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
  echo "Installing Alpaca (Flatpak GUI)..."
  flatpak install -y flathub com.jeffser.Alpaca
else
  echo "Skipping Ollama and Alpaca installation."
fi

# -------------------------
# Web & Code Tools
# -------------------------
# Visual Studio Code
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

# Google Chrome
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
sudo dnf install libavcodec-freeworld

# -------------------------
# Fonts & Font Config (Moved to End)
# -------------------------

# Enable Ubuntu fonts COPR
sudo dnf copr enable --assumeyes atim/ubuntu-fonts

# Install various fonts
sudo dnf install -y \
  rsms-inter-fonts \
  ubuntu-family-fonts \
  dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts \
  liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts \
  google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts \
  fira-code-fonts mozilla-fira-sans-fonts google-roboto-fonts \
  jetbrains-mono-fonts

# Microsoft Core Fonts
wget https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm -O /tmp/msfonts.rpm
sudo dnf install -y /tmp/msfonts.rpm

# Optional fontconfig tuning
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

echo "✅ Fedora 41 setup completed. Reboot recommended."
read -rp "Do you want to reboot now? [y/N]: " RESPONSE
if [[ "$RESPONSE" =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    sleep 2
    reboot
else
    echo "Reboot skipped."
fi
