#!/bin/bash
# Proves the move from ~/.moe to ~/Library/Application Support/Moe is safe.
#
# This is the only change in the product that picks up a directory holding a
# person's memories, meeting transcripts and ledger and puts it somewhere
# else. The happy path is the least interesting part of it; what matters is
# every case where it must refuse:
#
#   * both homes exist        → merging them automatically loses notes
#   * ~/.moe is already a link → it ran before; do not run again
#   * ~/.moe is someone's own link somewhere else → not ours to redirect
#   * the move fails          → say so, never claim success
#
# And the shim the whole thing rests on: ~/.moe stays a working symlink, so
# the ~317 payload scripts that still spell the old path keep writing to the
# same directory. Without that, half a user's data would land in a second
# home nobody knows about.
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SCRATCH="${MOE_TEST_SCRATCH:-$(mktemp -d)}"
trap 'rm -rf "$SCRATCH"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; }

# The two paths, as the Swift builds them. Named here so that a change to
# either side without the other shows up as a failure rather than as a Mac
# with two homes.
LEGACY=".moe"
TARGET="Library/Application Support/Moe"

echo "0. the two sides agree on where home is"
# Config.swift (the app) and Vocabulary.swift (MoeDictation) each build the
# path independently — the dictation module sits below the app and cannot see
# its constant. If they ever disagree, dictation writes its vocabulary into a
# different directory than everything else and nobody notices for weeks.
cfg=$(grep -c 'Library/Application Support/Moe' Sources/Moe/Config.swift 2>/dev/null)
voc=$(grep -c 'Library/Application Support/Moe' Sources/MoeDictation/Vocabulary.swift 2>/dev/null)
[ "${cfg:-0}" -ge 1 ] && [ "${voc:-0}" -ge 1 ] \
  && ok "Config.swift and Vocabulary.swift name the same home" \
  || bad "the two home definitions have drifted (Config $cfg, Vocabulary $voc)"

# No Swift outside the migration itself may still build a path from ".moe" —
# that is how one reader would keep pointing at the shim forever.
# The one legitimate use is Config.legacyHome, whose declaration is two lines
# above the path it builds — so the exclusion has to look at the declaration,
# not at the matching line.
stray=$(python3 - <<'PY'
import pathlib, re
hits = []
for f in [*pathlib.Path("Sources").rglob("*.swift"), *pathlib.Path("cloud").rglob("*.swift")]:
    lines = f.read_text().splitlines()
    for i, line in enumerate(lines):
        if 'appendingPathComponent(".moe"' not in line:
            continue
        # The declaration this expression belongs to, looking back a few lines.
        context = "\n".join(lines[max(0, i - 4):i + 1])
        if "legacyHome" in context:
            continue
        # Erase Moe from this Mac (D9.12) removes the ~/.moe link itself, so it
        # has to name it; it never reads or writes through it.
        if str(f) == "Sources/MoeErase/MacErase.swift" and "legacyLink" in context:
            continue
        hits.append("%s:%d:%s" % (f, i + 1, line.strip()))
for h in hits[:3]:
    print(h)
print("COUNT=%d" % len(hits))
PY
)
n=$(printf '%s' "$stray" | sed -n 's/^COUNT=//p')
[ "${n:-0}" -eq 0 ] \
  && ok "no Swift outside Config.legacyHome builds a path from .moe" \
  || { bad "$n place(s) still build ~/.moe directly"
       printf '%s\n' "$stray" | grep -v '^COUNT=' | sed 's/^/      /'; }

# A fake HOME per case. The binary is run with HOME set, and the migration
# reads FileManager.homeDirectoryForCurrentUser — which ignores $HOME for a
# non-sandboxed process. So these cases exercise the *shell* contract the
# payload depends on, and the Swift is covered by case 5 through MOE_HOME.
newhome() {
  H="$SCRATCH/$1"
  rm -rf "$H"
  mkdir -p "$H"
  echo "$H"
}

echo "1. the shim: both spellings are one directory"
H=$(newhome one)
mkdir -p "$H/$TARGET/memory"
ln -s "$H/$TARGET" "$H/$LEGACY"
printf 'a memory\n' > "$H/$LEGACY/memory/note.md"
if [ -f "$H/$TARGET/memory/note.md" ]; then
  ok "a write through ~/.moe lands in Application Support"
else
  bad "the link does not carry writes through"
fi
# The property the payload's 317 references actually depend on.
if [ "$(cat "$H/$TARGET/memory/note.md" 2>/dev/null)" = "a memory" ]; then
  ok "and the contents are the same file, not a copy"
else
  bad "the contents differ across the two paths"
fi

echo "2. a real directory at ~/.moe is never overwritten"
# The merge case. If both exist, one of them holds notes that would be lost,
# and no automatic rule can know which.
H=$(newhome two)
mkdir -p "$H/$LEGACY/memory" "$H/$TARGET/memory"
printf 'old\n' > "$H/$LEGACY/memory/a.md"
printf 'new\n' > "$H/$TARGET/memory/b.md"
before_old=$(cat "$H/$LEGACY/memory/a.md")
before_new=$(cat "$H/$TARGET/memory/b.md")
[ "$before_old" = "old" ] && [ "$before_new" = "new" ] \
  && ok "both homes still hold their own files (the case the code refuses)" \
  || bad "the fixture is wrong"

echo "2b. a stray ~/.moe that holds nothing of yours is folded, not refused"
# Measured 2026-09-07: a developer Mac's worktree-snapshot job wrote
# ~/.moe/bin and ~/.moe/logs within five minutes of a wipe, so the very first
# launch found "both exist", refused, and the payload then wrote a second
# home into the empty ~/.moe. Driven through `Moe --migrate-home`, because
# the real call reads homeDirectoryForCurrentUser and ignores $HOME.
#
# The DEBUG binary, never dist/Memoe.app: `--migrate-home` is compiled only
# into debug builds (main.swift, inside `#if DEBUG`). Handed the release
# bundle, the flag is unknown, the app starts instead, RunningFromHere puts a
# modal "This is a build of Moe from …" alert on whoever's screen this runs
# on, and the suite waits on it until test-all's 30-minute limit (2026-11-13,
# on ~/moe-release — the one checkout guaranteed to have a dist/ build).
MB="${MOE_DEBUG_BIN:-$ROOT/.build/debug/Moe}"
if [ ! -x "$MB" ]; then
  echo "  – skipped: no built Moe at $MB (swift build)"
else
  H=$(newhome twob)
  mkdir -p "$H/$LEGACY/bin" "$H/$LEGACY/logs" "$H/$LEGACY/context" "$H/$TARGET/memory" "$H/$TARGET/logs"
  printf 'guard\n' > "$H/$LEGACY/bin/moe-worktree-snapshot.sh"
  printf 'log\n' > "$H/$LEGACY/logs/snapshots.log"
  printf 'new\n' > "$H/$TARGET/memory/b.md"
  msg=$("$MB" --migrate-home "$H/$LEGACY" "$H/$TARGET" 2>&1)
  if [ -L "$H/$LEGACY" ] && [ "$(readlink "$H/$LEGACY")" = "$H/$TARGET" ]; then
    ok "~/.moe became the link (bin, logs and an empty context were nothing of yours)"
  else
    bad "~/.moe is still a real directory after a stray fold: $msg"
  fi
  [ -f "$H/$TARGET/bin/moe-worktree-snapshot.sh" ] && [ -f "$H/$TARGET/logs/snapshots.log" ] \
    && ok "what the guard had written travelled into the real home" \
    || bad "the stray files were lost: $(find "$H" -type f | sed "s|$H/||")"
  [ "$(cat "$H/$TARGET/memory/b.md" 2>/dev/null)" = "new" ] && ok "the real home's own files are untouched" || bad "the real home lost a file"
  case "$msg" in *"nothing of yours"*) ok "and the launch log says so";; *) bad "unexpected message: $msg";; esac

  # The refusal still stands for anything that could be a person's.
  H=$(newhome twoc)
  mkdir -p "$H/$LEGACY/memory" "$H/$TARGET/memory"
  printf 'old\n' > "$H/$LEGACY/memory/a.md"
  printf 'new\n' > "$H/$TARGET/memory/b.md"
  msg=$("$MB" --migrate-home "$H/$LEGACY" "$H/$TARGET" 2>&1)
  if [ ! -L "$H/$LEGACY" ] && [ -f "$H/$LEGACY/memory/a.md" ] && [ -f "$H/$TARGET/memory/b.md" ]; then
    ok "a ~/.moe with a memory in it is still refused, both homes intact"
  else
    bad "a home with a memory was folded or lost: $msg"
  fi
  case "$msg" in *"leaving them alone"*) ok "and the refusal is logged";; *) bad "unexpected message: $msg";; esac

  # A stray file among the stray dirs is a person's until proven otherwise.
  H=$(newhome twod)
  mkdir -p "$H/$LEGACY/logs" "$H/$TARGET"
  printf '{}\n' > "$H/$LEGACY/config.json"
  msg=$("$MB" --migrate-home "$H/$LEGACY" "$H/$TARGET" 2>&1)
  [ ! -L "$H/$LEGACY" ] && [ -f "$H/$LEGACY/config.json" ] \
    && ok "a config.json beside the stray dirs keeps the refusal" \
    || bad "a config.json was folded away: $msg"
fi

echo "3. the payload's scripts still find their home"
# The reason the shim exists at all. If this number ever reaches zero the
# shim can be retired; until then it must not be removed.
refs=$(grep -rn '\$HOME/\.moe\|~/\.moe' --include="*.sh" --include="*.py" \
        moe-home/ scripts/ 2>/dev/null | grep -v 'MOE_HOME' | wc -l | tr -d ' ')
if [ "${refs:-0}" -gt 0 ]; then
  ok "$refs payload references still spell ~/.moe — the shim is load-bearing"
else
  ok "no payload reference spells ~/.moe any more — the shim can be retired"
fi

echo "4. a home whose path contains a space really works"
# "Application Support" has a space in it, and an unquoted shell expansion of
# such a path splits into two arguments — producing a file with half a name
# rather than an error anyone would notice.
#
# This was a static check for unquoted `$MOE/…` first, and it was wrong twice:
# `CONN="${CONN:-$MOE/connectors}"` is quoted, and so is `"$(stat "$MOE/x")"`,
# whose inner quotes a line-by-line tracker cannot see through. Detecting this
# properly needs a shell parser, and a check that reports 25 false positives is
# a check people delete. So it does the real thing instead: lay the payload
# down into a path with a space and see whether it arrives.
# The built app first: it carries the payload, so the checks below can look at
# real files landing rather than only at a directory being made. `swift build`
# output is the fallback for a checkout that has not assembled a bundle yet.
MOE_BIN="${MOE_BIN:-}"
if [ -z "$MOE_BIN" ]; then
  if [ -x "$ROOT/dist/Memoe.app/Contents/MacOS/Moe" ]; then
    MOE_BIN="$ROOT/dist/Memoe.app/Contents/MacOS/Moe"
  else
    MOE_BIN="$ROOT/.build/debug/Moe"
  fi
fi
if [ ! -x "$MOE_BIN" ]; then
  echo "  – skipped: no built Moe at $MOE_BIN (swift build)"
else
  SPACED="$SCRATCH/Application Support/Moe"
  rm -rf "$SCRATCH/Application Support"
  out=$(MOE_HOME="$SPACED" "$MOE_BIN" --install-payload "$SPACED" 2>&1 | tail -1)
  if [ -d "$SPACED" ]; then
    ok "the home is created at a path with a space"
  else
    bad "no home at a spaced path: $out"
  fi
  # Nothing may have been created at the truncated path — that is exactly what
  # an unquoted expansion produces, and it is silent.
  if [ -e "$SCRATCH/Application" ]; then
    bad "a path split on the space: $SCRATCH/Application was created"
  else
    ok "nothing was created at the truncated path"
  fi
  # And the payload's own files, if this build carries one.
  case "$out" in
    *"no payload in this build"*)
      echo "  – note: this binary has no bundled payload, so only the directory was checked" ;;
    *)
      [ -x "$SPACED/sync.sh" ] \
        && ok "an executable payload script landed and kept its mode" \
        || bad "sync.sh did not arrive at the spaced path: $out" ;;
  esac
fi

echo "5. the real binary honours MOE_HOME, so nothing here touched your home"

if [ ! -x "$MOE_BIN" ]; then
  echo "  – skipped: no built Moe at $MOE_BIN (swift build)"
else
  H=$(newhome five)
  out=$(MOE_HOME="$H/scratch-home" "$MOE_BIN" --install-payload "$H/scratch-home" 2>&1 | tail -1)
  if [ -d "$H/scratch-home" ]; then
    ok "an explicit home is used as given: $out"
  else
    bad "the explicit home was not created: $out"
  fi
  # The migration must be inert under MOE_HOME, or a test run would pick up
  # the developer's own ~/.moe and move it.
  [ ! -e "$H/$TARGET" ] \
    && ok "and no Application Support home was invented beside it" \
    || bad "a scratch run created $TARGET"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
