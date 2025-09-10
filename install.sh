#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Issei-177013/wingsbot-manager.git"
TARGET_DIR="/opt/wingsbot-manager"
BIN_LINK="/usr/local/bin/wingsbot-manager"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use: sudo bash ...)"
  exit 1
fi

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y git docker.io docker-compose-plugin curl ca-certificates

systemctl enable --now docker || true

if [[ -d "$TARGET_DIR/.git" ]]; then
  echo "[*] Updating existing repo at $TARGET_DIR"
  git -C "$TARGET_DIR" pull --ff-only || true
else
  echo "[*] Cloning repo to $TARGET_DIR"
  rm -rf "$TARGET_DIR"
  git clone "$REPO_URL" "$TARGET_DIR"
fi

chmod +x "$TARGET_DIR/wingsbot-manager"
ln -sf "$TARGET_DIR/wingsbot-manager" "$BIN_LINK"

echo
echo "Installed. Run:"
echo "  wingsbot-manager"