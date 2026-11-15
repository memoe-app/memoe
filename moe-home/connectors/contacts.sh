#!/bin/bash
# Contacts — whether Moe may read your address book. Read through the Moe
# binary (the Contacts framework, in-process, nothing launched); see the
# MOE_BIN note below. The lookup itself is tools/apple.sh contacts-find.
set -uo pipefail

# Read through the Moe binary when it is installed. The AppleScript path
# below is kept only as a fallback for a checkout without the app: it
# LAUNCHES Contacts.app, and it answers for the Automation grant rather than
# the Contacts one, which is the permission the row is about. MOE_BIN
# overrides the location (tests).
MOE_BIN="${MOE_BIN:-/Applications/Memoe.app/Contents/MacOS/Moe}"
have_moe() { [ -x "$MOE_BIN" ]; }

case "${1:-status}" in
status)
  if have_moe; then
    # Prints "ok: …" or "needs-setup: …" itself; exit 3 means no access.
    /usr/bin/perl -e 'alarm 10; exec @ARGV' "$MOE_BIN" --contacts --status 2>&1 | head -1
    [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
    exit 0
  fi
  if /usr/bin/perl -e 'alarm 10; exec @ARGV' \
       osascript -e 'tell application "Contacts" to return count of people' >/dev/null 2>&1; then
    echo "ok: reading Contacts"
  else
    echo "needs-setup: allow Memoe to read your Contacts (System Settings › Privacy & Security › Contacts)"
    exit 1
  fi
  ;;
find)
  # Who a name is: their number and email, from the address book. Read-only.
  [ -n "${2:-}" ] || { echo "usage: contacts.sh find <name>"; exit 2; }
  HERE_C="$(cd "$(dirname "$0")" && pwd)"
  exec "$HERE_C/../tools/apple.sh" contacts-find "$2"
  ;;
*) echo "usage: contacts.sh [status|find <name>]"; exit 2 ;;
esac
