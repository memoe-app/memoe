"""Memoe's own settings, for the brain: find one, change one, open one
(docs/SETTINGS-ASSISTANT.md).

The owner, 2026-11-14: when someone does not want something Memoe does, Moe
should know there is a switch for it — even when they never say "setting" —
offer it, and either flip it or open Settings exactly there.

* ``moe_settings_find(query)`` reads ``settings-catalogue.json``, which the
  app rewrites on launch and whenever a value changes. A file, so it works
  on any turn and needs no app round trip; ranked on the row's title, what
  it does, and the words people use when it bothers them. Nothing matching
  returns the whole map rather than "no such setting", because a miss here
  is a search failure, not a fact.
* ``moe_settings_change(id, value)`` and ``moe_settings_show(id|page)`` ask
  the app, which applies the change through its own setter or opens
  Settings on the row. Like ``moe_location`` the answer comes back down a
  named pipe only this user can open.

What these refuse, each tested:

* **Change and show on a turn nobody is at the Mac for.** Presence is the
  fork's verdict, fail closed, as in open_settings.py. The app checks again
  and its check is the one that counts: the signal is a distributed
  notification anything on this Mac can post.
* **Changing a setting that is the person's to flip** (``who: person``:
  privacy, screen control, sending, deleting, money, the brain). Refused
  here so the model hears why at once, and refused by the app whatever the
  request says.
* **A value the setting does not take.** The choices come back with the
  refusal, so the next try is right.
"""
from __future__ import annotations

import json
import os
import re
import select
import shutil
import tempfile
import time

try:
    from . import location as _location
except ImportError:  # loaded by path (the tests): location.py sits beside this file
    import importlib.util as _util
    _spec = _util.spec_from_file_location(
        "moe_screen_location", os.path.join(os.path.dirname(os.path.abspath(__file__)), "location.py"))
    _location = _util.module_from_spec(_spec)
    _spec.loader.exec_module(_location)

TOOLSET = "moe_settings"   # the same toolset as moe_open_settings: the Mac's list only
FIND_TOOL = "moe_settings_find"
CHANGE_TOOL = "moe_settings_change"
SHOW_TOOL = "moe_settings_show"
TOOL_NAMES = (FIND_TOOL, CHANGE_TOOL, SHOW_TOOL)

#: The distributed notification the app listens for
#: (Sources/Moe/Settings/SettingsBridge.swift); the object is the request.
SIGNAL = "com.moe.settings"
WAIT_SECONDS = 10.0
CATALOGUE = "settings-catalogue.json"
MAX_HITS = 5

_AT_THE_MAC = "the person's own turn"

FIND_SCHEMA = {
    "name": FIND_TOOL,
    "description": (
        "Search Memoe's own settings: the switches for how Moe talks, listens, shows answers, "
        "reminds, records meetings and so on. Use it whenever the person is bothered by, or "
        "wants to change, something Memoe itself does, even if they never say 'setting' "
        "(\"stop dinging\", \"you talk too much\", \"the notch keeps opening\"). Pass their own "
        "words. Each hit has its on-screen title, the page it is on, what it does, its current "
        "value, and `who`: `moe` means you may change it with moe_settings_change once they "
        "say yes; `person` means offer to open it with moe_settings_show and let them flip it."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string",
                      "description": "What the person said or wants, in their words."},
        },
        "required": ["query"],
    },
}

CHANGE_SCHEMA = {
    "name": CHANGE_TOOL,
    "description": (
        "Change one of Memoe's settings, by the `id` moe_settings_find gave. Only for settings "
        "whose `who` is `moe`, and only after the person said yes to that change in this "
        "conversation. A change that makes Moe do, say or listen more (speaking aloud, "
        "bringing things up, a longer listening window, a new key) also shows the person a "
        "confirmation first; a quieter one does not. Afterwards, say in one line what you "
        "changed and that you can put it back. Works while the person is at their Mac."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "id": {"type": "string", "description": "The setting's `id` from moe_settings_find."},
            "value": {"type": "string",
                      "description": "on/off for a switch; a choice's `value`; a number in range."},
        },
        "required": ["id", "value"],
    },
}

SHOW_SCHEMA = {
    "name": SHOW_TOOL,
    "description": (
        "Open Memoe's Settings on the person's Mac, on the page of a setting and with its row "
        "highlighted, so they can see or flip it themselves. Use it for settings whose `who` is "
        "`person`, or when they would rather do it themselves. Call it after they said yes."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "id": {"type": "string", "description": "The setting's `id` from moe_settings_find."},
        },
        "required": ["id"],
    },
}


def _ok(result) -> str:
    return json.dumps({"success": True, "result": result})


def _no(msg: str, status: str = "", **extra) -> str:
    out = {"success": False, "error": msg}
    if status:
        out["status"] = status
    out.update(extra)
    return json.dumps(out)


def moe_home() -> str:
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def load(path: str | None = None) -> list:
    """The published settings, or [] when the app has not written them."""
    path = path or os.path.join(moe_home(), CATALOGUE)
    try:
        with open(path, encoding="utf-8") as f:
            rows = json.load(f).get("settings")
        return [r for r in rows if isinstance(r, dict) and r.get("id")] if isinstance(rows, list) else []
    except (OSError, ValueError, AttributeError):
        return []


_STOP = frozenset("""a an and are at be but by can do does don't dont for from have how i i'm im in is it
it's its just keep keeps me my no not of on or please so stop that the them there this to too turn
want when why will with you your moe memoe""".split())


def _words(text: str) -> list:
    return [w for w in re.findall(r"[a-z0-9']+", (text or "").lower()) if w not in _STOP]


def _stem(w: str) -> str:
    for end in ("ing", "ed", "es", "s"):
        if len(w) > len(end) + 2 and w.endswith(end):
            return w[: -len(end)]
    return w


def score(row: dict, query: str) -> int:
    """How well `query` lands on `row`. A phrase people say counts most."""
    q = (query or "").lower().strip()
    qwords = {_stem(w) for w in _words(q)}
    if not qwords:
        return 0
    s = 0
    says = [str(x).lower() for x in (row.get("says") or [])]
    for phrase in says:
        if phrase and (phrase in q or q in phrase):
            s += 8
        pw = {_stem(w) for w in _words(phrase)}
        if pw:
            s += 3 * len(qwords & pw)
    s += 3 * len(qwords & {_stem(w) for w in _words(row.get("title", ""))})
    s += len(qwords & {_stem(w) for w in _words(row.get("does", ""))})
    s += len(qwords & {_stem(w) for w in _words("%s %s" % (row.get("page", ""), row.get("under", "")))})
    return s


def public(row: dict) -> dict:
    keep = ("id", "title", "page", "under", "does", "value", "who", "kind", "choices", "min", "max", "unit")
    return {k: row[k] for k in keep if k in row}


def the_map(rows: list) -> str:
    pages: dict = {}
    for r in rows:
        pages.setdefault(r.get("page", "?"), []).append(r.get("title", r["id"]))
    return "\n".join("%s: %s" % (p, "; ".join(t)) for p, t in pages.items())


def find(query: str, rows: list) -> dict:
    ranked = sorted(((score(r, query), i, r) for i, r in enumerate(rows)), key=lambda t: (-t[0], t[1]))
    hits = [public(r) for s, _, r in ranked if s > 0][:MAX_HITS]
    if hits:
        return {"matches": hits}
    return {"matches": [],
            "note": "Nothing matched those words. Every setting is below by page; if one fits, "
                    "search again with its title. If none does, say Memoe has no switch for it.",
            "all_settings": the_map(rows)}


def normalise(row: dict, raw) -> str | None:
    """The value as the app will take it, or None when the row does not take it."""
    v = str(raw if raw is not None else "").strip().lower()
    kind = row.get("kind")
    if kind == "toggle":
        if v in ("on", "true", "yes", "1", "enable", "enabled"):
            return "on"
        if v in ("off", "false", "no", "0", "disable", "disabled"):
            return "off"
        return None
    if kind == "choice":
        for c in row.get("choices") or []:
            if v in (str(c.get("value", "")).lower(), str(c.get("label", "")).lower()):
                return str(c.get("value"))
        return None
    if kind == "number":
        try:
            n = float(v)
        except ValueError:
            return None
        lo, hi = row.get("min"), row.get("max")
        if (lo is not None and n < lo) or (hi is not None and n > hi):
            return None
        return str(int(n)) if n == int(n) else str(n)
    return None


def ask_app(request: dict, wait: float = None) -> dict | None:
    """One round trip to the app, as moe_location makes it, under SIGNAL."""
    wait = WAIT_SECONDS if wait is None else wait
    folder = tempfile.mkdtemp(prefix="moe-set-")
    fd = -1
    try:
        pipe = os.path.join(folder, "reply")
        os.mkfifo(pipe, 0o600)
        fd = os.open(pipe, os.O_RDWR | os.O_NONBLOCK)
        if not post(json.dumps(dict(request, reply=pipe))):
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


def post(request: str) -> bool:
    """The same CoreFoundation post as moe_location's, under this SIGNAL."""
    return _location.post(request, SIGNAL)


def presence() -> dict:
    return _location.presence()


def _at_the_mac() -> str | None:
    """None when the person is at the Mac in their own turn, else why not."""
    verdict = presence()
    if verdict.get("live") and verdict.get("why") == _AT_THE_MAC:
        return None
    return verdict.get("why") or "not the person's own turn"


def _args(params, kwargs) -> dict:
    return params if isinstance(params, dict) else dict(kwargs)


def _row(rows: list, sid: str) -> dict | None:
    return next((r for r in rows if r.get("id") == sid), None)


def handle_find(params=None, **kwargs) -> str:
    try:
        query = str(_args(params, kwargs).get("query") or "").strip()
        rows = load()
        if not rows:
            return _no("Memoe's settings list is not available on this machine, so they cannot be "
                       "searched here. Tell the person where to look: Settings in the Memoe menu.",
                       "no_catalogue")
        if not query:
            return _no("Say what to look for, in the person's words.", "no_query")
        return _ok(find(query, rows))
    except Exception as e:
        return _no("%s: %s" % (type(e).__name__, e))


def _app_reply(answer: dict | None, what: str) -> str:
    if answer is None:
        return _no("The Memoe app did not answer, so nothing was %s. Tell the person where it is "
                   "instead (the page and the row's title)." % what, "no_answer")
    if answer.get("status") != "ok":
        return _no(str(answer.get("say") or "The app refused."), str(answer.get("status") or "refused"))
    return _ok({k: v for k, v in answer.items() if k != "status"})


def handle_change(params=None, **kwargs) -> str:
    try:
        args = _args(params, kwargs)
        sid = str(args.get("id") or "").strip()
        rows = load()
        row = _row(rows, sid)
        if row is None:
            return _no("No setting has the id %r. Use moe_settings_find and pass a hit's `id`." % sid,
                       "unknown")
        if row.get("who") != "moe":
            return _no("%r is the person's to change, not yours: offer to open it with "
                       "moe_settings_show and let them flip it." % row.get("title"), "theirs",
                       page=row.get("page"))
        value = normalise(row, args.get("value"))
        if value is None:
            return _no("%r does not take %r." % (row.get("title"), args.get("value")), "bad_value",
                       **{k: row[k] for k in ("kind", "choices", "min", "max", "unit") if k in row})
        if value == str(row.get("value")):
            return _ok({"title": row.get("title"), "now": value, "changed": False,
                        "say": "It is already %s." % value})
        why = _at_the_mac()
        if why:
            return _no("Not changed: this is %s, and Memoe's settings change only while the person is "
                       "at their Mac. Tell them it is %r on %s, and that you can change it when they "
                       "are at the Mac." % (why, row.get("title"), row.get("page")), "refused")
        return _app_reply(ask_app({"action": "change", "id": sid, "value": value}), "changed")
    except Exception as e:
        return _no("%s: %s" % (type(e).__name__, e))


def handle_show(params=None, **kwargs) -> str:
    try:
        sid = str(_args(params, kwargs).get("id") or "").strip()
        row = _row(load(), sid)
        if row is None:
            return _no("No setting has the id %r. Use moe_settings_find and pass a hit's `id`." % sid,
                       "unknown")
        why = _at_the_mac()
        if why:
            return _no("Not opened: this is %s, and Settings only opens on the Mac's screen while the "
                       "person is there. Tell them it is %r on Settings › %s." % (
                           why, row.get("title"), row.get("page")), "refused")
        return _app_reply(ask_app({"action": "show", "id": sid}), "opened")
    except Exception as e:
        return _no("%s: %s" % (type(e).__name__, e))


def available() -> bool:
    return _location.available()


TOOLS = (
    (FIND_TOOL, FIND_SCHEMA, handle_find, "🔎"),
    (CHANGE_TOOL, CHANGE_SCHEMA, handle_change, "🎚️"),
    (SHOW_TOOL, SHOW_SCHEMA, handle_show, "⚙️"),
)
