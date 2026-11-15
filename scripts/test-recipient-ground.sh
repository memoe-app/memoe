#!/bin/bash
# Who a message goes to and who named them — the recipient gate in the send
# hook (moe-home/tools/recipients.py), with the 2026-09-25 incident replayed.
# The suite itself lives beside the hook; this is the door test-all.sh counts.
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
exec bash moe-home/hermes/tests/test-recipient-ground.sh
