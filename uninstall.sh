#!/usr/bin/env bash
#
# Contextify uninstaller — removes everything the installer put on this machine.
#
#   curl -fsSL https://contextifyai.com/uninstall.sh | bash
#
# Order matters here. The Claude Code hook is undone FIRST, while the CLI that
# knows how to restore the previous settings still exists; deleting the install
# directory first would strand ANTHROPIC_BASE_URL in ~/.claude/settings.json
# pointing at a proxy that no longer exists, which breaks Claude Code and
# leaves no obvious way to find out why.
#
# Never uses sudo. Everything it touches is inside $HOME.
#
set -uo pipefail

INSTALL_DIR="${CONTEXTIFY_DIR:-$HOME/.contextify}"
BIN_DIR="${CONTEXTIFY_BIN_DIR:-$HOME/.local/bin}"
KEEP_SETTINGS=0

# ── Refuse to delete anything that is not plainly ours ───────────────────────
#
# This script runs `rm -rf "$INSTALL_DIR"`, and CONTEXTIFY_DIR is an ordinary
# environment variable. Set to $HOME — which is exactly what happened the first
# time this was tested — that command deletes the user's entire home
# directory. A destructive path has to be checked before it is used, not
# assumed to be sensible.
case "$INSTALL_DIR" in
  ""|"/"|"$HOME"|"$HOME/")
    printf '\nerror refusing to remove %s — that is not a Contextify directory.\n\n' "${INSTALL_DIR:-<empty>}" >&2
    exit 1
    ;;
esac
# A real install always has these. Without them we are pointed at something
# else and must not touch it.
if [ -e "$INSTALL_DIR" ] &&
   [ ! -f "$INSTALL_DIR/dist/server.js" ] &&
   [ ! -f "$INSTALL_DIR/package.json" ]; then
  printf '\nerror %s does not look like a Contextify install; refusing to delete it.\n' "$INSTALL_DIR" >&2
  printf '      Pass --dir if it is somewhere else.\n\n' >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --keep-claude-settings) KEEP_SETTINGS=1 ;;
    -h|--help)
      cat <<'HELPTEXT'
Contextify uninstaller

USAGE
  uninstall.sh [--keep-claude-settings]

Removes the proxy, the background service, the `contextify` command, and the
Claude Code hook. Never uses sudo; touches nothing outside your home directory.
HELPTEXT
      exit 0
      ;;
  esac
done

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; GREEN=""; YELLOW=""; RESET=""
fi
step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()   { printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %swarn%s %s\n' "$YELLOW" "$RESET" "$*"; }

printf '\n%sRemoving Contextify%s\n\n' "$BOLD" "$RESET"

# ── 1. Unhook Claude Code ────────────────────────────────────────────────────
step "Unhooking Claude Code"
if [ "$KEEP_SETTINGS" -eq 1 ]; then
  warn "left ~/.claude/settings.json untouched (--keep-claude-settings)"
elif [ -f "$INSTALL_DIR/dist/contextify.js" ] && command -v node >/dev/null 2>&1; then
  # The CLI restores whatever ANTHROPIC_BASE_URL was there before, which a
  # blind delete cannot do.
  node "$INSTALL_DIR/dist/contextify.js" uninstall >/dev/null 2>&1 &&
    ok "hook removed and previous settings restored" ||
    warn "the CLI could not unhook; falling back to editing settings.json"
fi

# Belt and braces: if the CLI was already gone, or failed, strip the key
# directly. Only that one key is touched, and only if it points at loopback —
# someone else's proxy setting is not ours to delete.
SETTINGS="$HOME/.claude/settings.json"
if [ "$KEEP_SETTINGS" -eq 0 ] && [ -f "$SETTINGS" ] && command -v node >/dev/null 2>&1; then
  node - "$SETTINGS" <<'NODE'
const { readFileSync, writeFileSync, copyFileSync } = require('node:fs');
const file = process.argv[2];
try {
  const raw = readFileSync(file, 'utf8');
  const settings = JSON.parse(raw);
  const url = settings?.env?.ANTHROPIC_BASE_URL;
  if (typeof url === 'string' && /^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])/.test(url)) {
    copyFileSync(file, `${file}.contextify-removed`);
    delete settings.env.ANTHROPIC_BASE_URL;
    if (Object.keys(settings.env).length === 0) delete settings.env;
    writeFileSync(file, `${JSON.stringify(settings, null, 2)}\n`, 'utf8');
    console.log('  ok   ANTHROPIC_BASE_URL removed from settings.json');
  }
} catch {
  // Unparseable or absent settings are not ours to rewrite.
}
NODE
fi
rm -f "$HOME/.claude/commands/contextify.md" 2>/dev/null && ok "/contextify slash command removed"

# ── 2. Stop and deregister the background service ────────────────────────────
step "Stopping the proxy"
case "$(uname -s)" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/com.contextify.proxy.plist"
    launchctl bootout "gui/$(id -u)/com.contextify.proxy" >/dev/null 2>&1
    launchctl unload -w "$PLIST" >/dev/null 2>&1
    if [ -f "$PLIST" ]; then rm -f "$PLIST" && ok "launchd service removed"; else ok "no launchd service"; fi
    ;;
  Linux)
    systemctl --user disable --now contextify.service >/dev/null 2>&1
    UNIT="$HOME/.config/systemd/user/contextify.service"
    if [ -f "$UNIT" ]; then
      rm -f "$UNIT"
      systemctl --user daemon-reload >/dev/null 2>&1
      ok "systemd unit removed"
    else
      ok "no systemd unit"
    fi
    ;;
esac

# Anything still holding the port: a proxy started by hand, or one the service
# manager has lost track of.
if pkill -f "$INSTALL_DIR/dist/server.js" >/dev/null 2>&1; then
  ok "stopped a running proxy process"
fi

# ── 3. Remove the files ──────────────────────────────────────────────────────
step "Removing files"
if [ -f "$BIN_DIR/contextify" ]; then
  rm -f "$BIN_DIR/contextify" && ok "$BIN_DIR/contextify removed"
fi
if [ -d "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_DIR" && ok "$INSTALL_DIR removed"
else
  ok "nothing at $INSTALL_DIR"
fi

printf '\n%sDone.%s Claude Code now talks straight to api.anthropic.com.\n' "$BOLD" "$RESET"
printf '%s\n' "${DIM}Backups of settings.json are kept beside it as *.contextify-backup-* files.${RESET}"
printf '\nReinstall with:\n  %scurl -fsSL https://contextifyai.com/install.sh | bash%s\n\n' "$BOLD" "$RESET"
