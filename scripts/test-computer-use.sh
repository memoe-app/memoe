#!/bin/bash
# Moe's eyes, end to end through Hermes — screenshot only.
#
# Runs Hermes's `computer_use` tool directly (no gateway, no Claude, no
# clicks, no typing) and then the same capture through the hermes-tools MCP
# server exactly as Claude Code would call it, checking that an MCP `image`
# block comes back, that it is ≤ 1568 px on its longest side, and that the
# text next to it carries the coordinate note.
#
#   1. unit tests  — the backend's scaling math and stubbed capture, plus the
#                    image-block conversion (pytest, no display needed)
#   2. live capture — only if Screen Recording is granted to the process
#                    running this script (Terminal / the IDE). If it is not,
#                    the live steps SKIP with a message and the script still
#                    exits 0: an ungranted permission is not a test failure.
#   3. MCP wire    — spawn the server with the claude-code profile against a
#                    stub screencapture (a generated PNG), call capture, and
#                    assert the image block. Runs whether or not (2) could.
#   4. hands off   — Moe's hands stop the moment a human takes over: the
#                    `moe-home/tools/mac.sh` side of abort-on-user-input, end
#                    to end, with a stub standing in for the event tap so
#                    nothing has to be clicked and no permission is needed.
#                    Needs no Hermes at all, so it runs even when 1–3 skip.
#
# Nothing is written outside a scratch dir: HERMES_HOME is a mktemp dir, so
# ~/.hermes is not read for config, and ~/.moe is not touched at all.
#
#   HERMES_AGENT_DIR  hermes-agent checkout (default ~/.hermes/hermes-agent)
#   HERMES_PYTHON     interpreter (default $HERMES_AGENT_DIR/.venv/bin/python,
#                     else ~/.hermes/hermes-agent/.venv/bin/python — a git
#                     worktree of the fork has no venv of its own)
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1

AGENT="${HERMES_AGENT_DIR:-$HOME/.hermes/hermes-agent}"
PY="${HERMES_PYTHON:-$AGENT/.venv/bin/python}"
[ -x "$PY" ] || PY="$HOME/.hermes/hermes-agent/.venv/bin/python"
# A missing venv skips the three Hermes sections rather than ending the run:
# section 4 is pure shell and has something to say either way.
HAVE_HERMES=1
[ -x "$PY" ] || HAVE_HERMES=0
export AGENT_DIR="$AGENT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/moe-computer-use.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HERMES_HOME="$WORK/hermes-home"
mkdir -p "$HERMES_HOME"
export HERMES_MCP_TOOL_PROFILE=claude-code
export HERMES_COMPUTER_USE_BACKEND=macos
export HERMES_SCREENSHOT_DIR="$WORK/shots"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
skip() { SKIP=$((SKIP+1)); echo "  skip $1"; }

# 1. unit tests --------------------------------------------------------------
echo "1. unit tests"
if [ "$HAVE_HERMES" = 0 ]; then
  skip "no Hermes venv at $PY (run scripts/install-hermes.sh first) — sections 1-3"
elif ! "$PY" -c "import pytest" >/dev/null 2>&1; then
  # The Hermes venv is uv-managed and ships no pytest, so this reported FAIL
  # on every run — a permanent red line that says nothing about the code and
  # trains you to ignore the summary. It is a missing tool, so say that.
  skip "pytest is not installed in $PY (uv-managed venv; \`uv pip install --python $PY pytest\`)"
elif (cd "$AGENT" && "$PY" -m pytest -q -p no:cacheprovider \
      tests/computer_use/test_macos_native_backend.py \
      tests/computer_use/test_cua_spaces.py \
      tests/computer_use/test_cua_stall.py \
      tests/agent/transports/test_hermes_tools_mcp_images.py >"$WORK/pytest.log" 2>&1); then
  ok "backend + image-bridge tests: $(tail -1 "$WORK/pytest.log")"
else
  fail "pytest" "$(tail -15 "$WORK/pytest.log")"
fi

# 2. live capture (screenshot only) ----------------------------------------------
echo "2. live screenshot through the tool"
if [ "$HAVE_HERMES" = 0 ]; then LIVE="SKIP"; else
LIVE="$(cd "$AGENT" && "$PY" - <<'PY' 2>"$WORK/live.err"
import base64, io, json, sys
from tools.computer_use.tool import handle_computer_use
r = handle_computer_use({"action": "capture", "mode": "vision"})
if isinstance(r, str):
    try:
        err = json.loads(r).get("error", r)
    except Exception:
        err = r
    print("ERR " + err.replace("\n", " ")[:300]); sys.exit(0)
from PIL import Image
url = r["content"][1]["image_url"]["url"]
im = Image.open(io.BytesIO(base64.b64decode(url.split(",", 1)[1])))
print("OK %dx%d %s" % (im.size[0], im.size[1], r["meta"].get("screenshot_path", "")))
PY
)"
fi
case "$LIVE" in
  SKIP) skip "no Hermes venv — live capture" ;;
  OK*)
    set -- $LIVE
    dims="$2"; w="${dims%x*}"; h="${dims#*x}"
    if [ "$w" -le 1568 ] && [ "$h" -le 1568 ]; then ok "captured ${dims}px (≤ 1568 longest side)"; else fail "capture is ${dims}px, longer than 1568"; fi
    WIN="$(cd "$AGENT" && "$PY" -c 'from tools.computer_use.tool import handle_computer_use as h; print(h({"action":"list_windows"}))' 2>/dev/null)"
    case "$WIN" in *'"frontmost": true'*) ok "list_windows reports the front app" ;; *) fail "list_windows" "$WIN" ;; esac
    ;;
  ERR*Screen\ Recording*)
    skip "Screen Recording is not granted to this terminal — grant it in System Settings › Privacy & Security › Screen Recording (or run from an app that has it) to exercise the live capture"
    ;;
  *)
    fail "live capture" "$LIVE $(head -5 "$WORK/live.err")"
    ;;
esac

# 3. MCP wire with a stub screencapture ---------------------------------------
echo "3. hermes-tools MCP server (claude-code profile) returns an image block"
if [ "$HAVE_HERMES" = 0 ]; then
  skip "no Hermes venv — MCP wire"
  WIRE=""
else
"$PY" - "$WORK/fixture.png" <<'PY'
import sys
from PIL import Image, ImageDraw
im = Image.new("RGB", (2940, 1912), (30, 120, 200))
ImageDraw.Draw(im).rectangle((100, 100, 900, 700), fill="white")
im.save(sys.argv[1])
PY
printf '#!/bin/sh\nfor last; do :; done\ncp "%s/fixture.png" "$last"\n' "$WORK" >"$WORK/screencapture"
chmod +x "$WORK/screencapture"
WIRE="$(cd "$AGENT" && HERMES_SCREENCAPTURE_BIN="$WORK/screencapture" "$PY" - <<'PY' 2>"$WORK/wire.err"
import asyncio, base64, io, os, sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
async def main():
    p = StdioServerParameters(command=sys.executable, args=["-m", "agent.transports.hermes_tools_mcp_server"],
                              env=dict(os.environ), cwd=os.getcwd())
    async with stdio_client(p) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            names = [t.name for t in (await s.list_tools()).tools]
            if "computer_use" not in names:
                print("ERR computer_use not exposed: %s" % names); return
            res = await s.call_tool("computer_use", {"action": "capture", "mode": "vision"})
            kinds = [c.type for c in res.content]
            if res.is_error or "image" not in kinds:
                print("ERR is_error=%s kinds=%s %s" % (res.is_error, kinds, getattr(res.content[0], "text", "")[:200])); return
            img = next(c for c in res.content if c.type == "image")
            from PIL import Image
            im = Image.open(io.BytesIO(base64.b64decode(img.data)))
            text = " ".join(getattr(c, "text", "") for c in res.content if c.type == "text")
            print("OK %dx%d %s note=%s" % (im.size[0], im.size[1], img.mime_type, "screenshot pixels" in text))
asyncio.run(main())
PY
)"
fi
case "$WIRE" in
  "") ;;                                             # skipped above
  OK*1568x1020*image/png*note=True) ok "image block: $WIRE" ;;
  OK*) fail "image block came back but wrong shape" "$WIRE" ;;
  *) fail "MCP wire" "$WIRE $(tail -5 "$WORK/wire.err")" ;;
esac

# 4. the hands-off guard, deleted ---------------------------------------------
#
# There were forty-odd checks here for a guard that watched the session's
# CGEvent stream and refused to act when it thought a human had taken over.
# It is gone, and so are they.
#
# It could not work. cua-driver's foreground path posts "a genuine HID key
# transition" — its own words — so that Chromium content and native menu
# equivalents receive it, which means it is indistinguishable from hardware by
# design: source pid 0, the same as the keyboard. Three thresholds were tried
# in one evening (3 points summed for the watcher's life; 32 points in a
# 400 ms burst; trusting the driver's bundle id) and every one of them fired
# on Moe rather than on the owner. Four of his sessions were refused by it,
# and each refusal told him he had touched a mouse he had not touched.
#
# Stopping is a person's decision now, not an inference: the notch changes
# colour while Moe drives and carries a stop that ends the run. The test for
# that lives with the island, where a person can actually be modelled.
#
# What is kept here is the one assertion that matters going forward — that
# nothing consults a guard any more — and it lives in the confirm-hook suite,
# next to the gate that used to call it.

# 5. Spaces: a window one desktop away ---------------------------------------
#
# The suite forces the macOS-native backend above, so until now nothing here
# ever exercised cua-driver — the backend that actually runs. On 2026-09-03
# capture(app='Calendar') reported "<no on-screen window matched>" for a
# window that was open one Space away, and blamed localized app names, so the
# agent re-spelled "Calendar" for ninety seconds. These assert the message and
# the records, not merely that a call was allowed.
echo
echo "5. a window on another Space is found, and says so"
if [ "$HAVE_HERMES" = 0 ]; then
    skip "no hermes venv"
else
    out="$("$PY" - <<'PYEND' 2>&1
import json, sys
sys.path.insert(0, __import__("os").environ.get("AGENT_DIR", ""))
from tools.computer_use.cua_backend import CuaDriverBackend, _ingest_windows

raw = [
    {"window_id": 1, "pid": 7253, "app_name": "Calendar", "title": "", "z_index": 5,
     "is_on_screen": False, "on_current_space": False, "space_ids": [1]},
    {"window_id": 2, "pid": 900, "app_name": "Terminal", "title": "", "z_index": 9,
     "is_on_screen": True, "on_current_space": True, "space_ids": [2915]},
    {"window_id": 3, "pid": 7253, "app_name": "Calendar", "title": "", "z_index": 0,
     "is_on_screen": False, "on_current_space": None, "space_ids": None},
]

class B(CuaDriverBackend):
    def __init__(self): pass
    def _load_windows_all_spaces_checked(self): return _ingest_windows(raw), False
    def _load_windows(self):
        return _ingest_windows([w for w in raw if w.get("on_current_space") is True])

b = B()
checks = []
ids = [w["window_id"] for w in b.list_windows()]
checks.append(("off-Space window is listed", 1 in ids))
checks.append(("hidden backing window is not", 3 not in ids))
checks.append(("reachable sorts first", ids[0] == 2))
checks.append(("old view really hid it",
               1 not in [w["window_id"] for w in b._load_windows()]))

msg = b._no_match_reason("Calendar")
checks.append(("message names the Space", "another macOS Space" in msg))
checks.append(("message names the window", "window_id=1" in msg and "pid=7253" in msg))
checks.append(("message stops the re-spelling", "NOT a naming problem" in msg))
checks.append(("message does not blame localization", "localized" not in msg.lower()))
checks.append(("message says reading still works", "READ it where it is" in msg))
checks.append(("absent app still gets naming advice",
               "list_apps" in b._no_match_reason("Xcode")))

from tools.computer_use.schema import get_computer_use_schema
d = get_computer_use_schema()["description"]
checks.append(("schema teaches on_current_space", "on_current_space" in d))

for name, good in checks:
    print(("PASS " if good else "FAIL ") + name)
PYEND
)" || true
    while IFS= read -r line; do
        case "$line" in
            PASS*) ok "${line#PASS }" ;;
            FAIL*) fail "${line#FAIL }" ;;
            *) [ -n "$line" ] && fail "spaces harness" "$line" ;;
        esac
    done <<EOF
$out
EOF
fi

# The live half: the driver must still report the field the code reads. This
# is metadata only — no screenshot, no pixels, nothing captured.
echo
echo "6. cua-driver still reports Space metadata"
if ! command -v cua-driver >/dev/null 2>&1; then
    skip "cua-driver not installed"
else
    # BOUNDED, because an unbounded call here hangs the whole suite and
    # test-all with it. Measured 2026-09-05: the daemon wedged, every call
    # blocked, and this line sat for ten minutes with no output — test-all
    # never reached the four suites after it, which read as "still running"
    # rather than "stuck". A stale socket file left behind by a dead daemon
    # does the same thing.
    #
    # perl's alarm, because macOS has no `timeout`. @ARGV has four elements so
    # exec takes the list form and nothing is re-split by a shell — the
    # single-element `exec @ARGV` is the one that splits on spaces.
    live="$(perl -e 'alarm 8; exec @ARGV' cua-driver call list_windows --json 2>/dev/null || true)"
    if [ -z "$live" ]; then
        skip "cua-driver returned nothing (daemon not running?)"
    else
        if printf '%s' "$live" | grep -q '"on_current_space"'; then
            ok "list_windows records carry on_current_space"
        else
            fail "list_windows records carry on_current_space" \
                 "the driver changed its payload; _no_match_reason will go quiet"
        fi
        if printf '%s' "$live" | grep -q '"space_ids"'; then
            ok "list_windows records carry space_ids"
        else
            fail "list_windows records carry space_ids"
        fi
    fi
fi

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
