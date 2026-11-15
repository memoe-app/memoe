#!/bin/bash
# The send gate in front of every Hermes tool — moe-home/hermes/hooks/
# confirm-send.sh — run as the rest of the shell suites are, so test-all.sh
# counts it. The suite itself lives beside the hook; this is the door.
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
exec bash moe-home/hermes/tests/test-confirm-hook.sh
