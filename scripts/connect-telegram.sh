#!/bin/bash
# Lets Moe READ your personal Telegram chats (separate from the bot).
#
# The bot can only see messages sent to the bot. To know what's happening in
# your actual conversations, Moe signs in as a second device on your own
# account using Telegram's official MTProto API (Telethon).
#
# Two ways to run it:
#
#   In a terminal: asks for api_id/api_hash (unless bundled, below), your
#   phone number, the code Telegram sends, and a 2FA password if you have one.
#
#   Driven by the app (MOE_CONNECT_NONINTERACTIVE=1): a conversation over
#   stdin/stdout, one `KEY=value` line per answer, and stdin STAYS OPEN across
#   the steps — the app keeps its write end of the pipe open until this
#   script exits, because Telegram only sends the code after the phone
#   number is known:
#
#     app → script   PHONE=+15551234567         (API_ID=/API_HASH= lines may
#                                               come before it; see below)
#     script → app   NEED=code                  Telegram has sent a code
#     app → script   CODE=12345
#     script → app   NEED=password              only if 2FA is on
#     app → script   PASSWORD=…
#     script → app   ✓ signed in as …           exit 0
#
#   A `✗ …` line and a non-zero exit at any point ends it; the last line on
#   stdout is the sentence to show. No secret is ever printed.
#
# api_id / api_hash. Telegram issues these per application at
# https://my.telegram.org/apps. The product ships its own pair — the app
# sets MOE_TELEGRAM_API_ID and MOE_TELEGRAM_API_HASH in the environment (or
# sends API_ID=/API_HASH= lines) so a user never sees that page. Without
# either, a terminal user is asked once; they are stored in
# ~/.moe/connectors/telegram.json (0600) for the connector.
#
# Redirection for tests: MOE_HOME; MOE_TELEGRAM_PYTHON = an interpreter that
# already has telethon (a fake one on PYTHONPATH), skipping the venv and the
# pip install; HERMES_HOME = where the seed's tool store (and its uv) lives; MOE_TELEGRAM_PIP_PYTHON =
# the interpreter whose pip is the last resort (default: the venv's base).
# Bash 3.2 and `set -u` clean.
set -euo pipefail
umask 077

MOE="${MOE_HOME:-$HOME/.moe}"
VENV="$MOE/venv"
CONFIG="$MOE/connectors/telegram.json"
NONINTERACTIVE="${MOE_CONNECT_NONINTERACTIVE:-}"
mkdir -p "$MOE/connectors"

# ── --accept-login: let a second device in, from this Mac's own session ──
#
# Slice E3. The person's cloud computer cannot use this Mac's session (one
# session live in two places is AUTH_KEY_DUPLICATED, and Telegram logs BOTH
# out), so it signs in as a device of its own: it exports a login key — what
# a QR code would carry — and this Mac's signed-in session accepts it
# (`auth.acceptLoginToken`), exactly as a phone accepts a scanned QR. The app
# fetches the key from the machine and hands it here on stdin as a
# `KEY=<base64>` line — never argv, never the log — with an `ACCOUNT=<id>`
# line: the Telegram user id the ask to the machine named. This Mac checks
# its own session is that account before it accepts anything, so a key is
# never let into an account the ask was not for.
#
# This mode never starts a sign-in of its own: no send_code_request, no
# sign_in, and no password — a PASSWORD= line is not read. A Mac that is not
# signed in says so and stops, and a Mac with no session file is not given
# one. The key lives about thirty seconds, so the venv is used as it is and
# nothing is installed on the way.
if [ "${1:-}" = "--accept-login" ]; then
  KEY=""
  ACCOUNT=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      KEY=*) KEY="${line#KEY=}" ;;
      ACCOUNT=*) ACCOUNT="${line#ACCOUNT=}" ;;
    esac
    [ -n "$KEY" ] && [ -n "$ACCOUNT" ] && break
  done
  [ -n "$KEY" ] || { echo "✗ No sign-in key was given."; exit 1; }
  case "$ACCOUNT" in
    ''|*[!0-9]*) echo "✗ This Mac was not told which Telegram account the key is for, so it accepted nothing."; exit 1 ;;
  esac
  [ -f "$CONFIG" ] || { echo "✗ Telegram is not connected on this Mac."; exit 1; }
  SESSION_FILE="$MOE/connectors/telegram.session"
  [ -s "$SESSION_FILE" ] || { echo "✗ Telegram is not connected on this Mac."; exit 1; }
  PY="${MOE_TELEGRAM_PYTHON:-$VENV/bin/python3}"
  command -v "$PY" >/dev/null 2>&1 || { echo "✗ Telegram is not connected on this Mac."; exit 1; }
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/moe-telegram.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/accept.py" <<'PY'
import base64, binascii, json, os, sys
moe = sys.argv[1]
account = sys.argv[2]
session = os.path.join(moe, "connectors", "telegram")
raw = sys.stdin.readline().strip()
try:
    key = base64.b64decode(raw, validate=True)
except (binascii.Error, ValueError):
    key = b""
if not key:
    print("✗ That sign-in key is not one Telegram gave out.")
    sys.exit(1)
try:
    cfg = json.load(open(os.path.join(moe, "connectors", "telegram.json")))
    api_id, api_hash = int(cfg["api_id"]), str(cfg["api_hash"])
except Exception:  # noqa: BLE001 - a missing or unreadable pair
    print("✗ Telegram is not connected on this Mac.")
    sys.exit(1)
try:
    from telethon.sync import TelegramClient
    from telethon.tl.functions.auth import AcceptLoginTokenRequest
except ImportError:
    print("✗ Telegram is not connected on this Mac.")
    sys.exit(1)

client = TelegramClient(session, api_id, api_hash)
closed = False


def close():
    # At most once: telethon's disconnect() writes through the session store
    # and re-opens it (see shutdown() in the sign-in below), so twice is how
    # a working session file gets clobbered.
    global closed
    if closed:
        return
    closed = True
    try:
        client.disconnect()
    except Exception:  # noqa: BLE001 - a failed close is not a failed accept
        pass


try:
    client.connect()
    if not client.is_user_authorized():
        # Never a sign-in from here: that would text the person a code they
        # did not ask for. The row under Connections is where that happens.
        print("✗ Telegram is not signed in on this Mac any more. Connect it again under Connections.")
        sys.exit(1)
    # Before accepting: this Mac's own account must be the one the ask named.
    holder = str(getattr(client.get_me(), "id", "") or "")
    if holder != account:
        print("✗ This Mac is signed in to a different Telegram account than the one your cloud "
              "computer was asked to join, so nothing was accepted.")
        sys.exit(1)
    client(AcceptLoginTokenRequest(token=key))
except SystemExit:
    close()
    raise
except Exception as e:  # noqa: BLE001 - AuthTokenExpiredError, AuthTokenInvalidError, a network
    close()
    kind = type(e).__name__
    if "Expired" in kind:
        print("✗ The sign-in key ran out before this Mac could use it (%s). Moe asks for a fresh one." % kind)
    else:
        print("✗ Telegram would not let the cloud computer in (%s)." % kind)
    sys.exit(1)
close()
print("✓ your cloud computer is signed in to your Telegram")
PY
  printf '%s\n' "$KEY" | "$PY" "$TMP/accept.py" "$MOE" "$ACCOUNT"
  exit $?
fi

# ── --whoami: which Telegram account this Mac is signed in to ────────────
#
# Slice E3. Every ask to the cloud computer names the account it is for, so a
# login that completes for anybody else is refused there. A sign-in records
# the id in `connectors/telegram-account.json`; a Mac signed in before that
# learns it here, once, from its own session. Never a sign-in: no
# send_code_request, no sign_in, and a Mac with no session is not given one.
if [ "${1:-}" = "--whoami" ]; then
  [ -f "$CONFIG" ] || { echo "✗ Telegram is not connected on this Mac."; exit 1; }
  SESSION_FILE="$MOE/connectors/telegram.session"
  [ -s "$SESSION_FILE" ] || { echo "✗ Telegram is not connected on this Mac."; exit 1; }
  PY="${MOE_TELEGRAM_PYTHON:-$VENV/bin/python3}"
  command -v "$PY" >/dev/null 2>&1 || { echo "✗ Telegram is not connected on this Mac."; exit 1; }
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/moe-telegram.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/whoami.py" <<'PY'
import json, os, sys
moe = sys.argv[1]
session = os.path.join(moe, "connectors", "telegram")
try:
    cfg = json.load(open(os.path.join(moe, "connectors", "telegram.json")))
    api_id, api_hash = int(cfg["api_id"]), str(cfg["api_hash"])
except Exception:  # noqa: BLE001 - a missing or unreadable pair
    print("✗ Telegram is not connected on this Mac.")
    sys.exit(1)
try:
    from telethon.sync import TelegramClient
except ImportError:
    print("✗ Telegram is not connected on this Mac.")
    sys.exit(1)

client = TelegramClient(session, api_id, api_hash)
closed = False


def close():
    # At most once — the same reason as --accept-login's.
    global closed
    if closed:
        return
    closed = True
    try:
        client.disconnect()
    except Exception:  # noqa: BLE001
        pass


try:
    client.connect()
    if not client.is_user_authorized():
        print("✗ Telegram is not signed in on this Mac any more. Connect it again under Connections.")
        sys.exit(1)
    uid = int(getattr(client.get_me(), "id"))
except SystemExit:
    close()
    raise
except Exception as e:  # noqa: BLE001
    close()
    print("✗ Telegram would not say which account this Mac is on (%s)." % type(e).__name__)
    sys.exit(1)
close()
account = os.path.join(moe, "connectors", "telegram-account.json")
with open(account + ".tmp", "w") as f:
    json.dump({"user_id": uid}, f)
os.chmod(account + ".tmp", 0o600)
os.replace(account + ".tmp", account)
print("✓ this Mac's Telegram account is known")
PY
  "$PY" "$TMP/whoami.py" "$MOE" </dev/null
  exit $?
fi

API_ID="${MOE_TELEGRAM_API_ID:-}"
API_HASH="${MOE_TELEGRAM_API_HASH:-}"
PHONE=""

# Reuse a stored pair when the caller brought none.
if [ -z "$API_ID" ] && [ -f "$CONFIG" ]; then
  API_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("api_id",""))' "$CONFIG" 2>/dev/null || true)"
  API_HASH="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("api_hash",""))' "$CONFIG" 2>/dev/null || true)"
fi

if [ -n "$NONINTERACTIVE" ]; then
  # Read up to and including the PHONE= line; the rest of stdin belongs to
  # the sign-in step (CODE=, PASSWORD=), which reads it itself.
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      API_ID=*)   API_ID="${line#API_ID=}" ;;
      API_HASH=*) API_HASH="${line#API_HASH=}" ;;
      PHONE=*)    PHONE="${line#PHONE=}"; break ;;
    esac
  done
  [ -n "$PHONE" ] || { echo "✗ PHONE is required."; exit 1; }
  [ -n "$API_ID" ] && [ -n "$API_HASH" ] || { echo "✗ API_ID and API_HASH are required (the app ships them as MOE_TELEGRAM_API_ID/HASH)."; exit 1; }
else
  cat <<'EOF'
Read your Telegram chats
────────────────────────
This signs Moe in as a linked device on your account, the same as adding
Telegram Desktop. You can revoke it any time from Telegram › Settings ›
Devices.

EOF
  if [ -z "$API_ID" ] || [ -z "$API_HASH" ]; then
    cat <<'EOF'
  1. Go to  https://my.telegram.org/apps   (log in with your phone number)
  2. Create an application — any name will do
  3. Copy the api_id and api_hash

EOF
    read -r -p "api_id: " API_ID || { echo; echo "✗ No input (not a terminal?)"; exit 1; }
    read -r -p "api_hash: " API_HASH || { echo; echo "✗ No input (not a terminal?)"; exit 1; }
    [ -n "$API_ID" ] && [ -n "$API_HASH" ] || { echo "✗ Both values are required."; exit 1; }
  fi
  read -r -p "Your phone number (with country code, e.g. +15551234567): " PHONE || { echo; echo "✗ No input (not a terminal?)"; exit 1; }
  [ -n "$PHONE" ] || { echo "✗ A phone number is required."; exit 1; }
fi
case "$API_ID" in ''|*[!0-9]*) echo "✗ api_id must be a number."; exit 1 ;; esac
case "$PHONE" in +[0-9]*) ;; [0-9]*) PHONE="+$PHONE" ;; *) echo "✗ The phone number must be digits with a country code, like +15551234567."; exit 1 ;; esac

python3 - "$CONFIG" "$API_ID" "$API_HASH" <<'PY'
import json, os, sys
path, api_id, api_hash = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as f:
    json.dump({"api_id": int(api_id), "api_hash": api_hash}, f, indent=2)
os.chmod(path, 0o600)
print("✓ credentials saved")
PY

# ── the private environment telethon lives in ─────────────────────────────
#
# Never ask Python for pip. The interpreter here is Hermes's, and the seed
# ships it without ensurepip (slim-hermes-tools.py did from 0.3.22 until
# 2026-11-13, and those Pythons stay on Macs until Hermes's Python changes),
# so a plain `python3 -m venv` died in ensurepip and every sign-in showed
# "…'-m', 'ensurepip', '--upgrade', '--default-pip']' returned non-zero exit
# status 1". The venv is made --without-pip, which needs nothing but the
# stdlib, and telethon goes in with the seed's own uv (how Hermes builds its
# venvs too), found through the store's facts.json. uv cannot reach the
# package index on every Mac where pip can, so a refusal falls back to pip:
# the venv's own if it has one, else the base interpreter's driving the venv
# (`pip --python`).
#
# A venv that never finished — ensurepip died after bin/python3 was made, so
# it looks usable and holds no pip and no activate scripts — or whose Python
# has gone (Hermes moved to a new one) is made again, not reused. venv writes
# bin/activate as its last step, so it is the "this finished" mark.
seed_uv() {
  local store="${HERMES_HOME:-$HOME/.hermes}/tools" entry
  [ -f "$store/facts.json" ] || return 1
  entry="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packages"]["uv"]["entry"])' \
    "$store/facts.json" 2>/dev/null)" || return 1
  case "$entry" in ''|*/*|.*) return 1 ;; esac
  [ -x "$store/$entry/uv" ] || return 1
  printf '%s\n' "$store/$entry/uv"
}

venv_finished() {
  [ -f "$VENV/pyvenv.cfg" ] && [ -f "$VENV/bin/activate" ] \
    && "$VENV/bin/python3" -c 'import sys' >/dev/null 2>&1
}

install_telethon() {
  local uv base
  uv="$(seed_uv || true)"
  if [ -n "$uv" ]; then
    "$uv" pip install --quiet --no-config --python "$VENV/bin/python3" --upgrade telethon >&2 && return 0
    echo "› uv could not install it; trying pip…"
  fi
  if "$VENV/bin/python3" -m pip --version >/dev/null 2>&1; then
    "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check --upgrade telethon >&2 && return 0
  fi
  base="${MOE_TELEGRAM_PIP_PYTHON:-$("$VENV/bin/python3" -c 'import sys; print(sys._base_executable)' 2>/dev/null || true)}"
  [ -n "$base" ] && "$base" -m pip --python "$VENV/bin/python3" install --quiet \
    --disable-pip-version-check --upgrade telethon >&2
}

PY="${MOE_TELEGRAM_PYTHON:-}"
if [ -z "$PY" ]; then
  if ! venv_finished; then
    echo "› creating a private python environment…"
    rm -rf "$VENV"
    python3 -m venv --without-pip "$VENV" >&2 \
      || { echo "✗ Moe could not set up the private Python it uses for Telegram."; exit 1; }
  fi
  echo "› installing telethon…"
  install_telethon \
    || { echo "✗ Moe could not download the piece it needs to read Telegram. Check your internet connection and try again."; exit 1; }
  PY="$VENV/bin/python3"
fi

[ -n "$NONINTERACTIVE" ] || echo "Signing in. Telegram will send you a code."
# The sign-in. stdin is still the app's pipe (or the terminal): the code and
# the password are read from it here, after NEED= says which — so the
# program goes to a private temp file rather than a heredoc on stdin. The
# session file is the logged-in device; 0600 and never printed.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/moe-telegram.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/signin.py" <<'PY'
import json, os, sys
moe = sys.argv[1]
cfg = json.load(open(os.path.join(moe, "connectors", "telegram.json")))
phone = os.environ["MOE_TG_PHONE"]
machine = bool(os.environ.get("MOE_TG_NONINTERACTIVE"))
session = os.path.join(moe, "connectors", "telegram")

try:
    from telethon.sync import TelegramClient
    from telethon.errors import SessionPasswordNeededError
except ImportError:
    print("✗ telethon is not installed — run this again.")
    sys.exit(1)


def answer(key, prompt):
    """One answer: a `KEY=value` line on stdin (app), or a prompt (terminal)."""
    sys.stdout.flush()
    if machine:
        while True:
            line = sys.stdin.readline()
            if not line:
                print("✗ No %s was given (stdin closed)." % key.lower())
                sys.exit(1)
            line = line.rstrip("\r\n")
            if line.startswith(key + "="):
                val = line[len(key) + 1:].strip()
                if val:
                    return val
                print("✗ %s is required." % key)
                sys.exit(1)
    if key == "PASSWORD":
        import getpass
        return getpass.getpass(prompt)
    return input(prompt).strip()


def remove_session():
    """Take the half-made session off disk. Only ever after shutdown()."""
    for leftover in (session + ".session", session + ".session-journal"):
        try:
            os.remove(leftover)
        except OSError:
            pass


_client = None


def shutdown():
    """Disconnect at most once, and never let the session store's errors out.

    Telethon's `disconnect()` is not a close: it writes the update state
    through the session database on the way, and `SQLiteSession._cursor()`
    *re-opens the file* when the previous connection was closed. So a second
    disconnect, after the first one has closed the session and the error path
    has deleted the file, re-creates that file as an empty database and then
    raises on a table it never created.

    Measured against telethon 1.44.0 on 2026-09-07, in exactly the shape
    this script used to have (an error handler that disconnected, deleted
    the session and called `sys.exit`, unwinding through `finally:
    client.disconnect()`):

        sqlite3.OperationalError: no such table: update_state

    …printed as a traceback *after* the honest `✗ …` line, so the app — which
    shows the last line — showed the person that sentence instead. It also
    left a 0-byte `telegram.session` behind, which every "have you signed in?"
    check on this Mac then read as a session.

    Nulling the client here is what makes it at most once: the `finally`
    below finds nothing left to disconnect.
    """
    global _client
    c, _client = _client, None
    if c is None:
        return
    try:
        c.disconnect()
    except Exception:  # noqa: BLE001 — a failed close is not a failed sign-in
        pass


def open_client():
    """The session store, repaired once if it will not open.

    A session file that exists but is not a working Telethon database — a
    0-byte one left by a killed run, a half-created one, a file from a
    library version that cannot be read here — is worth exactly nothing:
    it holds no authorisation. Deleting it and starting again costs the user
    a re-run of the sign-in they are already in the middle of; refusing to
    open it costs them the connection with no way out.
    """
    try:
        return TelegramClient(session, cfg["api_id"], cfg["api_hash"])
    except Exception:  # noqa: BLE001 — sqlite3 raises several, none recoverable
        remove_session()
    try:
        return TelegramClient(session, cfg["api_id"], cfg["api_hash"])
    except Exception as e:  # noqa: BLE001
        print("✗ Moe could not open its Telegram sign-in file (%s). "
              "Try again; if it keeps happening, disconnect Telegram and connect it fresh."
              % type(e).__name__)
        sys.exit(1)


# A 0-byte session is not a session — it is the wreckage of a run that died
# between creating the file and writing the schema. Telethon would open it
# and quietly build a fresh, unauthorised database; every check that asks
# "is there a session file?" would keep saying yes.
try:
    if os.path.getsize(session + ".session") == 0:
        remove_session()
except OSError:
    pass

_client = open_client()
client = _client
try:
    client.connect()
except Exception as e:  # noqa: BLE001 — no network, a dead DC, a bad proxy
    shutdown()
    print("✗ Moe could not reach Telegram (%s). Check the connection and try again."
          % type(e).__name__)
    sys.exit(1)
try:
    if not client.is_user_authorized():
        try:
            sent = client.send_code_request(phone)
        except Exception as e:
            # Not every failure here is about the phone number, and saying it
            # is sends people to check the one thing that was right.
            # ApiIdInvalidError is Telegram rejecting the api_id/api_hash
            # pair — it never looked at the number. When that is the fault,
            # the stored pair is wrong and must NOT be left behind: the app
            # skips asking for a pair it already has, so a bad one saved here
            # is a dead end with no way out of the sheet.
            kind = type(e).__name__
            # Telethon created the session file on connect(), before it knew
            # whether any of this would work. Left behind, it is a file that
            # says "signed in" to everything that looks for one. Order
            # matters: shutdown() first, so nothing re-opens the file after
            # it is gone (see shutdown's note).
            shutdown()
            remove_session()
            if kind in ("ApiIdInvalidError", "ApiIdPublishedFloodError"):
                try:
                    os.remove(os.path.join(moe, "connectors", "telegram.json"))
                except OSError:
                    pass
                print("✗ Telegram did not accept that api_id and api_hash. "
                      "Check you copied both whole from my.telegram.org/apps — "
                      "the api_hash is exactly 32 characters.")
            elif kind in ("PhoneNumberInvalidError", "PhoneNumberBannedError",
                          "PhoneNumberUnoccupiedError"):
                print("✗ Telegram does not recognise that phone number (%s). "
                      "It has to be the number your Telegram account is registered to." % kind)
            elif kind == "FloodWaitError":
                print("✗ Telegram is asking you to wait before trying again (%s)." % kind)
            else:
                print("✗ Telegram would not start the sign-in: %s" % kind)
            sys.exit(1)
        print("NEED=code")
        code = answer("CODE", "The code Telegram sent you: ")
        try:
            client.sign_in(phone, code, phone_code_hash=getattr(sent, "phone_code_hash", None))
        except SessionPasswordNeededError:
            print("NEED=password")
            pw = answer("PASSWORD", "Your Telegram two-step password: ")
            try:
                client.sign_in(password=pw)
            except Exception as e:
                print("✗ Telegram rejected the password (%s)." % type(e).__name__)
                sys.exit(1)
        except Exception as e:
            print("✗ Telegram rejected the code (%s). Run this again for a new one." % type(e).__name__)
            sys.exit(1)
    me = client.get_me()
except SystemExit:
    raise
except Exception as e:  # noqa: BLE001 — telethon raises a zoo, and a
    # traceback is not a sentence. Whatever went wrong, the person gets one
    # line they can act on and the sheet gets a last line that is it.
    print("✗ Telegram would not finish the sign-in (%s). Nothing was changed — try again."
          % type(e).__name__)
    sys.exit(1)
finally:
    shutdown()
try:
    os.chmod(session + ".session", 0o600)
except OSError:
    pass
# Which account this Mac is signed in to (slice E3): the account every ask
# to the cloud computer names, so a login for anybody else is refused there.
try:
    uid = int(getattr(me, "id"))
except (TypeError, ValueError):
    uid = None
account = os.path.join(moe, "connectors", "telegram-account.json")
if uid is not None:
    with open(account + ".tmp", "w") as f:
        json.dump({"user_id": uid}, f)
    os.chmod(account + ".tmp", 0o600)
    os.replace(account + ".tmp", account)
else:
    # Never a stale id from an earlier sign-in (possibly another account):
    # without the file, the app learns it with --whoami.
    try:
        os.remove(account)
    except OSError:
        pass
name = (getattr(me, "first_name", None) or "you")
print("✓ signed in as %s" % name)
PY
MOE_TG_PHONE="$PHONE" MOE_TG_NONINTERACTIVE="$NONINTERACTIVE" "$PY" "$TMP/signin.py" "$MOE"

echo "✓ Telegram chats connected. They'll appear in the next sync."
