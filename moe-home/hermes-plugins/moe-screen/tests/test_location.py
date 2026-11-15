"""`moe_location`: the Mac's location reaches a turn only when the person is at
the Mac in their own turn, travels down a pipe and never a file, and every way
of not knowing is a plain sentence rather than a guess.

Every refusal asserts the side effect — the app was NOT asked — not just the
verdict. Called the way Hermes calls a plugin tool: one dict, first. The app
is stood in for by a `post` that answers down the real pipe, the way
LocationBridge.write(_:toPipe:) does; no test reaches CoreLocation or posts a
real notification.
"""
from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
import types

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))
ROOT = os.path.normpath(os.path.join(PLUGIN, "..", "..", ".."))

PLACE = {
    "status": "ok",
    "source": "this Mac's own location (macOS Location Services), not the internet connection",
    "city": "Lakewood", "region": "NJ", "country": "United States", "country_code": "US",
    "time_zone": "America/New_York",
    "latitude": 40.08, "longitude": -74.21, "precision": "rounded to about 1 km",
    "accuracy_m": 65, "age_s": 3,
}
DENIED = {"status": "denied",
          "say": "Location is switched off for Memoe on this Mac (System Settings › Privacy & Security › "
                 "Location Services › Memoe), so Memoe cannot tell where it is. Do not guess: ask the "
                 "person where they are, or use the rough place their internet connection gives and say "
                 "that is what you used."}


def load():
    spec = importlib.util.spec_from_file_location("moe_screen_location", os.path.join(PLUGIN, "location.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class App:
    """The app's half: answers down the pipe the request names, or stays quiet."""

    def __init__(self, answer):
        self.answer = answer
        self.requests = []
        self.pipes = []

    def post(self, raw):
        request = json.loads(raw)
        self.requests.append(request)
        path = request["reply"]
        st = os.lstat(path)
        self.pipes.append({"path": path, "fifo": stat.S_ISFIFO(st.st_mode), "mode": stat.S_IMODE(st.st_mode),
                           "dir_mode": stat.S_IMODE(os.lstat(os.path.dirname(path)).st_mode)})
        if self.answer is None:
            return True
        fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, (json.dumps(self.answer) + "\n").encode())
        finally:
            os.close(fd)
        return True


@pytest.fixture
def tool(monkeypatch):
    mod = load()
    monkeypatch.setattr(mod, "WAIT_SECONDS", 0.4)
    return mod


def app(tool, monkeypatch, answer):
    a = App(answer)
    monkeypatch.setattr(tool, "post", a.post)
    return a


def verdict(monkeypatch, v):
    """A stand-in for the fork's tools.browser_chrome_extension."""
    fake = types.ModuleType("tools.browser_chrome_extension")
    fake.turn_presence = lambda: v
    pkg = sys.modules.get("tools") or types.ModuleType("tools")
    monkeypatch.setitem(sys.modules, "tools", pkg)
    monkeypatch.setitem(sys.modules, "tools.browser_chrome_extension", fake)


def call(mod, **args):
    return json.loads(mod.handle_tool(args))


PERSON = {"live": True, "why": "the person's own turn"}


def test_the_persons_turn_gets_the_place_the_app_gave(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, PLACE)
    out = call(tool)
    assert out["success"] is True
    assert out["result"] == {k: v for k, v in PLACE.items() if k != "status"}
    assert out["result"]["city"] == "Lakewood" and out["result"]["latitude"] == 40.08
    assert [r["precise"] for r in a.requests] == [False]


def test_precise_is_passed_on_only_when_it_is_true(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, PLACE)
    call(tool, precise=True)
    call(tool, precise="yes")   # not a boolean: about 1 km
    call(tool, precise=1)
    assert [r["precise"] for r in a.requests] == [True, False, False]


@pytest.mark.parametrize("v", [
    {"live": True, "why": "the person's message"},          # a chat platform: the phone
    {"live": False, "why": "a scheduled job"},
    {"live": False, "why": "a background note from the app"},
    {"live": False},
    {},
    None,
    "yes",
])
def test_a_turn_nobody_is_at_the_mac_for_never_asks_the_app(tool, monkeypatch, v):
    verdict(monkeypatch, v)
    a = app(tool, monkeypatch, PLACE)
    out = call(tool)
    assert out["success"] is False and out["status"] == "refused"
    assert "only read while the person is at the Mac" in out["error"]
    assert "Lakewood" not in json.dumps(out)
    assert a.requests == []


def test_a_fork_without_presence_fails_closed(tool, monkeypatch):
    monkeypatch.setitem(sys.modules, "tools", types.ModuleType("tools"))
    monkeypatch.delitem(sys.modules, "tools.browser_chrome_extension", raising=False)
    a = app(tool, monkeypatch, PLACE)
    out = call(tool)
    assert out["success"] is False and a.requests == []


def test_permission_off_is_the_apps_plain_sentence_never_a_place(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    app(tool, monkeypatch, DENIED)
    out = call(tool)
    assert out == {"success": False, "status": "denied", "error": DENIED["say"]}
    assert "result" not in out


@pytest.mark.parametrize("status", ["asked", "services_off", "restricted", "unavailable", "refused"])
def test_every_other_way_of_not_knowing_is_a_failure_with_its_reason(tool, monkeypatch, status):
    verdict(monkeypatch, PERSON)
    app(tool, monkeypatch, {"status": status, "say": "Because of %s." % status})
    out = call(tool)
    assert out == {"success": False, "status": status, "error": "Because of %s." % status}


def test_a_status_with_no_sentence_still_says_not_to_guess(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    app(tool, monkeypatch, {"status": "mystery"})
    out = call(tool)
    assert out["success"] is False and "Do not guess" in out["error"]


def test_an_app_that_never_answers_is_said_so_and_does_not_hang(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, None)
    out = call(tool)
    assert out["success"] is False and out["status"] == "no_answer"
    assert "did not answer" in out["error"] and "Do not guess" in out["error"]
    assert len(a.requests) == 1


def test_an_app_that_cannot_be_reached_is_the_same_sentence(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    monkeypatch.setattr(tool, "post", lambda raw: False)
    out = call(tool)
    assert out["success"] is False and out["status"] == "no_answer"


def test_the_answer_travels_down_a_private_pipe_that_is_gone_afterwards(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, PLACE)
    assert call(tool)["success"] is True
    (pipe,) = a.pipes
    assert pipe["fifo"] is True, "a regular file would put the place on disk"
    assert pipe["mode"] == 0o600 and pipe["dir_mode"] == 0o700
    assert not os.path.exists(pipe["path"]) and not os.path.exists(os.path.dirname(pipe["path"]))


def test_the_pipe_is_removed_when_nothing_came(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, None)
    call(tool)
    assert not os.path.exists(os.path.dirname(a.pipes[0]["path"]))


def test_garbage_down_the_pipe_is_no_answer(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = App(None)

    def post(raw):
        a.post(raw)
        fd = os.open(json.loads(raw)["reply"], os.O_WRONLY | os.O_NONBLOCK)
        os.write(fd, b"not json\n")
        os.close(fd)
        return True
    monkeypatch.setattr(tool, "post", post)
    out = call(tool)
    assert out["success"] is False and out["status"] == "no_answer"


def test_never_raises_whatever_it_is_handed(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    app(tool, monkeypatch, PLACE)
    for params in (None, "x", 3, []):
        assert json.loads(tool.handle_tool(params))["success"] in (True, False)


def test_the_tool_keeps_nothing(tool):
    """No log line, no file, no memory write, no network: the source has none
    of the ways to keep or forward a place."""
    with open(os.path.join(PLUGIN, "location.py")) as f:
        src = f.read()
    for word in ("logging", "logger", "print(", "urllib", "requests", "socket", "open("):
        assert word not in src.replace("os.open(", ""), word


def test_the_signal_and_names_match_the_app_and_the_config(tool):
    with open(os.path.join(ROOT, "Sources", "Moe", "Location", "LocationBridge.swift")) as f:
        swift = f.read()
    assert 'Notification.Name("%s")' % tool.SIGNAL in swift
    assert '"%s"' % tool.TOOL_NAME in swift
    with open(os.path.join(ROOT, "moe-home", "hermes", "configure-hermes.py")) as f:
        assert 'LOCATION_TOOLSET = "%s"' % tool.TOOLSET in f.read()
    with open(os.path.join(PLUGIN, "adapter.py")) as f:
        assert "_location.handle_tool" in f.read()
    with open(os.path.join(ROOT, "Sources", "Moe", "Brain", "BrainPrompt.swift")) as f:
        assert tool.TOOL_NAME in f.read()
