#!/usr/bin/env python3
"""The person's background jobs, one line each, for the brief (sync.sh
writes it to context/jobs.md; the section is "Your background jobs").

Why the brief: it is the one thing both brains read — this Mac's, and the
cloud computer's, where it travels as the `context/brief` document. The cloud
computer's own job list holds only the jobs that travel there, and its copy
of a job never runs while the Mac holds it, so on 2026-09-30 the cloud Moe
told the person it could see two of their twenty jobs and called one that had
failed five times in a row "healthy".

Each line: name, when it runs, where, and how it is doing — the words stay
the same from run to run (no times), so a job that keeps working never
changes the brief and never wakes the background pass; a job that starts
failing does, once. Moe's own jobs (`moe-…`) are left out.

    jobs_brief.py            prints the lines (nothing when there are no jobs)

Stdlib, Python 3.9. Never raises: a job list that cannot be read prints
nothing, and the brief simply has no such section.
"""
import json
import os
import re
import sys

MAX_JOBS = 40
_ID = re.compile(r"^[0-9a-f]{6,32}$")
#: The plans that come with a cloud computer (relay.py CLOUD_TIERS).
CLOUD_TIERS = ("away", "away_plus")
_WHY = [
    (re.compile(r"idle for \d+s|timed? ?out|TimeoutError", re.I), "it stalled before finishing"),
    (re.compile(r"tools did not load", re.I), "its tools did not load"),
    (re.compile(r"auth|401|403|credential|sign(ed)? in", re.I), "a sign-in it needs has lapsed"),
    (re.compile(r"rate.?limit|429|quota|limit reached", re.I), "it hit a usage limit"),
]


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def has_cloud():
    """Whether this person has a cloud computer at all (cloud/tier.json,
    the edge's own word, re-read hourly by the app)."""
    try:
        with open(os.path.join(moe_home(), "cloud", "tier.json"), encoding="utf-8") as f:
            return json.load(f).get("tier") in CLOUD_TIERS
    except (OSError, ValueError, AttributeError):
        return False


def hermes_home():
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def _portable(job):
    """The ledger's rule (moeledger.cronjobs.is_portable), repeated because
    this runs with the system python and no plugin on its path."""
    name = str(job.get("name") or "")
    if not name or name.startswith("moe-"):
        return False
    if job.get("no_agent") or job.get("script") or job.get("monitor_script") or job.get("monitor_url"):
        return False
    if not _ID.match(str(job.get("id") or "")):
        return False
    return isinstance(job.get("prompt"), str) and bool(job["prompt"].strip())


_MAC_BOUND = re.compile(r"(?:^|[\s\"'`(=])(?:/Users/|~/|\$HOME/)|\blocal\s*=\s*true\b", re.I)


def _travels(job):
    """moeledger.cronjobs.travels: portable and not tied to this Mac."""
    text = "%s\n%s" % (job.get("prompt") or "", job.get("workdir") or "")
    return _portable(job) and not _MAC_BOUND.search(text)


def _when(job):
    sched = job.get("schedule")
    if isinstance(sched, dict):
        return str(sched.get("display") or sched.get("expr") or "").strip() or "on its own schedule"
    return str(job.get("schedule_display") or sched or "").strip() or "on its own schedule"


def _health(job):
    if job.get("enabled") is False or job.get("state") == "paused" or job.get("paused_at"):
        return "paused"
    status = str(job.get("last_status") or "")
    streak = job.get("failure_streak")
    streak = streak if isinstance(streak, int) and streak > 0 else 0
    if status in ("error", "failed") or streak:
        why = next((w for rx, w in _WHY if rx.search(str(job.get("last_error") or ""))), "it failed")
        # No count: a count changes the brief at every failure, and the
        # brief changing is what wakes the background pass (review).
        runs = "several runs in a row" if streak > 1 else "last run"
        return "not working — %s, %s" % (why, runs)
    if not job.get("last_run_at"):
        return "not run yet"
    return "working"


def lines(jobs, cloud=None):
    cloud = has_cloud() if cloud is None else cloud
    out = []
    for job in jobs:
        if not isinstance(job, dict):
            continue
        name = " ".join(str(job.get("name") or "").split()).replace("&amp;", "&")
        if not name or name.startswith("moe-"):
            continue
        where = "on your Mac, and in the cloud while it is off" if cloud and _travels(job) else "on your Mac"
        out.append("- %s — %s, %s — %s" % (name[:80], _when(job), where, _health(job)))
    return out[:MAX_JOBS]


def main():
    try:
        with open(os.path.join(hermes_home(), "cron", "jobs.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return 0
    jobs = data.get("jobs") if isinstance(data, dict) else data
    for line in lines(jobs if isinstance(jobs, list) else []):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
