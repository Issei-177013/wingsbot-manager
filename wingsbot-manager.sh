#!/usr/bin/env bash
set -euo pipefail

# === Config ===
REPO_URL="https://github.com/Issei-177013/WINGSBOT.git"
# Resolve script directory even when invoked via symlink
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
MANAGER_ROOT="$(cd -P "$(dirname "$SOURCE")" && pwd)"
VENDOR_DIR="${MANAGER_ROOT}/vendor"
REPO_DIR="${VENDOR_DIR}/WINGSBOT"
BOTS_DIR="${MANAGER_ROOT}/bots"
DEFAULT_WEBHOOK_PORT="8080"   # internal port used only if USE_WEBHOOK=true (WINGSBOT default)
DEFAULT_EXPIRE_DAYS="0"        # 0 = no expiry
PORT_RANGE_START=10001
PORT_RANGE_END=19999

# === UI helpers ===
green(){ printf "\033[1;32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
red(){ printf "\033[1;31m%s\033[0m\n" "$*"; }
die(){ red "$*"; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

slugify(){ echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g;s/^-+//;s/-+$//'; }
now_epoch(){ date +%s; }
add_days_epoch(){ echo $(( $(date +%s) + ($1 * 86400) )); }
date_to_epoch(){ date -d "$1" +%s 2>/dev/null || echo 0; }
epoch_to_date(){ date -d "@$1" "+%Y-%m-%d %H:%M:%S"; }

ensure_dirs(){ mkdir -p "$BOTS_DIR" "$VENDOR_DIR"; }

ensure_repo(){
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    green "Cloning ${REPO_URL} -> ${REPO_DIR}"
    git clone "$REPO_URL" "$REPO_DIR"
  else
    green "Updating repo at ${REPO_DIR}"
    (cd "$REPO_DIR" && git pull --ff-only) || yellow "Git pull failed, continuing with existing repo."
  fi
}

compose_cmd(){
  if docker buildx version >/dev/null 2>&1; then
    docker compose "$@"
  else
    COMPOSE_DOCKER_CLI_BUILD=0 DOCKER_BUILDKIT=0 docker compose "$@"
  fi
}
container_running(){ local name="$1"; docker ps --format '{{.Names}}' | grep -Fxq "$name"; }

pick_free_port(){
  local used
  if command -v ss >/dev/null 2>&1; then
    used="$(
      { docker ps --format '{{.Ports}}' | tr ',' '\n' | sed -En 's/.*:([0-9]+)->.*/\1/p'; \
        ss -tuln | awk 'NR>1{split($5,a,":"); print a[length(a)]}'; } \
      | sort -u
    )"
  else
    used="$(
      docker ps --format '{{.Ports}}' | tr ',' '\n' | sed -En 's/.*:([0-9]+)->.*/\1/p' | sort -u
    )"
  fi
  for p in $(seq "$PORT_RANGE_START" "$PORT_RANGE_END"); do
    if ! grep -qx "$p" <<< "$used"; then echo "$p"; return 0; fi
  done
  return 1
}

# Regenerate compose and metadata from current .env and metadata
regen_compose(){
  local bot="$1"
  local dir="${BOTS_DIR}/${bot}"
  [[ -d "$dir" ]] || die "Bot not found: $bot"
  # shellcheck source=/dev/null
  source "$dir/.env" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$dir/metadata.env" 2>/dev/null || true

  local NAME_VAL="${NAME:-$bot}"
  local CREATED_VAL="${CREATED_AT:-$(now_epoch)}"
  local EXPIRES_VAL="${EXPIRES_AT:-0}"
  local HOST_PORT_VAL="${HOST_PORT:-}"
  local WEBHOOK_PORT_VAL="${WEBHOOK_PORT:-$DEFAULT_WEBHOOK_PORT}"
  local USE_WEBHOOK_VAL="${USE_WEBHOOK:-false}"

  cat > "$dir/metadata.env" <<EOF
NAME=${NAME_VAL}
CREATED_AT=${CREATED_VAL}
EXPIRES_AT=${EXPIRES_VAL}
HOST_PORT=${HOST_PORT_VAL}
WEBHOOK_PORT=${WEBHOOK_PORT_VAL}
EOF

  cat > "$dir/docker-compose.yml" <<EOF
services:
  wingsbot-${bot}:
    image: wingsbot-${bot}
    container_name: wingsbot-${bot}
    env_file: .env
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
$( [[ "${USE_WEBHOOK_VAL,,}" == "true" ]] && printf "    ports:\n      - \"%s:%s\"\n" "${HOST_PORT_VAL}" "${WEBHOOK_PORT_VAL}" )
EOF
}

compose_up(){
  local bot="$1"
  local dir="${BOTS_DIR}/${bot}"
  # Always prebuild with classic builder to avoid buildx path issues
  DOCKER_BUILDKIT=0 docker build -t "wingsbot-${bot}" "$REPO_DIR"
  (cd "$dir" && docker compose up -d --no-build)
}
compose_down(){
  local bot="$1"
  local dir="${BOTS_DIR}/${bot}"
  (cd "$dir" && compose_cmd down)
}

bot_exists(){ [[ -d "${BOTS_DIR}/$1" ]]; }
action_pause(){ read -rp "Press ENTER to continue..." _; }

# === Core commands ===
cmd_create(){
  ensure_dirs; ensure_repo
  local raw="${1:-}"; [[ -n "$raw" ]] || { read -rp "Bot name: " raw; }
  local BOT; BOT="$(slugify "$raw")"; [[ -n "$BOT" ]] || die "Invalid bot name"
  local DIR="${BOTS_DIR}/${BOT}"; [[ -d "$DIR" ]] && die "Bot '$BOT' already exists"

  echo "-- Environment --"
  read -rp "BOT_TOKEN: " BOT_TOKEN
  read -rp "ADMIN_ID (numeric): " ADMIN_ID
  read -rp "CHANNEL_ID (optional, e.g. @mychannel or -100...): " CHANNEL_ID
  read -rp "CHANNEL_USERNAME (optional, e.g. mychannel or @mychannel): " CHANNEL_USERNAME
  read -rp "USE_WEBHOOK? [false]: " USE_WEBHOOK; USE_WEBHOOK=${USE_WEBHOOK:-false}

  local HOST_PORT=""
  local WEBHOOK_PORT="$DEFAULT_WEBHOOK_PORT"
  local WEBHOOK_URL=""
  local WEBHOOK_SECRET=""

  if [[ "${USE_WEBHOOK,,}" == "true" ]]; then
    read -rp "WEBHOOK_URL (public base, e.g. https://example.com): " WEBHOOK_URL
    read -rp "WEBHOOK_PATH (optional, default token): " WEBHOOK_PATH
    read -rp "WEBHOOK_PORT [${DEFAULT_WEBHOOK_PORT}]: " tmp; WEBHOOK_PORT=${tmp:-$DEFAULT_WEBHOOK_PORT}
    read -rp "WEBHOOK_SECRET (optional): " WEBHOOK_SECRET
    read -rp "Auto-assign HOST_PORT? [Y/n]: " auto; auto=${auto:-Y}
    if [[ "${auto,,}" == "y" ]]; then
      HOST_PORT="$(pick_free_port)" || die "No free host ports in ${PORT_RANGE_START}-${PORT_RANGE_END}"
      green "Selected HOST_PORT: $HOST_PORT"
    else
      read -rp "HOST_PORT: " HOST_PORT
    fi
  fi

  read -rp "Expire in days [${DEFAULT_EXPIRE_DAYS}]: " EXPIRE_DAYS; EXPIRE_DAYS=${EXPIRE_DAYS:-$DEFAULT_EXPIRE_DAYS}
  local EXPIRES_AT="0"; if [[ "$EXPIRE_DAYS" =~ ^[0-9]+$ ]] && [[ "$EXPIRE_DAYS" -gt 0 ]]; then EXPIRES_AT="$(add_days_epoch "$EXPIRE_DAYS")"; fi

  mkdir -p "$DIR"/{data,logs}

  cat > "$DIR/.env" <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_ID=${ADMIN_ID}
CHANNEL_ID=${CHANNEL_ID}
CHANNEL_USERNAME=${CHANNEL_USERNAME}
USE_WEBHOOK=${USE_WEBHOOK}
WEBHOOK_LISTEN=0.0.0.0
WEBHOOK_PORT=${WEBHOOK_PORT}
WEBHOOK_PATH=${WEBHOOK_PATH}
WEBHOOK_URL=${WEBHOOK_URL}
WEBHOOK_SECRET=${WEBHOOK_SECRET}
DB_NAME=/app/data/bot.db
EOF
  chmod 600 "$DIR/.env"

  cat > "$DIR/metadata.env" <<EOF
NAME=${BOT}
CREATED_AT=$(now_epoch)
EXPIRES_AT=${EXPIRES_AT}
HOST_PORT=${HOST_PORT}
WEBHOOK_PORT=${WEBHOOK_PORT}
EOF

  cat > "$DIR/docker-compose.yml" <<EOF
services:
  wingsbot-${BOT}:
    image: wingsbot-${BOT}
    container_name: wingsbot-${BOT}
    env_file: .env
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
$( [[ "${USE_WEBHOOK,,}" == "true" ]] && printf "    ports:\n      - \"%s:%s\"\n" "${HOST_PORT}" "${WEBHOOK_PORT}" )
EOF

  if command -v id >/dev/null 2>&1; then sudo chown -R "$(id -u)":"$(id -g)" "$DIR" >/dev/null 2>&1 || true; fi
  compose_up "$BOT"
  green "Bot '${BOT}' is running."
  [[ "$EXPIRES_AT" != "0" ]] && echo "Expires at: $(epoch_to_date "$EXPIRES_AT")"
}

cmd_list(){
  ensure_dirs
  printf "%-20s %-10s %-20s %-10s %-10s\n" "NAME" "STATUS" "EXPIRES_AT" "HOST" "WPORT"
  for d in "${BOTS_DIR}"/*; do
    [[ -d "$d" ]] || continue
    local name
    name="$(basename "$d")"
    # shellcheck source=/dev/null
    source "$d/metadata.env" 2>/dev/null || true
    local status="stopped"; container_running "wingsbot-$name" && status="running"
    local exp="${EXPIRES_AT:-0}"
    [[ "${exp:-0}" -gt 0 ]] && exp="$(epoch_to_date "$exp")" || exp="-"
    printf "%-20s %-10s %-20s %-10s %-10s\n" "$name" "$status" "$exp" "${HOST_PORT:--}" "${WEBHOOK_PORT:--}"
  done
}

cmd_info(){ local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }; local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"; echo "# ${bot}"; echo "Path: ${dir}"; echo "- .env"; sed -n '1,200p' "${dir}/.env"; echo "- metadata"; sed -n '1,200p' "${dir}/metadata.env"; echo "- compose"; sed -n '1,200p' "${dir}/docker-compose.yml"; }
cmd_start(){
  local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }
  local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"
  # Prevent starting expired bots
  # shellcheck source=/dev/null
  source "${dir}/metadata.env" 2>/dev/null || true
  local now; now="$(now_epoch)"
  local exp="${EXPIRES_AT:-0}"
  if [[ "$exp" -gt 0 && "$now" -ge "$exp" ]]; then
    die "Bot '${bot}' is expired. Renew before starting."
  fi
  compose_up "$bot"
}
cmd_stop(){  local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }; compose_down "$bot"; }
cmd_restart(){
  local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }
  cmd_stop "$bot" || true
  cmd_start "$bot"
}
cmd_logs(){ local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }; (cd "${BOTS_DIR}/$bot" && compose_cmd logs -f); }

# Logs once (non-follow) for bots; useful for non-interactive callers
cmd_logs_once(){ local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }; (cd "${BOTS_DIR}/$bot" && compose_cmd logs --tail 200); }

cmd_rm(){ local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name to remove: " bot; }; local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"; compose_down "$bot" || true; rm -rf "$dir"; green "Removed bot '${bot}'."; }

# Edit a bot's configuration (.env, ports) and restart
cmd_edit(){
  local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name to edit: " bot; }
  local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"

  # Load current values
  # shellcheck source=/dev/null
  source "${dir}/.env" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "${dir}/metadata.env" 2>/dev/null || true

  echo "-- Edit config (leave blank to keep current) --"
  local v
  read -rp "BOT_TOKEN [${BOT_TOKEN:-}]: " v; BOT_TOKEN=${v:-${BOT_TOKEN:-}}
  read -rp "ADMIN_ID [${ADMIN_ID:-}]: " v; ADMIN_ID=${v:-${ADMIN_ID:-}}
  read -rp "CHANNEL_ID [${CHANNEL_ID:-}]: " v; CHANNEL_ID=${v:-${CHANNEL_ID:-}}
  read -rp "CHANNEL_USERNAME [${CHANNEL_USERNAME:-}]: " v; CHANNEL_USERNAME=${v:-${CHANNEL_USERNAME:-}}
  read -rp "USE_WEBHOOK [${USE_WEBHOOK:-false}]: " v; USE_WEBHOOK=${v:-${USE_WEBHOOK:-false}}; USE_WEBHOOK=${USE_WEBHOOK,,}

  local WEBHOOK_URL_NEW="${WEBHOOK_URL:-}"
  local WEBHOOK_PATH_NEW="${WEBHOOK_PATH:-}"
  local WEBHOOK_SECRET_NEW="${WEBHOOK_SECRET:-}"
  local WEBHOOK_PORT_NEW="${WEBHOOK_PORT:-$DEFAULT_WEBHOOK_PORT}"
  local HOST_PORT_NEW="${HOST_PORT:-}"

  if [[ "$USE_WEBHOOK" == "true" ]]; then
    read -rp "WEBHOOK_URL [${WEBHOOK_URL_NEW}]: " v; WEBHOOK_URL_NEW=${v:-$WEBHOOK_URL_NEW}
    read -rp "WEBHOOK_PATH [${WEBHOOK_PATH_NEW}]: " v; WEBHOOK_PATH_NEW=${v:-$WEBHOOK_PATH_NEW}
    read -rp "WEBHOOK_PORT [${WEBHOOK_PORT_NEW}]: " v; WEBHOOK_PORT_NEW=${v:-$WEBHOOK_PORT_NEW}
    read -rp "WEBHOOK_SECRET [${WEBHOOK_SECRET_NEW}]: " v; WEBHOOK_SECRET_NEW=${v:-$WEBHOOK_SECRET_NEW}
    read -rp "Auto-assign HOST_PORT? [Y/n] (current: ${HOST_PORT_NEW:-none}): " v; v=${v:-Y}
    if [[ "${v,,}" == "y" ]]; then
      HOST_PORT_NEW="$(pick_free_port)" || die "No free host ports in ${PORT_RANGE_START}-${PORT_RANGE_END}"
      green "Selected HOST_PORT: $HOST_PORT_NEW"
    else
      read -rp "HOST_PORT [${HOST_PORT_NEW}]: " v; HOST_PORT_NEW=${v:-$HOST_PORT_NEW}
    fi
  else
    HOST_PORT_NEW=""
  fi

  # Rewrite .env
  cat > "${dir}/.env" <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_ID=${ADMIN_ID}
CHANNEL_ID=${CHANNEL_ID}
CHANNEL_USERNAME=${CHANNEL_USERNAME}
USE_WEBHOOK=${USE_WEBHOOK}
WEBHOOK_LISTEN=0.0.0.0
WEBHOOK_PORT=${WEBHOOK_PORT_NEW}
WEBHOOK_PATH=${WEBHOOK_PATH_NEW}
WEBHOOK_URL=${WEBHOOK_URL_NEW}
WEBHOOK_SECRET=${WEBHOOK_SECRET_NEW}
DB_NAME=/app/data/bot.db
EOF
  chmod 600 "${dir}/.env"

  # Preserve NAME/CREATED_AT/EXPIRES_AT, update ports
  local NAME_VAL="${NAME:-$bot}"
  local CREATED_VAL="${CREATED_AT:-$(now_epoch)}"
  local EXPIRES_VAL="${EXPIRES_AT:-0}"
  cat > "${dir}/metadata.env" <<EOF
NAME=${NAME_VAL}
CREATED_AT=${CREATED_VAL}
EXPIRES_AT=${EXPIRES_VAL}
HOST_PORT=${HOST_PORT_NEW}
WEBHOOK_PORT=${WEBHOOK_PORT_NEW}
EOF

  # Rewrite compose
  cat > "${dir}/docker-compose.yml" <<EOF
services:
  wingsbot-${bot}:
    image: wingsbot-${bot}
    container_name: wingsbot-${bot}
    env_file: .env
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
$( [[ "$USE_WEBHOOK" == "true" ]] && printf "    ports:\n      - \"%s:%s\"\n" "${HOST_PORT_NEW}" "${WEBHOOK_PORT_NEW}" )
EOF

  if command -v id >/dev/null 2>&1; then sudo chown -R "$(id -u)":"$(id -g)" "$dir" >/dev/null 2>&1 || true; fi
  compose_down "$bot" || true
  compose_up "$bot"
  green "Bot '${bot}' updated and restarted."
}

cmd_set_expiry(){
  local bot="$1"; local val="${2:-}"
  [[ -n "$bot" && -n "$val" ]] || die "Usage: $0 set-expiry <bot> <days|YYYY-MM-DD|0|none>"
  local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"
  local epoch="0"
  case "${val,,}" in
    0|none|never) epoch=0 ;;
    *)
      if [[ "$val" =~ ^[0-9]+$ ]]; then
        if [[ "$val" -gt 0 ]]; then epoch="$(add_days_epoch "$val")"; else epoch=0; fi
      else
        epoch="$(date_to_epoch "$val")"
      fi
      ;;
  esac
  if [[ "$epoch" -gt 0 ]]; then
    sed -i -E "s/^EXPIRES_AT=.*/EXPIRES_AT=${epoch}/" "${dir}/metadata.env"
    green "Expiry set: $(epoch_to_date "$epoch")"
  else
    sed -i -E "s/^EXPIRES_AT=.*/EXPIRES_AT=0/" "${dir}/metadata.env"
    green "Expiry disabled (no expiry)."
  fi
}

cmd_renew(){
  local bot="$1"; local days="${2:-}"
  [[ -n "$bot" && -n "$days" ]] || die "Usage: $0 renew <bot> <days>"
  local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"
  # shellcheck source=/dev/null
  source "${dir}/metadata.env" 2>/dev/null || true
  local base="${EXPIRES_AT:-0}"
  [[ "$base" -lt "$(now_epoch)" ]] && base="$(now_epoch)"
  local new=$(( base + days*86400 ))
  sed -i -E "s/^EXPIRES_AT=.*/EXPIRES_AT=${new}/" "${dir}/metadata.env"
  green "Renewed until: $(epoch_to_date "$new")"
}

cmd_check_expiry(){
  ensure_dirs
  local now
  now="$(now_epoch)"
  for d in "${BOTS_DIR}"/*; do
    [[ -d "$d" ]] || continue
    # shellcheck source=/dev/null
    source "${d}/metadata.env" 2>/dev/null || true
    local name
    name="$(basename "$d")"
    local exp="${EXPIRES_AT:-0}"
    if [[ "$exp" -gt 0 && "$now" -ge "$exp" ]]; then
      if container_running "wingsbot-$name"; then
        yellow "Stopping expired bot: ${name}"
        compose_down "$name" || true
      fi
    fi
  done
}

cmd_update_vendor(){ ensure_dirs; ensure_repo; green "Vendor updated."; }

# === Manager self-update ===
cmd_self_update(){
  local mode="${1:-}"      # optional: --force or --apply-stash
  local maybe_apply="${2:-}"
  local dir="${MANAGER_ROOT}"
  [[ -d "$dir/.git" ]] || die "Manager directory is not a git repo: $dir. Reinstall via installer."
  green "Updating manager at ${dir}"

  # Stash local changes if any
  local has_changes=0
  if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
    has_changes=1
    yellow "Local changes detected; stashing before update..."
    git -C "$dir" stash push -u -m "wingsbot-manager auto-stash $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
  fi

  # Determine branch
  local branch
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

  # Fetch and update
  if git -C "$dir" fetch --all --prune; then
    if [[ "$mode" == "--force" ]]; then
      yellow "Forcing reset to origin/${branch} (local commits will be kept but HEAD will move)."
      git -C "$dir" reset --hard "origin/${branch}" || die "reset --hard failed"
      green "Manager updated (forced)."
    else
      if git -C "$dir" pull --ff-only; then
        green "Manager updated."
      else
        red "git pull failed. If you want to force update, run: wingsbot-manager self-update --force"
        return 1
      fi
    fi
  else
    die "git fetch failed. Check network/permissions."
  fi

  # Optionally re-apply stash
  if [[ "$mode" == "--apply-stash" || "$maybe_apply" == "--apply-stash" ]]; then
    yellow "Attempting to re-apply stashed changes..."
    if git -C "$dir" stash list | grep -q 'wingsbot-manager auto-stash'; then
      git -C "$dir" stash pop || yellow "Stash pop had conflicts or no matching stash. Resolve manually if needed."
    else
      yellow "No auto-stash entry found."
    fi
  else
    if [[ "$has_changes" -eq 1 ]]; then
      yellow "Your previous local changes were stashed. Use 'git -C ${dir} stash list' to review."
    fi
  fi
}

# === Admin Control Bot (Telegram) ===
ADMIN_BOT_DIR="${MANAGER_ROOT}/manager_bot"
ADMIN_BOT_ENV="${ADMIN_BOT_DIR}/.env"
ADMIN_BOT_VENV="${ADMIN_BOT_DIR}/.venv"
ADMIN_BOT_SERVICE="/etc/systemd/system/wingsbot-admin.service"

cmd_admin_bot_install(){
  need_cmd python3; need_cmd pip3
  if ! python3 -m venv --help >/dev/null 2>&1; then
    yellow "python3-venv not found; attempting to install..."
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y && sudo apt-get install -y python3-venv || true
    fi
  fi
  mkdir -p "$ADMIN_BOT_DIR"
  local token="" admins=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token) token="$2"; shift 2;;
      --token=*) token="${1#*=}"; shift;;
      --admins) admins="$2"; shift 2;;
      --admins=*) admins="${1#*=}"; shift;;
      *) shift;;
    esac
  done
  if [[ ! -f "$ADMIN_BOT_ENV" ]]; then
    if [[ -z "$token" ]]; then read -rp "MANAGER_BOT_TOKEN: " token; fi
    if [[ -z "$admins" ]]; then read -rp "ADMIN_IDS (comma separated): " admins; fi
    cat > "$ADMIN_BOT_ENV" <<EOF
MANAGER_BOT_TOKEN=${token}
ADMIN_IDS=${admins}
WINGS_MANAGER_BIN=$(command -v wingsbot-manager || echo ${MANAGER_ROOT}/wingsbot-manager.sh)
EOF
  fi
  python3 -m venv "$ADMIN_BOT_VENV"
  "${ADMIN_BOT_VENV}/bin/pip" install --upgrade pip
  "${ADMIN_BOT_VENV}/bin/pip" install -r "${ADMIN_BOT_DIR}/requirements.txt"
  sudo bash -c "cat > '$ADMIN_BOT_SERVICE'" <<EOF
[Unit]
Description=WINGS Manager Telegram Control Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=${ADMIN_BOT_DIR}
EnvironmentFile=${ADMIN_BOT_ENV}
ExecStart=${ADMIN_BOT_VENV}/bin/python ${ADMIN_BOT_DIR}/bot.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now wingsbot-admin.service
  green "Admin bot installed and started. Use: systemctl status wingsbot-admin"
}

cmd_admin_bot_start(){ sudo systemctl start wingsbot-admin.service; }
cmd_admin_bot_stop(){ sudo systemctl stop wingsbot-admin.service; }
cmd_admin_bot_restart(){ sudo systemctl restart wingsbot-admin.service; }
cmd_admin_bot_status(){ systemctl --no-pager --full status wingsbot-admin.service || true; }
cmd_admin_bot_logs(){ journalctl -u wingsbot-admin.service -n 200 --no-pager || true; }
cmd_admin_bot_edit(){ ${EDITOR:-nano} "$ADMIN_BOT_ENV"; }
cmd_admin_bot_uninstall(){ sudo systemctl disable --now wingsbot-admin.service || true; sudo rm -f "$ADMIN_BOT_SERVICE"; sudo systemctl daemon-reload; green "Admin bot uninstalled."; }

# Admin bot env management (non-interactive)
cmd_admin_bot_get_env(){ local key="${1:-}"; if [[ -z "$key" ]]; then sed -n '1,200p' "$ADMIN_BOT_ENV"; else grep -E "^${key}=" "$ADMIN_BOT_ENV" || true; fi }
cmd_admin_bot_set_env(){ local key="$1"; local value="$2"; local norestart="${3:-}"; [[ -n "$key" && -n "$value" ]] || die "Usage: $0 admin-bot set-env <KEY> <VALUE> [--no-restart]"; touch "$ADMIN_BOT_ENV"; if grep -qE "^${key}=" "$ADMIN_BOT_ENV"; then sed -i -E "s|^${key}=.*|${key}=${value}|" "$ADMIN_BOT_ENV"; else echo "${key}=${value}" >> "$ADMIN_BOT_ENV"; fi; [[ "$norestart" == "--no-restart" ]] || cmd_admin_bot_restart; }
cmd_admin_bot_unset_env(){ local key="$1"; local norestart="${2:-}"; [[ -n "$key" ]] || die "Usage: $0 admin-bot unset-env <KEY> [--no-restart]"; sed -i -E "/^${key}=.*/d" "$ADMIN_BOT_ENV" || true; [[ "$norestart" == "--no-restart" ]] || cmd_admin_bot_restart; }
# Rebuild a single bot (compose down + up --build), skip if expired
cmd_rebuild(){
  local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name to rebuild: " bot; }
  local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"
  # shellcheck source=/dev/null
  source "${dir}/metadata.env" 2>/dev/null || true
  local now; now="$(now_epoch)"; local exp="${EXPIRES_AT:-0}"
  if [[ "$exp" -gt 0 && "$now" -ge "$exp" ]]; then
    yellow "Skip rebuild (expired): ${bot}"
    return 0
  fi
  compose_down "$bot" || true
  compose_up "$bot"
  green "Rebuilt bot '${bot}'."
}

# Rebuild all non-expired bots
cmd_rebuild_all(){
  ensure_dirs
  local count=0; local skipped=0
  for d in "${BOTS_DIR}"/*; do
    [[ -d "$d" ]] || continue
    local name; name="$(basename "$d")"
    # shellcheck source=/dev/null
    source "$d/metadata.env" 2>/dev/null || true
    local now; now="$(now_epoch)"; local exp="${EXPIRES_AT:-0}"
    if [[ "$exp" -gt 0 && "$now" -ge "$exp" ]]; then
      yellow "Skip rebuild (expired): ${name}"; ((skipped++)); continue
    fi
    compose_down "$name" || true
    compose_up "$name"
    ((count++))
  done
  green "Rebuilt $count bot(s). Skipped $skipped expired."
}

# Update vendor and rebuild all non-expired bots
cmd_update_all(){
  cmd_update_vendor
  cmd_rebuild_all
}

install_cron(){
  local bin; bin="$(command -v wingsbot-manager || true)"; [[ -n "$bin" ]] || bin="${MANAGER_ROOT}/wingsbot-manager"
  (crontab -l 2>/dev/null | grep -v 'wingsbot-manager check-expiry' || true; echo "0 */12 * * * ${bin} check-expiry >/dev/null 2>&1") | crontab -
  green "Cron installed (every 12 hours)."
}
remove_cron(){ crontab -l 2>/dev/null | grep -v 'wingsbot-manager check-expiry' | crontab - || true; green "Cron removed."; }

# Get/Set/Unset .env values for a bot
cmd_get_env(){
  local bot="$1"; local key="${2:-}"
  local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"
  if [[ -z "$key" ]]; then
    sed -n '1,200p' "$dir/.env"
  else
    grep -E "^${key}=" "$dir/.env" || true
  fi
}

cmd_set_env(){
  local bot="$1"; local key="$2"; local value="$3"; local norestart="${4:-}"
  [[ -n "$bot" && -n "$key" && -n "$value" ]] || die "Usage: $0 set-env <bot> <KEY> <VALUE> [--no-restart]"
  local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"
  touch "$dir/.env"
  if grep -qE "^${key}=" "$dir/.env"; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$dir/.env"
  else
    echo "${key}=${value}" >> "$dir/.env"
  fi
  case "$key" in
    USE_WEBHOOK|WEBHOOK_PORT|WEBHOOK_URL|WEBHOOK_PATH|WEBHOOK_SECRET|DB_NAME) regen_compose "$bot";;
  esac
  if [[ "$norestart" != "--no-restart" ]]; then cmd_restart "$bot"; fi
  green "Set ${key} for ${bot}."
}

cmd_unset_env(){
  local bot="$1"; local key="$2"; local norestart="${3:-}"
  [[ -n "$bot" && -n "$key" ]] || die "Usage: $0 unset-env <bot> <KEY> [--no-restart]"
  local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"
  if [[ -f "$dir/.env" ]]; then
    sed -i -E "/^${key}=.*/d" "$dir/.env"
  fi
  case "$key" in
    USE_WEBHOOK|WEBHOOK_PORT|WEBHOOK_URL|WEBHOOK_PATH|WEBHOOK_SECRET|DB_NAME) regen_compose "$bot";;
  esac
  if [[ "$norestart" != "--no-restart" ]]; then cmd_restart "$bot"; fi
  green "Unset ${key} for ${bot}."
}

# Update host port in metadata and compose
cmd_set_host_port(){
  local bot="$1"; local val="$2"; [[ -n "$bot" && -n "$val" ]] || die "Usage: $0 set-host-port <bot> <auto|PORT>"
  local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"
  local port
  if [[ "$val" == "auto" ]]; then
    port="$(pick_free_port)" || die "No free ports available"
  else
    [[ "$val" =~ ^[0-9]+$ ]] || die "Invalid port"
    port="$val"
  fi
  if grep -qE '^HOST_PORT=' "$dir/metadata.env"; then
    sed -i -E "s/^HOST_PORT=.*/HOST_PORT=${port}/" "$dir/metadata.env"
  else
    echo "HOST_PORT=${port}" >> "$dir/metadata.env"
  fi
  regen_compose "$bot"
  cmd_restart "$bot"
  green "Host port for ${bot} set to ${port}."
}

# === Admin Control Bot (Telegram) ===
ADMIN_BOT_DIR="${MANAGER_ROOT}/manager_bot"
ADMIN_BOT_ENV="${ADMIN_BOT_DIR}/.env"
ADMIN_BOT_VENV="${ADMIN_BOT_DIR}/.venv"
ADMIN_BOT_SERVICE="/etc/systemd/system/wingsbot-admin.service"

cmd_admin_bot_install(){
  need_cmd python3; need_cmd pip3
  if ! python3 -m venv --help >/dev/null 2>&1; then
    yellow "python3-venv not found; attempting to install..."
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y && sudo apt-get install -y python3-venv || true
    fi
  fi
  mkdir -p "$ADMIN_BOT_DIR"
  if [[ ! -f "$ADMIN_BOT_ENV" ]]; then
    echo "Creating $ADMIN_BOT_ENV"
    read -rp "MANAGER_BOT_TOKEN: " tkn
    read -rp "ADMIN_IDS (comma separated): " aids
    cat > "$ADMIN_BOT_ENV" <<EOF
MANAGER_BOT_TOKEN=${tkn}
ADMIN_IDS=${aids}
WINGS_MANAGER_BIN=$(command -v wingsbot-manager || echo ${MANAGER_ROOT}/wingsbot-manager.sh)
EOF
  fi
  python3 -m venv "$ADMIN_BOT_VENV"
  "${ADMIN_BOT_VENV}/bin/pip" install --upgrade pip
  "${ADMIN_BOT_VENV}/bin/pip" install -r "${ADMIN_BOT_DIR}/requirements.txt"
  # Create systemd service
  sudo bash -c "cat > '$ADMIN_BOT_SERVICE'" <<EOF
[Unit]
Description=WINGS Manager Telegram Control Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=${ADMIN_BOT_DIR}
EnvironmentFile=${ADMIN_BOT_ENV}
ExecStart=${ADMIN_BOT_VENV}/bin/python ${ADMIN_BOT_DIR}/bot.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now wingsbot-admin.service
  green "Admin bot installed and started. Use: systemctl status wingsbot-admin"
}

cmd_admin_bot_start(){ sudo systemctl start wingsbot-admin.service; systemctl --no-pager --full status wingsbot-admin.service || true; }
cmd_admin_bot_stop(){ sudo systemctl stop wingsbot-admin.service; green "Stopped."; }
cmd_admin_bot_restart(){ sudo systemctl restart wingsbot-admin.service; green "Restarted."; }
cmd_admin_bot_status(){ systemctl --no-pager --full status wingsbot-admin.service || true; }
cmd_admin_bot_logs(){ journalctl -u wingsbot-admin.service -n 200 --no-pager || true; }
cmd_admin_bot_edit(){ ${EDITOR:-nano} "$ADMIN_BOT_ENV"; }
cmd_admin_bot_uninstall(){ sudo systemctl disable --now wingsbot-admin.service || true; sudo rm -f "$ADMIN_BOT_SERVICE"; sudo systemctl daemon-reload; green "Admin bot uninstalled."; }

menu_main(){
  while true; do
    echo -e "\n=== wingsbot-manager ==="
    echo " 1) Create new bot"
    echo " 2) List bots"
    echo " 3) Manage a bot"
    echo " 4) Housekeeping"
    echo " 5) Quit"
    read -rp "Choose: " c
    case "$c" in
      1) cmd_create; action_pause;;
      2) cmd_list; action_pause;;
      3) menu_manage_bot;;
      4) menu_housekeeping;;
      5) exit 0;;
      *) echo "Invalid";;
    esac
  done
}

# === CLI entrypoint ===
need_cmd git; need_cmd docker; docker compose version >/dev/null 2>&1 || die "Docker Compose plugin required (docker compose)."

print_help(){
  cat <<'USAGE'
Usage: wingsbot-manager <command> [args]

Core (used by Telegram control bot):
  create <name>            Create & run a new bot (prompts via stdin)
  list                     List bots
  info <name>              Show .env / metadata / compose
  start|stop|restart <name>
  logs <name>              Follow logs
  logs-once <name>         Show last 200 lines
  rm <name>                Remove a bot
  edit <name>              Interactive edit
  set-expiry <name> <val>  days|YYYY-MM-DD|0
  renew <name> <days>
  rebuild <name>
  rebuild-all
  update-all
  get-env <name> [KEY]
  set-env <name> KEY VALUE [--no-restart]
  unset-env <name> KEY [--no-restart]
  set-host-port <name> <auto|PORT>

Housekeeping:
  check-expiry             Stop expired bots
  cron install|remove      Manage expiry-check cron
  update-vendor            Update vendored WINGSBOT
  self-update [--force|--apply-stash]

Manager bot:
  admin-bot install [--token TOKEN --admins 1,2]
  admin-bot start|stop|restart|status|logs|edit|uninstall
  admin-bot get-env [KEY]
  admin-bot set-env KEY VALUE [--no-restart]
  admin-bot unset-env KEY [--no-restart]
USAGE
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  help|--help|-h)  print_help;;
  create)          cmd_create "${1:-}";;
  list)            cmd_list;;
  info)            cmd_info "${1:-}";;
  start)           cmd_start "${1:-}";;
  stop)            cmd_stop "${1:-}";;
  restart)         cmd_restart "${1:-}";;
  logs)            cmd_logs "${1:-}";;
  logs-once)       cmd_logs_once "${1:-}";;
  cron)
    sub="${1:-}"; shift || true
    case "$sub" in
      install) install_cron;;
      remove)  remove_cron;;
      *) echo "Use: wingsbot-manager cron [install|remove]";;
    esac;;
  rm)              cmd_rm "${1:-}";;
  edit)            cmd_edit "${1:-}";;
  rebuild)         cmd_rebuild "${1:-}";;
  rebuild-all)     cmd_rebuild_all;;
  update-all)      cmd_update_all;;
  get-env)         cmd_get_env "${1:-}" "${2:-}";;
  set-env)         cmd_set_env "${1:-}" "${2:-}" "${3:-}" "${4:-}";;
  unset-env)       cmd_unset_env "${1:-}" "${2:-}" "${3:-}";;
  set-host-port)   cmd_set_host_port "${1:-}" "${2:-}";;
  set-expiry)      cmd_set_expiry "${1:-}" "${2:-}";;
  renew)           cmd_renew "${1:-}" "${2:-}";;
  check-expiry)    cmd_check_expiry;;
  update-vendor)   cmd_update_vendor;;
  self-update)     cmd_self_update "$@";;
  admin-bot)
    sub="${1:-}"; shift || true
    case "$sub" in
      install)   cmd_admin_bot_install "$@";;
      start)     cmd_admin_bot_start;;
      stop)      cmd_admin_bot_stop;;
      restart)   cmd_admin_bot_restart;;
      status)    cmd_admin_bot_status;;
      logs)      cmd_admin_bot_logs;;
      edit)      cmd_admin_bot_edit;;
      uninstall) cmd_admin_bot_uninstall;;
      get-env)   cmd_admin_bot_get_env "${1:-}";;
      set-env)   cmd_admin_bot_set_env "${1:-}" "${2:-}" "${3:-}";;
      unset-env) cmd_admin_bot_unset_env "${1:-}" "${2:-}";;
      *)         echo "Use: wingsbot-manager admin-bot [install|start|stop|restart|status|logs|edit|uninstall|get-env|set-env|unset-env]";;
    esac;;
  *)               print_help;;
esac
