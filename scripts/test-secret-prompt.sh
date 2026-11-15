#!/bin/bash
# NEEDS: debug-confirm
#
# The secret window (Sources/MoeConfirm/SecretMain.swift, contract in
# Sources/MoeDesign/SecretPrompt.swift): a person types a password or a
# sign-in code, and Hermes gets it as JSON on stdout — never argv, env or a
# log line.
#
# Out of the built binary, and never with a window: every launch below is
# `--describe` (prints and exits), `--wait-test` (the clock, the signals and
# the caller going away, no window) or a request that fails to parse. Checked:
#
#   * reached by NAME — `moe-secret`, what HERMES_SECRET_PROMPT_CMD points at,
#     with no arguments — as well as with --secret;
#   * a bad request answers {"ok":false,"reason":"invalid"}, exit 1;
#   * nobody answering answers "timeout", exit 1; SIGTERM and the caller
#     going away answer "cancelled", exit 1 — each ONE JSON object;
#   * nothing it writes to stderr carries the username it was handed;
#   * the send card is untouched: moe-confirm without --secret still speaks
#     the NUL-separated format.
#
# Needs a built MoeConfirm (`swift build --product MoeConfirm`). A missing
# binary FAILS rather than skipping.
set -u

unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
S="$(mktemp -d /private/tmp/moe-secret-prompt.XXXXXX)"
PIDS=()
trap 'for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done; rm -rf "$S"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2" | head -8; }

# No line of this file may launch the window. Every launch goes through
# `secret`, which refuses anything that could draw one.
bare=$(grep -n '"\$LINK"\|"\$BIN"' "$0" | grep -v -e 'SECRET_DEFINITION' -e 'BARE_CHECK' -e 'CARD_CHECK' \
       | grep -v -E '^[0-9]+:[[:space:]]*#')
if [ -n "$bare" ]; then
  echo "  FAIL a line launches the binary outside \`secret\`:"; echo "$bare"; exit 1
fi
secret() {
  case " $* " in
    *" --wait-test "*|*" --describe "*) exec "$LINK" "$@" ;;   # SECRET_DEFINITION
    *) echo "  FAIL refused to launch the secret window without a headless flag" >&2; exit 99 ;;
  esac
}

BIN=""
for c in "${MOE_CONFIRM_BIN_FOR_TESTS:-}" "$REPO/.build/debug/MoeConfirm" "$REPO/.build/release/MoeConfirm"; do
  [ -n "$c" ] && [ -x "$c" ] && { BIN="$c"; break; }   # BARE_CHECK
done

echo "moe-secret: the password window's contract"
if [ -z "$BIN" ]; then   # BARE_CHECK
  fail "no built MoeConfirm — run: swift build --product MoeConfirm"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
# The name Hermes is pointed at, in a directory with a space in it, as the
# app's own is ("Memoe Dev.app").
mkdir -p "$S/Memoe Dev.app/Contents/MacOS"
LINK="$S/Memoe Dev.app/Contents/MacOS/moe-secret"
ln -s "$BIN" "$LINK"   # BARE_CHECK: a link, not a launch

LOGIN='{"kind":"login","origin":"https://www.fazier.com/login","label":"Fazier","username":"izzy.private@example.com","fields":["username","password"]}'

# 1. By name, no --secret.
out="$(printf '%s' "$LOGIN" | secret --describe 2>"$S/err1")"; st=$?
[ "$st" -eq 3 ] && ok "reached as moe-secret, with no --secret (describe exits 3)" \
  || fail "moe-secret by name → exit $st, wanted 3" "$out $(cat "$S/err1")"
case "$out" in *"headline	Save your login for fazier.com"*) ok "the headline is the site, www. dropped" ;;
  *) fail "headline" "$out" ;; esac
grep -q "izzy.private" "$S/err1" && fail "the username reached stderr" "$(cat "$S/err1")" \
  || ok "stderr names the site and the fields, not the username"

# 2. A request it cannot read. (--describe as well, so that a request that
#    DID parse would print and exit rather than open a window.)
out="$(printf 'not json' | secret --describe 2>/dev/null)"; st=$?
[ "$st" -eq 1 ] && [ "$out" = '{"ok":false,"reason":"invalid"}' ] \
  && ok "unreadable request → {\"ok\":false,\"reason\":\"invalid\"}, exit 1" \
  || fail "unreadable request → exit $st" "$out"
out="$(printf '{"kind":"login","origin":"javascript:alert(1)"}' | secret --describe 2>/dev/null)"; st=$?
[ "$st" -eq 1 ] && [ "$out" = '{"ok":false,"reason":"invalid"}' ] \
  && ok "a login with no http(s) site is refused, not drawn" || fail "bad origin → exit $st" "$out"

# 3. Nobody answers.
out="$(printf '%s' "$LOGIN" | MOE_SECRET_TIMEOUT_FOR_TESTS=1 secret --wait-test 2>"$S/err3")"; st=$?
[ "$st" -eq 1 ] && [ "$out" = '{"ok":false,"reason":"timeout"}' ] \
  && ok "nobody answers → {\"ok\":false,\"reason\":\"timeout\"}, exit 1" \
  || fail "timeout → exit $st" "$out"
# The test seam only ever shortens: 99999 is still five minutes, so the
# process is still there after a second.
( printf '%s' "$LOGIN" | MOE_SECRET_TIMEOUT_FOR_TESTS=99999 secret --wait-test >"$S/out4" 2>/dev/null ) & W=$!; PIDS+=("$W")
sleep 1.5
W_PID="$(pgrep -f "$S/Memoe Dev.app/Contents/MacOS/moe-secret --wait-test" | head -1)"
[ -n "$W_PID" ] && ok "a longer test timeout is ignored — still waiting" || fail "the window left early"

# 4. SIGTERM is a cancel.
if [ -n "$W_PID" ]; then
  kill -TERM "$W_PID"; wait "$W"; st=$?
  [ "$st" -eq 1 ] && [ "$(cat "$S/out4")" = '{"ok":false,"reason":"cancelled"}' ] \
    && ok "SIGTERM → {\"ok\":false,\"reason\":\"cancelled\"}, exit 1" \
    || fail "SIGTERM → exit $st" "$(cat "$S/out4")"
fi

# 5. The caller goes away (the window is re-parented to launchd).
bash -c 'printf "%s" "$1" | MOE_SECRET_TIMEOUT_FOR_TESTS=20 "$2" --wait-test >"$3" 2>/dev/null &' _ \
  "$LOGIN" "$LINK" "$S/out5"   # CARD_CHECK: --wait-test, no window
for _ in $(seq 40); do [ -s "$S/out5" ] && break; sleep 0.1; done
[ "$(cat "$S/out5" 2>/dev/null)" = '{"ok":false,"reason":"cancelled"}' ] \
  && ok "the caller went away → cancelled, within seconds (not the 20 s clock)" \
  || fail "caller gone → '$(cat "$S/out5" 2>/dev/null)'"

# 6. One JSON object, newline-terminated, on stdout — nothing else there.
lines=$(printf '%s' "$LOGIN" | MOE_SECRET_TIMEOUT_FOR_TESTS=1 secret --wait-test 2>/dev/null | wc -l | tr -d ' ')
[ "$lines" = 1 ] && ok "stdout is exactly one line" || fail "stdout had $lines lines"

# 7. The send card is not the secret window.
printf 'channel=WhatsApp\0to=Dad\0body=hi\0' | "$BIN" --describe >"$S/card" 2>&1; st=$?   # CARD_CHECK: --describe
[ "$st" -eq 3 ] && grep -q "^to	Dad" "$S/card" && ok "moe-confirm without --secret is still the send card" \
  || fail "the send card changed (exit $st)" "$(cat "$S/card")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
