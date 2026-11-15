#!/bin/bash
# The Python suites that sit beside Hermes's plugins, jobs and gateway hooks.
#
# These were written, they pass, and until 2026-09-04 nothing ran them: not
# test-all.sh, not CI, not the shell suite next door. Between them
# moe-ledger/ and claimstore/ are the memory and credential chain — the
# canonical record form, the sealed claim, the retired key, the projection
# into MEMORY.md, the drift a second writer must not cause — and they had
# been running nowhere at all. scripts/test-suites-are-run.sh is the guard
# that stops that happening again; this is the runner it points at.
#
#   moe-ledger            the ledger library and the memory provider
#   claimstore            the claim store plugin and its projection
#   moe-connectors        the connectors plugin and detached intents
#   moe-blueprints        the blueprints plugin against Hermes's catalog
#   moe-profile           the learning-profile plugin
#   hermes-gateway-hooks  the moe-activity hook: what it records and refuses
#   hermes-jobs           the away/intent/watch/autoread jobs
#   hermes/tests          migrate-memory (the configure-hermes merge tests are
#                         step 14 of scripts/test-configure-hermes.sh)
#   learn                 distil, merge, profile, consent, seed-memory
#   connectors            the gmail crawl parser and the telegram send gate
#
# The last two belong to scripts/test-learn.sh, which runs them first and then
# a long end-to-end half against a fake gateway. That end-to-end half fails on
# main today (25 of 136 checks), so test-learn.sh cannot be put in test-all.sh
# without turning it red for everyone — and if these unit tests only ran from
# there, they would not run at all. They are cheap and they pass, so they run
# here; scripts/test-suites-excused.txt records why the shell suite does not.
#
# moe-screen's main suite is not here: it is a stdlib unittest module that
# only runs as a script, and step 11 of test-configure-hermes.sh runs it that
# way. Its pytest file, test_pushes.py (slice E1: the gateway leaves the pull
# marker on a Mac), IS here — alone, and with --import-mode=importlib,
# because it is one more `tests/` directory with no __init__.py and pytest's
# default import mode would clash with the others' test module names.
#
# Nothing here touches the network, the real ~/.moe or the real ~/.hermes:
# every conftest points MOE_HOME and HERMES_HOME at a temp directory, and this
# script exports both at a scratch directory too, for the suites that have no
# conftest to do it.
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SCRATCH="${MOE_TEST_SCRATCH:-${TMPDIR:-/tmp}}/moe-plugins-test.$$"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

pass=0; fail=0
ok()  { echo "  ok   $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# ── an interpreter with pytest, and Hermes on the path ──────────────────────
# moe-ledger's plugin imports agent.memory_provider, so the hermes-agent
# checkout has to be importable whichever interpreter is used. The Hermes venv
# is uv-managed and ships no pytest (the same thing test-computer-use.sh
# found), so the test venv make-test-venv.sh builds — which does — is the
# fallback.
HERMES_AGENT="${MOE_HERMES_AGENT:-$HOME/.hermes/hermes-agent}"
PY=""
for cand in "${MOE_TEST_PYTHON:-}" "$HERMES_AGENT/.venv/bin/python" "$ROOT/edge/.venv/bin/python"; do
  [ -n "$cand" ] || continue
  [ -x "$cand" ] || continue
  if "$cand" -c 'import pytest' >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then
  echo "… skipped: no interpreter with pytest."
  echo "  tried MOE_TEST_PYTHON, $HERMES_AGENT/.venv/bin/python, $ROOT/edge/.venv/bin/python."
  echo "  Run ./scripts/make-test-venv.sh — one command, builds a test venv from"
  echo "  a pinned lock file — or set MOE_TEST_PYTHON at an interpreter that"
  echo "  has pytest. Nothing on this Mac has one by default: the system python is"
  echo "  3.9 (too old to import Hermes at all) and Hermes's own venv is uv-managed"
  echo "  and ships none."
  # Last, because scripts/test-all.sh prints the last line of each suite's log
  # and a skip that scrolls past as a hint reads exactly like a pass.
  echo "  THE PLUGIN SUITES DID NOT RUN."
  # **Non-zero.** This used to `exit 0`, so a Mac without an interpreter that
  # has pytest scored a PASS in test-all.sh for ten suites that never ran —
  # including the 1200-line test_brain.py that is the only coverage BYO brain
  # has, and it skipped on this Mac today (§18.30). A runner that cannot run
  # is a failure to report, not a result: "nobody checked" and "checked and
  # fine" must never be the same exit code. Set MOE_TEST_PYTHON, or run
  # make-test-venv.sh, and it runs.
  #
  # Exit 2 with these two lines is what scripts/test-all.sh reports as
  # SKIPPED (missing input) — a third answer, neither a pass nor a failure of
  # the code — and scripts/gate.sh refuses to ship on it: this suite is in
  # its release-critical list.
  echo "could not run: no interpreter with pytest — ./scripts/make-test-venv.sh"
  echo "could not run"
  exit 2
fi
echo "python: $PY"
if [ -d "$HERMES_AGENT" ]; then
  export PYTHONPATH="$HERMES_AGENT${PYTHONPATH:+:$PYTHONPATH}"
else
  echo "  (no hermes-agent at $HERMES_AGENT — the moe-ledger provider tests will fail on 'No module named agent')"
fi

# ── a note on the user's own Hermes and Moe ─────────────────────────────────
# Two things were tried here and are deliberately not done, because both were
# wrong in a way worth recording.
#
# Comparing ~/.hermes and the Moe home before and after, the way step 15 of
# test-configure-hermes.sh does, reports a failure every single time on this
# Mac: the live Moe writes to both while the suites run, and the check cannot
# tell its writes from theirs. A check that fires on unrelated noise is no
# better than one that cannot fire at all.
#
# Exporting MOE_HOME and HERMES_HOME at a scratch directory looks safer and
# breaks two tests that are meant to read the real thing —
# moe-connectors' RealCatalogue::test_it_registers_the_catalogue_not_a_curated_list
# and moe-ledger's test_the_published_shape_is_what_the_reader_parses read
# this machine's actual connector manifests on purpose, which is the point of
# them. Isolation of WRITES belongs to each conftest, and every one of them
# does it: an explicit temp MOE_HOME/HERMES_HOME per test.

run_pytest() {           # $1 = label, $2… = paths to hand pytest
  local label="$1"; shift
  local log="$SCRATCH/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '-').log"
  if "$PY" -m pytest -q -p no:cacheprovider "$@" >"$log" 2>&1; then
    ok "$label: $(grep -E '^[0-9]+ (passed|failed)|passed' "$log" | tail -1)"
  else
    bad "$label: $(grep -E 'passed|failed|error' "$log" | tail -1)"
    grep -E '^(FAILED|ERROR)' "$log" | head -5 | sed 's/^/       /'
  fi
}

echo "== the plugin, hook and job suites"
run_pytest "moe-ledger"           moe-home/hermes-plugins/moe-ledger/tests
run_pytest "claimstore"           moe-home/hermes-plugins/claimstore/tests
run_pytest "moe-connectors"       moe-home/hermes-plugins/moe-connectors/tests
run_pytest "moe-blueprints"       moe-home/hermes-plugins/moe-blueprints/tests
run_pytest "moe-profile"          moe-home/hermes-plugins/moe-profile/tests
run_pytest "hermes-gateway-hooks" moe-home/hermes-gateway-hooks/tests
run_pytest "hermes-jobs"          moe-home/hermes-jobs/tests
run_pytest "moe-screen pushes"     --import-mode=importlib moe-home/hermes-plugins/moe-screen/tests/test_pushes.py
# Same reason as test_pushes.py for --import-mode=importlib. This one needs
# Hermes importable AND `croniter` (it builds real cron jobs in a scratch
# HERMES_HOME); make-test-venv.sh installs it.
run_pytest "moe-screen rearm"      --import-mode=importlib moe-home/hermes-plugins/moe-screen/tests/test_rearm.py
run_pytest "moe-screen tasks"      --import-mode=importlib moe-home/hermes-plugins/moe-screen/tests/test_tasks.py
run_pytest "moe-screen nowline"    --import-mode=importlib moe-home/hermes-plugins/moe-screen/tests/test_nowline.py
run_pytest "moe-screen cronlist"   --import-mode=importlib moe-home/hermes-plugins/moe-screen/tests/test_cronlist.py
# docs/FIXABLE-FAILURES.md slice 4: moe_open_settings refuses anything but an
# allowlisted pane, and any turn the person is not at the Mac for — against
# the fork's own turn_presence (the test finds a fork that has it; export
# MOE_HERMES_FORK to choose one).
run_pytest "moe-screen open-settings" --import-mode=importlib moe-home/hermes-plugins/moe-screen/tests/test_open_settings.py
# moe_location: the Mac's location only in the person's own turn at the Mac,
# down a pipe and never a file, and a plain sentence for every way of not
# knowing (the app's half is LocationTests).
run_pytest "moe-screen location"   --import-mode=importlib moe-home/hermes-plugins/moe-screen/tests/test_location.py
run_pytest "moe-screen settings"   --import-mode=importlib moe-home/hermes-plugins/moe-screen/tests/test_settings.py
# D4, both sides claim each run: the Mac's half (claim.py) asks the app before
# a cron fires, and runs anyway — saying so — when nothing answers. Needs the
# fork's `pre_cron_run` hook importable (Hermes on PYTHONPATH, as above).
run_pytest "moe-screen claim"      --import-mode=importlib moe-home/hermes-plugins/moe-screen/tests/test_claim.py
run_pytest "migrate-memory"       moe-home/hermes/tests/test_migrate_memory.py

# Two files written as plain unittest scripts ("Run: python3 <file>") that no
# runner named, found by scripts/test-suites-are-run.sh on 2026-11-12: 9
# tests on the inbox's title-and-summary wire and 98 on who a message may go
# to. Run the way their own docstrings say, because pytest cannot collect
# them: test_recipients.py imports its fixture module (connector_output.py)
# from beside itself, and test_inboxwords.py loads the plugin by path.
#
# The second had three red cases the day it was first run by anything: its
# fixture chat.db had no attributedBody column, which imessage.sh has required
# since it began decoding that column, so the connector refused with
# "unfamiliar Messages layout" and the test read an empty answer. That is the
# cost of an unrun suite, measured: its fixture drifted and nobody was told.
run_unittest() {         # $1 = label, $2 = the test file
  local log="$SCRATCH/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-').log"
  if "$PY" "$2" >"$log" 2>&1 && grep -q '^OK' "$log"; then
    ok "$1: $(grep -o 'Ran [0-9]* tests' "$log")"
  else
    bad "$1: $(tail -3 "$log" | tr '\n' ' ')"
    grep -E '^(FAIL|ERROR):' "$log" | head -5 | sed 's/^/       /'
  fi
}
run_unittest "moe-screen inboxwords" moe-home/hermes-plugins/moe-screen/tests/test_inboxwords.py
run_unittest "recipients"            moe-home/hermes/tests/test_recipients.py
run_pytest "learn"                moe-home/learn/tests
run_pytest "connectors"           moe-home/connectors/tests

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
