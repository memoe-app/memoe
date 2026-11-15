#!/bin/bash
# Tests the send-confirmation dialog: how tools/confirm.sh chooses between
# Moe's own dialog and the AppleScript one, what it hands over, and how
# Sources/MoeConfirm reads it.
#
# No window ever opens. `moe-confirm` is replaced by a stub that records the
# request it was given on stdin and answers with whatever exit status the test
# wants, and `osascript` is replaced by a stub first on PATH, so the fallback
# path can be exercised without a dialog appearing on somebody's screen.
#
# The one thing every check here is really about: only exit 0 out of a dialog
# is a send. "I could not ask" must never become "yes".
set -u

unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
S="$(mktemp -d "${TMPDIR:-/tmp}/moe-confirm-test.XXXXXX")"
trap 'rm -rf "$S"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2" | head -8; }

# A copy of the gate with a stub dialog beside it — which is exactly how it
# ships, `moe-confirm` next to `confirm.sh`, and the first place find_ui looks.
mkdir -p "$S/tools" "$S/bin"
cp "$REPO/moe-home/tools/confirm.sh" "$S/tools/confirm.sh"
CONFIRM="$S/tools/confirm.sh"
REQUEST="$S/request.bin"
ARGV="$S/argv.txt"

cat >"$S/tools/moe-confirm" <<'STUB'
#!/bin/bash
cat > "$REQUEST_OUT"
[ $# -gt 0 ] && printf '%s\n' "$@" > "$ARGV_OUT" || : > "$ARGV_OUT"
# Exit 5 is "Send, as rewritten", and what was rewritten rides on stdout as
# the request's own record format. $UI_EDIT is that stdout, verbatim.
[ -n "${UI_EDIT:-}" ] && printf '%b' "$UI_EDIT"
exit "${UI_STATUS:-0}"
STUB
chmod +x "$S/tools/moe-confirm"

# osascript, replaced. If the fallback ever runs, this records it and answers
# whatever $OSA_ANSWER says, instead of a dialog appearing on a real screen.
cat >"$S/bin/osascript" <<'STUB'
#!/bin/bash
cat >/dev/null
echo "ran" >> "$OSA_LOG"
# What the dialog would have shown: argv 4 is the text ("-" comes first).
[ -n "${OSA_TEXT:-}" ] && printf '%s' "$4" > "$OSA_TEXT"
printf '%s\n' "${OSA_ANSWER:-Cancel}"
STUB
chmod +x "$S/bin/osascript"

export REQUEST_OUT="$REQUEST" ARGV_OUT="$ARGV" OSA_LOG="$S/osa.log"
# confirm.sh no longer looks for a dialog beside itself: that directory is the
# toolbelt, which the model writes to daily, and a planted moe-confirm there
# approved every send for ever with no dialog at all. The stub is reached
# through a test seam that needs BOTH variables, the same two-key arrangement
# the hook uses for $MOE_CONFIRM_BIN and for the same reason.
export MOE_HOOK_TEST=1 MOE_CONFIRM_UI_FOR_TESTS="$S/tools/moe-confirm"
# osascript is absolute in confirm.sh now — a dialog off $PATH is a dialog
# somebody else wrote — so the fallback is stubbed through the same
# temp-dir-only seam as the main one rather than by shadowing a binary.
export MOE_OSASCRIPT_FOR_TESTS="$S/bin/osascript"
export PATH="$S/bin:$PATH"

echo "confirm.sh → moe-confirm"

# 1. Approved.
: >"$OSA_LOG"
UI_STATUS=0 "$CONFIRM" "Gmail" "dad@example.com" "Running late" "gmail_send" "gmail" >/dev/null 2>&1
[ $? -eq 0 ] && ok "the dialog said Send → exit 0" || fail "approved send did not exit 0"
[ ! -s "$OSA_LOG" ] && ok "  …and no AppleScript dialog was shown" || fail "  …AppleScript ran anyway"

# 2. What it was handed. NUL-separated records on stdin, nothing on argv:
#    argv is world-readable through `ps`, and this is a private message.
records() { tr '\0' '\n' < "$REQUEST" | grep -c .; }
tr '\0' '\n' < "$REQUEST" | grep -qx "to=dad@example.com" && ok "  …recipient sent as a record" \
  || fail "  …recipient record missing" "$(tr '\0' '\n' < "$REQUEST")"
tr '\0' '\n' < "$REQUEST" | grep -qx "body=Running late" && ok "  …body sent as a record" \
  || fail "  …body record missing"
tr '\0' '\n' < "$REQUEST" | grep -qx "tool=gmail_send" && ok "  …tool id passed through" \
  || fail "  …tool id missing"
tr '\0' '\n' < "$REQUEST" | grep -qx "service=gmail" && ok "  …service hint passed through" \
  || fail "  …service hint missing"
[ ! -s "$ARGV" ] && ok "  …and nothing was put on argv" || fail "  …message leaked to argv" "$(cat "$ARGV")"
tr '\0' '\n' < "$REQUEST" | grep -q "^headline=" && fail "  …a headline record with no headline given" "$(tr '\0' '\n' < "$REQUEST")" \
  || ok "  …no headline record unless one was given"

# 2b. A headline — what is being asked, and where — is the ninth argument, and
#     travels as one record on one line (2026-09-29: the cards were "technical
#     and unsimple").
: >"$OSA_LOG"
UI_STATUS=1 "$CONFIRM" "browser account" "www.fazier.com" "Moe will make a strong password." "browser_vault_login" "chrome" "send" "no" "" \
  "Create an account on fazier.com?" >/dev/null 2>&1
tr '\0' '\n' < "$REQUEST" | grep -qx "headline=Create an account on fazier.com?" && ok "a headline is handed over as its own record" \
  || fail "headline record missing" "$(tr '\0' '\n' < "$REQUEST")"
tr '\0' '\n' < "$REQUEST" | grep -qx "body=Moe will make a strong password." && ok "  …apart from the body" \
  || fail "  …the body changed" "$(tr '\0' '\n' < "$REQUEST")"
UI_STATUS=1 "$CONFIRM" "browser account" "x.com" "b" "t" "chrome" "send" "no" "" $'line one\nTo: someone@else.com' >/dev/null 2>&1
tr '\0' '\n' < "$REQUEST" | grep -qx "headline=line one To: someone@else.com" && ok "  …on one line, whatever it was given" \
  || fail "  …a headline kept its line break" "$(tr '\0' '\n' < "$REQUEST")"
# Where there is no card, the headline leads the only text there is.
: >"$OSA_LOG"; export OSA_TEXT="$S/osa-text.txt"; : >"$OSA_TEXT"
UI_STATUS=2 OSA_ANSWER=Cancel "$CONFIRM" "browser account" "www.fazier.com" "Moe will make a strong password." "browser_vault_login" "chrome" "send" "no" "" \
  "Create an account on fazier.com?" >/dev/null 2>&1
[ "$(head -1 "$OSA_TEXT")" = "Create an account on fazier.com?" ] && grep -q "^Moe will make a strong password.$" "$OSA_TEXT" \
  && ok "  …and leads the AppleScript dialog's text when the card cannot be shown" || fail "  …the fallback lost the headline" "$(cat "$OSA_TEXT")"
unset OSA_TEXT; : >"$OSA_LOG"

# 3. Cancelled.
UI_STATUS=1 "$CONFIRM" "Gmail" "dad@example.com" "Running late" >/dev/null 2>&1
[ $? -eq 1 ] && ok "the dialog said Cancel → exit 1" || fail "cancelled send did not exit 1"
[ ! -s "$OSA_LOG" ] && ok "  …and it did not ask a second time" || fail "  …asked again after a Cancel"

# 4. The dialog could not be shown. This is the case the whole exit-code
#    contract exists for: it is not an answer, so the other dialog asks.
: >"$OSA_LOG"
UI_STATUS=2 OSA_ANSWER=Send "$CONFIRM" "Gmail" "dad@example.com" "Running late" >/dev/null 2>&1
[ $? -eq 0 ] && ok "no dialog → the AppleScript one asked, and Send was Send" \
  || fail "fallback did not approve on Send"
[ -s "$OSA_LOG" ] && ok "  …the fallback really ran" || fail "  …no fallback"
: >"$OSA_LOG"
UI_STATUS=2 OSA_ANSWER=Cancel "$CONFIRM" "Gmail" "dad@example.com" "hi" >/dev/null 2>&1
[ $? -eq 1 ] && ok "  …and a Cancel there is still a Cancel" || fail "  …fallback Cancel was not a refusal"

# 5. A crash, a signal, a stray non-zero — never an approval.
LEAKED=""
for status in 3 7 127; do
  UI_STATUS=$status OSA_ANSWER=Cancel "$CONFIRM" "Gmail" "d@e.com" "hi" >/dev/null 2>&1
  [ $? -ne 0 ] || LEAKED="$LEAKED $status"
done
# Counted, not announced: this used to print "ok" outside the loop whatever
# the loop had found.
[ -z "$LEAKED" ] && ok "an unexpected dialog exit is never an approval" \
  || fail "these dialog exits were read as approval:$LEAKED"

# 6. The message is not cut short for Moe's dialog — it scrolls. The 1,800
#    character limit belongs to `display dialog`, which cannot.
LONG="$(python3 -c 'print("x" * 5000)')"
UI_STATUS=0 "$CONFIRM" "Gmail" "d@e.com" "$LONG" >/dev/null 2>&1
SENT="$(tr '\0' '\n' < "$REQUEST" | grep '^body=' | wc -c | tr -d ' ')"
[ "$SENT" -gt 4000 ] && ok "a 5,000-character message reached the dialog whole" \
  || fail "the message was truncated on the way in ($SENT bytes)"

# 7. A recipient list too long to show is refused rather than shortened.
MANY="$(python3 -c 'print(",".join(["someone@example.com"] * 60))')"
UI_STATUS=0 "$CONFIRM" "Gmail" "$MANY" "hi" >/dev/null 2>&1
[ $? -ne 0 ] && ok "a recipient list too long to show is refused" \
  || fail "a list nobody could read was approved"

# 7b. Send, as rewritten. The dialog exits 5 with the new words on stdout;
#     confirm.sh passes exactly those records through and exits 5 itself, so
#     a caller that reads 5 sends what the person typed. A caller that
#     predates 5 reads it as "not 0" and sends nothing — the safe way round.
: >"$OSA_LOG"
UI_STATUS=5 UI_EDIT='body=Running 15 minutes late\0' "$CONFIRM" "Gmail" "dad@example.com" "Running late" >"$S/answer.bin" 2>/dev/null
RC=$?
ANSWER="$(tr '\0' '\n' < "$S/answer.bin")"
[ "$RC" -eq 5 ] && ok "the dialog said Send-as-edited → exit 5" || fail "an edited send did not exit 5 (rc=$RC)"
printf '%s\n' "$ANSWER" | grep -qx "body=Running 15 minutes late" && ok "  …and the rewritten body is on stdout" \
  || fail "  …the rewritten body did not come through" "$ANSWER"
[ ! -s "$OSA_LOG" ] && ok "  …with no second dialog" || fail "  …the fallback asked again after an edit"
tr '\0' '\n' < "$REQUEST" | grep -qx "edit=yes" && ok "  …the dialog was told edits are welcome" || fail "  …no edit record reached the dialog" "$(tr '\0' '\n' < "$REQUEST")"
# The subject too, and only the fields that changed.
ANSWER="$(UI_STATUS=5 UI_EDIT='subject=Late\0' "$CONFIRM" "Gmail" "dad@example.com" "Subject: Lte\n\nhi" 2>/dev/null | tr '\0' '\n')"
printf '%s\n' "$ANSWER" | grep -qx "subject=Late" && ! printf '%s\n' "$ANSWER" | grep -q "^body=" \
  && ok "a rewritten subject comes back alone" || fail "subject-only edit mangled" "$ANSWER"
# A 5 with nothing usable behind it is not an answer: the other dialog asks,
# with the ORIGINAL words, and its answer is the answer.
: >"$OSA_LOG"
UI_STATUS=5 UI_EDIT='' OSA_ANSWER=Cancel "$CONFIRM" "Gmail" "dad@example.com" "hi" >/dev/null 2>&1
[ $? -eq 1 ] && [ -s "$OSA_LOG" ] && ok "exit 5 with no records is not an answer — the fallback asked, and its Cancel held" \
  || fail "a bare exit 5 was read as an answer"
: >"$OSA_LOG"
UI_STATUS=5 UI_EDIT='body=x\xe2\x80\xaey\0' OSA_ANSWER=Cancel "$CONFIRM" "Gmail" "dad@example.com" "hi" >/dev/null 2>&1
[ $? -eq 1 ] && [ -s "$OSA_LOG" ] && ok "a rewritten body carrying a steering character is not an answer" \
  || fail "a steered edit was accepted"
: >"$OSA_LOG"
UI_STATUS=5 UI_EDIT='body=x\0' OSA_ANSWER=Cancel "$CONFIRM" "Gmail" "dad@example.com" "hi" "" "" "send" "no" >/dev/null 2>&1
[ $? -eq 1 ] && [ -s "$OSA_LOG" ] && ok "a caller that said edit=no never gets an edited send" \
  || fail "edit=no was not honoured"
tr '\0' '\n' < "$REQUEST" | grep -qx "edit=no" && ok "  …and the dialog was told so" || fail "  …edit=no did not reach the dialog"
: >"$OSA_LOG"
UI_STATUS=5 UI_EDIT='body=x\0' OSA_ANSWER=Cancel "$CONFIRM" "cloudflare" "zone 7" "x" "t" "" "act" >/dev/null 2>&1
[ $? -eq 1 ] && [ -s "$OSA_LOG" ] && ok "an act can never be 'edited' into running" \
  || fail "exit 5 on an act was read as an answer"
# A 5 that carries records never leaves them in the answer file behind it.
[ -z "$(ls "${TMPDIR:-/tmp}"/moe-confirm-answer.* 2>/dev/null)" ] && ok "  …and no answer file is left behind" \
  || fail "  …an answer file with a message in it was left in the temp dir"

# 8. There is no way to point the gate at a friendlier dialog.
# The property, not two magic names: every path confirm.sh will run the
# dialog from has to be a literal, not something an environment variable can
# point somewhere else.
CANDIDATES="$(sed -n '/for candidate in/,/^  do$/p' "$REPO/moe-home/tools/confirm.sh" \
  | grep -o '"[^"]*moe-confirm[^"]*"\|"[^"]*MoeConfirm[^"]*"')"
ROGUE="$(printf '%s\n' "$CANDIDATES" | grep -vE '^"(\$HERE|\$HOME|/Applications)' || true)"
[ -n "$CANDIDATES" ] && [ -z "$ROGUE" ] \
  && ok "every path the dialog is looked for on is fixed, not configurable" \
  || fail "a dialog path is not anchored to this script, \$HOME or /Applications" "$ROGUE"

echo
echo "moe-confirm"

# 9. Two kinds of question. A send (the default) is Send / Cancel and is never
#    remembered. An act — a tool that changes things, or one nobody has
#    vouched for — adds "Always allow", which is exit 4, and only for acts.
UI_STATUS=0 "$CONFIRM" "Gmail" "d@e.com" "hi" "gmail_send" "gmail" >/dev/null 2>&1
tr '\0' '\n' < "$REQUEST" | grep -qx "kind=send" && ok "no sixth argument → the dialog is told kind=send" \
  || fail "kind record missing or wrong" "$(tr '\0' '\n' < "$REQUEST")"
UI_STATUS=0 "$CONFIRM" "cloudflare" "zone 7" "Tool: zones_purge" "mcp__cloudflare__zones_purge" "cloudflare" "act" >/dev/null 2>&1
tr '\0' '\n' < "$REQUEST" | grep -qx "kind=act" && ok "sixth argument act → kind=act" \
  || fail "act kind not passed" "$(tr '\0' '\n' < "$REQUEST")"
UI_STATUS=0 "$CONFIRM" "x" "y" "z" "t" "s" "sideways" >/dev/null 2>&1
tr '\0' '\n' < "$REQUEST" | grep -qx "kind=send" && ok "an unknown kind is read as send (the stricter one)" \
  || fail "unknown kind not normalised" "$(tr '\0' '\n' < "$REQUEST")"
: >"$OSA_LOG"
UI_STATUS=4 "$CONFIRM" "cloudflare" "zone 7" "x" "mcp__cloudflare__zones_purge" "cloudflare" "act" >/dev/null 2>&1
[ $? -eq 4 ] && ok "Always allow on an act → exit 4, passed through for the hook to record" \
  || fail "exit 4 on an act was not passed through"
[ ! -s "$OSA_LOG" ] && ok "  …and no second dialog" || fail "  …fell back after a clear answer"
: >"$OSA_LOG"
UI_STATUS=4 OSA_ANSWER=Cancel "$CONFIRM" "Gmail" "d@e.com" "hi" "gmail_send" "gmail" >/dev/null 2>&1
STATUS=$?
[ "$STATUS" -ne 4 ] && [ "$STATUS" -ne 0 ] && ok "exit 4 from a SEND dialog is not an answer (got $STATUS, not approval)" \
  || fail "a send was allowed forever, or approved, on exit 4 ($STATUS)"
[ -s "$OSA_LOG" ] && ok "  …so the fallback asked instead" || fail "  …and nothing asked"

# 9b. A session: a browser or screen send whose yes covers the conversation.
#     The dialog is told kind=session, gets the code as its own record to
#     draw under the sentence, and may answer 6 — "Allow everything this
#     session" — which is passed through for the hook to record. A plain
#     send answering 6 is not an answer.
UI_STATUS=0 "$CONFIRM" "browser send" "x.com" "Moe is about to post a reply on x.com." "browser_exec" "twitter" "session" "no" "goto_url('https://x.com/a/status/1')
click('[data-testid=tweetButtonInline]')" >/dev/null 2>&1
tr '\0' '\n' < "$REQUEST" | grep -qx "kind=session" && ok "sixth argument session → kind=session, passed through whole" \
  || fail "session kind was coerced" "$(tr '\0' '\n' < "$REQUEST")"
tr '\0' '\n' < "$REQUEST" | grep -q "^detail=goto_url" && tr '\0' '\n' < "$REQUEST" | grep -q "^click('\[data-testid=tweetButtonInline\]')" \
  && ok "  …and the code travels as its own detail record, newlines kept" || fail "detail record missing" "$(tr '\0' '\n' < "$REQUEST")"
tr '\0' '\n' < "$REQUEST" | grep "^body=" | grep -q "tweetButton" && fail "  …the code leaked into the body" || ok "  …not inside the message"
: >"$OSA_LOG"
UI_STATUS=6 "$CONFIRM" "browser send" "x.com" "Moe is about to post." "browser_exec" "twitter" "session" >/dev/null 2>&1
[ $? -eq 6 ] && ok "Allow everything on a session → exit 6, passed through for the hook to record" \
  || fail "exit 6 on a session was not passed through"
[ ! -s "$OSA_LOG" ] && ok "  …and no second dialog" || fail "  …fell back after a clear answer"
: >"$OSA_LOG"
UI_STATUS=6 OSA_ANSWER=Cancel "$CONFIRM" "Gmail" "d@e.com" "hi" "gmail_send" "gmail" >/dev/null 2>&1
STATUS=$?
[ "$STATUS" -ne 6 ] && [ "$STATUS" -ne 0 ] && ok "exit 6 from a SEND dialog is not an answer (got $STATUS)" \
  || fail "a send was session-allowed, or approved, on exit 6 ($STATUS)"
[ -s "$OSA_LOG" ] && ok "  …so the fallback asked instead" || fail "  …and nothing asked"
: >"$OSA_LOG"
UI_STATUS=2 OSA_ANSWER="Do it" "$CONFIRM" "cloudflare" "zone 7" "x" "t" "cloudflare" "act" >/dev/null 2>&1
[ $? -eq 0 ] && ok "fallback for an act: Do it → approved once" || fail "fallback act approval failed"
: >"$OSA_LOG"
UI_STATUS=2 OSA_ANSWER="Cancel" "$CONFIRM" "cloudflare" "zone 7" "x" "t" "cloudflare" "act" >/dev/null 2>&1
[ $? -eq 1 ] && ok "  …and Cancel is Cancel" || fail "fallback act cancel was not a refusal"
sed -n "/<<'AS'/,/^AS\$/p" "$CONFIRM" | grep -q 'buttons {"Cancel", yesButton}' \
  && ! sed -n "/<<'AS'/,/^AS\$/p" "$CONFIRM" | grep -qi 'always' \
  && ok "  …the fallback has no Always allow: nothing is remembered from a dialog one pkill away" \
  || fail "the AppleScript fallback grew an Always button"

# The dialog binary itself, through --describe: what it parsed, printed, with
# nothing shown and nothing approved.
UI="$REPO/.build/release/MoeConfirm"
[ -x "$UI" ] || UI="$REPO/dist/Memoe.app/Contents/MacOS/moe-confirm"
[ -x "$UI" ] || UI="$REPO/.build/debug/MoeConfirm"
if [ ! -x "$UI" ]; then
  echo "  --   not built (swift build -c release --product MoeConfirm) — skipping"
else
  describe() { printf 'channel=%s\0to=%s\0body=%s\0tool=%s\0' "$1" "$2" "$3" "${4:-}" | "$UI" --describe; }
  describe_kind() { printf 'channel=%s\0to=%s\0body=%s\0tool=%s\0kind=%s\0' "$1" "$2" "$3" "$4" "$5" | "$UI" --describe; }
  OUT="$(describe_kind "cloudflare" "zone 7" "x" "mcp__cloudflare__zones_purge" "act")"
  printf '%s\n' "$OUT" | grep -qx "kind	act" && printf '%s\n' "$OUT" | grep -qx "action	Do it" \
    && ok "kind=act parses, and the button says Do it" || fail "act kind not parsed" "$OUT"
  OUT="$(describe_kind "gmail" "d@e.com" "hi" "gmail_send" "act-ish")"
  printf '%s\n' "$OUT" | grep -qx "kind	send" && printf '%s\n' "$OUT" | grep -qx "action	Send" \
    && ok "an unknown kind is send, and the button says Send" || fail "unknown kind not normalised in the dialog" "$OUT"
  OUT="$(describe "gmail" "d@e.com" "hi" "gmail_send")"
  printf '%s\n' "$OUT" | grep -qx "kind	send" && ok "no kind record → send" || fail "default kind wrong" "$OUT"
  OUT="$(printf 'channel=browser send\0to=x.com\0body=Moe is about to post a reply on x.com.\0tool=browser_exec\0service=twitter\0kind=session\0edit=no\0detail=click(1)\nclick(2)\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -qx "kind	session" && printf '%s\n' "$OUT" | grep -qx "action	Send" \
    && ok "kind=session parses, and a browser send's button says Send" || fail "session kind not parsed" "$OUT"
  printf '%s\n' "$OUT" | grep -qxF "detail	click(1)\nclick(2)" && ok "  …the detail is parsed apart from the body" || fail "detail not parsed" "$OUT"
  printf '%s\n' "$OUT" | grep -qx "editable	false" && ok "  …and a session is never editable" || fail "a session is editable" "$OUT"
  printf '%s\n' "$OUT" | grep -qx "service	X" && ok "  …headed with X's name, from the hint" || fail "x.com not headed X" "$OUT"
  OUT="$(printf 'channel=browser pay\0to=shop.example.com\0body=Moe is about to pay.\0tool=browser_exec\0service=chrome\0kind=session\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -qx "action	Do it" && ok "  …a payment's button says Do it, not Send" || fail "pay session button wrong" "$OUT"
  printf '%s\n' "$OUT" | grep -qx "service	Chrome" && printf '%s\n' "$OUT" | grep -qx "icon	chrome" \
    && ok "  …and an unbranded site is headed Chrome, with the browser's mark" || fail "chrome row missing" "$OUT"

  # The account card (ticket #17, 2026-09-29): its buttons say what they do.
  OUT="$(printf 'channel=browser account\0to=www.fazier.com\0body=Moe will make a strong password.\0tool=browser_vault_login\0service=chrome\0kind=send\0edit=no\0headline=Create an account on fazier.com?\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -qx "headline	Create an account on fazier.com?" && ok "the headline is parsed" || fail "headline not parsed" "$OUT"
  printf '%s\n' "$OUT" | grep -qx "action	Create account" && printf '%s\n' "$OUT" | grep -qx "cancel	Not now" \
    && ok "  …and a new account's buttons are Create account / Not now" || fail "account buttons wrong" "$OUT"
  printf '%s\n' "$OUT" | grep -qx "kind	send" && printf '%s\n' "$OUT" | grep -qx "editable	false" \
    && ok "  …still a plain send: no Always allow, nothing to edit" || fail "account card kind wrong" "$OUT"
  OUT="$(printf 'channel=browser pay\0to=shop.example.com\0body=b\0kind=session\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -qx "cancel	Cancel" && ok "  …every other card keeps Cancel" || fail "cancel label wrong" "$OUT"
  OUT="$(printf 'channel=x\0to=y\0body=z\0headline=Delete\xe2\x80\xaemoc.x\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -qx "steered	true" && ok "  …a steering character in a headline is named, not obeyed" || fail "steered headline not caught" "$OUT"

  OUT="$(describe "mcp__moe__gmail_send" "jordy@example.com" "hello" "mcp__moe__gmail_send")"
  printf '%s' "$OUT" | grep -q "^service	Gmail$" && ok "a raw tool id is read as the service a person knows" \
    || fail "tool id not resolved to a service" "$OUT"

  printf 'channel=x\0to=y\0body=z\0' | "$UI" --describe >/dev/null 2>&1
  [ $? -eq 3 ] && ok "--describe exits 3 — never 0, which would be a send" \
    || fail "--describe did not exit 3"

  # Editable when — and only when — the message can be rewritten and sent as
  # rewritten: a send, a caller that can take it, and a body drawn as itself.
  OUT="$(describe "Gmail" "d@e.com" "hi" "gmail_send")"
  printf '%s\n' "$OUT" | grep -qx "editable	true" && ok "a plain send is editable" || fail "a plain send is not editable" "$OUT"
  OUT="$(describe_kind "cloudflare" "zone 7" "x" "t" "act")"
  printf '%s\n' "$OUT" | grep -qx "editable	false" && ok "an act is not" || fail "an act is editable" "$OUT"
  OUT="$(printf 'channel=Gmail\0to=d@e.com\0body=hi\0edit=no\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -qx "editable	false" && ok "edit=no is honoured by the dialog itself" || fail "edit=no ignored" "$OUT"
  OUT="$(printf 'channel=Gmail\0to=d@e.com\0body=hi\xe2\x80\xae\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -qx "editable	false" && ok "a body with a steering character in it is shown, not offered" || fail "a steered body is editable" "$OUT"
  OUT="$(printf 'channel=Gmail\0to=d@e.com\0body=From: me@x.com\nSubject: Hi\n\nhello\0tool=gmail_send\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -qx "subjecteditable	true" && ok "a mail's subject is editable" || fail "the subject is not editable" "$OUT"
  OUT="$(printf 'channel=Slack\0to=#x\0body=hello\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -qx "subjecteditable	false" && ok "  …and only a mail has one" || fail "a chat grew a subject" "$OUT"

  printf '' | "$UI" >/dev/null 2>&1
  [ $? -eq 2 ] && ok "nothing to confirm → exit 2, which asks the other dialog" \
    || fail "empty request did not exit 2"

  OUT="$(describe "Gmail" "d@e.com" "From: me@example.com
Subject: Late

Running late")"
  printf '%s' "$OUT" | grep -q "^header	Subject	Late$" && ok "connector headers become fields, not the first line of the mail" \
    || fail "headers not split out" "$OUT"
  printf '%s' "$OUT" | grep -q "^body	Running late$" && ok "  …and the message is what is left" \
    || fail "  …body wrong" "$OUT"

  # One tool addresses every platform, so the service arrives glued to the
  # recipient: "teams:#engineering". The heading takes the service, the To
  # line keeps the person — nothing is lost, and every cross-platform send
  # stops being headed "Send message" with no mark on it.
  platform() {
    printf 'channel=send_message\0to=%s\0body=hi\0tool=send_message\0service=%s\0' "$1" "$2" \
      | "$UI" --describe
  }
  OUT="$(platform "teams:#engineering" "teams")"
  printf '%s' "$OUT" | grep -q "^service	Teams$" && ok "a teams: target is headed Teams" \
    || fail "teams target not identified" "$OUT"
  printf '%s' "$OUT" | grep -q "^icon	teams$" && ok "  …with the Teams mark" || fail "  …no mark"
  printf '%s' "$OUT" | grep -q "^to	#engineering$" && ok "  …and the To line is the channel alone" \
    || fail "  …prefix not split off" "$OUT"
  OUT="$(platform "slack:#general" "slack")"
  printf '%s' "$OUT" | grep -q "^service	Slack$" && ok "  …and the same tool reads as Slack" \
    || fail "  …slack not identified"
  # An unknown platform is named, not guessed at, and keeps its own text.
  OUT="$(platform "acmechat:#ops" "acmechat")"
  printf '%s' "$OUT" | grep -q "^service	Acmechat$" && ok "  …an unknown platform is named plainly" \
    || fail "  …unknown platform mangled" "$OUT"

  # The MCP server segment names the service, ahead of any generic word in
  # the tool name: `mcp__twilio__messages_create` is Twilio's, not "Messages".
  server() { printf 'channel=%s\0to=x\0body=hi\0tool=%s\0' "$1" "$1" | "$UI" --describe; }
  printf '%s' "$(server mcp__twilio__messages_create)" | grep -q "^service	Twilio$" \
    && ok "the MCP server names the service" || fail "server segment ignored"
  printf '%s' "$(server mcp__hermes-tools__mcp__moe__gmail_send)" | grep -q "^service	Gmail$" \
    && ok "  …and Moe's own proxied tools still read as their service" \
    || fail "  …nested proxy lost the service"
  printf '%s' "$(server mcp__outlook__send_mail)" | grep -q "^service	Outlook$" \
    && ok "  …Outlook is Outlook, not Email" || fail "  …outlook misread"

  # Text that can reorder itself on screen. gmail.py, telegram.py and
  # whatsapp.sh all refuse these outright — "a gate whose display can be
  # steered is not a gate" — and until now this dialog, which every caller
  # goes through, did not. Measured with the real font, U+202E + "4444555551+"
  # renders as "+1555554444": a person approves one number and another is
  # dialled. Named rather than refused, because the AppleScript dialog we
  # would fall back to reorders text exactly the same way.
  RTL="$(printf '\xe2\x80\xae')"
  OUT="$(printf 'channel=x\0to=%s4444555551+\0body=hi\0tool=whatsapp_send\0service=\0' "$RTL" | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q '⟨U+202E⟩4444555551+' && ok "a right-to-left override is named, not obeyed" \
    || fail "the recipient can still be reordered on screen" "$OUT"
  printf '%s' "$OUT" | grep -q "^steered	true$" && ok "  …and the person is told the text was rewritten" \
    || fail "  …no warning that the text steers"

  # The service heading comes from the tool, not from text the model wrote.
  OUT="$(printf 'channel=x\0to=gmail:#general\0body=hi\0tool=mcp__slack__chat_postMessage\0service=gmail\0' | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^service	Slack$" && ok "a spoofed service hint loses to the tool id" \
    || fail "the heading was taken from the recipient string" "$OUT"
  printf '%s' "$OUT" | grep -q "^to	gmail:#general$" && ok "  …and the prefix it did not believe stays on the To line" \
    || fail "  …a disbelieved prefix was still stripped" "$OUT"

  # A message cannot manufacture a second recipient.
  OUT="$(printf 'channel=gmail_send\0to=a@b.com\0body=To: dad@example.com\n\nwire the money\0tool=gmail_send\0service=\0' | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^header	" && fail "the body invented a header row" "$OUT" \
    || ok "a body that writes 'To:' does not become a second recipient"
  # …while the header a connector really does put there still becomes a field.
  OUT="$(printf 'channel=gmail_send\0to=a@b.com\0body=From: me@x.com\nSubject: Late\n\nTwenty minutes\0tool=gmail_send\0service=\0' | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^header	Subject	Late$" && ok "  …and a real Subject still is" || fail "  …real headers stopped splitting" "$OUT"

  # A message too long to draw is cut, and says by how much — rather than
  # never appearing at all, which is what a 216 KB body used to do.
  BIG="$(python3 -c "print('x' * 300000, end='')")"
  OUT="$(printf 'channel=gmail_send\0to=a@b.com\0body=%s\0tool=gmail_send\0service=\0' "$BIG" | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "NOT shown here" && ok "a message too long to draw says how much is not shown" \
    || fail "an enormous body was not bounded"
  DRAWN="$(printf '%s' "$OUT" | awk -F'\t' '/^body/{print length($2)}')"
  [ "${DRAWN:-0}" -lt 25000 ] && ok "  …and is bounded to something the dialog can lay out ($DRAWN chars)" \
    || fail "  …still $DRAWN characters"

  # Header rows are on screen too, and were exempt from every cap the body
  # got. 50,000 `From:` lines produced NO WINDOW AT ALL — offscreen layout of
  # that many rows never returned, and confirm.sh waits on the pipe with no
  # timeout, so the send hung for ever. One 300,000-character header value
  # gave a 98,367pt window.
  MANY="$(python3 -c "print('From: a@b.c\n' * 200 + '\nPay.', end='')")"
  OUT="$(printf 'channel=gmail_send\0to=a@b.com\0body=%s\0tool=gmail_send\0service=\0' "$MANY" | "$UI" --describe)"
  COUNT="$(printf '%s' "$OUT" | awk -F'\t' '/^headercount/{print $2}')"
  [ "${COUNT:-99}" -le 8 ] && ok "a body of 200 header lines shows at most 8 ($COUNT)" \
    || fail "header rows are unbounded ($COUNT)"
  LONG="$(python3 -c "print('From: ' + 'A'*300000 + '\nSubject: s\n\nbody', end='')")"
  OUT="$(printf 'channel=gmail_send\0to=a@b.com\0body=%s\0tool=gmail_send\0service=\0' "$LONG" | "$UI" --describe)"
  WIDEST="$(printf '%s' "$OUT" | awk -F'\t' '/^header/{if (length($3) > m) m = length($3)} END {print m+0}')"
  [ "$WIDEST" -le 400 ] && ok "  …and no single header value is unbounded ($WIDEST chars)" \
    || fail "  …a header value of $WIDEST characters reaches the screen"

  # The heading is on screen at 24pt. A service of "Gmail\nTo: dad@example.com"
  # drew two lines four times the size of the real recipient, claiming a
  # different one — and `steered` did not notice, because it only looked at
  # the recipient and the body.
  OUT="$(printf 'channel=x\0to=attacker@evil.com\0body=hi\0tool=x\0service=%s\0' "$(printf 'Gmail\nTo: dad@example.com')" | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^steered	true$" && ok "a heading that carries its own recipient line is flagged" \
    || fail "the heading escapes the steering check" "$OUT"

  # Invisible padding. 850 braille blanks pushed the real number off the
  # bottom of the panel; Hangul filler has no width at all, so two addresses
  # drew as one. The hook's whitespace normaliser matches neither.
  PAD="$(python3 -c "print('Dad' + '\u2800'*40 + 'attacker@evil.com', end='')")"
  OUT="$(printf 'channel=x\0to=%s\0body=hi\0tool=x\0service=\0' "$PAD" | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "⟨U+2800⟩" && ok "a blank that draws nothing is named" \
    || fail "invisible padding survives into the recipient" "$OUT"

  # A right-to-left script reorders the line with no override character in it.
  OUT="$(printf 'channel=x\0to=%s\0body=hi\0tool=x\0service=\0' "$(printf 'שלום dad@example.com, attacker@evil.com')" | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^steered	true$" && ok "a right-to-left recipient says the order on screen is not the order sent" \
    || fail "RTL reordering is silent" "$OUT"

  # A lookalike address. dad@exаmple.com with a Cyrillic а differs from the
  # real one by about a thousand sub-pixels.
  OUT="$(printf 'channel=x\0to=%s\0body=hi\0tool=x\0service=\0' "$(python3 -c "print('dad@ex\u0430mple.com', end='')")" | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^confusable" && ok "a lookalike recipient is called out" \
    || fail "a homoglyph address passes unremarked" "$OUT"

  # The tool id outranks the hint even when the platform is in the NAME
  # rather than in an mcp__server__ segment — which is every Moe tool.
  OUT="$(printf 'channel=x\0to=slack:#general\0body=hi\0tool=mcp__moe__gmail_send\0service=slack\0' | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^service	Gmail$" && ok "a bare tool name still outranks a spoofed hint" \
    || fail "the hint beat the tool id" "$OUT"

  # The primary button's word is a closed set.
  OUT="$(printf 'channel=x\0to=a@b.com\0body=hi\0tool=x\0service=\0action=Cancel\0' | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^action	Send$" && ok "the send button cannot be labelled Cancel" \
    || fail "the sending button took an arbitrary label" "$OUT"

  # A FROM row is a mail thing. A Slack body beginning "From: ceo@company.com"
  # drew an authoritative sender row in the same style as the real fields,
  # and nothing had checked it.
  MAILISH="$(printf 'From: ceo@company.com\nSubject: Payroll\n\nwire the funds')"
  OUT="$(printf 'channel=send_message\0to=#eng\0body=%s\0tool=mcp__slack__chat_postMessage\0service=slack\0' "$MAILISH" | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^header	" && fail "a chat message grew a From row" "$OUT" \
    || ok "only a mail tool reads a header block out of a body"
  OUT="$(printf 'channel=gmail_send\0to=a@b.com\0body=%s\0tool=gmail_send\0service=\0' "$MAILISH" | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "^header	From	ceo@company.com$" && ok "  …and a mail tool still does" \
    || fail "  …mail headers stopped splitting" "$OUT"

  # The To line is one line. telegram.py builds its recipient from the
  # contact's own name off the wire, which it never runs through its own
  # control-character check.
  OUT="$(printf 'channel=telegram_send\0to=%s\0body=hi\0tool=telegram_send\0service=\0' "$(printf 'Dad\n\nTo: attacker')" | "$UI" --describe)"
  printf '%s' "$OUT" | grep -q "⟨U+000A⟩" && ok "a newline in the recipient is named, not drawn" \
    || fail "the To field can still grow a second line" "$OUT"

  # A quit is not a Send. NSApplication.terminate exits the process itself
  # with status 0 — and 0 is this program's word for "the human clicked
  # Send". Logging out, restarting, Activity Monitor's Quit, `osascript … to
  # quit`: every one of them reaches terminate:, and none of them is a person
  # clicking anything. --quit-test asks for exactly that termination; the only
  # honest answer is 2. (It puts a window up for 0.2s and takes it down
  # itself.)
  printf 'channel=Gmail\0to=d@e.com\0body=hi\0tool=t\0service=\0' | "$UI" --quit-test >/dev/null 2>&1
  [ $? -eq 2 ] && ok "a quit while the dialog is open is 'could not ask', never a send" \
    || fail "terminating the dialog was read as approval"

  OUT="$(describe "Slack" "#general" "Subject line: not a header

body")"
  printf '%s' "$OUT" | grep -q "^header	" && fail "prose that starts like a header was eaten" "$OUT" \
    || ok "prose that only looks like a header is left alone"

  # The dialog must not answer itself. This is a real bug that shipped for
  # ten minutes: a zero-size button holding the Return shortcut — there to
  # make Return mean Cancel, as the AppleScript dialog did — fired the moment
  # the window opened, but only in a *signed* build, so an unsigned dev build
  # looked perfect. The window is opened for real here and has to still be
  # waiting a couple of seconds later, with nobody having touched it.
  #
  # It puts a real window on somebody's screen for two seconds, and a window
  # that appears under a working person's pointer collects the click they
  # meant for something else — so it is off unless MOE_CONFIRM_UI_TEST=1 asks
  # for it. Run it after touching anything about how the dialog answers.
  if [ "${MOE_CONFIRM_UI_TEST:-0}" != "1" ]; then
    echo "  --   set MOE_CONFIRM_UI_TEST=1 for the self-answering check (it opens a window)"
  elif [ -x "$REPO/dist/Memoe.app/Contents/MacOS/moe-confirm" ]; then
    SIGNED="$REPO/dist/Memoe.app/Contents/MacOS/moe-confirm"
    ANSWER="$S/answered"
    ( printf 'channel=%s\0to=%s\0body=%s\0' "Gmail" "d@e.com" "hi" \
        | "$SIGNED" >/dev/null 2>&1; echo "$?" > "$ANSWER" ) &
    WAITER=$!
    sleep 2.5
    if [ -s "$ANSWER" ]; then
      fail "the signed dialog answered itself (exit $(cat "$ANSWER")) — nobody clicked anything"
    else
      ok "the signed dialog waits for a human instead of answering itself"
    fi
    # Job-control chatter about the killed dialog is not a test result.
    { kill "$WAITER"; pkill -f "$SIGNED"; wait "$WAITER"; } >/dev/null 2>&1
  else
    echo "  --   dist/Memoe.app not built — skipping the signed-dialog check"
  fi
fi

# ---------------------------------------------------------------------------
# The away machine: no dialog binary, no window server, and a phone instead
# (CLOUD-PLAN §6 slice 4).
#
# This whole section is about ONE claim: the new branch can only ever refuse
# what the old code already refused. Before it existed, a runtime with no
# moe-confirm and no /usr/bin/osascript reached `$OSA` as a missing file, got
# an empty RESULT, and exited 1 — every time, for every message. So the bar
# each check below has to clear is not "does it approve when it should"; it is
# "is there any arrangement of files and answers that approves when a person
# did not".
#
# It cannot be reached on a Mac, which is the whole problem with testing it:
# /usr/bin/osascript is on every Mac. The seam is the same two-key,
# temp-directory-only arrangement as the other two in this file, and it
# ROUTES rather than approves — forced on, it reaches confirm-away.py, which
# still refuses without a $MOE_ASK_DIR somebody minted and refuses again
# without the exact word in it.
echo
echo "confirm.sh → the phone, on a machine with no screen"

cp "$REPO/moe-home/tools/confirm-away.py" "$S/tools/confirm-away.py"
chmod +x "$S/tools/confirm-away.py"

# EVERY call below is bounded from here, including the ones that do not go
# through `away()`. confirm-away.py's own default is an hour, which is right
# for a person and wrong for a suite, and a check that reaches it does not
# fail — it stops.
#
# This is the sixth way a mutation round can look like success, and it was
# found twice in one afternoon rather than reasoned about. A mutant that
# removes a bound removes the SUITE's bound with it: the harness inherits its
# timeout from the code it is trying to break, which is an oracle derived
# from the thing it guards, in the time dimension. Both times the round was
# killed by hand after forty minutes, and the first time that left a live
# mutant in the gate on disk. scripts/mutate.py has no suite timeout of its
# own, so this export is the only bound there is.
export MOE_ASK_DEADLINE=8

# Everything below runs with the Mac's dialog stub explicitly OUT of the
# environment: `env -u`, not an unset, so a later check cannot silently
# inherit a half-cleared one.
# Everything below runs with the Mac's dialog stub explicitly OUT of the
# environment, and inside the deadline exported above.
# The per-call key the gateway's AwayGate mints and hands to this one child.
# A yes is only a yes when it carries an HMAC under it (S3, 2026-10-19): the
# ask directory is writable by the agent's shell, and the bare word used to be
# a send.
ASK_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
away() { # [extra env assignments...] -- args to confirm.sh
  env -u MOE_CONFIRM_UI_FOR_TESTS MOE_NOT_A_MAC_FOR_TESTS=1 MOE_ASK_KEY="$ASK_KEY" "$@"
}
# What the plugin writes for a yes: awaygate.sign_approval over the question
# that is on disk, under ASK_KEY.
signed_yes() { # <askdir> [key]
  python3 - "$REPO/moe-home/hermes-plugins/moe-connectors/awaygate.py" "$1" "${2:-$ASK_KEY}" <<'PYS'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("awaygate_t", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
raw = open(os.path.join(sys.argv[2], "ask.json"), "rb").read()
sys.stdout.write(m.sign_approval(sys.argv[3], os.path.basename(os.path.normpath(sys.argv[2])), raw))
PYS
}

ASKDIR="$S/ask"

# A person, on a phone. Waits for the question to appear and answers it with
# whatever word the caller passed — including words that are not answers.
answerer() { # <word> <after-seconds>
  ( for _ in $(seq 1 100); do
      [ -f "$ASKDIR/ask.json" ] && break
      sleep 0.1
    done
    [ -n "${2:-}" ] && sleep "$2"
    sleep 0.1   # the question is one write; let it land before signing it
    case "$1" in
      SIGNED*) printf '%s%s' "$(signed_yes "$ASKDIR" 2>/dev/null)" "${1#SIGNED}" > "$ASKDIR/answer" ;;
      WRONGKEY) printf '%s' "$(signed_yes "$ASKDIR" "$(printf '0%.0s' $(seq 1 64))")" > "$ASKDIR/answer" ;;
      *) printf '%s' "$1" > "$ASKDIR/answer" ;;
    esac ) &
}

# 1. The surface is missing. Half an image is the shape this gets wrong.
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
mv "$S/tools/confirm-away.py" "$S/tools/confirm-away.py.hidden"
OUT="$(away MOE_ASK_DIR="$ASKDIR" "$CONFIRM" "Gmail" "d@e.com" "hi" 2>&1)"; ST=$?
mv "$S/tools/confirm-away.py.hidden" "$S/tools/confirm-away.py"
[ "$ST" -eq 1 ] && ok "no confirm-away.py beside the gate → refused" \
  || fail "a missing away surface did not refuse" "exit $ST"
case "$OUT" in *confirm-away.py*) ok "  …and it names the file that is missing" ;;
  *) fail "  …the refusal did not say what was missing" "$OUT" ;; esac

# 2. Nowhere to ask. No caller minted a directory, so there is no question to
#    put and nothing may be sent. This is the state a stray call arrives in.
#
#    The exit code is the WEAKEST of the three things checked here, and on
#    its own it proves nothing: deleting this guard entirely leaves the exit
#    code at 1, because the poll below it then times out instead. A mutation
#    round found exactly that — the guard survived, killed by nothing, while
#    the suite stayed green. What the guard actually prevents is the two
#    checks after it.
rm -rf "$ASKDIR"
CWD="$S/stray"; rm -rf "$CWD"; mkdir -p "$CWD"
START=$(date +%s)
OUT="$(cd "$CWD" && away "$CONFIRM" "Gmail" "d@e.com" "a private message" 2>&1)"; ST=$?
ELAPSED=$(( $(date +%s) - START ))
[ "$ST" -eq 1 ] && ok "no \$MOE_ASK_DIR → refused" || fail "a send with nowhere to ask was not refused" "exit $ST"
case "$OUT" in *"nothing was sent"*) ok "  …and it says nothing was sent" ;;
  *) fail "  …no sentence about what happened" "$OUT" ;; esac
#    Without the guard, `os.path.join("", "ask.json")` is "ask.json" — so the
#    recipient and the message are written, in the clear, into whatever
#    directory the gateway happened to be in. That is the harm, and it is
#    invisible to an exit code.
if [ -z "$(find "$CWD" -type f 2>/dev/null)" ]; then
  ok "  …and it wrote the message NOWHERE — not into its working directory"
else
  fail "  …a private message was written outside the ask directory" "$(find "$CWD" -type f -exec sh -c 'echo "$1: $(cat "$1")"' _ {} \;)"
fi
#    And it refuses before it waits. A guard that costs the deadline is a
#    guard the next person removes for being slow.
[ "$ELAPSED" -lt 5 ] && ok "  …at once, without waiting out the deadline" \
  || fail "  …it waited ${ELAPSED}s for an answer to a question it never asked"

# 3. A person approves. The one path in this section that ends in a send.
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
answerer SIGNED
OUT="$(away MOE_ASK_DIR="$ASKDIR" MOE_ASK_DEADLINE=20 \
       "$CONFIRM" "Gmail" "dad@example.com" "Running late" "gmail_send" "gmail" 2>&1)"; ST=$?
wait 2>/dev/null
[ "$ST" -eq 0 ] && ok "the person said approved → exit 0" || fail "an approved send did not exit 0" "exit $ST: $OUT"
# What they were asked about. The recipient and the words, or the approval is
# about something else.
python3 - "$ASKDIR/ask.json" <<'PYQ' && ok "  …the question carried the exact recipient and the exact words" \
  || fail "  …the question did not carry what was being approved" "$(cat "$ASKDIR/ask.json" 2>/dev/null)"
import json, sys
q = json.load(open(sys.argv[1]))
sys.exit(0 if q.get("to") == "dad@example.com" and q.get("body") == "Running late"
         and q.get("channel") == "Gmail" and q.get("tool") == "gmail_send" else 1)
PYQ

# 4. A refusal.
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
answerer denied
away MOE_ASK_DIR="$ASKDIR" MOE_ASK_DEADLINE=20 "$CONFIRM" "Gmail" "d@e.com" "hi" >/dev/null 2>&1
[ $? -eq 1 ] && ok "the person said denied → exit 1" || fail "a denial was not a refusal"
wait 2>/dev/null

# 5. **An answer that is not the word is not consent.** Every one of these is
#    something a person, a half-written file, or a different program could
#    plausibly leave behind, and a gate that reads any of them as yes is not
#    a gate. Counted rather than announced — this shape used to print one ok
#    outside the loop whatever the loop found.
LEAKED=""
for word in yes y ok Send "approved!" " approved x" true 1 "" "APPROVED
denied"; do
  rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
  answerer "$word"
  away MOE_ASK_DIR="$ASKDIR" MOE_ASK_DEADLINE=8 "$CONFIRM" "Gmail" "d@e.com" "hi" >/dev/null 2>&1
  [ $? -ne 0 ] || LEAKED="$LEAKED [$word]"
  wait 2>/dev/null
done
[ -z "$LEAKED" ] && ok "no answer but the exact word 'approved' is a send" \
  || fail "these answers were read as consent:$LEAKED"

# 6. The one word, with the ordinary whitespace a file gets. This is the other
#    half of check 5 — a gate so strict it refuses its own answer is a gate
#    that never sends, and the suite would still be green.
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
answerer 'SIGNED
'
away MOE_ASK_DIR="$ASKDIR" MOE_ASK_DEADLINE=20 "$CONFIRM" "Gmail" "d@e.com" "hi" >/dev/null 2>&1
[ $? -eq 0 ] && ok "  …and a trailing newline on it is still that word" || fail "  …the real answer was refused"
wait 2>/dev/null

# 6b. **The word is not the gate's.** The ask directory sits in the profile
#     home, which the agent's own shell can write. A background loop echoing
#     `approved` into every answer file passed every send with nobody asked
#     (security review S3, 2026-10-19). Now only a yes signed under this
#     call's key is a yes — the bare word, and a signature under any other
#     key, are refusals that say so.
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
answerer approved
OUT="$(away MOE_ASK_DIR="$ASKDIR" MOE_ASK_DEADLINE=8 "$CONFIRM" "Gmail" "d@e.com" "hi" 2>&1)"; ST=$?
wait 2>/dev/null
[ "$ST" -ne 0 ] && ok "a bare 'approved' written by something other than the gate is refused" \
  || fail "a forged bare 'approved' was a send (S3)" "exit $ST: $OUT"
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
answerer WRONGKEY
away MOE_ASK_DIR="$ASKDIR" MOE_ASK_DEADLINE=8 "$CONFIRM" "Gmail" "d@e.com" "hi" >/dev/null 2>&1; ST=$?
wait 2>/dev/null
[ "$ST" -ne 0 ] && ok "  …and so is a yes signed under any other key" || fail "  …a yes under a guessed key was a send"
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
answerer SIGNED
env -u MOE_CONFIRM_UI_FOR_TESTS MOE_NOT_A_MAC_FOR_TESTS=1 MOE_ASK_DIR="$ASKDIR" MOE_ASK_DEADLINE=8 \
  "$CONFIRM" "Gmail" "d@e.com" "hi" >/dev/null 2>&1; ST=$?
wait 2>/dev/null
[ "$ST" -ne 0 ] && [ ! -f "$ASKDIR/ask.json" ] && ok "  …and with no key handed down nothing is asked or sent" \
  || fail "  …a child with no key asked, or sent"

# 7. An answer that was already there. A directory carrying a verdict before
#    the question was asked is the shape a replay takes, and refusing it costs
#    one stat.
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"; printf 'approved' > "$ASKDIR/answer"
away MOE_ASK_DIR="$ASKDIR" MOE_ASK_DEADLINE=8 "$CONFIRM" "Gmail" "d@e.com" "hi" >/dev/null 2>&1
[ $? -eq 1 ] && ok "an answer that predates the question is refused" \
  || fail "a pre-existing answer approved a send nobody was asked about"
[ ! -f "$ASKDIR/ask.json" ] && ok "  …and the question was never even written" \
  || fail "  …it asked anyway"

# 8. Nobody answers. The 2 a.m. case, and the one that has to end in silence.
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
START=$(date +%s)
away MOE_ASK_DIR="$ASKDIR" MOE_ASK_DEADLINE=3 "$CONFIRM" "Gmail" "d@e.com" "hi" >/dev/null 2>&1
[ $? -eq 1 ] && ok "nobody answered → nothing was sent" || fail "an unanswered send went out"
[ $(( $(date +%s) - START )) -ge 2 ] && ok "  …after waiting for them, not instantly" \
  || fail "  …it gave up without waiting"

# 9. And the branch stays shut on a Mac. With the seam disarmed, the dialog
#    path runs exactly as it did above and nothing is ever written to the ask
#    directory — this is the check that fails if somebody makes the away path
#    the default.
rm -rf "$ASKDIR"; mkdir -p "$ASKDIR"
UI_STATUS=0 MOE_ASK_DIR="$ASKDIR" "$CONFIRM" "Gmail" "d@e.com" "hi" >/dev/null 2>&1
[ $? -eq 0 ] && ok "on a Mac the dialog still answers" || fail "the Mac path broke"
[ ! -f "$ASKDIR/ask.json" ] && ok "  …and nothing was asked over a channel" \
  || fail "  …a Mac asked somebody's phone about a dialog it had already shown"

# The other direction, now that the icon column is gone: every mark that
# ships should be reachable by some key the dialog can resolve. A bundled
# file nothing points at is a mark that will never be drawn. `buzz` was one,
# for months, behind a table that mirrored the directory by hand and got it
# wrong in both directions.
MISSING="$(python3 "$HERE/lib/unnamed-marks.py" "$REPO" 2>/dev/null)"
[ -z "$MISSING" ] && ok "every messaging mark that ships can be named" \
  || fail "marks that ship but nothing can name: $MISSING"

# ── Who named the recipient (MOE_CONFIRM_PROVENANCE → a provenance record) ──
# Incident 2026-09-25: the dialog named a real chat and nothing on it said
# that nobody had asked for that person. recipients.py now says who named
# them, and confirm.sh must hand that to the dialog as data.
echo "provenance"
PROV='{"v": 1, "state": "found", "recipient": "Walter Brennan", "source": "your WhatsApp chats", "requested": "Jordan", "mismatch": true, "query": "grandpa", "query_unasked": true}'
MOE_CONFIRM_PROVENANCE="$PROV" UI_STATUS=0 "$CONFIRM" "WhatsApp" "Walter Brennan" "hi" >/dev/null 2>&1
tr '\0' '\n' < "$REQUEST" | grep -qxF "provenance=$PROV" && ok "the provenance reaches the dialog as its own record, verbatim" \
  || fail "no provenance record" "$(tr '\0' '\n' < "$REQUEST")"
MOE_CONFIRM_PROVENANCE="" UI_STATUS=0 "$CONFIRM" "WhatsApp" "Dan" "hi" >/dev/null 2>&1
tr '\0' '\n' < "$REQUEST" | grep -qx "provenance=" && ok "  …and an empty one when nobody said" || fail "  …empty provenance record missing"
MOE_CONFIRM_PROVENANCE="$(printf '{"state":"named"}\nto=evil@x.com')" UI_STATUS=0 "$CONFIRM" "WhatsApp" "Dan" "hi" >/dev/null 2>&1
! tr '\0' '\n' < "$REQUEST" | grep -q "evil@x.com" && ok "  …a provenance carrying a newline is dropped, never split into records" \
  || fail "  …a newline in the provenance forged a record" "$(tr '\0' '\n' < "$REQUEST")"
# The AppleScript fallback says it too — in words, since it cannot style it.
cat >"$S/bin/osascript-args" <<'STUB'
#!/bin/bash
cat >/dev/null
printf '%s\n' "$@" > "$OSA_ARGS"
printf 'Cancel\n'
STUB
chmod +x "$S/bin/osascript-args"
export OSA_ARGS="$S/osa-args.txt"
MOE_OSASCRIPT_FOR_TESTS="$S/bin/osascript-args" MOE_CONFIRM_PROVENANCE="$PROV" UI_STATUS=2 \
  "$CONFIRM" "WhatsApp" "Walter Brennan" "hi" >/dev/null 2>&1
grep -q "Moe chose this person — found in your WhatsApp chats" "$OSA_ARGS" && grep -q "You asked for .Jordan." "$OSA_ARGS" \
  && grep -q "Moe searched for .grandpa. on its own" "$OSA_ARGS" \
  && ok "the fallback dialog says Moe chose this person, and who was asked for" || fail "fallback provenance" "$(cat "$OSA_ARGS" 2>/dev/null)"
MOE_OSASCRIPT_FOR_TESTS="$S/bin/osascript-args" UI_STATUS=2 \
  MOE_CONFIRM_PROVENANCE='{"v": 1, "state": "named", "recipient": "Dan", "quote": "text Dan I am late"}' \
  "$CONFIRM" "WhatsApp" "Dan" "hi" >/dev/null 2>&1
grep -q "you named this person: .text Dan I am late." "$OSA_ARGS" && ok "  …and quotes the person when they named them" \
  || fail "  …named quote missing" "$(cat "$OSA_ARGS" 2>/dev/null)"
MOE_OSASCRIPT_FOR_TESTS="$S/bin/osascript-args" UI_STATUS=2 \
  MOE_CONFIRM_PROVENANCE='{"v": 1, "state": "partial", "recipient": "Walter Brennan", "said": "Walter"}' \
  "$CONFIRM" "WhatsApp" "Walter Brennan" "hi" >/dev/null 2>&1
grep -q "you said .Walter. — Moe picked Walter Brennan" "$OSA_ARGS" && ok "  …and says when Moe filled in the rest of a name" \
  || fail "  …partial line missing" "$(cat "$OSA_ARGS" 2>/dev/null)"
MOE_OSASCRIPT_FOR_TESTS="$S/bin/osascript-args" UI_STATUS=2 \
  MOE_CONFIRM_PROVENANCE='{"v": 1, "state": "shown", "recipient": "partnerships@compare.com", "source": "your screen", "said": "good"}' \
  "$CONFIRM" "Gmail" "partnerships@compare.com" "hi" >/dev/null 2>&1
grep -q "⚠️ Moe found this address on your screen and showed it to you — you said .good." "$OSA_ARGS" \
  && ok "  …and, in amber, where an address it showed was found and what the person said (ticket #22)" \
  || fail "  …shown line missing" "$(cat "$OSA_ARGS" 2>/dev/null)"
if [ -x "$UI" ]; then
  OUT="$(printf 'channel=Gmail\0to=partnerships@compare.com\0body=hi\0provenance={"state":"shown","source":"compare.com","said":"good"}\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -q "^provenance	warn	Moe found this address on compare.com and showed it to you — you said “good”." \
    && ok "  …an address Moe showed and the person said yes to is amber, and says both" || fail "  …shown provenance" "$OUT"
  OUT="$(printf 'channel=WhatsApp\0to=Walter Brennan\0body=hi\0tool=whatsapp_send\0provenance=%s\0' "$PROV" | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -q "^provenance	warn	Moe chose this person — found in your WhatsApp chats" \
    && printf '%s\n' "$OUT" | grep -q "^provenancewarning	You asked for “Jordan”" \
    && printf '%s\n' "$OUT" | grep -q "^provenancewarning	Moe searched for “grandpa” on its own" \
    && ok "moe-confirm parses it: amber 'found in your WhatsApp chats', the mismatch, Moe's own search" || fail "moe-confirm provenance" "$OUT"
  OUT="$(printf 'channel=WhatsApp\0to=Walter Brennan\0body=hi\0provenance={"state":"partial","said":"Walter","recipient":"Walter Brennan"}\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -q "^provenance	warn	You said “Walter” — Moe picked Walter Brennan" \
    && ok "  …a partial name is amber: 'You said Walter — Moe picked Walter Brennan'" || fail "  …partial provenance" "$OUT"
  OUT="$(printf 'channel=WhatsApp\0to=Dan Levi\0body=hi\0provenance={"state":"found","source":"your WhatsApp chats","query_unasked":true}\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -q "^provenancewarning	Moe picked them from a list it pulled up on its own" \
    && ok "  …a list pulled up with no search is Moe's choice, and says so" || fail "  …query-less lookup" "$OUT"
  OUT="$(printf 'channel=WhatsApp\0to=Walter\0body=hi\0provenance={"state":"legacy"}\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -q "^provenance	warn	This job was made before Moe checked recipients" \
    && ok "  …a job made before Moe checked recipients is amber, and says so" || fail "  …legacy provenance" "$OUT"
  OUT="$(printf 'channel=WhatsApp\0to=Dan\0body=hi\0provenance={"state":"unknown"}\0' | "$UI" --describe)"
  ! printf '%s\n' "$OUT" | grep -q "^provenance" && ok "  …and there is no amber 'could not check' state to show" || fail "  …unknown state shown" "$OUT"
  OUT="$(printf 'channel=WhatsApp\0to=Dan\0body=hi\0provenance={"state":"named","quote":"text Dan"}\0' | "$UI" --describe)"
  printf '%s\n' "$OUT" | grep -q "^provenance	plain	You named this person: “text Dan”" \
    && ok "  …and quiet 'You named this person' with the quote" || fail "  …named provenance" "$OUT"
  OUT="$(printf 'channel=WhatsApp\0to=Dan\0body=hi\0provenance=not json\0' | "$UI" --describe)"
  ! printf '%s\n' "$OUT" | grep -q "^provenance" && ok "  …and a record that does not parse says nothing" || fail "  …garbage provenance shown" "$OUT"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
