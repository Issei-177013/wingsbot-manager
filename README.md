# wingsbot-manager

A small, menu-driven Bash manager to **create, run, list, stop, renew, and auto-expire multiple Telegram bot instances** built from your fork of `WINGSBOT`. Each bot runs in its own Docker container with isolated data/logs.

## One-liner install (Ubuntu)
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Issei-177013/wingsbot-manager/main/install.sh)"
```

Then run:
```bash
wingsbot-manager
```

## Features
- **Interactive menu** (no flags needed).
- **Per-bot isolation** under `bots/<name>`: each has `.env`, `docker-compose.yml`, `data/`, `logs/`.
- **Webhook support (optional)** with **auto host-port assignment** (configurable range).
- **Expiry & renewal**: set an expiry (days or date), auto-stop expired bots, renew on demand.
- **Cron-friendly**: `check-expiry` is idempotent; schedule it safely.
- **Vendor once**: your WINGSBOT fork is cloned into `vendor/WINGSBOT` and reused.

## Requirements
- Ubuntu 20.04/22.04/24.04
- Docker Engine + Docker Compose plugin
- `git`, `bash`, GNU `date` (default on Ubuntu)

> The installer sets up the required packages and enables Docker.

## Quick start
```bash
# open interactive menus
wingsbot-manager

# or use CLI directly:
wingsbot-manager create mybot
wingsbot-manager list
wingsbot-manager logs mybot
wingsbot-manager edit mybot
wingsbot-manager rebuild mybot        # rebuild from latest vendor code
wingsbot-manager rebuild-all          # rebuild all non-expired bots
wingsbot-manager update-all           # update vendor + rebuild all
wingsbot-manager self-update          # update the manager itself (git pull)
wingsbot-manager set-expiry mybot 30
wingsbot-manager renew mybot 15
```

## Commands
- `menu` (default): interactive UI
- `create <name>`: create & run a new bot (interactive prompts)
- `list`: list all bots with status, expiry, and ports
- `info <name>`: print a bot’s `.env`, metadata, and compose file
- `start|stop|restart <name>`: lifecycle
- `logs <name>`: tail logs
- `logs-once <name>`: show last 200 log lines (non-follow)
- `rm <name>`: stop and remove a bot directory
- `edit <name>`: interactively update bot config (.env, ports); restarts the bot
- `get-env <name> [KEY]`: print .env or a single key
- `set-env <name> <KEY> <VALUE> [--no-restart]`: update .env and restart (unless `--no-restart`)
- `unset-env <name> <KEY> [--no-restart]`: remove a key from .env and restart
- `set-host-port <name> <auto|PORT>`: change mapped host port (restarts)
- `rebuild <name>`: rebuild a bot from vendored code (down + up --build)
- `rebuild-all`: rebuild all non-expired bots
- `update-all`: update vendored fork then rebuild all non-expired bots
- `set-expiry <name> <days|YYYY-MM-DD|0|none>`: set/override expiry (`0`/`none` disables)
- `renew <name> <days>`: extend expiry by N days
- `check-expiry`: stop any expired bots (use in cron)
- `update-vendor`: pull latest code for your vendored fork
- `admin-bot [install|start|stop|restart|status|logs|edit|uninstall]`: Telegram control bot setup & management
- `self-update`: update the manager repo itself

## Defaults (editable at top of script)
- Internal port (webhook): `8080`
- Auto host-port range: `10001–19999`
- Default expiry: `0` (no expiry)

## Webhook & ports
If you choose `USE_WEBHOOK=true` at creation time:
- The manager will map `HOST_PORT:INTERNAL_PORT` in compose.
- It will auto-pick a free host port in `10001–19999`, or you can specify one.
- If you don’t use webhook, **no ports are exposed**.

## Cron (auto-stop expired bots)
```bash
0 */12 * * * /usr/local/bin/wingsbot-manager check-expiry >/dev/null 2>&1
```

## Update vendored fork
```bash
wingsbot-manager update-vendor
# then restart a bot if needed
wingsbot-manager restart mybot
```

## Backup & restore
- **Backup**: copy `bots/<name>/{.env,metadata.env,data,logs}`.
- **Restore**: place the folder back under `bots/` and run `wingsbot-manager start <name>`.

## Uninstall
```bash
sudo /opt/wingsbot-manager/uninstall.sh
```

## Security
- `.env` files contain secrets; permissions are set to `600`.
- Lock down server access; use HTTPS for webhook endpoints.
## Telegram Control Bot (optional)
- Install and start:
  - `wingsbot-manager admin-bot install`
  - Prompts: `MANAGER_BOT_TOKEN`, `ADMIN_IDS` (comma-separated Telegram user IDs)
- Use in Telegram (only by admins):
  - `/list`, `/info <name>`, `/startbot <name>`, `/stopbot <name>`, `/restart <name>`
  - `/setexpiry <name> <days|YYYY-MM-DD|0>`, `/renew <name> <days>`
  - `/create` (interactive wizard)
  - `/updateall`
- The control bot calls the local CLI under the hood and keeps data safe.
