#!/bin/bash
# NEEDS: dist-app
#
# Proves the app can populate ~/.moe on its own, from inside its own bundle,
# with no git checkout anywhere — which is the whole difference between what a
# stranger downloads and what a developer runs.
#
# It builds a staged app (no compiler), then compares the payload against the
# manifest in scripts/test-fresh-install.sh — the authoritative list of every
# file the app and the shell scripts read, and who reads each one. That test
# checks what scripts/install.sh puts in ~/.moe; this one checks that the
# bundle can put the same things there.
#
#   1. the payload is in the bundle       → staged by build.sh
#   2. it carries every required file     → against test-fresh-install.sh
#   3. it carries no user state           → no credentials, no memories
#   4. it carries no repo furniture       → no tests/, no .git, no docs
#   5. a fresh ~/.moe gets populated      → the copy, run for real
#   6. a second run changes nothing       → the stamp
#   7. user edits survive an update       → the never-overwrite rule
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SCRATCH="${MOE_TEST_SCRATCH:-$(mktemp -d)}"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; }

echo "1. build.sh stages the payload"
APP="$SCRATCH/Memoe.app"
MOE_BUILD_STAGE_ONLY="$APP" "$ROOT/build.sh" > "$SCRATCH/build.out" 2>&1
PAYLOAD="$APP/Contents/Resources/moe-home"
if [ -d "$PAYLOAD" ]; then
  n=$(find "$PAYLOAD" -type f | wc -l | tr -d ' ')
  ok "Contents/Resources/moe-home ($n files, $(du -sh "$PAYLOAD" | cut -f1))"
else
  bad "no payload in the bundle: $(tail -3 "$SCRATCH/build.out")"
  echo; echo "$pass passed, $fail failed"; exit 1
fi

echo "2. it carries every file the manifest requires"
python3 - "$PAYLOAD" <<'PY'
import re, sys
from pathlib import Path
payload = Path(sys.argv[1])
text = Path("scripts/test-fresh-install.sh").read_text()

# The two lists that test asserts on: `required=` (file|reader per line) and
# the connector manifests it checks separately.
names = []
m = re.search(r'^required="\n(.*?)^"', text, re.S | re.M)
if not m:
    print("  ✗ could not read required= from scripts/test-fresh-install.sh")
    sys.exit(1)
for line in m.group(1).splitlines():
    line = line.strip()
    if line and not line.startswith("#"):
        names.append(line.split("|", 1)[0])

missing = [n for n in names if not (payload / n).exists()]
if missing:
    print(f"  ✗ {len(missing)} of {len(names)} manifest files missing from the payload:")
    for n in missing:
        print("      -", n)
    sys.exit(1)
print(f"  ✓ all {len(names)} files the manifest names are in the bundle")
PY
[ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))

for m in calendar reminders notes imessage calls call-recordings chrome drive gmail telegram drive-docs whatsapp; do
  [ -f "$PAYLOAD/connectors/$m.manifest" ] || { bad "connectors/$m.manifest missing — that connector would not exist"; miss=1; }
done
[ "${miss:-0}" = 0 ] && ok "all 12 connector manifests present"

echo "3. no user state rides along"
# A payload is the same for everyone. Anything here that is specific to the
# machine that built it would be shipped to every person who downloads Moe.
leaked=0
for p in connectors/gmail-accounts.json connectors/telegram.json connectors/telegram.session \
         connectors/telegram-bot.json connectors/drive-docs-files.json config.json \
         contacts.json licence.txt google-client.json .env; do
  [ -e "$PAYLOAD/$p" ] && { bad "user state in the payload: $p"; leaked=1; }
done
for d in memory context ledger conversations meetings logs history venv whatsapp-mcp; do
  [ -e "$PAYLOAD/$d" ] && { bad "user state in the payload: $d/"; leaked=1; }
done
[ "$leaked" = 0 ] && ok "no credentials, memories, conversations or config"

echo "4. no repo furniture"
junk=0
find "$PAYLOAD" -type d -name tests | grep -q . && { bad "tests/ directories are in the payload"; junk=1; }
find "$PAYLOAD" -name '.git*' | grep -q . && { bad ".git files are in the payload"; junk=1; }
[ -e "$PAYLOAD/hermes-toolsets.md" ] && { bad "hermes-toolsets.md (a repo doc) is in the payload"; junk=1; }
[ "$junk" = 0 ] && ok "no tests, no .git, no repo docs"

echo "5. a fresh home gets populated — by the real binary"
# Not a Swift-shaped reimplementation in python: the actual shipped executable,
# through `Moe --install-payload <dir>`. The destination is an argument and not
# $HOME because FileManager.homeDirectoryForCurrentUser ignores the environment
# for a non-sandboxed process — a test that exported HOME would silently assert
# against the developer's own ~/.moe and pass for entirely the wrong reason.
# That is not hypothetical; it is what happened the first time this was tried.
HOME_DIR="$SCRATCH/moe-home"
BIN="$ROOT/dist/Memoe.app/Contents/MacOS/Moe"
if [ ! -x "$BIN" ]; then
  # No reimplementation-in-bash fallback. There used to be one, and it meant
  # this script could pass green having tested a copy of the logic rather than
  # the logic: a Payload.swift that copied nothing would still have ticked
  # every box below.
  bad "no dist/Memoe.app — run ./build.sh; this test needs the real binary"
  echo; echo "$pass passed, $fail failed"; exit 1
fi
out="$("$BIN" --install-payload "$HOME_DIR" 2>&1)"
case "$out" in
  *"installed ("*) ok "the binary installed it: $out" ;;
  *) bad "unexpected: $out" ;;
esac
out2="$("$BIN" --install-payload "$HOME_DIR" 2>&1)"
case "$out2" in
  *"already installed"*) ok "a second run does nothing: $out2" ;;
  *) bad "second run was not a no-op: $out2" ;;
esac
[ -x "$HOME_DIR/scripts/connect.sh" ] && ok "scripts/connect.sh is there and executable" || bad "connect.sh missing or not executable"
[ -x "$HOME_DIR/connectors/hermes-catalog.py" ] && ok "connectors/hermes-catalog.py is executable (ConnectionsModel gates the whole pane on this)" || bad "hermes-catalog.py not executable"
[ -x "$HOME_DIR/sync.sh" ] && ok "sync.sh is there and executable (Moe --sync hard-fails without it)" || bad "sync.sh missing or not executable"
[ -f "$HOME_DIR/hermes/configure-hermes.py" ] && ok "hermes/configure-hermes.py is there (the only way to pick a provider)" || bad "configure-hermes.py missing"
[ -f "$HOME_DIR/lib/connectors.sh" ] && ok "lib/connectors.sh is there (sync, doctor and learn hard-fail without it)" || bad "lib/connectors.sh missing"
[ -f "$HOME_DIR/tools/confirm.sh" ] && [ -d "$HOME_DIR/connectors" ] \
  && ok "tools/ is a sibling of connectors/ (gmail.py finds confirm.sh by its own realpath)" \
  || bad "tools/ and connectors/ are not siblings — the send gate would silently vanish"

echo "6. the payload matches what install.sh would have copied"
# Same source, two routes. Anything install.sh copies that the bundle does not
# carry is a file a downloaded Moe will never have.
# __pycache__ is excluded on both sides. It is generated by whoever last ran
# a script here, is not tracked in git, and each .pyc embeds the absolute path
# of the source it was compiled from — which is how Moe 0.3.5 shipped two of
# them naming the builder's home directory. build.sh and install.sh both prune
# them now, so enumerating them here would report a difference that is the fix
# working.
missing_vs_installer=0
while IFS= read -r f; do
  rel="${f#moe-home/}"
  case "$rel" in */tests/*|hermes-toolsets.md) continue ;; esac
  [ -f "$PAYLOAD/$rel" ] || { bad "install.sh copies $rel, the bundle does not"; missing_vs_installer=1; }
done < <(find moe-home -type f ! -path '*/tests/*' ! -name hermes-toolsets.md \
                       ! -path '*/__pycache__/*' ! -name '*.pyc')
[ "$missing_vs_installer" = 0 ] && ok "every moe-home file install.sh copies is in the bundle"

echo "7. a user edit survives an update, and a deleted file comes back"
# The binary is guaranteed by section 5, which exits if it is missing.
if true; then
  printf 'my own word\n' > "$HOME_DIR/vocabulary.txt"
  printf '{"model":"mine"}\n' > "$HOME_DIR/config.json"   # state, not payload
  rm -f "$HOME_DIR/scripts/connect.sh"                     # the repair case
  rm -f "$HOME_DIR/.payload"                               # force a re-run
  "$BIN" --install-payload "$HOME_DIR" >/dev/null 2>&1
  grep -q "my own word" "$HOME_DIR/vocabulary.txt" && ok "vocabulary.txt was not overwritten" || bad "the update clobbered the user's vocabulary"
  grep -q '"mine"' "$HOME_DIR/config.json" && ok "config.json was left alone" || bad "config.json was touched"
  [ -x "$HOME_DIR/scripts/connect.sh" ] && ok "a deleted script is put back" || bad "connect.sh was not restored"
else
  echo "  skipped (needs dist/Memoe.app)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
