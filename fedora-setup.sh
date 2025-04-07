
# -------------------------------------------------
# Fedora 41 Setup Script (Grouped, Cleaned, Final)
# -------------------------------------------------
#

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
# Cleanup Unwanted Defaults
# -------------------------
sudo dnf remove -y evince rhythmbox abrt gnome-tour mediawriter

sudo dnf update -y

# Enable RPM Fusion repositories
sudo dnf install -y \\
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \\
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Firmware updates
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update

# -------------------------
# System Utilities
# -------------------------
sudo dnf install -y openssl curl cabextract xorg-x11-font-utils fontconfig snapd dnf5 dnf5-plugins

# Enable snap support
sudo ln -s /var/lib/snapd/snap /snap

# Install Timeshift via DNF5
sudo dnf5 install -y timeshift

# -------------------------
# GNOME Tweaks & Behavior
# -------------------------
sudo dnf install -y gnome-tweaks gnome-extensions-app gnome-calendar gnome-usage

# Install better Font Familys
sudo dnf install rsms-inter-fonts
sudo dnf copr enable atim/ubuntu-fonts
sudo dnf install ubuntu-family-fonts
#gsettings set org.gnome.desktop.interface font-name 'Ubuntu'
#gsettings set org.gnome.desktop.interface document-font-name 'Ubuntu'
#gsettings set org.gnome.desktop.interface monospace-font-name 'Ubuntu'

# Install Better Developer Fonts
sudo dnf install fira-code-fonts dejavu-sans-mono-fonts jetbrains-mono-fonts

# GTK4 file chooser tweak
gsettings set org.gtk.gtk4.Settings.FileChooser sort-directories-first true

# GNOME behavior tweaks
gsettings set org.gnome.desktop.wm.preferences button-layout ":minimize,maximize,close"
gsettings set org.gnome.desktop.wm.keybindings switch-windows "['<Alt>Tab']"
gsettings set org.gnome.desktop.wm.keybindings switch-applications "['<Super>Tab']"
gsettings set org.gnome.desktop.wm.keybindings switch-windows-backward "['<Shift><Alt>Tab']"
gsettings set org.gnome.desktop.wm.keybindings switch-applications-backward "['<Shift><Super>Tab']"
gsettings set org.gnome.nautilus.preferences recursive-search 'never'
gsettings set org.gnome.desktop.wm.preferences resize-with-right-button true

# -------------------------
# Fonts & Font Config
# -------------------------
sudo dnf install -y \\
  dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts \\
  liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts \\
  google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts \\
  fira-code-fonts 'mozilla-fira*' 'google-roboto*'

# Microsoft Core Fonts
sudo rpm -i https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm

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

# -------------------------
# Productivity Applications
# -------------------------
sudo dnf install -y thunderbird filezilla flatseal

flatpak install -y flathub com.microsoft.AzureStorageExplorer
flatpak install -y flathub org.gnome.Secrets
flatpak install -y flathub io.bassi.Amberol
flatpak install -y flathub org.gnome.World.PikaBackup
flatpak install -y flathub com.rafaelmardojai.Blanket
flatpak install -y flathub com.github.diegoinacio.Iconic

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
wget -P /usr/share/fonts/ \\
  https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf \\
  https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf \\
  https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf \\
  https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf
sudo fc-cache -vf


echo "✅ Fedora 41 setup completed. Reboot recommended."
