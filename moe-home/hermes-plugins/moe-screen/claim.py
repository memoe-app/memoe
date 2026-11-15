"""The Mac claims each run before it fires (owner decision D4, 2026-11-13).

docs/ONE-AGENT-SYNC-2026-11-13.md §4.5. Until D4 the Mac never asked: it
fired and then said `ran`, and the machine asked first. So a run the cloud
computer had already claimed while the Mac slept was run AGAIN by the Mac on
wake — whatever it did (a message sent, a reply drafted) done twice.

Now both sides claim. This is the Mac's half, a ``pre_cron_run`` hook (the
fork's seam, Hermes ``cron/scheduler.py``): before a job of the person's
fires, ask the edge "may I run this occurrence?". The answer arrives through
the app, because the device credential lives in its keychain and never on
disk: this writes one small request file into ``~/.moe/cloud/claims/`` and
the app (`CronClaims.swift`, `CloudSync`) answers beside it within a second
or two.

* **another device has it** (`held`, or `ran` by somebody else): this run is
  skipped, silent — the other side ran it or is running it;
* **won**, or anything else: it runs;
* **no answer** — the app is not running, is too old to answer, or the edge
  cannot be reached: it **runs anyway**, and the `ran` it reports afterwards
  says ``ran-offline``, so the one place exactly-once becomes at-least-once is
  written down (§4.3.5). A reminder is never lost to a claim.

The wait is only taken when the app has said, recently, that it answers
(`alive`), so a Mac on an older app pays nothing. The machine is not this
file's: its travelled copies carry their own claim (`moe-claim-*.py`).

Stdlib only; never raises.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
from datetime import datetime, timezone

from . import ran as _ran

logger = logging.getLogger(__name__)

CLAIMS_DIRNAME = os.path.join("cloud", "claims")
ALIVE_FILENAME = "alive"
#: The app touches ``alive`` at launch and on every sync (five minutes), so
#: fifteen is three missed syncs: an app that quit stops being waited on.
ALIVE_FRESH_S = 15 * 60
#: How long a fire waits for the app's answer. The edge answers in well
#: under a second; this is a slow network's worth, and the hook itself is
#: bounded by Hermes (fail-open) on top.
WAIT_S = 12.0
POLL_S = 0.2
KEEP_S = 24 * 3600
#: Verdicts that mean "another device has this occurrence".
NOT_YOURS = frozenset(("held", "ran"))
OFFLINE_STATUS = "ran-offline"


def claims_dir():
    return os.path.join(_ran.moe_home(), CLAIMS_DIRNAME)


def _key(name, iso):
    return hashlib.sha256(("%s\n%s" % (name, iso)).encode("utf-8")).hexdigest()[:24]


def ask_path(name, iso):
    return os.path.join(claims_dir(), _key(name, iso) + ".ask.json")


def answer_path(name, iso):
    return os.path.join(claims_dir(), _key(name, iso) + ".answer.json")


def app_answers(now=None):
    """True when the app said, within ALIVE_FRESH_S, that it answers claims."""
    try:
        age = (now or time.time()) - os.stat(os.path.join(claims_dir(), ALIVE_FILENAME)).st_mtime
    except OSError:
        return False
    return -60 <= age <= ALIVE_FRESH_S


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _write(path, data):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def prune(now=None):
    """Requests and answers older than a day go."""
    now = now or time.time()
    try:
        names = os.listdir(claims_dir())
    except OSError:
        return
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(claims_dir(), name)
        try:
            if now - os.stat(path).st_mtime > KEEP_S:
                os.unlink(path)
        except OSError:
            pass


def ask(job, now=None, wait=None, sleep=time.sleep, clock=time.monotonic):
    """Ask the app to claim this job's current occurrence. Returns the
    answer dict, or None when there is nobody to ask or no answer came."""
    when = _ran.occurrence(job, now)
    if when is None:
        return None
    name, iso = str(job.get("name"))[:120], when.isoformat()
    answer = _read(answer_path(name, iso))
    if answer is not None:                     # asked already, this occurrence
        return answer
    if not app_answers():
        return None
    _write(ask_path(name, iso), {"job": name, "occurrence": iso,
                                 "asked_at": datetime.now(timezone.utc).isoformat()})
    deadline = clock() + max(0.0, WAIT_S if wait is None else wait)
    while True:
        answer = _read(answer_path(name, iso))
        if answer is not None:
            return answer
        if clock() >= deadline:
            return None
        sleep(POLL_S)


def before_run(job=None, job_id=None, job_name=None, **_kwargs):
    """``pre_cron_run``: skip when another device has this occurrence."""
    try:
        if not isinstance(job, dict) or not _ran.is_reported(job):
            return None
        if _ran.machine_credential()[0]:
            return None                         # the machine claims through its own shim
        prune()
        answer = ask(job)
        if not answer:
            logger.info("claim: no answer for %s; running it here", job.get("name"))
            return None
        verdict = str(answer.get("verdict") or "")
        if verdict in NOT_YOURS and not answer.get("won"):
            logger.info("claim: %s is %s by another device; not running it here",
                        job.get("name"), verdict)
            return {"action": "skip",
                    "reason": "this run is already %s on the person's other computer"
                              % ("done" if verdict == "ran" else "being done")}
        return None
    except Exception as e:  # noqa: BLE001 — a claim that cannot be asked never stops a job
        logger.warning("claim: not asked: %s: %s", type(e).__name__, e)
        return None


def status_for(job, now=None):
    """What the `ran` report says for this job's current occurrence:
    ``ran-offline`` when the Mac ran it without the edge's word, else ``ok``."""
    try:
        when = _ran.occurrence(job, now)
        if when is None:
            return "ok"
        answer = _read(answer_path(str(job.get("name"))[:120], when.isoformat()))
        if answer is None:
            return OFFLINE_STATUS if app_answers() else "ok"
        return OFFLINE_STATUS if answer.get("verdict") == "offline" else "ok"
    except Exception:  # noqa: BLE001
        return "ok"
