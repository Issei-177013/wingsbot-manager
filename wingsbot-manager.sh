#!/usr/bin/env bash
set -euo pipefail

# === Config ===
REPO_URL="https://github.com/Issei-177013/WINGSBOT.git"
MANAGER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="${MANAGER_ROOT}/vendor"
REPO_DIR="${VENDOR_DIR}/WINGSBOT"
BOTS_DIR="${MANAGER_ROOT}/bots"
DEFAULT_INTERNAL_PORT="9090"   # used only if USE_WEBHOOK=true
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

compose_cmd(){ docker compose "$@"; }
container_running(){ local name="$1"; docker ps --format '{{.Names}}' | grep -Fxq "$name"; }

pick_free_port(){
  local used
  used="$(
    { docker ps --format '{{.Ports}}' | tr ',' '\n' | sed -En 's/.*:([0-9]+)->.*/\1/p'; \
      ss -tuln | awk 'NR>1{split($5,a,\":\"); print a[length(a)]}'; } \
    | sort -u
  )"
  for p in $(seq "$PORT_RANGE_START" "$PORT_RANGE_END"); do
    if ! grep -qx "$p" <<< "$used"; then echo "$p"; return 0; fi
  done
  return 1
}

compose_up(){ local bot="$1" dir="${BOTS_DIR}/${bot}"; (cd "$dir" && compose_cmd up -d --build); }
compose_down(){ local bot="$1" dir="${BOTS_DIR}/${bot}"; (cd "$dir" && compose_cmd down); }

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
  read -rp "USE_WEBHOOK? [false]: " USE_WEBHOOK; USE_WEBHOOK=${USE_WEBHOOK:-false}

  local HOST_PORT="" INTERNAL_PORT="$DEFAULT_INTERNAL_PORT" WEBHOOK_URL="" WEBHOOK_SECRET=""
  if [[ "${USE_WEBHOOK,,}" == "true" ]]; then
    read -rp "WEBHOOK_URL (e.g. https://example.com/hook): " WEBHOOK_URL
    read -rp "WEBHOOK_SECRET (optional): " WEBHOOK_SECRET
    read -rp "INTERNAL_PORT [${DEFAULT_INTERNAL_PORT}]: " tmp; INTERNAL_PORT=${tmp:-$DEFAULT_INTERNAL_PORT}
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
USE_WEBHOOK=${USE_WEBHOOK}
WEBHOOK_URL=${WEBHOOK_URL}
WEBHOOK_SECRET=${WEBHOOK_SECRET}
INTERNAL_PORT=${INTERNAL_PORT}
EOF
  chmod 600 "$DIR/.env"

  cat > "$DIR/metadata.env" <<EOF
NAME=${BOT}
CREATED_AT=$(now_epoch)
EXPIRES_AT=${EXPIRES_AT}
HOST_PORT=${HOST_PORT}
INTERNAL_PORT=${INTERNAL_PORT}
EOF

  cat > "$DIR/docker-compose.yml" <<EOF
services:
  ${BOT}:
    build: ../../vendor/WINGSBOT
    container_name: ${BOT}
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
$( [[ "${USE_WEBHOOK,,}" == "true" ]] && printf "    ports:\n      - \"%s:%s\"\n" "${HOST_PORT}" "${INTERNAL_PORT}" )
EOF

  if command -v id >/dev/null 2>&1; then sudo chown -R "$(id -u)":"$(id -g)" "$DIR" >/dev/null 2>&1 || true; fi
  compose_up "$BOT"
  green "Bot '${BOT}' is running."
  [[ "$EXPIRES_AT" != "0" ]] && echo "Expires at: $(epoch_to_date "$EXPIRES_AT")"
}

cmd_list(){
  ensure_dirs
  printf "%-20s %-10s %-20s %-10s %-10s\n" "NAME" "STATUS" "EXPIRES_AT" "HOST" "INT"
  for d in "${BOTS_DIR}"/*; do
    [[ -d "$d" ]] || continue
    local name; name="$(basename "$d")"
    source "$d/metadata.env" 2>/dev/null || true
    local status="stopped"; container_running "$name" && status="running"
    local exp="${EXPIRES_AT:-0}"; [[ "${exp:-0}" -gt 0 ]] && exp="$(epoch_to_date "$exp")" || exp="-"
    printf "%-20s %-10s %-20s %-10s %-10s\n" "$name" "$status" "$exp" "${HOST_PORT:--}" "${INTERNAL_PORT:--}"
  done
}

cmd_info(){ local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }; local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"; echo "# ${bot}"; echo "Path: ${dir}"; echo "- .env"; sed -n '1,200p' "${dir}/.env"; echo "- metadata"; sed -n '1,200p' "${dir}/metadata.env"; echo "- compose"; sed -n '1,200p' "${dir}/docker-compose.yml"; }
cmd_start(){ local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }; compose_up "$bot"; }
cmd_stop(){  local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }; compose_down "$bot"; }
cmd_restart(){ local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }; compose_down "$bot"; compose_up "$bot"; }
cmd_logs(){ local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name: " bot; }; (cd "${BOTS_DIR}/$bot" && compose_cmd logs -f); }

cmd_rm(){ local bot="${1:-}"; [[ -n "$bot" ]] || { read -rp "Bot name to remove: " bot; }; local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"; compose_down "$bot" || true; rm -rf "$dir"; green "Removed bot '${bot}'."; }

cmd_set_expiry(){ local bot="$1"; local val="${2:-}"; [[ -n "$bot" && -n "$val" ]] || die "Usage: $0 set-expiry <bot> <days|YYYY-MM-DD>"; local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"; local epoch="0"; if [[ "$val" =~ ^[0-9]+$ ]]; then epoch="$(add_days_epoch "$val")"; else epoch="$(date_to_epoch "$val")"; fi; [[ "$epoch" -gt 0 ]] || die "Invalid expiry"; sed -i -E "s/^EXPIRES_AT=.*/EXPIRES_AT=${epoch}/" "${dir}/metadata.env"; green "Expiry set: $(epoch_to_date "$epoch")"; }

cmd_renew(){ local bot="$1"; local days="${2:-}"; [[ -n "$bot" && -n "$days" ]] || die "Usage: $0 renew <bot> <days>"; local dir="${BOTS_DIR}/${bot}"; [[ -d "$dir" ]] || die "Bot not found: $bot"; source "${dir}/metadata.env" || true; local base="${EXPIRES_AT:-0}"; [[ "$base" -lt "$(now_epoch)" ]] && base="$(now_epoch)"; local new=$(( base + days*86400 )); sed -i -E "s/^EXPIRES_AT=.*/EXPIRES_AT=${new}/" "${dir}/metadata.env"; green "Renewed until: $(epoch_to_date "$new")"; }

cmd_check_expiry(){ ensure_dirs; local now; now="$(now_epoch)"; for d in "${BOTS_DIR}"/*; do [[ -d "$d" ]] || continue; source "${d}/metadata.env" 2>/dev/null || true; local name="$(basename "$d")"; local exp="${EXPIRES_AT:-0}"; if [[ "$exp" -gt 0 && "$now" -ge "$exp" ]]; then if container_running "$name"; then yellow "Stopping expired bot: ${name}"; compose_down "$name" || true; fi; fi; done }

cmd_update_vendor(){ ensure_dirs; ensure_repo; green "Vendor updated."; }

# === Menus ===
select_bot(){
  local i=0; declare -a names; echo "Available bots:"
  for d in "${BOTS_DIR}"/*; do [[ -d "$d" ]] || continue; names+=("$(basename "$d")"); printf "%2d) %s\n" "$((++i))" "${names[-1]}"; done
  [[ ${#names[@]} -gt 0 ]] || { echo "No bots found."; return 1; }
  local choice; read -rp "Choose [1-${#names[@]}]: " choice; [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#names[@]} )) || return 1
  echo "${names[$((choice-1))]}"
}

menu_manage_bot(){
  local bot; bot="${1:-}"; [[ -n "$bot" ]] || bot="$(select_bot)" || return 0
  while true; do
    echo -e "\n[Manage: $bot]"
    echo " 1) Start"
    echo " 2) Stop"
    echo " 3) Restart"
    echo " 4) Logs"
    echo " 5) Info"
    echo " 6) Set expiry"
    echo " 7) Renew"
    echo " 8) Remove"
    echo " 9) Back"
    read -rp "Choose: " a
    case "$a" in
      1) cmd_start "$bot";;
      2) cmd_stop "$bot";;
      3) cmd_restart "$bot";;
      4) cmd_logs "$bot";;
      5) cmd_info "$bot";;
      6) read -rp "Expiry (days or YYYY-MM-DD): " v; cmd_set_expiry "$bot" "$v";;
      7) read -rp "Days to extend: " d; cmd_renew "$bot" "$d";;
      8) read -rp "Type the bot name to confirm removal: " c; [[ "$c" == "$bot" ]] && cmd_rm "$bot" && break || echo "Cancelled.";;
      9) break;;
      *) echo "Invalid";;
    esac
    action_pause
  done
}

install_cron(){
  local bin; bin="$(command -v wingsbot-manager || true)"; [[ -n "$bin" ]] || bin="${MANAGER_ROOT}/wingsbot-manager"
  (crontab -l 2>/dev/null | grep -v 'wingsbot-manager check-expiry' || true; echo "*/5 * * * * ${bin} check-expiry >/dev/null 2>&1") | crontab -
  green "Cron installed (every 5 minutes)."
}
remove_cron(){ crontab -l 2>/dev/null | grep -v 'wingsbot-manager check-expiry' | crontab - || true; green "Cron removed."; }

menu_housekeeping(){
  while true; do
    echo -e "\n[Housekeeping]"
    echo " 1) Run expiry check now"
    echo " 2) Install cron (check-expiry)"
    echo " 3) Remove cron"
    echo " 4) Update vendored fork"
    echo " 5) Back"
    read -rp "Choose: " a
    case "$a" in
      1) cmd_check_expiry;;
      2) install_cron;;
      3) remove_cron;;
      4) cmd_update_vendor;;
      5) break;;
      *) echo "Invalid";;
    esac
    action_pause
  done
}

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

cmd="${1:-menu}"; shift || true
case "$cmd" in
  menu)            menu_main;;
  create)          cmd_create "${1:-}";;
  list)            cmd_list;;
  info)            cmd_info "${1:-}";;
  start)           cmd_start "${1:-}";;
  stop)            cmd_stop "${1:-}";;
  restart)         cmd_restart "${1:-}";;
  logs)            cmd_logs "${1:-}";;
  rm)              cmd_rm "${1:-}";;
  set-expiry)      cmd_set_expiry "${1:-}" "${2:-}";;
  renew)           cmd_renew "${1:-}" "${2:-}";;
  check-expiry)    cmd_check_expiry;;
  update-vendor)   cmd_update_vendor;;
  help|--help|-h)  echo "Use: wingsbot-manager [menu|create|list|info|start|stop|restart|logs|rm|set-expiry|renew|check-expiry|update-vendor]";;
  *)               menu_main;;
esac