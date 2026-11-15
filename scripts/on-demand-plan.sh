#!/bin/bash
# What a release of a given version does about the on-demand models: the one
# reader of scripts/on-demand-plan.txt.
#
#   on-demand-plan.sh mode <X.Y.Z>   prints off, prepare or on
#   on-demand-plan.sh check          the plan itself is well formed
#
# build.sh asks it for the default of a real (not Dev, not community) build;
# ship.sh asks before it builds; publish-release.sh asks about the version
# inside the image and refuses a mismatch. One reader, so the three cannot
# come to read the file differently.
#
# Exit 0 with the answer; 2 when there is no answer to give — an unreadable
# plan, a line that breaks a rule, a version that is not a version. Never a
# guess: every caller treats 2 as a refusal.
#
# MOE_ON_DEMAND_PLAN names another plan file. It is for the test suites, which
# need to see `on` and a broken plan without editing the real one.
set -u
unset CDPATH
HERE="$(cd "$(dirname "$0")" && pwd)"
PLAN="${MOE_ON_DEMAND_PLAN:-$HERE/on-demand-plan.txt}"

cant() { echo "✗ on-demand-plan: $*" >&2; exit 2; }
[ -f "$PLAN" ] || cant "no plan at $PLAN"

# Prints the mode for $1 (empty = only check), or a line starting "!" on error.
answer() {
  awk -v want="$1" '
    function num(v,   p) { split(v, p, "."); return p[1] * 1000000 + p[2] * 1000 + p[3] }
    /^[[:space:]]*(#|$)/ { next }
    {
      if (NF != 2) { print "! line " NR ": expected <version> <mode>, got: " $0; bad = 1; exit }
      if ($1 !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print "! line " NR ": " $1 " is not X.Y.Z"; bad = 1; exit }
      if ($2 != "off" && $2 != "prepare" && $2 != "on") { print "! line " NR ": mode " $2 " — off, prepare or on"; bad = 1; exit }
      if (seen && num($1) <= last) { print "! line " NR ": " $1 " does not come after the line before it"; bad = 1; exit }
      if ($2 == "on" && mode != "prepare" && mode != "on") {
        print "! line " NR ": " $1 " is on, but the release before it is " mode " — a prepare release has to go out first"; bad = 1; exit
      }
      last = num($1); seen = 1; mode = $2
      if (want != "" && num($1) <= num(want)) got = $2
    }
    BEGIN { mode = "off"; got = "off" }
    END { if (!bad) print got }
  ' "$PLAN"
}

case "${1:-}" in
  mode)
    v="${2:-}"
    printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || cant "'$v' is not a version (X.Y.Z)"
    out="$(answer "$v")" || cant "could not read $PLAN"
    case "$out" in
      off|prepare|on) echo "$out" ;;
      *) cant "${out#! } ($PLAN)" ;;
    esac ;;
  check)
    out="$(answer "")" || cant "could not read $PLAN"
    case "$out" in
      off|prepare|on) exit 0 ;;
      *) cant "${out#! } ($PLAN)" ;;
    esac ;;
  *) echo "usage: on-demand-plan.sh mode <X.Y.Z> | check" >&2; exit 2 ;;
esac
