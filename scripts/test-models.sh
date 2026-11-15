#!/bin/bash
# NEEDS: dist-app
# TOUCHES THE REAL MAC: for the length of the run it moves the speech-model
# roots under this user's Application Support and ~/.cache/fluidaudio aside
# (and puts them back on exit, on Ctrl-C and on TERM). A Memoe running at the
# same time has its models taken away for those seconds, and a SIGKILL leaves
# them parked as <root>.moved-<stamp>. Do not run it while somebody is using
# Memoe on this Mac. It is release-critical in scripts/gate.sh all the same:
# it is the only check that a bundle really carries its models.
#
# Proves a downloaded Moe can hear and speak on a Mac that has never fetched a
# model — the thing the bundling exists for, and the one claim that cannot be
# checked by looking at file sizes.
#
# It moves this Mac's two FluidAudio caches aside, links the app's own copies
# into the empty roots, and loads every model with `ModelHub.offlineMode` on,
# so any attempted download is a typed error rather than a silent success.
# The caches are put back on the way out, whatever happens — including a
# Ctrl-C, which is what the trap is for.
#
#   1. the models are in the bundle
#   2. nothing personal rode along with them
#   3. an empty cache gets links, not copies
#   4. every model loads with the network refused
#   5. a real download already there is never touched
#   6. a link left over from an older app is repointed
#
# Only step 4 touches the real caches. 3, 5 and 6 run against scratch roots
# (`Moe --link-models <dir>`); 5 and 6 used to `rm -rf` inside the real,
# moved-aside root for no reason but that step 4 had already taken it.
#
#   MOE_TEST_MODELS_APP=<bundle>     check this bundle instead of dist/Memoe.app
#                                    (a Memoe Dev build, a slim build set aside)
#   MOE_TEST_MODELS_SKIP_REAL_CACHES=1
#                                    do not run step 4, so nothing outside the
#                                    scratch directory is touched. The suite
#                                    then says NOT RUN and exits 1: a release
#                                    cannot be gated on a run that skipped the
#                                    one check this file exists for.
#
# A slim bundle (MoeOnDemandComponents = on, docs/SLIM-DOWNLOAD.md) is checked
# as what it is: the listed set minus ON_DEMAND_MODELS, those folders absent,
# and step 4 loads what it carries (`--verify-models` says which it left out).
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
APPDIR="${MOE_TEST_MODELS_APP:-$ROOT/dist/Memoe.app}"
BIN="$APPDIR/Contents/MacOS/Moe"
MODELS="$APPDIR/Contents/Resources/Models"
SKIP_REAL="${MOE_TEST_MODELS_SKIP_REAL_CACHES:-0}"
APP_SUPPORT="$HOME/Library/Application Support/FluidAudio/Models"
CACHE="$HOME/.cache/fluidaudio/Models"
STAMP=$(date +%s)
SCRATCH="${MOE_TEST_SCRATCH:-$(mktemp -d)}"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; }

moved_app=0
moved_cache=0
# Restoring must be safe to run more than once, and it is run more than once:
# the INT handler calls it and then `exit`s, which fires the EXIT handler,
# which calls it again. An earlier version put `rm -rf "$APP_SUPPORT"` outside
# the "is there something to move back" guard, so the second call deleted the
# 461 MB cache the first call had just restored — in the suite whose header
# promises the caches come back "whatever happens, including a Ctrl-C".
#
# So: each root is claimed once, released once, and `restored` records that it
# is done. Nothing is removed unless there is a saved copy to put in its place,
# except the scratch links this suite made itself — and those only while the
# root is still ours.
restored=0
restore() {
  [ "$restored" = 1 ] && return 0
  restored=1
  if [ "$moved_app" = 1 ]; then
    if [ -d "$APP_SUPPORT.moved-$STAMP" ]; then
      rm -rf "$APP_SUPPORT"
      mv "$APP_SUPPORT.moved-$STAMP" "$APP_SUPPORT"
    elif [ -z "$(find "$APP_SUPPORT" -maxdepth 1 ! -type l ! -path "$APP_SUPPORT" 2>/dev/null)" ]; then
      # Nothing was moved aside, so this root did not exist before. It holds
      # only the links this suite made; taking it away leaves the Mac as it
      # was. Anything that is not a link is not ours and stays.
      rm -rf "$APP_SUPPORT"
    fi
  fi
  if [ "$moved_cache" = 1 ]; then
    if [ -d "$CACHE.moved-$STAMP" ]; then
      rm -rf "$CACHE"
      mv "$CACHE.moved-$STAMP" "$CACHE"
    elif [ -z "$(find "$CACHE" -maxdepth 1 ! -type l ! -path "$CACHE" 2>/dev/null)" ]; then
      rm -rf "$CACHE"
    fi
  fi
  rm -rf "$SCRATCH"
  return 0
}
# `trap restore INT` alone would restore and then *continue at the next
# statement* — which, if the interrupt landed in step 4, is step 5's `rm -rf`
# of a directory that is once again the developer's real one. Exit explicitly,
# and let the idempotence above absorb the second call that `exit` triggers.
trap restore EXIT
trap 'restore; exit 130' INT TERM

if [ ! -x "$BIN" ]; then
  echo "✗ no app at $APPDIR — run ./build.sh first" >&2; exit 1
fi
mkdir -p "$SCRATCH"
# Which of the three builds this is, from the key the app itself acts on.
OD_MODE="$(/usr/libexec/PlistBuddy -c 'Print :MoeOnDemandComponents' "$APPDIR/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$OD_MODE" ] || OD_MODE=off
ON_DEMAND="$(sed -n 's/^ON_DEMAND_MODELS="\(.*\)"$/\1/p' scripts/fetch-models.sh)"
LISTS="$ROOT/scripts/fetch-models.sh"
if [ "$OD_MODE" = on ]; then
  # The lists a slim bundle answers to: the same two lines, without the
  # on-demand names. Derived, so a model added to either list is still
  # required of a slim bundle the day it is added.
  [ -n "$ON_DEMAND" ] || { echo "✗ the bundle says on, but fetch-models.sh has no ON_DEMAND_MODELS line" >&2; exit 1; }
  LISTS="$SCRATCH/slim-lists.sh"
  ON_DEMAND="$ON_DEMAND" python3 - "$ROOT/scripts/fetch-models.sh" "$LISTS" <<'PY'
import os, re, sys
drop = set(os.environ["ON_DEMAND"].split())
out = []
for line in open(sys.argv[1]):
    m = re.match(r'^(APP_SUPPORT_MODELS|CACHE_MODELS)="(.*)"$', line.rstrip("\n"))
    if m:
        out.append('%s="%s"\n' % (m.group(1), " ".join(x for x in m.group(2).split() if x not in drop)))
open(sys.argv[2], "w").writelines(out)
PY
fi
echo "   ($APPDIR — on-demand mode: $OD_MODE)"

echo "1. the models are in the bundle"
if [ -d "$MODELS" ]; then
  ok "Contents/Resources/Models ($(du -sh "$MODELS" | cut -f1))"
  # Not a list repeated here. It used to be — six names, hardcoded, while
  # scripts/fetch-models.sh named eight — so this said "all six present"
  # over a bundle missing silero-vad and campplus and carrying 937 MB of
  # two engines deleted from the lists three days earlier. A check that
  # enumerates its own expectations agrees with itself and nothing else.
  if ./scripts/check-bundled-models.sh "$MODELS" "$LISTS" >/dev/null 2>&1; then
    [ "$OD_MODE" = on ] && ok "the bundled set is exactly the lists minus the on-demand models ($ON_DEMAND)" \
                        || ok "the bundled set is exactly what the lists name"
  else
    bad "the bundled set does not match scripts/fetch-models.sh ($OD_MODE):"
    ./scripts/check-bundled-models.sh "$MODELS" "$LISTS" 2>&1 | sed 's/^/      /'
  fi
  # The other direction, for the two modes that carry everything: a `prepare`
  # bundle missing an on-demand model has nothing to copy out, and says so
  # nowhere. (For `on`, their absence is what the check above just required.)
  if [ "$OD_MODE" != on ]; then
    for m in $ON_DEMAND; do
      [ -n "$(find "$MODELS/$m" -type f 2>/dev/null | head -1)" ] || bad "$OD_MODE, but $m is not in the bundle"
    done
  fi
  find "$MODELS" -type l 2>/dev/null | grep -q . \
    && bad "the bundled models contain symlinks — they would dangle on any other Mac" \
    || ok "they are real directories, not links"
else
  echo "  … this build has no bundled models (./scripts/fetch-models.sh, then ./build.sh)"
  echo; echo "$pass passed, $fail failed"; exit 0
fi

echo "2. nothing personal rode along"
# These weights are the same for everyone. Anything user-shaped in here would
# be shipped to every person who downloads Moe.
if find "$MODELS" -type f \( -name '*.json' -o -name '*.txt' -o -name '*.yaml' \) -print0 2>/dev/null \
   | xargs -0 grep -lIE '/Users/[a-z]|BEGIN [A-Z ]*PRIVATE KEY' 2>/dev/null | head -1 | grep -q .; then
  bad "a personal path or key is inside the model files:"
  find "$MODELS" -type f \( -name '*.json' -o -name '*.txt' -o -name '*.yaml' \) -print0 2>/dev/null \
    | xargs -0 grep -lIE '/Users/[a-z]' 2>/dev/null | sed 's/^/      /' | head -5
else
  ok "no home paths, addresses or keys in any model metadata"
fi

echo "3. an empty cache gets links, not copies"
# Counted from the bundle rather than written down: this said six for as
# long as six models shipped, and failed the day a seventh did — which is
# a test breaking on the change it exists to check.
WANT=$(ls "$MODELS" 2>/dev/null | wc -l | tr -d ' ')
SB="$SCRATCH/roots"
out="$("$BIN" --link-models "$SB" 2>&1)"
case "$out" in *"linked $WANT"*) ok "$WANT links made ($out)" ;; *) bad "unexpected: $out (wanted $WANT)" ;; esac
n=$(find "$SB" -type l | wc -l | tr -d ' ')
[ "$n" = "$WANT" ] && ok "all $WANT are symlinks — no gigabyte copied" || bad "$n symlinks, expected $WANT"
sz=$(du -sk "$SB" | cut -f1)
[ "$sz" -lt 200 ] && ok "the links weigh ${sz}K" || bad "the 'links' weigh ${sz}K"

echo "4. every model loads with the network refused"
# The real test. Both caches are moved aside so nothing already downloaded can
# answer, the bundle is linked into the empty roots, and downloads are refused.
# `moved` means "this root is ours for the duration", not "there was
# something here". On a Mac that has never downloaded a FluidAudio model —
# a fresh machine, or the stranger this suite exists to simulate — the old
# version set neither flag, created the roots anyway, linked six symlinks
# into the developer's *real* cache, and then bailed out at step 5 leaving
# them there, pointing into a build directory the next ./build.sh deletes.
# That is the dangling-link breakage this very commit fixed elsewhere.
# The flag goes up *before* the move, not after. An interrupt landing between
# a successful `mv` and the assignment would otherwise leave the developer's
# real cache parked under a .moved-<stamp> name with nothing that knows to put
# it back — not lost, but indistinguishable from lost at the moment it
# matters. restore() is written to cope with a flag set for a move that never
# happened; it cannot cope with a move that nothing recorded.
not_run=0
if [ "$SKIP_REAL" = 1 ]; then
  not_run=1
  echo "  NOT RUN — MOE_TEST_MODELS_SKIP_REAL_CACHES=1. Nothing outside $SCRATCH was touched,"
  echo "            and whether this bundle hears and speaks offline was not checked."
else
moved_app=1
if [ -d "$APP_SUPPORT" ]; then
  mv "$APP_SUPPORT" "$APP_SUPPORT.moved-$STAMP" || { echo "✗ could not move $APP_SUPPORT aside" >&2; exit 1; }
fi
moved_cache=1
if [ -d "$CACHE" ]; then
  mv "$CACHE" "$CACHE.moved-$STAMP" || { echo "✗ could not move $CACHE aside" >&2; exit 1; }
fi
mkdir -p "$APP_SUPPORT" "$CACHE"

link_out="$("$BIN" --link-models 2>&1)"
case "$link_out" in *"linked $WANT"*) ok "linked into the real, now-empty roots" ;; *) bad "link: $link_out" ;; esac

if verify="$("$BIN" --verify-models 2>&1)"; then
  ok "every bundled model loaded offline"
  if [ "$OD_MODE" = on ]; then
    printf '%s\n' "$verify" | grep -q "not checked: vocabulary boost, speaker diarization" \
      && ok "…and it said which two it did not check, being a slim build" \
      || bad "a slim build's offline check did not say what it left out"
  fi
else
  bad "offline load failed"
  printf '%s\n' "$verify" | grep -E '^(✗|…)' | sed 's/^/      /' | head -8
fi
fi

echo "5. a real download is never replaced by a link"
# In scratch roots of its own. This and step 6 used to run inside the real
# Application Support root while step 4 had it moved aside — an `rm -rf` of a
# model directory there, guarded by a flag. Neither step needs the real root:
# `--link-models <dir>` is the same code with the roots named.
R56="$SCRATCH/roots56"
mkdir -p "$R56/appsupport/parakeet-tdt-0.6b-v3"
printf 'not ours\n' > "$R56/appsupport/parakeet-tdt-0.6b-v3/marker"
out5="$("$BIN" --link-models "$R56" 2>&1)"
[ -f "$R56/appsupport/parakeet-tdt-0.6b-v3/marker" ] && [ ! -L "$R56/appsupport/parakeet-tdt-0.6b-v3" ] \
  && ok "the existing directory is left exactly as it was" \
  || bad "a real model directory was replaced: $out5"
case "$out5" in *"linked $((WANT - 1))"*) ok "…and the other $((WANT - 1)) were linked around it" ;; *) bad "unexpected: $out5" ;; esac

echo "6. a stale link is repointed"
rm -rf "$R56/appsupport/parakeet-tdt-0.6b-v3"
ln -s /nowhere/at/all "$R56/appsupport/parakeet-tdt-0.6b-v3"
"$BIN" --link-models "$R56" >/dev/null 2>&1
target=$(readlink "$R56/appsupport/parakeet-tdt-0.6b-v3" 2>/dev/null)
case "$target" in
  "$MODELS/parakeet-tdt-0.6b-v3") ok "a link to an app that moved is repaired" ;;
  *) bad "still points at: $target" ;;
esac

# 7. the guard that keeps section 1 honest
#
# Sections 1–6 all run against whatever this checkout staged. If the guard
# has stopped firing, every one of them still passes — which is exactly how
# 937 MB of de-listed models reached /Applications. So the guard is run here
# against directories built to fail it, and a guard that allows them is the
# failure. Reverting check-bundled-models.sh turns these three red.
echo
echo "7. the staged-set guard refuses what it must"
GUARD_DIR="$SCRATCH/guard"
lists=$(sed -n 's/^APP_SUPPORT_MODELS="\(.*\)"$/\1/p; s/^CACHE_MODELS="\(.*\)"$/\1/p' scripts/fetch-models.sh | tr ' ' '\n' | grep -v '^$')

mkdir -p "$GUARD_DIR/exact"
for m in $lists; do mkdir -p "$GUARD_DIR/exact/$m"; done
if ./scripts/check-bundled-models.sh "$GUARD_DIR/exact" >/dev/null 2>&1; then
  ok "an exact set passes"
else
  bad "the guard rejects a set that matches the lists — it would block every build"
fi

cp -R "$GUARD_DIR/exact" "$GUARD_DIR/extra"
mkdir -p "$GUARD_DIR/extra/supertonic-3"
out=$(./scripts/check-bundled-models.sh "$GUARD_DIR/extra" 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "supertonic-3"; then
  ok "a de-listed model is refused, and named"
else
  bad "a de-listed model passed the guard (exit $rc) — this is the 2026-09-06 bug"
fi

cp -R "$GUARD_DIR/exact" "$GUARD_DIR/short"
first=$(printf '%s\n' $lists | head -1)
rm -rf "$GUARD_DIR/short/$first"
out=$(./scripts/check-bundled-models.sh "$GUARD_DIR/short" 2>&1); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "$first"; then
  ok "a missing model is refused, and named"
else
  bad "a bundle missing $first passed the guard (exit $rc)"
fi

# And the case that matters most: a guard that cannot run must not pass.
out=$(./scripts/check-bundled-models.sh "$GUARD_DIR/exact" /dev/null 2>&1); rc=$?
if [ "$rc" = 2 ]; then
  ok "unreadable lists fail the check rather than passing it"
else
  bad "the guard reported success with no lists to check against (exit $rc)"
fi

echo
if [ "$not_run" = 1 ]; then
  echo "$pass passed, $fail failed, and step 4 did not run — this is not a pass"
  exit 1
fi
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
