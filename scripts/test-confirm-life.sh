#!/bin/bash
# NEEDS: debug-confirm
#
# A confirmation card is bound to whoever asked for it (Sources/MoeDesign/
# ConfirmLifecycle.swift, tools/confirm.sh).
#
# On 2026-09-25 a scheduled job's watchdog killed the job while its WhatsApp
# card was up; the card had no idea and sat over the owner's chat for ninety
# minutes. These checks do the damage and look at what is left:
#
#   * the REAL moe-confirm, in `--withdraw-test` (the lifecycle with no window,
#     so nothing appears on anybody's screen): kill its requester, kill its
#     parent with SIGKILL, let its deadline pass, send it SIGTERM — and each
#     time require exit 7 and a sentence in the inbox saying nothing was sent;
#   * confirm.sh: kill it and require its card gone; a 7 from the card must
#     come back as 7 and must NOT open the AppleScript dialog;
#   * both together: confirm.sh running the real card, SIGKILLed.
#
# Needs a built MoeConfirm (`swift build --product MoeConfirm`). A missing
# binary FAILS rather than skipping: a check that cannot run is not a pass.
set -u

unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
# Always under /private/tmp, whatever $TMPDIR says. confirm.sh honours its
# test seams (the stub card, the stub osascript) ONLY when it runs from a
# temporary directory; from anywhere else it goes looking for the real
# moe-confirm in /Applications/Memoe.app and draws a real card on the
# owner's screen. A $TMPDIR outside the recognised prefixes did exactly that
# once (2026-09-25). See the preflight below.
S="$(mktemp -d /private/tmp/moe-confirm-life.XXXXXX)"
PIDS=()
trap 'for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done; rm -rf "$S"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2" | head -8; }

# ── Preflight: nothing in this file may ever put a card on a real display ──
#
# 1. Every copy of confirm.sh this file runs must sit where its seams are
#    honoured — the same prefixes confirm.sh's seam_away/find_ui accept.
#    Checked BEFORE anything runs, because the failure mode is a real card.
# 2. Every launch of the real moe-confirm below goes through `card`, which
#    refuses anything but --withdraw-test (no window at all) or --describe
#    (prints and exits); and this file is read to prove no line launches
#    "$BIN" any other way.
seam_ok() { case "$(cd "$1" && pwd -P)" in
  /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;; esac; return 1; }
if ! seam_ok "$S"; then
  echo "  FAIL refusing to run: $S is not a directory confirm.sh treats as a test copy — it would reach the real card"
  exit 1
fi
bare=$(grep -n '"\$BIN"' "$0" | grep -v -e '--withdraw-test' -e '--describe' \
       -e 'BIN_DEFINITION' -e 'BARE_CHECK' | grep -v -E '^[0-9]+:[[:space:]]*#')
if [ -n "$bare" ]; then
  echo "  FAIL a line launches moe-confirm without a headless flag:"; echo "$bare"
  exit 1
fi
card() {
  case " $* " in
    *" --withdraw-test "*|*" --describe "*) exec "$BIN" "$@" ;;   # BIN_DEFINITION (exec: the pid is the card)
    *) echo "  FAIL refused to launch moe-confirm without --withdraw-test/--describe" >&2; exit 99 ;;
  esac
}

BIN=""
for c in "${MOE_CONFIRM_BIN_FOR_TESTS:-}" "$REPO/.build/debug/MoeConfirm" "$REPO/.build/release/MoeConfirm"; do
  [ -n "$c" ] && [ -x "$c" ] && { BIN="$c"; break; }   # BARE_CHECK
done

# A Moe home: the card only believes a `home=` that holds tools/confirm.sh.
HOME_DIR="$S/home"
mkdir -p "$HOME_DIR/tools"
cp "$REPO/moe-home/tools/confirm.sh" "$HOME_DIR/tools/confirm.sh"
seam_ok "$HOME_DIR/tools" || { echo "  FAIL refusing to run: the test copy of confirm.sh would reach the real card"; exit 1; }
INBOX="$HOME_DIR/inbox"
# Nothing in here may reach the real home. A card handed no `home=` falls
# back to $MOE_HOME and then ~/.moe — and a running Memoe shows whatever
# lands in ~/.moe/inbox on the owner's island. Both point at scratch.
export MOE_HOME="$S/fallback-home" HOME="$S/fallback-home"
# And a temp dir of its own: a SIGKILLed confirm.sh (as below) runs no trap
# and leaves its empty answer file behind, which test-confirm-ui.sh counts.
export TMPDIR="$S/tmp"
mkdir -p "$TMPDIR"
mkdir -p "$HOME"

notes() { ls "$INBOX" 2>/dev/null | grep -c '\.json$'; }
last_note() { cat "$(ls -d "$INBOX"/*.json 2>/dev/null | sort | tail -1)" 2>/dev/null; }
# Wait up to $2 seconds for pid $1 to be gone. 0 = gone.
gone_within() { local i=0; while kill -0 "$1" 2>/dev/null; do
  i=$((i+1)); [ "$i" -gt $(( $2 * 10 )) ] && return 1; sleep 0.1; done; return 0; }
request() { # to, extra records…
  printf 'channel=WhatsApp\0to=%s\0body=Running late\0home=%s\0' "$1" "$HOME_DIR"; shift
  for r in "$@"; do printf '%s\0' "$r"; done
}

echo "moe-confirm withdraws when nobody is waiting"
if [ -z "$BIN" ]; then   # BARE_CHECK
  fail "no built MoeConfirm — run: swift build --product MoeConfirm"
else
  # 1. The requester dies.
  sleep 60 & REQ=$!; PIDS+=("$REQ")
  before=$(notes)
  request "Dad" "requester=$REQ" | card --withdraw-test >/dev/null 2>"$S/err1" & CARD=$!; PIDS+=("$CARD")
  sleep 1
  kill -0 "$CARD" 2>/dev/null && ok "the card waits while its requester lives" \
    || fail "the card left while its requester was alive" "$(cat "$S/err1")"
  kill -9 "$REQ"
  if gone_within "$CARD" 5; then
    wait "$CARD"; st=$?
    [ "$st" -eq 7 ] && ok "requester killed → the card withdrew (exit 7)" || fail "requester killed → exit $st, wanted 7"
  else
    fail "requester killed → the card is STILL UP after 5 s (the 2026-09-25 orphan)"
  fi
  [ "$(notes)" -gt "$before" ] && ok "  …and left a note in the inbox" || fail "  …no inbox note"
  last_note | grep -q 'That WhatsApp send to “Dad” was withdrawn because the task that asked for it stopped — nothing was sent.' \
    && ok "  …saying what was not sent, and why" || fail "  …the note says something else" "$(last_note)"
  last_note | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["chat_id"]=="screen" and isinstance(d["at"],float)' 2>/dev/null \
    && ok "  …in the shape the island reads" || fail "  …not in deliver.write_inbox's shape" "$(last_note)"
  perm=$(stat -f %Lp "$(ls -d "$INBOX"/*.json | sort | tail -1)")
  [ "$perm" = "600" ] && ok "  …mode 0600" || fail "  …mode $perm, wanted 600"

  # 2. Its parent (confirm.sh's place) is SIGKILLed: no trap runs anywhere.
  before=$(notes)
  request "Mum" >"$S/req2"
  bash -c '"$0" --withdraw-test <"$1" 2>/dev/null & echo $! >"$2"; wait' "$BIN" "$S/req2" "$S/card2.pid" & PARENT=$!
  PIDS+=("$PARENT")
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$S/card2.pid" ] && break; sleep 0.2; done
  CARD2=$(cat "$S/card2.pid" 2>/dev/null); PIDS+=("$CARD2")
  sleep 0.5
  kill -9 "$PARENT"
  if [ -n "$CARD2" ] && gone_within "$CARD2" 5; then ok "parent SIGKILLed → the card withdrew on its own"
  else fail "parent SIGKILLed → the card is still up"; fi
  [ "$(notes)" -gt "$before" ] && last_note | grep -q 'to “Mum” was withdrawn' && ok "  …and said so in the inbox" \
    || fail "  …no note for Mum" "$(last_note)"

  # 3. The deadline passes.
  request "Bob" "deadline=$(( $(date +%s) + 1 ))" | card --withdraw-test >/dev/null 2>&1 & CARD3=$!; PIDS+=("$CARD3")
  if gone_within "$CARD3" 6; then wait "$CARD3"; st=$?
    [ "$st" -eq 7 ] && ok "deadline passed → withdrew (exit 7)" || fail "deadline passed → exit $st"
  else fail "deadline passed → still up after 6 s"; fi

  # 3b. The person is at the Mac (a fresh, active presence.json): the card
  # withdraws the same way, but only the log hears about it — no inbox note
  # (owner, 2026-09-30: "send withdrawn" cards were noise).
  before=$(notes)
  printf '{"active": true, "at": %s}' "$(date +%s)" >"$HOME_DIR/presence.json"
  request "Zed" "deadline=$(( $(date +%s) + 1 ))" | card --withdraw-test >/dev/null 2>"$S/err3b" & CARD3B=$!
  PIDS+=("$CARD3B")
  if gone_within "$CARD3B" 6; then wait "$CARD3B"; st=$?
    [ "$st" -eq 7 ] && ok "at the Mac → still withdrew (exit 7)" || fail "at the Mac → exit $st"
  else fail "at the Mac → still up after 6 s"; fi
  [ "$(notes)" -eq "$before" ] && ok "  …and left no inbox note" || fail "  …left a note anyway" "$(last_note)"
  grep -q "no inbox note" "$S/err3b" && ok "  …but logged why" || fail "  …stderr: $(cat "$S/err3b")"
  rm -f "$HOME_DIR/presence.json"
  last_note | grep -q 'to “Bob” expired before you answered' && ok "  …and the note says it expired" \
    || fail "  …deadline note" "$(last_note)"

  # 3b. A far-future deadline is not believed. The ceiling is shrunk for the
  #     test (it can only ever be shortened), and the card must leave at IT.
  request "Zed" "deadline=99999999999" \
    | MOE_CONFIRM_LONGEST_WAIT_FOR_TESTS=2 card --withdraw-test >/dev/null 2>&1 & CARD3B=$!; PIDS+=("$CARD3B")
  sleep 1
  kill -0 "$CARD3B" 2>/dev/null && ok "a far-future deadline: still up before the ceiling" || fail "left before the ceiling"
  if gone_within "$CARD3B" 5; then ok "  …and withdrawn at the ceiling, not in the year 5138"
  else fail "a far-future deadline was believed — the card is still up"; kill -9 "$CARD3B" 2>/dev/null; fi
  last_note | grep -q 'to “Zed” expired' && ok "  …as an expiry" || fail "  …note" "$(last_note)"

  # 4. A far-future deadline is capped, not believed: --describe shows what
  #    was parsed, and the card keeps its own ceiling (ConfirmLifecycle).
  out=$(request "Bob" "deadline=99999999999" "requester=0 1 -5 $$" | card --describe 2>/dev/null)
  printf '%s\n' "$out" | grep -qx "requester	$$" && ok "requester pids 0, 1 and negatives are dropped" \
    || fail "requester parse" "$(printf '%s\n' "$out" | grep requester)"

  # 4b. Who asked, when it was not the person: parsed, one line, legible.
  out=$(request "Bob" "origin=a scheduled job" | card --describe 2>/dev/null)
  printf '%s\n' "$out" | grep -qx "origin	a scheduled job" && ok "the card reads who asked" \
    || fail "origin parse" "$(printf '%s\n' "$out" | grep origin)"

  # 5. SIGTERM is the requester calling it off.
  request "Eve" | card --withdraw-test >/dev/null 2>&1 & CARD5=$!; PIDS+=("$CARD5")
  sleep 1; kill -TERM "$CARD5"
  if gone_within "$CARD5" 5; then wait "$CARD5"; st=$?
    [ "$st" -eq 7 ] && ok "SIGTERM → withdrew (exit 7), never 0" || fail "SIGTERM → exit $st"
  else fail "SIGTERM → still up"; fi
  last_note | grep -q 'to “Eve” was closed before you answered' && ok "  …and the note says it was closed" \
    || fail "  …TERM note" "$(last_note)"

  # 5a. A hang-up that arrives before the card has even read its request is
  #     not lost: the handlers are installed first, and the note is written
  #     once the request is in.
  before=$(notes)
  ( sleep 1.5; request "Early" ) | card --withdraw-test >/dev/null 2>&1 & CARD5A=$!; PIDS+=("$CARD5A")
  sleep 0.7; kill -HUP "$CARD5A"
  if gone_within "$CARD5A" 8; then wait "$CARD5A"; st=$?
    [ "$st" -eq 7 ] && ok "a hang-up before the request was read → still exit 7" || fail "early SIGHUP → exit $st"
  else fail "early SIGHUP → still up"; kill -9 "$CARD5A" 2>/dev/null; fi
  [ "$(notes)" -gt "$before" ] && last_note | grep -q 'to “Early” was withdrawn' \
    && ok "  …and the note was still written" || fail "  …no note after an early hang-up" "$(last_note)"

  # 5b. SIGHUP is the requester hanging up (the plugin, when the turn ends).
  request "Hal" | card --withdraw-test >/dev/null 2>&1 & CARD5B=$!; PIDS+=("$CARD5B")
  sleep 1; kill -HUP "$CARD5B"
  if gone_within "$CARD5B" 5; then wait "$CARD5B"; st=$?
    [ "$st" -eq 7 ] && ok "SIGHUP → withdrew (exit 7)" || fail "SIGHUP → exit $st"
  else fail "SIGHUP → still up"; fi
  last_note | grep -q 'to “Hal” was withdrawn because the task that asked for it stopped' \
    && ok "  …because the task that asked stopped" || fail "  …HUP note" "$(last_note)"
fi

echo "confirm.sh takes its card with it"
# A stub card that records what it was handed and then waits to be killed.
cat >"$S/stub-card" <<'STUB'
#!/bin/bash
cat >"$REQUEST_OUT"
echo $$ >"$CARD_PID_OUT"
[ -n "${UI_STATUS:-}" ] && exit "$UI_STATUS"
sleep 60 &
wait
STUB
chmod +x "$S/stub-card"
cat >"$S/osascript" <<'STUB'
#!/bin/bash
cat >/dev/null; echo ran >>"$OSA_LOG"; echo Cancel
STUB
chmod +x "$S/osascript"
export MOE_HOOK_TEST=1 MOE_CONFIRM_UI_FOR_TESTS="$S/stub-card" MOE_OSASCRIPT_FOR_TESTS="$S/osascript"
export REQUEST_OUT="$S/request.bin" CARD_PID_OUT="$S/card.pid" OSA_LOG="$S/osa.log"
: >"$OSA_LOG"

# 6. What the card is told about its life.
: >"$CARD_PID_OUT"
MOE_CONFIRM_REQUESTER=4242 MOE_CONFIRM_DEADLINE=2000000000 \
  "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1 & SH=$!; PIDS+=("$SH")
for _ in $(seq 1 30); do [ -s "$CARD_PID_OUT" ] && break; sleep 0.1; done
recs="$(tr '\0' '\n' <"$S/request.bin")"
printf '%s\n' "$recs" | grep -qx "requester=$$ 4242" && ok "the card is handed its caller's pid and the plugin's" \
  || fail "requester record" "$(printf '%s\n' "$recs" | grep requester)"
printf '%s\n' "$recs" | grep -qx "deadline=2000000000" && ok "  …and the caller's deadline" \
  || fail "deadline record" "$(printf '%s\n' "$recs" | grep deadline)"
printf '%s\n' "$recs" | grep -qx "home=$(cd "$HOME_DIR" && pwd -P)" && ok "  …and the home its note goes to" \
  || fail "home record" "$(printf '%s\n' "$recs" | grep home)"

# 7. confirm.sh is killed (TERM, as a subprocess timeout or a group kill
#    sends first): the card goes with it.
CARD=$(cat "$CARD_PID_OUT")
kill -TERM "$SH"
if gone_within "$CARD" 5; then ok "confirm.sh terminated → its card was taken down"
else fail "confirm.sh terminated → its card is still running (pid $CARD)"; kill -9 "$CARD" 2>/dev/null; fi
wait "$SH" 2>/dev/null

# 7b. The TERM trap on its own: a copy of confirm.sh with NO exit trap still
#     takes its card down when it is terminated.
sed '/^ *trap .* EXIT$/d' "$HOME_DIR/tools/confirm.sh" >"$S/no-exit-confirm.sh"
chmod +x "$S/no-exit-confirm.sh"
if ! grep -q "^ *trap .* EXIT$" "$HOME_DIR/tools/confirm.sh" || grep -q "^ *trap .* EXIT$" "$S/no-exit-confirm.sh" \
   || ! grep -q "^trap 'stop_card; exit 143' TERM" "$S/no-exit-confirm.sh"; then
  fail "could not make a copy with only the TERM trap"
else
  : >"$CARD_PID_OUT"
  "$S/no-exit-confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1 & SH=$!; PIDS+=("$SH")
  for _ in $(seq 1 30); do [ -s "$CARD_PID_OUT" ] && break; sleep 0.1; done
  CARD=$(cat "$CARD_PID_OUT")
  kill -TERM "$SH"
  if [ -n "$CARD" ] && gone_within "$CARD" 5; then ok "the TERM trap alone (no EXIT trap) takes the card down"
  else fail "with only the TERM trap, the card survived confirm.sh"; kill -9 "$CARD" 2>/dev/null; fi
  wait "$SH" 2>/dev/null
fi

# 7c. Who asked, when it was not the person's own turn, reaches the card.
: >"$CARD_PID_OUT"
MOE_CONFIRM_ORIGIN="a scheduled job" UI_STATUS=1 "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1
tr '\0' '\n' <"$S/request.bin" | grep -qx "origin=a scheduled job" && ok "the card is told a scheduled job asked" \
  || fail "origin record" "$(tr '\0' '\n' <"$S/request.bin" | grep origin)"
: >"$CARD_PID_OUT"
UI_STATUS=1 "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1
! tr '\0' '\n' <"$S/request.bin" | grep -q "^origin=" && ok "  …and a person's own send carries no label" \
  || fail "an origin record with no origin"

# 7d. The card's answer is marked for the plugin's turn watch — only on a
#     FINAL answer, and only on a path of the shape the plugin makes.
MARK="$S/moe-card-x/answered"
mkdir -p "$S/moe-card-x"
for st in 0 1; do
  rm -f "$MARK"
  UI_STATUS=$st MOE_CONFIRM_ANSWERED="$MARK" "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1
  [ -f "$MARK" ] && ok "a final answer on the card (exit $st) is marked for the turn watch" || fail "no mark after exit $st"
done
rm -f "$MARK"
UI_STATUS=7 MOE_CONFIRM_ANSWERED="$MARK" "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1
[ ! -e "$MARK" ] && ok "  …a withdrawal is not an answer" || fail "a withdrawn card was marked answered"
UI_STATUS=0 MOE_CONFIRM_ANSWERED="$S/elsewhere" "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1
[ ! -e "$S/elsewhere" ] && ok "  …and nothing else can be aimed at with it" || fail "touched an arbitrary path"

# 7e. The AppleScript fallback. A stand-in osascript records whether the mark
#     was already there when it was asked (it must not be: nobody had answered
#     yet), the script it was handed, and its arguments.
cat >"$S/osa-probe" <<'STUB'
#!/bin/bash
cat >"$OSA_SCRIPT_OUT"
printf '%s\n' "$@" >"$OSA_ARGS_OUT"
[ -e "${MOE_CONFIRM_ANSWERED:-/nonexistent}" ] && echo premature >>"$OSA_LOG"
echo $$ >"$OSA_PID_OUT"
[ -n "${OSA_SLEEP:-}" ] && { sleep "$OSA_SLEEP" & wait; }
printf '%s\n' "${OSA_ANSWER:-Cancel}"
STUB
chmod +x "$S/osa-probe"
export OSA_SCRIPT_OUT="$S/osa-script" OSA_ARGS_OUT="$S/osa-args" OSA_PID_OUT="$S/osa-pid"
for fall in 5 2; do
  : >"$OSA_LOG"; rm -f "$MARK"
  UI_STATUS=$fall OSA_ANSWER=Send MOE_OSASCRIPT_FOR_TESTS="$S/osa-probe" MOE_CONFIRM_ANSWERED="$MARK" \
    MOE_CONFIRM_DEADLINE=$(( $(date +%s) + 100 )) "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1; st=$?
  label=$([ "$fall" = 5 ] && echo "a card whose answer was not usable (fallthrough)" || echo "no card at all (fallback only)")
  [ "$st" -eq 0 ] && ! grep -q premature "$OSA_LOG" && [ -f "$MARK" ] \
    && ok "$label: not marked until the other dialog answered, then marked" \
    || fail "$label: st=$st, $(cat "$OSA_LOG"), mark=$([ -f "$MARK" ] && echo yes || echo no)"
done
grep -q "giving up after giveUp" "$OSA_SCRIPT_OUT" && ok "the fallback dialog is bounded (giving up after)" || fail "no give-up in the AppleScript"
g=$(sed -n 7p "$OSA_ARGS_OUT")   # "-", channel, to, shown, hidden, kind, give-up
[ -n "$g" ] && [ "$g" -le 100 ] && [ "$g" -ge 90 ] && ok "  …at the card's own deadline ($g s left)" || fail "give-up seconds '$g'"
rm -f "$MARK"
UI_STATUS=2 OSA_ANSWER=GaveUp MOE_OSASCRIPT_FOR_TESTS="$S/osa-probe" MOE_CONFIRM_ANSWERED="$MARK" \
  "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>"$S/err-gave"; st=$?
[ "$st" -eq 7 ] && [ ! -e "$MARK" ] && grep -q expired "$S/err-gave" \
  && ok "  …and a dialog that gave up is an expiry (exit 7), not an answer" || fail "gave up → st=$st"
UI_STATUS=2 OSA_ANSWER=Error MOE_OSASCRIPT_FOR_TESTS="$S/osa-probe" MOE_CONFIRM_ANSWERED="$MARK" \
  "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1; st=$?
[ "$st" -eq 1 ] && [ ! -e "$MARK" ] && ok "  …a dialog that errored sends nothing and is not an answer" || fail "error → st=$st"
UI_STATUS=2 OSA_ANSWER=Error MOE_OSASCRIPT_FOR_TESTS="$S/osa-probe" \
  "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>"$S/err-osa"
! grep -q "cancelled by user" "$S/err-osa" && grep -q "could not be shown" "$S/err-osa" \
  && ok "  …and says it could not be shown, not that anyone cancelled" || fail "error wording: $(cat "$S/err-osa")"
# Withdrawn with its turn: the fallback dialog goes when confirm.sh is hung up.
rm -f "$OSA_PID_OUT"
UI_STATUS=2 OSA_SLEEP=60 MOE_OSASCRIPT_FOR_TESTS="$S/osa-probe" \
  "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1 & SH=$!; PIDS+=("$SH")
for _ in $(seq 1 50); do [ -s "$OSA_PID_OUT" ] && break; sleep 0.1; done
OSAP=$(cat "$OSA_PID_OUT" 2>/dev/null); PIDS+=("$OSAP")
kill -HUP "$SH"
if [ -n "$OSAP" ] && gone_within "$OSAP" 5; then ok "  …and it is taken down with its turn (HUP)"
else fail "the fallback dialog outlived confirm.sh"; fi
wait "$SH" 2>/dev/null

# 8. Without a deadline from the caller there is still one.
: >"$CARD_PID_OUT"
UI_STATUS=1 "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>&1
d=$(tr '\0' '\n' <"$S/request.bin" | sed -n 's/^deadline=//p')
now=$(date +%s)
[ -n "$d" ] && [ "$d" -gt "$now" ] && [ "$d" -le $(( now + 1800 )) ] \
  && ok "no caller deadline → half an hour, never none" || fail "default deadline is '$d'"

# 9. A withdrawal is a 7 and never the other dialog.
: >"$OSA_LOG"
UI_STATUS=7 "$HOME_DIR/tools/confirm.sh" "WhatsApp" "Dad" "hi" >/dev/null 2>"$S/err9"; st=$?
[ "$st" -eq 7 ] && ok "card withdrew → confirm.sh exits 7" || fail "card withdrew → confirm.sh exit $st"
[ ! -s "$OSA_LOG" ] && ok "  …and no AppleScript dialog was opened for nobody" || fail "  …the fallback dialog ran"
grep -q "expired" "$S/err9" && ok "  …saying it expired" || fail "  …stderr: $(cat "$S/err9")"

echo "confirm.sh + the real card, SIGKILLed"
if [ -n "$BIN" ]; then   # BARE_CHECK
  cat >"$S/real-card" <<EOF
#!/bin/bash
echo \$\$ >"$S/real.pid"
exec "$BIN" --withdraw-test
EOF
  chmod +x "$S/real-card"
  before=$(notes)
  MOE_CONFIRM_UI_FOR_TESTS="$S/real-card" "$HOME_DIR/tools/confirm.sh" "Telegram" "Sam" "hi" >/dev/null 2>&1 & SH=$!
  PIDS+=("$SH")
  for _ in $(seq 1 30); do [ -s "$S/real.pid" ] && break; sleep 0.1; done
  REAL=$(cat "$S/real.pid" 2>/dev/null); PIDS+=("$REAL")
  sleep 0.7
  kill -0 "$REAL" 2>/dev/null && ok "the real card is up under confirm.sh" || fail "the real card did not start"
  kill -9 "$SH"
  if [ -n "$REAL" ] && gone_within "$REAL" 5; then ok "confirm.sh SIGKILLed → the real card withdrew"
  else fail "confirm.sh SIGKILLed → the real card is orphaned"; fi
  [ "$(notes)" -gt "$before" ] && last_note | grep -q 'That Telegram send to “Sam” was withdrawn' \
    && ok "  …and the inbox says nothing was sent to Sam" || fail "  …no note" "$(last_note)"
else
  fail "no built MoeConfirm for the end-to-end check"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
