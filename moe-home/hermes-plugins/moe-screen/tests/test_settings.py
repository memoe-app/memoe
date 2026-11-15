"""`moe_settings_find` / `_change` / `_show` (docs/SETTINGS-ASSISTANT.md).

Find reads the published file and lands on the words people use. Change and
show ask the app only for the person's own turn at the Mac, never change a
setting that is the person's to flip, and never send a value the setting
does not take. Every refusal asserts the side effect — the app was NOT
asked — not just the verdict.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import types

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))

CATALOGUE = {"version": 1, "settings": [
    {"id": "replyChime", "title": "Ding when a written answer is ready", "page": "Voice", "under": "More",
     "does": "One soft note when a written answer is ready.", "who": "moe", "kind": "toggle", "value": "on",
     "says": ["stop dinging", "the ding", "that sound", "the chime"]},
    {"id": "replyLength", "title": "How much Moe says", "page": "Voice",
     "does": "How long Moe's answers are.", "who": "moe", "kind": "choice", "value": "short",
     "choices": [{"value": "short", "label": "Short"}, {"value": "balanced", "label": "Balanced"},
                 {"value": "detailed", "label": "Detailed"}],
     "says": ["too long", "talks too much", "too chatty", "more detail"]},
    {"id": "replyReadingSeconds", "title": "How long the panel stays", "page": "Voice", "under": "More",
     "does": "How long an answer stays on screen.", "who": "moe", "kind": "number", "value": "12",
     "min": 4, "max": 60, "unit": "seconds", "says": ["disappears too fast"]},
    {"id": "screenContext", "title": "Let Moe see your screen", "page": "Permissions",
     "does": "Moe looks at the screen when you ask.", "who": "person", "kind": "toggle", "value": "on",
     "says": ["stop looking at my screen", "watching me"]},
]}


def load():
    spec = importlib.util.spec_from_file_location("moe_screen_settings", os.path.join(PLUGIN, "settings.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class App:
    """The app's half: answers down the pipe the request names."""

    def __init__(self, answer):
        self.answer = answer
        self.requests = []

    def post(self, raw):
        request = json.loads(raw)
        self.requests.append(request)
        if self.answer is None:
            return True
        fd = os.open(request["reply"], os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(fd, (json.dumps(self.answer) + "\n").encode())
        finally:
            os.close(fd)
        return True


@pytest.fixture
def tool(monkeypatch, tmp_path):
    (tmp_path / "settings-catalogue.json").write_text(json.dumps(CATALOGUE))
    monkeypatch.setenv("MOE_HOME", str(tmp_path))
    mod = load()
    monkeypatch.setattr(mod, "WAIT_SECONDS", 0.4)
    return mod


def app(tool, monkeypatch, answer):
    a = App(answer)
    monkeypatch.setattr(tool, "post", a.post)
    return a


def verdict(monkeypatch, v):
    fake = types.ModuleType("tools.browser_chrome_extension")
    fake.turn_presence = lambda: v
    monkeypatch.setitem(sys.modules, "tools", sys.modules.get("tools") or types.ModuleType("tools"))
    monkeypatch.setitem(sys.modules, "tools.browser_chrome_extension", fake)


PERSON = {"live": True, "why": "the person's own turn"}
PHONE = {"live": True, "why": "the person's message"}
CRON = {"live": False, "why": "a scheduled job"}


def find(mod, q):
    return json.loads(mod.handle_find({"query": q}))


def change(mod, **a):
    return json.loads(mod.handle_change(a))


def show(mod, **a):
    return json.loads(mod.handle_show(a))


# --- find -----------------------------------------------------------------

@pytest.mark.parametrize("words,first", [
    ("can you stop dinging at me", "replyChime"),
    ("you talk too much", "replyLength"),
    ("your answers are too long", "replyLength"),
    ("the answer disappears too fast", "replyReadingSeconds"),
    ("stop looking at my screen", "screenContext"),
])
def test_the_persons_own_words_land_on_the_switch(tool, words, first):
    out = find(tool, words)
    assert out["success"] is True
    assert out["result"]["matches"][0]["id"] == first


def test_a_hit_carries_what_the_brain_needs_and_nothing_else(tool):
    hit = find(tool, "too chatty")["result"]["matches"][0]
    assert hit["value"] == "short" and hit["who"] == "moe"
    assert [c["value"] for c in hit["choices"]] == ["short", "balanced", "detailed"]
    assert "says" not in hit


def test_no_match_returns_every_setting_by_page_not_none(tool):
    out = find(tool, "zebra quantum")["result"]
    assert out["matches"] == []
    assert "Voice: Ding when a written answer is ready; How much Moe says" in out["all_settings"]
    assert "Permissions: Let Moe see your screen" in out["all_settings"]


def test_no_published_file_says_so(tool, monkeypatch, tmp_path):
    monkeypatch.setenv("MOE_HOME", str(tmp_path / "nowhere"))
    out = find(tool, "the ding")
    assert out["success"] is False and out["status"] == "no_catalogue"


# --- change ---------------------------------------------------------------

def test_the_persons_turn_at_the_mac_asks_the_app(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, {"status": "ok", "title": "Ding when a written answer is ready",
                                "was": "on", "now": "off"})
    out = change(tool, id="replyChime", value="off")
    assert out["success"] is True and out["result"]["now"] == "off"
    assert [(r["action"], r["id"], r["value"]) for r in a.requests] == [("change", "replyChime", "off")]


def test_a_choice_is_sent_by_its_value_even_when_named_by_its_label(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, {"status": "ok"})
    change(tool, id="replyLength", value="Balanced")
    assert a.requests[0]["value"] == "balanced"


@pytest.mark.parametrize("who", [PHONE, CRON, {}])
def test_no_one_at_the_mac_changes_nothing(tool, monkeypatch, who):
    verdict(monkeypatch, who)
    a = app(tool, monkeypatch, {"status": "ok"})
    out = change(tool, id="replyChime", value="off")
    assert out["success"] is False and out["status"] == "refused"
    assert a.requests == []


def test_the_persons_switch_is_never_changed_by_moe(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, {"status": "ok"})
    out = change(tool, id="screenContext", value="off")
    assert out["success"] is False and out["status"] == "theirs"
    assert "moe_settings_show" in out["error"]
    assert a.requests == []


@pytest.mark.parametrize("sid,value", [("replyChime", "loud"), ("replyLength", "huge"),
                                       ("replyReadingSeconds", "600"), ("replyReadingSeconds", "soon")])
def test_a_value_the_setting_does_not_take_is_never_sent(tool, monkeypatch, sid, value):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, {"status": "ok"})
    out = change(tool, id=sid, value=value)
    assert out["success"] is False and out["status"] == "bad_value"
    assert a.requests == []


def test_an_unknown_id_is_never_sent(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, {"status": "ok"})
    assert change(tool, id="launchMissiles", value="on")["status"] == "unknown"
    assert a.requests == []


def test_already_set_asks_nothing(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, {"status": "ok"})
    out = change(tool, id="replyChime", value="on")
    assert out["success"] is True and out["result"]["changed"] is False
    assert a.requests == []


def test_the_apps_refusal_is_passed_on(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    app(tool, monkeypatch, {"status": "refused", "say": "No turn of the person's is in flight."})
    out = change(tool, id="replyChime", value="off")
    assert out["success"] is False and out["error"] == "No turn of the person's is in flight."


def test_a_silent_app_is_not_a_success(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    app(tool, monkeypatch, None)
    out = change(tool, id="replyChime", value="off")
    assert out["success"] is False and out["status"] == "no_answer"


# --- show -----------------------------------------------------------------

def test_show_opens_any_setting_for_the_person_at_the_mac(tool, monkeypatch):
    verdict(monkeypatch, PERSON)
    a = app(tool, monkeypatch, {"status": "ok", "opened": "Permissions"})
    assert show(tool, id="screenContext")["success"] is True
    assert [(r["action"], r["id"]) for r in a.requests] == [("show", "screenContext")]


@pytest.mark.parametrize("who", [PHONE, CRON])
def test_show_from_elsewhere_names_the_place_and_opens_nothing(tool, monkeypatch, who):
    verdict(monkeypatch, who)
    a = app(tool, monkeypatch, {"status": "ok"})
    out = show(tool, id="replyChime")
    assert out["success"] is False and "Settings › Voice" in out["error"]
    assert a.requests == []


def test_the_four_tools_share_the_settings_toolset(tool):
    assert tool.TOOLSET == "moe_settings"
    assert [t[0] for t in tool.TOOLS] == ["moe_settings_find", "moe_settings_change", "moe_settings_show"]
