#!/bin/bash
# End-to-end test of install-hermes.sh / uninstall-hermes.sh in a scratch
# directory. Nothing under ~ is touched: MOE_HOME, HERMES_HOME, the bin dir,
# uv's cache and python dir are all redirected, PATH is cut down to the
# system so the real uv/hermes are invisible, and `security` is the stub in
# scripts/test-stubs (configure-hermes.py --check honours MOE_SECURITY_BIN).
# Needs the network: it really downloads uv, Python 3.14, the fork and
# Hermes's pm tools (node, npm, uv, ffmpeg, ripgrep, the browser).
#
#   1. fresh install   → every step ✓ "installed/cloned/synced"; timed
#   2. second run      → every step ✓ "already"; nothing re-downloaded
#   3. dirty checkout  → ✗ and exit 1, tree untouched
#   4. uninstall       → checkout + wrapper gone; config.yaml/memories kept
#
# KEEP=1 keeps the scratch dir (and its uv cache) for a look afterwards.
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
# A fresh directory each run. The default used to be one particular agent
# session's scratchpad, complete with a username and a dead UUID — it
# worked, which is why nobody noticed it was in the repo.
SCRATCH="${MOE_TEST_SCRATCH:-$(mktemp -d)}/hermes-install-test"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
export MOE_HOME="$SCRATCH/moe-home"
export HERMES_HOME="$SCRATCH/hermes-home"
export MOE_BIN_DIR="$SCRATCH/bin"
export UV_PYTHON_INSTALL_DIR="$SCRATCH/uv-python"
# uv also links every Python it installs into its executable dir, which is the
# real ~/.local/bin unless told otherwise. Pinning only the install dir left a
# `python3.14` in the developer's ~/.local/bin pointing into this run's mktemp
# directory (found 2026-11-13: dangling the moment macOS cleans /var/folders).
export UV_PYTHON_BIN_DIR="$SCRATCH/uv-python-bin"
export UV_TOOL_BIN_DIR="$SCRATCH/uv-tool-bin"
export UV_CACHE_DIR="$SCRATCH/uv-cache"
export MOE_SECURITY_BIN="$ROOT/scripts/test-stubs/security"
export MOE_STUB_LOG="$SCRATCH/security-calls.log"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
LOG="$MOE_HOME/logs/install-hermes.log"
pass=0; failn=0
check() { # description, file, regex
  if grep -qE -- "$3" "$2"; then echo "  ok   $1"; pass=$((pass+1))
  else echo "  FAIL $1  (expected /$3/)"; failn=$((failn+1)); fi
}
nocheck() { if grep -qE -- "$3" "$2"; then echo "  FAIL $1  (found /$3/)"; failn=$((failn+1)); else echo "  ok   $1"; pass=$((pass+1)); fi; }

echo "1. fresh install into $SCRATCH"
t0=$(date +%s)
bash "$ROOT/scripts/install-hermes.sh" >"$SCRATCH/run1.out" 2>&1; rc=$?
t1=$(date +%s)
sed 's/^/     /' "$SCRATCH/run1.out"
echo "  exit $rc in $((t1-t0)) s"
[ $rc = 0 ] && { echo "  ok   exit 0"; pass=$((pass+1)); } || { echo "  FAIL exit $rc"; failn=$((failn+1)); }
check "uv downloaded + verified"   "$SCRATCH/run1.out" '^✓ uv 0\.[0-9.]+ installed .*sha256 verified'
nocheck "installer did not skip its tarball checksum" "$LOG" 'skipping sha256'
check "python 3.14 installed"      "$SCRATCH/run1.out" '^✓ Python installed: Python 3\.14'
check "fork cloned"                 "$SCRATCH/run1.out" '^✓ hermes-agent cloned: .*claude-code-runtime'
check "venv synced"                 "$SCRATCH/run1.out" '^✓ venv synced: [0-9]+ packages'
check "wrapper installed"           "$SCRATCH/run1.out" '^✓ hermes wrapper installed at '"$MOE_BIN_DIR"'/hermes'
check "hermes --version"            "$SCRATCH/run1.out" '^✓ hermes --version: Hermes Agent v'
check "hermes doctor"               "$SCRATCH/run1.out" '^✓ hermes doctor passed'
check "configure --check ran"       "$SCRATCH/run1.out" 'configure-hermes.py --check'
check "next step printed"           "$SCRATCH/run1.out" 'hermes-signin.sh'
nocheck "no ✗"                      "$SCRATCH/run1.out" '^✗'
check "wrapper runs the scratch venv python" "$MOE_BIN_DIR/hermes" "$HERMES_HOME/hermes-agent/.venv/bin/python"
# Since the 3.14 line the stamp, not the absence of one, decides who updates
# this tree: without `external` Hermes adopts it as self-updating and re-syncs
# its dependencies at launch.
check "install stamp says external" "$HERMES_HOME/hermes-agent/install-stamp.json" '"updateMechanism": "external"'
check "pm tool store filled"        "$SCRATCH/run1.out" "^✓ Hermes's tool store (filled|already has)"
# The browser-use launcher must run a venv inside the scratch home, never the
# person's own ~/.local/share/uv/tools venv (2026-09-25: this test and
# test-hermes-upgrade.sh re-created that venv on their throwaway Python).
if [ -f "$HERMES_HOME/bin/browser-use" ]; then
  # uv normalises the path (T//x → T/x) and, for a long one, writes a /bin/sh
  # trampoline ('''exec' '<python>') instead of a #! line: match the python
  # path under the scratch dir wherever the launcher names it.
  check "browser-use venv stays in the scratch home" "$HERMES_HOME/bin/browser-use" "/hermes-install-test/hermes-home/uv-tools/browser-use/bin/python"
else
  nocheck "browser-use never installed outside the scratch home" "$SCRATCH/run1.out" 'browser-use CLI installed'
fi
[ -f "$MOE_STUB_LOG" ] && { echo "  ok   security stub used, not /usr/bin/security"; pass=$((pass+1)); }
[ -z "$(git -C "$HERMES_HOME/hermes-agent" status --porcelain)" ] && { echo "  ok   checkout clean after sync"; pass=$((pass+1)); } || { echo "  FAIL checkout dirty after sync"; failn=$((failn+1)); }
# The pin is the whole point: an install must land on the commit the script
# names, not on whatever the branch tip is the day it runs.
pin=$(sed -n 's/^HERMES_COMMIT="${HERMES_COMMIT-\([0-9a-f]*\)}"$/\1/p' "$ROOT/scripts/install-hermes.sh")
head=$(git -C "$HERMES_HOME/hermes-agent" rev-parse HEAD)
if [ -n "$pin" ] && [ "$pin" = "$head" ]; then
  echo "  ok   installed the pinned commit ${pin:0:7}"; pass=$((pass+1))
elif [ -z "$pin" ]; then
  echo "  FAIL install-hermes.sh has no HERMES_COMMIT pin"; failn=$((failn+1))
else
  echo "  FAIL installed $head, pin says $pin"; failn=$((failn+1))
fi
echo "  size: $(du -sh "$HERMES_HOME/hermes-agent" | cut -f1) checkout+venv, $(du -sh "$UV_PYTHON_INSTALL_DIR" | cut -f1) python, $(du -sh "$UV_CACHE_DIR" | cut -f1) uv cache, $(du -sh "$MOE_BIN_DIR" | cut -f1) bin"

echo "2. second run (idempotent)"
t0=$(date +%s)
bash "$ROOT/scripts/install-hermes.sh" >"$SCRATCH/run2.out" 2>&1; rc=$?
t1=$(date +%s)
sed 's/^/     /' "$SCRATCH/run2.out"
echo "  exit $rc in $((t1-t0)) s"
[ $rc = 0 ] && { echo "  ok   exit 0"; pass=$((pass+1)); } || { echo "  FAIL exit $rc"; failn=$((failn+1)); }
check "uv already"       "$SCRATCH/run2.out" '^✓ uv already installed'
check "python already"   "$SCRATCH/run2.out" '^✓ Python already installed: Python 3\.14'
check "checkout already" "$SCRATCH/run2.out" '^✓ hermes-agent already at '
check "venv already"     "$SCRATCH/run2.out" '^✓ venv already in sync'
check "wrapper already"  "$SCRATCH/run2.out" '^✓ hermes wrapper already at'
check "tool store already" "$SCRATCH/run2.out" "^✓ Hermes's tool store already has"
nocheck "no ✗"           "$SCRATCH/run2.out" '^✗'
nocheck "nothing installed/cloned/synced again" "$SCRATCH/run2.out" '(installed to|cloned:|venv synced)'

echo "3. dirty checkout stops the script"
touch "$HERMES_HOME/hermes-agent/MOE-TEST-DIRTY"
bash "$ROOT/scripts/install-hermes.sh" >"$SCRATCH/run3.out" 2>&1; rc=$?
[ $rc != 0 ] && { echo "  ok   exit $rc"; pass=$((pass+1)); } || { echo "  FAIL exit 0"; failn=$((failn+1)); }
check "✗ names local changes" "$SCRATCH/run3.out" '^✗ hermes-agent: .*local changes'
[ -f "$HERMES_HOME/hermes-agent/MOE-TEST-DIRTY" ] && { echo "  ok   tree untouched"; pass=$((pass+1)); }
rm -f "$HERMES_HOME/hermes-agent/MOE-TEST-DIRTY"

echo "3b. ahead of the pin: moved back only when nothing would be lost"
AGENT="$HERMES_HOME/hermes-agent"
if [ -d "$AGENT/.git" ]; then
  pin=$(git -C "$AGENT" rev-parse HEAD)

  # (a) Ahead with a commit that is NOT on the remote. This is the case that
  # matters: the checkout on the machine where this was written was two
  # unpushed commits ahead, and an unconditional move back would have
  # orphaned them to the reflog during what looks like an install.
  git -C "$AGENT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "unpushed work"
  ahead=$(git -C "$AGENT" rev-parse HEAD)
  bash "$ROOT/scripts/install-hermes.sh" >"$SCRATCH/run3b.out" 2>&1; rc=$?
  now=$(git -C "$AGENT" rev-parse HEAD)
  if [ $rc -ne 0 ] && [ "$now" = "$ahead" ]; then
    echo "  ok   refuses, and the unpushed commit is still there"; pass=$((pass+1))
  else
    echo "  FAIL exit $rc, HEAD $now (was $ahead)"; failn=$((failn+1))
    tail -3 "$SCRATCH/run3b.out" | sed 's/^/       /'
  fi
  check "says they are not on the remote" "$SCRATCH/run3b.out" 'not on'

  # (b) Ahead of an OLDER pin, with everything on the remote. `hermes update`
  # and a downgraded Moe both land here, and this one must repair itself.
  git -C "$AGENT" reset -q --hard "$pin"
  older=$(git -C "$AGENT" rev-parse "HEAD~1" 2>/dev/null || echo "")
  if [ -n "$older" ]; then
    HERMES_COMMIT="$older" bash "$ROOT/scripts/install-hermes.sh" >"$SCRATCH/run3c.out" 2>&1; rc=$?
    now=$(git -C "$AGENT" rev-parse HEAD)
    if [ $rc -eq 0 ] && [ "$now" = "$older" ]; then
      echo "  ok   moved back to an older pin"; pass=$((pass+1))
    else
      echo "  FAIL exit $rc, HEAD ${now:0:7} (pin ${older:0:7})"; failn=$((failn+1))
      tail -3 "$SCRATCH/run3c.out" | sed 's/^/       /'
    fi
    check "says it was ahead" "$SCRATCH/run3c.out" 'moved back to the pinned'
    git -C "$AGENT" reset -q --hard "$pin"
  fi
else
  echo "  … no checkout to test with"
fi

echo "4. uninstall keeps config"
echo "model: {provider: claude-code-cli}" >"$HERMES_HOME/config.yaml"
mkdir -p "$HERMES_HOME/memories"; echo keep >"$HERMES_HOME/memories/MEMORY.md"
bash "$ROOT/scripts/uninstall-hermes.sh" >"$SCRATCH/run4.out" 2>&1; rc=$?
sed 's/^/     /' "$SCRATCH/run4.out"
[ $rc = 0 ] && { echo "  ok   exit 0"; pass=$((pass+1)); } || { echo "  FAIL exit $rc"; failn=$((failn+1)); }
[ ! -e "$HERMES_HOME/hermes-agent" ] && { echo "  ok   checkout removed"; pass=$((pass+1)); } || { echo "  FAIL checkout remains"; failn=$((failn+1)); }
[ ! -e "$MOE_BIN_DIR/hermes" ] && { echo "  ok   wrapper removed"; pass=$((pass+1)); } || { echo "  FAIL wrapper remains"; failn=$((failn+1)); }
[ -f "$HERMES_HOME/config.yaml" ] && [ -f "$HERMES_HOME/memories/MEMORY.md" ] && { echo "  ok   config.yaml + memories kept"; pass=$((pass+1)); } || { echo "  FAIL config/memories touched"; failn=$((failn+1)); }
[ -x "$MOE_BIN_DIR/uv" ] && { echo "  ok   uv kept"; pass=$((pass+1)); }
[ ! -e "$HERMES_HOME/tools" ] && { echo "  ok   Hermes's tool store removed"; pass=$((pass+1)); } || { echo "  FAIL $HERMES_HOME/tools remains"; failn=$((failn+1)); }

echo
echo "$pass passed, $failn failed   (log: $LOG)"
[ "${KEEP:-0}" = 1 ] || rm -rf "$SCRATCH"
[ $failn = 0 ]
