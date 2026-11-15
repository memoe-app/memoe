#!/bin/bash
# Hermes pre_tool_call hook: the two things that bound what Moe spends at
# Composio. HERMES-SURFACES.md §3.1, which had been written in five places
# and enforced in none.
#
# It answers two separate questions about one tool call, in this order:
#
#   1. THE CLOCK RULE. "Anything that runs on a clock against Composio is a
#      paid feature. Anything a person asks for, in the moment, is free."
#      A Composio call in a turn nobody asked for is blocked unless this
#      Mac's tenant is on a tier that pays for clocks. Free is NOT a
#      crippled tier: an interactive call is never touched by this rule.
#
#   2. THE CALL BUDGET. Every Composio call, on any tier, interactive or
#      scheduled, is counted against an hourly and a daily bound. Over
#      either one, it is blocked. This exists because of what the owner
#      said when the clock rule was being built — *"people will just set up
#      crons"* — and it is the half that does not depend on getting question
#      1 right.
#
# Why both, and why the budget is the load-bearing one
# ----------------------------------------------------
# Question 1 is answered from how the turn STARTED (below), which is a
# positive identification of a scheduled turn. Anything it cannot identify
# is treated as interactive — it fails OPEN on that axis, deliberately,
# because the alternative is a free Mac where Gmail stops working when a
# person asks for it, which is the exact failure the rule exists to avoid.
#
# That would leave a hole if question 2 did not exist. It does: whatever
# the clock check decides, the budget counts the call, and a runaway of any
# shape — a mis-classified cron, a retry loop, a tool that calls itself —
# hits the hourly bound within the hour. So the classification is allowed to
# be imperfect, and the bill is not.
#
# What this does NOT do, said plainly
# -----------------------------------
# The counters live on this Mac and this Mac's owner can delete them. That
# is fine: this is not a boundary against the person sitting here, who is
# allowed to spend their own allowance. It is a bound on runaway code and a
# refusal in front of a feature nobody costed. The boundary that matters for
# OUR shared Composio pool — 100K calls a month and 2,000 a minute across
# every tenant — has to be enforced where the calls are counted for everyone,
# which is the edge. §3.1 point 3. Nothing here substitutes for that.
#
# Failure policy is CLOSED, and it is closed toward FREE. Malformed input, a
# missing python3, an unreadable credential, an unwritable counter — every
# one of them blocks a Composio call rather than permitting it. A gate that
# opens when it is confused is not a gate, and the specific confusion to
# avoid is a corrupted credential file reading as "paid" and quietly
# spending someone into their cap, which they meet as Gmail breaking with
# nothing that names the cause.
#
# Bash 3.2 (macOS ships nothing newer) and no jq: python3 does the JSON.
set -u

MOE_HOME="${MOE_HOME:-$HOME/.moe}"
export MOE_HOME

# ---------------------------------------------------------------------------
# The fast path, and why it is a substring test on the raw payload.
#
# This hook is on `matcher: ".*"` — it is handed EVERY tool call Moe makes,
# and the overwhelming majority have nothing to do with Composio. Spawning
# python3 for each of those would put an interpreter start in front of every
# tool call in the product.
#
# So: if the raw stdin does not contain the string at all, there is no
# Composio tool call in it and we are done. The test is deliberately loose in
# the permissive direction — a payload that merely MENTIONS the string (a
# message quoting a tool name, say) falls through to python, which then makes
# the real decision on the parsed `tool_name` and passes it. A false positive
# here costs one interpreter start. A false negative would be a hole, and a
# substring test cannot produce one: every name we gate contains this string.
# ---------------------------------------------------------------------------
PAYLOAD="$(cat)"
case "$PAYLOAD" in
  *mcp__composio*) ;;
  *) exit 0 ;;
esac

block() { # reason
  local r
  r="$(printf '%s' "$1" | tr -d '\000-\037')"
  r="${r//\\/\\\\}"
  r="${r//\"/\\\"}"
  printf '{"decision":"block","reason":"%s"}\n' "$r"
  exit 2
}

if ! command -v python3 >/dev/null 2>&1; then
  block "Composio budget hook: python3 not found — refusing to let a metered call through"
fi

# ---------------------------------------------------------------------------
# The decision. python3 reads the payload from our stdin and prints one line:
#
#   PASS
#   BLOCK<TAB><reason>
#
# Anything else — a crash, an empty line, a word we do not know — blocks.
# ---------------------------------------------------------------------------
DECISION="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, math, os, sys, time, errno

# --- the tool names this gate is about ------------------------------------
#
# `mcp__composio__…`. The middle segment is an mcp_servers KEY, and that key
# is written by our own configure-hermes.py (`apply_composio`, which sets
# `servers["composio"]`) — not by a model, not by a feature author, and not
# by Composio. That is what makes this a structural match rather than the
# enumerated-name kind CLAUDE.md warns about: a scheduled mail check somebody
# adds next month reaches Composio through the same server entry and is
# therefore already covered, whatever the job or the tool is called.
#
# The prefix is `mcp__composio` rather than `mcp__composio__` so that a
# per-tenant server key (`composio-<something>`, which §3.3s one-project-per-
# person design would produce) is covered the day it lands rather than
# silently falling outside the gate.
#
# scripts/test-composio-budget.sh asserts this prefix against
# configure-hermes.py itself, so renaming the server key there fails a test
# instead of turning this gate off.
COMPOSIO_TOOL_PREFIX = "mcp__composio"

# --- how a turn that nobody asked for is recognised -----------------------
#
# Hermes stamps a cron run`s agent with
#   session_id = f"cron_{job_id}_{timestamp}"        (cron/scheduler.py)
# and a subagent of that run carries it as parent_session_id, which
# agent/shell_hooks.py falls back to. So this prefix is a property of HOW
# THE TURN STARTED, set by the scheduler, and no job name appears anywhere
# in this file.
#
# It is still a string from someone else`s source, and if Hermes renames it
# this gate would go quiet rather than fail — the worst shape a guard can
# have. scripts/test-composio-budget.sh greps the INSTALLED scheduler for
# this literal and goes red if it moves, which turns a silent stand-down
# into a loud one.
CRON_SESSION_PREFIX = "cron_"

# CLOUD-PLAN §19.4 and §19.9: the allowance each tier gets, per hour and per
# day. These replaced a single 120/1,000 pair that was set before there was a
# tier to key on.
#
# The hourly figure is deliberately about a THIRD of the day`s budget rather
# than a twenty-fourth. A person asking twenty-five things in one sitting is
# ordinary, and an hourly cap that forbade it would fire on real use — while a
# runaway held to a third a day still takes most of a day to catch.
#
# The paid numbers are the owner`s of 2026-11-13 (docs/PLANS-AND-CAPS-2026-11-13.md
# §7 D5): Away 100 / 200, Away+ 200 / 500. The Composio proxy in the cloud carries
# the same three pairs in its CAPS, and test-composio-budget.sh compares them.
CAPS = {
    "free": (50, 150),
    "away": (100, 200),
    "away_plus": (200, 500),
}

# --- looking is not doing --------------------------------------------------
#
# Until 2026-11-12 every Composio call drew on the allowance above, and the
# system prompt REQUIRES a search before every brokered action
# (configure-hermes.py: "run COMPOSIO_SEARCH_TOOLS for it"). So one request
# from a person cost at least two calls — often three, with a schema fetch —
# and a free Mac`s fifty an hour was nearer twenty things asked. The lookups
# reach no service and touch nobody`s data: they are Moe reading the catalog.
#
# What a lookup IS, so that this is not a list of names a new name walks
# past. A Composio tool slug is <TOOLKIT>_<ACTION>. Two things must both hold:
#
#   - the toolkit is COMPOSIO itself — the broker`s own meta tools, which
#     talk to Composio about tools and never to Gmail or Slack. That half is
#     structural: `GMAIL_SEARCH` and `GOOGLECONTACTS_SEARCH_CONTACTS` are
#     searches OF a service, they are real brokered calls, and they count.
#   - the action begins with a reading verb. This half IS a short list of
#     words, said plainly: the slug carries nothing else to tell
#     COMPOSIO_SEARCH_TOOLS from COMPOSIO_MULTI_EXECUTE_TOOL. What makes it
#     safe is the direction it fails in — a meta tool with any verb not
#     listed here (EXECUTE, MANAGE, REMOTE, or one invented next month) is
#     COUNTED. A new name can only walk into the allowance, never past it.
#
# Not counted is not unbounded. The budget exists to stop a runaway of any
# shape, and a loop that only ever searches is a shape. Lookups have their
# own counters and their own ceiling, LOOKUP_FACTOR times the tier`s — room
# for several lookups per action, and still a wall a loop hits within the
# hour. And the clock rule is untouched: a scheduled turn on a free Mac is
# refused its lookups like everything else.
META_TOOLKIT = "COMPOSIO"
LOOKUP_VERBS = ("SEARCH", "GET", "LIST", "FIND")
LOOKUP_FACTOR = 4


def is_lookup(tool_name):
    """True for one of the broker`s own catalog lookups. Never raises."""
    parts = tool_name.split("__")
    if len(parts) < 3:
        return False
    slug = "__".join(parts[2:]).upper()
    toolkit, _, action = slug.partition("_")
    return toolkit == META_TOOLKIT and action.split("_", 1)[0] in LOOKUP_VERBS


# Which tiers may run Composio on a clock. The gate rule in one line: anything
# a person asks for is free, anything on a schedule is paid. Derived from CAPS
# rather than written out again: a tier added above and forgotten here would
# have an allowance and no clock, silently. (Reviewer, 2026-09-06.)
CLOCK_TIERS = tuple(name for name in CAPS if name != "free")

# How long a cached tier is honoured, and how far into the future a
# `checked_at` may sit before it is disbelieved. See `tier()`.
TIER_MAX_AGE = 30 * 24 * 60 * 60
TIER_FUTURE_SLACK = 24 * 60 * 60


def out(*parts):
    sys.stdout.write("\t".join(parts) + "\n")
    sys.exit(0)


try:
    payload = json.load(sys.stdin)
except Exception:
    out("BLOCK", "Composio budget hook: unreadable hook payload")
if not isinstance(payload, dict):
    out("BLOCK", "Composio budget hook: hook payload is not an object")

tool = payload.get("tool_name")
if not isinstance(tool, str) or not tool.startswith(COMPOSIO_TOOL_PREFIX):
    # Not ours. The fast path let a mention through; this is where it ends.
    out("PASS")

home = os.environ.get("MOE_HOME") or os.path.join(os.path.expanduser("~"), ".moe")

# --- the away machine is not gated ----------------------------------------
#
# CLOUD-PLAN §15 / HERMES-SURFACES §3.1: a machine exists only by enrolling
# as a device under a tenant, and enrolment is what creates the tenant. A
# free tenant`s machine cannot exist, so a machine is a paid-tier runtime by
# construction and the clock rule permits it Composio on a schedule. The
# gate belongs on the Mac only.
#
# It still counts (below) — "permitted a clock" was never "free to spend
# without limit", and the shared 2,000/minute is drawn on by paid tenants
# too.
# MOE_RUNS_IN says which runtime this is; it is an environment variable, and
# on a Mac the agent can reach the environment its own gateway is spawned
# with (launchctl setenv, then a relaunch). So the variable alone must not be
# what hands out the machine`s allowance and its clock: it is corroborated by
# the platform, which a process cannot lie about to itself. The machine is a
# Linux box (per its deploy config); a Mac saying "cloud" is a Mac.
# (Reviewer, 2026-09-06: MOE_RUNS_IN=cloud on a Mac bought `away` caps and a
# clock with no file anywhere.)
runs_in = (os.environ.get("MOE_RUNS_IN") or "").strip().lower()
on_the_machine = runs_in == "cloud" and sys.platform.startswith("linux")


def tier():
    """`free`, `away` or `away_plus`, from this Mac`s cached tier. Never `paid`.

    **The name still matters.** Slice 9 — paying creates a machine — is not
    built, so nothing ties this value to a payment yet: a webhook that sets it
    is the next thing to build. It is deliberately a tier and not an
    `is_paid` boolean, because a boolean called `is_paid` that actually meant
    something narrower is precisely the thing nobody re-checks.

    **What it reads, and the two signals it is NOT.** Not "does a credential
    file exist" — that died on 2026-09-04, when the owner decided free Macs
    enrol too so the edge can mint them a Composio project
    (HERMES-SURFACES §3.3), which made a credential mean "has a tenant" on
    every Mac that connects anything. And no longer `sync`, which was the
    stopgap that replaced it: `sync` separates an Away enrolment from a
    connections-only one, which is a question about uploading conversations
    and was never a question about money. A connections-only Mac can be
    paying, and under `sync` it read as free.

    `~/.moe/cloud/tier.json` is written by `CloudSync.refreshTierLocked` from
    `GET /v1/tenant`, which serves `moe.tenants.tier` — a column on the
    tenant record, which is what §3.1 said the real answer would be. It is
    honoured only beside a readable `credential.json` naming a tenant: a tier
    is a property of a tenant, and a tier file with no tenant behind it is an
    orphan — a crash between the two deletions in `forget()` — and reads as
    free.

    **Why a file and not a request.** This runs inside a tool call, before
    every Composio call. It must answer locally, synchronously, with no
    network: a version that asked the edge would put a round trip in front of
    every call and would fail OPEN the moment the edge was unreachable.

    **Fail closed toward free — and "closed" means FREE, not "refuse".** Every
    unreadable shape reads as `free`: missing, unparseable, not an object, an
    unrecognised or non-string tier, a `checked_at` that is missing, a string,
    a boolean, NaN, absurdly large, or outside its window. The failure this
    must not have is a corrupt or forged file reading as paid. The failure it
    must not have EITHER is a corrupt file making the interpreter crash, because
    the shell around this treats no answer as BLOCK — and blocking a person`s
    own Gmail question is the outage the whole rule exists to avoid. So the
    body is in a helper and this wrapper turns any exception into `free`.
    (Reviewer, 2026-09-06: a list as the tier, a 400-digit stamp and a
    100k-deep document each crashed the gate into "block everything".)

    **NaN is named because it is the one that walks past the window.**
    Python`s json accepts the literal; `time.time() - nan` is nan; nan is
    neither greater than thirty days nor less than minus one, so without
    `isfinite` a forged file reads as paid for ever. Foundation`s parser
    refuses NaN, so the app would report "no tier" while the gate spent on the
    top one. (Reviewer, 2026-09-06.)

    **The window is thirty days forward and one day back.** Forward is a
    month of grace for someone offline, and a bound on how long a cancelled
    subscription keeps working. Backward exists because a `checked_at` in the
    future never expires: without it, one bad clock — or one edited file —
    buys a permanent tier. A day of slack absorbs a timezone mistake and
    nothing larger.

    **The machine is not gated and does not read this.** See below: a machine
    exists only by enrolling under a tenant, so it is a paid runtime by
    construction, and no `tier.json` is written on it.
    """
    try:
        return _tier_or_raise()
    except Exception:
        return "free"


def machine_tier():
    """The machine`s tier: `away` unless the edge has said `away_plus`.

    The floor of the paid tiers, not the ceiling, is still the default. Until
    2026-11-13 it was the ONLY answer — an Away+ person`s cloud computer, which
    is where scheduled work runs, stopped at Away`s numbers (PLANS-AND-CAPS
    G3). Now `/opt/moe/report-usage.py` writes `$HERMES_HOME/moe/tier.json`
    from the edge`s own answer to `POST /v1/usage` (which reads
    `moe.tenants.tier`), and this honours `away_plus` from it when it is fresh
    by the same window a Mac`s file is held to. Anything else — missing,
    unreadable, stale, `free`, an unknown word — is `away`: the machine exists
    only for a paying tenant, so `away` is never an over-grant, and the edge
    proxy counts the tenant`s real allowance whatever this file says.
    """
    try:
        hermes_home = os.environ.get("HERMES_HOME") or os.path.join(
            os.path.expanduser("~"), ".hermes")
        with open(os.path.join(hermes_home, "moe", "tier.json"), encoding="utf-8") as fh:
            doc = json.load(fh)
        if not isinstance(doc, dict) or doc.get("tier") != "away_plus":
            return "away"
        checked = doc.get("checked_at")
        if not isinstance(checked, (int, float)) or not math.isfinite(checked):
            return "away"
        age = time.time() - checked
        if age > TIER_MAX_AGE or age < -TIER_FUTURE_SLACK:
            return "away"
        return "away_plus"
    except Exception:
        return "away"


def _tier_or_raise():
    if on_the_machine:
        return machine_tier()
    with open(os.path.join(home, "cloud", "credential.json"), encoding="utf-8") as fh:
        credential = json.load(fh)
    if not isinstance(credential, dict):
        return "free"
    tenant = credential.get("tenant")
    if not isinstance(tenant, str) or not tenant.strip():
        return "free"
    with open(os.path.join(home, "cloud", "tier.json"), encoding="utf-8") as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict):
        return "free"
    name = doc.get("tier")
    if not isinstance(name, str) or name not in CAPS:
        return "free"
    checked = doc.get("checked_at")
    # `bool` is deliberately NOT excluded. True is 1, which is 1970, which the
    # window rejects three lines down — so a `not isinstance(checked, bool)`
    # here is a branch no input can reach, and a mutant that deleted it
    # survived the whole suite. CLAUDE.md: a check that cannot fail is worse
    # than no check. The suite still feeds `true` and asserts free.
    if not isinstance(checked, (int, float)):
        return "free"
    if not math.isfinite(checked):
        return "free"
    age = time.time() - checked
    if age > TIER_MAX_AGE or age < -TIER_FUTURE_SLACK:
        return "free"
    return name


session = payload.get("session_id")
if not isinstance(session, str):
    session = ""
if not session:
    parent = payload.get("parent_session_id")
    session = parent if isinstance(parent, str) else ""
on_a_clock = session.startswith(CRON_SESSION_PREFIX)

TIER = tier()
clocks_allowed = on_the_machine or TIER in CLOCK_TIERS
LOOKUP = is_lookup(tool)


# --- the counters ---------------------------------------------------------
#
# One small JSON file, rewritten under a lock. Two windows because they catch
# two different things: the DAY bounds a month`s share of a shared pool, and
# the HOUR is what actually catches "people will just set up crons" — a
# one-minute cron making two calls burns a generous daily allowance in eight
# hours and an hourly one in half an hour.
#
# The count happens BEFORE the call, so a call that then fails is still
# counted. That is the right direction for a budget: over-counting costs a
# person a few calls at the very end of a window, under-counting costs the
# bound its meaning.
BUDGET_DIR = os.path.join(home, "composio")
BUDGET_FILE = os.path.join(BUDGET_DIR, "budget.json")
LIMITS_FILE = os.path.join(BUDGET_DIR, "limits.json")
LOCK_DIR = os.path.join(BUDGET_DIR, "budget.lock")
# What the app reads to tell the PERSON, once, that a cap was hit. Until
# 2026-11-12 the refusal below reached only the model, which said whatever it
# made of it — or carried on as if the service were broken. Numbers and keys
# only, never a sentence: the app writes the words (ComposioCapNotice), so
# nothing that can write this file can put text in front of the person.
NOTICE_FILE = os.path.join(BUDGET_DIR, "cap-notice.json")


def note_cap_for_the_person(state, which, limit):
    """Leave the notice, once per window. Never raises, never decides: a
    notice that could not be written is a quieter refusal, not a different
    one."""
    key = hour_key if which == "hour" else day_key
    mark = which + ":" + key
    if state.get("cap_noticed") == mark:
        return
    state["cap_noticed"] = mark
    try:
        tmp = NOTICE_FILE + ".tmp"
        with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600),
                  "w", encoding="utf-8") as fh:
            json.dump({"window": which, "key": key, "limit": limit, "tier": TIER, "at": stamp},
                      fh, sort_keys=True)
        os.replace(tmp, NOTICE_FILE)
    except OSError:
        pass


def limits():
    """The two bounds: the tier`s, raised or lowered by a FILE, never by the
    environment.

    Not because a file is harder for the agent to reach — it is not; the
    agent can write anything the person can. Because a file can be GUARDED
    and the environment cannot. `limits.json` and `tier.json` are on the
    shell gate`s protected paths (configure-hermes.py, GATE_PROTECTED_PATHS)
    and the send gate`s write-only list (confirm-send.sh, GATE_WRITE_ONLY), so
    a tool call that would write either is refused before it runs. An
    environment variable is inherited by every child the gateway spawns and
    is set by `launchctl setenv` from any terminal, which no gate here sees.
    (Reviewer, 2026-09-06: the earlier version of this docstring had the
    argument backwards, and the two files were on neither list.)
    """
    per_hour, per_day = CAPS[TIER]
    try:
        with open(LIMITS_FILE, encoding="utf-8") as fh:
            doc = json.load(fh)
        if isinstance(doc, dict):
            h, d = doc.get("per_hour"), doc.get("per_day")
            if isinstance(h, int) and h > 0:
                per_hour = h
            if isinstance(d, int) and d > 0:
                per_day = d
    except (OSError, ValueError):
        pass
    return per_hour, per_day


def take_lock(deadline):
    while True:
        try:
            os.mkdir(LOCK_DIR, 0o700)
            return True
        except OSError as exc:
            if exc.errno != errno.EEXIST:
                return False
            # A lock left behind by something that died is not a reason to
            # refuse Composio for ever. Two seconds is far longer than the
            # read-modify-write below can take.
            try:
                if time.time() - os.stat(LOCK_DIR).st_mtime > 2:
                    os.rmdir(LOCK_DIR)
                    continue
            except OSError:
                pass
            if time.time() > deadline:
                return False
            time.sleep(0.01)


now = time.time()
day_key = time.strftime("%Y-%m-%d", time.localtime(now))
hour_key = time.strftime("%Y-%m-%dT%H", time.localtime(now))
stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
per_hour, per_day = limits()

try:
    os.makedirs(BUDGET_DIR, 0o700, exist_ok=True)
except OSError:
    out("BLOCK", "Composio budget hook: cannot open the call budget — refusing a metered call")

if not take_lock(now + 2.0):
    out("BLOCK", "Composio budget hook: the call budget is locked — refusing a metered call")

try:
    try:
        with open(BUDGET_FILE, encoding="utf-8") as fh:
            state = json.load(fh)
        if not isinstance(state, dict):
            state = {}
    except (OSError, ValueError):
        state = {}

    if state.get("day") != day_key:
        state["day"], state["day_calls"], state["day_lookups"] = day_key, 0, 0
    if state.get("hour") != hour_key:
        state["hour"], state["hour_calls"], state["hour_lookups"] = hour_key, 0, 0
    for k in ("day_calls", "hour_calls", "day_lookups", "hour_lookups"):
        if not isinstance(state.get(k), int) or state[k] < 0:
            state[k] = 0

    decision = ("PASS",)

    if on_a_clock and not clocks_allowed:
        # The clock rule. Record it: whether Moe SAYS anything about a
        # skipped scheduled check is a product decision that is still open
        # (§3.1), and it cannot be made at all unless the skip is written
        # down somewhere a person can be shown. This is that somewhere; the
        # first one is stamped separately so "say it once" stays available
        # as an answer.
        state["clock_skips"] = (state.get("clock_skips") or 0) + 1
        state.setdefault("first_clock_skip", stamp)
        state["last_clock_skip"] = stamp
        decision = ("BLOCK",
                    "Scheduled background checks against Google and the other "
                    "Composio-connected services are part of the paid plan, so "
                    "this one was skipped. Nothing is wrong and nothing is "
                    "disconnected: ask for it and Moe will look right now.")
    elif LOOKUP:
        # Reading the catalog: not drawn from the allowance, and bounded on
        # its own so that a loop of lookups still meets a wall.
        if (state["hour_lookups"] >= per_hour * LOOKUP_FACTOR
                or state["day_lookups"] >= per_day * LOOKUP_FACTOR):
            which = "hour" if state["hour_lookups"] >= per_hour * LOOKUP_FACTOR else "day"
            state["lookup_blocks"] = (state.get("lookup_blocks") or 0) + 1
            state["last_lookup_block"] = stamp
            decision = ("BLOCK",
                        "Moe has looked up tools for the connected services %d "
                        "times this %s without that being what anyone asked "
                        "for, and stopped. Use the tools already found, or say "
                        "plainly that this cannot be done right now."
                        % ((per_hour if which == "hour" else per_day) * LOOKUP_FACTOR, which))
        else:
            state["day_lookups"] += 1
            state["hour_lookups"] += 1
            state["last_lookup"] = stamp
    elif state["hour_calls"] >= per_hour or state["day_calls"] >= per_day:
        which = "hour" if state["hour_calls"] >= per_hour else "day"
        state["cap_blocks"] = (state.get("cap_blocks") or 0) + 1
        state["last_cap_block"] = stamp
        state["last_cap_window"] = which
        note_cap_for_the_person(state, which, per_hour if which == "hour" else per_day)
        decision = ("BLOCK",
                    "Moe has used its whole %s of calls to the connected "
                    "services (%d this %s) and stopped rather than keep "
                    "spending. It starts again at the top of the next %s."
                    % (which, per_hour if which == "hour" else per_day,
                       which, which))
    else:
        state["day_calls"] += 1
        state["hour_calls"] += 1
        state["last_call"] = stamp

    try:
        tmp = BUDGET_FILE + ".tmp"
        # O_NOFOLLOW: a planted symlink at the temp path must not redirect
        # the write. Same user, so a nuisance rather than an escalation — but
        # a budget that can be pointed at /dev/null is not a budget.
        with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600),
                  "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2, sort_keys=True)
        os.replace(tmp, BUDGET_FILE)
    except OSError:
        out("BLOCK", "Composio budget hook: cannot write the call budget — "
                     "refusing a metered call")
finally:
    try:
        os.rmdir(LOCK_DIR)
    except OSError:
        pass

out(*decision)
' 2>/dev/null)"

case "$DECISION" in
  PASS) exit 0 ;;
  BLOCK*) ;;
  *) block "Composio budget hook: the budget check did not answer — refusing a metered call" ;;
esac

REASON="${DECISION#BLOCK	}"
[ -n "$REASON" ] && [ "$REASON" != "$DECISION" ] || REASON="Composio call refused by Moe's call budget"

# The receipt. Whose decision, which tool, and nothing else — never an
# argument, because the arguments of a Composio call are the user's mail
# query, their calendar, their documents.
( umask 077
  mkdir -p "$MOE_HOME/logs" 2>/dev/null || exit 0
  TOOL="$(printf '%s' "$PAYLOAD" | python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("tool_name") or "?")[:80])
except Exception: print("?")' 2>/dev/null || echo "?")"
  printf '%s\tblock\ttool=%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TOOL" "$REASON" \
    >>"$MOE_HOME/logs/composio-budget.log" 2>/dev/null
) || true

block "$REASON"
