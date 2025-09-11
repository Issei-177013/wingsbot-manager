import asyncio
import os
import shlex
import subprocess
from dataclasses import dataclass
from typing import List, Optional

from telegram import Update
from telegram.constants import ParseMode
from telegram.ext import Application, CommandHandler, ContextTypes, ConversationHandler, MessageHandler, filters


MANAGER_BIN = os.getenv("WINGS_MANAGER_BIN", "/usr/local/bin/wingsbot-manager")
ADMIN_IDS = [int(x) for x in (os.getenv("ADMIN_IDS", "").replace(" ", "").split(",") if x)]
BOT_TOKEN = os.getenv("MANAGER_BOT_TOKEN", "")

DOCKER_PLUGIN_DIRS = "/usr/libexec/docker/cli-plugins:/usr/lib/docker/cli-plugins:/usr/local/lib/docker/cli-plugins"


def ensure_auth(user_id: Optional[int]) -> bool:
    try:
        return user_id is not None and int(user_id) in ADMIN_IDS
    except Exception:
        return False


def run_manager(args: List[str], stdin_data: Optional[str] = None, timeout: int = 120) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["DOCKER_CLI_PLUGIN_EXTRA_DIRS"] = f"{DOCKER_PLUGIN_DIRS}:{env.get('DOCKER_CLI_PLUGIN_EXTRA_DIRS','')}"
    env["COMPOSE_DOCKER_CLI_BUILD"] = "0"
    env["DOCKER_BUILDKIT"] = "0"
    return subprocess.run(
        [MANAGER_BIN, *args],
        input=stdin_data,
        text=True,
        capture_output=True,
        timeout=timeout,
        env=env,
    )


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        await update.message.reply_text(
            f"Unauthorized. Your ID: {update.effective_user.id}\n"
            "Ask the server admin to add it:\n"
            "  wingsbot-manager admin-bot set-env ADMIN_IDS <id1,id2>"
        )
        return
    await update.message.reply_text(
        "WINGS Manager Bot\nCommands:\n"
        "/list - list bots\n"
        "/info <name> - show details\n"
        "/logs <name> - last 200 lines\n"
        "/startbot <name> | /stopbot <name> | /restart <name>\n"
        "/setexpiry <name> <days|YYYY-MM-DD|0>\n"
        "/renew <name> <days>\n"
        "/create - interactive create\n"
        "/setenv <name> <KEY> <VALUE>\n"
        "/getenv <name> [KEY]\n"
        "/rm <name>\n"
        "/rebuild <name>\n"
        "/updateall - update vendor + rebuild all\n"
    )


async def cmd_list(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        await update.message.reply_text("Unauthorized. Use /id to get your numeric ID.")
        return
    p = run_manager(["list"]) 
    text = p.stdout.strip() or p.stderr.strip() or "(no output)"
    await update.message.reply_text(f"<pre>{text}</pre>", parse_mode=ParseMode.HTML)


async def cmd_info(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        await update.message.reply_text("Unauthorized. Use /id to get your numeric ID.")
        return
    if not context.args:
        await update.message.reply_text("Usage: /info <name>")
        return
    name = context.args[0]
    p = run_manager(["info", name])
    out = p.stdout if p.returncode == 0 else p.stderr
    # cap to avoid huge output
    out = "\n".join(out.splitlines()[:200])
    await update.message.reply_text(f"<pre>{out}</pre>", parse_mode=ParseMode.HTML)


async def cmd_simple(update: Update, context: ContextTypes.DEFAULT_TYPE, action: str) -> None:
    if not ensure_auth(update.effective_user.id):
        await update.message.reply_text("Unauthorized. Use /id to get your numeric ID.")
        return
    if not context.args:
        await update.message.reply_text(f"Usage: /{action} <name>")
        return
    name = context.args[0]
    p = run_manager([action.replace("bot", ""), name])
    out = p.stdout if p.returncode == 0 else p.stderr
    await update.message.reply_text(f"<pre>{out.strip() or '(done)'}" + "</pre>", parse_mode=ParseMode.HTML)


async def cmd_logs(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        return
    if not context.args:
        await update.message.reply_text("Usage: /logs <name>")
        return
    name = context.args[0]
    p = run_manager(["logs-once", name])
    out = p.stdout if p.returncode == 0 else p.stderr
    # tail already limited in CLI; still cap
    out = "\n".join(out.splitlines()[-200:])
    await update.message.reply_text(f"<pre>{out or '(no logs)'}" + "</pre>", parse_mode=ParseMode.HTML)


async def cmd_rm(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        return
    if not context.args:
        await update.message.reply_text("Usage: /rm <name>")
        return
    name = context.args[0]
    p = run_manager(["rm", name])
    out = p.stdout if p.returncode == 0 else p.stderr
    await update.message.reply_text(out.strip() or "(done)")


async def cmd_setenv(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        return
    if len(context.args) < 3:
        await update.message.reply_text("Usage: /setenv <name> <KEY> <VALUE>")
        return
    name, key, val = context.args[0], context.args[1], " ".join(context.args[2:])
    p = run_manager(["set-env", name, key, val])
    out = p.stdout if p.returncode == 0 else p.stderr
    await update.message.reply_text(out.strip() or "(done)")


async def cmd_getenv(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        return
    if len(context.args) < 1:
        await update.message.reply_text("Usage: /getenv <name> [KEY]")
        return
    name = context.args[0]
    key = context.args[1] if len(context.args) > 1 else None
    args = ["get-env", name]
    if key:
        args.append(key)
    p = run_manager(args)
    out = p.stdout if p.returncode == 0 else p.stderr
    out = "\n".join(out.splitlines()[:200])
    await update.message.reply_text(f"<pre>{out or '(no data)'}" + "</pre>", parse_mode=ParseMode.HTML)


CREATE_NAME, CREATE_TOKEN, CREATE_ADMIN, CREATE_CHANID, CREATE_CHANUSER, CREATE_WEBHOOK_YN, CREATE_WEBHOOK_URL, CREATE_WEBHOOK_PATH, CREATE_WEBHOOK_PORT, CREATE_WEBHOOK_SECRET, CREATE_HOSTPORT_AUTO, CREATE_HOSTPORT_VAL, CREATE_EXPIRE = range(13)


@dataclass
class CreateState:
    name: str = ""
    token: str = ""
    admin_id: str = ""
    channel_id: str = ""
    channel_username: str = ""
    use_webhook: bool = False
    webhook_url: str = ""
    webhook_path: str = ""
    webhook_port: str = "8080"
    webhook_secret: str = ""
    hostport_auto: bool = True
    host_port: str = ""
    expire_days: str = "0"


async def create_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not ensure_auth(update.effective_user.id):
        return ConversationHandler.END
    context.user_data["create"] = CreateState()
    await update.message.reply_text("Bot name (slug friendly):")
    return CREATE_NAME


async def create_name(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.name = update.message.text.strip()
    await update.message.reply_text("BOT_TOKEN:")
    return CREATE_TOKEN


async def create_token(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.token = update.message.text.strip()
    await update.message.reply_text("ADMIN_ID (numeric):")
    return CREATE_ADMIN


async def create_admin(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.admin_id = update.message.text.strip()
    await update.message.reply_text("CHANNEL_ID (optional, e.g. @mychannel or -100...):")
    return CREATE_CHANID


async def create_chanid(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.channel_id = update.message.text.strip()
    await update.message.reply_text("CHANNEL_USERNAME (optional, e.g. mychannel or @mychannel):")
    return CREATE_CHANUSER


async def create_chanuser(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.channel_username = update.message.text.strip()
    await update.message.reply_text("Use webhook? (yes/no) [no]:")
    return CREATE_WEBHOOK_YN


async def create_webhook_yn(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    yn = (update.message.text or "no").strip().lower()
    st.use_webhook = yn in ("y", "yes", "true", "1")
    if st.use_webhook:
        await update.message.reply_text("WEBHOOK_URL (public base, e.g. https://example.com):")
        return CREATE_WEBHOOK_URL
    else:
        await update.message.reply_text("Expire in days [0]:")
        return CREATE_EXPIRE


async def create_webhook_url(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.webhook_url = update.message.text.strip()
    await update.message.reply_text("WEBHOOK_PATH (optional, default token):")
    return CREATE_WEBHOOK_PATH


async def create_webhook_path(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.webhook_path = update.message.text.strip()
    await update.message.reply_text("WEBHOOK_PORT [8080]:")
    return CREATE_WEBHOOK_PORT


async def create_webhook_port(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.webhook_port = (update.message.text or "8080").strip() or "8080"
    await update.message.reply_text("WEBHOOK_SECRET (optional):")
    return CREATE_WEBHOOK_SECRET


async def create_webhook_secret(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.webhook_secret = update.message.text.strip()
    await update.message.reply_text("Auto-assign HOST_PORT? [Y/n]:")
    return CREATE_HOSTPORT_AUTO


async def create_hostport_auto(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    yn = (update.message.text or "Y").strip().lower()
    st.hostport_auto = yn in ("y", "yes", "true", "1", "")
    if st.hostport_auto:
        await update.message.reply_text("Expire in days [0]:")
        return CREATE_EXPIRE
    else:
        await update.message.reply_text("HOST_PORT:")
        return CREATE_HOSTPORT_VAL


async def create_hostport_val(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.host_port = update.message.text.strip()
    await update.message.reply_text("Expire in days [0]:")
    return CREATE_EXPIRE


async def create_expire(update: Update, context: ContextTypes.DEFAULT_TYPE):
    st: CreateState = context.user_data["create"]
    st.expire_days = (update.message.text or "0").strip() or "0"

    # Build stdin for CLI create prompts, matching manager's order
    answers = []
    answers.append(st.token)
    answers.append(st.admin_id)
    answers.append(st.channel_id)
    answers.append("true" if st.use_webhook else "false")
    if st.use_webhook:
        answers.append(st.webhook_url)
        answers.append(st.webhook_path)
        answers.append(st.webhook_port)
        answers.append(st.webhook_secret)
        answers.append("Y" if st.hostport_auto else "n")
        if not st.hostport_auto:
            answers.append(st.host_port)
    answers.append(st.expire_days)
    stdin_data = "\n".join(answers) + "\n"

    p = run_manager(["create", st.name], stdin_data=stdin_data, timeout=300)
    out = p.stdout if p.returncode == 0 else (p.stdout + "\n" + p.stderr)
    out = "\n".join(out.splitlines()[-50:])
    await update.message.reply_text(f"<pre>{out}</pre>", parse_mode=ParseMode.HTML)
    return ConversationHandler.END


async def cmd_setexpiry(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        return
    if len(context.args) < 2:
        await update.message.reply_text("Usage: /setexpiry <name> <days|YYYY-MM-DD|0>")
        return
    name, val = context.args[0], context.args[1]
    p = run_manager(["set-expiry", name, val])
    out = p.stdout if p.returncode == 0 else p.stderr
    await update.message.reply_text(out.strip() or "(done)")


async def cmd_renew(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        return
    if len(context.args) < 2:
        await update.message.reply_text("Usage: /renew <name> <days>")
        return
    name, days = context.args[0], context.args[1]
    p = run_manager(["renew", name, days])
    out = p.stdout if p.returncode == 0 else p.stderr
    await update.message.reply_text(out.strip() or "(done)")


async def cmd_updateall(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not ensure_auth(update.effective_user.id):
        return
    p = run_manager(["update-all"])
    out = p.stdout if p.returncode == 0 else p.stderr
    await update.message.reply_text(f"<pre>{(out or '').strip() or '(done)'}" + "</pre>", parse_mode=ParseMode.HTML)


def build_app() -> Application:
    if not BOT_TOKEN:
        raise SystemExit("MANAGER_BOT_TOKEN is not set")
    if not ADMIN_IDS:
        raise SystemExit("ADMIN_IDS is not set (comma-separated user IDs)")
    app = Application.builder().token(BOT_TOKEN).build()

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("id", cmd_id))
    app.add_handler(CommandHandler("list", cmd_list))
    app.add_handler(CommandHandler("info", cmd_info))
    app.add_handler(CommandHandler("logs", cmd_logs))
    app.add_handler(CommandHandler("startbot", lambda u, c: cmd_simple(u, c, "start")))
    app.add_handler(CommandHandler("stopbot", lambda u, c: cmd_simple(u, c, "stop")))
    app.add_handler(CommandHandler("restart", lambda u, c: cmd_simple(u, c, "restart")))
    app.add_handler(CommandHandler("rm", cmd_rm))
    app.add_handler(CommandHandler("setenv", cmd_setenv))
    app.add_handler(CommandHandler("getenv", cmd_getenv))
    app.add_handler(CommandHandler("setexpiry", cmd_setexpiry))
    app.add_handler(CommandHandler("renew", cmd_renew))
    app.add_handler(CommandHandler("rebuild", lambda u, c: cmd_simple(u, c, "rebuild")))
    app.add_handler(CommandHandler("updateall", cmd_updateall))

    conv = ConversationHandler(
        entry_points=[CommandHandler("create", create_start)],
        states={
            CREATE_NAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_name)],
            CREATE_TOKEN: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_token)],
            CREATE_ADMIN: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_admin)],
            CREATE_CHANID: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_chanid)],
            CREATE_CHANUSER: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_chanuser)],
            CREATE_WEBHOOK_YN: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_webhook_yn)],
            CREATE_WEBHOOK_URL: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_webhook_url)],
            CREATE_WEBHOOK_PATH: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_webhook_path)],
            CREATE_WEBHOOK_PORT: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_webhook_port)],
            CREATE_WEBHOOK_SECRET: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_webhook_secret)],
            CREATE_HOSTPORT_AUTO: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_hostport_auto)],
            CREATE_HOSTPORT_VAL: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_hostport_val)],
            CREATE_EXPIRE: [MessageHandler(filters.TEXT & ~filters.COMMAND, create_expire)],
        },
        fallbacks=[],
        allow_reentry=True,
    )
    app.add_handler(conv)
    return app


def main():
    app = build_app()
    app.run_polling(close_loop=False)


if __name__ == "__main__":
async def cmd_id(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(f"Your user ID: {update.effective_user.id}")

    main()
