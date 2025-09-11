# wingsbot-manager

A small CLI + Telegram-based manager to **create, run, list, stop, renew, and auto-expire multiple WINGSBOT instances**. Each bot runs in its own Docker container with isolated data/logs. The preferred UX is via the bundled Telegram "admin control bot"; the local CLI is non-interactive and script-friendly.

## One-liner install (Ubuntu)
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Issei-177013/wingsbot-manager/main/install.sh)"
```

Then set up the Telegram admin bot:
```bash
# installs and starts a small PTB bot to manage your bots via Telegram
wingsbot-manager admin-bot install --token <TELEGRAM_BOT_TOKEN> --admins 123456,789012

# see status/logs
wingsbot-manager admin-bot status
wingsbot-manager admin-bot logs
```

## Features
- **Telegram control bot**: manage everything from Telegram (create, start/stop, logs, edit env, renew, etc.).
- **Per-bot isolation** under `bots/<name>`: each has `.env`, `docker-compose.yml`, `data/`, `logs/`.
- **Webhook support (optional)** with **auto host-port assignment** (configurable range).
- **Expiry & renewal**: set an expiry (days or date), auto-stop expired bots, renew on demand.
- **Cron-friendly**: `check-expiry` is idempotent; schedule it safely.
- **No buildx required**: classic `docker build` + `compose up --no-build` for reliability.
- **Vendor once**: your WINGSBOT fork is cloned into `vendor/WINGSBOT` and reused.

## Requirements
- Ubuntu 20.04/22.04/24.04
- Docker Engine + Docker Compose plugin
- `git`, `bash`, GNU `date` (default on Ubuntu)

> The installer sets up the required packages and enables Docker.

## Quick start
```bash
# 1) Install and run the Telegram control bot
wingsbot-manager admin-bot install --token <TELEGRAM_BOT_TOKEN> --admins 123456,789012

# 2) Manage from Telegram (by admins only):
#   /create, /list, /info <name>, /logs <name>
#   /startbot <name>, /stopbot <name>, /restart <name>
#   /setenv <name> KEY VALUE, /getenv <name> [KEY]
#   /setexpiry <name> <days|YYYY-MM-DD|0>, /renew <name> <days>
#   /rm <name>, /rebuild <name>, /updateall

# 3) Optional local CLI usage:
wingsbot-manager help
wingsbot-manager list
wingsbot-manager create mybot
wingsbot-manager logs mybot
wingsbot-manager set-expiry mybot 30
wingsbot-manager renew mybot 15
wingsbot-manager update-all
```

## Commands (CLI)
  
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
- `cron install|remove`: manage expiry-check cron
- `update-vendor`: pull latest code for your vendored fork
- `self-update [--force|--apply-stash]`: update the manager repo itself
- `admin-bot [install|start|stop|restart|status|logs|edit|uninstall|get-env|set-env|unset-env]`: Telegram control bot setup & management

## Defaults (editable at top of script)
- Internal port (webhook): `8080`
- Auto host-port range: `10001–19999`
- Default expiry: `0` (no expiry)

## Webhook & ports
If you choose `USE_WEBHOOK=true` at creation time:
- The manager will map `HOST_PORT:WEBHOOK_PORT` in compose (internal default: `8080`).
- It will auto-pick a free host port in `10001-19999`, or you can specify one.
- If you don't use webhook, **no ports are exposed**.

## Cron (auto-stop expired bots)
```bash
# recommended
wingsbot-manager cron install

# remove later
wingsbot-manager cron remove
```

## Update vendored fork & rebuild
```bash
# one-shot: update vendor and rebuild all non-expired bots
wingsbot-manager update-all

# or separately
wingsbot-manager update-vendor
wingsbot-manager rebuild-all
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
## Telegram Control Bot
- Install/start:
  - `wingsbot-manager admin-bot install --token <TOKEN> --admins 123,456`
  - or run `admin-bot install` and follow prompts
- Use in Telegram (admins only):
  - `/create`, `/list`, `/info <name>`, `/logs <name>`
  - `/startbot <name>`, `/stopbot <name>`, `/restart <name>`
  - `/setenv <name> <KEY> <VALUE>`, `/getenv <name> [KEY]`
  - `/setexpiry <name> <days|YYYY-MM-DD|0>`, `/renew <name> <days>`
  - `/rm <name>`, `/rebuild <name>`, `/updateall`
- The control bot calls the local CLI under the hood and keeps data safe.
