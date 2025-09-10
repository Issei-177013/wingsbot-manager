#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="/opt/wingsbot-manager"
BIN_LINK="/usr/local/bin/wingsbot-manager"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

rm -f "$BIN_LINK"
rm -rf "$TARGET_DIR"
echo "Uninstalled."