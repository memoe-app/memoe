"""Both sides claim each run (D4): the Mac's half (claim.py).

Before D4 the Mac never asked, so a run the cloud computer had claimed while
the Mac slept was run again on wake. Proven here with a stand-in for the app
(`CronClaims.swift`) that answers beside the request file.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import threading
import time
import types
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))


def load():
    pkg = types.ModuleType("moe_screen_claimpkg")
    pkg.__path__ = [PLUGIN]
    sys.modules["moe_screen_claimpkg"] = pkg
    for name in ("ran", "claim"):
        spec = importlib.util.spec_from_file_location("moe_screen_claimpkg." + name,
                                                      os.path.join(PLUGIN, name + ".py"))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = mod
        spec.loader.exec_module(mod)
    return sys.modules["moe_screen_claimpkg.claim"]


JOB = {"id": "a1b2c3d4e5f6", "name": "Journalists", "prompt": "Draft replies to the journalists.",
       "schedule": {"kind": "interval", "minutes": 60}}


def app(claim, verdict, won=False, delay=0.3):
    """The app: answers the first request it sees, like CronClaims.serve."""
    def run():
        d = claim.claims_dir()
        for _ in range(100):
            for name in os.listdir(d) if os.path.isdir(d) else ():
                if name.endswith(".ask.json") and not os.path.exists(
                        os.path.join(d, name.replace(".ask.", ".answer."))):
                    time.sleep(delay)
                    with open(os.path.join(d, name)) as f:
                        ask = json.load(f)
                    with open(os.path.join(d, name.replace(".ask.", ".answer.")), "w") as f:
                        json.dump({"job": ask["job"], "occurrence": ask["occurrence"],
                                   "verdict": verdict, "won": won, "epoch": 3}, f)
                    return
            time.sleep(0.05)
    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


def alive(claim):
    os.makedirs(claim.claims_dir(), exist_ok=True)
    open(os.path.join(claim.claims_dir(), claim.ALIVE_FILENAME), "w").close()


def test_a_run_another_device_holds_is_skipped_and_a_won_one_runs(tmp_path, monkeypatch):
    claim = load()
    monkeypatch.setenv("MOE_HOME", str(tmp_path))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))     # no machine credential here
    alive(claim)
    app(claim, "held")
    out = claim.before_run(job=dict(JOB), job_id=JOB["id"], job_name=JOB["name"])
    assert out == {"action": "skip", "reason": "this run is already being done on the person's other computer"}
    # The same occurrence asked again is answered from the file, no second ask.
    assert claim.before_run(job=dict(JOB))["action"] == "skip"
    assert len([n for n in os.listdir(claim.claims_dir()) if n.endswith(".ask.json")]) == 1

    other = dict(JOB, name="Morning digest", id="b1b2c3d4e5f6")
    app(claim, "won", won=True)
    assert claim.before_run(job=other) is None
    assert claim.status_for(other) == "ok"


def test_no_answer_runs_it_and_says_ran_offline(tmp_path, monkeypatch):
    claim = load()
    monkeypatch.setenv("MOE_HOME", str(tmp_path))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))
    alive(claim)
    monkeypatch.setattr(claim, "WAIT_S", 0.3)
    started = time.monotonic()
    assert claim.before_run(job=dict(JOB)) is None
    assert time.monotonic() - started < 3
    assert claim.status_for(JOB) == claim.OFFLINE_STATUS
    # The app answering "offline" (the edge unreachable) says the same.
    other = dict(JOB, name="Weekly review", id="c1b2c3d4e5f6")
    app(claim, "offline", delay=0)
    assert claim.before_run(job=other) is None
    assert claim.status_for(other) == claim.OFFLINE_STATUS


def test_an_app_that_does_not_answer_claims_costs_nothing(tmp_path, monkeypatch):
    claim = load()
    monkeypatch.setenv("MOE_HOME", str(tmp_path))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))
    started = time.monotonic()
    assert claim.before_run(job=dict(JOB)) is None          # no `alive`: an older app
    assert time.monotonic() - started < 0.5
    assert not os.path.isdir(claim.claims_dir()) or not os.listdir(claim.claims_dir())
    assert claim.status_for(JOB) == "ok"
    # A stale `alive` (the app quit an hour ago) is the same.
    alive(claim)
    old = time.time() - 3600
    os.utime(os.path.join(claim.claims_dir(), claim.ALIVE_FILENAME), (old, old))
    assert claim.before_run(job=dict(JOB)) is None
    # Moe's own jobs and the machine are not this file's.
    assert claim.before_run(job=dict(JOB, name="moe-situations")) is None


def test_the_machine_never_asks_through_the_app(tmp_path, monkeypatch):
    claim = load()
    monkeypatch.setenv("MOE_HOME", str(tmp_path))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))
    vault = tmp_path / "hermes" / "moe"
    vault.mkdir(parents=True)
    (vault / "credential.json").write_text(json.dumps({"token": "x" * 44}))
    (vault / "edge.json").write_text(json.dumps({"url": "https://edge.example"}))
    alive(claim)
    assert claim.before_run(job=dict(JOB)) is None
    assert [n for n in os.listdir(claim.claims_dir()) if n.endswith(".ask.json")] == []
