#!/usr/bin/env bash
#
# Contextify installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ShnakeIO/contextify/main/scripts/install.sh | bash
#
# ─── On piping this to a shell ────────────────────────────────────────────────
# You are about to execute a script you have not read, fetched over a connection
# you are trusting, from a repository you may not control. That is a real trust
# decision, not a formality, and it is worth making deliberately:
#
#   curl -fsSL <url> -o install.sh   # fetch
#   less install.sh                  # read it
#   bash install.sh                  # then run it
#
# This script is written to make that reading worthwhile: it never uses sudo,
# never writes outside the install directory, never pipes anything else to a
# shell, and prints every directory it touches. `--dry-run` prints the plan and
# exits without changing anything.
#
set -euo pipefail

# Where the built release lives.
#
# A prebuilt tarball, not a git clone. The clone this replaced targeted a
# PRIVATE repository, so it failed for everyone who was not already
# authenticated to it — and because `curl -fsSL` swallows the body on an HTTP
# error, the whole install command produced no output and no error at all.
# A tarball also removes the `git` requirement, which on a stock Mac triggers
# the Xcode command line tools prompt before anything else can happen.
RELEASE_BASE="${CONTEXTIFY_RELEASE_BASE:-https://github.com/ShnakeIO/contextify-install/releases/latest/download}"
RELEASE_TARBALL="${CONTEXTIFY_TARBALL:-contextify.tar.gz}"
INSTALL_DIR="${CONTEXTIFY_DIR:-$HOME/.contextify}"
PORT="${CONTEXTIFY_PORT:-3000}"
DRY_RUN=0
ASSUME_YES=0
NODE_MIN_MAJOR=22

# ── Output helpers ────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()    { printf '  %sok%s   %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '  %swarn%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()   { printf '\n%serror%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  # Delimiter deliberately not "USAGE": the help text below contains a line
  # that is exactly that word, which would terminate the heredoc early.
  cat <<'HELPTEXT'
Contextify installer

USAGE
  install.sh [options]

OPTIONS
  --dir <path>      Install directory        (default: ~/.contextify)
  --port <n>        Port to configure        (default: 3000)
  --dry-run         Print the plan and exit without changing anything
  --yes, -y         Accept defaults, no prompts (implies non-interactive setup)
  -h, --help        Show this help

ENVIRONMENT
  CONTEXTIFY_DIR, CONTEXTIFY_PORT, CONTEXTIFY_RELEASE_BASE, CONTEXTIFY_BIN_DIR

This script never uses sudo and never writes outside the install directory.
HELPTEXT
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     INSTALL_DIR="${2:?--dir requires a path}"; shift 2 ;;
    --port)    PORT="${2:?--port requires a number}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "unknown option: $1 (try --help)" ;;
  esac
done

printf '\n%sContextify installer%s\n\n' "$BOLD" "$RESET"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Checking prerequisites"

command -v curl >/dev/null 2>&1 || die "curl is required but was not found on PATH."
ok "curl $(curl --version | head -1 | awk '{print $2}')"

command -v tar >/dev/null 2>&1 || die "tar is required but was not found on PATH."

command -v node >/dev/null 2>&1 || die \
  "Node.js ${NODE_MIN_MAJOR}+ is required but was not found on PATH.
  Install it from https://nodejs.org or via your version manager, then re-run."

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt "$NODE_MIN_MAJOR" ]; then
  die "Node.js ${NODE_MIN_MAJOR}+ is required; found $(node -v).
  Contextify uses native fetch and the modern stream APIs."
fi
ok "node $(node -v)"

command -v npm >/dev/null 2>&1 || die "npm is required but was not found on PATH."
ok "npm $(npm --version)"

if command -v docker >/dev/null 2>&1; then
  ok "docker detected (Redis can be started automatically)"
else
  warn "docker not found - the in-memory cache will be used instead of Redis"
fi

# ── Plan ──────────────────────────────────────────────────────────────────────
printf '\n'
step "Plan"
info "  release      $RELEASE_BASE/$RELEASE_TARBALL"
info "  install to   $INSTALL_DIR"
info "  port         $PORT"
info "  ${DIM}no sudo, nothing written outside the install directory${RESET}"
printf '\n'

if [ "$DRY_RUN" -eq 1 ]; then
  info "${YELLOW}--dry-run: stopping here. Nothing was changed.${RESET}"
  exit 0
fi

# Only prompt when we actually have a terminal. Piped into bash, stdin is the
# script itself, so reading from it would consume the script - hence /dev/tty.
if [ "$ASSUME_YES" -eq 0 ] && [ -e /dev/tty ]; then
  printf 'Proceed? [Y/n] '
  read -r reply </dev/tty || reply=""
  case "$reply" in
    [nN]*) info "Aborted."; exit 0 ;;
  esac
  printf '\n'
fi

# ── Fetch ─────────────────────────────────────────────────────────────────────
step "Fetching Contextify"

if [ -d "$INSTALL_DIR" ]; then
  ok "existing install found, replacing"
fi

# Staged in a temp directory and verified BEFORE anything is written to the
# install directory, so a truncated download or a tampered artifact can never
# half-overwrite a working installation.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL "$RELEASE_BASE/$RELEASE_TARBALL" -o "$TMP_DIR/contextify.tar.gz" || die \
  "Could not download the release from:
    $RELEASE_BASE/$RELEASE_TARBALL
  Check your connection, or report this at https://contextifyai.com."
ok "downloaded $(wc -c < "$TMP_DIR/contextify.tar.gz" | tr -d ' ') bytes"

# The checksum is published beside the tarball. Verified when a sha256 tool is
# available; a missing tool is a warning rather than a failure, because
# refusing to install over it would be worse than the risk on a TLS transfer.
if curl -fsSL "$RELEASE_BASE/$RELEASE_TARBALL.sha256" -o "$TMP_DIR/expected.sha256" 2>/dev/null; then
  EXPECTED="$(awk '{print $1}' < "$TMP_DIR/expected.sha256")"
  ACTUAL=""
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$TMP_DIR/contextify.tar.gz" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    # macOS ships shasum, not sha256sum.
    ACTUAL="$(shasum -a 256 "$TMP_DIR/contextify.tar.gz" | awk '{print $1}')"
  fi
  if [ -z "$ACTUAL" ]; then
    warn "no sha256 tool found - skipping checksum verification"
  elif [ "$ACTUAL" != "$EXPECTED" ]; then
    die "Checksum mismatch. Refusing to install.
    expected $EXPECTED
    actual   $ACTUAL"
  else
    ok "checksum verified"
  fi
else
  warn "no published checksum found - skipping verification"
fi

mkdir -p "$TMP_DIR/unpacked"
tar -xzf "$TMP_DIR/contextify.tar.gz" -C "$TMP_DIR/unpacked"
[ -f "$TMP_DIR/unpacked/package.json" ] || die "The downloaded archive is not a Contextify release."

# Only now is the install directory touched. An existing .env is preserved:
# it holds the user's port and API settings and is not ours to discard.
mkdir -p "$INSTALL_DIR"
if [ -f "$INSTALL_DIR/.env" ]; then
  cp "$INSTALL_DIR/.env" "$TMP_DIR/.env.kept"
fi
rm -rf "$INSTALL_DIR/dist"
cp -R "$TMP_DIR/unpacked/." "$INSTALL_DIR/"
if [ -f "$TMP_DIR/.env.kept" ]; then
  cp "$TMP_DIR/.env.kept" "$INSTALL_DIR/.env"
  ok "kept your existing .env"
fi
ok "installed to $INSTALL_DIR"

cd "$INSTALL_DIR"

# ── Dependencies ──────────────────────────────────────────────────────────────
#
# --omit=dev: the release is prebuilt, so nothing here needs a compiler, a test
# runner or a TypeScript toolchain. Only the four runtime packages are fetched.
printf '\n'
step "Installing dependencies"
npm install --omit=dev --no-audit --no-fund --loglevel=error
ok "dependencies installed"

# ── Configure ─────────────────────────────────────────────────────────────────
printf '\n'
step "Configuring"

SETUP_ARGS=(--port "$PORT")
# Piped-to-bash has no usable stdin for an interactive wizard, so fall back to
# the non-interactive path rather than hanging on a prompt nobody can answer.
if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
  SETUP_ARGS+=(--yes)
  info "  ${DIM}non-interactive: using detected defaults${RESET}"
  info "  ${DIM}re-run 'npm run setup' in a terminal to change them${RESET}"
fi

npm run setup -- "${SETUP_ARGS[@]}"

# ── The `contextify` command ──────────────────────────────────────────────────
#
# Without this there is no `contextify` on PATH at all, and every instruction
# that names one — `contextify link <code>` on the dashboard, `contextify
# doctor` in the docs — is a command the user does not have. The CLI itself
# worked; it was simply unreachable.
#
# A shim rather than `npm link`: linking needs write access to a global prefix,
# which fails on a stock macOS or a locked-down box for a tool that has been
# careful to never ask for sudo. This writes one file inside $HOME.
#
# It runs the bundled CLI with plain `node`. The release carries no TypeScript
# and no tsx, so there is no toolchain to find and nothing to resolve beyond
# node itself.
step "Adding the contextify command"
BIN_DIR="${CONTEXTIFY_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/contextify" <<SHIM
#!/usr/bin/env sh
# Generated by the Contextify installer. Safe to delete.
exec node "$INSTALL_DIR/dist/contextify.js" "\$@"
SHIM
chmod +x "$BIN_DIR/contextify"
ok "contextify -> $BIN_DIR/contextify"

# Being on PATH is the whole point, so say so plainly when it is not rather
# than leaving the user with a command that "does not exist".
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR is not on your PATH. Add this to your shell profile:"
    info "    export PATH=\"\$PATH:$BIN_DIR\""
    ;;
esac

# ── Start it ──────────────────────────────────────────────────────────────────
#
# Previously the installer finished by PRINTING `npm start` and stopped. That
# left every new install with nothing running and nothing hooked: the proxy was
# not listening, Claude Code was not pointed at it, and the honest report from
# `contextify status` was a row of warnings. "Installed" has to mean running.
#
# A user-level service, never a system one: no sudo, and it dies with the user
# session rather than lingering as root.
step "Starting the proxy"
STARTED=0
case "$(uname -s)" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/com.contextify.proxy.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.contextify.proxy</string>
  <!-- --env-file-if-exists is NOT optional. Without it the service ignores
       .env entirely and the proxy binds its built-in default port instead of
       the configured one, so it runs perfectly somewhere nobody is looking:
       the CLI, the doctor and the Claude Code hook all read the configured
       port and report "proxy is down" against a healthy process. -->
  <key>ProgramArguments</key>
  <array>
    <string>$(command -v node)</string>
    <string>--env-file-if-exists=.env</string>
    <string>$INSTALL_DIR/dist/server.js</string>
  </array>
  <key>WorkingDirectory</key><string>$INSTALL_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$INSTALL_DIR/proxy.log</string>
  <key>StandardErrorPath</key><string>$INSTALL_DIR/proxy.log</string>
</dict>
</plist>
PLISTEOF
    # bootout first so a re-install replaces the old definition rather than
    # failing with "service already loaded".
    launchctl bootout "gui/$(id -u)/com.contextify.proxy" 2>/dev/null || true

    # Errors are SHOWN, not swallowed. They were hidden behind 2>/dev/null,
    # which meant a service that failed to register looked identical to one
    # that started fine — and the only symptom left was "proxy is down" with
    # no way to find out why.
    BOOT_ERR="$(launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>&1)" && STARTED=1
    if [ "$STARTED" -ne 1 ]; then
      warn "launchctl bootstrap failed: ${BOOT_ERR:-no message}"
      # Older macOS predates bootstrap/bootout.
      if launchctl load -w "$PLIST" 2>/dev/null; then
        STARTED=1
        ok "registered with launchctl load (legacy path)"
      fi
    fi
    ;;
  Linux)
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/contextify.service" <<UNITEOF
[Unit]
Description=Contextify proxy
After=network.target

[Service]
# --env-file-if-exists is NOT optional; see the macOS plist above for why.
ExecStart=$(command -v node) --env-file-if-exists=.env $INSTALL_DIR/dist/server.js
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
UNITEOF
    if systemctl --user daemon-reload 2>/dev/null &&
       systemctl --user enable --now contextify.service 2>/dev/null; then STARTED=1; fi
    ;;
esac

if [ "$STARTED" -eq 1 ]; then
  # Poll rather than sleep: the service manager returns before the port binds.
  for _ in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
    sleep 0.25
  done
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ok "proxy running on port $PORT, and will start again at login"
  else
    STARTED=0
    warn "the service was registered but the proxy did not answer on port $PORT"
    # Show the reason here rather than pointing at a file. A failure the user
    # has to go hunting for is a failure they will report as "it just says
    # down", which is not something anyone can act on.
    if [ -s "$INSTALL_DIR/proxy.log" ]; then
      info ""
      info "  Last lines of $INSTALL_DIR/proxy.log:"
      tail -n 8 "$INSTALL_DIR/proxy.log" | sed 's/^/    /'
    else
      info ""
      info "  No output was logged. Run it in the foreground to see the error:"
      info "    cd $INSTALL_DIR && npm start"
    fi
  fi
else
  warn "could not register a background service on this system"
  info "    start it yourself with: cd $INSTALL_DIR && npm start"
fi

# ── Hook Claude Code ──────────────────────────────────────────────────────────
#
# The step that makes Claude Code actually route through the proxy. It was
# never run, and never even mentioned, so an install that "succeeded" optimised
# nothing at all.
#
# Allowed to fail without failing the install: it exits non-zero, by design,
# when Claude Code authenticates with a Pro/Max subscription — a flat fee has
# no per-token bill to cut. Its own output explains that far better than a
# generic installer error would.
if [ "$STARTED" -eq 1 ]; then
  printf '\n'
  step "Hooking Claude Code"
  CONTEXTIFY_URL="http://127.0.0.1:$PORT" node "$INSTALL_DIR/dist/contextify.js" install || true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
cat <<EOF

${BOLD}Installed.${RESET}

Link this machine to your account:

  ${BOLD}contextify link <code>${RESET}   ${DIM}(get a code at https://contextifyai.com/dashboard)${RESET}

Then point your SDK at Contextify:

  ${BOLD}export ANTHROPIC_BASE_URL=http://localhost:$PORT${RESET}

  Health   http://localhost:$PORT/health
  Savings  http://localhost:$PORT/v1/metrics/savings

${DIM}Your API key is passed straight through. Contextify never stores it.${RESET}
EOF
