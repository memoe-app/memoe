"""``moe_location()``: where this Mac is, from macOS Location Services, with
the person's permission.

Before this, "what's the weather" was answered for wherever the internet
connection happened to be routed through (the owner, 2026-11-12: Huntington
Station). The Memoe app owns the permission, so the app does the asking and
the reading; this tool only carries the question over and the answer back.

How the answer travels: this tool makes a named pipe that only this user can
open, posts a distributed notification naming it (the same channel
``moe_open_settings`` uses), and the app writes one line of JSON down the
pipe. A pipe, not a file: where the person is goes from the app's memory to
this process's and is never on disk.

What it refuses, each tested:

* **A turn nobody is at.** macOS asks its question the first time this is
  called, on the Mac's screen, so it needs the person's own live turn at the
  Mac, and the Mac's whereabouts are only read for the person sitting at it:
  never a cron job, a background note, a helper, or a message from a phone
  (the phone is not where the Mac is). Presence is the fork's judgement and
  fails closed, exactly as in open_settings.py. The app checks again.
* **A guess.** When there is no place — permission off, not answered yet, no
  fix — the result is ``success: false`` with the app's plain sentence saying
  which, and what to do instead. It never substitutes anything.

Nothing here logs, stores or forwards the answer; it is returned to the turn
that asked and that is all.
"""
from __future__ import annotations

import json
import os
import select
import shutil
import sys
import tempfile
import time

TOOL_NAME = "moe_location"
#: Its own toolset, listed in configure-hermes.py's MOE_TOOLSETS (the Mac)
#: and not in MOE_CHAT_TOOLSETS. As with moe_settings that is not the gate
#: under claude-code; the `why` check below and the app's own are.
TOOLSET = "moe_location"

#: The distributed notification the app listens for
#: (Sources/Moe/Location/LocationBridge.swift); the object is the request.
SIGNAL = "com.moe.location"

#: Longer than the app waits on macOS's question (LocationService.decisionWait,
#: 25 s) plus a fix (10 s), so the app's own sentence always arrives first.
WAIT_SECONDS = 40.0

_AT_THE_MAC = "the person's own turn"

FALLBACK = ("Do not guess: ask the person where they are, or use the rough place their "
            "internet connection gives and say that is what you used.")

TOOL_SCHEMA = {
    "name": TOOL_NAME,
    "description": (
        "Where the person's Mac is right now, from macOS Location Services: city, region, "
        "country, time zone, coordinates, how accurate the fix is and how old. Use it whenever "
        "the answer depends on where they are (weather, 'near me', directions, local times) "
        "instead of going by their internet connection. The first time, macOS asks the person "
        "for permission. Coordinates come rounded to about 1 km; set `precise` only when a "
        "street-level position is needed, such as directions from where they are. If it "
        "cannot give a place it says why in plain words: pass that on, never guess."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "precise": {
                "type": "boolean",
                "description": "True only when street-level position matters (directions, the "
                               "nearest one of something). Default false: about 1 km.",
            },
        },
        "required": [],
    },
}


def _ok(place: dict) -> str:
    return json.dumps({"success": True, "result": place})


def _no(msg: str, status: str = "") -> str:
    out = {"success": False, "error": msg}
    if status:
        out["status"] = status
    return json.dumps(out)


def presence() -> dict:
    """``{"live": bool, "why": str}`` from the fork, or not live."""
    try:
        from tools.browser_chrome_extension import turn_presence
        verdict = turn_presence()
        return verdict if isinstance(verdict, dict) else {"live": False, "why": "no answer"}
    except Exception as e:  # an older fork, no bridge: fail closed
        return {"live": False, "why": "presence could not be established (%s)" % type(e).__name__}


def post(request: str, signal: str | None = None) -> bool:
    """Post SIGNAL (or `signal`: settings.py shares this) with the request as
    its object, through CoreFoundation."""
    if sys.platform != "darwin":
        return False
    try:
        import ctypes
        import ctypes.util
        cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFNotificationCenterGetDistributedCenter.restype = ctypes.c_void_p
        cf.CFNotificationCenterPostNotification.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_bool]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        utf8 = 0x08000100
        name = cf.CFStringCreateWithCString(None, (signal or SIGNAL).encode(), utf8)
        obj = cf.CFStringCreateWithCString(None, request.encode(), utf8)
        cf.CFNotificationCenterPostNotification(cf.CFNotificationCenterGetDistributedCenter(),
                                                name, obj, None, True)
        cf.CFRelease(name)
        cf.CFRelease(obj)
        return True
    except Exception:
        return False


def ask_app(precise: bool, wait: float = None) -> dict | None:
    """One round trip to the app: its JSON answer, or None when it never came.

    The pipe lives in a directory made 0700 for this call and is removed with
    it. Opened read-write so there is always a writer and an early read is
    "nothing yet", not end-of-file; the app opens it write-only, non-blocking.
    """
    wait = WAIT_SECONDS if wait is None else wait
    folder = tempfile.mkdtemp(prefix="moe-loc-")
    fd = -1
    try:
        pipe = os.path.join(folder, "reply")
        os.mkfifo(pipe, 0o600)
        fd = os.open(pipe, os.O_RDWR | os.O_NONBLOCK)
        if not post(json.dumps({"reply": pipe, "precise": bool(precise)})):
            return None
        deadline = time.monotonic() + wait
        got = b""
        while b"\n" not in got:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            ready, _, _ = select.select([fd], [], [], left)
            if not ready:
                return None
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                continue
            if not chunk:
                return None
            got += chunk
        answer = json.loads(got.split(b"\n", 1)[0].decode("utf-8"))
        return answer if isinstance(answer, dict) else None
    except (OSError, ValueError):
        return None
    finally:
        if fd >= 0:
            os.close(fd)
        shutil.rmtree(folder, ignore_errors=True)


def handle_tool(params=None, **kwargs) -> str:
    """Hermes calls ``handler(args_dict, **kw)``. Always JSON, never raises."""
    try:
        args = params if isinstance(params, dict) else dict(kwargs)
        precise = args.get("precise") is True
        verdict = presence()
        if not verdict.get("live") or verdict.get("why") != _AT_THE_MAC:
            return _no("Not read: this is %s, and the Mac's location is only read while the person "
                       "is at the Mac in their own turn. Ask them where they are, or use what they "
                       "have already told you." % (verdict.get("why") or "not the person's own turn"),
                       "refused")
        answer = ask_app(precise)
        if answer is None:
            return _no("The Memoe app did not answer, so this Mac's location is not known. " + FALLBACK,
                       "no_answer")
        if answer.get("status") != "ok":
            return _no(str(answer.get("say") or ("No location (%s). " % answer.get("status")) + FALLBACK),
                       str(answer.get("status") or ""))
        place = {k: v for k, v in answer.items() if k != "status"}
        return _ok(place)
    except Exception as e:
        return _no("%s: %s" % (type(e).__name__, e))


def available() -> bool:
    return sys.platform == "darwin"
