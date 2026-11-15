#!/bin/bash
# NEEDS: debug-moe
#
# Integration test for meeting mode's file pipeline, driven through
# `.build/debug/Moe --meeting-test <dir> <out>` against scripts/fake-hermes.
# No audio device is opened, nothing is played, and nothing of the user's
# is touched: MOE_HOME (debug-only) points Moe at a scratch config.json and
# log, and the fake gateway sits on a random free port — never 8642.
#
# The recording is the spike's 8 s pair (system.wav: two `say` voices, one
# agreeing to ship on Tuesday, one promising the notes; mic.wav: the room,
# nobody speaking). Set MOE_MEETING_FIXTURE to point at another pair.
#
#   1. timeline shape  → [mm:ss] them (speaker N): … lines, two speakers,
#                        the words that matter, nothing on "you"
#   2. notes           → summary.md + meeting.json from the fake's canned JSON;
#                        request carried session key moe-meeting, fenced transcript
#   2b. minute scan    → the live action-item pass (ActionItemScan) reaches the
#                        gateway with <new-lines>, and what it found is merged
#                        into the notes at the end, deduped against them
#   3. bad reply       → prose instead of JSON: transcript kept, no summary.md,
#                        meeting.json says why
#   4. no gateway      → connection refused: transcript kept, "brain unavailable"
#   5. disabled        → meetingSummarise=false: no request at all
#   6. captures        → MOE_MEETING_CAPTURES=1: a captioned screenshot and a
#                        clip land in meeting.json, in summary.md's Screens
#                        section, and the caption reaches the summary prompt
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
MOE="$ROOT/.build/debug/Moe"
FAKE="$ROOT/scripts/fake-hermes"
FIXTURE="${MOE_MEETING_FIXTURE:-$ROOT/scripts/fixtures/meeting}"
SCRATCH="${MOE_TEST_SCRATCH:-${TMPDIR:-/tmp}}/moe-meeting-test.$$"
mkdir -p "$SCRATCH/home" "$SCRATCH/out"
export MOE_HOME="$SCRATCH/home"
REQLOG="$SCRATCH/requests"
MOELOG="$MOE_HOME/logs/moe.log"

[ -x "$MOE" ] || { echo "build first: swift build"; exit 1; }
[ -x "$FAKE" ] || { echo "$FAKE is not executable"; exit 1; }
[ -f "$FIXTURE/system.wav" ] && [ -f "$FIXTURE/mic.wav" ] || { echo "no recording at $FIXTURE (system.wav + mic.wav)"; exit 1; }

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
[ "$PORT" != 8642 ] || PORT=$((PORT + 1))

pass=0; fail=0
ok()  { echo "  ok   $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

fake_pid=""
start_fake() {
  stop_fake
  env MOE_FAKE_PORT="$PORT" MOE_FAKE_REQLOG="$REQLOG" "$@" "$FAKE" >"$SCRATCH/fake.out" 2>&1 &
  fake_pid=$!
  for _ in $(seq 1 50); do
    curl -s -m 1 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "fake gateway did not come up"; cat "$SCRATCH/fake.out"; exit 1
}
stop_fake() {
  if [ -n "$fake_pid" ]; then kill "$fake_pid" 2>/dev/null; wait "$fake_pid" 2>/dev/null; fake_pid=""; fi
}
cleanup() { stop_fake; rm -rf "$SCRATCH"; }
trap cleanup EXIT

write_config() { # write_config <summarise true|false>
  cat > "$MOE_HOME/config.json" <<EOC
{ "brain": "hermes", "hermesPort": $PORT, "hermesKey": "test-key", "meetingSummarise": $1, "speakReplies": false }
EOC
}

run() { # run <out-dir>: stdout → $OUT (timeline), stderr → $SCRATCH/err
  rm -rf "$1"; mkdir -p "$1"
  OUT=$("$MOE" --meeting-test "$FIXTURE" "$1" 2>"$SCRATCH/err"); RC=$?
}
# Two "note this" taps during run 1, at 3.5 s (…ship the meeting feature) and 7 s (…send the notes).
export MOE_MEETING_BOOKMARKS="3.5,7"

echo "== 1. timeline shape (loads the speech model; ~15 s the first time)"
write_config true
: > "$REQLOG"
start_fake
run "$SCRATCH/out/1"
[ "$RC" -eq 0 ] && ok "exit 0 ($(grep -o 'transcribed + diarized.*' "$SCRATCH/err" | head -1))" || { bad "exit $RC"; cat "$SCRATCH/err"; }
echo "$OUT" | sed 's/^/       /'
LINES=$(echo "$OUT" | grep -c '^\[[0-9][0-9]:[0-9][0-9]\] ')
[ "$LINES" -ge 2 ] && ok "$LINES timeline lines, all [mm:ss]-stamped" || bad "only $LINES stamped lines"
echo "$OUT" | grep -q '^\[00:00\] them (speaker 1): ' && ok "first line is them (speaker 1) at 00:00" || bad "first line: $(echo "$OUT" | head -1)"
echo "$OUT" | grep -q 'them (speaker 2): ' && ok "a second speaker was found" || bad "no speaker 2"
echo "$OUT" | grep -qi 'tuesday' && ok "\"Tuesday\" recognised" || bad "\"Tuesday\" missing"
echo "$OUT" | grep -qi 'notes' && ok "\"notes\" recognised" || bad "\"notes\" missing"
echo "$OUT" | grep -q '\] you: ' && bad "something landed on \"you\" (the mic was silent)" || ok "nothing on \"you\" — the streams are clean"
# In time order: every stamp ≥ the one before.
echo "$OUT" | grep -o '^\[[0-9:]*\]' | tr -d '[]' | awk -F: '{t=$1*60+$2; if (t<p) bad=1; p=t} END {exit bad}' && ok "lines in time order" || bad "out of order"
diff -q <(echo "$OUT") "$SCRATCH/out/1/transcript.txt" >/dev/null && ok "transcript.txt matches the timeline" || bad "transcript.txt differs"

echo "== 2. notes from the fake gateway"
[ -f "$SCRATCH/out/1/summary.md" ] && ok "summary.md written" || bad "no summary.md"
grep -q '^# Fake meeting notes' "$SCRATCH/out/1/summary.md" && ok "title from the reply" || bad "title missing"
grep -q '^- Ship the meeting feature on Tuesday' "$SCRATCH/out/1/summary.md" && ok "decision listed" || bad "decision missing"
grep -q 'them (speaker 2)\*\*: send the notes — by after the call' "$SCRATCH/out/1/summary.md" && ok "action item with who/what/when" || bad "action item missing"
python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
assert r["summarised"] is True, r
assert r["summaryFile"] == "summary.md", r
assert r["notes"]["title"] == "Fake meeting notes", r
assert sorted(r["speakers"]) == [1, 2], r["speakers"]
assert r["durationSeconds"] > 5, r
assert r["recordingsDeleted"] is False
' "$SCRATCH/out/1/meeting.json" && ok "meeting.json is well-formed" || bad "meeting.json wrong"
# Each purpose has a session of its own: the notes were once asked on the
# session the minute scan had used sixty times, and came back as action
# items (MeetingBrainSessions.swift has the measurement). So the two keys
# are required exactly, and their session ids must differ. This check used
# to be a prefix match on "moe-meeting", which any of the five keys passes.
KEYS="$(grep -a '^X-Hermes-Session-Key: ' "$REQLOG" | tr -d '\r' | sort -u | sed 's/^X-Hermes-Session-Key: //' | tr '\n' ' ')"
case " $KEYS" in *" moe-meeting-notes "*) ok "the notes are asked on session key moe-meeting-notes" ;; *) bad "no moe-meeting-notes request (keys seen: $KEYS)" ;; esac
case " $KEYS" in *" moe-meeting-scan "*)  ok "the minute scan on moe-meeting-scan" ;; *) bad "no moe-meeting-scan request (keys seen: $KEYS)" ;; esac
# Header order inside a request is not promised, so each key is paired with
# the session id in the same request block.
SHARED="$(tr -d '\r' < "$REQLOG" | awk '
  /^POST /                    { key = ""; id = "" }
  /^X-Hermes-Session-Key: /   { key = $2 }
  /^X-Hermes-Session-Id: /    { id = $2 }
  key != "" && id != ""       { if (key == "moe-meeting-notes") notes[id] = 1
                                if (key == "moe-meeting-scan")  scan[id] = 1
                                key = ""; id = "" }
  END { n = 0; s = 0; both = 0
        for (i in notes) { n++; if (i in scan) both++ }
        for (i in scan) s++
        print n, s, both }')"
case "$SHARED" in
  "0 "*|*" 0 "*) bad "could not pair the meeting keys with their session ids ($SHARED) — nothing was compared" ;;
  *" 0")        ok "and the two never share a session id" ;;
  *)            bad "the scan and the notes share a session id ($SHARED) — the notes would be answered as action items" ;;
esac
grep -q "^Authorization: Bearer test-key" "$REQLOG" && ok "bearer key sent" || bad "no bearer"
grep -q '<transcript>' "$REQLOG" && grep -q 'them (speaker 1)' "$REQLOG" && ok "transcript fenced in the request" || bad "transcript not in request"
grep -q 'ONE JSON object' "$REQLOG" && ok "fixed summary prompt present" || bad "prompt missing"
grep -q "^X-Hermes-Session-Key: moe$" "$REQLOG" && bad "conversation session key leaked" || ok "conversation session untouched"
grep -q "meeting: Notes written" "$MOELOG" && ok "outcome logged" || bad "no outcome line in the log"
grep -q "meeting: bookmark at 00:03" "$MOELOG" && grep -q "meeting: bookmark at 00:07" "$MOELOG" && ok "bookmarks logged" || bad "bookmark log lines missing"
grep -q '^## Bookmarks' "$SCRATCH/out/1/summary.md" && grep -q '^- \[00:07\] ' "$SCRATCH/out/1/summary.md" && ok "bookmarks listed in summary.md" || bad "bookmarks missing from summary.md"
grep -q 'bookmarked these moments' "$REQLOG" && grep -q '\[00:07\]' "$REQLOG" && ok "bookmarks weighted in the prompt" || bad "bookmarks not in the prompt"
grep -q '"taker" *: *"moe-agent"' "$SCRATCH/out/1/meeting.json" && ok "taker is moe-agent" || bad "taker missing"
grep -q 'diarizer found 2 speaker' "$SCRATCH/err" && ok "diarizer found 2 speakers" || bad "diarizer: $(grep -o 'diarizer found.*' "$SCRATCH/err")"
unset MOE_MEETING_BOOKMARKS
grep -qi "tuesday" "$MOELOG" && bad "transcript text in the log" || ok "text never logged"

echo "== 2b. the minute scan's action items reach the notes"
# While a meeting runs, the new lines go to the brain once a minute and what
# comes back is merged into the notes at the end. The fake answers the scan
# (MOE_FAKE_MEETING_ACTIONS, told apart by <new-lines>) with one item the
# summary also finds, spelled differently — "Send the notes." vs "send the
# notes" — and one only it saw. The first must not appear twice; the second
# must survive into summary.md.
grep -q '<new-lines>' "$REQLOG" && ok "the scan reached the gateway" || bad "no minute-scan request"
grep -q 'You watch a meeting transcript as it grows' "$REQLOG" && ok "scan prompt sent" || bad "scan prompt missing"
grep -q 'minute scan found 2 action item' "$SCRATCH/err" && ok "the scan parsed both items" || bad "scan: $(grep -o 'minute scan.*' "$SCRATCH/err")"
grep -q '^- \*\*you\*\*: book the follow-up — by Friday' "$SCRATCH/out/1/summary.md" \
  && ok "the live-only item is in the notes" || bad "live item missing from summary.md"
# Only the action-item lines ("- **who**: …"); a bookmark label near 00:07
# quotes the same words and is not a duplicate.
[ "$(grep -ci '^- \*\*.*send the notes' "$SCRATCH/out/1/summary.md")" = 1 ] \
  && ok "the item both passes found is listed once" || bad "duplicated: $(grep -i '^- \*\*.*send the notes' "$SCRATCH/out/1/summary.md")"
python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
what = [a["what"] for a in r["notes"]["action_items"]]
assert what == ["send the notes", "book the follow-up"], what
' "$SCRATCH/out/1/meeting.json" && ok "meeting.json has both, summary first" || bad "action items in meeting.json wrong"

echo "== 3. a reply that is not notes"
printf 'Sorry, I cannot summarise this meeting.' > "$SCRATCH/prose"
start_fake MOE_FAKE_MEETING="$SCRATCH/prose"
run "$SCRATCH/out/3"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
[ ! -f "$SCRATCH/out/3/summary.md" ] && ok "no summary.md" || bad "summary.md written from prose"
[ -s "$SCRATCH/out/3/transcript.txt" ] && ok "transcript kept" || bad "transcript missing"
# The record now quotes what came back, so a meeting with no notes can be
# told from the record alone whether the model refused, answered another
# question, or returned nothing (MeetingSummary.swift:
#   record.summaryFailure = "the brain's reply was not notes: " + NotesRequest.excerpt(reply)).
# This required the sentence to END at "not notes", and failed on the excerpt.
grep -q '"summaryFailure" *: *"the brain.s reply was not notes: .*Sorry, I cannot summarise' "$SCRATCH/out/3/meeting.json" \
  && ok "meeting.json says why, and quotes the reply it could not use" \
  || bad "reason missing or without the reply: $(grep -o '"summaryFailure"[^,}]*' "$SCRATCH/out/3/meeting.json" | head -1)"

echo "== 4. no gateway"
stop_fake
run "$SCRATCH/out/4"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "exit $RC"
[ -s "$SCRATCH/out/4/transcript.txt" ] && ok "transcript kept" || bad "transcript missing"
grep -q '"summaryFailure" *: *"brain unavailable' "$SCRATCH/out/4/meeting.json" && ok "brain unavailable recorded" || bad "reason missing"
grep -q "not reachable" "$SCRATCH/err" && ok "stderr says so" || bad "stderr silent: $(tail -1 "$SCRATCH/err")"

echo "== 5. summarising off: nothing sent"
write_config false
: > "$REQLOG"
start_fake
run "$SCRATCH/out/5"
[ ! -s "$REQLOG" ] && ok "no request reached the gateway" || bad "a request was made"
[ ! -f "$SCRATCH/out/5/summary.md" ] && [ -s "$SCRATCH/out/5/transcript.txt" ] && ok "transcript only" || bad "unexpected outputs"
grep -q 'Summarising is off' "$SCRATCH/err" && ok "stderr says so" || bad "stderr: $(tail -1 "$SCRATCH/err")"

echo "== 6. captures taken during the meeting reach the notes"
write_config true
: > "$REQLOG"
start_fake
MOE_MEETING_CAPTURES=1 run "$SCRATCH/out/6"
[ "$RC" -eq 0 ] && ok "exit 0" || { bad "exit $RC"; cat "$SCRATCH/err"; }
grep -q '^## Screens' "$SCRATCH/out/6/summary.md" && ok "Screens section in summary.md" || bad "no Screens section"
grep -q '^- \[00:03\] screenshot · screen share — A slide titled Ship plan with Tuesday circled (shots/001-00m03s-screen-share.jpg)' "$SCRATCH/out/6/summary.md" \
  && ok "the screenshot line: time, reason, caption, file" || bad "screenshot line wrong: $(grep 'shots/' "$SCRATCH/out/6/summary.md")"
grep -q '^- \[00:05\] clip 00:02 (clips/001-00m05s.mp4)' "$SCRATCH/out/6/summary.md" && ok "the clip line with its length" || bad "clip line wrong: $(grep 'clips/' "$SCRATCH/out/6/summary.md")"
grep -q 'Screenshots were taken during the meeting' "$REQLOG" && grep -q '\[00:03\] A slide titled Ship plan' "$REQLOG" \
  && ok "the caption reached the summary prompt" || bad "caption not in the prompt"
grep -q 'clips/001-00m05s.mp4' "$REQLOG" && bad "an uncaptioned clip leaked into the prompt" || ok "uncaptioned captures stay out of the prompt"
python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
c = r["captures"]
assert len(c) == 2, c
assert c[0]["kind"] == "screenshot" and c[0]["trigger"] == "auto" and c[0]["reason"] == "screen-share", c[0]
assert c[0]["caption"].startswith("A slide"), c[0]
assert c[1]["kind"] == "recording" and c[1]["durationSeconds"] == 2.5, c[1]
assert r["callApp"] == "Zoom", r
' "$SCRATCH/out/6/meeting.json" && ok "meeting.json carries both captures and the call app" || bad "captures in meeting.json wrong"
[ -f "$SCRATCH/out/6/shots/001-00m03s-screen-share.jpg" ] && ok "shots/ written under the meeting folder" || bad "shots/ missing"
[ "$(stat -f %Lp "$SCRATCH/out/6/shots/001-00m03s-screen-share.jpg")" = "600" ] && ok "capture file is owner-only" || bad "capture file mode $(stat -f %Lp "$SCRATCH/out/6/shots/001-00m03s-screen-share.jpg")"
[ ! -f "$SCRATCH/out/1/summary.md" ] || ! grep -q '^## Screens' "$SCRATCH/out/1/summary.md" && ok "no Screens section without captures" || bad "Screens section appeared with no captures"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
