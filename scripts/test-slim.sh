#!/bin/bash
# The slim download's build side, checked in what it PRODUCES
# (docs/SLIM-DOWNLOAD.md). The fetcher's own rules — a wrong hash refused, a
# cut download resumed — are Swift tests (Tests/MoeComponentsTests); this is
# the one flag, MOE_ON_DEMAND_COMPONENTS, and the script that acts on it.
#
#   1. the flag: stamped into the real Info.plist; with none set, a real
#      Memoe takes the mode scripts/on-demand-plan.txt gives its version and
#      Dev / community builds stay off; a value that is none of the three, a
#      plan that cannot be read, and a published build that is not the planned
#      mode are each refused
#   2. `on` leaves out exactly the listed folders and nothing else
#   3. `prepare` leaves out nothing
#   4. a staged model that is not the pinned one is refused, and the bundle
#      is left whole — the guard, watched refusing
#   5. the manifest in the source tree is the staged models, file for file
#
# Nothing here compiles, signs, downloads or touches /Applications or the
# model caches. 2–5 need real staged models (Models/ is gitignored); without
# them those checks are reported as NOT RUN and the suite fails, because a
# guard that did not run must not read as one that passed.
set -u
unset CDPATH
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
SCRATCH="${MOE_TEST_SCRATCH:-${TMPDIR:-/tmp}}/moe-slim-test.$$"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

pass=0; fail=0
ok()  { echo "  ok   $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
stage() { # <out> [env…]
  local out="$1"; shift
  ( cd "$REPO" && env -u MOE_ON_DEMAND_COMPONENTS "$@" MOE_BUILD_STAGE_ONLY="$out" ./build.sh ) > "$out.log" 2>&1
}

echo "1. one flag, and what a build gets when nobody sets it"
# The default is not a constant: a real Memoe takes the mode planned for the
# version build.sh carries (scripts/on-demand-plan.txt). So this compares the
# stamped plist with the plan — and then, because today's version may plan
# `off` and a comparison of off with off proves nothing, does it again under
# a plan of its own that says `prepare`.
VER="$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\([^<]*\)<.*/\1/p' build.sh | head -1)"
PLANNED="$(./scripts/on-demand-plan.sh mode "$VER" 2>/dev/null)"
case "$PLANNED" in off|prepare|on) ok "the plan answers for this checkout's version: $VER is $PLANNED" ;;
  *) bad "no plan for $VER: $(./scripts/on-demand-plan.sh mode "$VER" 2>&1)"; PLANNED=off ;; esac
stage "$SCRATCH/default"
[ "$(plist "$SCRATCH/default" MoeOnDemandComponents)" = "$PLANNED" ] \
  && ok "no flag → MoeOnDemandComponents is the plan's $PLANNED" \
  || bad "default: '$(plist "$SCRATCH/default" MoeOnDemandComponents)', plan $PLANNED ($(tail -1 "$SCRATCH/default.log"))"

printf '# a plan of this suite'"'"'s own\n0.0.1 prepare\n' > "$SCRATCH/plan-prepare"
stage "$SCRATCH/planned" MOE_ON_DEMAND_PLAN="$SCRATCH/plan-prepare"
[ "$(plist "$SCRATCH/planned" MoeOnDemandComponents)" = prepare ] \
  && ok "a plan that says prepare makes prepare the default, with no flag set" \
  || bad "planned prepare, stamped '$(plist "$SCRATCH/planned" MoeOnDemandComponents)' ($(tail -1 "$SCRATCH/planned.log"))"
stage "$SCRATCH/planned-dev" MOE_ON_DEMAND_PLAN="$SCRATCH/plan-prepare" MOE_DEV=1
[ "$(plist "$SCRATCH/planned-dev" MoeOnDemandComponents)" = off ] && [ "$(plist "$SCRATCH/planned-dev" MoeDev)" = 1 ] \
  && ok "Memoe Dev stays off under the same plan (it shares the real Memoe's model caches)" \
  || bad "Dev under a prepare plan: '$(plist "$SCRATCH/planned-dev" MoeOnDemandComponents)'"
stage "$SCRATCH/planned-oss" MOE_ON_DEMAND_PLAN="$SCRATCH/plan-prepare" MOE_EDITION=community
[ "$(plist "$SCRATCH/planned-oss" MoeOnDemandComponents)" = off ] \
  && ok "a community build stays off under the same plan" \
  || bad "community under a prepare plan: '$(plist "$SCRATCH/planned-oss" MoeOnDemandComponents)'"
stage "$SCRATCH/planned-off" MOE_ON_DEMAND_PLAN="$SCRATCH/plan-prepare" MOE_ON_DEMAND_COMPONENTS=off
[ "$(plist "$SCRATCH/planned-off" MoeOnDemandComponents)" = off ] \
  && ok "a local build can still say off under that plan" \
  || bad "explicit off under a prepare plan: '$(plist "$SCRATCH/planned-off" MoeOnDemandComponents)'"

# The decision this file exists to hold. Rows of history: they do not change
# when a later line is added to the plan.
[ "$(./scripts/on-demand-plan.sh mode 0.3.24 2>&1)" = off ] && ok "0.3.24 was off" || bad "0.3.24: $(./scripts/on-demand-plan.sh mode 0.3.24 2>&1)"
[ "$(./scripts/on-demand-plan.sh mode 0.3.25 2>&1)" = prepare ] && ok "0.3.25 is the prepare release" || bad "0.3.25: $(./scripts/on-demand-plan.sh mode 0.3.25 2>&1)"
./scripts/on-demand-plan.sh check >/dev/null 2>&1 && ok "the plan in the tree is well formed" || bad "the plan: $(./scripts/on-demand-plan.sh check 2>&1)"

# The plan's own rules, watched refusing.
printf '0.0.1 on\n' > "$SCRATCH/plan-skip"
out=$(MOE_ON_DEMAND_PLAN="$SCRATCH/plan-skip" ./scripts/on-demand-plan.sh mode 9.9.9 2>&1); rc=$?
[ $rc = 2 ] && echo "$out" | grep -q "prepare release has to go out first" \
  && ok "a plan that goes straight to on is refused: no answer, exit 2" || bad "on without prepare: rc=$rc $out"
printf '0.0.1 prepare\n0.0.2 on\n' > "$SCRATCH/plan-both"
[ "$(MOE_ON_DEMAND_PLAN="$SCRATCH/plan-both" ./scripts/on-demand-plan.sh mode 0.0.1)" = prepare ] \
  && [ "$(MOE_ON_DEMAND_PLAN="$SCRATCH/plan-both" ./scripts/on-demand-plan.sh mode 0.0.2)" = on ] \
  && [ "$(MOE_ON_DEMAND_PLAN="$SCRATCH/plan-both" ./scripts/on-demand-plan.sh mode 7.0.0)" = on ] \
  && ok "prepare then on: each release gets its own, and on stays on" || bad "a prepare→on plan did not answer in order"
printf '0.0.2 prepare\n0.0.1 off\n' > "$SCRATCH/plan-order"
MOE_ON_DEMAND_PLAN="$SCRATCH/plan-order" ./scripts/on-demand-plan.sh check >/dev/null 2>&1
[ $? = 2 ] && ok "versions out of order are refused" || bad "a plan out of order was accepted"
printf '0.0.1 perpare\n' > "$SCRATCH/plan-typo"
MOE_ON_DEMAND_PLAN="$SCRATCH/plan-typo" ./scripts/on-demand-plan.sh mode 1.0.0 >/dev/null 2>&1
[ $? = 2 ] && ok "a misspelt mode is refused, not read as off" || bad "a misspelt mode was accepted"
# …and build.sh does not build on a plan it cannot read. The side effect, not
# the exit status alone: no Info.plist was written.
if stage "$SCRATCH/typo" MOE_ON_DEMAND_PLAN="$SCRATCH/plan-typo"; then
  bad "build.sh staged a bundle under a plan with a misspelt mode"
else
  [ ! -e "$SCRATCH/typo/Contents/Info.plist" ] && grep -q "on-demand-plan" "$SCRATCH/typo.log" \
    && ok "build.sh refuses under an unreadable plan, and writes no Info.plist" \
    || bad "refused, but: plist $( [ -e "$SCRATCH/typo/Contents/Info.plist" ] && echo written || echo absent ), $(tail -1 "$SCRATCH/typo.log")"
fi

# The published build is the planned one or it is not built.
if stage "$SCRATCH/pub-wrong" MOE_ON_DEMAND_PLAN="$SCRATCH/plan-prepare" MOE_RELEASE_IS_PUBLISHED=1 MOE_ON_DEMAND_COMPONENTS=off; then
  bad "a published build was staged as off under a plan that says prepare"
else
  [ ! -e "$SCRATCH/pub-wrong/Contents/Info.plist" ] && grep -q "whose plan is 'prepare'" "$SCRATCH/pub-wrong.log" \
    && ok "a published build that is not the planned mode is refused before anything is written" \
    || bad "refused, but: plist $( [ -e "$SCRATCH/pub-wrong/Contents/Info.plist" ] && echo written || echo absent ), $(tail -1 "$SCRATCH/pub-wrong.log")"
fi
stage "$SCRATCH/pub-right" MOE_ON_DEMAND_PLAN="$SCRATCH/plan-prepare" MOE_RELEASE_IS_PUBLISHED=1
[ "$(plist "$SCRATCH/pub-right" MoeOnDemandComponents)" = prepare ] && [ "$(plist "$SCRATCH/pub-right" MoeReleaseBuild)" = 1 ] \
  && ok "the same published build with no flag is staged, as prepare" \
  || bad "published under a prepare plan: '$(plist "$SCRATCH/pub-right" MoeOnDemandComponents)' ($(tail -1 "$SCRATCH/pub-right.log"))"

for mode in off prepare on; do
  stage "$SCRATCH/$mode" MOE_ON_DEMAND_COMPONENTS=$mode
  [ "$(plist "$SCRATCH/$mode" MoeOnDemandComponents)" = "$mode" ] \
    && ok "MOE_ON_DEMAND_COMPONENTS=$mode is stamped as $mode" \
    || bad "$mode: '$(plist "$SCRATCH/$mode" MoeOnDemandComponents)' ($(tail -1 "$SCRATCH/$mode.log"))"
done
for wrong in 1 ON yes ""; do
  # "" is the one that must NOT be refused: an empty variable is unset.
  if stage "$SCRATCH/wrong" MOE_ON_DEMAND_COMPONENTS="$wrong"; then
    if [ -z "$wrong" ] && [ "$(plist "$SCRATCH/wrong" MoeOnDemandComponents)" = "$PLANNED" ]; then
      ok "an empty flag is no flag: the plan's $PLANNED"
    else
      bad "MOE_ON_DEMAND_COMPONENTS='$wrong' built (as '$(plist "$SCRATCH/wrong" MoeOnDemandComponents)')"
    fi
  else
    grep -q "off, prepare or on" "$SCRATCH/wrong.log" \
      && ok "MOE_ON_DEMAND_COMPONENTS='$wrong' is refused, by name" \
      || bad "'$wrong' failed for another reason: $(tail -1 "$SCRATCH/wrong.log")"
  fi
  rm -rf "$SCRATCH/wrong" "$SCRATCH/wrong.log"
done

# ---- real staged models, wherever this Mac has them --------------------------
ON_DEMAND=$(sed -n 's/^ON_DEMAND_MODELS="\(.*\)"$/\1/p' scripts/fetch-models.sh)
ALL=$(sed -n 's/^APP_SUPPORT_MODELS="\(.*\)"$/\1/p; s/^CACHE_MODELS="\(.*\)"$/\1/p' scripts/fetch-models.sh | tr '\n' ' ')
[ -n "$ON_DEMAND" ] && ok "fetch-models.sh names the on-demand models: $ON_DEMAND" || bad "no ON_DEMAND_MODELS line"
for m in $ON_DEMAND; do
  case " $ALL " in *" $m "*) ok "$m is also a staged model" ;; *) bad "$m is on demand but is in neither staging list" ;; esac
done

SRC=""
for c in "${MOE_SLIM_TEST_MODELS:-}" "$REPO/Models" "$HOME/moe-release/Models" "$HOME/moe-catchup/Models"; do
  [ -n "$c" ] || continue
  have=1; for m in $ON_DEMAND; do [ -d "$c/$m" ] || have=0; done
  [ "$have" = 1 ] && { SRC=$c; break; }
done
if [ -z "$SRC" ]; then
  echo "  NOT RUN 2–5: no staged models on this Mac (Models/ here, ~/moe-release, ~/moe-catchup,"
  echo "               or MOE_SLIM_TEST_MODELS). Run ./scripts/fetch-models.sh."
  echo
  echo "$pass passed, $fail failed, and four sections did not run"
  exit 1
fi
echo "   (staged models from $SRC)"

fixture() { # <dir>: a staged Models and a bundle copy of it — the real on-demand
            # folders (APFS clones, no bytes copied) and a stand-in for the rest
  local d="$1"; rm -rf "$d"; mkdir -p "$d/Models"
  for m in $ALL; do
    case " $ON_DEMAND " in
      *" $m "*) cp -Rc "$SRC/$m" "$d/Models/$m" 2>/dev/null || cp -R "$SRC/$m" "$d/Models/$m" ;;
      *) mkdir -p "$d/Models/$m"; echo weights > "$d/Models/$m/model.bin" ;;
    esac
  done
  cp -Rc "$d/Models" "$d/bundle" 2>/dev/null || cp -R "$d/Models" "$d/bundle"
}
# The models a slim bundle still carries. A function, not inline: bash 3.2
# (the one macOS ships) cannot parse a `case` inside `$( … )`.
carried() {
  local m
  for m in $ALL; do
    case " $ON_DEMAND " in *" $m "*) ;; *) echo "$m" ;; esac
  done
}
listing() { (cd "$1" && find . -type f | sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1); }

echo "2. on: exactly the listed folders are left out"
fixture "$SCRATCH/on"
if out=$(./scripts/slim-bundled-models.sh on "$SCRATCH/on/Models" "$SCRATCH/on/bundle" 2>&1); then
  gone=1; for m in $ON_DEMAND; do [ -e "$SCRATCH/on/bundle/$m" ] && gone=0; done
  [ "$gone" = 1 ] && ok "the on-demand folders are not in the bundle" || bad "an on-demand folder is still there"
  kept=1; for m in $ALL; do case " $ON_DEMAND " in *" $m "*) ;; *) [ -f "$SCRATCH/on/bundle/$m/model.bin" ] || kept=0 ;; esac; done
  [ "$kept" = 1 ] && ok "every other model is untouched" || bad "a model that is not on demand was removed"
  want=$(carried | sort | tr '\n' ' ')
  [ "$(ls "$SCRATCH/on/bundle" | sort | tr '\n' ' ')" = "$want" ] && ok "the bundle is the list minus the on-demand ones" || bad "bundle holds: $(ls "$SCRATCH/on/bundle" | tr '\n' ' ')"
  for m in $ON_DEMAND; do [ -d "$SCRATCH/on/Models/$m" ] || bad "the STAGED $m was removed — only the bundle's copy may be"; done
  echo "$out" | grep -q "left out" && ok "and it says so: $(echo "$out" | tail -1 | sed 's/^ *//')" || bad "no report line: $out"
else
  bad "on was refused: $out"
fi

echo "3. prepare: nothing is left out"
fixture "$SCRATCH/prep"
before=$(listing "$SCRATCH/prep/bundle")
if out=$(./scripts/slim-bundled-models.sh prepare "$SCRATCH/prep/Models" "$SCRATCH/prep/bundle" 2>&1); then
  [ "$(listing "$SCRATCH/prep/bundle")" = "$before" ] && ok "the bundle is byte for byte what it was" || bad "prepare changed the bundle"
else
  bad "prepare was refused: $out"
fi

echo "4. a model that is not the pinned one is refused, and the bundle stays whole"
first=${ON_DEMAND%% *}
fixture "$SCRATCH/drift"
victim=$(cd "$SCRATCH/drift/Models/$first" && find . -type f -name '*.json' | sort | head -1)
# Replace, never write through: the fixture's files are clones of the real
# staged ones and must not be reachable from here.
rm -f "$SCRATCH/drift/Models/$first/$victim" "$SCRATCH/drift/bundle/$first/$victim"
echo '{"not": "the pinned file"}' > "$SCRATCH/drift/Models/$first/$victim"
cp "$SCRATCH/drift/Models/$first/$victim" "$SCRATCH/drift/bundle/$first/$victim"
before=$(listing "$SCRATCH/drift/bundle")
for mode in on prepare; do
  if out=$(./scripts/slim-bundled-models.sh $mode "$SCRATCH/drift/Models" "$SCRATCH/drift/bundle" 2>&1); then
    bad "$mode accepted a staged $first whose $victim is not the pinned file"
  else
    echo "$out" | grep -q "does not describe the models staged" \
      && ok "$mode refuses a changed $victim, and says the manifest disagrees" \
      || bad "$mode refused for another reason: $out"
  fi
done
[ "$(listing "$SCRATCH/drift/bundle")" = "$before" ] && ok "nothing was removed by the refused runs" || bad "a refused run changed the bundle"

fixture "$SCRATCH/extra"
echo stray > "$SCRATCH/extra/Models/$first/stray.bin"; cp "$SCRATCH/extra/Models/$first/stray.bin" "$SCRATCH/extra/bundle/$first/stray.bin"
./scripts/slim-bundled-models.sh on "$SCRATCH/extra/Models" "$SCRATCH/extra/bundle" >/dev/null 2>&1 \
  && bad "a staged folder with a file the manifest does not name was accepted" \
  || ok "a file the manifest does not name is refused too (the app would never fetch it)"

fixture "$SCRATCH/missing"
rm -rf "$SCRATCH/missing/bundle/$first"
before=$(listing "$SCRATCH/missing/bundle")
./scripts/slim-bundled-models.sh on "$SCRATCH/missing/Models" "$SCRATCH/missing/bundle" >/dev/null 2>&1 \
  && bad "on accepted a bundle that never had $first" || ok "a bundle that never had $first is refused"
[ "$(listing "$SCRATCH/missing/bundle")" = "$before" ] && ok "…with the other on-demand folders still in it" || bad "it removed some before refusing"

fixture "$SCRATCH/between"
echo x >> "$SCRATCH/between/bundle/$first/$victim.new"
./scripts/slim-bundled-models.sh on "$SCRATCH/between/Models" "$SCRATCH/between/bundle" >/dev/null 2>&1 \
  && bad "a bundle copy that differs from the staged one was accepted" || ok "a bundle copy that is not the staged copy is refused"

printf 'APP_SUPPORT_MODELS="a b"\nCACHE_MODELS="c"\n' > "$SCRATCH/nolist.sh"
fixture "$SCRATCH/nolist"
./scripts/slim-bundled-models.sh on "$SCRATCH/nolist/Models" "$SCRATCH/nolist/bundle" "$SCRATCH/nolist.sh" >/dev/null 2>&1
[ $? = 2 ] && ok "no ON_DEMAND_MODELS line: cannot run, exit 2 — not a pass" || bad "a missing list did not exit 2"
./scripts/slim-bundled-models.sh off "$SCRATCH/nolist/Models" "$SCRATCH/nolist/bundle" >/dev/null 2>&1
[ $? = 2 ] && ok "mode 'off' is not this script's to handle, exit 2" || bad "mode off did not exit 2"

echo "5. the manifest in the source tree is the staged models"
if python3 scripts/make-component-manifest.py --models "$SRC" --check >/dev/null 2>&1; then
  ok "ComponentManifest.swift matches $SRC, sha256 for sha256"
else
  bad "ComponentManifest.swift does not match $SRC — $(python3 scripts/make-component-manifest.py --models "$SRC" --check 2>&1 | head -1)"
fi
n=$(grep -c 'ComponentFile("' Sources/MoeComponents/ComponentManifest.swift)
real=$(for m in $ON_DEMAND; do find "$SRC/$m" -type f ! -name .DS_Store; done | wc -l | tr -d ' ')
[ "$n" = "$real" ] && [ "$n" -gt 0 ] && ok "$n files pinned, $real staged" || bad "$n files pinned but $real staged"
grep -Eq '"[0-9a-f]{40}"\),$' Sources/MoeComponents/ComponentManifest.swift \
  && ! grep -q '"main"' Sources/MoeComponents/ComponentManifest.swift \
  && ok "every repository is pinned to a commit, not a branch" || bad "a pin is not a 40-character commit"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
