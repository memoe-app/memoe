"""What the agent's job list says about the OTHER side (owner decision D2,
2026-11-13; ticket #24).

Every one of the person's jobs is on both sides now (moeledger/cronjobs.py).
Two things about a job live only in the ledger, not in Hermes's own store,
so `cronjob_manage list` could not show them:

* **its last run on the other side** — `cronlast/<id>`, applied by the
  ledger reader to ``$HERMES_HOME/moe/cron-last/<id>.json``: when, how it
  went, where, and the first 2,000 characters of what it said. Added to a
  job as ``last_run_elsewhere`` when it is newer than the job's own
  ``last_run_at`` here, so "what did this morning's digest say?" has an
  answer on either side.
* **that it runs on the Mac only** — the copy on Away is paused with a
  reason that starts "Runs on your Mac only". The list then carries one
  plain ``note`` for the agent to pass on in general words.

A ``transform_tool_result`` hook: it only ever ADDS fields, and returns
None — the result untouched — on anything it does not recognise. Stdlib only.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

CRON_TOOLS = frozenset({"cronjob", "cronjob_manage"})
LAST_DIR = "cron-last"
MAP_FILE = "cron-docs.json"
MAC_ONLY_REASON = "Runs on your Mac only"     # moeledger.cronjobs.MAC_ONLY_REASON
WHERE = {"mac": "on your Mac", "away": "on Away"}
NOTE = ("Jobs whose paused_reason begins \"Runs on your Mac only\" need something that is only on "
        "the person's Mac. They are listed here so nothing is hidden, and they are never run here. "
        "If one comes up, tell the person plainly that it runs on their Mac whenever the Mac is on "
        "and awake; do not resume it here.")


def _hermes_home() -> str:
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def _read_json(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _when(value: Any):
    from datetime import datetime
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        at = datetime.fromisoformat(text)
    except ValueError:
        return None
    return at if at.tzinfo else at.astimezone()


def elsewhere(job: Dict[str, Any], doc_for: Dict[str, str], home: str) -> Optional[Dict[str, Any]]:
    """The other side's last run of ``job`` when it is newer than its run
    here, shaped for the agent; None otherwise."""
    job_id = str(job.get("job_id") or job.get("id") or "")
    doc = doc_for.get(job_id, job_id)
    data = _read_json(os.path.join(home, "moe", LAST_DIR, "%s.json" % doc))
    if not isinstance(data, dict) or data.get("side") not in WHERE:
        return None
    theirs = _when(data.get("at"))
    if theirs is None:
        return None
    ours = _when(job.get("last_run_at"))
    if ours is not None and ours >= theirs:
        return None
    return {"where": WHERE[data["side"]], "at": data["at"], "status": str(data.get("status") or ""),
            "said": str(data.get("said") or "")}


def annotate(tool_name=None, args=None, result=None, **_kwargs):
    """transform_tool_result for `cronjob_manage` list."""
    if tool_name not in CRON_TOOLS or not isinstance(result, str):
        return None
    if str((args or {}).get("action") or "").strip().lower() != "list":
        return None
    try:
        data = json.loads(result)
    except ValueError:
        return None
    jobs = data.get("jobs") if isinstance(data, dict) else None
    if not isinstance(jobs, list) or not jobs:
        return None
    home = _hermes_home()
    mapping = _read_json(os.path.join(home, "moe", MAP_FILE))
    doc_for = {}
    if isinstance(mapping, dict):
        doc_for = {str(v): str(k)[len("cron/"):] for k, v in mapping.items()
                   if isinstance(k, str) and k.startswith("cron/")}
    changed = False
    mac_only = False
    for job in jobs:
        if not isinstance(job, dict):
            continue
        try:
            other = elsewhere(job, doc_for, home)
        except Exception:  # noqa: BLE001 — a list is never refused for this
            logger.debug("moe-screen: last run elsewhere unreadable", exc_info=True)
            other = None
        if other:
            job["last_run_elsewhere"] = other
            changed = True
        if str(job.get("paused_reason") or "").startswith(MAC_ONLY_REASON):
            mac_only = True
    if mac_only:
        data["mac_only_note"] = NOTE
        changed = True
    return json.dumps(data, ensure_ascii=False) if changed else None
