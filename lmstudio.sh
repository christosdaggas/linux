#!/bin/bash
set -e

# -------------------------
# Configuration
# -------------------------
APPIMAGE_URL="https://installers.lmstudio.ai/linux/x64/0.3.36-1/LM-Studio-0.3.36-1-x64.AppImage"
APPIMAGE_NAME="LM-Studio-0.3.36-1-x64.AppImage"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons"
EXTRACT_DIR="$HOME/.local/share/lmstudio-extract"
DESKTOP_FILE="lmstudio.desktop"
ICON_PATH="$ICON_DIR/lm-studio.png"

# -------------------------
# Create folders
# -------------------------
echo "📁 Creating directories..."
mkdir -p "$BIN_DIR" "$APP_DIR" "$ICON_DIR" "$EXTRACT_DIR"

# -------------------------
# Download AppImage
# -------------------------
echo "⬇️ Downloading LM Studio..."
curl -L "$APPIMAGE_URL" -o "$BIN_DIR/$APPIMAGE_NAME"
chmod +x "$BIN_DIR/$APPIMAGE_NAME"

# -------------------------
# Extract icon
# -------------------------
echo "🧨 Extracting AppImage to find icon..."
cd "$EXTRACT_DIR"
"$BIN_DIR/$APPIMAGE_NAME" --appimage-extract > /dev/null

ICON_SOURCE=$(find "$EXTRACT_DIR/squashfs-root" -name "lm-studio.png" | head -n 1)

if [[ -n "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$ICON_PATH"
  echo "🖼️ Icon saved to $ICON_PATH"
else
  echo "⚠️ Icon not found in AppImage. Will use fallback."
  ICON_PATH="utilities-terminal"
fi

# -------------------------
# Write .desktop file
# -------------------------
echo "📝 Creating launcher..."
cat > "$APP_DIR/$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=LM Studio
Exec=env APPIMAGE_EXTRACT_AND_RUN=1 bash -c "$BIN_DIR/$APPIMAGE_NAME"
Icon=$ICON_PATH
Type=Application
Categories=Development;Utility;
Comment=LM Studio - Local AI chat and development tool
Terminal=false
EOF

# -------------------------
# Update desktop database
# -------------------------
echo "🔄 Updating desktop database..."
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database "$APP_DIR"
else
  echo "⚠️ desktop-file-utils not installed. Install it with: sudo dnf install desktop-file-utils"
fi

# -------------------------
# Done
# -------------------------
echo "✅ LM Studio installed with working launcher and icon."
echo "🚀 Find it in GNOME Activities menu. If it still doesn't launch, try running:"
echo ""
echo "   env APPIMAGE_EXTRACT_AND_RUN=1 $BIN_DIR/$APPIMAGE_NAME"
echo ""
