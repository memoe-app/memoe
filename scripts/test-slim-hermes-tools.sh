#!/bin/bash
# What slim-hermes-tools.py takes out of the Hermes tool store before it ships,
# on a fixture store — no seed, no network, nothing under ~ touched.
#
# The one thing it must never take is Python's ensurepip. From 0.3.22 it did,
# and on every seeded Mac `python -m venv` then died in ensurepip: the Telegram
# sign-in showed "…'-m', 'ensurepip', '--upgrade', '--default-pip']' returned
# non-zero exit status 1" (owner's Mac, 2026-11-13). Tk/IDLE/turtle, headers
# and static archives still go.
set -u
unset CDPATH
cd "$(dirname "$0")/.." || exit 1
SLIM="$PWD/scripts/slim-hermes-tools.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/moe-slim-tools.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; }

store="$T/tools"; PYRT="python-3.14.9+20261021-darwin-arm64"; L="$store/$PYRT/lib/python3.14"
mkdir -p "$L/ensurepip/_bundled" "$L/tkinter" "$L/idlelib" "$L/turtledemo" "$L/lib-dynload" "$L/json" \
         "$store/$PYRT/include/python3.14" "$store/$PYRT/bin"
: > "$L/ensurepip/__init__.py"; : > "$L/ensurepip/_bundled/pip-26.0-py3-none-any.whl"
: > "$L/lib-dynload/_tkinter.cpython-314-darwin.so"; : > "$L/json/__init__.py"; : > "$L/tkinter/__init__.py"
printf '{"schema":1,"packages":{"python":{"entry":"%s","env":{}}}}\n' "$PYRT" > "$store/facts.json"

echo "1. --check names what would go, and not ensurepip"
out="$(python3 "$SLIM" "$store" --check 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "--check runs" || bad "--check failed ($rc): $out"
case "$out" in *ensurepip*) bad "--check would drop ensurepip: $out" ;; *) ok "ensurepip is not on the list" ;; esac
case "$out" in *tkinter*) ok "tkinter is" ;; *) bad "tkinter is not on the list: $out" ;; esac

echo "2. slimming keeps ensurepip and drops the rest"
out="$(python3 "$SLIM" "$store" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "slim runs" || bad "slim failed ($rc): $out"
[ -f "$L/ensurepip/__init__.py" ] && [ -f "$L/ensurepip/_bundled/pip-26.0-py3-none-any.whl" ] \
  && ok "lib/python3.14/ensurepip and its bundled pip wheel are still there" || bad "ensurepip was removed"
[ ! -e "$L/tkinter" ] && [ ! -e "$L/idlelib" ] && [ ! -e "$L/turtledemo" ] && [ ! -e "$L/lib-dynload/_tkinter.cpython-314-darwin.so" ] \
  && [ ! -e "$store/$PYRT/include" ] && ok "tkinter, idlelib, turtledemo, _tkinter and include/ are gone" || bad "something on the drop list survived"
[ -f "$L/json/__init__.py" ] && ok "the rest of the stdlib is untouched" || bad "json was removed"

echo "3. a drop pattern that would take ensurepip is refused, not obeyed"
cp "$SLIM" "$T/slim-wide.py"
python3 - "$T/slim-wide.py" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace('"lib/python3.*/tkinter",', '"lib/python3.*/tkinter", "lib/python3.*/ensurepip",', 1)
open(p, "w").write(s)
PY
mkdir -p "$L/tkinter"
out="$(python3 "$T/slim-wide.py" "$store" 2>&1)"; rc=$?
[ $rc -ne 0 ] && [ -f "$L/ensurepip/__init__.py" ] && ok "refused (exit $rc), ensurepip kept: $(printf '%s' "$out" | grep '✗' | cut -c1-90)" \
  || bad "a pattern naming ensurepip was obeyed (exit $rc): $out"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
