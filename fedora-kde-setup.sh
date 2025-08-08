#!/usr/bin/env bash
set -euo pipefail

echo "=== Fedora KDE Ultimate Setup ==="

# ==================================================
# 0. CONFIG
# ==================================================
COLOR_SCHEME="BreezeDark"
ICON_THEME="breeze-dark"
CURSOR_THEME="Breeze_Snow"
UI_FONT="Noto Sans,10,-1,5,50,0,0,0,0,0"
MONO_FONT="JetBrains Mono,10,-1,5,50,0,0,0,0,0"
TERMINAL_PROFILE_NAME="CleanDark"
TERMINAL_FONT="JetBrains Mono 11"
DEFAULT_LANG="en_US.UTF-8"    # Change to el_GR.UTF-8 for full Greek UI
XKB_LAYOUTS="us,gr"
XKB_OPTIONS="grp:alt_shift_toggle"

KWRITE="$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)"
KQUIT="$(command -v kquitapp6 || command -v kquitapp5 || true)"
KSTART="$(command -v kstart6 || command -v kstart5 || true)"

# ==================================================
# 1. DNF OPTIMIZATION
# ==================================================
echo "[1] Optimizing DNF..."
sudo tee -a /etc/dnf/dnf.conf <<EOL
fastestmirror=True
max_parallel_downloads=10
deltarpm=True
keepcache=True
EOL

# ==================================================
# 2. REMOVE KDE DEFAULT & EXTRA APPS
# ==================================================
echo "[2] Removing KDE & extra apps..."
REMOVE_PKGS=(
  akregator dragon juk kaddressbook kalarm kamera kcalc kcharselect kcolorchooser
  kdenlive khelpcenter kmail kmousetool knotes kolourpaint konversation korganizer
  krdc krfb ktnef skanlite sweeper gwenview elisa-player elisa okular kwrite
  kmahjongg kmines kpat plasma-welcome neochat kamoso qrca mediawriter
)
sudo dnf remove -y --noautoremove "${REMOVE_PKGS[@]}" 2>/dev/null || true
sudo dnf autoremove -y || true

# ==================================================
# 3. GREEK LANGUAGE SUPPORT
# ==================================================
echo "[3] Installing Greek language packs..."
sudo dnf install -y glibc-langpack-el langpacks-el \
  google-noto-sans-fonts google-noto-serif-fonts google-noto-mono-fonts \
  ibus ibus-gtk ibus-qt || true

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

# ==================================================
# 4. FONT RENDERING
# ==================================================
echo "[4] Optimizing font rendering..."
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

# ==================================================
# 5. KDE UI TWEAKS
# ==================================================
echo "[5] Applying KDE UI tweaks..."
if [[ -n "$KWRITE" ]]; then
  $KWRITE --file "$HOME/.config/kdeglobals" --group "General" --key "ColorScheme" "$COLOR_SCHEME"
  $KWRITE --file "$HOME/.config/kdeglobals" --group "Icons" --key "Theme" "$ICON_THEME"
  $KWRITE --file "$HOME/.config/kdeglobals" --group "General" --key "font" "$UI_FONT"
  $KWRITE --file "$HOME/.config/kdeglobals" --group "General" --key "fixed" "$MONO_FONT"
  $KWRITE --file "$HOME/.config/kdeglobals" --group "KDE" --key "SingleClick" "true"
fi
$KWRITE --file "$HOME/.config/dolphinrc" --group "General" --key "ShowFullPathInTitlebar" "true"
$KWRITE --file "$HOME/.config/dolphinrc" --group "General" --key "ShowHiddenFiles" "true"
$KWRITE --file "$HOME/.config/dolphinrc" --group "General" --key "PreviewsShown" "false"
$KWRITE --file "$HOME/.config/kwinrc" --group "Plugins" --key "blurEnabled" "true"
$KWRITE --file "$HOME/.config/kwinrc" --group "NightColor" --key "Active" "true"
$KWRITE --file "$HOME/.config/kwinrc" --group "NightColor" --key "Mode" "Automatic"
mkdir -p "$HOME/Pictures/Screenshots"
$KWRITE --file "$HOME/.config/spectaclerc" --group "General" --key "defaultSaveLocation" "$HOME/Pictures/Screenshots"
$KWRITE --file "$HOME/.config/spectaclerc" --group "General" --key "autoSaveImage" "true"
$KWRITE --file "$HOME/.config/spectaclerc" --group "General" --key "copyImageToClipboard" "true"

# ==================================================
# 6. PANEL TWEAKS
# ==================================================
echo "[6] Tweaking panel..."
PANEL_CFG="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
if [[ -f "$PANEL_CFG" ]]; then
  sed -i 's/plugin=org.kde.panel/position=bottom\nplugin=org.kde.panel/' "$PANEL_CFG"
  sed -i 's/thickness=.*/thickness=35/' "$PANEL_CFG"
  grep -q "floating=false" "$PANEL_CFG" || echo "floating=false" >> "$PANEL_CFG"
fi

# ==================================================
# 7. SPEED BOOST
# ==================================================
echo "[7] Disabling animations & indexing..."
$KWRITE --file "$HOME/.config/kwinrc" --group "Compositing" --key "AnimationsEnabled" "false"
$KWRITE --file "$HOME/.config/kdeglobals" --group "KDE" --key "GraphicEffectsLevel" "0"
balooctl disable || true
$KWRITE --file "$HOME/.config/baloofilerc" --group "Basic Settings" --key "Indexing-Enabled" "false"

# ==================================================
# 8. SECURITY
# ==================================================
echo "[8] Installing security tools..."
sudo dnf install -y fail2ban rkhunter lynis setools-console policycoreutils-python-utils
sudo systemctl enable --now firewalld
sudo firewall-cmd --set-default-zone=public
sudo dnf install -y dnf-automatic
sudo systemctl enable --now dnf-automatic.timer

# ==================================================
# 9. SYSTEM PERFORMANCE
# ==================================================
echo "[9] System tuning..."
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl --system
sudo dnf install -y zram-generator-defaults
sudo systemctl enable --now systemd-zram-setup@zram0
sudo systemctl enable --now fstrim.timer

# ==================================================
# 10. DEV & PRODUCTIVITY TOOLS
# ==================================================
echo "[10] Installing dev/productivity tools..."
sudo dnf install -y git curl vim htop ncdu unzip p7zip p7zip-plugins unrar \
  fwupd bash-completion flatpak

# ==================================================
# 11. MULTIMEDIA & RPM FUSION
# ==================================================
echo "[11] Enabling RPM Fusion & multimedia..."
sudo dnf install -y \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf groupinstall -y "Multimedia" "Sound and Video"
sudo dnf install -y ffmpeg-libs

# ==================================================
# 12. EXTRA SOFTWARE
# ==================================================
echo "[12] Installing VS Code..."
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
sudo dnf install -y code

echo "[12] Installing Google Chrome..."
sudo dnf install -y fedora-workstation-repositories
sudo dnf config-manager --set-enabled google-chrome
sudo dnf install -y google-chrome-stable


echo "[12] Installing Cockpit..."
sudo dnf install -y cockpit
sudo systemctl enable --now cockpit.socket

# ==================================================
# 13. DESKTOP SHORTCUTS
# ==================================================
echo "[13] Creating desktop shortcuts..."
mkdir -p ~/Desktop
cat > ~/Desktop/Home.desktop <<EOF
[Desktop Entry]
Name=Home
Type=Link
URL=file://$HOME
Icon=user-home
EOF
cat > ~/Desktop/User.desktop <<EOF
[Desktop Entry]
Name=User
Type=Link
URL=file:///usr
Icon=folder
EOF
chmod +x ~/Desktop/*.desktop

# ==================================================
# 14. RELOAD KDE
# ==================================================
echo "[14] Reloading KDE..."
qdbus org.kde.KWin /KWin reconfigure || true
if [[ -n "$KQUIT" ]]; then
  $KQUIT plasmashell || true
  [[ -n "$KSTART" ]] && ($KSTART plasmashell >/dev/null 2>&1 &) || true
fi

echo "=== Done. Reboot or log out/in for full effect. ==="
