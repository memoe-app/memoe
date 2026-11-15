#!/bin/bash
# Calendar — every calendar subscribed in Calendar.app, which includes Google
# calendars if they're added there. No OAuth involved. Read via EventKit
# (Moe --calendar); see the MOE_BIN note below.
set -uo pipefail
DAYS="${MOE_CAL_DAYS:-3}"

# crawl [--since DAYS] [--max-bytes N]: the learn-me pass (learn.sh). Same
# read path as pull, wider window, and a hard byte cap so one chatty source
# cannot swamp the rest. Both values are validated as plain integers before
# they go anywhere near a query.
crawl_args() {
  SINCE_DAYS=90; MAX_BYTES="${MOE_CRAWL_MAX_BYTES:-400000}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)     SINCE_DAYS="${2:-}"; shift ;;
      --max-bytes) MAX_BYTES="${2:-}"; shift ;;
      *) echo "crawl: unknown option $1" >&2; exit 2 ;;
    esac
    shift
  done
  # Each on its own: concatenated, an empty --since would hide behind a
  # valid --max-bytes and reach the query as "-  days".
  case "$SINCE_DAYS" in ''|*[!0-9]*) echo "crawl: --since takes a whole number of days" >&2; exit 2 ;; esac
  case "$MAX_BYTES"  in ''|*[!0-9]*) echo "crawl: --max-bytes takes a whole number" >&2; exit 2 ;; esac
}

# Read through the Moe binary (EventKit) when it is installed. The AppleScript
# path below is kept only as a fallback for a checkout without the app: it
# LAUNCHES Calendar.app visibly every time the sync timer fires, which is
# the bug the EventKit path fixes. MOE_BIN overrides the location (tests).
MOE_BIN="${MOE_BIN:-/Applications/Memoe.app/Contents/MacOS/Moe}"
have_moe() { [ -x "$MOE_BIN" ]; }

case "${1:-status}" in
status)
  if have_moe; then
    # Prints "ok: …" or "needs-setup: …" itself; exit 3 means no access.
    /usr/bin/perl -e 'alarm 10; exec @ARGV' "$MOE_BIN" --calendar --status 2>&1 | head -1
    [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
    exit 0
  fi
  # Ask Calendar itself, not System Events — and give up after 10s so an
  # unanswered permission dialog can't wedge the sync.
  if /usr/bin/perl -e 'alarm 10; exec @ARGV' \
       osascript -e 'tell application "Calendar" to return count of calendars' >/dev/null 2>&1; then
    echo "ok: reading Calendar.app"
  else
    echo "needs-setup: allow Memoe to control Calendar (System Settings › Privacy & Security › Automation)"
    exit 1
  fi
  ;;
pull)
  case "$DAYS" in ''|*[!0-9]*) echo "MOE_CAL_DAYS must be a whole number of days" >&2; exit 2 ;; esac
  if have_moe; then exec "$MOE_BIN" --calendar "$DAYS"; fi
  osascript <<APPLESCRIPT 2>/dev/null
set out to ""
set d to (current date)
set time of d to 0
set d2 to d + $DAYS * days
tell application "Calendar"
  repeat with c in calendars
    try
      repeat with e in (events of c whose start date is greater than or equal to d and start date is less than d2)
        -- coerce out of the app reference first; a bare "short date string of
        -- start date of e" fails on some events and used to kill the whole
        -- calendar, because the try below sits outside this loop.
        try
          set theStart to (start date of e) as string
          set out to out & theStart & " | " & (summary of e as string)
          try
            if location of e is not missing value and location of e is not "" then
              set out to out & " | " & (location of e as string)
            end if
          end try
          set out to out & linefeed
        end try
      end repeat
    end try
  end repeat
end tell
return out
APPLESCRIPT
  ;;
brief)
  # The brief's calendar, split by the clock (ticket #9): what is over today,
  # what is on now, what is coming — each with its end and a label relative
  # to MOE_NOW (the brief's stamp; sync.sh passes it). Through the app only:
  # nothing here has end times or an all-day flag without EventKit, and a
  # failure here makes sync.sh fall back to calendar.md, which is the old
  # shape and still honest.
  case "$DAYS" in ''|*[!0-9]*) echo "MOE_CAL_DAYS must be a whole number of days" >&2; exit 2 ;; esac
  have_moe || exit 3
  if [ -n "${MOE_NOW:-}" ]; then
    exec /usr/bin/perl -e 'alarm 15; exec @ARGV' "$MOE_BIN" --calendar "$DAYS" --brief --now "$MOE_NOW"
  fi
  exec /usr/bin/perl -e 'alarm 15; exec @ARGV' "$MOE_BIN" --calendar "$DAYS" --brief
  ;;
items)
  # The situations engine's feed (moe-home/lib/situations.py): events created
  # or changed since a unix-time cursor, whole invitation text, as JSON items,
  # then {"cursor": …}. Through the app only: EventKit knows when an event
  # changed and who organised it; AppleScript does not.
  shift
  [ "${1:-}" = "--since" ] || { echo "usage: calendar.sh items --since CURSOR" >&2; exit 2; }
  have_moe || { echo "unavailable: Memoe is not installed" >&2; exit 1; }
  exec /usr/bin/perl -e 'alarm 60; exec @ARGV' "$MOE_BIN" --calendar --items-since "${2:-}"
  ;;
crawl)
  shift; crawl_args "$@"
  # The past window plus the next 30 days: recurring meetings and who is in
  # them say more about the shape of a week than any single event.
  if have_moe; then "$MOE_BIN" --calendar --crawl "$SINCE_DAYS" | { head -c "$MAX_BYTES"; cat >/dev/null; }; exit "${PIPESTATUS[0]}"; fi
  osascript <<APPLESCRIPT 2>/dev/null | { head -c "$MAX_BYTES"; cat >/dev/null; }
set out to ""
set d to (current date)
set time of d to 0
set d1 to d - $SINCE_DAYS * days
set d2 to d + 30 * days
tell application "Calendar"
  repeat with c in calendars
    try
      repeat with e in (events of c whose start date is greater than or equal to d1 and start date is less than d2)
        try
          set theStart to (start date of e) as string
          set out to out & theStart & " | " & (name of c as string) & " | " & (summary of e as string)
          try
            if location of e is not missing value and location of e is not "" then
              set out to out & " | " & (location of e as string)
            end if
          end try
          try
            set out to out & " | with:"
            repeat with a in attendees of e
              set out to out & " " & (display name of a as string)
            end repeat
          end try
          set out to out & linefeed
        end try
      end repeat
    end try
  end repeat
end tell
return out
APPLESCRIPT
  ;;
*) echo "usage: calendar.sh [status|pull|brief|items --since CURSOR|crawl [--since DAYS] [--max-bytes N]]"; exit 2 ;;
esac
