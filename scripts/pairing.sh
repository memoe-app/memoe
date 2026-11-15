#!/bin/bash
# Who may talk to Moe on a chat platform — Hermes's DM pairing, for the app.
#
# Hermes denies every sender until they are approved. The first message from
# a stranger gets a one-time code back; the operator approves the request
# and that user is on the allowlist for good. `hermes pairing` is the CLI
# for that; this wraps it in lines a program can read:
#
#   pairing.sh list              Hermes's own table (pending + approved)
#   pairing.sh list --json       pending requests as a JSON array, from the
#                                store files themselves (no subprocess):
#                                [{"platform": "telegram", "request_id": "0123…16 hex",
#                                  "user_name": "Ada", "user_id": "12345",
#                                  "age_minutes": 3, "created_at": 1756…}]
#                                — the same array hermes-connections.py --json
#                                puts under "pending_pairings"; codes are
#                                stored hashed and never appear anywhere
#   pairing.sh approve <platform> <request-id|code>
#                                → `hermes pairing approve`; exit 0 and
#                                "✓ approved …" on success, 1 and Hermes's
#                                own last line otherwise (not found/expired,
#                                or a lockout after too many wrong codes)
#   pairing.sh revoke <platform> <user-id>
#
# Arguments are checked before they reach argv: a platform is [a-z0-9_]+,
# an id is 16 hex characters (from `list`) or an 8-character code (what the
# bot DM'd the user — the app never sees those, but a person can relay one).
#
# Redirection for tests: HERMES_HOME, HERMES_BIN (or a `hermes` first on
# PATH), MOE_HOME. Bash 3.2 and `set -u` clean.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export HERMES_HOME
MOE="${MOE_HOME:-$HOME/.moe}"
CONN="$MOE/connectors"
[ -f "$CONN/hermeslib.py" ] || CONN="$HERE/../moe-home/connectors"
[ -f "$CONN/hermeslib.py" ] || { echo "✗ hermeslib.py not found under $CONN — re-run the installer"; exit 1; }

HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
[ -n "$HERMES_BIN" ] || HERMES_BIN="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}/.venv/bin/hermes"

hermes() {
  HERMES_HOME="$HERMES_HOME" SSH_TTY="${SSH_TTY:-moe}" PYTHONDONTWRITEBYTECODE=1 "$HERMES_BIN" "$@" </dev/null
}
need_hermes() {
  [ -x "$HERMES_BIN" ] || { echo "✗ hermes CLI not found (looked on PATH and at $HERMES_BIN)."; exit 1; }
}

valid_platform() {
  case "$1" in ''|*[!a-z0-9_]*) echo "✗ platform must be a lowercase name like telegram, discord, slack"; exit 1 ;; esac
}
valid_id() {
  case "$1" in
    ????????????????) case "$1" in *[!0-9a-fA-F]*) ;; *) return 0 ;; esac ;;
  esac
  case "$1" in
    ????????) case "$1" in *[!A-Za-z0-9]*) ;; *) return 0 ;; esac ;;
  esac
  echo "✗ that is neither a request id (16 hex characters) nor a pairing code (8 letters/digits)"; exit 1
}

case "${1:-}" in
  list)
    if [ "${2:-}" = --json ]; then
      python3 "$CONN/hermeslib.py" pending-pairings
    else
      need_hermes; hermes pairing list
    fi ;;
  approve)
    [ $# -eq 3 ] || { echo "usage: pairing.sh approve <platform> <request-id|code>"; exit 1; }
    # An Add to Slack waiting for this Mac's word (Moe's own Slack app, slice
    # G1) rides the same Approve button, and is not a Hermes pairing at all:
    # the cloud holds it, and channels.py is what answers it.
    if [ "$2" = slack_link ]; then
      case "$3" in *[!0-9a-f]*|'') echo "✗ that is not an install id"; exit 1 ;; esac
      [ "${#3}" -eq 16 ] || { echo "✗ that is not an install id"; exit 1; }
      exec "$CONN/channels.py" slack-confirm "$3"
    fi
    # Somebody waiting at a channel the cloud holds (hermes-connections.py
    # cloud_channel_knocks): not a Hermes pairing either. The id is the chat
    # id zero-padded to 16 digits; channels.py approve takes it bare.
    case "$2" in cloud_*)
      ch="${2#cloud_}"
      case "$ch" in ''|*[!a-z0-9_]*) echo "✗ that is not a channel"; exit 1 ;; esac
      case "$3" in *[!0-9]*|'') echo "✗ that is not a chat"; exit 1 ;; esac
      [ "${#3}" -eq 16 ] || { echo "✗ that is not a chat"; exit 1; }
      chat="$(printf '%s' "$3" | sed 's/^0*//')"
      [ -n "$chat" ] || { echo "✗ that is not a chat"; exit 1; }
      exec "$CONN/channels.py" approve "$ch" "$chat"
    esac
    valid_platform "$2"; valid_id "$3"; need_hermes
    out="$(hermes pairing approve "$2" "$3" 2>&1)" || true
    case "$out" in
      *Approved!*)
        # "Approved! User Ada (12345) on telegram can now use the bot~" → keep the who.
        who="$(printf '%s\n' "$out" | grep -m1 'Approved!' | sed 's/.*Approved! User //; s/ on [a-z0-9_]* can now.*//')"
        echo "✓ approved ${who:-the request} on $2" ;;
      *"locked out"*)
        echo "✗ $2 is locked out after too many wrong codes; try again later (or approve by request id from the list)"; exit 1 ;;
      *)
        # Hermes's reason, then its advice: the reason is the line to show.
        last="$(printf '%s\n' "$out" | grep -m1 -i 'not found\|expired\|error\|✗' || true)"
        [ -n "$last" ] || last="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1)"
        last="$(printf '%s' "$last" | sed 's/^[[:space:]]*//')"
        echo "✗ ${last:-not approved}"; exit 1 ;;
    esac ;;
  revoke)
    [ $# -eq 3 ] || { echo "usage: pairing.sh revoke <platform> <user-id>"; exit 1; }
    valid_platform "$2"
    case "$3" in ''|*[!A-Za-z0-9_.@:+-]*) echo "✗ user id may only use letters, digits and _ . @ : + -"; exit 1 ;; esac
    need_hermes
    out="$(hermes pairing revoke "$2" "$3" 2>&1)" || true
    case "$out" in
      *Revoked*) echo "✓ revoked $3 on $2" ;;
      *) echo "✗ $(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1 | sed 's/^[[:space:]]*//')"; exit 1 ;;
    esac ;;
  -h|--help|'') sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] && exit 0 || exit 1 ;;
  *) echo "✗ unknown command $1 (list | approve | revoke)"; exit 1 ;;
esac
