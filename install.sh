#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Issei-177013/wingsbot-manager.git"
TARGET_DIR="/opt/wingsbot-manager"
BIN_LINK="/usr/local/bin/wingsbot-manager"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

echo "[*] Updating apt cache..."
apt-get update -y

# Use Ubuntu's docker.io + docker-compose-plugin; avoid containerd.io conflicts
echo "[*] Installing required packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git docker.io docker-compose-plugin curl ca-certificates

echo "[*] Enabling & starting Docker..."
systemctl enable --now docker || true

# Prepare target dir
if [[ -d "$TARGET_DIR/.git" ]]; then
  echo "[*] Updating existing repo at $TARGET_DIR"
  git -C "$TARGET_DIR" pull --ff-only || true
else
  echo "[*] Cloning repo to $TARGET_DIR"
  rm -rf "$TARGET_DIR"
  git clone "$REPO_URL" "$TARGET_DIR"
fi

# Detect CLI filename (with or without .sh)
CLI_PATH=""
if [[ -f "$TARGET_DIR/wingsbot-manager" ]]; then
  CLI_PATH="$TARGET_DIR/wingsbot-manager"
elif [[ -f "$TARGET_DIR/wingsbot-manager.sh" ]]; then
  CLI_PATH="$TARGET_DIR/wingsbot-manager.sh"
else
  echo "ERROR: CLI file not found (expected 'wingsbot-manager' or 'wingsbot-manager.sh')."
  exit 1
fi

chmod +x "$CLI_PATH"
ln -sf "$CLI_PATH" "$BIN_LINK"

echo
echo "Installed successfully."
echo "Run: wingsbot-manager"
echo
echo "If you want to run Docker without sudo:"
echo "  sudo usermod -aG docker $SUDO_USER 2>/dev/null || sudo usermod -aG docker $USER"
echo "  newgrp docker"