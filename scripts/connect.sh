#!/bin/bash
# Connect anything to Moe. One entry point; Hermes does the work.
#
#   connect.sh                          what is available, grouped, ✓ = connected
#   connect.sh <name>                   connect it (see "dispatch" below);
#                                       skill/notion, platform/telegram pick a kind
#   connect.sh --url <name> <url>       any remote MCP server, by URL (advanced)
#   connect.sh --command <name> <cmd> [args…]   any local (stdio) MCP server (advanced)
#   connect.sh --remove <name>          disconnect and forget the credential
#   connect.sh --remove gmail [address] one mailbox, or the only one there is
#   connect.sh --status [<name>]        real status, one line per connection
#   connect.sh composio/<service> --key paste a key for a brokered service
#                                       Composio holds no sign-in for (asked,
#                                       or KEY=value lines when the app drives)
#   connect.sh --fields composio/<service>   what that key flow will ask for,
#                                       as JSON — the app reads it before it
#                                       draws the paste sheet
#
# Dispatch, by where the name comes from:
#   Mac native   gmail telegram whatsapp → the existing connect-*.sh
#                (there is no Google row: Calendar and Contacts come from
#                Calendar.app and Contacts.app, Gmail from an app password
#                — CONNECTORS.md §Google: the decision)
#   MCP catalog  hermes mcp install <name>, then hermes mcp login <name> when
#                the server uses OAuth (65+ servers: notion, linear, slack…)
#   skill        asked for each credential, written to ~/.hermes/.env
#   platform     slack, discord, email, signal, … → the bot token, written
#                to ~/.hermes/.env, and platforms.<name>.enabled: true in
#                config.yaml (through `hermes config set`). Who may talk to
#                the bot is decided by pairing afterwards (pairing.sh), not
#                asked here.
#   telegram-bot the one-click managed bot (connect-telegram-bot.sh: a
#                t.me link, tap "Create Bot", done); `--token` instead pastes
#                a BotFather token
#   auth         spotify → the spotify catalog plugin (installed on first
#                use), then its own `hermes spotify login`
#
# Browsers. Nothing here opens one: every URL is printed for you to open.
# Hermes's OAuth code opens the browser itself on a Mac and has no flag to
# stop it, but it stays closed when it believes it is on an SSH session, so
# every hermes call below runs with SSH_TTY set. The one cost is that Hermes
# then prints "ssh -L …" tunnel advice — ignore it, the callback on
# 127.0.0.1 works directly. `--open <name>` lets Hermes open the browser
# after all (the single allowed exception, and only when you ask).
#
# Machine lines, for the app (Connections screen), always on stdout, never
# carrying a secret:
#   SIGN_IN_URL=<url>        every sign-in URL, once, whatever Hermes wrote it in
#   NEEDS_RESTART=gateway    a chat platform was added or removed; the gateway
#                            only reads .env/config.yaml at start, and
#                            restarting it is the app's job (HermesSupervisor)
# Set MOE_CONNECT_NONINTERACTIVE=1 and nothing is asked: the answers come as
# `KEY=value` lines on stdin (one per credential), read before anything runs.
# A missing required key is a plain "✗ KEY is required." exit 1, never a hang
# on a closed stdin.
#
# Redirection for tests: HERMES_HOME, HERMES_AGENT_DIR, HERMES_BIN (or a
# `hermes` first on PATH), MOE_HOME. Nothing is written outside HERMES_HOME.
# Bash 3.2 and `set -u` clean; secrets are read with `read -s` and travel
# to the .env writer over stdin, never argv.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME
MOE="${MOE_HOME:-$HOME/.moe}"
CONN="$MOE/connectors"
[ -x "$CONN/hermes-connections.py" ] || CONN="$HERE/../moe-home/connectors"
CATALOG="$CONN/hermes-catalog.py"
CONNECTIONS="$CONN/hermes-connections.py"
[ -x "$CATALOG" ] && [ -x "$CONNECTIONS" ] || {
  echo "✗ $CONN has no hermes-catalog.py / hermes-connections.py — re-run scripts/install.sh" >&2; exit 1; }

HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
[ -n "$HERMES_BIN" ] || HERMES_BIN="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}/.venv/bin/hermes"
if [ ! -x "$HERMES_BIN" ]; then
  echo "✗ Moe's brain is not installed (looked on PATH and in $HERMES_BIN). Run scripts/install.sh first." >&2
  exit 1
fi

OPEN_BROWSER=0
NONINTERACTIVE="${MOE_CONNECT_NONINTERACTIVE:-}"

# ── Tell Moe, now, that this changed ─────────────────────────────────────
#
# context/_connections.md is the one thing the model is told about which
# services exist — it goes into the system prompt, because the claude-code
# child runs with Read disallowed and cannot open a file to find out. Until
# 2026-09-07 the ONLY writer of that file was sync.sh's ten-minute tick, so
# the ten minutes after a person connected something were the ten minutes in
# which Moe would tell them, in the local connector's own words, that "no
# mailbox is added yet" and offer to walk them through connecting the thing
# they had just connected. Measured on the owner's Mac: connected 21:34,
# asked 21:36, file rewritten 21:47.
#
# It goes HERE, not in the app, because this script is what every route to a
# connection change passes through — the Connections pane, a terminal, and
# Moe's own tools — and a refresh that only the app performs is one the model
# and the terminal walk straight past.
#
# The list below is of READS, not of writes, and that direction is the whole
# design: a verb added later refreshes unless someone deliberately says it
# does not. A guard that enumerates the ways of changing something is walked
# past by the next way (CLAUDE.md); enumerating the two ways of changing
# nothing cannot be.
REFRESH=1
refresh_connections() {
  [ "$REFRESH" = 1 ] || return 0
  # Never fails a connect: the account is connected either way, and the
  # ten-minute sync is still behind this. Backgrounded so a person who has
  # just signed in is not left watching a spinner for a network read they
  # did not ask for — and every fd redirected inside the group, because the
  # app reads this script's stdout to EOF and a child still holding that
  # pipe would keep the Connections sheet spinning after the work was done.
  ( MOE_HOME="$MOE" python3 "$CONNECTIONS" refresh || true ) >/dev/null 2>&1 </dev/null &
  # Tests (and anyone who wants determinism) can ask for the synchronous
  # version: a background write is unobservable to the caller by design.
  if [ "${MOE_CONNECT_REFRESH_SYNC:-0}" = 1 ]; then wait; fi
  return 0
}
# Armed further down, in the ONE exit trap (`on_exit`). It cannot be armed
# here: `trap … EXIT` replaces rather than adds, and the temp-directory
# cleanup below would disarm it.

# Every hermes subprocess: our HERMES_HOME, no browser (see the header),
# no bytecode in a checkout we do not own. Unbuffered, because a sign-in
# URL printed into a pipe (the app's) must arrive before the callback that
# only the user can trigger by opening it.
hermes() {
  if [ "$OPEN_BROWSER" = 1 ]; then
    HERMES_HOME="$HERMES_HOME" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 "$HERMES_BIN" "$@"
  else
    HERMES_HOME="$HERMES_HOME" SSH_TTY="${SSH_TTY:-moe}" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 "$HERMES_BIN" "$@"
  fi
}

# Pass Hermes's output through and, the first time a line carries a URL,
# add the machine line the app reads. Hermes prints the URL to stderr with
# indentation and sometimes a trailing sentence; the URL is the first
# https:// word on the line.
mark_sign_in_url() {
  local line word marked=""
  while IFS= read -r line; do
    printf '%s\n' "$line"
    [ -n "$marked" ] && continue
    case "$line" in
      # Never Hermes's own pages. A setup wizard's "Full guide:" line is the
      # first link Hermes prints for Spotify, and this marked it: the app
      # opened hermes-agent.nousresearch.com as "sign in to Spotify"
      # (2026-09-30). A sign-in is the service's page, never the engine's docs.
      *https://*nousresearch.com*|*https://github.com/NousResearch*) ;;
      *https://*)
        # No word splitting (a `?` or `*` in the URL would glob): cut with
        # parameter expansion — from the first https:// to the next blank.
        word="https://${line#*https://}"
        word="${word%%[[:space:]]*}"
        printf 'SIGN_IN_URL=%s\n' "$word"; marked=1 ;;
    esac
  done
}

# `read` on a closed stdin fails silently under set -e; say what was needed.
ask() { # var prompt [secret]
  local _in                     # not `v`: callers pass that name and a local would shadow it
  if [ "${3:-}" = secret ]; then
    if ! read -r -s -p "$2" _in; then echo; echo "✗ No input (not a terminal?)"; exit 1; fi
    echo
  else
    if ! read -r -p "$2" _in; then echo; echo "✗ No input (not a terminal?)"; exit 1; fi
  fi
  eval "$1=\$_in"
}

# A credential, by env name: the non-interactive answer file when the app is
# driving, else a prompt. Empty when non-interactive and not supplied — the
# caller decides whether that is fatal.
ask_value() { # var KEY prompt [secret]
  if [ -n "$NONINTERACTIVE" ]; then
    local _line
    _line="$(grep -m1 "^$2=" "$ANSWERS" 2>/dev/null || true)"
    _line="${_line%$'\r'}"        # a pasted value may carry a CR; never write one to .env
    eval "$1=\${_line#*=}"
  else
    ask "$1" "$3" "${4:-}"
  fi
}

# ~/.hermes/.env, line by line: other lines and comments survive verbatim,
# the file ends up 0600, the write is atomic. Hermes reads .env on every
# turn and enables a platform from the presence of its token, so this IS
# Hermes's mechanism — its own wizard writes the same file the same way
# (hermes_cli.config.save_env_value), it just cannot be driven without a
# TTY and `hermes config set KEY VALUE` would put the secret on argv.
#   env_set KEY      value on stdin (one line)
#   env_unset KEY…   delete
env_set()   { python3 "$CONN/hermeslib.py" dotenv-set "$1"; }
env_unset() { python3 "$CONN/hermeslib.py" dotenv-unset "$@"; }

# platforms.<name>.enabled in ~/.hermes/config.yaml, through Hermes's own
# writer (`hermes config set` → hermes_cli.config.set_config_value: reads the
# raw file, sets the dotted key, coerces "true"/"false" to booleans, writes
# it back). The token in .env already makes the gateway start the platform,
# but the explicit flag is what config.yaml readers — Hermes's dashboard,
# hermes-connections.py, a user with an editor — see as the intent, and an
# earlier `enabled: false` left behind by a wizard would otherwise win.
# Non-fatal: a refused write (config.yaml unreadable, managed install) is
# reported and the token still stands.
platform_enabled() { # name true|false
  local out
  if out="$(hermes config set "platforms.$1.enabled" "$2" 2>&1)"; then
    echo "✓ config.yaml: platforms.$1.enabled: $2"
  else
    echo "… could not set platforms.$1.enabled in config.yaml ($(printf '%s' "$out" | tail -n 1))"
  fi
  return 0
}

# Catalog lookup: prints "<kind>\t<auth>\t<credentials space-separated>\t<allowed_users>"
# or nothing. A name can exist in more than one kind (notion is an OAuth MCP
# server *and* an API-key skill; airtable too): the MCP server wins, being
# the one-click path, and "skill/notion" or "platform/telegram" picks a kind.
lookup() { # name [kind]
  "$CATALOG" --json | python3 -c '
import json, sys
want, only = sys.argv[1], sys.argv[2]
cat = json.load(sys.stdin)
for kind in ("mcp", "skills", "platforms"):
    for e in cat[kind]:
        if e["name"] == want and (not only or e["kind"] == only):
            print("%s\t%s\t%s\t%s\t%s" % (e["kind"], e["auth"], " ".join(e.get("credentials", [])), e.get("allowed_users", ""), e.get("provider", "")))
            raise SystemExit
' "$1" "${2:-}"
}

# "skill/notion" → NAME=notion ONLY=skill; "notion" → ONLY="".
split_kind() {
  case "$1" in
    */*) ONLY="${1%%/*}"; NAME="${1#*/}" ;;
    *)   ONLY=""; NAME="$1" ;;
  esac
  # composio is a kind here even though Hermes's catalog has no such kind:
  # the catalog holds the SERVER, and a composio/<service> row is one of the
  # ~500 services behind it. Without this line every composio branch below is
  # unreachable — split_kind runs first and exits 2.
  case "$ONLY" in ''|mcp|skill|platform|composio) ;; *) echo "✗ kind must be mcp, skill, platform or composio" >&2; exit 2 ;; esac
}

is_connected() { "$CONNECTIONS" names 2>/dev/null | grep -qx "$1"; }

# ── Listing ───────────────────────────────────────────────────────────────

cmd_list() {
  echo "Connect to Moe — everything Moe can reach, plus the Mac"
  echo "══════════════════════════════════════════════════════════"
  echo
  echo "Mac native (no setup, or one click in System Settings)"
  echo "  calendar reminders notes contacts imessage calls call-recordings"
  echo "  (Calendar.app already includes your Google calendars — nothing to connect)"
  echo "  gmail       Gmail, read and send, with an app password              connect.sh gmail"
  echo "  drive-docs  Google Docs and Sheets you pick — their contents        connect.sh drive-docs"
  echo "  telegram    your Telegram chats (phone login)                        connect.sh telegram"
  echo "  whatsapp    WhatsApp — scan one QR code (read the warning first)      connect.sh whatsapp"
  echo "  signal      Signal — scan one QR code, then talk in Note to Self      connect.sh signal"
  echo
  "$CONNECTIONS" names > "$TMP/connected" 2>/dev/null || true
  "$CATALOG" --json > "$TMP/catalog.json"
  python3 - "$TMP/catalog.json" "$TMP/connected" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1]))
connected = set(open(sys.argv[2]).read().split())
def row(kind, e, extra):
    mark = "✓" if "%s/%s" % (kind, e["name"]) in connected else " "
    print("  %s %-20s %s" % (mark, e["name"], extra))
print("Services (%d)                             connect.sh <name>" % len(cat["mcp"]))
for e in cat["mcp"]:
    row("mcp", e, "%-8s %s" % (e["auth"], e["description"]))
print()
print("Skills with a credential (%d)" % len(cat["skills"]))
for e in cat["skills"]:
    row("skill", e, "%-8s %s" % (e["auth"], e["description"]))
print()
print("Chat platforms — talk to Moe from your phone (%d)" % len(cat["platforms"]))
for e in cat["platforms"]:
    row("platform", e, "%-28s %s" % (e["label"], ", ".join(e["credentials"])))
print()
print("  %s %-20s Spotify (hermes spotify login)" % ("✓" if "auth/spotify" in connected else " ", "spotify"))
PY
  echo
  echo "Any other MCP server:  connect.sh --url <name> <https://…>   (advanced — read the warning it prints)"
  echo "Disconnect:            connect.sh --remove <name>"
}

# ── The kinds ─────────────────────────────────────────────────────────────

warn_untrusted() {
  cat <<'EOF'
⚠  You are adding a server Hermes has not reviewed. An MCP server sees
   whatever the agent hands it, and its tool descriptions are text it
   controls that lands in the model's context. Moe's confirm-before-send
   rule still applies to every tool it exposes; nothing else does.
   (CONNECTORS.md — "Curation is a security requirement".)
EOF
}

oauth_login() { # name
  local name="$1"
  echo
  if [ "$OPEN_BROWSER" = 1 ]; then
    echo "Moe will open your browser to sign in to $name."
  else
    echo "A sign-in URL is printed below. Open it yourself; nothing is opened for you."
    echo "Ignore any 'ssh -L' tunnel advice it prints — the callback on 127.0.0.1 works"
    echo "directly on this Mac. If the browser cannot reach it, paste the redirected URL back."
  fi
  echo
  # `hermes mcp login` exits 0 whatever happened; the token file is the proof.
  hermes mcp login "$name" 2>&1 | mark_sign_in_url || true
  local safe
  safe="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-\n' '_')"
  if [ -s "$HERMES_HOME/mcp-tokens/$safe.json" ]; then
    echo "✓ $name signed in."
  else
    echo "… no token saved for $name yet. Re-run: connect.sh $name"
    return 1
  fi
}

connect_mcp() { # name auth provider credentials…
  local name="$1" auth="$2" provider="${3:-}"; shift 3
  if is_connected "mcp/$name"; then
    # Installed is not signed in. A server whose sign-in ran out (Hermes
    # deletes the token when a refresh is refused) is still installed, and
    # this used to say "already set up" and stop — so Reconnect on
    # Cloudflare opened nothing, ever (2026-09-30). No token: sign in again.
    local safe
    safe="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-\n' '_')"
    if [ "$auth" = oauth ] && [ -z "$provider" ] && [ ! -s "$HERMES_HOME/mcp-tokens/$safe.json" ]; then
      echo "$name is installed but signed out — signing in again."
      oauth_login "$name"
      return
    fi
    echo "$name is already set up:"; "$CONNECTIONS" status "mcp/$name" || true
    echo "connect.sh --remove $name to start over."
    return 0
  fi
  echo "Installing ${name}…"
  # api-key servers: Hermes's installer asks for the key itself and writes
  # it to .env; tool selection is skipped without a TTY and kept otherwise.
  # Driven by the app there is no TTY to ask at, so the keys go into .env
  # first — the installer sees them "already set" and asks nothing
  # (mcp_catalog._prompt_env_vars).
  if [ "$auth" = api-key ] && [ -n "$NONINTERACTIVE" ] && [ $# -gt 0 ]; then
    collect_env "$@"
  fi
  hermes mcp install "$name"
  if [ "$auth" = oauth ] && [ -n "$provider" ]; then
    # Hermes's "case 2": the token comes from `hermes auth <provider>`, not
    # from the MCP login flow (mcp_catalog.install_entry says the same).
    echo "$name signs in through $provider. A URL is printed; open it yourself."
    hermes auth "$provider" 2>&1 | mark_sign_in_url
  elif [ "$auth" = oauth ]; then
    oauth_login "$name"
  fi
  echo "Moe picks the server up on its next conversation."
}

connect_mcp_url() { # name url
  local name="$1" url="$2"
  warn_untrusted
  local auth
  ask_value auth AUTH "Does $url need a sign-in? [oauth/key/none] (none): "
  case "${auth:-none}" in
    oauth) hermes mcp add "$name" --url "$url" --auth oauth; oauth_login "$name" ;;
    key)   hermes mcp add "$name" --url "$url" --auth header ;;   # Hermes prompts for the key
    *)     hermes mcp add "$name" --url "$url" ;;
  esac
  echo "Moe picks the server up on its next conversation."
}

connect_mcp_command() { # name cmd args…
  local name="$1"; shift
  warn_untrusted
  echo "This runs '$*' on your Mac with your user's permissions whenever Moe uses it."
  if [ $# -gt 1 ]; then
    hermes mcp add "$name" --command "$1" --args "${@:2}"
  else
    hermes mcp add "$name" --command "$1"
  fi
  echo "Moe picks the server up on its next conversation."
}

# Ask for each env var and write it. Secrets are typed blind; the rest echo.
collect_env() { # var…
  local k v
  for k in "$@"; do
    case "$k" in
      *_ALLOW_ALL_USERS|*_ENABLED) continue ;;   # never prompt for these
      *TOKEN*|*SECRET*|*KEY*|*PASSWORD*|*PRIVATE*) ask_value v "$k" "$k: " secret ;;
      *) ask_value v "$k" "$k: " ;;
    esac
    [ -n "$v" ] || { echo "✗ $k is required."; exit 1; }
    printf '%s\n' "$v" | env_set "$k"
    v=""
  done
}

connect_skill() { # name credentials…
  local name="$1"; shift
  local envs="" f
  for f in "$@"; do
    case "$f" in
      *.*) echo "✗ $name needs the file ~/.hermes/$f, which this script cannot create — see its SKILL.md."; exit 1 ;;
      *)   envs="$envs $f" ;;
    esac
  done
  echo "Connecting '$name'. Its credentials go to $HERMES_HOME/.env (owner-only)."
  # shellcheck disable=SC2086
  collect_env $envs
  echo "✓ $name configured. Moe picks it up on its next turn."
}

# Who may talk to the bot is not asked here. Hermes denies everyone until
# they are paired: the first person to message the bot gets a code, the
# app shows "Approve" (pairing.sh list / approve, or `hermes pairing`), and
# that person is on the allowlist from then on. One tap beats typing a
# numeric user ID nobody knows. An allowed-users line given on stdin in
# non-interactive mode is still honoured, for the app's advanced field.
connect_platform() { # name credentials allowed_users
  local name="$1" creds="$2" allowed="$3"
  if [ "$name" = signal ]; then
    # Signal is a linked device of the person's own account, not a key to
    # paste: connect-signal.sh fetches Signal support once, emits QR= for the
    # app to draw, and writes .env and config.yaml itself (docs/SIGNAL.md).
    # Called, never `exec`ed, for the same reason as WhatsApp below: this
    # script's EXIT trap refreshes context/_connections.md.
    "$HERE/connect-signal.sh"
    return $?
  fi
  # "even when the Mac is closed" used to be the first line here. Nothing in
  # the product does that: the part of Moe that thinks is a child of the app
  # (HermesSupervisor), so it answers while the Mac is awake and not
  # otherwise. scripts/test-connections-ui.sh bans the sentence on screen,
  # and a script's lines are the screen.
  if [ "$name" = line ]; then
    echo "Connecting LINE: it only delivers to a public address, so your messages reach Moe through Moe's cloud."
  else
    echo "Connecting the '$name' chat platform: Moe answers you there while this Mac is awake."
  fi
  echo "Tokens go to $HERMES_HOME/.env (owner-only)."
  if [ "$name" = whatsapp ]; then
    # This branch used to write WHATSAPP_ENABLED=true, say "run 'hermes
    # whatsapp' in a terminal", and report success — so the row went green
    # over a platform with no session, and the live check then said "set up,
    # but not running yet — quit Moe and open it again", which was advice
    # that could never help. WhatsApp is pairing, not a key: it belongs in
    # connect-whatsapp.sh, which drives Hermes's bundled bridge and emits
    # QR= for the app to render. Sending a person to a terminal from inside
    # the Connections sheet is the defect, not the wording of it.
    #
    # Called, never `exec`ed: this script's EXIT trap is what refreshes
    # context/_connections.md, and exec would replace the shell and skip it,
    # leaving the model telling the person to connect the thing they have
    # just connected — the bug that put refresh_connections here.
    "$HERE/connect-whatsapp.sh"
    return $?
  fi
  # shellcheck disable=SC2086
  collect_env $creds
  if [ -n "$allowed" ] && [ -n "$NONINTERACTIVE" ]; then
    local who=""
    ask_value who "$allowed" ""
    [ -n "$who" ] && printf '%s\n' "$who" | env_set "$allowed"
  fi
  platform_enabled "$name" true
  if [ "$name" = line ]; then
    connect_line_cloud
  else
    echo "✓ $name configured. The first person to message the bot is asked to pair;"
    echo "  approve them in Settings › Connections (or: pairing.sh list / approve)."
  fi
  # The gateway reads .env and config.yaml only at start. The restart is the
  # app's job (HermesSupervisor owns the process); this line is its cue.
  echo "NEEDS_RESTART=gateway"
}

# LINE is the one of the five chat apps that cannot reach a Mac on its own:
# the Messaging API only ever delivers to a public HTTPS address (a webhook —
# no polling, no socket), and a Mac behind a router has none. The engine's
# own adapter starts a listener on port 8646 that LINE can never reach, and
# until 2026-09-11 that is where connecting LINE stopped: the row went green
# over a listener nothing would ever call.
#
# The address LINE can reach is Moe's cloud (edge POST /v1/channels/line/app
# hands back a webhook URL; the edge then routes each message to whichever
# Moe is awake, this Mac included). channels.py register does exactly that —
# reads the token and secret just written to .env, registers them, and points
# LINE at the URL over LINE's own endpoint API — and it is what enrolment's
# `migrate` does for a LINE connected earlier. This calls it for a LINE
# connected later, and says plainly what happened when it cannot.
connect_line_cloud() {
  local out rc=0
  # `|| rc=$?`, not `; rc=$?`: under set -e a refused register in a plain
  # assignment ends the script before the honest line below is printed.
  out="$(python3 "$CONN/channels.py" register line 2>&1 </dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out" | grep -v '^Using the ' | sed 's/^/  /'
    echo "✓ LINE configured. It sends to Moe through Moe's cloud; the first person to message"
    echo "  the bot is asked to pair — approve them in Settings › Connections."
  else
    # Not enrolled (no cloud credential on this Mac), or the cloud refused:
    # the keys are saved either way, and the honest line is that nothing
    # arrives until the cloud half exists. Enrolment runs `migrate`, which
    # picks these keys up, so signing in finishes the job.
    echo "✓ LINE keys saved. Nothing arrives yet: LINE only delivers through Moe's cloud,"
    echo "  and this Mac is not signed in to it — sign in to Moe and it points LINE at itself."
  fi
}

# The Telegram bot. Default: the managed bot — connect-telegram-bot.sh talks
# to Hermes's onboarding service, prints one t.me link, and the token
# arrives by itself when the user taps "Create Bot". `--token` is the old
# way: paste a BotFather token (the generic platform flow above).
connect_telegram_bot() { # [--token]
  if [ "${1:-}" = --token ]; then
    HIT="$(lookup telegram platform)"
    connect_platform telegram "$(printf '%s' "$HIT" | cut -f3)" "$(printf '%s' "$HIT" | cut -f4)"
    return
  fi
  [ -x "$HERE/connect-telegram-bot.sh" ] || { echo "✗ connect-telegram-bot.sh is missing beside connect.sh"; exit 1; }
  if [ -n "$NONINTERACTIVE" ]; then
    MOE_CONNECT_NONINTERACTIVE=1 "$HERE/connect-telegram-bot.sh" < "$ANSWERS"
  else
    "$HERE/connect-telegram-bot.sh"
  fi
}

# Slack in one click: Moe's own Slack app. `channels.py slack-install` asks
# the cloud for a one-time link and prints SIGN_IN_URL=…, which the
# Connections sheet opens; the person picks a workspace and approves, and the
# screen's polling (`--status platform/slack`, below) sees it land.
connect_slack_app() {
  [ -x "$CHANNELS" ] || { echo "✗ channels.py is missing"; exit 1; }
  "$CHANNELS" slack-install
}

connect_spotify() {
  # Hermes signs in to Spotify with PKCE against a Spotify app's client id.
  # With none set it starts an interactive wizard telling the person to make
  # their own Spotify developer app — which, run from the app with no stdin,
  # opened Hermes's docs and then died at the prompt. So: a client id or an
  # honest refusal. Memoe's own id arrives as MOE_SPOTIFY_CLIENT_ID once its
  # Spotify app is registered; a person's own in ~/.hermes/.env still wins.
  local cid="${HERMES_SPOTIFY_CLIENT_ID:-}"
  [ -n "$cid" ] || cid="$(sed -n 's/^HERMES_SPOTIFY_CLIENT_ID=//p' "$HERMES_HOME/.env" 2>/dev/null | head -1)"
  [ -n "$cid" ] || cid="${MOE_SPOTIFY_CLIENT_ID:-}"
  if [ -z "$cid" ]; then
    echo "✗ Spotify can't be connected yet: Memoe has no Spotify app of its own to sign you in with."
    exit 1
  fi
  # Since Hermes 0.21.7 Spotify is a catalog plugin, not core: the sign-in is
  # the plugin's own `hermes spotify login`, and `hermes auth spotify` only
  # prints where it went. The plugin is fetched from the catalog's pinned
  # commit the first time someone connects Spotify, and never before — lazy
  # installs are off for Moe, so nothing else will fetch it.
  #
  # --enable --yes-deps, both: with no terminal `plugins install` asks neither
  # question and answers both no — the plugin lands on disk DISABLED, and any
  # Python dependency it declares is refused (hermes_cli/plugins_cmd_install.py,
  # cmd_install: `should_enable = _is_tty() and …`, and _consent_python_deps'
  # "Non-interactive install — skipping"). A disabled plugin registers no
  # `hermes spotify` command, so the sign-in below would be "unknown command".
  local fresh=""
  if [ ! -d "$HERMES_HOME/plugins/spotify" ]; then
    echo "Adding Spotify to Moe (one time)…"
    if ! hermes plugins install spotify --enable --yes-deps </dev/null 2>&1; then
      echo "✗ Spotify couldn't be added: Moe could not fetch the Spotify plugin. Check the connection and try again."
      exit 1
    fi
    # Hermes can exit 0 having installed nothing it will load; the directory
    # is what `hermes spotify` and configure-hermes.py both look for.
    if [ ! -d "$HERMES_HOME/plugins/spotify" ]; then
      echo "✗ Spotify couldn't be added: the Spotify plugin did not install."
      exit 1
    fi
    fresh=1
  fi
  echo "Moe signs in to Spotify with PKCE. The URL is printed; open it yourself."
  HERMES_SPOTIFY_CLIENT_ID="$cid" hermes spotify login </dev/null 2>&1 | mark_sign_in_url
  # The gateway loads plugins at start, and `spotify` is a default-off toolset:
  # it is on only once configure-hermes.py lists it, which it does when the
  # plugin directory exists. The restart is the app's job; a fresh supervisor
  # runs configure-hermes.py before it starts the gateway.
  [ -z "$fresh" ] || echo "NEEDS_RESTART=gateway"
}

# ── Remove ────────────────────────────────────────────────────────────────

# One Gmail mailbox: the Keychain item and the line in gmail-accounts.json.
# Everything else about "disconnect" is Hermes's; this one is entirely ours,
# and until it existed the app's Disconnect button ran `--remove ""` and
# always failed.
#
# With several mailboxes connected and no address given this asks instead of
# guessing: "disconnect Gmail" must never quietly take the work account away
# with the personal one.
remove_gmail() { # [address-or-label]
  # gmail.py OWNS this file and finds it at a hardcoded ~/.moe on purpose —
  # "a gate whose location an environment variable can move is not a gate".
  # Reading it through $MOE here made the two disagree the moment a second
  # app with its own home existed: status found two mailboxes and removal
  # found none, and the sheet said "No Gmail mailbox is connected" about
  # mailboxes that were plainly connected. Ask the owner where it is.
  local want="${1:-}" accounts chosen
  accounts="$("$CONN/gmail.py" accounts-file 2>/dev/null)"
  [ -n "$accounts" ] && [ -f "$accounts" ] || accounts="$HOME/.moe/connectors/gmail-accounts.json"
  chosen="$(python3 - "$accounts" "$want" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2].strip().lower()
try:
    with open(path) as f:
        accounts = json.load(f)
except (FileNotFoundError, json.JSONDecodeError, OSError):
    accounts = []
accounts = [a for a in accounts if a.get("email")]
if not accounts:
    print("NONE")
    raise SystemExit(0)
if want:
    hit = [a for a in accounts
           if want in (a["email"].lower(), str(a.get("label") or "").lower())]
    if not hit:
        print("NOMATCH\t" + ", ".join(a["email"] for a in accounts))
        raise SystemExit(0)
elif len(accounts) > 1:
    print("MANY\t" + ", ".join(a["email"] for a in accounts))
    raise SystemExit(0)
else:
    hit = accounts
print("ONE\t%s\t%s" % (hit[0]["email"], hit[0].get("label") or hit[0]["email"]))
PY
)"
  case "$chosen" in
    NONE)
      echo "✗ No Gmail mailbox is connected."; return 1 ;;
    MANY*)
      echo "✗ Several mailboxes are connected: ${chosen#MANY	}."
      echo "  Say which one: connect.sh --remove gmail <address>"; return 1 ;;
    NOMATCH*)
      echo "✗ No connected mailbox matches that. Connected: ${chosen#NOMATCH	}."; return 1 ;;
  esac
  local email label
  email="$(printf '%s' "$chosen" | cut -f2)"
  label="$(printf '%s' "$chosen" | cut -f3)"

  # The Keychain item first: an account left in the file with no password
  # reads as "needs attention", which is recoverable; a password left behind
  # with no account in the file is invisible and stays forever.
  security delete-generic-password -s moe-gmail -a "$email" >/dev/null 2>&1 || true

  local left
  left="$(python3 - "$accounts" "$email" <<'PY'
import json, os, sys
path, email = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        accounts = json.load(f)
except (FileNotFoundError, json.JSONDecodeError, OSError):
    accounts = []
accounts = [a for a in accounts if a.get("email") != email]
with open(path, "w") as f:
    json.dump(accounts, f, indent=2)
os.chmod(path, 0o600)
print(len(accounts))
PY
)"
  if [ "$left" = 0 ]; then
    echo "✓ $label <$email> disconnected. No Gmail mailbox is connected now."
  else
    echo "✓ $label <$email> disconnected. $left still connected."
  fi
  return 0
}

cmd_remove() { # name [account]
  local name="$1" hit kind creds
  case "$name" in
    gmail) if remove_gmail "${2:-}"; then return 0; else return 1; fi ;;
    # Hands the grant back to Google, forgets the saved sign-in and forgets
    # the picked list. All three are ours; none of it is in the engine, so
    # the lookup below would find nothing to remove.
    drive-docs)
      [ -x "$HERE/connect-drive-docs.sh" ] \
        || { echo "✗ connect-drive-docs.sh is missing beside connect.sh"; return 1; }
      "$HERE/connect-drive-docs.sh" --revoke; return $? ;;
    # The chats connector. Both the session file (a logged-in device, as
    # real as Telegram Desktop) and the application pair are ours, on this
    # disk — nothing about them is in the engine, so the lookup below would
    # find nothing and cheerfully report success having removed neither.
    telegram)
      local gone=0
      for f in "$CONN/telegram.session" "$CONN/telegram.session-journal" "$CONN/telegram.json"; do
        [ -e "$f" ] && { rm -f "$f" && gone=1; }
      done
      if [ "$gone" = 1 ]; then
        echo "✓ Telegram signed out on this Mac. Your account is untouched — remove the device in Telegram › Settings › Devices too if you want it gone from there."
        return 0
      fi
      echo "✗ Telegram was not signed in on this Mac."
      return 1 ;;
    telegram-bot) name=telegram ;;      # the platform; `telegram` alone is the chats connector
  esac
  if [ "${ONLY:-mcp}" = mcp ] && is_connected "mcp/$name"; then
    printf 'y\n' | hermes mcp remove "$name"      # Hermes asks "Remove?"; OAuth tokens go with it
    # `hermes mcp remove` deletes the config entry and mcp-tokens/<name>.json
    # (mcp_config.cmd_mcp_remove → MCPOAuthManager.remove) but never touches
    # .env. The bearer an api-key server keeps there is named after the
    # server (MCP_<NAME>_API_KEY, mcp_config._env_key_for_server) and read
    # by nothing else, so it goes too. Anything a manifest declared under
    # its own name (N8N_BASE_URL …) stays: another skill may share it.
    local derived
    derived="MCP_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_' | sed 's/^_*//; s/_*$//')_API_KEY"
    if grep -q "^\(export \)\{0,1\}$derived=" "$HERMES_HOME/.env" 2>/dev/null; then
      env_unset "$derived"
      echo "✓ $name removed (config, any OAuth token, and $derived from .env)."
    else
      echo "✓ $name removed (config and any OAuth token)."
    fi
    return 0
  fi
  hit="$(lookup "$name" "${ONLY:-}")"
  kind="${hit%%	*}"
  creds="$(printf '%s' "$hit" | cut -f3)"
  case "$kind" in
    skill)
      # shellcheck disable=SC2086
      env_unset $creds; echo "✓ $name credentials removed from .env." ;;
    platform)
      # Signal's link is keys on this disk, not only lines in .env: without
      # --forget the daemon would come back up as the person's device at the
      # next start.
      if [ "$name" = signal ] && [ -x "$HERE/connect-signal.sh" ]; then "$HERE/connect-signal.sh" --forget; fi
      # shellcheck disable=SC2086
      env_unset $creds $(printf '%s' "$hit" | cut -f4)    # unquoted: empty → no argument
      platform_enabled "$name" false
      echo "✓ $name token removed from .env."
      echo "NEEDS_RESTART=gateway" ;;
    *)
      if [ "$name" = spotify ]; then hermes spotify logout; return 0; fi
      echo "✗ nothing called '$name' is connected."; return 1 ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────

TMP="$(mktemp -d "${TMPDIR:-/tmp}/moe-connect.XXXXXX")"
# ONE exit trap, doing both jobs. A second `trap … EXIT` does not add a
# handler, it REPLACES the one before it — which is exactly how the first
# version of `refresh_connections` came to do nothing at all: it was armed
# two hundred lines above and silently disarmed here. `on_exit` is the only
# place either job may be added, and `scripts/test-connections-fresh.sh`
# drives a real change through the script and requires the file on disk to
# have been rewritten, so a future third trap turns that red rather than
# quietly costing the next person their connection.
on_exit() { rm -rf "$TMP"; refresh_connections; }
trap on_exit EXIT

# Non-interactive: every answer arrives up front (umask 077 → the file is
# owner-only, and it dies with $TMP). Read now, so a later `hermes` child
# never inherits a stdin with secrets on it.
ANSWERS="$TMP/answers"
if [ -n "$NONINTERACTIVE" ]; then
  cat > "$ANSWERS" 2>/dev/null || : > "$ANSWERS"
  exec </dev/null
fi

# Same rule as hermeslib.safe_name: a leading '-' would reach `hermes mcp
# test|login|remove` as an option, a leading '.' is a hidden file.
valid_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) echo "✗ names may only use letters, digits, _ and -" >&2; exit 2 ;;
    -*|.*)               echo "✗ names may not start with '-' or '.'" >&2; exit 2 ;;
  esac
}

# Composio brokers ~500 services behind one MCP server, and a person wants to
# connect Gmail, not "Composio". connectors/composio.py splits that one server
# into a row per service; this is the bridge from the name the app uses
# (composio/gmail) to that script.
#
# It prints a URL and stops. Opening a browser belongs to whoever asked — the
# app opens it because a person clicked; a cron job or the cloud tier must be
# able to run the same command and get a link to deliver instead. Every other
# connector here holds the same line, and `--open` is the one exception,
# granted explicitly by the caller.
COMPOSIO="$CONN/composio.py"
# $CONN is the installed payload, which is right — the payload is what runs.
# But composio.py is newer than most installed payloads, so fall back to this
# checkout rather than failing with a path nobody can act on. Mirrors the
# fallback $CONN itself has a few lines above.
[ -x "$COMPOSIO" ] || COMPOSIO="$HERE/../moe-home/connectors/composio.py"
# channels.py: the cloud half of chat apps (Moe's own Slack app's install,
# status and disconnect). Found the same way as composio.py. It was USED below
# from slice G1 on and assigned nowhere, so `[ -x "$CHANNELS" ]` was always
# false: Add to Slack said "channels.py is missing" and the status poll never
# asked the cloud anything (review of slice G1, 2026-09-14).
CHANNELS="$CONN/channels.py"
[ -x "$CHANNELS" ] || CHANNELS="$HERE/../moe-home/connectors/channels.py"

# The services Composio holds no sign-in for — ~1,250 of 1,378, most of them
# wanting an API key from the service's own settings page. Until 2026-09-11
# Connect on one of these asked the session for a link and printed "Composio
# did not return a sign-in link". Now: ask Composio's record of the service
# which fields it takes (their names, not ours — `api_key`, `token`,
# `subdomain`…), collect them the way every other key flow here does (a blind
# prompt, or the app's KEY=value answers on stdin), and hand them to
# composio.py on ITS stdin. The values never touch argv, the log, or this
# script's output; the account is live at Composio the moment it is made, so
# there is no link and nothing to wait for.
connect_composio_key() { # slug [--another]
  local slug="$1" another="${2:-}" spec names n label secret v key lines="" out
  if ! spec="$("$COMPOSIO" fields "$slug" 2>"$TMP/fields.err")"; then
    case "$spec" in
      *'"managed": true'*) echo "✗ $slug signs in through a link, not a key — connect.sh composio/$slug" ;;
      *) echo "✗ Composio lists nothing a person can paste for $slug. $(tail -n 1 "$TMP/fields.err" 2>/dev/null)" ;;
    esac
    exit 1
  fi
  names="$(printf '%s' "$spec" | python3 -c '
import json, sys
for f in json.load(sys.stdin).get("fields") or []:
    # Blind unless the record says plainly it is not a secret: a field with
    # no flag is typed as one (composio.py PLAIN_FIELDS).
    print("%s\t%s\t%s" % (f["name"], f.get("label") or f["name"], "0" if f.get("secret") is False else "1"))')"
  [ -n "$names" ] || { echo "✗ Composio names no field to paste for $slug."; exit 1; }
  # fd 3, not stdin: `ask` reads the person's answer from stdin, and a loop
  # fed on stdin would hand it the next field's name instead.
  exec 3<<<"$names"
  while IFS=$'\t' read -r -u 3 n label secret; do
    key="$(printf '%s' "$n" | tr 'a-z-' 'A-Z_')"
    if [ "$secret" = 1 ]; then ask_value v "$key" "$label: " secret; else ask_value v "$key" "$label: "; fi
    [ -n "$v" ] || { echo "✗ $label is required."; exit 1; }
    lines="$lines$n=$v"$'\n'
    v=""
  done
  exec 3<&-
  # --another is what makes a SECOND key account: without it composio.py
  # answers "already connected" for a service that is, and makes nothing.
  # Its answer is read, not assumed — this used to print "connected" after
  # an "already connected", so "Add another" on a key row reported success
  # and connected nothing.
  # shellcheck disable=SC2086
  if out="$(printf '%s' "$lines" | "$COMPOSIO" connect "$slug" --key $another)"; then
    lines=""
    if [ "$out" = "already connected" ]; then
      echo "✓ $slug is already connected — nothing new was added."
    elif [ -n "$another" ]; then
      echo "✓ $slug connected — another account. Composio accepted the key."
    else
      # What this can see is Composio accepting the key. That Moe's session
      # then reaches the account is not yet measured live (docs/COMPOSIO.md,
      # "Not yet exercised"), so the line does not promise it.
      echo "✓ $slug connected. Composio accepted the key."
    fi
    return 0
  fi
  lines=""
  exit 1
}

connect_composio() {
  slug=${1#composio/}
  # $2 is --another when the app is adding a second account to a service that
  # is already signed in. Passed straight through: the connector is what knows
  # that a duplicate must be asked for rather than assumed.
  # --key (a pasted key rather than a link) may come with it, in either
  # order: the app sends `--key --another` for "Add another" on a key row.
  local a key=0
  extra=""
  for a in "${@:2}"; do
    case "$a" in
      --key) key=1 ;;
      --another) extra=--another ;;
      "") ;;
      *) echo "✗ unknown option $a"; exit 2 ;;
    esac
  done
  [ -x "$COMPOSIO" ] || { echo "✗ composio.py is not installed in this payload"; exit 1; }
  if [ "$key" = 1 ]; then connect_composio_key "$slug" "$extra"; return $?; fi
  # shellcheck disable=SC2086
  url="$("$COMPOSIO" connect "$slug" $extra)" || exit 1
  case "$url" in
    "already connected") echo "✓ $slug is already connected"; return 0 ;;
    https://*) ;;
    *) echo "✗ $url"; exit 1 ;;
  esac
  # SIGN_IN_URL= is the app's contract (Connection.MachineLine): it opens the
  # page itself and starts polling. On a terminal it is just a line with a URL
  # in it, which is why the human sentence follows rather than replaces it.
  echo "SIGN_IN_URL=$url"
  if [ "${OPEN_BROWSER:-0}" = 1 ]; then
    /usr/bin/open "$url" >/dev/null 2>&1 || true
    echo "Opened your browser to sign in to $slug."
  else
    echo "Open this to sign in to $slug:"
    echo "  $url"
  fi
  echo "The link is good for ten minutes. Nothing is pasted back — the"
  echo "connection goes live on its own once you have signed in."
  # Start the notes file the model reads before using these tools, ONCE.
  # Without it Moe has five tools whose names say nothing about Google and
  # no reason to think Gmail is reachable at all — which is why it told Izzy
  # nothing was connected while his Gmail was signed in. Never overwritten:
  # the file says "edit or delete anything here, it is yours", and a payload
  # that rewrote it every launch would make that a lie.
  notes="$MOE/memory/tools/composio.md"
  if [ ! -f "$notes" ] && [ -f "$CONN/../memory-tools/composio.md" ]; then
    mkdir -p "$(dirname "$notes")" 2>/dev/null
    cp "$CONN/../memory-tools/composio.md" "$notes" 2>/dev/null || true
  fi
  # Then WAIT. The app keeps this script running while it shows "approve this
  # in the page that opened" and treats the exit as the answer, so a connector
  # that printed a URL and exited would report success before the person had
  # finished switching to the browser.
  "$COMPOSIO" wait "$slug" 300
}

# The two reads. Nothing else clears REFRESH — see the note beside it.
# --status in particular is what the Connections pane polls every few
# seconds while it is open, so refreshing on it would mean a Composio round
# trip every few seconds for a screen nobody changed.
[ $# -eq 0 ] && { REFRESH=0; cmd_list; exit 0; }

case "$1" in
  -h|--help) REFRESH=0; sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --open) OPEN_BROWSER=1; shift; [ $# -gt 0 ] || { echo "--open needs a name"; exit 2; } ;;
esac

case "$1" in
  --status)
    REFRESH=0
    if [ -n "${2:-}" ]; then
      split_kind "$2"; valid_name "$NAME"; hit="$(lookup "$NAME" "$ONLY")"; kind="${hit%%	*}"
      # Slack's one click finishes in a BROWSER, so nothing on this Mac hears
      # about it. This is the screen's own polling, so it is where the answer
      # is fetched: one quiet call that writes Moe's own Slack app's marker
      # (`channel-slack-moe.json` — never `channel-slack.json`, which is a
      # migrated Slack app of the person's own), and then the ordinary status
      # below reads it. Quiet and
      # never fatal — a Mac that is not signed in to Moe still has the
      # paste-the-keys path, and its status must not fail.
      if [ "$ONLY" = platform ] && [ "$NAME" = slack ] && [ -x "$CHANNELS" ]; then
        "$CHANNELS" slack-status --quiet >/dev/null 2>&1 || true
      fi
      # Moe's email address (slice G3) is not in Hermes's catalog -- it is not a
      # Hermes platform, and never `email`, which is the person's own mailbox.
      # The cloud's answer is written to the marker, and the row is read back.
      if [ "$ONLY" = platform ] && [ "$NAME" = moemail ]; then
        [ -x "$CHANNELS" ] && { "$CHANNELS" email-status --quiet >/dev/null 2>&1 || true; }
        "$CONNECTIONS" status platform/moemail; exit $?
      fi
      # Composio rows are not in Hermes's catalog at all — they are services
      # behind one MCP server, so the catalog knows the server and not them.
      if [ "$ONLY" = composio ]; then "$COMPOSIO" status "$NAME"; exit $?; fi
      # Not in the catalog (added with --url/--command, or spotify): ask the
      # connections list, which knows everything configured under ~/.hermes.
      [ -n "$kind" ] || kind="$("$CONNECTIONS" names 2>/dev/null | grep -m1 "^${ONLY:-[a-z]*}/$NAME\$" | cut -d/ -f1)"
      [ -n "$kind" ] || { echo "✗ unknown: $2"; exit 1; }
      "$CONNECTIONS" status "$kind/$NAME"
    else
      "$CONNECTIONS" list --live
    fi ;;
  --fields)
    # A read: what the key flow for a brokered service will ask for, as
    # JSON. The app runs it before drawing the paste sheet, so the sheet
    # shows the service's own field names and where to find each one.
    REFRESH=0
    split_kind "${2:-}"; valid_name "$NAME"
    [ "$ONLY" = composio ] || { echo "✗ only composio/<service> rows have fields to ask for"; exit 2; }
    [ -x "$COMPOSIO" ] || { echo "✗ composio.py is not installed in this payload"; exit 1; }
    "$COMPOSIO" fields "$NAME"; exit $? ;;
  --url)
    valid_name "${2:-}"; [ -n "${3:-}" ] || { echo "usage: connect.sh --url <name> <url>"; exit 2; }
    case "$3" in https://*|http://127.0.0.1*|http://localhost*) ;; *) echo "✗ the URL must be https:// (or a loopback http://)"; exit 2 ;; esac
    connect_mcp_url "$2" "$3" ;;
  --command)
    valid_name "${2:-}"; [ -n "${3:-}" ] || { echo "usage: connect.sh --command <name> <cmd> [args…]"; exit 2; }
    connect_mcp_command "$2" "${@:3}" ;;
  --name)
    # connect.sh --name composio/<service> <account-id> <label…>
    # Naming an account is how two of the same service are told apart, and
    # the app is the only place a person can do it without a terminal.
    split_kind "${2:-}"; valid_name "$NAME"
    [ "$ONLY" = composio ] || { echo "✗ only composio accounts can be named"; exit 2; }
    [ -n "${3:-}" ] && [ -n "${4:-}" ] || { echo "usage: connect.sh --name composio/<service> <account-id> <label>"; exit 2; }
    "$COMPOSIO" name "$NAME" "${@:4}" --account "$3"; exit $? ;;
  --remove)
    # $3 is the optional Gmail address. It is never a name and never reaches
    # a shell: gmail-accounts.json is matched against it in python.
    split_kind "${2:-}"; valid_name "$NAME"
    # $3 is one account id when the app asked which. Dropping it here would
    # turn "remove my work account" into "remove both", which is the whole
    # reason the chooser exists.
    if [ "$ONLY" = composio ]; then "$COMPOSIO" disconnect "$NAME" ${3:+"$3"}; exit $?; fi
    # Slack is two different things behind one row: Moe's own app, added in
    # one click and held on the cloud, and a Slack app of the person's own
    # whose keys are in .env (the row shows the keys when both exist). Remove
    # the one the row IS — never both, and never the other: this used to end
    # Moe's app on the cloud as a side effect of forgetting pasted keys
    # (second review of slice G1). **Either pasted key is a Slack of the
    # person's own** — the two the row counts (`SLACK_BOT_TOKEN`,
    # `SLACK_APP_TOKEN`) — not only the bot key: a half-pasted app token
    # alone used to fall through to the cloud unlink (third review).
    if [ "$NAME" = slack ] && { [ -z "${ONLY:-}" ] || [ "$ONLY" = platform ]; } \
       && ! grep -Eq '^(export )?SLACK_(BOT|APP)_TOKEN=' "$HERMES_HOME/.env" 2>/dev/null \
       && [ -f "$MOE/cloud/channel-slack-moe.json" ]; then
      [ -x "$CHANNELS" ] || { echo "✗ channels.py is missing"; exit 1; }
      "$CHANNELS" slack-unlink; exit $?
    fi
    # Moe's email address: let it go on the cloud. Never `platform/email`,
    # which is the person's own mailbox and is removed like any platform.
    if [ "$ONLY" = platform ] && [ "$NAME" = moemail ]; then
      [ -x "$CHANNELS" ] || { echo "✗ channels.py is missing"; exit 1; }
      "$CHANNELS" email-release; exit $?
    fi
    cmd_remove "$NAME" "${3:-}" ;;
  -*)
    echo "✗ unknown option $1"; exit 2 ;;
  *)
    split_kind "$1"; valid_name "$NAME"
    # Handed on, not `exec`ed. `exec` replaces this shell, and a replaced
    # shell has no EXIT trap — so every one of these four sign-ins used to
    # leave Moe's picture of what is connected untouched until the next
    # ten-minute sync, which is the whole defect this trap exists for. The
    # exit status is passed through unchanged, which is what the app reads.
    [ -n "$ONLY" ] || case "$NAME" in
      gmail)    "$HERE/connect-gmail.sh"; exit $? ;;
      telegram) "$HERE/connect-telegram.sh"; exit $? ;;
      whatsapp) "$HERE/connect-whatsapp.sh"; exit $? ;;
      signal)   "$HERE/connect-signal.sh"; exit $? ;;
      # Google Docs/Sheets/Slides contents. Its own script, and its own
      # sign-in, because the scope it uses cannot be combined with any
      # other (docs/GOOGLE-WITHOUT-OAUTH.md) — so it can never be folded
      # into one Google row with anything else.
      drive-docs) "$HERE/connect-drive-docs.sh"; exit $? ;;
      spotify)  connect_spotify; exit ;;
      telegram-bot) connect_telegram_bot "${2:-}"; exit ;;
    esac
    # A composio/<service> row. Checked before the catalog lookup because the
    # catalog does not contain these — it holds the SERVER, and these are the
    # services behind it.
    if [ "$ONLY" = composio ]; then connect_composio "$NAME" "${@:2}"; exit; fi
    # platform/telegram is the same bot: managed by default, --token to paste.
    if [ "$ONLY" = platform ] && [ "$NAME" = telegram ]; then connect_telegram_bot "${2:-}"; exit; fi
    # platform/slack: Moe's own Slack app, added in one click. `--token` is
    # the old way (paste a bot key and an app-level key from your own Slack
    # app), kept for a workspace that will not allow a third-party app and
    # for anyone who would rather keep their Slack inside their own app.
    if [ "$ONLY" = platform ] && [ "$NAME" = slack ] && [ "${2:-}" != --token ]; then
      connect_slack_app; exit
    fi
    # platform/moemail <name>: choose, or change, Moe's email address for this
    # account (slice G3). The name is checked here for its shape only, so it
    # never reaches anything as more than one plain word; the cloud decides
    # whether it is free.
    if [ "$ONLY" = platform ] && [ "$NAME" = moemail ]; then
      [ -x "$CHANNELS" ] || { echo "✗ channels.py is missing"; exit 1; }
      case "${2:-}" in
        ""|-*|*[!a-z0-9._-]*) echo "✗ choose a name: connect.sh platform/moemail <name> (a-z, 0-9, . _ -)"; exit 2 ;;
      esac
      "$CHANNELS" email-name "$2"; exit $?
    fi
    HIT="$(lookup "$NAME" "$ONLY")"
    if [ -z "$HIT" ]; then
      echo "✗ Moe has nothing called '$NAME'. connect.sh (no arguments) lists everything;"
      echo "  connect.sh --url $NAME <url> adds any MCP server by URL."
      exit 1
    fi
    KIND="${HIT%%	*}"
    AUTH="$(printf '%s' "$HIT" | cut -f2)"
    CREDS="$(printf '%s' "$HIT" | cut -f3)"
    ALLOWED="$(printf '%s' "$HIT" | cut -f4)"
    case "$KIND" in
      # shellcheck disable=SC2086
      mcp)      connect_mcp "$NAME" "$AUTH" "$(printf '%s' "$HIT" | cut -f5)" $CREDS ;;
      skill)    connect_skill "$NAME" $CREDS ;;
      platform) connect_platform "$NAME" "$CREDS" "$ALLOWED" ;;
    esac ;;
esac
