"""A routine the person asked for that keeps failing is said, in Moe's words.

Hermes reports a failing cron job two ways, and neither reaches a person as
something they can act on:

* a run that errors is delivered as a notice — ``⚠️ Cron 'name' failed: …``
  (cron/scheduler.py ``_summarize_cron_failure_for_delivery``) — which
  ``deliver.is_machinery`` drops from the island, rightly for Moe's own jobs;
* a run that ends *blocked* delivers the model's own reply, and from the
  third in a row Hermes appends "This job has failed N runs in a row — worth
  a review. Fix its prompt/config, or pause it with `hermes cron pause …`",
  which is instructions for a developer with a terminal.

The owner's "X daily growth" routine was blocked nine days running
(2026-09-16 → 09-24) and nobody was told: the drop above, and a
``deliver: local`` that sent the rest to a file. The delivery is repaired
elsewhere; this is the telling. For a job the **person** made (it carries an
origin; Moe's own jobs never do) a failure becomes one plain sentence at the
second failure in a row, again at the seventh, and then fortnightly — a
routine that fails every day is worth hearing about, not every day. Moe's
own jobs are unchanged: dropped and logged, as before.

**Since 2026-10-07 the telling is not done at delivery time.** Two holes in
it, both from ticket #15: it only ever saw a failure that was *delivered to
``moe``* (the ticket's job delivered to WhatsApp, failed to resolve a
target, and so reached nobody — not even this adapter), and it counted to
two before speaking, which a one-off job never reaches. The person learned
about it only by asking. So the failure notice is now dropped here like any
other, and ``tell_failures`` below — run every five minutes by
``moe-loop-check``, reading Hermes's own job records — puts one card in front
of the person per failure *episode*, with a one-tap answer (docs/INBOX-QUIET.md):
"Show me what went wrong" and "Run it again", or "Show me what it said" for a
run whose message never arrived. A one-off is told at its failure; a routine
at its second failure in a row (one is weather); a run that was blocked, or
whose message reached nobody, at once. Then nothing more until the job works
again — no seventh-failure reminder, no card per retry.

**Since 2026-11-12 Moe's own jobs are not simply dropped.** "Dropped and
logged" is right for the island — a card about Moe's own machinery has no
one-tap answer, so by the inbox rule it stays quiet — but the log was the
only record, and nobody reads a log: the proactive pass, the learning pass
or the calendar heads-up could be dead for weeks and nothing a person looks
at would say so. ``record_own_jobs`` keeps, per job, when it last ran, when
it last worked and when it last failed, in ``proactive/job-health.json``;
Settings › Running in the background reads that file and says one quiet line
per job ("Last ran 2 h ago." / "Has not worked since Tuesday."). Still not a
card, and still never a sentence on the island.

Stdlib only, never raises.
"""

import json
import os
import re
from datetime import datetime, timezone

#: Hermes's streak line, from cron/scheduler.py ``_failure_streak_nudge``.
#: Matched from "This job has failed" to the end, because everything after
#: it on the same run is the same developer instruction.
_STREAK_NUDGE = re.compile(r"\s*\n?This job has failed \d+ runs? in a row\b.*\Z", re.S)

#: The failures in a row at which the person hears about it: the second
#: (not the first — one failure is weather), the seventh (a week of a daily
#: routine), then every fourteenth.
FIRST_TELL = 2
SECOND_TELL = 7
EVERY_AFTER = 14


def is_persons_job(job):
    """True for a routine somebody asked for in a conversation.

    The scheduler stamps ``origin`` on a job created from a session; Moe's
    own jobs are registered by configure-hermes.py with none."""
    if not isinstance(job, dict):
        return False
    origin = job.get("origin")
    platform = origin.get("platform") if isinstance(origin, dict) else origin
    return bool(str(platform or "").strip())


def streak_now(job):
    """Failures in a row including the run being delivered.

    The failure is delivered BEFORE ``mark_job_run`` records it, so the
    stored ``failure_streak`` is one behind (the scheduler's own nudge adds
    one for the same reason)."""
    try:
        return int((job or {}).get("failure_streak") or 0) + 1
    except (TypeError, ValueError):
        return 1


def should_tell(streak):
    if streak == FIRST_TELL or streak == SECOND_TELL:
        return True
    return streak > SECOND_TELL and (streak - SECOND_TELL) % EVERY_AFTER == 0


def _name(job):
    name = str((job or {}).get("name") or "").strip()
    # Hermes stores what the model typed; one routine on the owner's Mac was
    # named "follow &amp; comment".
    return name.replace("&amp;", "&") or "one of your routines"


def telling(job, streak):
    """Moe's sentence about a routine that keeps failing."""
    return ("Your routine “%s” hasn’t worked the last %d times in a row. "
            "Want me to look into why?" % (_name(job), streak))


def strip_streak_nudge(text):
    """``text`` without Hermes's developer-facing streak line."""
    if not isinstance(text, str):
        return text
    return _STREAK_NUDGE.sub("", text).rstrip()


def for_machinery(job, text):
    """What to deliver instead of a dropped failure notice: always None now.

    The person's own failing job is told by ``tell_failures`` instead, once
    per episode and with something to tap, whatever the job delivers to. A
    sentence here as well would be the same news twice."""
    return None


def for_reply(job, text):
    """A blocked run's reply as the person should read it.

    The model's own explanation stays; Hermes's streak line goes, and at a
    telling streak Moe's sentence takes its place."""
    had_nudge = isinstance(text, str) and bool(_STREAK_NUDGE.search(text))
    out = strip_streak_nudge(text)
    if had_nudge and is_persons_job(job):
        streak = streak_now(job)
        if should_tell(streak):
            out = (out + "\n\n" if out else "") + telling(job, streak)
    return out


# ── failures the person has not heard about (ticket #15) ───────────────────

#: Where the episodes already told are remembered, in the proactive dir.
TOLD_FILENAME = "job-failures-told.json"
#: A failure older than this when first seen is history, not news: the
#: first run after an install must not raise every failure in the file.
FRESH_SECONDS = 12 * 3600
#: What a finished run's ``last_status`` says when it did not do its job
#: (hermes-agent cron/jobs.py ``_record_run_outcome`` and the scheduler's
#: explicit statuses). ``delivery_failed`` is judged separately: the run
#: worked and only the message may have gone astray.
_FAILED = ("error", "failed")
_BLOCKED = ("blocked", "blocked_config")
_UNDELIVERED = "delivery_failed"
#: The card's answers, one tap each.
LOOK = "Show me what went wrong"
RETRY = "Run it again"
SHOW = "Show me what it said"


def is_one_shot(job):
    sched = (job or {}).get("schedule")
    if isinstance(sched, dict) and str(sched.get("kind") or "") == "once":
        return True
    rep = (job or {}).get("repeat")
    return isinstance(rep, dict) and rep.get("times") == 1


def _tokens(job):
    raw = (job or {}).get("deliver")
    items = raw if isinstance(raw, (list, tuple)) else str(raw or "").split(",")
    return [str(t).strip().lower() for t in items if str(t).strip()]


def _reached(job):
    """Did the run's message reach the person somewhere?

    A ``moe`` target is the island (and the phone when away); it failing
    would say ``moe`` in the error. Anything else that errored did not
    arrive, and ``local`` is a file nobody reads."""
    err = str((job or {}).get("last_delivery_error") or "").strip().lower()
    toks = [t for t in _tokens(job) if t != "local"]
    if not toks:
        return False
    if not err:
        return True
    return any(t.split(":", 1)[0] == "moe" for t in toks) and "moe" not in err


def failure_of(job):
    """``(kind, reason)`` for a run the person has not been told about, or None.

    kind: ``failed`` (it errored), ``blocked`` (it could not do the job and
    said why), ``undelivered`` (it ran; its message reached nobody)."""
    status = str((job or {}).get("last_status") or "").strip().lower()
    err = str((job or {}).get("last_error") or "").strip()
    if status in _BLOCKED:
        if status == "blocked" and _reached(job):
            return None          # its own words, saying why, already arrived
        return "blocked", re.sub(r"^blocked:\s*", "", err, flags=re.I)
    if status in _FAILED:
        return "failed", err
    if status == _UNDELIVERED and not _reached(job):
        return "undelivered", str(job.get("last_delivery_error") or "")
    return None


def _when(iso):
    try:
        return datetime.fromisoformat(str(iso))
    except (TypeError, ValueError):
        return None


def _clock(when):
    """"10:04 AM" in the run's own local time (Hermes writes its offset)."""
    if when is None:
        return ""
    h = when.hour % 12 or 12
    return "%d:%02d %s" % (h, when.minute, "AM" if when.hour < 12 else "PM")


def due_to_tell(job, kind):
    """Whether this failure is told now: a one-off, a block or a lost
    message at once; a routine's error from its second in a row."""
    if kind != "failed" or is_one_shot(job):
        return True
    try:
        return int(job.get("failure_streak") or 0) >= FIRST_TELL
    except (TypeError, ValueError):
        return True


def card(job, kind, reason=""):
    """``(text, options, instruction)`` — the card for this failure."""
    name = _name(job)
    at = _clock(_when(job.get("last_run_at")))
    at_words = (" at %s" % at) if at else ""
    jid = str(job.get("id") or "")
    if kind == "undelivered":
        text = "“%s” ran%s, but its message didn’t reach you." % (name, at_words)
        options = [SHOW]
    elif kind == "blocked":
        why = " ".join(str(reason or "").split())[:160].rstrip(".")
        text = "“%s” couldn’t finish%s%s." % (name, at_words, (": " + why) if why else "")
        options = [LOOK, RETRY]
    elif is_one_shot(job):
        text = "“%s” didn’t work when it ran%s." % (name, at_words)
        options = [LOOK, RETRY]
    else:
        streak = int(job.get("failure_streak") or 0) or 1
        text = "Your routine “%s” hasn’t worked the last %d times in a row." % (name, streak)
        options = [LOOK, RETRY]
    finished = is_one_shot(job)
    rerun = ("It was a one-off and is finished, so it cannot be run again as it is: make a new "
             "one-off with the cronjob tool (action `create`) with the same prompt and delivery, "
             "due a minute from now. " if finished else
             "Use the cronjob tool, action `run`, job_id %s. " % jid)
    instruction = (
        "This card is about the person's own scheduled job “%s” (cronjob job_id %s): its last "
        "run, at %s, %s. If they chose “%s” or “%s”: read the job's record and last output "
        "(the cronjob tool, action `list`; the run's output), then tell them in plain words what "
        "happened and what would fix it — never paste raw errors or tool names. If they chose "
        "“%s”: first say in one line if something only they can do (a sign-in, a permission, a "
        "missing recipient) has to happen for it to work, and ask; otherwise %sthen say it has "
        "started. Do nothing else without asking."
        % (name, jid, job.get("last_run_at") or "unknown",
           {"failed": "failed", "blocked": "was blocked", "undelivered":
            "worked but its message reached nobody"}[kind],
           LOOK, SHOW, RETRY, rerun))
    return text, options, instruction


def subject_of(job):
    """The inbox subject for one job (docs/INBOX-QUIET.md ``routine:<id>``):
    a later card about the same job updates this one in place."""
    return "routine:%s" % str((job or {}).get("id") or "")


def _read_told(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_told(path, told):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(told, f, sort_keys=True, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        pass


# ── Moe's own jobs: when each last ran, worked and failed ──────────────────

#: Beside the told-episodes file, in the proactive dir. The app reads it.
HEALTH_FILENAME = "job-health.json"


def _stamp_utc(when):
    return when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _as_utc(iso):
    """Hermes's local-offset timestamp as a UTC ``…Z`` stamp, or ""."""
    when = _when(iso)
    if when is None:
        return ""
    if when.tzinfo is None:
        when = when.astimezone()          # Hermes writes local time
    return _stamp_utc(when)


def health_path(directory):
    return os.path.join(directory, HEALTH_FILENAME)


def read_health(directory):
    """``{"checked": …, "jobs": {name: {…}}}``; empty when there is none."""
    data = _read_told(health_path(directory))
    jobs = data.get("jobs")
    return {"checked": str(data.get("checked") or ""),
            "jobs": jobs if isinstance(jobs, dict) else {}}


def record_own_jobs(jobs, directory, now=None):
    """Write what Hermes's records say about Moe's own jobs, keeping what
    they cannot say. Returns the health dict written (or what was read, if
    nothing could be written). Never raises.

    Hermes keeps only the LAST run's status, so "when did this last work?"
    is lost at the first failure — which is exactly when it is wanted. This
    carries ``last_success`` and ``last_failure`` forward from one look to
    the next. A job that is gone from Hermes's records is dropped here too.

    ``checked`` is stamped every time, whatever was found: the job that
    calls this is itself one of Moe's own, and a file nobody has refreshed
    is how the reader tells that the watcher has stopped."""
    try:
        now = now or datetime.now(timezone.utc)
        before = read_health(directory)["jobs"]
        out = {}
        for job in jobs or []:
            if not isinstance(job, dict) or is_persons_job(job):
                continue
            name = str(job.get("name") or "").strip()
            if not name:
                continue
            was = before.get(name) if isinstance(before.get(name), dict) else {}
            status = str(job.get("last_status") or "").strip().lower()
            ran = _as_utc(job.get("last_run_at"))
            entry = {
                "id": str(job.get("id") or ""),
                "enabled": bool(job.get("enabled", True)),
                "last_run": ran,
                "last_status": status,
                "next_run": _as_utc(job.get("next_run_at")),
                "last_success": str(was.get("last_success") or ""),
                "last_failure": str(was.get("last_failure") or ""),
            }
            if ran and status:
                # A run that errored or was blocked did not do its job. Any
                # other finished status did — including one whose message
                # went astray, which is a delivery fault, not a dead job.
                key = "last_failure" if status in _FAILED + _BLOCKED else "last_success"
                if ran > entry[key]:
                    entry[key] = ran
            out[name] = entry
        health = {"checked": _stamp_utc(now), "jobs": out}
        _write_told(health_path(directory), health)
        return health
    except Exception:  # noqa: BLE001 — a record that could not be kept is not a failed tick
        return {"checked": "", "jobs": {}}


def read_jobs(hermes_home):
    """Hermes's job records, read-only. [] when the file cannot be read."""
    try:
        with open(os.path.join(hermes_home, "cron", "jobs.json"), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    jobs = data.get("jobs") if isinstance(data, dict) else data
    return [j for j in jobs or [] if isinstance(j, dict)]


def tell_failures(jobs, deliver, now=None):
    """One card per failure episode of the person's own jobs. Returns the
    ids told this time. ``deliver`` is moe-screen's deliver module (its
    ``deliver`` and ``open_dir``), injected because this module is loaded
    beside it, not inside a package.

    An episode starts at the first failed run and ends at the next run that
    did not fail; it is told once, whatever happens in between. Never raises."""
    told_now = []
    try:
        now = now or datetime.now(timezone.utc)
        # Moe's own jobs get no card, by the inbox rule; they get a record
        # the Settings pane reads. Here because this is the one place that
        # already holds Hermes's job records every five minutes.
        record_own_jobs(jobs, deliver.open_dir(), now=now)
        path = os.path.join(deliver.open_dir(), TOLD_FILENAME)
        told = _read_told(path)
        changed = False
        seen_ids = set()
        for job in jobs:
            if not is_persons_job(job):
                continue
            jid = str(job.get("id") or "")
            if not jid:
                continue
            seen_ids.add(jid)
            found = failure_of(job)
            if found is None:
                status = str(job.get("last_status") or "").strip().lower()
                if jid in told and status and status not in _FAILED + _BLOCKED:
                    told.pop(jid)        # it worked: the episode is over
                    changed = True
                continue
            if jid in told:
                continue                 # this episode was told; retries are not news
            kind, reason = found
            if not due_to_tell(job, kind):
                continue
            when = _when(job.get("last_run_at"))
            if when is not None and when.tzinfo is not None \
                    and (now - when).total_seconds() > FRESH_SECONDS:
                told[jid] = {"run": job.get("last_run_at"), "kind": kind, "told": False}
                changed = True           # history: remembered, never raised
                continue
            text, options, instruction = card(job, kind, reason)
            ok, err = deliver.deliver(text, source="jobs", job=JOB_FAILURES_SOURCE, job_id=jid,
                                      instruction=instruction, options=options,
                                      subject=subject_of(job), now=now)
            if not ok:
                continue                 # not told: try again next tick
            told[jid] = {"run": job.get("last_run_at"), "kind": kind, "told": True,
                         "at": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
            told_now.append(jid)
            changed = True
        for gone in [k for k in told if k not in seen_ids]:
            told.pop(gone)               # the job was removed: nothing to keep
            changed = True
        if changed:
            _write_told(path, told)
    except Exception:  # noqa: BLE001 — a card that could not be made is a log line, never a crash
        return told_now
    return told_now


#: The `job` the card is filed under. Moe's own prefix, so quiet hours keep
#: it off the phone at night like anything else Moe raises on its own.
JOB_FAILURES_SOURCE = "moe-job-failures"
