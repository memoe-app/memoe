#!/bin/bash
# Is the bundled Hermes seed the size, and the shape, the download promises?
#
#   check-hermes-seed-size.sh <seed-dir>
#
# The seed is ~687 MB (316 MB code + sealed venv, 371 MB tool store; measured
# 2026-11-14 at fork 169f94d2d2, the v0.23.1 merge). It was ~646 MB at fork
# 8998ffbe2e (2026-10-07); the 41 MB since is honest: v0.23.1's pm calls pnpm
# required, so the store now carries it (46 MB), and the code grew. Two ways
# it has gone wrong, both caught here:
#   - too SMALL: a half-copied seed (the floor, MOE_MIN_HERMES_MB, default 550);
#   - too BIG: the slimming did not run, so Chrome for Testing (330 MB) or
#     build-time files rode along and the download grew by half a gigabyte
#     (the ceiling, MOE_MAX_HERMES_MB, default 720 — measured + ~5%; the
#     browser alone is 330 MB, so it still cannot ride along unseen).
# And by name, because a size can drift for an honest reason and a 330 MB
# browser cannot: no chromium-* in tools/, no tools/node-*/include, and the
# .browser-pending marker that tells the fork's browser tools to say "still
# downloading" until Memoe's installer has put the browser in.
set -u
SEED="${1:?usage: $0 <seed-dir>}"
MIN="${MOE_MIN_HERMES_MB:-550}"
MAX="${MOE_MAX_HERMES_MB:-720}"
bad=0
no() { echo "✗ $*" >&2; bad=1; }
mb=$(du -sm "$SEED" 2>/dev/null | cut -f1)
mb=${mb:-0}
[ "$mb" -ge "$MIN" ] || no "the Hermes seed is only ${mb} MB — expected ~687 MB (floor ${MIN}); a half-copied seed?"
[ "$mb" -le "$MAX" ] || no "the Hermes seed is ${mb} MB — over the ${MAX} MB ceiling (expected ~687). Did scripts/slim-hermes-tools.py run? $(du -sm "$SEED"/tools/* 2>/dev/null | sort -rn | head -3 | awk '{printf "%s %s MB; ", $2, $1}')"
if [ -d "$SEED/tools" ]; then
  for c in "$SEED"/tools/chromium-* "$SEED"/tools/chromium_*; do
    [ -e "$c" ] && no "the seed carries $(basename "$c") — the browser is fetched on first launch, not shipped (330 MB)"
  done
  for i in "$SEED"/tools/node-*/include; do
    [ -e "$i" ] && no "the seed carries $(basename "$(dirname "$i")")/include — build-time headers nothing reads at run time"
  done
  [ -f "$SEED/tools/.browser-pending" ] || no "the seed's tool store has no .browser-pending — its browser tools would vanish instead of saying the browser is on its way"
fi
[ "$bad" = 0 ] && echo "✓ the Hermes seed is ${mb} MB (${MIN}–${MAX}), without the browser or build-time files"
exit "$bad"
