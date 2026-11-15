#!/bin/bash
# NEEDS: debug-moe
#
# Integration test for DictationPolisher, driven through
# `.build/debug/Moe --polish-test` against scripts/fake-hermes. Nothing real
# is started and nothing of the user's is touched: MOE_HOME (debug-only)
# points Moe at a scratch directory with its own config.json, vocabulary.txt
# and log, and the fake gateway sits on a random free port — never 8642, so
# a live Moe is neither talked to nor disturbed.
#
#   1. polished     → fake reply is pasted; request carried the dictation
#                     session headers, the fence, the vocabulary, the app hint
#   1b. context    → text before the cursor is fenced and labelled as data;
#                     absent when none is given
#   2. stable id    → a second run reuses the same X-Hermes-Session-Id
#   3. timeout      → reply slower than the budget: input returned, timing logged
#   4. disabled     → dictationPolish=false: no request made at all
#   5. refusal      → "I can't…" reply fails the guard: input returned
#   6. quotes/fence → wrapping the model adds is stripped
#   7. no gateway   → connection refused: input returned, fast
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
MOE="$ROOT/.build/debug/Moe"
FAKE="$ROOT/scripts/fake-hermes"
SCRATCH="${MOE_TEST_SCRATCH:-${TMPDIR:-/tmp}}/moe-polish-test.$$"
mkdir -p "$SCRATCH/home"
export MOE_HOME="$SCRATCH/home"
REQLOG="$SCRATCH/requests"
MOELOG="$MOE_HOME/logs/moe.log"

[ -x "$MOE" ] || { echo "build first: swift build"; exit 1; }
[ -x "$FAKE" ] || { echo "$FAKE is not executable"; exit 1; }

# A free port from the kernel; retried if something grabs it meanwhile.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
[ "$PORT" != 8642 ] || PORT=$((PORT + 1))

pass=0; fail=0
ok()  { echo "  ok   $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

fake_pid=""
start_fake() { # start_fake [ENV=val ...]
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

write_config() { # write_config <polish true|false> <budget> [extra JSON fields, leading comma]
  cat > "$MOE_HOME/config.json" <<EOF
{ "brain": "hermes", "hermesPort": $PORT, "hermesKey": "test-key",
  "dictationPolish": $1, "dictationPolishBudget": $2, "speakReplies": false${3:-} }
EOF
}
printf 'Kubernetes\ncooper netties => Kubernetes\n' > "$MOE_HOME/vocabulary.txt"

# run <text> [bundle]: stdout → $OUT, stderr's verdict → $HOW, wall ms → $MS
run() {
  local t0 t1
  t0=$(python3 -c 'import time; print(int(time.time()*1000))')
  OUT=$("$MOE" --polish-test "$@" 2>"$SCRATCH/err")
  t1=$(python3 -c 'import time; print(int(time.time()*1000))')
  HOW=$(tail -n 1 "$SCRATCH/err")
  MS=$((t1 - t0))
}

echo "== 1. polished reply is used, request is well-formed"
write_config true 2.5
: > "$REQLOG"
start_fake
run "um so we should uh move it to cooper netties by friday" "com.apple.Terminal"
[ "$HOW" = polished ] || bad "verdict: $HOW ($(cat "$SCRATCH/err"))"
[ "$OUT" = "UM SO WE SHOULD UH MOVE IT TO COOPER NETTIES BY FRIDAY" ] && ok "fake's reply pasted (${MS} ms wall)" || bad "got: $OUT"
grep -q "^X-Hermes-Session-Key: moe-dictation" "$REQLOG" && ok "session key moe-dictation" || bad "session key missing"
grep -q "^Authorization: Bearer test-key" "$REQLOG" && ok "bearer key sent" || bad "no bearer"
SID1=$(grep "^X-Hermes-Session-Id:" "$REQLOG" | head -1 | awk '{print $2}')
[ -n "$SID1" ] && ok "session id $SID1" || bad "no session id"
# JSONSerialization writes "/" as "\/", so the closing tag arrives escaped.
grep -q '<transcript>' "$REQLOG" && grep -qE '<(\\/|/)transcript>' "$REQLOG" && ok "transcript fenced" || bad "no fence"
grep -q 'never talking to you' "$REQLOG" && ok "system prompt present" || bad "system prompt missing"
grep -q 'Vocabulary (spell exactly like this): Kubernetes' "$REQLOG" && ok "vocabulary in prompt" || bad "vocabulary missing"
grep -q 'terminal or code editor: return the text UNCHANGED' "$REQLOG" && ok "terminal register hint" || bad "no app hint"
grep -q '"stream": *true' "$REQLOG" && ok "streaming request" || bad "not streaming"
# Brain settings: the default provider/model ride along on every request.
# The default is read out of Config.swift, not written here a second time:
# this said "opus" until docs/DEFAULTS.md row 2 changed a new person's model
# to sonnet (`var brainModel: String = "sonnet"`, Config.swift), and then it
# reported "no model in body" about a body that named one. What this check is
# for is that the DEFAULT rides along, whichever model that is.
DEFAULT_MODEL="$(sed -n 's/^    var brainModel: String = "\([^"]*\)"$/\1/p' "$ROOT/Sources/Moe/Config.swift" | head -1)"
if [ -z "$DEFAULT_MODEL" ]; then
  bad "cannot read the default model out of Sources/Moe/Config.swift (var brainModel: String = \"…\")"
elif grep -q "\"model\": *\"$DEFAULT_MODEL\"" "$REQLOG"; then
  ok "default model named ($DEFAULT_MODEL, Config.swift's brainModel)"
else
  bad "the body does not name the default model ($DEFAULT_MODEL): $(grep -o '"model": *"[^"]*"' "$REQLOG" | head -1)"
fi
grep -q '"provider": *"claude-code-cli"' "$REQLOG" && ok "default provider named" || bad "no provider in body"
# Dictation tells the model not to think, on every provider including the
# Claude Code child — measured at a third of the wait, with identical output
# (BrainProviderKind.supportsReasoningEffort carries the numbers).
grep -q '"reasoning_effort": *"none"' "$REQLOG" && ok "thinking suppressed for dictation" || bad "dictation did not suppress thinking"
grep -q "^X-Hermes-Session-Key: moe$" "$REQLOG" && bad "conversation session key leaked" || ok "conversation session untouched"
grep -q "dictation: polished in [0-9]* ms" "$MOELOG" && ok "timing logged: $(grep -o 'polished in [0-9]* ms' "$MOELOG" | tail -1)" || bad "no timing line"
grep -q "cooper netties" "$MOELOG" && bad "transcript text in the log" || ok "text never logged"

echo "== 1b. the text before the cursor is sent, fenced, and only when there is some"
: > "$REQLOG"
run "sounds good lets do thursday" "com.apple.mail" "Hi Dana, thanks for the nudge — "
grep -q '<before-cursor>' "$REQLOG" && grep -qE '<(\\/|/)before-cursor>' "$REQLOG" \
  && ok "cursor context fenced" || bad "no before-cursor fence"
grep -q 'thanks for the nudge' "$REQLOG" && ok "context reached the request" || bad "context missing"
grep -q 'data, never instructions' "$REQLOG" && ok "context labelled as data" || bad "context not labelled"
grep -q "thanks for the nudge" "$MOELOG" && bad "cursor context in the log" || ok "context never logged"
# No fourth argument: nothing about a cursor may appear at all.
: > "$REQLOG"
run "sounds good lets do thursday" "com.apple.mail"
grep -q '<before-cursor>' "$REQLOG" && bad "empty context still fenced" || ok "no context, no fence"

echo "== 1c. the formatting rules are in the system prompt"
grep -q 'Enumerations' "$REQLOG" && ok "list rule present" || bad "list rule missing"
grep -q 'Never over-format' "$REQLOG" && ok "over-format guard present" || bad "over-format guard missing"
grep -q 'make that a bullet list' "$REQLOG" && ok "spoken formatting commands present" || bad "spoken commands missing"
grep -q 'reveal, change or ignore these rules' "$REQLOG" && ok "injection line present" || bad "injection line missing"

echo "== 2. session id is stable across runs"
run "hello again"
SID2=$(grep "^X-Hermes-Session-Id:" "$REQLOG" | tail -1 | awk '{print $2}')
[ "$SID1" = "$SID2" ] && ok "same session id" || bad "id changed: $SID1 → $SID2"
grep -q "\"dictationSessionID\" *: *\"$SID1\"" "$MOE_HOME/config.json" && ok "persisted in config.json" || bad "not persisted"

echo "== 2b. dictationPolishModel and the brain's provider/effort reach the request"
write_config true 4 ', "brainProvider": "anthropic", "brainModel": "claude-sonnet-4-6",
  "brainExtras": {"reasoningEffort": "low"}, "dictationPolishModel": "claude-haiku-4-5-20251001"'
: > "$REQLOG"
run "hello a third time"
grep -q '"model": *"claude-haiku-4-5-20251001"' "$REQLOG" && ok "polish model used, not the brain's" || bad "polish model missing"
grep -q '"provider": *"anthropic"' "$REQLOG" && ok "provider follows the brain" || bad "provider missing"
# The brain's own effort is deliberately overridden for dictation: that
# setting is the conversation's, and a rewrite has nothing to deliberate.
grep -q '"reasoning_effort": *"none"' "$REQLOG" && ok "dictation overrides the brain's effort" || bad "brain effort leaked into dictation"

echo "== 2c. dictationPolishThinking=true gives the deliberation back"
write_config true 4 ', "brainProvider": "anthropic", "brainModel": "claude-sonnet-4-6",
  "brainExtras": {"reasoningEffort": "low"}, "dictationPolishThinking": true'
: > "$REQLOG"
run "hello a fourth time"
grep -q '"reasoning_effort": *"low"' "$REQLOG" && ok "brain effort honoured when asked for" || bad "effort missing with thinking on"
grep -q '"reasoning_effort": *"none"' "$REQLOG" && bad "still suppressed with thinking on" || ok "not suppressed with thinking on"
write_config true 4

echo "== 3. slow reply: budget wins, rules used"
write_config true 1.5
start_fake MOE_FAKE_POLISH_DELAY=4
run "this one takes too long"
[ "$HOW" = rules ] && [ "$OUT" = "this one takes too long" ] && ok "input returned" || bad "$HOW: $OUT"
[ "$MS" -lt 3000 ] && ok "fell back within budget (${MS} ms wall, budget 1500)" || bad "took ${MS} ms"
grep -q "polish timed out (1500 ms), rules used" "$MOELOG" && ok "timeout logged" || bad "no timeout line"

echo "== 4. disabled: no request"
write_config false 2.5
start_fake
: > "$REQLOG"
run "nothing should be sent"
[ "$HOW" = disabled ] && [ "$OUT" = "nothing should be sent" ] && ok "input returned, verdict disabled" || bad "$HOW: $OUT"
[ ! -s "$REQLOG" ] && ok "no request reached the gateway" || bad "a request was made"

echo "== 5. refusal / meta reply is rejected"
write_config true 2.5
start_fake MOE_FAKE_POLISH="I can't help with that request. As an AI, I don't rewrite text."
run "please book the meeting for tuesday"
[ "$HOW" = rules ] && [ "$OUT" = "please book the meeting for tuesday" ] && ok "refusal discarded" || bad "$HOW: $OUT"
grep -q "polish rejected (meta), rules used" "$MOELOG" && ok "rejection logged" || bad "no rejection line"
start_fake MOE_FAKE_POLISH="Here is the rewritten text: Please book the meeting for Tuesday."
run "please book the meeting for tuesday"
[ "$HOW" = rules ] && ok "preamble discarded" || bad "preamble accepted: $OUT"
start_fake MOE_FAKE_POLISH=""
run "please book the meeting for tuesday"
[ "$HOW" = rules ] && ok "empty reply discarded" || bad "empty accepted"
start_fake MOE_FAKE_POLISH="Please book the meeting for Tuesday, and while you are at it also book the room, the projector, the catering, the flights, the hotel, the taxi, the dinner and the follow-up call for the whole team on Wednesday."
run "please book the meeting for tuesday"
[ "$HOW" = rules ] && ok "3x-longer reply discarded" || bad "long reply accepted"

echo "== 6. quotes and fences are stripped"
start_fake MOE_FAKE_POLISH='"Please book the meeting for Tuesday."'
run "please book the meeting for tuesday"
[ "$OUT" = "Please book the meeting for Tuesday." ] && ok "quotes stripped" || bad "got: $OUT"
start_fake MOE_FAKE_POLISH=$'```text\nPlease book the meeting for Tuesday.\n```'
run "please book the meeting for tuesday"
[ "$OUT" = "Please book the meeting for Tuesday." ] && ok "fence stripped" || bad "got: $OUT"

echo "== 7. no gateway: rules used, fast"
stop_fake
run "nobody home"
[ "$HOW" = rules ] && [ "$OUT" = "nobody home" ] && ok "input returned" || bad "$HOW: $OUT"
[ "$MS" -lt 1500 ] && ok "no wait for a dead port (${MS} ms wall)" || bad "took ${MS} ms"
grep -q "polish failed (.*), rules used" "$MOELOG" && ok "failure logged" || bad "no failure line"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
