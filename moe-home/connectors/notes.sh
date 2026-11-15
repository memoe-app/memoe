#!/bin/bash
# Apple Notes — recently modified notes, titles plus a snippet.
#
# Reads through Notes.app rather than NoteStore.sqlite: the database stores
# note bodies gzip-compressed inside a protobuf, so parsing it by hand is both
# fragile and a good way to get stale data.
set -uo pipefail
LIMIT="${MOE_NOTES_LIMIT:-12}"

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

# On the sync timer, read through Notes.app only when it is already open:
# `tell application "Notes"` LAUNCHES it, visibly, and sync runs every ten
# minutes. A person asking (tools/apple.sh, learn.sh) gets the old behaviour.
# "skipped:" with exit 0 tells sync.sh to keep the last context file.
# TODO: read ~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite
# directly (ZICNOTEDATA.ZDATA is gzip + protobuf) and drop AppleScript here.
notes_open() { [ -z "${MOE_SYNC:-}" ] || /usr/bin/pgrep -xq Notes; }

case "${1:-status}" in
items)
  # The situations engine's read (moe-home/lib/situations.py): notes changed
  # since a cursor, whole text, as JSON items, then {"cursor": …}. Only while
  # Notes is open; see notes-items.py.
  shift
  exec /usr/bin/python3 "$(dirname "$0")/notes-items.py" notes "$@"
  ;;
status)
  notes_open || { echo "ok: reading Apple Notes (when it is open)"; exit 0; }
  if /usr/bin/perl -e 'alarm 10; exec @ARGV' \
       osascript -e 'tell application "Notes" to return count of notes' >/dev/null 2>&1; then
    echo "ok: reading Apple Notes"
  else
    echo "needs-setup: allow Memoe to control Notes (System Settings › Privacy & Security › Automation)"
    exit 1
  fi
  ;;
pull)
  notes_open || { echo "skipped: Notes not running"; exit 0; }
  osascript <<APPLESCRIPT 2>/dev/null
set out to ""
tell application "Notes"
  set n to count of notes
  if n > $LIMIT then set n to $LIMIT
  repeat with i from 1 to n
    try
      set theNote to note i
      set t to name of theNote
      set b to plaintext of theNote
      if (length of b) > 180 then set b to (text 1 thru 180 of b)
      set out to out & t & " | " & (my clean(b)) & linefeed
    end try
  end repeat
end tell
return out

on clean(s)
  set AppleScript's text item delimiters to {linefeed, return, tab}
  set parts to text items of s
  set AppleScript's text item delimiters to " "
  set r to parts as text
  set AppleScript's text item delimiters to ""
  return r
end clean
APPLESCRIPT
  ;;
crawl)
  shift; crawl_args "$@"
  # Every note touched in the window, whole body (capped per note so one
  # pasted document does not eat the byte budget).
  osascript <<APPLESCRIPT 2>/dev/null | { head -c "$MAX_BYTES"; cat >/dev/null; }
set out to ""
set cutoff to (current date) - $SINCE_DAYS * days
tell application "Notes"
  repeat with theNote in notes
    try
      set d to modification date of theNote
      if d > cutoff then
        set b to plaintext of theNote
        if (length of b) > 6000 then set b to (text 1 thru 6000 of b) & "…"
        set out to out & "### " & (name of theNote) & " (" & (short date string of d) & ")" & linefeed
        set out to out & (my clean(b)) & linefeed & linefeed
      end if
    end try
  end repeat
end tell
return out

on clean(s)
  set AppleScript's text item delimiters to {return, tab}
  set parts to text items of s
  set AppleScript's text item delimiters to " "
  set r to parts as text
  set AppleScript's text item delimiters to ""
  return r
end clean
APPLESCRIPT
  ;;
create)
  # One JSON object on stdin — {"title": …, "body": …} — never argv, where
  # `ps` shows every word of a private note to every process on this Mac
  # (the rule gmail.py and telegram.py already follow). The Python program is
  # captured from a single-quoted heredoc into $PROG by command substitution,
  # so the connector's OWN stdin (fd 0, the JSON) is never redirected away —
  # `python3 - <<PY` would have made the heredoc BE stdin and left json.loads
  # reading nothing. osascript likewise takes its script on stdin with the
  # text as string literals: no temp file, nothing in the process list. This
  # verb is what the model reaches for instead of raw osascript — which is
  # what it did when the verb did not exist, and the send gate then read the
  # note's own words ("Send … Gmail") as a mail send.
  PROG=$(cat <<'PY'
import html, json, re, subprocess, sys
try:
    req = json.loads(sys.stdin.read() or "{}")
except ValueError:
    sys.stderr.write("create: expected one JSON object on stdin, {\"title\": ..., \"body\": ...}\n")
    sys.exit(2)
if not isinstance(req, dict):
    sys.stderr.write("create: expected one JSON object on stdin\n"); sys.exit(2)
title = re.sub(r"\s+", " ", str(req.get("title") or "")).strip()
body = str(req.get("body") or "").replace("\r\n", "\n").replace("\r", "\n")
if not title:
    sys.stderr.write("create: needs a title\n"); sys.exit(2)
# Notes bodies are HTML. One <div> per line keeps the model's line breaks;
# escaping keeps anything in the text from becoming markup. The title is NOT
# repeated in the body — `name:` below already sets it, and Notes shows the
# note's name as the first line; an <h1> here as well printed the title twice.
rows = []
for line in body.split("\n"):
    rows.append("<div>" + (html.escape(line) if line.strip() else "<br>") + "</div>")
def lit(text):
    text = "".join(ch for ch in text if ch >= " " or ch in "\n\t")
    text = text.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + text.replace("\n", '" & linefeed & "') + '"'
script = (
    'tell application "Notes"\n'
    '  tell default account\n'
    '    set theNote to make new note with properties {name:' + lit(title) + ', body:' + lit("".join(rows)) + '}\n'
    '  end tell\n'
    '  return id of theNote\n'
    'end tell\n'
)
try:
    done = subprocess.run(["/usr/bin/osascript", "-"], input=script,
                          capture_output=True, text=True, timeout=30)
except subprocess.TimeoutExpired:
    sys.stderr.write("create: Notes did not answer in 30s\n"); sys.exit(1)
if done.returncode != 0:
    err = (done.stderr or "").strip()
    if "-1743" in err or "not allowed" in err.lower() or "not authorized" in err.lower():
        print("needs-setup: allow Memoe to control Notes (System Settings > Privacy & Security > Automation)")
        sys.exit(1)
    sys.stderr.write("create: Notes refused: " + (err or "no reason given") + "\n"); sys.exit(1)
print("created: " + title)
PY
)
  exec /usr/bin/python3 -c "$PROG"
  ;;
*) echo "usage: notes.sh [status|pull|items --since CURSOR|crawl [--since DAYS] [--max-bytes N]|create < {\"title\",\"body\"}]"; exit 2 ;;
esac
