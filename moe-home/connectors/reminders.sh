#!/bin/bash
# Reminders — open tasks, soonest first. Read via EventKit (Moe --reminders);
# see the MOE_BIN note below.
set -uo pipefail

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
# LAUNCHES Reminders.app visibly every time the sync timer fires, which is
# the bug the EventKit path fixes. MOE_BIN overrides the location (tests).
MOE_BIN="${MOE_BIN:-/Applications/Memoe.app/Contents/MacOS/Moe}"
have_moe() { [ -x "$MOE_BIN" ]; }

case "${1:-status}" in
status)
  if have_moe; then
    # Prints "ok: …" or "needs-setup: …" itself; exit 3 means no access.
    /usr/bin/perl -e 'alarm 10; exec @ARGV' "$MOE_BIN" --reminders --status 2>&1 | head -1
    [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
    exit 0
  fi
  if /usr/bin/perl -e 'alarm 10; exec @ARGV' \
       osascript -e 'tell application "Reminders" to return name of first list' >/dev/null 2>&1; then
    echo "ok: reading Reminders"
  else
    echo "needs-setup: allow Memoe to control Reminders (System Settings › Privacy & Security › Reminders)"
    exit 1
  fi
  ;;
pull)
  if have_moe; then exec "$MOE_BIN" --reminders; fi
  osascript <<'APPLESCRIPT' 2>/dev/null
set out to ""
tell application "Reminders"
  repeat with l in lists
    try
      repeat with r in (reminders of l whose completed is false)
        set out to out & (name of l) & " | " & (name of r)
        try
          if due date of r is not missing value then
            set out to out & " | due " & (short date string of (due date of r))
          end if
        end try
        set out to out & linefeed
      end repeat
    end try
  end repeat
end tell
return out
APPLESCRIPT
  ;;
crawl)
  shift; crawl_args "$@"
  # Open tasks plus anything completed in the window: what someone finishes
  # (and keeps not finishing) is a live-threads signal pull never sees.
  if have_moe; then "$MOE_BIN" --reminders --crawl "$SINCE_DAYS" | { head -c "$MAX_BYTES"; cat >/dev/null; }; exit "${PIPESTATUS[0]}"; fi
  osascript <<APPLESCRIPT 2>/dev/null | { head -c "$MAX_BYTES"; cat >/dev/null; }
set out to ""
set cutoff to (current date) - $SINCE_DAYS * days
tell application "Reminders"
  repeat with l in lists
    try
      repeat with r in (reminders of l whose completed is false or completion date > cutoff)
        set out to out & (name of l) & " | " & (name of r)
        try
          if due date of r is not missing value then
            set out to out & " | due " & (short date string of (due date of r))
          end if
        end try
        try
          if completed of r then set out to out & " | done " & (short date string of (completion date of r))
        end try
        set out to out & linefeed
      end repeat
    end try
  end repeat
end tell
return out
APPLESCRIPT
  ;;
create)
  # One JSON object on stdin — {"title": …, "notes": …, "due": …, "list": …}
  # — never argv (see notes.sh create for why, and for the $PROG idiom that
  # keeps the JSON on fd 0). AppleScript rather than the EventKit path: `Moe
  # --reminders` is read-only, and a one-off create the person just asked for
  # may launch Reminders.app; the sync timer, which must not, never calls
  # this verb. `due` is local time, "YYYY-MM-DD" or "YYYY-MM-DD HH:MM", turned
  # into date components here and assembled in AppleScript because `date "…"`
  # literals depend on the Mac's locale.
  PROG=$(cat <<'PY'
import datetime, json, re, subprocess, sys
try:
    req = json.loads(sys.stdin.read() or "{}")
except ValueError:
    sys.stderr.write("create: expected one JSON object on stdin, {\"title\": ...}\n"); sys.exit(2)
if not isinstance(req, dict):
    sys.stderr.write("create: expected one JSON object on stdin\n"); sys.exit(2)
title = re.sub(r"\s+", " ", str(req.get("title") or "")).strip()
notes = str(req.get("notes") or "").replace("\r\n", "\n").replace("\r", "\n").strip()
list_name = re.sub(r"\s+", " ", str(req.get("list") or "")).strip()
due = str(req.get("due") or "").strip()
if not title:
    sys.stderr.write("create: needs a title\n"); sys.exit(2)
parts = None
if due:
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}))?$", due)
    if not m:
        sys.stderr.write("create: due must be YYYY-MM-DD or YYYY-MM-DD HH:MM (local time), got " + repr(due) + "\n")
        sys.exit(2)
    y, mo, d, hh, mm = (int(x) if x else None for x in m.groups())
    if hh is None:
        hh, mm = 9, 0  # a date with no time is a morning reminder, not midnight
    # datetime.date rejects a day that does not exist in that month (2026-02-30,
    # 2026-04-31, a non-leap Feb 29); a month-agnostic 1<=d<=31 let those roll
    # silently forward into the next month. Time bounds are checked plainly.
    try:
        datetime.date(y, mo, d)
    except ValueError:
        sys.stderr.write("create: no such date: " + repr(due) + "\n"); sys.exit(2)
    if not (0 <= hh <= 23 and 0 <= mm <= 59):
        sys.stderr.write("create: not a real time: " + repr(due) + "\n"); sys.exit(2)
    parts = (y, mo, d, hh, mm)
def lit(text):
    text = "".join(ch for ch in text if ch >= " " or ch in "\n\t")
    text = text.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + text.replace("\n", '" & linefeed & "') + '"'
lines = ['tell application "Reminders"']
lines.append('  set theList to list ' + lit(list_name) if list_name else '  set theList to default list')
lines.append('  set theReminder to make new reminder at end of reminders of theList with properties {name:' + lit(title) + '}')
if notes:
    lines.append('  set body of theReminder to ' + lit(notes))
if parts:
    y, mo, d, hh, mm = parts
    # Day to 1 first so setting the month can never overflow into the next.
    lines += [
        '  set theDate to current date',
        '  set day of theDate to 1',
        '  set year of theDate to ' + str(y),
        '  set month of theDate to ' + str(mo),
        '  set day of theDate to ' + str(d),
        '  set time of theDate to ' + str(hh * 3600 + mm * 60),
        '  set due date of theReminder to theDate',
        '  set remind me date of theReminder to theDate',
    ]
lines += ['  return id of theReminder', 'end tell', '']
try:
    done = subprocess.run(["/usr/bin/osascript", "-"], input="\n".join(lines),
                          capture_output=True, text=True, timeout=30)
except subprocess.TimeoutExpired:
    sys.stderr.write("create: Reminders did not answer in 30s\n"); sys.exit(1)
if done.returncode != 0:
    err = (done.stderr or "").strip()
    if "-1743" in err or "not allowed" in err.lower() or "not authorized" in err.lower():
        print("needs-setup: allow Memoe to control Reminders (System Settings > Privacy & Security > Reminders)")
        sys.exit(1)
    if list_name and ("-1728" in err or "get list" in err.lower()):
        sys.stderr.write("create: there is no Reminders list called " + repr(list_name) + "\n"); sys.exit(1)
    sys.stderr.write("create: Reminders refused: " + (err or "no reason given") + "\n"); sys.exit(1)
tail = (" in " + list_name) if list_name else ""
tail += (" - due " + due) if due else ""
print("created: " + title + tail)
PY
)
  exec /usr/bin/python3 -c "$PROG"
  ;;
*) echo "usage: reminders.sh [status|pull|crawl [--since DAYS] [--max-bytes N]|create < {\"title\",\"notes\",\"due\",\"list\"}]"; exit 2 ;;
esac
