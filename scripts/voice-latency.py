#!/usr/bin/env python3
"""Where a spoken turn's time went, per brain route, from Moe's own traces.

Reads `logs/voice/turns.jsonl` (and the rotated `.1`) under Moe's home and
prints p50 / p90 for each stage, grouped by the brain that answered
(`TurnTrace.brain`, recorded since 2026-10-30; older rows are "unrecorded").
Durations only: the traces never hold a word of what was said.

This is the baseline every speed change is judged against (the speed plan,
2026-10-30, phase 0): a change ships only if it beats these numbers on each
route it touches — the Claude plan, the ChatGPT plan, and a key.

    scripts/voice-latency.py                  # every turn on record
    scripts/voice-latency.py --since 2026-10-30
    scripts/voice-latency.py --source hold    # hold-to-talk only
    scripts/voice-latency.py --json           # one object per route
"""
import argparse
import json
import os
import statistics
import sys
from datetime import datetime, timezone

HOME = os.environ.get("MOE_HOME") or os.path.expanduser("~/Library/Application Support/Moe")

# (label, start mark, end mark). The first is how fast Moe feels.
STAGES = [
    ("decided → first word heard", "turnDecidedMs", "firstAudioHeardMs"),
    ("decided → transcript", "turnDecidedMs", "transcribedMs"),
    ("submit → first token", "submittedMs", "firstTokenMs"),
    ("first token → audio queued", "firstTokenMs", "firstAudioQueuedMs"),
    ("audio queued → heard", "firstAudioQueuedMs", "firstAudioHeardMs"),
]


def rows(home):
    out = []
    for name in ("turns.jsonl.1", "turns.jsonl"):
        path = os.path.join(home, "logs", "voice", name)
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        continue
        except FileNotFoundError:
            continue
    return out


def started(row):
    raw = row.get("startedAt") or ""
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def pct(values, p):
    """Nearest-rank percentile; honest on the small samples a route starts with."""
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(p / 100 * len(s) + 0.5)) - 1))
    return s[k]


def summarise(group):
    stages = {}
    for label, a, b in STAGES:
        gaps = [r[b] - r[a] for r in group
                if isinstance(r.get(a), (int, float)) and isinstance(r.get(b), (int, float))]
        # A negative gap means two marks from different turns (a reply still
        # playing when the next one ended): not a measurement of anything.
        gaps = [g for g in gaps if g >= 0]
        if gaps:
            stages[label] = {"n": len(gaps), "p50": pct(gaps, 50), "p90": pct(gaps, 90),
                             "mean": round(statistics.fmean(gaps))}
    return stages


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--since", help="only turns started on or after this date (YYYY-MM-DD, UTC)")
    ap.add_argument("--source", help="only this trigger: hold, wake, …")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--home", default=HOME)
    args = ap.parse_args()

    since = None
    if args.since:
        since = datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc)

    turns = [r for r in rows(args.home) if r.get("submittedMs") is not None]
    if since:
        turns = [r for r in turns if (started(r) or since) >= since]
    if args.source:
        turns = [r for r in turns if r.get("source") == args.source]
    if not turns:
        print("no spoken turns on record under " + args.home, file=sys.stderr)
        return 1

    groups = {}
    for r in turns:
        key = r.get("brain") or "unrecorded"
        if r.get("model"):
            key += " · " + r["model"]
        groups.setdefault(key, []).append(r)

    report = {k: {"turns": len(v), "stages": summarise(v)} for k, v in sorted(groups.items())}
    if args.json:
        print(json.dumps(report, indent=2))
        return 0
    for route, body in report.items():
        print(f"{route}  ({body['turns']} turns)")
        for label, s in body["stages"].items():
            print(f"  {label:<28} p50 {s['p50'] / 1000:5.2f} s   p90 {s['p90'] / 1000:5.2f} s   (n={s['n']})")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
