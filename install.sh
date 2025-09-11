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

# Optional: upgrade packages before installation
# - Set APT_UPGRADE=1 to run "apt-get upgrade -y"
# - Or set APT_FULL_UPGRADE=1 to run "apt-get full-upgrade -y" (more invasive)
if [[ "${APT_FULL_UPGRADE:-0}" == "1" ]]; then
  echo "[*] Upgrading system packages (full-upgrade)..."
  DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
elif [[ "${APT_UPGRADE:-0}" == "1" ]]; then
  echo "[*] Upgrading system packages (upgrade)..."
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
fi

# Use Ubuntu's docker.io + docker-compose-plugin; avoid containerd.io conflicts on 24.04
echo "[*] Installing base packages (git, curl, ca-certificates, gnupg)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git curl ca-certificates gnupg

# Try Ubuntu's docker.io first
if ! command -v docker >/dev/null 2>&1; then
  echo "[*] Installing docker.io from Ubuntu repo..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io || true
fi

# Try to get docker compose plugin from Ubuntu repo
if ! docker compose version >/dev/null 2>&1; then
  echo "[*] Installing docker-compose-plugin from Ubuntu repo..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || true
fi

# If compose plugin still missing, set up official Docker repo and install CE + plugins
if ! docker compose version >/dev/null 2>&1; then
  echo "[*] docker-compose-plugin not found. Setting up official Docker APT repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck source=/etc/os-release
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  echo "[*] Updating apt cache (Docker repo)..."
  apt-get update -y

  if command -v docker >/dev/null 2>&1; then
    echo "[*] Installing compose/buildx plugins from Docker repo..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-buildx-plugin docker-compose-plugin
  else
    echo "[*] Installing docker-ce and compose plugin from Docker repo..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
fi

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
