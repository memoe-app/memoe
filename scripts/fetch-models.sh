#!/bin/bash
# Stages the speech and voice models into Models/, so build.sh can put them
# inside the app and a stranger's first run needs no download at all.
#
#   ./scripts/fetch-models.sh          fetch what is missing, then stage
#   ./scripts/fetch-models.sh --check  say what is staged and what is not
#
# Models/ is gitignored: ~900 MB of Core ML weights do not belong in a git
# history, and they are reproducible from Hugging Face by this script.
#
# **Which files each model needs is not written down here.** The app itself
# warms every model through `Moe --fetch-models`, which runs the same load
# calls the product runs — so FluidAudio decides what to download, and this
# script only copies the result out of its caches. A hand-written file list
# would drift the first time a model gained a file, and the symptom would be
# an app that downloads "bundled" models anyway.
#
# The licences permit redistribution: Parakeet v3 and CTC-110M are CC-BY-4.0,
# the streaming EOU model is NVIDIA Open Model (redistribution allowed, §
# Redistribution), diarization is Apache-2.0, Kokoro is Apache-2.0. NOTICE
# carries the attributions. LICENSES.md §"Models" describes the obligations.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
DEST="$ROOT/Models"
APP_BIN="$ROOT/dist/Memoe.app/Contents/MacOS/Moe"

# The two cache roots FluidAudio uses, and which models land in each. Measured,
# not assumed: the recognisers go to Application Support and the voices to
# ~/.cache. Sources/Moe/Models.swift carries the same table and the comment
# explaining why getting it wrong is silent.
APP_SUPPORT="$HOME/Library/Application Support/FluidAudio/Models"
CACHE="$HOME/.cache/fluidaudio/Models"
APP_SUPPORT_MODELS="parakeet-eou-streaming parakeet-tdt-0.6b-v3 parakeet-ctc-110m-coreml speaker-diarization silero-vad campplus"
CACHE_MODELS="kokoro-82m-coreml kokoro"

# The models a slim build leaves out of the box and fetches the first time
# they are needed (docs/SLIM-DOWNLOAD.md). Still staged here, always: a full
# build carries them, and scripts/make-component-manifest.py reads their
# hashes from this staging to pin what a slim build will download. Every name
# must also be in one of the two lists above. build.sh only acts on this when
# MOE_ON_DEMAND_COMPONENTS=on; the default bundles everything, as before.
ON_DEMAND_MODELS="parakeet-ctc-110m-coreml speaker-diarization"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

report() {
  local total=0 missing=0
  for m in $APP_SUPPORT_MODELS $CACHE_MODELS; do
    if [ -d "$DEST/$m" ]; then
      printf '  ✓ %-26s %s\n' "$m" "$(du -sh "$DEST/$m" | cut -f1)"
      total=$((total+1))
    else
      printf '  ✗ %-26s not staged\n' "$m"
      missing=$((missing+1))
    fi
  done
  if [ -d "$DEST" ]; then
    echo "  ── $total staged, $missing missing, $(du -sh "$DEST" | cut -f1) total"
  fi
  return $missing
}

if [ "$CHECK" = 1 ]; then
  echo "Models/ (staged for the bundle):"
  report || true
  exit 0
fi

# 1. Warm them, which downloads whatever is not already cached. Skipped when
#    every cache directory is already there, so a re-run is seconds.
need_fetch=0
for m in $APP_SUPPORT_MODELS; do [ -d "$APP_SUPPORT/$m" ] || need_fetch=1; done
for m in $CACHE_MODELS;       do [ -d "$CACHE/$m" ]       || need_fetch=1; done

if [ "$need_fetch" = 1 ]; then
  if [ ! -x "$APP_BIN" ]; then
    echo "✗ need dist/Memoe.app to fetch the models — run ./build.sh first" >&2
    exit 1
  fi
  echo "› fetching what is missing (this is the ~800 MB, once)…"
  "$APP_BIN" --fetch-models || { echo "✗ could not fetch every model" >&2; exit 1; }
else
  echo "› every model is already in FluidAudio's caches"
fi

# 2. Copy them into Models/, laid out by name exactly as each cache has them.
#    Whole directories: FluidAudio decides what belongs in one, not this file.
# `cp -RL`, not `cp -R`, and the reason is a trap this walked into: once the
# app has run, Models.linkIfNeeded has replaced each cache directory with a
# **symlink into Memoe.app**. `-d` follows a symlink so the check passes, but
# BSD `cp -R` copies the link itself — so Models/ would fill up with links
# into dist/Memoe.app, build.sh would `rm -rf` that app, and the next release
# would ship a Models tree of dangling links. It would report a few kilobytes
# and say nothing, and the user would get the 806 MB first-run download the
# whole exercise exists to remove.
mkdir -p "$DEST"
stage() {
  local src="$1" name="$2"
  [ -d "$src" ] || { echo "✗ $src is missing after the fetch" >&2; exit 1; }
  rm -rf "$DEST/$name"
  cp -RL "$src" "$DEST/$name" || { echo "✗ could not copy $src" >&2; exit 1; }
  if find "$DEST/$name" -type l | grep -q .; then
    echo "✗ $DEST/$name still contains symlinks after cp -RL" >&2; exit 1
  fi
}
for m in $APP_SUPPORT_MODELS; do stage "$APP_SUPPORT/$m" "$m"; done
for m in $CACHE_MODELS;       do stage "$CACHE/$m" "$m"; done

# Weight the app does not use. FluidAudio's PocketTTS cache accumulates every
# model set that has ever been asked for, and `pocket_state.mlmodelc` (163 MB)
# belongs to the `.aneState` placement — which Moe deliberately does not ship
# (TtsTuning.pocketPreferred, and it never loaded on the machine that tried
# it). Staged unpruned it would be 163 MB of an app nobody ever reads.
#
# The cache keeps its copy, so asking for `.aneState` with `--tts-ladder`
# still works; this only trims what goes inside Memoe.app.
# A model dropped from the lists above stays in Models/ forever otherwise, and
# gets copied into the app by build.sh. That is not hypothetical: Supertonic
# was removed from `CACHE_MODELS` and `Models.bundled`, `--check` reported
# "7 staged, 0 missing", and the next build still shipped 161 MB of it —
# because nothing here was looking for models that should no longer be there.
# A check that reports only what it went looking for is the mistake this repo
# keeps making, so this one names what it took away.
want=" $APP_SUPPORT_MODELS $CACHE_MODELS "
for existing in "$DEST"/*; do
  [ -d "$existing" ] || continue
  name=$(basename "$existing")
  case "$want" in
    *" $name "*) ;;
    *)
      sz=$(du -sm "$existing" 2>/dev/null | cut -f1)
      rm -rf "$existing"
      echo "  removed $name (${sz}M) — no longer bundled"
      ;;
  esac
done

pruned=0
while IFS= read -r dead; do
  [ -n "$dead" ] || continue
  sz=$(du -sm "$dead" 2>/dev/null | cut -f1)
  rm -rf "$dead" && pruned=$((pruned + ${sz:-0}))
done <<EOF
$(find "$DEST" -type d -name "pocket_state.mlmodelc" 2>/dev/null)
EOF
[ "$pruned" -gt 0 ] && echo "  pruned ${pruned}M of models the app does not load"

echo "✓ staged into Models/"
report || true
echo
echo "  ./build.sh now puts these inside Memoe.app; without them the app still"
echo "  works and downloads them on first use."
