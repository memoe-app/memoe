#!/usr/bin/env python3
"""Time the brain alone, per route: request → first token → done.

Sends a few short, neutral questions to the local Hermes API server, the
way Moe does (`HermesEndpoint.chatRequest`: SSE chat completions with a
per-request model and provider), and prints p50 / p90 time to first token
and to the end, with thinking as configured and with thinking off
(`model_options.reasoning_effort: none`, what `BrainSelection
.suppressReasoning` sends). It is the half of the speed baseline the voice
traces cannot give: the same questions on every route, side by side.

Read the printed answer: Hermes returns a failed turn (a plan at its limit,
a key with no credit) as a normal reply carrying the error, and it times
like a fast one. On 2026-10-30 the Claude plan "answered" in 2.7 s for that
reason.

Each run is its own throwaway session (never the session key "moe"), so it
lands in nobody's conversation. It does spend the route's usage: a plan's
allowance or a key's tokens, a few hundred tokens a question.

    scripts/brain-latency.py --route claude-code-cli:sonnet
    scripts/brain-latency.py --route deepseek:deepseek-v4-flash --route openai-codex:gpt-5.5
    scripts/brain-latency.py --route anthropic:claude-haiku-4-5 --runs 5 --json
    scripts/brain-latency.py --route deepseek:deepseek-v4-flash --warm --toolsets memory,moe_profile
"""
import argparse
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request
import uuid

QUESTIONS = [
    "What's seventeen times twenty-three?",
    "In one sentence, why is the sky blue?",
    "Give me a two-word name for a grey cat.",
    "What's the capital of Australia?",
]


def api_key():
    key = os.environ.get("API_SERVER_KEY", "").strip()
    if key:
        return key
    env = os.path.expanduser("~/.hermes/.env")
    try:
        with open(env, encoding="utf-8") as f:
            for line in f:
                if line.startswith("API_SERVER_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return ""


def one_turn(base, key, provider, model, question, thinking, timeout, session=None, toolsets=None):
    body = {
        "model": model,
        "provider": provider,
        "stream": True,
        "messages": [{"role": "user", "content": question + " Answer in one short sentence."}],
    }
    if not thinking:
        body["model_options"] = {"reasoning_effort": "none"}
    req = urllib.request.Request(
        base.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
            "X-Hermes-Session-Id": session or ("speed-bench-" + uuid.uuid4().hex),
        },
        method="POST",
    )
    if toolsets is not None:
        # Narrow-only on Hermes's side (api_server ``restrict_toolsets``):
        # the tools this turn may use, out of what api_server already has.
        req.add_header("X-Hermes-Enabled-Toolsets", toolsets)
    t0 = time.monotonic()
    first = None
    text = []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except ValueError:
                continue
            for ch in chunk.get("choices") or []:
                piece = (ch.get("delta") or {}).get("content") or ""
                if piece:
                    if first is None:
                        first = time.monotonic() - t0
                    text.append(piece)
    return first, time.monotonic() - t0, "".join(text).strip()


def pct(values, p):
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(p / 100 * len(s) + 0.5)) - 1))
    return s[k]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--route", action="append", required=True,
                    help="provider:model, e.g. claude-code-cli:sonnet (repeatable)")
    ap.add_argument("--runs", type=int, default=1, help="passes over the questions per mode")
    ap.add_argument("--base", default="http://127.0.0.1:8642")
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--modes", default="default,none", help="default, none, or both")
    ap.add_argument("--warm", action="store_true",
                    help="one session per route and mode, as a conversation is; the first (cold) "
                         "question is asked but not counted")
    ap.add_argument("--toolsets", default=None,
                    help="send X-Hermes-Enabled-Toolsets with this comma list (\"\" = no tools)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    key = api_key()
    if not key:
        print("no API_SERVER_KEY (env or ~/.hermes/.env)", file=sys.stderr)
        return 2

    report = {}
    for route in args.route:
        provider, _, model = route.partition(":")
        for mode in [m.strip() for m in args.modes.split(",") if m.strip()]:
            firsts, totals, errors, sample = [], [], [], ""
            session = ("speed-bench-" + uuid.uuid4().hex) if args.warm else None
            asks = [(q, True) for _ in range(args.runs) for q in QUESTIONS]
            if args.warm:
                asks.insert(0, ("Say ready.", False))
            for q, counted in asks:
                    try:
                        first, total, text = one_turn(args.base, key, provider, model, q,
                                                      thinking=(mode == "default"), timeout=args.timeout,
                                                      session=session, toolsets=args.toolsets)
                        if not counted:
                            continue
                    except (urllib.error.URLError, TimeoutError, OSError) as e:
                        errors.append(str(getattr(e, "code", "")) + " " + str(e)[:120])
                        continue
                    if first is None:
                        errors.append("no content")
                        continue
                    firsts.append(first)
                    totals.append(total)
                    sample = sample or text[:80]
            row = {"n": len(firsts), "errors": errors[:3], "sample": sample}
            if firsts:
                row.update(first_p50=round(pct(firsts, 50), 2), first_p90=round(pct(firsts, 90), 2),
                           first_min=round(min(firsts), 2), done_p50=round(pct(totals, 50), 2),
                           first_mean=round(statistics.fmean(firsts), 2))
            report[f"{route} · thinking {mode}"] = row
            if not args.json:
                if firsts:
                    print(f"{route:<36} thinking {mode:<8} first token p50 {row['first_p50']:5.2f} s  "
                          f"p90 {row['first_p90']:5.2f} s  min {row['first_min']:5.2f} s  "
                          f"done p50 {row['done_p50']:5.2f} s  (n={row['n']})")
                    # Hermes answers a failed turn with a 200 and the error as
                    # the reply ("You've hit your weekly limit"), so a timing
                    # alone cannot tell an answer from a refusal. Read this.
                    print(f"{'':<36} answer: {row['sample']!r}")
                else:
                    print(f"{route:<36} thinking {mode:<8} FAILED: {errors[:2]}")
                if errors and firsts:
                    print(f"{'':<36} {len(errors)} error(s): {errors[0]}")
                sys.stdout.flush()
    if args.json:
        print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
