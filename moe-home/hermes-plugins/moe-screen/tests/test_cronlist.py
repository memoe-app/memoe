"""The job list shows the other side's last run and the Mac-only note (D2)."""
from __future__ import annotations

import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, ".."))


def load():
    spec = importlib.util.spec_from_file_location("moe_screen_cronlist", os.path.join(PLUGIN, "cronlist.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def listing(*jobs):
    return json.dumps({"success": True, "count": len(jobs), "jobs": list(jobs)})


def test_a_newer_run_on_the_other_side_is_shown_and_an_older_one_is_not(tmp_path, monkeypatch):
    m = load()
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / "moe" / "cron-last").mkdir(parents=True)
    (tmp_path / "moe" / "cron-docs.json").write_text(json.dumps({"cron/aaaaaaaaaaaa": "m00000000009"}))
    (tmp_path / "moe" / "cron-last" / "aaaaaaaaaaaa.json").write_text(json.dumps(
        {"at": "2026-11-13T09:00:05-05:00", "side": "mac", "status": "ok", "said": "Three replies drafted."}))
    never_here = {"job_id": "m00000000009", "name": "Journalists", "last_run_at": None}
    out = json.loads(m.annotate("cronjob_manage", {"action": "list"}, listing(never_here)))
    seen = out["jobs"][0]["last_run_elsewhere"]
    assert seen == {"where": "on your Mac", "at": "2026-11-13T09:00:05-05:00", "status": "ok",
                    "said": "Three replies drafted."}
    ran_here_later = dict(never_here, last_run_at="2026-11-14T09:00:00-05:00")
    assert m.annotate("cronjob_manage", {"action": "list"}, listing(ran_here_later)) is None
    # Not a list, not the cron tool, not JSON: untouched.
    assert m.annotate("cronjob_manage", {"action": "create"}, listing(never_here)) is None
    assert m.annotate("terminal", {"action": "list"}, listing(never_here)) is None
    assert m.annotate("cronjob_manage", {"action": "list"}, "not json") is None


def test_a_mac_only_job_brings_the_plain_note(tmp_path, monkeypatch):
    m = load()
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    job = {"job_id": "m00000000001", "name": "Marketing", "state": "paused",
           "paused_reason": "Runs on your Mac only: it needs ~/moe-marketing, which is on the Mac and not here."}
    out = json.loads(m.annotate("cronjob_manage", {"action": "list"}, listing(job)))
    assert "runs on their Mac" in out["mac_only_note"] and "do not resume it here" in out["mac_only_note"]
