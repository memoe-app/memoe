#!/bin/bash
# The on-demand half of bundling the models (docs/SLIM-DOWNLOAD.md).
#
#   slim-bundled-models.sh <prepare|on> <staged Models dir> <bundle Models dir> [lists-file]
#
# build.sh calls this only when MOE_ON_DEMAND_COMPONENTS is not `off`; the
# default build never reaches it. A separate script, like
# check-bundled-models.sh, so scripts/test-slim.sh can run the real thing
# against scratch directories and watch it refuse.
#
# Both modes first require that the manifest compiled into the app
# (Sources/MoeComponents/ComponentManifest.swift) describes, byte for byte,
# the models staged in this checkout — so what a slim app downloads is what a
# full app carried and this build was tested with.
#
#   prepare  removes nothing. The app copies the on-demand models out of
#            itself at launch, checking them against that same manifest.
#   on       removes the folders named by ON_DEMAND_MODELS from the bundle.
#
# Exit 0 done; 1 refused, and the bundle is exactly as it was handed over;
# 2 the check itself could not run.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"

MODE=${1:-} STAGED=${2:-} BUNDLE=${3:-}
LISTS=${4:-"$HERE/fetch-models.sh"}

case "$MODE" in
  prepare|on) ;;
  *) echo "✗ slim-bundled-models: mode is '${MODE}' — prepare or on" >&2; exit 2 ;;
esac
for d in "$STAGED" "$BUNDLE"; do
  [ -n "$d" ] && [ -d "$d" ] || { echo "✗ slim-bundled-models: no such directory: ${d:-<none>}" >&2; exit 2; }
done
[ -f "$LISTS" ] || { echo "✗ slim-bundled-models: cannot read the model lists at $LISTS" >&2; exit 2; }

on_demand=$(sed -n 's/^ON_DEMAND_MODELS="\(.*\)"$/\1/p' "$LISTS")
if [ -z "$on_demand" ]; then
  echo "✗ slim-bundled-models: no ON_DEMAND_MODELS line in $LISTS." >&2
  echo "  Refusing rather than building a slim app that dropped nothing, or one" >&2
  echo "  that dropped something it has no way to fetch." >&2
  exit 2
fi

# Everything is checked before anything is removed: a refusal half-way would
# leave a bundle that is neither the full one nor the slim one.
for m in $on_demand; do
  # A name with a slash or a leading dot is not a model folder, and what
  # follows is an rm -rf.
  case "$m" in */*|.*) echo "✗ '$m' in ON_DEMAND_MODELS is not a folder name" >&2; exit 1 ;; esac
  if [ ! -d "$BUNDLE/$m" ]; then
    echo "✗ $m is on demand but is not in $BUNDLE — nothing to leave out," >&2
    echo "  and nothing its manifest could have been checked against." >&2
    exit 1
  fi
done

if ! python3 "$HERE/make-component-manifest.py" --models "$STAGED" --check; then
  exit 1
fi
# …and the bundle's copy is the staged copy. build.sh has just made it with
# cp -R, so this only ever fails when something came between the two.
for m in $on_demand; do
  if ! diff -rq "$STAGED/$m" "$BUNDLE/$m" >/dev/null 2>&1; then
    echo "✗ $BUNDLE/$m is not the staged $STAGED/$m" >&2
    exit 1
  fi
done

if [ "$MODE" = prepare ]; then
  echo "  slim:    prepare — every model bundled; the app keeps [$on_demand] outside itself for the slim build that follows"
  exit 0
fi

before=$(du -sm "$BUNDLE" | cut -f1)
for m in $on_demand; do
  rm -rf "${BUNDLE:?}/$m" || { echo "✗ could not remove $BUNDLE/$m" >&2; exit 1; }
done
after=$(du -sm "$BUNDLE" | cut -f1)
echo "  slim:    left out [$on_demand] — models ${before} MB → ${after} MB; each is fetched on first use"
exit 0
