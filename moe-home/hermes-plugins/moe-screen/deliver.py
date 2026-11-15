"""Where a message addressed to `moe` actually goes.

Two halves, and both are plain files or Hermes's own CLI — nothing here
talks to a model:

* **The screen.** One JSON file per message under ``~/.moe/inbox/``, mode
  0600. The app polls that directory (``Conductor.watchForInbox``), speaks
  the text, shows it on the island and deletes the file. The inbox is a
  directory rather than one file so two reminders a second apart are two
  reminders, not one overwriting the other.

* **The connectors.** ``reminderChannels`` in ``~/.moe/config.json`` — the
  list Settings › Background writes — names the chat platforms the user
  wants reminders forwarded to. Each one is sent through ``hermes send
  --to <platform>``: Hermes's own credentials, Hermes's own home channel
  for that platform (the user's own phone), no gateway needed. Only BARE
  platform names are accepted. A chat id or an address can never be named
  here, for the same reason moe-blueprints closes its `deliver` list: a
  bare name resolves to the home channel the user set, and cannot be
  pointed at someone else.

Why the fan-out lives in the delivery target and not in each job's
``deliver`` string: a job's target is fixed when the job is made, and the
user changes their mind in Settings. Every Moe-made job says ``deliver:
moe``; what ``moe`` means is read at delivery time, so flipping a switch in
Settings takes effect on the next reminder without touching any job.

The third thing this file does is the **open-loop ledger**: a reply may end
with trailer lines, which are applied to ``~/.moe/proactive/open.json`` and
stripped before anything is shown, spoken or forwarded. See the ledger
section below for why the write path is a line of text rather than a tool.

Python 3.9, stdlib only — this runs inside Hermes's venv but must not depend
on anything Hermes might drop.
"""

import contextlib
import fcntl
import hashlib
import json
import logging
import os
import re
import unicodedata
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

logger = logging.getLogger(__name__)

INBOX_DIRNAME = "inbox"
CONFIG_KEY = "reminderChannels"
#: The platform name Hermes knows this target by.
PLATFORM = "moe"
#: The one chat id the screen has. Home channel and explicit target alike.
SCREEN = "screen"
#: Tokens that are never a connector, whatever config.json says.
_NOT_A_CONNECTOR = frozenset({PLATFORM, "local", "origin", "all", "api_server",
                              "cli", "cron", "bot-chat"})
_BARE_NAME = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
#: Hermes's `send` refuses nothing, so keep a spoken reminder in bounds.
MAX_CHARS = 4000
#: Per connector. The scheduler waits 60 s for the whole delivery and then
#: assumes it went; two slow connectors must still fit inside that.
SEND_TIMEOUT = 20


def moe_home():
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


def inbox_dir():
    return os.path.join(moe_home(), INBOX_DIRNAME)


def read_config():
    try:
        with open(os.path.join(moe_home(), "config.json"), encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        return {}
    return cfg if isinstance(cfg, dict) else {}


#: A separate yes for offers reaching the chat apps (review of the offer path
#: #9/#10): ticking a channel for reminders is not agreeing to drafts and
#: amounts from one's OTHER conversations being sent there. Off unless the
#: person turns it on.
OFFERS_TO_CHATS_KEY = "situationOffersToChats"


def offers_to_chats(cfg=None):
    cfg = read_config() if cfg is None else cfg
    return cfg.get(OFFERS_TO_CHATS_KEY) is True


def extra_channels(cfg=None):
    """The connectors the user asked reminders to be forwarded to.

    Bare platform names only, lower-cased, de-duplicated, in the order the
    user listed them. Anything else in the list is dropped silently: the
    app writes this key, and a hand edit that names a chat id must not
    become a delivery."""
    if cfg is None:
        cfg = read_config()
    raw = cfg.get(CONFIG_KEY)
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw:
        if not isinstance(item, str):
            continue
        name = item.strip().lower()
        if not _BARE_NAME.match(name) or name in _NOT_A_CONNECTOR:
            continue
        if name not in out:
            out.append(name)
    return out


# Hermes's cron wrapper, byte for byte from cron/scheduler.py:
#   Cronjob Response: <name>\n(job_id: <id>)\n-------------\n\n<content>\n\n
#   To stop or manage this job, send me a new message (e.g. "stop reminder <name>").
_WRAP_HEAD = re.compile(r"^\s*Cronjob Response:[^\n]*\n(?:\(job_id:[^\n]*\)\n)?(?:-{3,}\n)?\s*", re.I)
_WRAP_TAIL = re.compile(r"\s*\n+To stop or manage this job,[^\n]*\s*$", re.I)
# gateway/delivery.py appends this when it cuts a long delivery short.
_TRUNCATED = re.compile(r"\s*\n*\.{3}\s*\[truncated, full output saved to [^\]]*\]\s*$", re.I)

#: What Hermes puts on the front of a notice about itself. `⚠️` is U+26A0
#: plus the variation selector U+FE0F, `❗` and `⏱️` and the kanban marks are
#: others — Hermes has never been consistent and there is no reason it will
#: start. Stripped before the shape is read, in both copies of this rule.
#: Written as literals on purpose: the first version spelled these as
#: `\u1f6d1`, and `\u` takes exactly four hex digits — so 🛑 and 🔴 were
#: never in the set, and a stray "1" and "4" were.
_MARKS = "⚠♻❗⏱✖🛑🔴\ufe0f \t"

#: Moe's plumbing describing itself. One rule, and the list is of SHAPES —
#: how a notice opens — never of reasons, because the reasons are Hermes's
#: and it invents new ones. Each was read out of the Hermes source; the file
#: and line are in docs, and Tests/vectors/machinery-notices.json holds the
#: verbatim strings both this and the Swift copy are tested against.
#:
#:   Gateway …                      gateway/run.py:11088, :25401
#:   Cron 'name' …                  cron/scheduler.py:234-357
#:   Cron job 'name' …              gateway/run.py:11019   ← one word from the
#:                                  six that reached the island, and it fires
#:                                  on every gateway restart
#:   Agent session …                gateway/session_stall.py:63
#:   Agent inactive for …           gateway/run.py:30350
#:   Recovered reply …              gateway/delivery_ledger.py:70, :78
#:   Session database corruption …  gateway/run.py:25488
#:   Background process …           gateway/run.py:27144, :27168
#: "Gateway" on its own is a word people use — "Gateway is a word in this
#: reminder" was in the tests as a keeper and this rule swallowed it. Hermes's
#: gateway broadcasts always carry a mark, so that shape alone needs one; the
#: rest name themselves and do not.
_MARKED_ONLY = re.compile(r"^Gateway\b", re.I)

#: The job's name out of a cron notice, for the log line. "" when the
#: notice is not about a named job (a gateway broadcast, a background
#: process), which is a fine thing for a log line to say.
_JOB_NAME = re.compile(r"^Cron(?:\s+job)?\s+'([^']*)'", re.I)


def job_name(text):
    """The job a machinery notice is about, or ""."""
    if not isinstance(text, str):
        return ""
    m = _JOB_NAME.match(text.lstrip().lstrip(_MARKS + "["))
    return m.group(1) if m else ""

_MACHINERY = re.compile(
    r"^(?:"
    r"Cron(?:\s+job)?\s+'[^']*'"
    r"|Agent\s+(?:session\b|inactive\s+for\b)"
    r"|Recovered\s+reply\b"
    r"|Session\s+database\s+corruption\b"
    r"|Background\s+process\b"
    r")", re.I)


# The four SHAPES of a line that is not Moe's words. Shapes, not a list of
# sentences: `_MACHINERY` above is a list of sentences, its own docstring says
# the first six "were filtered one exit code at a time", and that is the failure
# this repo keeps writing down — a guard that enumerates names is walked past by
# a new name. On 2026-09-14 six new names walked past it at once, in the owner's
# own Telegram thread, and he asked "why does it show this technical stuff?".
#
# Each shape is a thing a PERSON DOES NOT HAVE. That is the test for admitting a
# new one here, and it is why these four are not arbitrary:
#
#   SLASH    an instruction to type a slash command. A person messaging Moe from
#            their phone has no command line. ("/busy queue", "`/stop`")
#   TOOL     a snake_case identifier announced with an ellipsis or a colon —
#            the shape of a tool id, which is a name the MODEL calls, never a
#            name a person knows. ("📧 gmail_status...", "🧠 moe_profile...")
#   PLUGIN   one of our own `moe-*` plug-in directory names. Open-ended on
#            purpose: it catches moe-ledger and moe-screen and equally the
#            plug-in nobody has written yet. ("🧠 moe-ledger — recalled 2…")
#   COUNTER  "iteration 3/60" — a loop bound. The person asked a question; they
#            did not enrol in a run. ("↪ Redirected current run (iteration 1/60)")
#
# Kept deliberately narrow so ordinary prose survives: SLASH wants a lowercase
# word after the slash and refuses a second one, so "/Users/me/notes" and
# "and/or" and "9/15" are not commands; TOOL must lead its line.
_NOT_MOES_WORDS = (
    ("slash command",   re.compile(r"(?:^|[\s`(\"'])/[a-z][a-z-]{1,15}\b(?!/)")),
    ("tool name",       re.compile(r"(?m)^\W{0,4}[a-z][a-z0-9]*(?:_[a-z0-9]+)+\s*(?:\.\.\.|…|:)")),
    ("plug-in name",    re.compile(r"\bmoe-[a-z][a-z0-9-]*\b")),
    # `(?i)` inline rather than the `re.I` argument, so this table and the one
    # in MachineryNotice.swift are the same strings character for character
    # and `test-only-moes-words.sh` §3b can say so.
    #
    # Deliberately NOT `iteration N/M`, which is what this was for a while. A
    # review asked the obvious question — "what about `↪ Resumed run (step
    # 2/9)`?" — and the answer was that it sailed through, because the shape
    # knew one word. The word is the part that varies (iteration, step, turn,
    # attempt); a labelled fraction is the part that does not.
    #
    # The PARENTHESES are not decoration and they are not a guess. The gateway
    # builds this detail as `status_detail = f" ({', '.join(status_parts)})"`
    # — measured in gateway/run.py, both at the busy-ack and at the
    # long-running heartbeat — so every counter it emits arrives inside a
    # bracket. That is what makes the shape safe: a bare labelled fraction
    # also describes "the invoice is due 10/1", "page 4/10 of the contract"
    # and "Section 2/3 is the one he means", and an earlier cut of this line
    # refused all three. Ordinary prose puts a fraction in a sentence; a
    # machine puts it in a bracket.
    ("loop counter",    re.compile(r"(?i)\([^)]*\b[a-z]+\s+\d{1,4}\s*/\s*\d{1,4}\b[^)]*\)")),
    # Hermes builds the memory indicator as "{glyph} {label} — {detail}"
    # (agent/memory_manager.py describe_recall). Matching the TEMPLATE rather
    # than the label catches a provider not called `moe-*` — which the plug-in
    # shape above cannot see, and which is one `memory.provider` away.
    ("memory indicator", re.compile(r"(?i)\brecalled\s+\d+\s+memor(?:y|ies)\b")),
)


#: Moe's own inline markup, removed before the shapes are read. See
#: `not_moes_words`. `MachineryNotice.swift` strips the same span.
#:
#: The second alternative is an opener that never closes — a truncated
#: delivery or a model typo, which `read_trailers` already consumes to the end
#: of the text for the same reason. Without it, `[[moe-open: dan-call | …`
#: with the `[[` chewed off by the mark-stripper reads as a plug-in name and
#: the person loses the reminder it was attached to.
_TRAILER_MARKUP = re.compile(r"\[\[.*?\]\]|\[\[.*", re.S)


def _reads_as_a_sentence(head):
    """True when this line ends the way a person's sentence ends.

    An ELLIPSIS does not count, and that exception is the whole reason this is
    a function rather than one `endswith` call: "📧 gmail_status..." ends in a
    full stop by the letter, and the first cut of this rule let every
    ellipsis-terminated tool trace through on exactly that technicality —
    which is to say it let through two of the six lines it was written for.
    A trailing "…" is a thing that has been interrupted, not a thing that has
    been said.

    `MachineryNotice.swift` has the same three-line function beside its own
    copy of the shapes."""
    if head.endswith("...") or head.endswith("…"):
        return False
    return head.endswith((".", "?", "!"))


def not_moes_words(text):
    """The shape that fails, or None when this reads as something Moe said.

    The rule a channel adapter is held to: whatever reaches a person is Moe's
    answer, and at most a short line in Moe's own voice. A tool id, a plug-in
    directory, a slash command or a loop counter is none of those, whoever
    generated it and whichever release adds the next one.

    Returns the NAME of the shape rather than True so a failure says which rule
    it broke and with what text — a test that only knows "something matched"
    sends its reader back to the regex to find out what."""
    if not isinstance(text, str) or not text.strip():
        return None
    # `[[moe-open: dan-call | … ]]` and its kin are Moe's own markup: the
    # ledger parser reads them and takes them off, so they are never words
    # reaching anybody and they are not this rule's business. Scanned without
    # them because they would otherwise trip the plug-in shape on `moe-open`
    # — which is a trailer keyword, not a plug-in — and cost the person the
    # whole reminder the trailer was riding on. (Measured: it took out 21 of
    # LedgerTest's 40 before this line existed.)
    text = _TRAILER_MARKUP.sub(" ", text)
    for name, shape in _NOT_MOES_WORDS:
        if shape.search(text):
            return name
    return None


#: Hermes and our plug-ins open a self-narration with a PICTOGRAPH — 📧 🧠 📅
#: ↪ ⏩ ⏳ 💡 💾 ⚠ ♻ — because the glyph is how a bubble is meant to read as
#: machinery at a glance. A person's answer does not open that way.
#:
#: This is the second line of defence and it was added on 2026-09-15, after
#: the G3 review ran real answers through the shape table and five of them
#: were DROPPED — each one a reply a person had asked for and would simply
#: never have received:
#:
#:     "…(option 1/3)\nUnited 7am, $320."        the counter shape
#:     "Here's what I found (page 2/5)"          the counter shape
#:     "total_cost: $412\nThat includes tax."    the tool shape
#:     "check_in_time: 3pm"                      the tool shape
#:     "Open /settings in the app, then tap Email"   the slash shape
#:
#: **A false positive here is worse than a false negative and it is not
#: close.** A machinery line that gets through is one ugly bubble; an answer
#: that is dropped is the person asking Moe something and getting silence,
#: with no trace of it anywhere they would look. The shapes were tuned the
#: other way round — "kept deliberately narrow so ordinary prose survives" —
#: and they were still not narrow enough, because a shape cannot tell
#: `total_cost:` from `gmail_status:` by looking at the identifier. The
#: GLYPH is what tells them apart, and it is not a heuristic: it is what the
#: emitting code puts there.
#:
#: Unicode category `So` (Symbol, other) is the test, so a glyph nobody has
#: used yet counts without being listed — the enumeration lesson again. `…`
#: is category `Po` and does NOT count, which is what saves the first line
#: above.
#:
#: The ONE exception, and it is narrow: a bare tool id with an ellipsis and
#: nothing after it (`moe_away_status…`) is in the corpus with no glyph,
#: because a tool registered with no emoji renders that way. A line that is
#: ONLY an identifier and an ellipsis is nobody's answer. An identifier
#: followed by a colon and a VALUE is data and is delivered — that is exactly
#: the difference between `moe_away_status…` and `check_in_time: 3pm`.
_BARE_TRACE = re.compile(r"^[a-z][a-z0-9]*(?:[_-][a-z0-9]+)+\s*(?:\.\.\.|…)\s*$")


def _narrates_itself(head):
    """Does this line OPEN the way machinery opens — with a pictograph?

    See `_BARE_TRACE` above for why this gate exists and what the one
    exception is."""
    stripped = head.lstrip(_MARKS)
    if _BARE_TRACE.match(stripped.strip()):
        return True
    for ch in head:
        if ch.isspace() or ch in "\ufe0f":
            continue
        return unicodedata.category(ch) == "So"
    return False


def is_machinery(text):
    """True when this is Moe's plumbing talking, not a message for a person.

    Not "any failure except the real ones" — every one of them. Moe is not a
    technical product, and there is no such thing as one of these written in
    a form a person can act on. Every one is an exit code, a traceback, a
    stderr tail, a slash command, a config key, or advice to run `hermes`:

        ⚠️ Cron 'moe-proactive' failed: claude exited unexpectedly (code 143)
        ⚠️ Cron job 'moe-proactive' was interrupted — the gateway is restarting…
        ⚠️ Agent session appears stalled (last activity 12 min ago). Try /new…
        ⚠️ Session database corruption detected… Run `hermes doctor --fix`
        [Background process 3de34721 finished with exit code 1~ …]

    The first six of these reached the island and were filtered one exit code
    at a time; the next four were found by reading Hermes's source rather
    than waiting for them to arrive. **The rule is the shape, never the
    reason** — `Cron job '…' was interrupted` is one word away from the six
    and fires on every gateway restart, which on this Mac is several times an
    hour while someone is in Settings.

    Nothing is lost. A job that is failing already says so in plain words in
    Settings › Background — "Watching pulse · needs a look" — which is a
    place someone chooses to go, not an amber light in the middle of their
    morning, and `note_machinery` writes the raw text to the log.

    A failure a person really should hear about has to be said in Moe's own
    voice by whatever knows what it means. It cannot be Hermes's sentence
    with the emoji taken off."""
    if not isinstance(text, str):
        return False
    t = text.lstrip()
    bare = t.lstrip(_MARKS + "[")
    if _MACHINERY.match(bare):
        return True
    # The shapes — but only in the FIRST LINE, and only when that line does not
    # read as a sentence. Dropping is the whole message, so this side of the
    # rule is the conservative one, and the three conditions are each load-
    # bearing: a notice LEADS with its machinery ("📧 gmail_status...", "🧠
    # moe-ledger — recalled 2 memories"), it is SHORT, and it does not end in
    # sentence punctuation the way an answer does. An answer that happens to
    # mention a file name or a path keeps all three the other way round.
    #
    # `MachineryNotice.swift` implements these same three conditions, in the
    # same order. **This is one rule with two copies**, and the first time
    # that was true they disagreed four ways while each suite proved only its
    # own; both now read Tests/vectors/machinery-notices.json. Change the rule
    # in both, or in neither.
    # The markup comes off BEFORE the marks do: `bare` has already had a
    # leading "[" stripped by the mark-stripper above, which would leave
    # `moe-open: …` looking exactly like a plug-in narrating itself.
    # `opener` keeps the marks; `head` has them off. The glyph gate reads the
    # OPENER, because a mark (⚠ ♻ ❗) is itself a pictograph and stripping it
    # first would make `⚠ moe-ledger — recalled 2` look like a person's line.
    opener = _TRAILER_MARKUP.sub(" ", t).split("\n", 1)[0].rstrip()
    head = _TRAILER_MARKUP.sub(" ", t).lstrip(_MARKS + "[").split("\n", 1)[0].rstrip()
    if head and len(head) <= 200 and not _reads_as_a_sentence(head) \
            and _narrates_itself(opener) and not_moes_words(head):
        return True
    # Only with one of Hermes's marks in front of it.
    return bare != t and bool(_MARKED_ONLY.match(bare))


#: A model's tool call written out as text — the child had no tools that
#: turn (hermes-tools failed to connect), so it typed the calls it meant to
#: make and stopped. 2026-09-30 09:17: `<invoke name="skill_view">…` reached
#: the island and Telegram as the marketing monitor's "reply". No answer to
#: a person contains these tags.
_TOOL_MARKUP = re.compile(r"<\s*(?:invoke|parameter)\s+name\s*=|<\s*/?\s*(?:function_calls|invoke)\s*>", re.I)
#: The silence marker on a line of its own inside a longer reply: Hermes
#: swallows a reply that IS the marker, not one that ends with it.
_SILENT_LINE = re.compile(r"^[ \t]*\[SILENT\][ \t]*$", re.M)


#: A reply that says nothing, in the words models use for it — the Swift
#: twin is `MachineryNotice.isSilence`.
_SILENCE_WORDS = frozenset(("noop", "no-op", "no_reply", "no reply", "[silent]", "silent", "(no response)",
                            "no response", "nothing to report"))


def is_tool_markup(text):
    return isinstance(text, str) and bool(_TOOL_MARKUP.search(text))


#: The background pass talking to itself instead of to the person: "the
#: user", "the loop", a slug. 2026-09-30 08:58 and 09:58, from the cloud:
#: "The one due loop is Andrew Wilson prep — but … not something worth
#: nagging about yet." Moe speaks to "you", and never about its ledger.
_SELF_TALK = re.compile(
    r"\bthe user(?!(?:'s)?\s+(?:manual|guide|interface|experience|account|name|id|agreement|group|base|story|stories))"
    r"(?:'s)?\b"
    r"|\b(?:due|open) loops?\b|\braise time\b|\bmonitor output\b|\bmoe-(?:open|close)\b", re.I)
#: A loop's name as the pass writes it: two hyphens or more ("andrew-
#: followup-prep"). One hyphen is ordinary English ("check-in", "follow-up").
_SLUG_SHAPED = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+){2,}$")


def talks_to_itself(text, slugs=()):
    """True when the pass's words are its own deliberation, not a sentence
    for the person."""
    if _SELF_TALK.search(text or ""):
        return True
    low = (text or "").lower()
    return any(_SLUG_SHAPED.match(s) and re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(s), low)
               for s in slugs)


def scrub(text):
    """The write-time backstop, ~/.moe/lib/redact.py `scrub_ids`: an SSN
    shape or an explicitly labelled identifier never reaches the screen or
    a chat app, whatever a prompt let through. A missing lib is a missing
    backstop, not a reason to drop the reminder — the primary control is
    upstream (metadata-only reads, no verbatim), and a reminder someone
    asked for must still arrive."""
    lib = os.path.join(moe_home(), "lib")
    try:
        if lib not in sys.path:
            sys.path.insert(0, lib)
        import redact  # noqa: WPS433
        return redact.scrub_ids(text)
    except Exception:
        return text


def clean(text):
    """The text as it should be spoken.

    Hermes wraps cron output in a "Cronjob Response: <name>" header and a
    "To stop or manage this job" footer unless ``cron.wrap_response`` is
    off. Moe turns that off, but a job created before it was, or on a
    machine where someone turned it back on, would otherwise be read aloud
    header first. The truncation footer names a file path; nobody wants
    that spoken either."""
    if not isinstance(text, str):
        return ""
    text = _WRAP_HEAD.sub("", text, count=1)
    text = _WRAP_TAIL.sub("", text, count=1)
    text = _TRUNCATED.sub("", text, count=1)
    return text.strip()


# ── The open-loop ledger ─────────────────────────────────────────────────
#
# `~/.moe/proactive/open.json`, 0600, atomic: the things a PERSON is waiting
# on the user for. `moe-brief-monitor.sh` reads it and prints one line per
# loop as `due`, `stalled` or `later`, which is what wakes `moe-proactive`
# when a raise time passes on a brief that did not move
# (moe-home/hermes-jobs/README.md).
#
# It is written HERE, from trailer lines the agent puts at the end of its own
# reply:
#
#     [[moe-open: dan-call | Dan asked for a call this week | raise 3h]]
#     [[moe-close: invoice-question]]
#
# The agent has no tool to call and no command to run, which is the whole
# point. The obvious store — Hermes's own cron notepad — has no model tool:
# its only write path is `hermes cron notepad <job_id> set` through the
# TERMINAL tool, and moe-proactive reads the user's mail and chats, which is
# exactly the text a prompt injection arrives in. A shell on that job is what
# such an injection wants; a line of text in a reply is not.
#
# ── ONE JOB IS TOLD ABOUT TRAILERS, AND ONLY THAT JOB WRITES THE LEDGER ──
#
# `deliver()` is the whole `moe` platform: every reminder cron the user makes,
# `hermes send --to moe`, an agent's send_message, moe-learn-deep's failures.
# Most of those quote text the user did not write — a mail body, a chat
# message — and a digest that quotes
#
#     [[moe-open: bank-hold | Call your bank on 555-0100 | raise 0h]]
#
# out of a phishing mail must not become a permanently-due entry that Moe
# then reads aloud in its own voice at a time the sender chose.
#
# So the parse is scoped to `LEDGER_JOB`, the one job whose prompt documents
# trailers and whose replies are the agent's own words about the user's own
# brief. The job name comes from the job record (adapter.py `_job_delivers_to`)
# and nothing else: `_standalone_send` passes none, so `hermes send --to moe`
# can never write the ledger, and an unknown or absent name is "do not parse".
#
# A trailer-looking line on any OTHER job is STRIPPED AND LOGGED, never
# applied: the rest of the message is delivered as it stands, and the line
# itself is not spoken — it is bookkeeping noise whichever job it came from,
# and reading `[[moe-open: …]]` out loud helps nobody. The ledger is not
# touched, so nothing an attacker plants survives the delivery.
#
# Trailers are applied and removed in `deliver()` BEFORE `clean`/`scrub` and
# before the fan-out, so a line of bookkeeping can never be shown on the
# island, spoken aloud, or forwarded to a chat app. A reply that is nothing
# but trailers therefore delivers nothing — and that is a success, not the
# "empty message" error, or the scheduler would report a delivery failure
# for a run that did exactly what it should.
#
# ── AND EVERY LOOP ENDS ──────────────────────────────────────────────────
#
# "Say it three hours later, then in the morning, then daily, then stop"
# was a promise the prompt made and the code did not keep, which is the same
# as not keeping it: a model that miscounts, or a `raise 0h`, gave a loop
# that was due for ever and woke the agent every 30 minutes. The ceiling is
# enforced here now — `MAX_SAID` mentions, `MAX_AGE_DAYS` days, and a raise
# time that can never be nearer than `MIN_RAISE_HOURS` — so the number of
# times any one loop can ever wake the agent is bounded by arithmetic rather
# than by the model behaving.
OPEN_DIRNAME = "proactive"
OPEN_FILENAME = "open.json"
#: The lock two writers take before a read-modify-write of the ledger. Only
#: one job writes it today, and the scheduler serialises that job — but a
#: lost update is a follow-up that silently never comes back, and flock on a
#: file we already own costs nothing.
LOCK_FILENAME = "open.json.lock"
#: What has already had its run, so a slug cannot start a fresh
#: budget of four the moment it expires. Kept for MAX_AGE_DAYS — except a
#: slug the PERSON muted, which is kept until they say otherwise
#: (`_MUTED_UNTIL`).
CLOSED_FILENAME = "closed.json"
#: NOT downgrade-safe, and deliberately not pretended to be: a Moe from
#: before mute existed reads only the bare-ISO shape and drops every dict
#: entry it finds, so going backwards loses the mutes AND the run-out
#: tombstones in one go. Both shapes cannot be written at once — the old
#: reader requires a string — and a mute is worth more than a clean
#: revert. Documented rather than solved.
#: `until` on a tombstone the user asked for. "Do not remind me about that
#: any more" is not a seven-day request, and a mute that quietly lapsed
#: after a week would bring the same sentence back with no new reason.
#: `unmute_loop` is the only thing that lifts it.
_MUTED_UNTIL = "never"
#: A mute the person lifted: kept, dated, instead of deleted, so the Mac and
#: the cloud computer can tell "lifted on Tuesday" from "muted on Monday"
#: when their copies of closed.json meet (moeledger documents.merge_closed).
#: It blocks nothing; it ages out like any tombstone.
_LIFTED = "lifted"
#: The one cron job whose replies are read as ledger writes. Its `name` in
#: Hermes's job record, which is what the adapter hands `deliver()`.
LEDGER_JOB = "moe-proactive"
#: Loops kept at once. Past this the oldest `first` is evicted: a ledger is
#: for what is live, and 50 open loops is already a person in trouble.
MAX_OPEN = 50
#: One loop's description. The monitor prints it back; the block is capped.
MAX_WHAT = 200
#: How many times one loop may ever be mentioned. The fourth `moe-open` for
#: a slug is its last; the fifth closes it instead. See the module note.
MAX_SAID = 4
#: And how old it may get, whatever the count. Both are enforced on the
#: write side and again in the monitor's block, so neither a stalled reply
#: nor a hand-edited file can leave something due for ever.
MAX_AGE_DAYS = 7
#: The soonest a loop may be raised again. `0h`, `-1h` and an ISO instant in
#: the past all land here: without a floor they make an entry that is due
#: the moment it is written and for ever after, which is a wake-up every
#: tick. One hour is also what the prompt asks for when it defers a loop.
MIN_RAISE_HOURS = 1
#: And the furthest out. Also the answer for a date arithmetic cannot reach
#: (`9999-12-31T23:59:59-14:00` overflows `astimezone`).
MAX_RAISE_DAYS = 365
#: Slugs are the agent's own names for its loops and end up in a filename-
#: shaped key, so they are kept to something that cannot be a path, a shell
#: word or a surprise: lower case, digits, hyphens. `\Z`, not `$`: `$` also
#: matches before a trailing newline, and "dan-call\n" is a second slug.
_SLUG = re.compile(r"^[a-z0-9-]{1,40}\Z")
#: Every dash a model might type between `moe` and `open`. A non-breaking
#: hyphen is invisible in a reply and would otherwise be a trailer that got
#: spoken instead of applied.
_DASHES = "\\-\u2010\u2011\u2012\u2013\u2014\u2015\u2212\u00ad"
_HEAD = r"\[\[\s*moe\s*[%s]\s*(open|close)\s*:" % _DASHES
#: A whole line that is one trailer, with any trailing punctuation the model
#: added ("…]]."). Greedy to the last `]]` on the line, so a `]]` inside the
#: description stays inside it.
_TRAILER_LINE = re.compile(r"^[ \t]*" + _HEAD + r"(.*)\]\][ \t]*[.!?,;:]*[ \t]*$", re.I)
#: The same thing anywhere else: on the end of a sentence, with a newline
#: inside it, three of them on one line. Line-anchoring was the bug — the
#: common model mistakes all landed outside the anchor and got spoken.
_TRAILER_ANY = re.compile(_HEAD + r"(.*?)\]\][ \t]*[.!?,;:]*", re.I | re.S)
#: Anything that OPENS like a trailer and never closes: a truncated
#: delivery, a model typo. Half a directive is not a sentence and must not be
#: read out either, so it and everything after it is dropped.
_TRAILER_ISH = re.compile(_HEAD.replace("(open|close)", "(?:open|close)")
                          .replace(r"\s*:", r"\b"), re.I)
#: `3h`, `2d`, and the `-1h` a model writes when it means "overdue" —
#: bounded so a garbled number cannot overflow a date, and floored below so
#: a negative one cannot mean "due for ever".
_RELATIVE = re.compile(r"^([+-]?\d{1,4})\s*([hd])$", re.I)
#: What `raise` falls back to, in hours, for anything unreadable.
DEFAULT_RAISE_HOURS = 3
#: Control characters never belong in a description the monitor prints back.
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")

# ── Kinds, checks, and the second write path (docs/LOOPS.md) ─────────────
#
# Until 2026-09-10 a loop was one thing: a person waiting on the user, opened
# by the background pass from the brief. The owner's brief that day, after
# reading Instinct's transcripts: "it should be architected so generally it
# covers everything" — what they said they would do, what Moe started, a
# deadline, a price they looked at. So an entry carries a `kind`, may carry
# a `check` (how a script watches it without a model), and has a second
# writer: the brain in the person's own turn, through `moe_followups open`.
#
# The trust story is different for the two writers and the code keeps them
# apart. The pass reads mail and chats, where injections arrive, so it still
# writes by trailer and holds no tool. The turn is the person's own words
# and Moe's own work; the worst an injected line in a pasted mail can do
# through `open_loop` is a nudge later, never an action, and `source` says
# which path wrote the entry.
#: The five kinds, and nothing that cannot be one of them. `waiting` is the
#: default so a ledger from before kinds existed reads exactly as it did.
KINDS = ("said", "started", "waiting", "deadline", "watch")
DEFAULT_KIND = "waiting"
#: Who wrote the entry: the background pass by trailer, or the brain in the
#: person's own turn through the tool.
SOURCE_PASS = "pass"
SOURCE_TURN = "conversation"
#: What a check may be. `url` is slice 1; `connector` is slice 1b.
CHECK_VIAS = ("url",)
#: How often a check may run. The floor keeps a loop from becoming a
#: five-minute poll of somebody's server; the default suits a price.
CHECK_MIN_MINUTES = 15
CHECK_DEFAULT_MINUTES = 6 * 60
CHECK_MAX_DAYS = 7
#: A `find` regex is the model's own and is compiled here before it is
#: stored, so a broken one is refused at the tool and not at the check.
MAX_FIND_CHARS = 200
MAX_URL_CHARS = 2000
#: The bit of the page a check keeps to show the person what moved.
MAX_EXCERPT = 160
_HTTP_URL = re.compile(r"^https?://[^\s]+$", re.I)
_EVERY = re.compile(r"^(\d{1,4})\s*([mhd])$", re.I)


#: What has happened to a loop so far, newest last, so the pass speaks with
#: the context — "this is the third time the price has moved; last time
#: they said not yet" — rather than as if each raise were the first. Kept
#: short: it is printed to the model on every due tick.
MAX_HISTORY = 8
MAX_HISTORY_TEXT = 160


def _remember(entry, now, event):
    """Append one line to the loop's history. Never raises."""
    try:
        text = " ".join(_CONTROL.sub(" ", str(event or "")).split())[:MAX_HISTORY_TEXT]
        if not text:
            return
        history = entry.get("history")
        if not isinstance(history, list):
            history = []
        history.append({"at": _stamp(now), "event": text})
        entry["history"] = history[-MAX_HISTORY:]
    except Exception:  # noqa: BLE001
        pass


def normalise_kind(kind):
    """One of KINDS, or the default. Never raises."""
    k = str(kind or "").strip().lower()
    return k if k in KINDS else DEFAULT_KIND


def parse_every(spec):
    """`15m`, `6h`, `2d` → minutes, bounded. None for nothing readable."""
    m = _EVERY.match(str(spec or "").strip())
    if not m:
        return None
    n = int(m.group(1))
    unit = m.group(2).lower()
    minutes = n * (1 if unit == "m" else 60 if unit == "h" else 1440)
    return max(CHECK_MIN_MINUTES, min(minutes, CHECK_MAX_DAYS * 1440))


def normalise_check(check):
    """A check as it may be stored, or None (no check) — and a reason.

    Returns (check_or_None, error). An absent or empty check is fine; a
    present one that cannot be run is an error the tool reports, because a
    watch that silently has no check is a loop that never fires."""
    if check in (None, "", {}):
        return None, ""
    if isinstance(check, str):
        try:
            check = json.loads(check)
        except ValueError:
            return None, "check must be an object"
    if not isinstance(check, dict):
        return None, "check must be an object"
    via = str(check.get("via") or "url").strip().lower()
    if via not in CHECK_VIAS:
        return None, "check.via must be one of %s" % ", ".join(CHECK_VIAS)
    url = str(check.get("url") or "").strip()
    if not _HTTP_URL.match(url) or len(url) > MAX_URL_CHARS:
        return None, "check.url must be an http(s) address"
    out = {"via": via, "url": url}
    find = check.get("find")
    if find not in (None, ""):
        find = str(find)
        if len(find) > MAX_FIND_CHARS:
            return None, "check.find is too long"
        try:
            re.compile(find)
        except re.error as e:
            return None, "check.find is not a regular expression: %s" % e
        out["find"] = find
    every = parse_every(check.get("every")) if check.get("every") else CHECK_DEFAULT_MINUTES
    if every is None:
        return None, "check.every must be like 30m, 6h or 2d"
    out["every"] = "%dm" % every
    return out, ""


def check_minutes(entry):
    """How often this entry's check runs, in minutes, or 0 for no check."""
    check = entry.get("check") if isinstance(entry, dict) else None
    if not isinstance(check, dict):
        return 0
    return parse_every(check.get("every")) or CHECK_DEFAULT_MINUTES


def open_dir():
    return os.path.join(moe_home(), OPEN_DIRNAME)


def open_path():
    return os.path.join(open_dir(), OPEN_FILENAME)


def _stamp(when):
    """UTC ISO 8601 with a Z — one spelling, so the file sorts and compares."""
    return (when.astimezone(timezone.utc).replace(microsecond=0)
            .isoformat().replace("+00:00", "Z"))


def _parse_stamp(text):
    """An ISO instant from the ledger, or None. Never raises."""
    text = str(text or "").strip()
    if not text:
        return None
    if text[-1:] in ("Z", "z"):
        text = text[:-1] + "+00:00"
    try:
        when = datetime.fromisoformat(text)
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        return when.astimezone(timezone.utc)
    except (ValueError, OverflowError, OSError):
        return None


def read_open():
    """The ledger, or {} for a missing, unreadable or nonsense one.

    A corrupt file is not an error and not a crash: the next write replaces
    it. Losing a ledger costs a follow-up; refusing to deliver costs the
    reminder the person was waiting for."""
    try:
        with open(open_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    loops = data.get("open") if isinstance(data, dict) else None
    if not isinstance(loops, dict):
        return {}
    out = {}
    for slug, entry in loops.items():
        if isinstance(slug, str) and _SLUG.match(slug) and isinstance(entry, dict):
            out[slug] = dict(entry)
    return out


def write_open(loops):
    """Replace the ledger. Atomic (tmp + rename) and 0600, like the inbox:
    the monitor reads this file every tick and must never see half of one,
    and `what` quotes a person's mail.

    fsync before the rename and the tmp file removed on any failure: a
    zero-length open.json reads as "no open loops", which is every follow-up
    silently gone, and a directory slowly filling with open.json.tmp.<pid>
    is a bug nobody notices until the disk does."""
    d = open_dir()
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    path = open_path()
    tmp = path + ".tmp.%d" % os.getpid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"open": loops}, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        # The rename itself, so a power cut leaves the old ledger or the new
        # one and never neither.
        fd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass
    return path


@contextlib.contextmanager
def ledger_lock():
    """Exclusive across processes for the ledger's read-modify-write.

    Best effort by design: if the lock cannot be taken the write still
    happens. A missed follow-up is worse than a racy one, and the monitor —
    the only reader — never takes it, because a rename is atomic and it must
    never block a tick."""
    fd = None
    try:
        os.makedirs(open_dir(), exist_ok=True)
        fd = os.open(os.path.join(open_dir(), LOCK_FILENAME),
                     os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError as e:
        logger.info("open loop: no ledger lock (%s) — writing anyway", e)
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
            fd = None
    try:
        yield
    finally:
        if fd is not None:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(fd)
            except OSError:
                pass


def parse_raise(spec, now):
    """When this loop should be mentioned again, as a UTC instant.

    `3h`, `2d`, `tomorrow-morning` (08:00 local, the next day) or an ISO 8601
    instant. Anything else is three hours and a log line: a raise time nobody
    can read must not become a loop that never comes back, and must not stop
    the reply being delivered either.

    Whatever it says, the answer is between an hour and a year from now.
    `0h`, `-1h` and `2020-01-01T00:00:00Z` all mean "due the moment it is
    written and for ever after", which is a wake-up every tick until
    something else stops it; and a year is past the age at which a loop is
    dropped anyway, so a date arithmetic cannot even represent is no loss."""
    floor = now + timedelta(hours=MIN_RAISE_HOURS)
    ceiling = now + timedelta(days=MAX_RAISE_DAYS)

    def bounded(when):
        try:
            when = when.astimezone(timezone.utc)
            if when < floor:
                logger.info("open loop: raise %r is not in the future — %dh",
                            spec, MIN_RAISE_HOURS)
                when = floor
            elif when > ceiling:
                when = ceiling
        except (OverflowError, ValueError, OSError):
            when = ceiling
        return _stamp(when)

    text = (spec or "").strip()
    if text[:5].lower() == "raise":
        text = text[5:].strip()
    low = text.lower()
    found = _RELATIVE.match(low)
    if found:
        n = int(found.group(1))
        return bounded(now + timedelta(hours=n * (24 if found.group(2).lower() == "d" else 1)))
    if low in ("tomorrow-morning", "tomorrow morning"):
        return bounded(_tomorrow_morning(now))
    if low:
        stamp = text
        if stamp[-1:] in ("Z", "z"):
            stamp = stamp[:-1] + "+00:00"
        try:
            when = datetime.fromisoformat(stamp)
        except ValueError:
            pass
        else:
            if when.tzinfo is None:
                # No offset: the agent meant the user's clock.
                when = when.replace(tzinfo=_local_offset(now))
            return bounded(when)
    logger.info("open loop: unreadable raise %r — using %dh", spec, DEFAULT_RAISE_HOURS)
    return bounded(now + timedelta(hours=DEFAULT_RAISE_HOURS))


def _local_offset(now):
    """This Mac's UTC offset at `now`, as a fixed-offset tzinfo."""
    return now.astimezone().tzinfo


def _tomorrow_morning(now):
    """08:00 local on the next calendar day, through the C library's own
    DST table.

    `now.astimezone() + timedelta(days=1)` is the obvious version and is
    wrong twice a year: `astimezone()` hands back TODAY's fixed offset, and
    adding 24 hours to it keeps that offset over a clock change. Measured
    with TZ=America/New_York: 31 October 2026 gave 07:00 EST and 7 March
    2026 gave 09:00 EDT. So the wall clock is built naively — dates have no
    DST — and `time.mktime` resolves it, which is the one stdlib call that
    asks the platform what the offset will actually be that morning."""
    local = time.localtime(now.timestamp())
    day = datetime(local.tm_year, local.tm_mon, local.tm_mday) + timedelta(days=1)
    try:
        epoch = time.mktime((day.year, day.month, day.day, 8, 0, 0, 0, 1, -1))
    except (OverflowError, ValueError, OSError):
        return now + timedelta(days=1)
    return datetime.fromtimestamp(epoch, timezone.utc)


def closed_path():
    return os.path.join(open_dir(), CLOSED_FILENAME)


def _read_closed(now):
    """{slug: {"at": when it was let go, "until": when it may come back}},
    minus the ones old enough to forget.

    Its own small file rather than a key in the ledger: the ledger's shape
    is what the monitor reads every tick, and this is nobody's business but
    the writer's.

    Two shapes are read, because the first one shipped before mute existed
    and a Mac that updates mid-week must not lose its tombstones: a bare
    ISO string is "let go at that time, forgettable after MAX_AGE_DAYS",
    and a dict is the same plus an `until`. `until: never` is a mute the
    person asked for and is never pruned."""
    try:
        with open(closed_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    out = {}
    if isinstance(data, dict):
        for slug, value in data.items():
            if not (isinstance(slug, str) and _SLUG.match(slug)):
                continue
            if isinstance(value, str):
                when, until = value, ""
            elif isinstance(value, dict):
                when = value.get("at")
                until = value.get("until")
                when = when if isinstance(when, str) else ""
                until = until if isinstance(until, str) else ""
                lifted = value.get("lifted") if isinstance(value.get("lifted"), str) else ""
            else:
                continue
            at = _parse_stamp(when)
            if at is None:
                continue
            # A mute, and a mute lifted, are the person's own answers and are
            # kept: a lifted one that aged out let the other side's older
            # mute come back a week later (review 2026-09-29).
            if until not in (_MUTED_UNTIL, _LIFTED) and not (isinstance(value, dict) and lifted) \
                    and now - at > timedelta(days=MAX_AGE_DAYS):
                continue
            out[slug] = {"at": when, "until": until}
            if isinstance(value, dict) and lifted:
                out[slug]["lifted"] = lifted
    return out


def _in_tombstones(slug, loops, now):
    return (_read_closed(now).get(slug) or {}).get("until", _LIFTED) != _LIFTED


def is_muted(slug, now=None):
    """True when the person asked for this one to stop coming back."""
    kept = _read_closed(now or datetime.now(timezone.utc))
    return (kept.get(slug) or {}).get("until") == _MUTED_UNTIL


def _write_closed(kept):
    """Replace closed.json. Never raises — a tombstone that cannot be
    written costs a repeat, and a raised exception costs the delivery."""
    d = open_dir()
    try:
        os.makedirs(d, exist_ok=True)
        os.chmod(d, 0o700)
    except OSError:
        pass
    tmp = closed_path() + ".tmp.%d" % os.getpid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(kept, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, closed_path())
    except OSError as e:
        logger.warning("open loop: could not write closed.json: %s", e)
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _tombstone(slug, now, until=""):
    """Remember that this loop is over, and for how long it stays over.

    Expiry writes here with no `until` — Moe has said this four times and
    is letting go, and MAX_AGE_DAYS later the same mail may legitimately
    start it again. A deliberate `moe-close` never writes here at all:
    closing is "the person dealt with it", and something genuinely dealt
    with that comes back is new and worth raising.

    `until=_MUTED_UNTIL` is the third case and the only one a PERSON asks
    for: "stop reminding me about that". That one is not a seven-day
    reprieve, so it is never pruned and only `unmute_loop` lifts it."""
    kept = _read_closed(now)
    prior = kept.get(slug) or {}
    if until != _MUTED_UNTIL and prior.get("until") == _MUTED_UNTIL:
        # A run-out never undoes the person's mute (review 2026-09-29).
        return
    kept[slug] = {"at": _stamp(now), "until": until}
    # A run-out over a mute the person lifted keeps when they lifted it: the
    # other side may still hold the older mute, and only this date says the
    # lift came after it (moeledger documents._closed_wins).
    lift = prior.get("at") if prior.get("until") == _LIFTED else prior.get("lifted")
    if until != _MUTED_UNTIL and lift:
        kept[slug]["lifted"] = lift
    if len(kept) > MAX_OPEN * 2:
        # The person's own answers (a mute, a mute lifted) are never the
        # ones evicted; the run-out tombstones are bookkeeping and are.
        aged = [s for s in kept if (kept[s] or {}).get("until") not in (_MUTED_UNTIL, _LIFTED)
                and not (kept[s] or {}).get("lifted")]
        for old in sorted(aged, key=lambda s: str((kept[s] or {}).get("at") or ""))[
                :len(kept) - MAX_OPEN * 2]:
            del kept[old]
    _write_closed(kept)


def _expired(entry, now):
    """Why this loop is over, or "". The ceiling the prompt promises.

    A loop with no readable `first` is never aged out — it is `said` that
    ends it — because a hand-edited or half-written entry that vanishes is
    a follow-up the person never hears about again."""
    said = entry.get("said")
    if isinstance(said, int) and said >= MAX_SAID:
        return "said %d" % said
    first = _parse_stamp(entry.get("first"))
    if first is not None and now - first > timedelta(days=MAX_AGE_DAYS):
        return "older than %d days" % MAX_AGE_DAYS
    return ""


def prune_open(loops, now):
    """Drop the loops that have run out of mentions or days. True if any went.

    The monitor hides these from its block on the same rule, so this is
    housekeeping rather than the control — but a ledger that only ever grows
    would evict live loops to make room for dead ones."""
    gone = False
    for slug in sorted(loops):
        why = _expired(loops[slug], now)
        if why:
            logger.info("open loop: letting %s go (%s)", slug, why)
            del loops[slug]
            _tombstone(slug, now)
            gone = True
    return gone


def _fields(body):
    """(slug, what, raise) from the inside of one trailer.

    Split on `|`, but the time is only the last field when it says so:
    `[[moe-open: dan-call | Dan, re: the call | raise 3h]]` used to become
    what="Dan", raise="re: the call" (unreadable, so three hours) — a comma
    in someone's name quietly rewrote the schedule.

    A `kind <k>` field anywhere after the slug is the loop's kind and is
    taken out of `what`; see `_fields_kind` for the value."""
    parts = [p.strip() for p in str(body).split("|")]
    slug = parts[0] if parts else ""
    rest = parts[1:]
    when = ""
    if rest and rest[-1][:5].lower() == "raise":
        when = rest.pop()
    rest = [p for p in rest if not _is_kind_field(p)]
    return slug, " | ".join(p for p in rest if p), when


def _is_kind_field(part):
    return str(part or "").strip().lower()[:5] == "kind " or \
        str(part or "").strip().lower() == "kind"


def _trailer_kind(body):
    """The `kind <k>` field of a trailer, normalised; "" when there is none."""
    for part in str(body).split("|"):
        if _is_kind_field(part):
            return normalise_kind(str(part).strip()[5:])
    return ""


def _fields_kind(body):
    """The kind a trailer names, or the default."""
    return _trailer_kind(body) or DEFAULT_KIND


def _apply_open(kind, body, loops, now, quiet=False):
    """One trailer against the in-memory ledger. True if it changed it.
    `quiet`: the reply this rides on says nothing to the person (it was only
    trailers, or its sentence was held back) — a re-open then moves the
    raise and counts NO mention, so four silent passes cannot retire a loop
    the person never heard (review of no-machine-talk #2)."""
    slug, what, when = _fields(body)
    if not _SLUG.match(slug):
        logger.warning("open loop: refusing slug %r", slug[:60])
        return False
    if kind == "close":
        if loops.pop(slug, None) is None:
            # Closing something already closed (or never opened) is how a
            # tidy-up reads. Not an error.
            logger.info("open loop: close %s — nothing open", slug)
            return False
        return True
    what = " ".join(_CONTROL.sub(" ", what).split())[:MAX_WHAT]
    entry = loops.get(slug)
    if isinstance(entry, dict):
        # Same loop, said again — unless it has had its four mentions or its
        # seven days, in which case this re-open IS the close. The prompt
        # asks the agent to stop there; this is the code keeping the promise
        # whatever the reply says, so no loop can be raised for ever.
        why = _expired(entry, now)
        if why:
            logger.info("open loop: %s has had enough (%s) — closing instead", slug, why)
            del loops[slug]
            _tombstone(slug, now)
            return True
        if quiet:
            entry["what"] = what or entry.get("what") or slug
            entry["raise"] = parse_raise(when, now)
            _remember(entry, now, "not said yet, next %s" % entry["raise"])
            return True
        said = entry.get("said")
        said = (said if isinstance(said, int) and said >= 0 else 0) + 1
        entry["said"] = said
        entry["what"] = what or entry.get("what") or slug
        entry["raise"] = parse_raise(when, now)
        if not entry.get("first"):
            entry["first"] = _stamp(now)
        named = _trailer_kind(body)
        entry["kind"] = named if named else normalise_kind(entry.get("kind"))
        # Said again: whatever had changed has now been mentioned. A `changed`
        # that survived a mention would keep the loop due for ever.
        entry.pop("changed", None)
        _remember(entry, now, "raised again (mention %d), next %s" % (said, entry["raise"]))
        if _expired(entry, now):
            # The mention it just used up was its last. A ledger of what is
            # OPEN should not carry rows the monitor is only going to hide.
            logger.info("open loop: %s has now been said %d times — letting it go",
                        slug, said)
            del loops[slug]
            _tombstone(slug, now)
    else:
        # A loop that has already had its run does not get a second one by
        # being opened again. Without this the ceiling was per LIFE of a
        # slug, not per thing: the fourth mention deleted the entry, the
        # next reply re-created it with said=1 and a fresh `first`, and the
        # same mail nudged the person four times more, for ever, in batches
        # of four. Measured before this line existed.
        #
        # A rename still dodges it, and no bookkeeping can stop a model that
        # invents a new name for the same thing — the honest bound there is
        # the 50-loop cap and seven days. What this closes is the case that
        # actually happens: the agent sees the same unanswered mail, forms
        # the same slug from it, and starts again.
        if _in_tombstones(slug, loops, now):
            logger.info("open loop: %s was let go recently — not reopening", slug)
            return False
        loops[slug] = {"what": what or slug, "first": _stamp(now),
                       "raise": parse_raise(when, now), "said": 1,
                       "kind": _fields_kind(body), "source": SOURCE_PASS}
        _remember(loops[slug], now, "opened by the background pass: %s" % (what or slug))
    return True


def open_loop(slug, what, kind=DEFAULT_KIND, when="", check=None, now=None,
              source=SOURCE_TURN):
    """The second write path: the brain, in the person's own turn.

    Returns (ok, error). Same slug rules, same ceiling, same tombstones as
    the trailer path — one ledger, two doors — with two differences that
    are the point of the door. `said` starts at 0: nothing has been said to
    the person yet, and charging a mention for hearing them would spend a
    quarter of the loop's life on its birth. And a `check` may be attached,
    which the trailer path (a line of text out of a job that reads mail)
    deliberately cannot do.

    Re-opening a slug that is already open updates its words, its kind and
    its check, and moves the raise time; it does NOT count a mention. Never
    raises."""
    if not (isinstance(slug, str) and _SLUG.match(slug)):
        return False, "%r is not a short name: lower-case letters, digits and hyphens, up to 40" % str(slug)[:60]
    what = " ".join(_CONTROL.sub(" ", str(what or "")).split())[:MAX_WHAT]
    if not what:
        return False, "say what the follow-up is about"
    check, why = normalise_check(check)
    if why:
        return False, why
    try:
        now = now or datetime.now(timezone.utc)
        with ledger_lock():
            loops = read_open()
            entry = loops.get(slug)
            if isinstance(entry, dict):
                if _expired(entry, now):
                    return False, "%s has had its run — open it under a new name if something new happened" % slug
                entry["what"] = what
                entry["kind"] = normalise_kind(kind)
                entry["raise"] = parse_raise(when, now)
                if check is not None:
                    entry["check"] = check
                    entry.pop("seen", None)
                entry.pop("changed", None)
                _remember(entry, now, "updated in conversation: %s" % what)
            else:
                if _in_tombstones(slug, loops, now):
                    return False, "%s was let go recently — not reopening it" % slug
                entry = {"what": what, "first": _stamp(now), "raise": parse_raise(when, now),
                         "said": 0, "kind": normalise_kind(kind), "source": source}
                if check is not None:
                    entry["check"] = check
                _remember(entry, now, "opened in conversation: %s" % what)
                loops[slug] = entry
            prune_open(loops, now)
            while len(loops) > MAX_OPEN:
                oldest = min(loops, key=lambda s: (str(loops[s].get("first") or ""), s))
                if oldest == slug:
                    break
                logger.warning("open loop: ledger full (%d) — dropping %s", MAX_OPEN, oldest)
                del loops[oldest]
            write_open(loops)
        logger.info("open loop: %s opened from the %s (%s)", slug, source, entry["kind"])
        return True, ""
    except Exception as e:  # noqa: BLE001
        logger.warning("open loop: could not open %s: %s: %s", slug, type(e).__name__, e)
        return False, "%s: %s" % (type(e).__name__, e)


def note_seen(slug, digest, excerpt, now=None, changed=False, was=""):
    """`moe-loop-check`'s one write: what the check saw, and whether it moved.

    `seen` is bookkeeping and the monitor's digest ignores it, so a check
    that ran and found the same thing changes no bytes and wakes nothing.
    `changed` is the opposite: it is printed, its arrival moves the bytes,
    and the loop's raise time is pulled to now so the pass sees it `due` on
    the next tick. Never raises; a check that cannot record itself is a
    check that runs again next tick."""
    if not (isinstance(slug, str) and _SLUG.match(slug)):
        return False
    try:
        now = now or datetime.now(timezone.utc)
        with ledger_lock():
            loops = read_open()
            entry = loops.get(slug)
            if not isinstance(entry, dict):
                return False
            first_look = not isinstance(entry.get("seen"), dict)
            entry["seen"] = {"at": _stamp(now), "hash": str(digest or "")[:16],
                             "excerpt": " ".join(_CONTROL.sub(" ", str(excerpt or "")).split())[:MAX_EXCERPT]}
            if changed:
                entry["changed"] = {"at": _stamp(now),
                                    "was": " ".join(_CONTROL.sub(" ", str(was or "")).split())[:MAX_EXCERPT],
                                    "now": entry["seen"]["excerpt"]}
                entry["raise"] = _stamp(now)
                _remember(entry, now, "check saw a change: %s -> %s"
                          % (entry["changed"]["was"], entry["changed"]["now"]))
            elif first_look and entry["seen"]["excerpt"]:
                _remember(entry, now, "check first saw: %s" % entry["seen"]["excerpt"])
            write_open(loops)
        return True
    except Exception as e:  # noqa: BLE001
        logger.warning("open loop: could not note what %s saw: %s", slug, e)
        return False


def strip_trailers(text):
    """(the reply without any trailer lines, [the insides of the ones found]).

    Nothing here writes anything: stripping happens on EVERY delivery, on
    every job, and applying happens only for `LEDGER_JOB`. A trailer-shaped
    line quoted out of somebody's mail is noise on the island whichever job
    read the mail.

    Three passes, in this order, because the model gets it wrong in three
    different ways: a whole line (the documented form, and the only one that
    can hold a `]]` inside its description); one anywhere else — after a
    sentence, split over two lines, three on one line; and one that opens
    and never closes, which takes everything after it with it."""
    if not isinstance(text, str):
        return "", []
    found = []
    kept = []
    for line in text.split("\n"):
        m = _TRAILER_LINE.match(line)
        if m:
            found.append((m.group(1).lower(), m.group(2)))
        else:
            kept.append(line)
    text = "\n".join(kept)

    def take(m):
        found.append((m.group(1).lower(), m.group(2)))
        return ""

    text = _TRAILER_ANY.sub(take, text)
    opener = _TRAILER_ISH.search(text)
    if opener:
        logger.warning("open loop: unterminated trailer at %d — dropping the rest",
                       opener.start())
        found.append(("", ""))
        text = text[:opener.start()]
    return text, found


def apply_trailers(text, now=None, job="", quiet=False):
    """Take the ledger trailers out of a reply, and — for `LEDGER_JOB` only —
    apply them.

    Returns (the reply without them, how many were APPLIED, the slugs the
    APPLIED `moe-open` lines named). The count is zero for every other job,
    so a message that was nothing but a quoted trailer stays the empty
    delivery it is instead of passing as a successful silent bookkeeping
    run.

    The slugs are what makes a reply answerable later. The sentence the
    person reads is "Eli's still waiting for IT admin rights"; the thing
    that has to change when they say "stop reminding me about that" is the
    loop `eli-it-admin`, and this reply is the only place the two are
    known to be the same thing. `deliver()` writes them down beside the
    text (`note_said`), and `followups.py` hands them back to the model
    when the answer arrives. Close lines are deliberately not returned: a
    message is never *about* a loop it just closed.

    Every failure below this line is swallowed: a ledger that cannot be
    written must not stop a reminder reaching the person."""
    text, found = strip_trailers(text)
    if not found:
        return text, 0, []
    if str(job or "").strip().lower() != LEDGER_JOB:
        logger.warning("open loop: %d trailer line(s) from job %r — stripped, "
                       "not applied (only %s writes the ledger)",
                       len(found), str(job or "")[:60], LEDGER_JOB)
        return text, 0, []
    applied = 0
    slugs = []
    try:
        now = now or datetime.now(timezone.utc)
        with ledger_lock():
            loops = read_open()
            changed = False
            for kind, body in found:
                if not kind:
                    continue
                try:
                    if _apply_open(kind, body, loops, now, quiet=quiet):
                        changed = True
                    applied += 1
                    slug = _fields(body)[0]
                    if kind == "open" and slug in loops and slug not in slugs:
                        slugs.append(slug)
                except Exception as e:  # noqa: BLE001
                    # One unreadable trailer loses itself, never the others:
                    # a batch that threw used to lose a good loop in the same
                    # reply, and the reply is the only place it was written.
                    logger.warning("open loop: trailer %r not applied: %s: %s",
                                   str(body)[:80], type(e).__name__, e)
            # After the trailers, not before: a re-open of a loop that has
            # run out of mentions or days has to meet the entry that is
            # still there, so it becomes the close it should be rather than
            # finding an empty ledger and starting the same loop again.
            if prune_open(loops, now):
                changed = True
            while len(loops) > MAX_OPEN:
                oldest = min(loops, key=lambda s: (str(loops[s].get("first") or ""), s))
                logger.warning("open loop: ledger full (%d) — dropping %s", MAX_OPEN, oldest)
                del loops[oldest]
                changed = True
            if changed:
                write_open(loops)
    except Exception as e:  # noqa: BLE001 — see the docstring
        logger.warning("open loop: ledger not updated: %s: %s", type(e).__name__, e)
    return text, applied, slugs


# ── What Moe said unprompted, and what it was about ──────────────────────
#
# `~/.moe/proactive/said.json`, 0600. Every proactive message that actually
# reaches a person is written here with the handles it can be acted on by.
#
# WHY IT HAS TO EXIST. A nudge goes out through `hermes send --to telegram`,
# which is a PUSH: it writes nothing to that platform's conversation. So the
# session that handles the reply has never seen the thing being replied to,
# and a one-word answer has no antecedent. Measured on 2026-09-04, twice:
#
#     Moe:  Moe's waiting to know if you called Fred by noon like you planned.
#     User: i did
#     Moe:  Did what, exactly? I don't have context for that — fill me in.
#
#     Moe:  Eli's still waiting for IT admin rights — he asked yesterday…
#     User: ok dont remond me anymore about that
#     Moe:  Sure — but which reminder do you mean? I don't have one in view.
#
# Both are the same bug and neither is a model failure: nothing had told the
# model. `followups.py` reads this file on the way in and puts the sentence
# back in front of the model, on every surface an alert can arrive on.
#
# WHAT A RECORD CARRIES, and why each field:
#   id      — so an answer marks THIS one answered and not the next one.
#   at      — a nudge older than ATTACH_HOURS is not what "I did" means.
#   text    — the sentence the person read. Nothing else identifies it.
#   job     — the cron's name. `job_id` with it is the handle for "stop
#             reminding me" on a reminder the person themselves asked for:
#             Hermes's own `cronjob` tool takes the id.
#   loops   — the open-loop slugs the SAME reply opened (`apply_trailers`).
#             The handle for "stop reminding me" on a proactive follow-up.
#   to      — which surfaces it went to, so an answer on Telegram is matched
#             against something that was actually sent to Telegram.
#
# It is a spool, not a log: SAID_KEEP records, SAID_TTL_HOURS, and answered
# ones drop out. What happened is already in `~/.moe/logs`.
SAID_FILENAME = "said.json"
#: Records kept at once. A day of proactive messages is a handful; this is
#: two weeks of them, and the file is read on every inbound message.
SAID_KEEP = 20
#: And how long one is kept at all, answered or not.
SAID_TTL_HOURS = 48
#: How long after Moe says something unprompted a reply is still read as an
#: answer to it. Long enough for "did you call Fred by noon" at 11:00 to be
#: answered after lunch; short enough that yesterday's nudge is not attached
#: to this morning's unrelated question. A record is attached AT MOST ONCE
#: whatever this says — the first message after it is the answer, and the
#: second is a new subject.
ATTACH_HOURS = 12
#: The delivered text, as kept for the attach. Longer than any nudge Moe
#: writes; a truncated sentence is still the sentence they read.
MAX_SAID_TEXT = 600
#: Where the app says "I dealt with that one on the island".
#:
#: A drop-directory of empty 0600 files named by record id, the same shape
#: and the same direction of travel as `~/.moe/inbox/` reversed: the app
#: cannot take this file's flock or share its schema, and a second Swift
#: reader of `said.json` would be two files with two beliefs about one
#: shape — which is the failure this repo keeps paying for. Creating an
#: empty file is atomic, needs no lock, and cannot half-happen.
ANSWERED_DIRNAME = "answered"
#: Moe's own background jobs. Every one `configure-hermes.py` installs is
#: named `moe-…` — moe-proactive, moe-calendar-heads-up, moe-drain-intents,
#: moe-learn-deep, moe-watch-<connection> — and a reminder a PERSON asks
#: for never is: it is named from what they said ("call Dan").
#:
#: The distinction decides what "stop telling me about that" is pointed at,
#: and getting it wrong is expensive in one direction only. A reminder the
#: person made is theirs, and `cronjob pause|remove` on it is exactly
#: right. Moe's own jobs are not: `remove` on `moe-proactive` deletes the
#: whole proactive pass — every follow-up, the memory it saves, the ledger
#: — because one nudge out of it was unwelcome, and `pause` on
#: `moe-calendar-heads-up` leaves Settings › Background still showing "5
#: minutes before" while nothing arrives. Those belong to switches in
#: Settings, so the note says so instead of naming a job id.
_MOE_JOB_PREFIX = "moe-"


def is_moe_job(job):
    """True when this is one of Moe's own background jobs rather than a
    reminder the person asked for. See `_MOE_JOB_PREFIX`."""
    return str(job or "").strip().lower().startswith(_MOE_JOB_PREFIX)


def answered_dir():
    return os.path.join(open_dir(), ANSWERED_DIRNAME)


def note_answered_on_screen(rec_id):
    """The island's "this one has had its answer", for the app to call.

    Kept deliberately dumb — a file, not a lock and not a schema — because
    the caller is `Conductor.playNudge` on the other side of a language
    boundary. Returns the path written, or "". Never raises."""
    rec_id = str(rec_id or "").strip()
    if not rec_id or not re.match(r"^[0-9a-f]{1,32}\Z", rec_id):
        return ""
    try:
        d = answered_dir()
        os.makedirs(d, exist_ok=True)
        os.chmod(d, 0o700)
        path = os.path.join(d, rec_id)
        with open(path, "w", encoding="utf-8"):
            pass
        os.chmod(path, 0o600)
        return path
    except OSError as e:
        logger.warning("follow-up: could not mark %s answered on screen: %s", rec_id, e)
        return ""


def _answered_on_screen(rec_id):
    try:
        return os.path.exists(os.path.join(answered_dir(), str(rec_id or "")))
    except OSError:
        return False


def _sweep_answered(rows):
    """Drop markers for records that are no longer in the spool.

    The directory would otherwise grow one file per nudge for ever. Run
    from `note_said`, which already holds the lock and is the only thing
    that happens often enough to matter."""
    live = {row.get("id") for row in rows}
    try:
        for name in os.listdir(answered_dir()):
            if name not in live:
                try:
                    os.unlink(os.path.join(answered_dir(), name))
                except OSError:
                    pass
    except OSError:
        pass


def said_path():
    return os.path.join(open_dir(), SAID_FILENAME)


def _read_said():
    """The spool, oldest first. A corrupt or missing file is an empty one:
    losing it costs one attached context, and refusing to deliver over it
    would cost the reminder."""
    try:
        with open(said_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    rows = data.get("said") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        return []
    out = []
    for row in rows:
        if isinstance(row, dict) and isinstance(row.get("id"), str):
            out.append(dict(row))
    return out


def _write_said(rows):
    """Replace the spool. Atomic and 0600 — it quotes the same mail the
    ledger does. Never raises: see `note_said`."""
    d = open_dir()
    try:
        os.makedirs(d, exist_ok=True)
        os.chmod(d, 0o700)
    except OSError:
        pass
    tmp = said_path() + ".tmp.%d" % os.getpid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"said": rows}, f)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, said_path())
    except OSError as e:
        logger.warning("follow-up: could not write said.json: %s", e)
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _prune_said(rows, now):
    keep = []
    for row in rows:
        at = _parse_stamp(row.get("at"))
        if at is None or now - at > timedelta(hours=SAID_TTL_HOURS):
            continue
        keep.append(row)
    return keep[-SAID_KEEP:]


def note_said(text, job="", job_id="", loops=(), to=(), now=None, rec_id="", note=""):
    """Write down that Moe said this unprompted. Returns the record id, or
    "" when nothing was written.

    Called from `deliver()` AFTER the delivery, with the surfaces that
    actually took it, and with the text as it was finally shown — cleaned,
    scrubbed and trailer-free. Both halves of that are load-bearing: a
    record spooled before the sending would offer "you sent them this and
    they have not answered it" about a sentence a failed `hermes send`
    meant they never saw, which is the "Moe brings something up out of
    nowhere" failure this file exists to prevent.

    `to` is therefore never assumed. A record with an empty one is offered
    to no surface at all.

    Never raises: a spool that cannot be written costs the context on one
    reply, and the reminder itself must still go."""
    try:
        now = now or datetime.now(timezone.utc)
        rec = {
            "id": str(rec_id or "") or uuid.uuid4().hex[:12],
            "at": _stamp(now),
            "text": str(text or "")[:MAX_SAID_TEXT],
            "job": str(job or "")[:80],
            "job_id": str(job_id or "")[:80],
            "loops": [s for s in loops if isinstance(s, str) and _SLUG.match(s)][:8],
            "to": sorted({str(t).strip().lower() for t in to if str(t).strip()}),
            "answered": "",
        }
        # An offer's note for the brain — the draft, fenced, and what to do
        # with it — so a "send it" typed on a phone has the draft to send
        # (review of the offer path #6: only the one line was kept).
        if note:
            rec["note"] = str(note)[:MAX_CHARS]
        if not rec["text"]:
            return ""
        with ledger_lock():
            rows = _prune_said(_read_said(), now)
            rows.append(rec)
            rows = rows[-SAID_KEEP:]
            _write_said(rows)
            _sweep_answered(rows)
        return rec["id"]
    except Exception as e:  # noqa: BLE001 — see the docstring
        logger.warning("follow-up: not spooled: %s: %s", type(e).__name__, e)
        return ""


def unanswered(surface="", now=None):
    """The newest thing Moe said unprompted on `surface` that nobody has
    answered yet, or None.

    `surface` is a platform name (`telegram`) or `screen` for this Mac's
    island; "" means any. A record is only offered to a surface it was
    actually delivered to — an answer typed on Telegram must not be matched
    against something that only ever appeared on the Mac, and a record that
    reached NOBODY (`to` empty, every send having failed) is offered
    nowhere. "Unknown, so allow" is how a message the person never saw gets
    quoted back at them.

    Older than ATTACH_HOURS is not an answer to anything: it is a new
    subject that happens to be short."""
    now = now or datetime.now(timezone.utc)
    want = str(surface or "").strip().lower()
    for row in reversed(_read_said()):
        if row.get("answered") or _answered_on_screen(row.get("id")):
            continue
        at = _parse_stamp(row.get("at"))
        if at is None or now - at > timedelta(hours=ATTACH_HOURS):
            continue
        to = row.get("to")
        if not isinstance(to, list) or not to:
            # Reached nobody. Not "unknown, so allow": that is how a
            # message a failed send meant they never saw gets quoted back
            # at them as something they did not answer.
            continue
        if want and want not in to:
            continue
        return dict(row)
    return None


def mark_answered(rec_id, surface="", now=None):
    """This one has had its answer: never attach it again.

    ONCE, and on the first message after it, whichever surface that is.
    Attaching the same sentence to every message for twelve hours is how a
    helpful note becomes Moe bringing up Eli's laptop in the middle of
    something else. Never raises."""
    if not rec_id:
        return False
    try:
        now = now or datetime.now(timezone.utc)
        with ledger_lock():
            rows = _read_said()
            hit = False
            if _answered_on_screen(rec_id):
                return False
            for row in rows:
                if row.get("id") == rec_id and not row.get("answered"):
                    row["answered"] = str(surface or "?").strip().lower() or "?"
                    row["answered_at"] = _stamp(now)
                    hit = True
            if hit:
                _write_said(_prune_said(rows, now))
            return hit
    except Exception as e:  # noqa: BLE001
        logger.warning("follow-up: could not mark %s answered: %s", rec_id, e)
        return False


# ── Changing a follow-up because the person asked ────────────────────────
#
# The ledger's ONLY write path used to be trailer lines in `moe-proactive`'s
# own reply, and the reasoning for that is above and still holds: that job
# reads the user's mail, so it must not hold a tool an injected instruction
# could reach for.
#
# These four are the other direction and a different trust story. They are
# reached from the `moe_followups` tool, which the model calls when the
# PERSON says something — "I did", "not now", "stop reminding me about
# that". The worst an injected instruction can achieve here is closing or
# muting a follow-up: it can silence Moe, never make it say something, and
# never reach outside `~/.moe/proactive/`. That is the same shape as the
# person clicking × on the island, which has always been available.
#
# All four are no-ops on a slug that is not open, and none of them raises.

def close_loop(slug, now=None):
    """Dealt with. Out of the ledger, no tombstone — something genuinely
    finished that comes back later is new, and worth raising again."""
    return _drop_loop(slug, now=now, mute=False)


def mute_loop(slug, now=None):
    """"Stop reminding me about that." Out of the ledger AND tombstoned
    with no expiry, so `moe-proactive` cannot open the same slug again on
    its next pass over the same unanswered mail."""
    return _drop_loop(slug, now=now, mute=True)


# ── "Done" on something that is still there (owner, 2026-09-30) ──────────
#
# Miriam's overdue Reminder was raised seven times in two days, and Done on
# the island stopped none of them: every pass saw the Reminder still overdue
# in the brief and raised it again — reworded, under a new slug or none, so
# neither closing the loop nor the per-loop cap could hold it.
#
# The rule is about REPEATS, never about topics: Moe may always say
# something NEW about a thing — "the Hanoi booking was cancelled" after "Dan
# is waiting on the Hanoi booking" — and silence there is worse than a
# repeat. A sentence is a repeat when it names the same thing and adds no
# word of its own to what was already said about it (`adds_nothing`).
#
# - Done HOLDS the subject (owner: "quiet until it changes"): anchored, where
#   there is one, to the Reminder or calendar line it came from — never a
#   message line, which scrolls off within hours — and lifted when that line
#   changes or goes; with no such line, after HOLD_UNANCHORED_DAYS. While it
#   stands, a repeat about it is not said. News about it still is.
# - A repeat with no loop is not said either, for a week: a mention with no
#   loop is one the per-loop cap cannot count.
# The pass's trailers apply either way: holding a sentence back must never
# lose the close or the reschedule of some other loop in the same reply.

HOLDS_FILENAME = "holds.json"
HOLD_UNANCHORED_DAYS = 7
HOLDS_KEEP = 60
#: Phrasing, not facts: the words a nag says differently every time.
_PLAIN_WORDS = frozenset("""
about after again also back been before being does done from have here into just like make more
need needs overdue still that them then there these they this today tomorrow tonight want what
when where which while will with would your yours days week weeks hours reminder reminders help
since follow reach pending open issue right sure could should thing things said says their
find fixed wrong handle sort check look send draft pull work recent remind ask asked update
confirm reply message email mail anything something someone need sorted handled deal dealing
please maybe know soon later time now still yet already there's it's that's you're let's
past outstanding ping task tasks item items waiting behind late quick note heads mind
three four five seven eight nine eleven twelve twenty thirty fortnight month months
monday tuesday wednesday thursday friday saturday sunday morning afternoon evening
""".split())
#: Facts a sentence carries that are not words: a time, an amount, a date.
#: "departs at 6:00 PM" -> "9:15 PM" is news; they are compared as tokens.
_FACT = re.compile(r"\d{1,2}:\d{2}|\d{1,2}\s?[ap]\.?m\b|[$€£₪]\s?[\d,.]+\d|\d{1,2}/\d{1,2}(?:/\d{2,4})?", re.I)
_WORDY = re.compile(r"[^\W\d_]{4,}", re.U)
#: Sections of the brief whose lines are things that stay put until they
#: change: Reminders and the calendar. Message lines are not anchors.
_ANCHOR_SECTIONS = re.compile(r"^#{1,2}\s+(tasks|calendar)\b", re.I)


def holds_path():
    return os.path.join(open_dir(), HOLDS_FILENAME)


def subject_words(text):
    """What a sentence is about, as a set of words: names and nouns, not the
    phrasing that changes every time."""
    norm = unicodedata.normalize("NFKC", str(text or "")).lower().replace("\u2019s", "").replace("'s", "")
    norm = _ANCHOR_URL.sub(" ", norm)
    return {w for w in _WORDY.findall(norm) if w not in _PLAIN_WORDS}


def same_subject(a, b):
    """The same thing named: at least three words shared, and most of the
    smaller set."""
    a, b = set(a or ()), set(b or ())
    shared = a & b
    return len(shared) >= 3 and len(shared) >= 0.5 * min(len(a), len(b))


def facts(text):
    """The times, amounts and dates in a sentence, as comparable tokens."""
    return {"#" + re.sub(r"[\s.,]", "", m.lower()) for m in _FACT.findall(str(text or ""))}


def _brief_words(skip=""):
    """Every subject word and fact in the brief, but for the line `skip`
    (a hold's own anchor); None when there is no brief."""
    try:
        with open(os.path.join(moe_home(), "context", "_brief.md"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    out = set()
    for line in lines:
        if skip and anchor_key(line) == skip:
            continue
        out |= subject_words(line) | facts(line)
    return out


#: -2: the key keeps a calendar line's day (a meeting moved to another day
#: is a changed line); a new name so the first look back-dates, not "now".
BRIEF_SEEN_FILENAME = "brief-seen-2.json"


def _line_key(line):
    """A brief line as brief-seen compares it: no links, no countdown — but
    its day kept."""
    return " ".join(_ANCHOR_CLOCK.sub("", _ANCHOR_URL.sub("", str(line or ""))).split())
_LINE_STAMP = re.compile(r"(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})")


def _line_stamp(m):
    """A line's own local timestamp as a UTC stamp, in the person's zone
    where it is known; else read as UTC (early rather than late)."""
    try:
        when = datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)),
                        tzinfo=local_zone(any_age=True) or timezone.utc)
        return _stamp(when)
    except ValueError:
        return "1970-01-01T00:00:00Z"
SEEDED_FILENAME = ".seeded-repeats"


def _brief_since(when, skip="", now=None):
    """Every subject word and fact on the brief lines first seen after
    `when` (the line compared without its links or countdown), but for the
    line `skip`; None when there is no brief. Each line's first sighting is
    kept in `brief-seen.json`, this side's own (the machine's brief is its
    own), for a week past its last sighting.

    Why: news has to be NEW. Until 2026-09-30 any word the brief carried
    counted, and the brief always carries the meeting's own calendar line —
    so "Andrew Wilson Follow Up Discussion" was news about Andrew Wilson's
    follow-up discussion every half hour."""
    try:
        with open(os.path.join(moe_home(), "context", "_brief.md"), encoding="utf-8") as f:
            lines = [l.strip() for l in f.read().splitlines()]
    except OSError:
        return None
    now = now or datetime.now(timezone.utc)
    path = os.path.join(open_dir(), BRIEF_SEEN_FILENAME)
    first_run = not os.path.exists(path)
    try:
        with open(path, encoding="utf-8") as f:
            seen = json.load(f)
        seen = seen if isinstance(seen, dict) else {}
    except (OSError, ValueError):
        seen = {}
    keys = {}
    for line in lines:
        if not line or line.startswith("#") or line.startswith("_"):
            continue
        k = hashlib.sha1(_line_key(line).encode("utf-8")).hexdigest()[:16]
        keys[k] = line
    stamp = _stamp(now)
    changed = first_run         # written even for an empty brief: the first look happens once
    for k in keys:
        row = seen.get(k)
        if not isinstance(row, list) or len(row) != 2:
            # The very first look at a brief cannot know when its lines
            # appeared: a line's own timestamp where it carries one ("2026-
            # 09-30 10:27 | …"), else "long ago" — never "now", which made the
            # whole brief news and let the first repeat after an install out
            # (review of repeats-real #2).
            first = stamp
            if first_run:
                m = _LINE_STAMP.search(keys[k])
                first = _line_stamp(m) if m else "1970-01-01T00:00:00Z"
            seen[k] = [first, stamp]
            changed = True
        elif row[1] != stamp:
            row[1] = stamp
            changed = True
    week = _stamp(now - timedelta(days=8))
    for k in [k for k, row in seen.items() if not (isinstance(row, list) and len(row) == 2 and row[1] >= week)]:
        del seen[k]
        changed = True
    if changed:
        try:
            os.makedirs(open_dir(), exist_ok=True)
            tmp = path + ".tmp.%d" % os.getpid()
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(seen, f, sort_keys=True)
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except OSError:
            pass
    since = _stamp(when) if isinstance(when, datetime) else str(when or "")
    out = set()
    fresh = []
    for k, line in keys.items():
        if skip and anchor_key(line) == skip:
            continue
        if seen.get(k, [stamp])[0] > since:
            out |= subject_words(line) | facts(line)
            fresh.append(line)
    _brief_since.fresh = fresh
    return out


def seed_repeats(now=None):
    """Once per home: what was already said and already dismissed, before
    this history existed, is history too. On 2026-09-30 the fix went in with
    an empty week and no holds, so the first repeat after it went out, and
    Dones pressed that morning counted for nothing. Seeds `mentions.json`
    from said.json's background-pass rows of the last week. Never raises."""
    marker = os.path.join(open_dir(), SEEDED_FILENAME)
    if os.path.exists(marker):
        return
    try:
        now = now or datetime.now(timezone.utc)
        week = _stamp(now - timedelta(days=MAX_AGE_DAYS))
        rows = [r for r in _read_said() if r.get("job") == LEDGER_JOB and str(r.get("at") or "") >= week]
        with ledger_lock():
            have = _read_mentions()
            known = {(m.get("at"), tuple(m.get("words") or ())) for m in have}
            for r in rows:
                if len(subject_words(r.get("text"))) < 3:
                    continue
                words = sorted(subject_words(r.get("text")) | facts(r.get("text")))
                if (r.get("at"), tuple(words)) not in known:
                    have.append({"at": r.get("at"), "words": words})
            have.sort(key=lambda m: str(m.get("at") or ""))
            os.makedirs(open_dir(), exist_ok=True)
            tmp = mentions_path() + ".tmp.%d" % os.getpid()
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(json.dumps({"mentions": have[-MENTIONS_KEEP:]}, sort_keys=True))
            os.chmod(tmp, 0o600)
            os.replace(tmp, mentions_path())
        # Not holds: `answered/` is written by ▶, a card waved away and a typed
        # reply as well as by Done, so it cannot say "quiet until it changes"
        # (review of repeats-real). The history alone stops the repeats.
        with open(marker, "w") as f:
            f.write(_stamp(now) + "\n")
    except Exception as e:  # noqa: BLE001
        logger.warning("repeats: not seeded: %s: %s", type(e).__name__, e)


def adds_nothing(words, known, source=None):
    """True when the sentence says nothing that was not said already: a
    repeat. A new word ("cancelled", "bounced", "contract") or a changed
    time or amount is news — provided it came from somewhere: with the brief
    in hand (`source`), a new word the brief does not carry is the model
    rewording, not news (review of nag-hold: "outstanding", "ping her")."""
    new = set(words) - set(known)
    if source is not None:
        new &= source
    return not new


_ANCHOR_URL = re.compile(r"https?://\S+")
#: What a brief line says about the clock, not about the thing — "— in 7 h",
#: "— in 1 h 30 min", "— now", "— today, in 6 h". A calendar line carries one and it moves every
#: pass; a hold anchored to the raw line would lift on the next one.
_ANCHOR_CLOCK = re.compile(r"\s*[—–]\s*(?:in\s+[^|]*|now|started[^|]*|ended[^|]*|just ended[^|]*|starting[^|]*"
                           r"|tomorrow|today(?:,[^|]*)?|tonight|on\s+\w+|until\s+[^|]*)\s*$"
                           r"|\s*\((?:in\s+\d+[^)]*|now)\)\s*$", re.I)
#: The day an event's calendar line names ("- Thu 1 Oct, 3:00–4:00 PM …").
#: CalendarTimeline writes it on every line since 2026-09-30, today's
#: included; a brief written before then drops it on the event's own day,
#: so it is stripped either way and one event keeps one key.
_ANCHOR_DAY = re.compile(r"^(-\s*)?(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s+\d{1,2}\s+[a-z]{3,9},?\s+", re.I)


def anchor_key(line):
    """A brief line as a hold compares it: no links, no countdown."""
    t = _ANCHOR_URL.sub("", str(line or ""))
    t = _ANCHOR_CLOCK.sub("", t)
    t = _ANCHOR_DAY.sub(lambda m: m.group(1) or "", t.strip())
    return " ".join(t.split())


def _brief_anchors():
    """(line, kind) for every Reminder ("task") and calendar ("calendar")
    line in the brief, plus the set of those sections present; None when
    there is no brief to read. Only a `#` or `##` heading changes section —
    a "### Coming up" under Calendar stays in it, a "### Tasks for Sunday"
    in someone's notes is not the Reminders (review of nag-hold #4)."""
    try:
        with open(os.path.join(moe_home(), "context", "_brief.md"), encoding="utf-8") as f:
            raw = f.read().splitlines()
    except OSError:
        return None
    out, present, kind = [], set(), ""
    for line in raw:
        line = line.strip()
        if re.match(r"^#{1,2}\s", line):
            m = _ANCHOR_SECTIONS.match(line)
            kind = ("task" if m.group(1).lower() == "tasks" else "calendar") if m else ""
            if kind:
                present.add(kind)
            continue
        if line.startswith("#") or not line or line.startswith("_") or not kind:
            continue
        out.append((line, kind))
    return out, present


def _read_holds():
    try:
        with open(holds_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    rows = data.get("holds") if isinstance(data, dict) else None
    return [r for r in rows if isinstance(r, dict) and isinstance(r.get("words"), list)] \
        if isinstance(rows, list) else []


def _write_holds(rows):
    try:
        os.makedirs(open_dir(), exist_ok=True)
        tmp = holds_path() + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"holds": rows[-HOLDS_KEEP:]}, f, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, holds_path())
        return True
    except OSError:
        logger.warning("holds: could not write %s", holds_path())
        return False


def _hold_live(row, anchors, now):
    """A hold stands while its line is in the brief as it was; one with no
    line, for HOLD_UNANCHORED_DAYS. A brief that is missing, or has no such
    section this time (an empty Tasks is left out), lifts nothing: only the
    line gone from a section that is there is a change."""
    anchor = row.get("anchor") or ""
    if anchor:
        if anchors is None:
            return True
        lines, present = anchors
        if (row.get("kind") or "task") not in present:
            return True
        return any(anchor_key(l) == anchor for l, _k in lines)
    try:
        at = datetime.fromisoformat(str(row.get("at")).replace("Z", "+00:00"))
    except ValueError:
        return False
    return now - at <= timedelta(days=HOLD_UNANCHORED_DAYS)


def hold_subject(slugs, text="", now=None):
    """Done on the island: close each loop, and hold its subject until what
    it came from changes. Returns {"closed": [slugs that were open],
    "held": bool, "anchor": line or "", "reminder": title or ""} —
    `reminder` when the line is an Apple Reminder, so the card can offer to
    tick it off there too."""
    now = now or datetime.now(timezone.utc)
    _brief_since(now, now=now)          # what the brief shows as the person presses Done
    words = set(subject_words(text))
    with ledger_lock():
        loops = read_open()
        for slug in slugs:
            words |= subject_words((loops.get(slug) or {}).get("what", ""))
    closed = [slug for slug in slugs if close_loop(slug, now=now)]
    out = {"closed": closed, "held": False, "anchor": "", "reminder": ""}
    if len(words) < 3:
        # Fewer than three could never match (`same_subject` needs three).
        return out
    anchors = (_brief_anchors() or ([], set()))[0]
    best, kind, best_n = "", "", 0
    for line, k in anchors:
        lw = subject_words(line)
        n = len(words & lw)
        if n >= 2 and n >= 0.5 * min(len(words), len(lw)) and n > best_n:
            best, kind, best_n = line, k, n
    task = kind == "task"
    row = {"slugs": list(slugs), "words": sorted(words | subject_words(best)),
           "anchor": anchor_key(best) if best else "", "kind": kind, "at": _stamp(now)}
    with ledger_lock():
        live = _brief_anchors()
        rows = [r for r in _read_holds() if _hold_live(r, live, now)]
        rows.append(row)
        out["held"] = _write_holds(rows)
    out["anchor"] = row["anchor"]
    parts = [x.strip() for x in anchor_key(best).split(" | ")] if task else []
    out["reminder"] = parts[1] if len(parts) >= 2 else ""
    return out


MENTIONS_FILENAME = "mentions.json"
MENTIONS_KEEP = 200


def mentions_path():
    return os.path.join(open_dir(), MENTIONS_FILENAME)


def _read_mentions():
    try:
        with open(mentions_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    rows = data.get("mentions") if isinstance(data, dict) else None
    return [r for r in rows if isinstance(r, dict) and isinstance(r.get("words"), list)] \
        if isinstance(rows, list) else []


def note_mention(text, now=None):
    """What the background pass said, as its subject words, for a week — the
    history a repeat is recognised against. said.json cannot be that: it is
    a spool of twenty records over two days. Under the ledger lock, which the
    cloud merge of this file takes too. Never raises."""
    if len(subject_words(text)) < 3:
        return
    words = sorted(subject_words(text) | facts(text))
    now = now or datetime.now(timezone.utc)
    week = _stamp(now - timedelta(days=MAX_AGE_DAYS))
    try:
        with ledger_lock():
            rows = [r for r in _read_mentions() if str(r.get("at") or "") >= week]
            rows.append({"at": _stamp(now), "words": words})
            os.makedirs(open_dir(), exist_ok=True)
            tmp = mentions_path() + ".tmp.%d" % os.getpid()
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(json.dumps({"mentions": rows[-MENTIONS_KEEP:]}, sort_keys=True))
            os.chmod(tmp, 0o600)
            os.replace(tmp, mentions_path())
    except Exception as e:  # noqa: BLE001 — a lost mention costs a repeat, never the reminder
        logger.warning("mentions: not written: %s: %s", type(e).__name__, e)


# ── What the person already has in its own app (owner, 2026-09-30) ──────
#
# "They're seeing email, they're seeing WhatsApp. Why do they need to hear it
# twice from Moe?" Of 20 notices that day, 11 re-told a message, a Reminder or
# a meeting the person already had in front of them. The owner's rules:
# - a message is raised only when a PERSON has waited three hours or more and
#   the person has neither read nor answered it — never as it arrives;
# - a Reminder is their Reminders app's, never re-announced;
# - a meeting is the heads-up's, plus at most one offer to prepare, per
#   meeting, per day.
# These hold whatever the background pass decides.

INBOUND_WAIT_S = 3 * 3600
PREP_FILENAME = "prep-offered.json"
_BRIEF_MSG = re.compile(r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2})?)\s*\|")
#: WhatsApp's sender field: "from me → Ada", "from Ada → me", "from Bob → Family (group)".
_WA_FROM = re.compile(r"^from (.+?) → ")
#: A business, not a person: iMessage's "urn:biz:" senders, SMS short codes,
#: and mail from addresses nobody answers.
_BUSINESS = re.compile(r"urn:biz:|^\+?\d{3,6}$|no-?reply|noreply|do-?not-?reply|notifications?@|"
                       r"billing@|receipts?@|failed-payments@|mailer-daemon|newsletter", re.I)
#: A chat that is itself a business (a WhatsApp channel), by its id only — a
#: family group called "newsletter" is people.
_BUSINESS_CHAT = re.compile(r"urn:biz:|@newsletter\b", re.I)


_MAIL_WHEN = re.compile(r"(\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2})")
_MONTHS = {m: i + 1 for i, m in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split())}


def _inbound(now=None):
    """The brief's inbound messages as (when, chat, sender, text, mine,
    read), oldest first; [] when there is none. Four shapes, one per reader:
      messages   "2026-09-30 10:27:01 | +1555… -> me | text"
      WhatsApp   "2026-09-30 10:27:01|chat|from <sender> → <whom>|text" (or a bare
                 "me"/number in place of "from …", before 2026-10-07)
      Telegram   "2026-09-30 10:27 | who: text" under "## chat: <name>"
      mail       "- Wed, 30 Sep 2026 10:43:12 | UNREAD | sender | subject"
    `read` is True only where the reader knows it (mail's flag)."""
    try:
        with open(os.path.join(moe_home(), "context", "_brief.md"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    # The Mac writes these times in its own zone: the person's, from tz.json
    # at any age, else this machine's own.
    zone = local_zone(now, any_age=True) or datetime.now().astimezone().tzinfo or timezone.utc
    out, inbound, tg_chat = [], False, ""
    for raw in lines:
        line = raw.strip()
        if line.startswith("## "):
            head = line[3:].strip()
            if head.lower().startswith("chat:") and inbound:
                tg_chat = head[5:].strip()            # Telegram's chats sit inside Inbound
                continue
            inbound, tg_chat = head.lower().startswith("inbound"), ""
            continue
        if not inbound or not line:
            continue
        if line.startswith("- ") and " | " in line:
            parts = [x.strip() for x in line[2:].split(" | ")]
            m = _MAIL_WHEN.search(parts[0]) if len(parts) >= 4 else None
            if m and parts[1] in ("UNREAD", "read"):
                try:
                    when = datetime(int(m.group(3)), _MONTHS.get(m.group(2).lower(), 1), int(m.group(1)),
                                    int(m.group(4)), int(m.group(5)), tzinfo=zone)
                except ValueError:
                    continue
                out.append((when, parts[2], parts[2], " | ".join(parts[3:]), False, parts[1] == "read"))
            continue
        m = _BRIEF_MSG.match(line)
        if not m:
            continue
        try:
            when = datetime.fromisoformat(m.group(1).replace(" ", "T")).replace(tzinfo=zone)
        except ValueError:
            continue
        rest = line[m.end():]
        parts = [x.strip() for x in rest.split("|")]
        if tg_chat and len(parts) == 1 and ":" in parts[0]:
            who, _, body = parts[0].partition(":")
            who = who.strip()
            out.append((when, tg_chat, who, body.strip(), who.lower() == "me", False))
        elif len(parts) >= 2 and "->" in parts[0]:
            left, _, right = parts[0].partition("->")
            left, right = left.strip(), right.strip()
            mine = left == "me"
            out.append((when, right if mine else left, "me" if mine else left, "|".join(parts[1:]), mine, False))
        elif len(parts) >= 3:
            chat, sender = parts[0], parts[1]
            # whatsapp.sh since 2026-10-07 (ticket #21): "from <who> → <whom>"
            # in place of a bare "me" or number, so the model can tell who
            # sent it. A brief written before then still says "me".
            m_from = _WA_FROM.match(sender)
            if m_from:
                sender = m_from.group(1).strip()
            out.append((when, chat, sender, "|".join(parts[2:]), sender == "me", False))
    out.sort(key=lambda r: r[0])
    return out


def restates_inbound(words, now=None):
    """(why not, when): why a sentence about an inbound message must not be
    said ("" when it may), and when that message arrived (None when the
    sentence is not about one). The message it restates is the one whose
    own words it shares most — a contact's name alone is not a match
    (review: "your call with Shloime moved to 5pm" was tied to an old
    "Kaporos lunch was great" and held)."""
    now = now or datetime.now(timezone.utc)
    rows = _inbound(now)
    words = set(words)
    match, best = None, (0, 0)
    for row in rows:
        when, chat, sender, body, mine, read = row
        if mine:
            continue
        bw = subject_words(body)
        in_body = words & bw
        shared = words & (bw | subject_words(chat) | subject_words(sender))
        if not in_body or len(shared) < 2 or len(shared) < 0.4 * min(len(words), len(bw) or 1):
            continue
        score = (len(in_body), len(shared))
        if score >= best:
            match, best = row, score
    if match is None:
        return "", None
    when, chat, sender, body, _mine, read = match
    if _BUSINESS.search(sender) or _BUSINESS_CHAT.search(chat):
        return "a message from a business, not a person waiting", when
    if read:
        return "they have read it", when
    if any(r[4] and r[1] == chat and r[0] >= when for r in rows):
        return "you have written in that chat since", when
    if (now - when).total_seconds() < INBOUND_WAIT_S:
        return "it arrived less than three hours ago and is in front of them already", when
    return "", when


def _calendar_or_task(words, now=None):
    """("task" | "calendar", anchor key) when the sentence restates a
    Reminder or a meeting on the brief; (None, "") otherwise."""
    anchors = _brief_anchors()
    if not anchors:
        return None, ""
    best, kind, best_n = "", None, 0
    for line, k in anchors[0]:
        lw = subject_words(line)
        n = len(set(words) & lw)
        if n >= 2 and n >= 0.5 * min(len(words), len(lw) or 1) and n > best_n:
            best, kind, best_n = line, k, n
    # The prep key keeps the event's day (anchor_key drops it, for holds):
    # a meeting moved to another day is a different mention.
    return kind, " ".join(_ANCHOR_CLOCK.sub("", _ANCHOR_URL.sub("", best)).split()) if best else ""


def _prep_offered_today(key, now, news_at=None):
    """True when a meeting already had its one mention today — unless the
    message the sentence is about (`news_at`) arrived after that mention;
    records the mention when it goes. Local day, this side's own file."""
    path = os.path.join(open_dir(), PREP_FILENAME)
    day = now.astimezone(local_zone(now, any_age=True) or timezone.utc).strftime("%Y-%m-%d")
    try:
        with open(path, encoding="utf-8") as f:
            done = json.load(f)
        done = done if isinstance(done, dict) else {}
    except (OSError, ValueError):
        done = {}
    prior = done.get(key)
    if isinstance(prior, str) and prior[:10] == day:
        if news_at is None or _stamp(news_at) <= prior[11:]:
            return True
    done = {k: v for k, v in done.items() if isinstance(v, str) and v[:10] == day}
    done[key] = "%s %s" % (day, _stamp(now))
    try:
        os.makedirs(open_dir(), exist_ok=True)
        tmp = path + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(done, f, sort_keys=True)
        os.replace(tmp, path)
    except OSError:
        pass
    return False


def _meeting_mention(kind, key, until, now, message_at):
    """Last of the rules, so a mention is recorded only when the sentence
    goes: a meeting gets one a day — a later one only for a message about it
    that arrived after that mention (a person waiting three hours is news)."""
    if kind == "calendar" and not until and _prep_offered_today(key, now, message_at):
        return "that meeting has had its one mention today; the heads-up has the rest"
    return ""


def quiet_about(text, loops=(), now=None, until=""):
    """Why the background pass must not say `text`, or "". Only ever a
    REPEAT — the same thing, with nothing new said about it:
    - its subject is held (Done on the island, the thing unchanged);
    - it carries no loop, and was said this week already."""
    now = now or datetime.now(timezone.utc)
    # Every pass records what the brief shows now, said or not: a line's
    # first sighting must be when it appeared, not when it was first needed.
    _brief_since(now, now=now)
    words = subject_words(text)
    if len(words) < 3:
        return ""
    seed_repeats(now)
    why, message_at = restates_inbound(words, now)
    if why:
        return why
    kind, key = _calendar_or_task(words, now)
    if kind == "task" and message_at is None:
        return "a Reminder: their Reminders app has it"
    said = words | facts(text)
    anchors = _brief_anchors()
    for row in _read_holds():
        if _hold_live(row, anchors, now) and same_subject(words, row.get("words")) \
                and adds_nothing(said, row.get("words"), _brief_since(row.get("at"), skip=row.get("anchor") or "", now=now)):
            return "held since %s (%s)" % (row.get("at"), ", ".join(row.get("slugs") or []) or "no loop")
    if loops:
        return _meeting_mention(kind, key, until, now, message_at)
    week = _stamp(now - timedelta(days=MAX_AGE_DAYS))
    known, last = set(), ""
    for rec in _read_mentions():
        at = str(rec.get("at") or "")
        if until and at >= until:
            continue
        if at >= week and same_subject(words, rec.get("words")):
            known |= set(rec.get("words") or ())
            last = max(last, at)
    source = _brief_since(last, now=now)
    changed = any(same_subject(words, subject_words(l)) for l in getattr(_brief_since, "fresh", []))
    if known and not changed and adds_nothing(said, known, source):
        return "said this week already, and this carries no loop"
    return _meeting_mention(kind, key, until, now, message_at)


def _drop_loop(slug, now=None, mute=False):
    if not (isinstance(slug, str) and _SLUG.match(slug)):
        return False
    try:
        now = now or datetime.now(timezone.utc)
        with ledger_lock():
            loops = read_open()
            gone = loops.pop(slug, None) is not None
            if gone:
                write_open(loops)
            if mute:
                # Tombstoned even when nothing was open: the person asked
                # for silence about this, and the next pass over the same
                # mail is exactly what would break the promise.
                _tombstone(slug, now, until=_MUTED_UNTIL)
        logger.info("follow-up: %s %s", "muted" if mute else "closed", slug)
        return gone or mute
    except Exception as e:  # noqa: BLE001
        logger.warning("follow-up: could not drop %s: %s", slug, e)
        return False


def snooze_loop(slug, when, now=None):
    """"Not now — tomorrow." Moves the raise time and does NOT count a
    mention: the person deferring something is not Moe nagging them, and
    charging them a mention for it would use the loop up in four asks.

    `when` is anything `parse_raise` reads, and its floor and ceiling
    apply, so "remind me in a minute" is an hour and no loop becomes due
    for ever. Returns the new raise time, or ""."""
    if not (isinstance(slug, str) and _SLUG.match(slug)):
        return ""
    try:
        now = now or datetime.now(timezone.utc)
        with ledger_lock():
            loops = read_open()
            entry = loops.get(slug)
            if not isinstance(entry, dict):
                return ""
            entry["raise"] = parse_raise(when, now)
            entry.pop("changed", None)
            _remember(entry, now, "they said not now; snoozed until %s" % entry["raise"])
            write_open(loops)
            logger.info("follow-up: snoozed %s to %s", slug, entry["raise"])
            return entry["raise"]
    except Exception as e:  # noqa: BLE001
        logger.warning("follow-up: could not snooze %s: %s", slug, e)
        return ""


def note_history(slugs, event, now=None):
    """One line into the history of each named loop. Never raises."""
    try:
        now = now or datetime.now(timezone.utc)
        with ledger_lock():
            loops = read_open()
            hit = False
            for slug in slugs:
                entry = loops.get(slug)
                if isinstance(entry, dict):
                    _remember(entry, now, event)
                    hit = True
            if hit:
                write_open(loops)
        return hit
    except Exception as e:  # noqa: BLE001
        logger.warning("open loop: history not written: %s", e)
        return False


def unmute_loop(slug):
    """Lift a mute. The loop is not reopened — nothing here invents a
    follow-up — but `moe-proactive` may open it again when there is a
    reason to."""
    if not (isinstance(slug, str) and _SLUG.match(slug)):
        return False
    try:
        now = datetime.now(timezone.utc)
        with ledger_lock():
            kept = _read_closed(now)
            if (kept.get(slug) or {}).get("until") != _MUTED_UNTIL:
                return False
            # Dated, not deleted: a deletion looks like "never muted" to the
            # other side's copy, which would bring the mute back.
            kept[slug] = {"at": _stamp(now), "until": _LIFTED}
            _write_closed(kept)
        logger.info("follow-up: unmuted %s", slug)
        return True
    except Exception as e:  # noqa: BLE001
        logger.warning("follow-up: could not unmute %s: %s", slug, e)
        return False


def list_loops(now=None):
    """(open loops, muted slugs) — what the model needs to answer "what are
    you still chasing me about?" and to pick the right slug when the person
    names a thing rather than a slug."""
    now = now or datetime.now(timezone.utc)
    out = []
    for slug, entry in sorted(read_open().items()):
        if not isinstance(entry, dict):
            continue
        row = {
            "slug": slug,
            "what": str(entry.get("what") or slug)[:MAX_WHAT],
            "kind": normalise_kind(entry.get("kind")),
            "said": entry.get("said") if isinstance(entry.get("said"), int) else 0,
            "first": str(entry.get("first") or ""),
            "raise": str(entry.get("raise") or ""),
            "due": bool(_parse_stamp(entry.get("raise")) and
                        _parse_stamp(entry.get("raise")) <= now),
        }
        if isinstance(entry.get("check"), dict):
            row["check"] = dict(entry["check"])
        seen = entry.get("seen")
        if isinstance(seen, dict) and seen.get("excerpt"):
            row["seen"] = str(seen.get("excerpt"))[:MAX_EXCERPT]
        changed = entry.get("changed")
        if isinstance(changed, dict):
            row["changed"] = {"was": str(changed.get("was") or "")[:MAX_EXCERPT],
                              "now": str(changed.get("now") or "")[:MAX_EXCERPT]}
        history = entry.get("history")
        if isinstance(history, list) and history:
            row["history"] = [{"at": str(h.get("at") or ""), "event": str(h.get("event") or "")}
                              for h in history[-MAX_HISTORY:] if isinstance(h, dict)]
        out.append(row)
    muted = sorted(s for s, v in _read_closed(now).items()
                   if (v or {}).get("until") == _MUTED_UNTIL)
    return out, muted


#: How long the same failure from the same job stays out of the log after
#: it has been written once. Long enough that a five-minute job cannot fill
#: the file, short enough that something still broken tomorrow morning
#: leaves a fresh line to find.
REPEAT_QUIET_SECONDS = 3600
#: Where the last-logged failures are remembered. Not the ledger: this is
#: about Moe's own noise, and losing it costs one extra line.
FAILURES_FILENAME = "failures.json"


def is_repeat_failure(text, job="", now=None):
    """True when this exact failure has already been recorded within the hour.

    Nothing here reaches a person any more — `is_machinery` drops every
    cron notice before this is asked. This damps the *log*: a five-minute
    job whose plugin was half-installed wrote the same sentence twelve
    times an hour, and the twelfth told whoever reads it nothing the first
    had not. Keyed on the job and the whole text, so a job that starts
    failing differently is news again.

    Any error here means "not a repeat": a damper that swallows a real
    failure because it could not write a file is worse than a duplicate."""
    if not isinstance(text, str):
        return False
    if not is_machinery(text):
        return False
    key = "%s\n%s" % (job or job_name(text), " ".join(text.split()))
    try:
        import hashlib
        key = hashlib.sha1(key.encode("utf-8", "replace")).hexdigest()[:16]
        stamp = (now or datetime.now(timezone.utc)).timestamp()
        path = os.path.join(open_dir(), FAILURES_FILENAME)
        seen = {}
        try:
            with open(path, encoding="utf-8") as f:
                loaded = json.load(f)
            if isinstance(loaded, dict):
                seen = {k: v for k, v in loaded.items()
                        if isinstance(v, (int, float)) and stamp - v < REPEAT_QUIET_SECONDS * 24}
        except (OSError, ValueError):
            seen = {}
        last = seen.get(key)
        if isinstance(last, (int, float)) and 0 <= stamp - last < REPEAT_QUIET_SECONDS:
            logger.info("delivery: same failure from %r again — said %d s ago, not repeating",
                        job or m.group(1), int(stamp - last))
            return True
        seen[key] = stamp
        private = open_dir()
        os.makedirs(private, exist_ok=True)
        try:
            os.chmod(private, 0o700)
        except OSError:
            pass
        tmp = path + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(seen, f, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception as e:
        logger.warning("delivery: could not check for a repeated failure: %s", e)
        return False
    return False


#: Machinery, in the one place someone debugging it will look. Beside
#: moe.log and hermes-gateway.log, not inside them, so "is a job failing?"
#: is one file and not a grep.
MACHINERY_LOG = "job-failures.log"


def note_machinery(text, job="", now=None):
    """Write a dropped job failure down, once an hour per distinct one.

    Dropping these from the island is the point; dropping them entirely is
    not. A guard whose only evidence is that nothing happened cannot be
    told from a guard that stopped running — so every notice `is_machinery`
    swallows leaves a dated line in ~/.moe/logs/job-failures.log with the
    raw text Hermes sent, and Settings › Background still shows the job as
    "needs a look" from Hermes's own run ledger.

    Never raises: a log that cannot be written is not a reason to put an
    exit code in front of somebody."""
    try:
        # A gateway restart is Moe stopping and starting its own thinking
        # part — it does that several times an hour while somebody is
        # changing settings, it is already in hermes-gateway.log, and a file
        # about failing jobs that is nine-tenths restart chatter is a file
        # nobody reads. Everything else machinery-shaped is worth a line.
        who = job or job_name(text)
        if not who or is_repeat_failure(text, job, now=now):
            return
        when = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
        logs = os.path.join(moe_home(), "logs")
        os.makedirs(logs, exist_ok=True)
        line = "[%s] %s: %s\n" % (when, who, " ".join(text.split()))
        path = os.path.join(logs, MACHINERY_LOG)
        with open(path, "a", encoding="utf-8") as f:
            f.write(line)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    except Exception as e:  # noqa: BLE001 — see the docstring
        logger.warning("delivery: could not record a dropped notice: %s", e)


def has_screen():
    """Whether this runtime has an island to write to.

    `moe` does not mean "the island". It means "reach the person, wherever
    they are", and on this Mac that is the island plus whatever chats they
    ticked. The same Moe runs on a cloud machine with no screen, where an
    inbox file is a message nobody will ever read — and, worse, a delivery
    that counts as having succeeded.

    `MOE_SURFACE` (screen | none) says so outright; agreed with the away
    session, which sets it in the machine's env. When it is unset the
    answer is derived from `MOE_RUNS_IN`, so a machine cannot start
    writing to a dead inbox because someone forgot a key. Neither is set on
    a Mac, and a Mac is unchanged."""
    surface = (os.environ.get("MOE_SURFACE") or "").strip().lower()
    if surface:
        return surface != "none"
    return (os.environ.get("MOE_RUNS_IN") or "").strip().lower() != "cloud"


#: Where the app says whether the person is at this Mac. Written by
#: `Conductor.writePresence` every minute and on lock, unlock, sleep and
#: wake: `{"active": true, "at": <epoch seconds>, "idle": <seconds>}`.
PRESENCE_FILENAME = "presence.json"
#: A stamp older than this says nothing — the app is closed, or the Mac is
#: asleep and the last word was "active". Absent is the same as stale.
PRESENCE_FRESH_SECONDS = 3 * 60


def at_mac(now=None):
    """Is the person at this Mac right now — screen unlocked, awake, hands on
    it in the last few minutes?

    "Where you are" is the delivery rule (docs/LOOPS.md §2): a message for
    someone sitting at the island goes to the island and not to their phone
    as well, and one for someone who has walked away goes to the chat
    channels they ticked. Only the app can answer this, so it is a file the
    app writes, and a file it has not written lately is "not here" — which
    is the safe answer: a nudge forwarded to a phone in a pocket next to the
    Mac costs a glance; one kept on an island nobody is looking at costs the
    message."""
    if not has_screen():
        return False
    try:
        with open(os.path.join(moe_home(), PRESENCE_FILENAME), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict) or data.get("active") is not True:
        return False
    at = data.get("at")
    if not isinstance(at, (int, float)):
        return False
    now_s = (now or datetime.now(timezone.utc)).timestamp()
    return 0 <= now_s - float(at) <= PRESENCE_FRESH_SECONDS


_LAST_INBOX_MS = 0


def write_inbox(text, source="", job="", chat_id=SCREEN, said="",
                job_id="", loops=(), kind="", offer="", instruction="",
                session_id="", title="", summary="", subject="", options=()):
    """One message for the app. Returns the path written.

    `kind` says what the app should do with it. Unset (every reminder) is a
    nudge on the island. "turn" is a finished helper's result — the app runs
    a turn on it so Moe can say the outcome in its own words, rather than
    reading the raw result aloud (see completions.py).

    Atomic (tmp + rename) so the poller never reads half a file, and 0600
    like nudge.json: a reminder can quote a message from someone.

    `said`, `job_id` and `loops` are the same handles `note_said` spools,
    written into the file itself so the app needs nothing but the message
    it already reads. The island's half of the fix — `Conductor.playNudge`
    telling the brain what was just said and how to change it — is a plain
    read of this file, not a second reader of `said.json` with a second
    opinion about its shape."""
    d = inbox_dir()
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    now = time.time()
    # The app reads the inbox in name order, so two messages written in one
    # millisecond used to come out in the order of their random suffixes —
    # half the time backwards (test_drain_says caught it under load). The
    # millisecond is kept strictly increasing within this process.
    global _LAST_INBOX_MS
    ms = max(int(now * 1000), _LAST_INBOX_MS + 1)
    _LAST_INBOX_MS = ms
    name = "%d-%s.json" % (ms, uuid.uuid4().hex[:8])
    path = os.path.join(d, name)
    tmp = path + ".tmp"
    body = {"text": text, "at": now, "source": source or "cron",
            "job": job or "", "chat_id": chat_id or SCREEN, "said": said or "",
            "job_id": job_id or "",
            "loops": [s for s in loops if isinstance(s, str)]}
    if kind:
        body["kind"] = kind
    # The Hermes session a finished helper was started from — the id the app
    # sent as X-Hermes-Session-Id, derived from the conversation. The app
    # routes the result back to THAT conversation rather than whichever one
    # is on screen (2026-09-29: seven helpers finished in a conversation the
    # app had left, and were answered from one that had never started them).
    if session_id:
        body["session_id"] = session_id
    # An offer from the situations engine (docs/PROACTIVE-MEMORY.md §4.8):
    # the situation's id, which the island reads its prepared work from, and
    # the sentence the brain is given when the person plays or answers it.
    if offer:
        body["offer"] = offer
    if instruction:
        body["instruction"] = instruction
    # The inbox's words for it (docs/INBOX.md): a few-word title and a
    # sentence of summary, when something better than the text's own first
    # line was worked out (`inboxwords.py`). The app derives both otherwise.
    if title:
        body["title"] = title
    if summary:
        body["summary"] = summary
    # What it is about (docs/INBOX-QUIET.md decision 8): a situation, a
    # follow-up, a promise, a meeting, a routine. The app keeps one open card
    # per subject and updates it in place when another message about the
    # same thing arrives, instead of adding a card for every rewording.
    subject = subject_key(subject)
    if subject:
        body["subject"] = subject
    # The card's one-tap answers (docs/INBOX-QUIET.md decision 1): each is a
    # chip on the island, and tapping one answers the card with those words,
    # which the brain reads beside `instruction`. A short list of short
    # lines; anything else is not an answer a person can tap.
    opts = [o.strip()[:60] for o in (options or ()) if isinstance(o, str) and o.strip()][:4]
    if opts:
        body["options"] = opts
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(body, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return path


def subject_key(subject):
    """A subject as the inbox file carries it: one line, at most 120
    characters, or "" for anything that is not text."""
    if not isinstance(subject, str):
        return ""
    return " ".join(subject.split())[:120]


def subject_for(subject="", offer="", loops=()):
    """The subject a delivery is about: the writer's own, else the situation
    an offer came from (`situation:<id>`), else the first follow-up it names
    (`loop:<slug>`). The app derives the same when a file carries none."""
    given = subject_key(subject)
    if given:
        return given
    if offer:
        return "situation:%s" % offer
    for slug in loops or ():
        if isinstance(slug, str) and slug:
            return "loop:%s" % slug
    return ""


def hermes_cli():
    """The `hermes` this process belongs to, else the installed one."""
    candidates = [
        os.path.join(os.path.dirname(sys.executable), "hermes"),
        os.path.expanduser("~/.hermes/hermes-agent/.venv/bin/hermes"),
        os.path.expanduser("~/.local/bin/hermes"),
    ]
    for c in candidates:
        if os.access(c, os.X_OK):
            return c
    return "hermes"


# ── Quiet hours (docs/LOOPS.md §2, §5) ───────────────────────────────────
#
# Between QUIET_START and QUIET_END local, a message Moe raises ON ITS OWN
# does not go to the person's phone; it waits in `held.json` and goes out
# when the morning comes (`release_held`, run by moe-loop-check every five
# minutes). The island still gets it — the glow is silent and waits to be
# tapped. A reminder the person set themselves is not held: "wake me at six"
# is theirs, and `is_moe_job` is the line between the two.
#
# "Local" is the hard part, and the rule is: only on a fresh stamp. The zone
# comes from `~/.moe/tz.json`, which the app writes from the Mac's OS on
# launch, wake and every zone change, and which travels to the cloud copy
# as the `tz` document. Older than TZ_FRESH_SECONDS, or absent, and there
# are no quiet hours at all: a guess about where somebody is in the world
# is how a nudge arrives at 3 a.m. in Hanoi, and refusing beats assuming.
QUIET_KEY = "quietHours"
QUIET_START = 22
QUIET_END = 8
TZ_FILENAME = "tz.json"
TZ_FRESH_SECONDS = 24 * 3600
HELD_FILENAME = "held.json"
HELD_KEEP = 40
HELD_TTL_HOURS = 20


def quiet_window(cfg=None):
    """(start_hour, end_hour) or None when quiet hours are off."""
    cfg = cfg if cfg is not None else read_config()
    raw = cfg.get(QUIET_KEY)
    if raw is False:
        return None
    if not isinstance(raw, dict):
        return QUIET_START, QUIET_END
    if raw.get("enabled") is False:
        return None
    start, end = raw.get("start"), raw.get("end")
    if not (isinstance(start, int) and isinstance(end, int) and 0 <= start < 24 and 0 <= end < 24):
        return QUIET_START, QUIET_END
    return start, end


def local_zone(now=None, any_age=False):
    """The person's zone as a fixed-offset tzinfo, or None when unknown.

    From tz.json while it is fresh; nothing else. Not the OS: on a Mac the
    app writes the file from the OS anyway, and on the machine the OS is UTC
    and says nothing about the person. `any_age`: the last zone the Mac
    wrote, however long ago — for what must wait for the morning rather than
    go at an unknown hour (an offer from the machine while the Mac is shut)."""
    try:
        with open(os.path.join(moe_home(), TZ_FILENAME), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    at, offset = data.get("at"), data.get("utc_offset_seconds")
    if not isinstance(at, (int, float)) or isinstance(offset, bool) or not isinstance(offset, int):
        return None
    now_s = (now or datetime.now(timezone.utc)).timestamp()
    if not (0 <= now_s - float(at) <= (float("inf") if any_age else TZ_FRESH_SECONDS)) \
            or abs(offset) > 26 * 3600:
        return None
    return timezone(timedelta(seconds=offset))


def is_quiet(now=None, cfg=None, any_age=False):
    """True inside the quiet window, in the person's own zone, and only
    when that zone is known fresh (or known at all, with `any_age`)."""
    window = quiet_window(cfg)
    if window is None:
        return False
    zone = local_zone(now, any_age=any_age)
    if zone is None:
        return False
    hour = (now or datetime.now(timezone.utc)).astimezone(zone).hour
    start, end = window
    if start == end:
        return False
    if start < end:
        return start <= hour < end
    return hour >= start or hour < end


def held_path():
    return os.path.join(open_dir(), HELD_FILENAME)


def _read_held():
    try:
        with open(held_path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    rows = data.get("held") if isinstance(data, dict) else None
    return [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []


def _write_held(rows):
    d = open_dir()
    try:
        os.makedirs(d, exist_ok=True)
        os.chmod(d, 0o700)
    except OSError:
        pass
    tmp = held_path() + ".tmp.%d" % os.getpid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"held": rows[-HELD_KEEP:]}, f)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, held_path())
    except OSError as e:
        logger.warning("quiet hours: could not write held.json: %s", e)
        try:
            os.unlink(tmp)
        except OSError:
            pass


def hold_for_morning(text, channels, now=None, job=""):
    """Keep a sentence for the channels until quiet hours end. Never raises."""
    try:
        now = now or datetime.now(timezone.utc)
        with ledger_lock():
            rows = _read_held()
            rows.append({"at": _stamp(now), "text": str(text or "")[:MAX_CHARS],
                         "channels": [c for c in channels if isinstance(c, str)],
                         "job": str(job or "")[:80]})
            _write_held(rows)
        logger.info("quiet hours: held for the morning (%s)", ", ".join(channels))
        return True
    except Exception as e:  # noqa: BLE001
        logger.warning("quiet hours: could not hold: %s", e)
        return False


def release_held(now=None, cfg=None, run=None):
    """Outside quiet hours, send what was held, oldest first, once. A held
    line older than HELD_TTL_HOURS is dropped: last night's nudge is not
    this afternoon's news. Returns how many went. Never raises."""
    try:
        now = now or datetime.now(timezone.utc)
        if is_quiet(now, cfg):
            return 0
        # Asked BEFORE the lock: `quiet_about` may seed the history, which
        # takes the ledger lock itself.
        rows = _read_held()
        if not rows:
            return 0
        here = at_mac(now)
        stale = {(r.get("text"), tuple(r.get("channels") or ())) for r in rows
                 if r.get("job") == LEDGER_JOB
                 and quiet_about(r.get("text") or "", (), now=now, until=str(r.get("at") or ""))}
        released = []
        with ledger_lock():
            rows = _read_held()
            sent = 0
            keep = []
            seen = set()
            for row in rows:
                at = _parse_stamp(row.get("at"))
                if at is None or now - at > timedelta(hours=HELD_TTL_HOURS):
                    continue
                key = (row.get("text"), tuple(row.get("channels") or ()))
                if key in seen:
                    continue
                seen.add(key)
                # Checked again now, not as it was at night (2026-09-29: a
                # 05:41 nudge reached the phone at 08:04 while the person sat
                # at the Mac, about a loop let go since). At the Mac, the
                # island already has it; a subject since held or said, gone.
                if here or key in stale:
                    logger.info("quiet hours: not releasing (%s): %s",
                                "at the Mac" if here else "no longer news", (row.get("text") or "")[:80])
                    continue
                errors = fan_out(row.get("text") or "", row.get("channels") or [], run=run)
                if errors:
                    logger.warning("quiet hours: release failed for %s — kept", _errors_text(errors))
                    keep.append(row)
                else:
                    sent += 1
                    released.append(row)
            _write_held(keep)
            if sent:
                logger.info("quiet hours: released %d held message(s)", sent)
        # What went is written down like any delivery, so an answer to it
        # finds it (it was never recorded, so "done" in reply matched nothing).
        for row in released:
            note_said(row.get("text") or "", job=row.get("job") or "", to=list(row.get("channels") or []),
                      now=now)
        return sent
    except Exception as e:  # noqa: BLE001
        logger.warning("quiet hours: release failed: %s", e)
        return 0


# ── Reaching the owner (`reach_owner`, and every forward below) ──────────
#
# "Message me on Telegram" once reached a CONTACT. The brain had no tool that
# could only reach the person it works for, so it made a cron job told to
# WhatsApp him, and the send resolved to somebody else. Meanwhile this file's
# own forward shelled `hermes send --to telegram --quiet`, which cannot work
# on a Mac whose Telegram the cloud holds (the platform is switched off here
# and `hermes send` never uses the relay) — and `--quiet` swallowed why, so
# the only trace was "hermes send exited 1".
#
# One primitive now, and it names no address anywhere:
#
# 1. **Where they are.** At the Mac (`at_mac`: the app's presence stamp —
#    screen unlocked, awake, hands on it lately) the island is the whole
#    delivery. A channel overrides that only when THE PERSON'S OWN WORDS asked
#    for it ("message me on Telegram") — never the model's argument alone
#    (`person_asked_for`).
# 2. **Memoe's cloud** (`POST /v1/owner/notify`): words only; the edge sends
#    them to the owner's own chat — which the EDGE recorded, never this Mac —
#    on whichever chat app is live, and says which one took it.
# 3. **This Mac's own forwards**: the chat apps they ticked in Settings ›
#    Background, through `hermes send` — never `--quiet`.
# 4. **Nobody**: kept in the inbox (or held on the ledger where there is no
#    screen), and SAID — never a success that reached nobody.
#
# **One key per message.** A sentence gets one idempotency key, reused by a
# repeat within `REPEAT_WINDOW_S` and by every retry, so the edge sends it
# once however often it is asked. A cloud that did not answer in time may
# have sent it: that is reported as exactly that, and nothing else is tried —
# a phone buzzing twice is the failure this avoids. And it is rate-limited
# here as well as at the edge.

#: The edge route. The edge's owner-notify handler is the other half.
OWNER_NOTIFY_PATH = "/v1/owner/notify"
#: Longer than the edge's worst case for one request (`owner.WORST_CASE_S`,
#: 30 s: a 15 s send budget plus one 15 s provider call), so a slow edge is
#: waited for rather than retried around.
NOTIFY_TIMEOUT = 35
URGENCIES = ("normal", "urgent")
#: The chat apps Memoe's cloud can carry (`relayconfig.CHAT_CHANNELS`): what a
#: `moe:<app>` target may name, and what a job's bare target is rewritten
#: from. Email, SMS and Signal are not among them and are left alone.
CHAT_APPS = ("telegram", "slack", "discord", "whatsapp", "line")
#: How the person might name each in their own words.
_SAID = {
    "telegram": re.compile(r"\b(telegram|tg)\b", re.I),
    "slack": re.compile(r"\bslack\b", re.I),
    "discord": re.compile(r"\bdiscord\b", re.I),
    "whatsapp": re.compile(r"\b(whats\s?app|wa)\b", re.I),
    "line": re.compile(r"\bLINE\b|\bline app\b"),
}
REACH_FILENAME = "reach.json"
REPEAT_WINDOW_S = 600
#: What this Mac itself sends to the owner's phone, before the edge's own
#: limits: five in ten minutes, forty a day, urgent three an hour.
LOCAL_LIMITS = ((600, 5, "five in ten minutes"), (86400, 40, "forty in a day"))
LOCAL_URGENT_LIMIT = (3600, 3, "three urgent in an hour")


def _read_json_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def owner_edge():
    """``(edge base URL, device bearer)`` for this runtime, or ``("", "")``.

    Read off disk, because a tool runs in a process whose environment has the
    gateway's own secrets stripped (the claude-code child's MCP server gets no
    GATEWAY_RELAY_SECRET). The Mac's vault is ``$MOE_HOME/cloud`` and its edge
    is ``cloudEdge`` in Moe's config; the away machine's are
    ``$HERMES_HOME/moe`` and ``MOE_EDGE_URL`` / ``edge.json`` — the same places
    `ran.machine_credential` and `channels.py` read."""
    hermes = os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")
    # The machine's vault only on the machine: a Mac reads its own and nothing
    # else, so a stray file under ~/.hermes can never make a Mac speak as
    # some other device.
    vaults = ([os.path.join(moe_home(), "cloud")] if has_screen()
              else [os.path.join(hermes, "moe"), os.path.join(moe_home(), "cloud")])
    for vault in vaults:
        cred = _read_json_file(os.path.join(vault, "credential.json")) or {}
        bearer = cred.get("token")
        bearer = bearer.strip() if isinstance(bearer, str) else ""
        if not bearer:
            continue
        url = (os.environ.get("MOE_EDGE_URL") or "").strip()
        if not url:
            url = str((_read_json_file(os.path.join(vault, "edge.json")) or {}).get("url") or "")
        if not url:
            url = str(read_config().get("cloudEdge") or "")
        if not url:
            url = os.environ.get("GATEWAY_RELAY_URL") or ""
        url = url.strip()
        if url.startswith("wss://"):
            url = "https://" + url[len("wss://"):]
        elif url.startswith("ws://"):
            url = "http://" + url[len("ws://"):]
        url = url.rstrip("/")
        if url.endswith("/relay"):
            url = url[:-len("/relay")]
        if url.startswith("https://") or url.startswith("http://127.0.0.1") \
                or url.startswith("http://localhost"):
            return url, bearer
    return "", ""


def _timed_out(e):
    import socket
    if isinstance(e, (socket.timeout, TimeoutError)):
        return True
    reason = getattr(e, "reason", None)
    return isinstance(reason, (socket.timeout, TimeoutError)) or "timed out" in str(reason or e)


def notify_edge(text, urgency="normal", channel="", strict=False, key="", channels=None,
                edge=None, timeout=NOTIFY_TIMEOUT):
    """``POST /v1/owner/notify``. Always a dict, never raises.

    ``delivered`` is True when the edge put it in front of them; False with
    ``error`` in the edge's own words when it did not. Three flags change what
    a caller may do next:

    ``unconfigured``  no cloud to ask (not signed in): try this Mac's own way;
    ``maybe``         no answer in time — it MAY have been delivered: do not
                      send it any other way (``delivered`` is None);
    ``limited``       the account's rate limit: nothing was sent, and nothing
                      else should be tried either.

    ``channels`` is the exact set of chat apps to send to (all of them);
    ``channel`` a preference, alone when ``strict``."""
    import urllib.error
    import urllib.request

    base, bearer = edge if edge is not None else owner_edge()
    if not base or not bearer:
        return {"delivered": False, "unconfigured": True,
                "error": "this Mac is not signed in to Memoe's cloud"}
    body = {"text": str(text)[:MAX_CHARS], "urgency": urgency if urgency in URGENCIES else "normal",
            "idempotency_key": key or uuid.uuid4().hex}
    if channels:
        body["channels"] = list(channels)
    elif channel:
        body["channel"] = channel
        body["strict"] = bool(strict)
    request = urllib.request.Request(
        base + OWNER_NOTIFY_PATH, data=json.dumps(body).encode("utf-8"), method="POST",
        headers={"Authorization": "Bearer " + bearer, "Content-Type": "application/json",
                 "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as answer:
            doc = json.loads(answer.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read().decode("utf-8") or "{}").get("detail")
        except (ValueError, OSError, AttributeError):
            detail = None
        if e.code == 404:
            detail = "this Memoe cloud does not have owner notify yet (404)"
        out = {"delivered": False, "error": "Memoe's cloud refused (%d): %s"
               % (e.code, detail or e.reason)}
        if e.code == 429:
            out["limited"] = True
        return out
    except (urllib.error.URLError, OSError, ValueError) as e:
        if _timed_out(e):
            return {"delivered": None, "maybe": True,
                    "error": "Memoe's cloud did not answer within %ds, so it may have been "
                             "delivered — not sending it again" % timeout}
        return {"delivered": False, "error": "could not reach Memoe's cloud: %s"
                % (getattr(e, "reason", None) or type(e).__name__)}
    if not isinstance(doc, dict):
        return {"delivered": False, "error": "Memoe's cloud answered something that is not a result"}
    if doc.get("delivered") is None and doc.get("duplicate"):
        doc["maybe"] = True
        doc.setdefault("error", "it is still being sent — not sending it again")
    doc.setdefault("delivered", False)
    if doc["delivered"] is False and not doc.get("error"):
        doc["error"] = "Memoe's cloud reached none of the owner's chats"
    return doc


def send_direct(name, text, run=None):
    """One forward through this Mac's own `hermes send --to <name>`. "" when
    it went, otherwise the refusal in Hermes's own words.

    **Never `--quiet`.** With it, a refusal was "hermes send exited 1" and
    nothing else, which is how a switched-off Telegram looked like a flaky one
    for days. The body goes over stdin, never argv: `ps` shows argv to every
    user on the Mac, and a reminder can quote private mail."""
    run = run or subprocess.run
    try:
        p = run([hermes_cli(), "send", "--to", name, "--file", "-"],
                input=text, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                universal_newlines=True, timeout=SEND_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return "%s: %s" % (type(e).__name__, e)
    if p.returncode == 0:
        return ""
    lines = [ln.strip() for ln in ((p.stderr or "") + "\n" + (p.stdout or "")).splitlines()
             if ln.strip()]
    # The last line that says something, not a traceback's frame or a blank.
    said = [ln for ln in lines if not ln.startswith(("File ", "Traceback"))]
    return said[-1] if said else "hermes send exited %d and printed nothing" % p.returncode


# ── one key per message, and a local limit ───────────────────────────────

@contextlib.contextmanager
def _reach_lock():
    """Its own lock, never `ledger_lock`: `release_held` forwards while it
    holds that one, and flock is not re-entrant across two opens."""
    fd = None
    try:
        os.makedirs(moe_home(), exist_ok=True)
        fd = os.open(_reach_path() + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError as e:
        logger.info("reach: no lock (%s) — going on", e)
    try:
        yield
    finally:
        if fd is not None:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


def _reach_path():
    return os.path.join(moe_home(), REACH_FILENAME)


def _read_reach():
    doc = _read_json_file(_reach_path()) or {}
    recent = [r for r in doc.get("recent") or [] if isinstance(r, dict)]
    sends = [s for s in doc.get("sends") or [] if isinstance(s, dict)]
    return recent, sends


def _write_reach(recent, sends):
    path = _reach_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"recent": recent[-50:], "sends": sends[-200:]}, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _digest(text, scope):
    import hashlib
    return hashlib.sha256(("%s\0%s" % (scope, " ".join(str(text).split()))).encode("utf-8")) \
        .hexdigest()[:32]


def message_key(text, scope, now_s=None):
    """``(key, earlier result or None)`` for one logical message. The same
    words for the same scope inside `REPEAT_WINDOW_S` get the same key — so
    the edge sends them once — and the earlier call's result."""
    now_s = time.time() if now_s is None else now_s
    h = _digest(text, scope)
    try:
        with _reach_lock():
            recent, sends = _read_reach()
            recent = [r for r in recent if now_s - float(r.get("at") or 0) < REPEAT_WINDOW_S]
            for r in recent:
                if r.get("h") == h and isinstance(r.get("key"), str):
                    return r["key"], r.get("result")
            key = "moe-" + uuid.uuid4().hex
            recent.append({"h": h, "key": key, "at": now_s, "result": None})
            _write_reach(recent, sends)
            return key, None
    except Exception as e:  # noqa: BLE001 — a key is never worth a lost message
        logger.warning("reach: could not keep the message key: %s", e)
        # A time bucket, so the same words tomorrow are a new message.
        return "moe-%s-%d" % (h, int(now_s // REPEAT_WINDOW_S)), None


def _remember_result(key, result):
    try:
        with _reach_lock():
            recent, sends = _read_reach()
            for r in recent:
                if r.get("key") == key:
                    r["result"] = result
            _write_reach(recent, sends)
    except Exception as e:  # noqa: BLE001
        logger.warning("reach: could not keep the result: %s", e)


def _local_limit(urgency, now_s=None, count=False):
    """"" when this Mac may send one more to the owner's phone, else why not.
    Counts nothing unless `count`: a send is counted by `_count_send` once it
    was actually attempted, so a message that went nowhere costs nothing."""
    now_s = time.time() if now_s is None else now_s
    try:
        with _reach_lock():
            recent, sends = _read_reach()
            sends = [s for s in sends if now_s - float(s.get("at") or 0) < 86400]
            rules = list(LOCAL_LIMITS)
            if urgency == "urgent":
                rules.append(LOCAL_URGENT_LIMIT)
            for window, most, words in rules:
                seen = [s for s in sends if now_s - float(s.get("at") or 0) < window
                        and (window != LOCAL_URGENT_LIMIT[0] or s.get("urgency") == "urgent")]
                if len(seen) >= most:
                    return words
            if count:
                sends.append({"at": now_s, "urgency": urgency})
                _write_reach(recent, sends)
            return ""
    except Exception as e:  # noqa: BLE001 — a limit that cannot be read does not block
        logger.warning("reach: could not read the local limit: %s", e)
        return ""


def _count_send(urgency, now_s=None):
    """One message this Mac actually tried to put on the owner's phone."""
    now_s = time.time() if now_s is None else now_s
    try:
        with _reach_lock():
            recent, sends = _read_reach()
            sends = [s for s in sends if now_s - float(s.get("at") or 0) < 86400]
            sends.append({"at": now_s, "urgency": urgency})
            _write_reach(recent, sends)
    except Exception as e:  # noqa: BLE001
        logger.warning("reach: could not count a send: %s", e)


#: What the cloud said reaches the owner, as `channels.py owner-status` (the
#: channel-holder tick) last wrote it, or as asked here when that is old.
OWNER_REACH_FILENAME = "owner-reach.json"
OWNER_REACH_FRESH_S = 15 * 60
OWNER_STATUS_PATH = "/v1/owner/status"


def owner_channels(now_s=None, edge=None):
    """The chat apps Memoe's cloud can reach the owner on, or None when that
    cannot be known (not signed in, never asked, cloud unreachable). A
    positive answer is cached for `OWNER_REACH_FRESH_S` (the app writes it
    too, the moment it sees a chat confirmed); "none" never is. So a forward
    never spends the account's notify allowance for an owner chat that does
    not exist, and never skips one that has just been confirmed."""
    import urllib.error
    import urllib.request

    now_s = time.time() if now_s is None else now_s
    path = os.path.join(moe_home(), "cloud", OWNER_REACH_FILENAME)
    doc = _read_json_file(path)
    known = doc.get("channels") if isinstance(doc, dict) else None
    known = [str(c) for c in known if isinstance(c, str)] if isinstance(known, list) else None
    # Only a POSITIVE answer is trusted from the file: "no owner chat" can
    # change the moment they confirm it in the app, and a cached "none" would
    # keep every forward off the cloud for a quarter of an hour after.
    if known and now_s - float((doc or {}).get("at") or 0) < OWNER_REACH_FRESH_S:
        return known
    base, bearer = edge if edge is not None else owner_edge()
    if not base or not bearer:
        return known
    request = urllib.request.Request(base + OWNER_STATUS_PATH, method="GET",
                                     headers={"Authorization": "Bearer " + bearer,
                                              "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=5) as answer:
            got = json.loads(answer.read().decode("utf-8") or "{}").get("channels")
    except (urllib.error.URLError, OSError, ValueError, AttributeError):
        return known
    if not isinstance(got, list):
        return known
    got = sorted(str(c) for c in got if isinstance(c, str))
    if not got:
        return got
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"channels": got, "at": int(now_s)}, f)
        os.replace(tmp, path)
    except OSError:
        pass
    return got


# ── whose words asked for a channel ─────────────────────────────────────

def _turn_words():
    """The words of the turn this call belongs to, when a PERSON said them —
    from the fork's recipient-grounding ledger (slice B,
    `agent/recipient_grounding.py`): "" when this turn is not a person's (a
    job, a helper, a note), None when there is no ledger to ask."""
    try:
        from agent import recipient_grounding as grounding  # type: ignore
    except Exception:
        return None
    try:
        key = grounding.current_key(os.environ.get("HERMES_SESSION_ID", ""))
        if not key:
            return None
        doc = _read_json_file(str(grounding.ledger_path(key)))
        if doc is None:
            return None
        cur = doc.get("current") if isinstance(doc.get("current"), dict) else {}
        if cur.get("origin") != "person":
            return ""
        # A person on THIS Mac. A chat-platform sender may be any contact let
        # in, and this Mac cannot check them against the owner chat (only the
        # edge holds it), so their words never pick a channel for the owner.
        sender = cur.get("sender") if isinstance(cur.get("sender"), dict) else {}
        return str(cur.get("text") or "") if sender.get("kind") == "local" else ""
    except Exception:
        return None


#: The fork's words for a live turn the person started AT THIS MAC
#: (`open_settings._AT_THE_MAC`); "the person's message" is a chat platform,
#: where the sender may be a contact.
_AT_THE_MAC = "the person's own turn"


def _live_person_turn():
    """With no words to read: only a live turn the person started at this Mac
    counts — never a chat-platform turn (possibly a contact's), a job, a
    helper or a note. The fork's `turn_presence`; fails closed."""
    try:
        from tools.browser_chrome_extension import turn_presence  # type: ignore
        verdict = turn_presence()
        return bool(isinstance(verdict, dict) and verdict.get("live")
                    and verdict.get("why") == _AT_THE_MAC)
    except Exception:
        return False


def names_app(words, name):
    rule = _SAID.get(name)
    return bool(rule and words and rule.search(words))


def person_asked_for(name):
    """Did the PERSON ask for `name`, in their own words this turn? With the
    grounding ledger: their words, typed or spoken at this Mac, must name it.
    Without one: only a live turn they started at this Mac — never a contact's
    chat turn, a job, a helper or a background note."""
    words = _turn_words()
    if words is None:
        return _live_person_turn()
    return names_app(words, name)


# ── the forward, and the primitive ──────────────────────────────────────

def fan_out(text, channels, run=None, skip=(), notify=None, direct=None, key=None,
            outcome=None, known=None):
    """Forward `text` to the owner on each named chat app.

    Each name is a CHANNEL, never an address. The ones Memoe's cloud can reach
    the owner on (`owner_channels`, cached; `known` for a caller that already
    asked) go in ONE request, under ONE key for this message, to the owner's
    own chat on each; the rest go through this Mac's own `hermes send`
    (`send_direct`), as they always did. A cloud that did not answer in time
    MAY have sent it: those channels report that and nothing else is sent. A
    cloud that rate-limited the account falls back to this Mac's own send.

    `key` is the message's key when the caller already has one (`deliver`
    shares one across this and its own cloud call); `outcome`, a dict, is told
    whether the cloud was asked and whether it may have delivered. `skip`
    names platforms the scheduler is delivering to itself; `direct` limits the
    second step to the channels named in it (None: all of them).

    Returns {platform: error} for the ones that failed, in their own words;
    empty means all went."""
    notify = notify or notify_edge
    outcome = outcome if isinstance(outcome, dict) else {}
    skip = {str(s).strip().lower() for s in (skip or ())}
    names = [c for c in channels if c not in skip]
    if not names:
        return {}
    prior = None
    if key is None:
        key, prior = message_key(text, "fan:" + ",".join(sorted(names)))
    if isinstance(prior, dict) and prior.get("done"):
        return dict(prior.get("errors") or {})
    reachable = owner_channels() if known is None else known
    on_cloud = [c for c in names if c in CHAT_APPS
                and (reachable is None or c in reachable)]
    errors, reached = {}, set()
    cloud = {"unconfigured": True}
    if on_cloud:
        cloud = notify(text, channels=on_cloud, key=key)
        outcome["asked"] = True
        outcome["maybe"] = bool(cloud.get("maybe"))
        reached = set(cloud.get("channels") or ([cloud["channel"]] if cloud.get("delivered")
                                                and cloud.get("channel") else []))
        outcome["reached"] = sorted(reached)
    for name in names:
        if name in reached:
            continue
        if name in on_cloud and cloud.get("maybe"):
            errors[name] = cloud.get("error") or "may have been delivered"
            continue
        if not has_screen():
            errors[name] = (cloud.get("error") if name in on_cloud else "") or "not reached"
            continue
        if direct is not None and name not in direct:
            errors[name] = "%s; and it is not ticked in Settings › Background, so this Mac " \
                "does not guess at a chat there" % ((cloud.get("error") if name in on_cloud
                                                     else "") or "not reached")
            continue
        err = send_direct(name, text, run=run)
        if not err:
            continue
        if name not in on_cloud or cloud.get("unconfigured"):
            errors[name] = err
        else:
            errors[name] = "%s (and Memoe's cloud: %s)" % (err, cloud.get("error"))
    if not cloud.get("maybe"):
        _remember_result(key, {"done": True, "errors": errors})
    return errors


def _channel_name(channel):
    """A bare chat-app name, "" for none, or None for something that is not
    one — an address, a chat id, a phone number."""
    if channel is None:
        return ""
    name = str(channel).strip().lower()
    if not name:
        return ""
    if not _BARE_NAME.match(name) or name in _NOT_A_CONNECTOR:
        return None
    return name


def reach_owner(text, urgency="normal", channel="", now=None, cfg=None, run=None,
                notify=None, hold=None, source="reach_owner"):
    """Put `text` in front of the owner — never anybody else. See the section
    comment above for the order. Returns a dict the brain can repeat
    truthfully:

    ``ok``        whether it reached them (False when it may have: see ``via``)
    ``channel``   where: "island", a chat app's name, or "inbox" when kept
    ``via``       "island", "memoe", "this-mac", "held", "maybe" or "limited"
    ``tried``     {channel: why not}, in each refusal's own words
    ``detail``    one sentence for the brain to say
    Never raises."""
    try:
        notify = notify or notify_edge
        name = _channel_name(channel)
        if name is None:
            return {"ok": False, "channel": "", "via": "", "tried": {},
                    "detail": "channel takes a chat app's name, like telegram — never a "
                              "chat, a number or an address. Nothing was sent."}
        urgency = urgency if urgency in URGENCIES else "normal"
        body = scrub(clean(text))[:MAX_CHARS]
        if not body:
            return {"ok": False, "channel": "", "via": "", "tried": {},
                    "detail": "there was nothing to say. Nothing was sent."}
        note = ""
        if name and not person_asked_for(name):
            # The model's argument alone never overrides where they are.
            note = (" (They did not ask for %s in their own words, so it went where "
                    "they are.)" % name)
            name = ""
        if not name and at_mac(now):
            write_inbox(body, source=source)
            note_said(body, to=(SCREEN,), now=now)
            return {"ok": True, "channel": "island", "via": "island", "tried": {},
                    "detail": "They are at the Mac, so it is on the island (not their "
                              "phone)." + note}
        key, prior = message_key(body, "reach:%s:%s" % (name, urgency))
        if isinstance(prior, dict) and prior.get("ok"):
            done = dict(prior)
            done["detail"] = "Already sent a moment ago: " + str(prior.get("detail") or "")
            done["duplicate"] = True
            return done
        if not (isinstance(prior, dict) and prior.get("via") == "maybe"):
            why_not = _local_limit(urgency, count=False)
            if why_not:
                if has_screen():
                    write_inbox(body, source=source)
                return {"ok": False, "channel": "inbox" if has_screen() else "",
                        "via": "limited", "tried": {},
                        "detail": "Not sent to their phone: Moe has already messaged them %s "
                                  "(this Mac's limit). It is in their inbox instead — say so."
                                  % why_not}
        tried = {}
        counted = False
        reachable = owner_channels()
        if reachable is not None and not reachable:
            # The cloud has no owner chat for them: asking it would cost the
            # account's allowance and reach nobody. Straight to this Mac's own.
            cloud = {"delivered": False, "error": "their own chat is not confirmed with "
                     "Memoe (Connections › Telegram › Confirm it's you)"}
        else:
            cloud = notify(body, urgency=urgency, channel=name, strict=False, key=key)
            if not cloud.get("unconfigured"):
                _count_send(urgency)
                counted = True
        if cloud.get("delivered"):
            went = cloud.get("channel") or name or "a chat"
            tried.update(cloud.get("tried") or {})
            note_said(body, to=tuple(cloud.get("channels") or [went]), now=now)
            also = [c for c in (cloud.get("channels") or []) if c != went]
            out = {"ok": True, "channel": went, "via": "memoe", "tried": tried,
                   "detail": "Sent to them on %s%s, through Memoe's own bot.%s"
                             % (went, (" and " + ", ".join(also)) if also else "", note)}
            _remember_result(key, out)
            return out
        if cloud.get("maybe"):
            out = {"ok": False, "channel": name or "", "via": "maybe", "tried": {},
                   "detail": "It may have reached them — %s. Do not say it was sent for "
                             "certain, and do not send it another way." % cloud.get("error")}
            _remember_result(key, out)
            return out
        if not cloud.get("unconfigured"):
            tried.update(cloud.get("tried") or {})
            tried.setdefault("memoe", cloud.get("error") or "not reached")
        # This Mac's own forwards: the chat apps they ticked themselves. A
        # named channel they did not tick is not guessed at — a home channel on
        # a personal account can be somebody else's chat (ticket #15).
        if has_screen():
            ticked = extra_channels(cfg)
            for c in ([name] if name else ticked):
                if c not in ticked:
                    tried[c] = ("not set up for Moe to reach them (confirm their chat through "
                                "Memoe, or tick it in Settings › Background)")
                    continue
                if not counted:
                    _count_send(urgency)
                    counted = True
                err = send_direct(c, body, run=run)
                if not err:
                    note_said(body, to=(c,), now=now)
                    out = {"ok": True, "channel": c, "via": "this-mac", "tried": tried,
                           "detail": "Sent to them on %s, from this Mac.%s" % (c, note)}
                    _remember_result(key, out)
                    return out
                tried[c] = ("%s; from this Mac: %s" % (tried[c], err)) if c in tried else err
        why = "; ".join("%s: %s" % kv for kv in sorted(tried.items())) or \
            "none of their chat apps is connected"
        if has_screen():
            try:
                write_inbox(body, source=source)
            except OSError as e:
                return {"ok": False, "channel": "", "via": "", "tried": tried,
                        "detail": "Could not reach them (%s), and could not keep it: %s" % (why, e)}
            return {"ok": False, "channel": "inbox", "via": "held", "tried": tried,
                    "detail": "Could not reach them on their phone (%s). It is waiting in their "
                              "inbox on the Mac — tell them that, do not say it was sent." % why}
        held, why_not = _hold(hold, body, source=source, reason=_hold_reason(tried))
        if held:
            return {"ok": False, "channel": "inbox", "via": "held", "tried": tried,
                    "detail": "Could not reach them (%s). It is held for their Mac, which will "
                              "say it when it wakes — tell them that, do not say it was sent." % why}
        return {"ok": False, "channel": "", "via": "", "tried": tried,
                "detail": "Could not reach them (%s) and could not hold it: %s" % (why, why_not)}
    except Exception as e:  # noqa: BLE001 — a tool never raises
        logger.warning("reach_owner failed: %s", e, exc_info=True)
        return {"ok": False, "channel": "", "via": "", "tried": {},
                "detail": "Could not reach them: %s: %s" % (type(e).__name__, e)}


def already_ran(job, occurrence, seen_file=None):
    """True when `ran-seen.json` — what the app pulled from the edge on wake
    ("loops follow the person" S2) — says another device claimed or ran
    `job`'s `occurrence`. Read here, in the delivery, because this is the
    last moment before the person hears it twice: a 09:00 daily reminder
    the machine fired while the Mac was shut is not said again by a Mac
    waking at 09:10. Stdlib only; an unreadable file is "nobody has"."""
    if not job or not occurrence:
        return False
    path = seen_file or os.path.join(moe_home(), "cloud", "ran-seen.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    rows = data.get("ran") if isinstance(data, dict) else None
    # Another device's run, never this Mac's own: the edge returns every
    # device's rows, and since Moe's own background jobs report `ran` too, a
    # Mac's earlier delivery in the same bucket would mute its next one.
    return any(isinstance(r, dict) and r.get("job") == job and r.get("occurrence") == occurrence
               and r.get("runtime") != "mac" for r in rows or [])


def deliver(text, source="", job="", job_id="", chat_id=SCREEN, cfg=None,
            run=None, skip=(), now=None, hold=None, occurrence="",
            offer="", instruction="", channel_text="", words=None, subject="",
            options=()):
    """The whole target: screen first, then the user's connectors.

    The screen never fails for a reason a connector would, so it is written
    first and a connector error is reported without un-writing it — a
    reminder that reached the screen but not Telegram is a reminder that
    reached the user. A gateway lifecycle broadcast is accepted and dropped:
    success, so Hermes does not retry it, and nothing written.

    `job` is the job's NAME from Hermes's own record, and it is the only
    thing that arms the ledger: trailer lines are taken off every delivery
    and applied on `LEDGER_JOB` alone. `job_id` is the same record's id and
    is carried only so that "stop reminding me" has something to hand
    Hermes's `cronjob` tool. Returns (ok, error_text).

    **`hold` is what stops a screenless runtime dropping the message.** On a
    machine `has_screen()` is False, and if the person has ticked no
    `reminderChannels` there is nothing left: `reached` comes back empty and
    every earlier version of this function returned `(True, "")` — a
    delivery that reached nobody, reported as success, which is the exact
    failure this module's own `has_screen()` docstring names one screen
    over. CLOUD-PLAN §6 item 7: *a message is held, never dropped.*

    `hold(text, source=…, job=…, reason=…)` is called with nobody reached and
    should write the sentence down where the Mac will find it — in
    production a sealed `say` record on the ledger, which the notch speaks on
    wake (LEDGER-WIRE §16). It is **injected rather than imported** because
    this module is stdlib-only by contract and the ledger is not; the adapter
    holds that wire.

    It returns truthy when it took the message. **A `hold` that is absent, or
    that refuses, is a FAILED delivery** and says so — never a quiet success.
    That is `_sibling.py`'s own rule, which this is the first caller to need:
    a runtime that cannot queue must say so rather than answer "I'll do it
    when your Mac wakes" about a record nobody wrote.
    """
    # The one gate, and it is a shape not a reason: Moe's plumbing
    # describing itself never reaches a person. Accepted, so Hermes does
    # not retry it, and written to the log instead of the island.
    if is_tool_markup(text):
        # Never a message: tool calls a model wrote out as text. Recorded as
        # machinery, accepted so Hermes does not retry it.
        note_machinery(text, job, now=now)
        return True, ""
    if isinstance(text, str) and text.strip().strip(".").lower() in _SILENCE_WORDS:
        # A turn that said nothing: "noop" became a card on 2026-09-30.
        logger.info("delivery: a silent reply (%r), not delivered", text.strip()[:20])
        return True, ""
    if isinstance(text, str) and _SILENT_LINE.search(text):
        text = _SILENT_LINE.sub("", text).strip()
        if not strip_trailers(text)[0].strip() and not strip_trailers(text)[1]:
            return True, ""
    if is_machinery(text) or is_machinery(clean(text)):
        note_machinery(text, job, now=now)
        return True, ""
    # S2: another device already ran this occurrence — the machine, while
    # this Mac was shut. Said once, there; not again here. Success, so Hermes
    # does not retry it, and the log says which occurrence and why.
    if occurrence and already_ran(job, occurrence):
        logger.info("delivery: %s @ %s was already run by another device; not said again",
                    job, occurrence)
        if job == LEDGER_JOB:
            # Not said — but the pass's ledger changes still apply, quietly:
            # the monitor has moved past this change and will not show it
            # again (review of one-moe #2).
            apply_trailers(text, now=now, job=job, quiet=True)
        return True, ""
    # First, before the text is cleaned, shown, spoken or forwarded: the
    # ledger trailers come off — on every job. They are only APPLIED for
    # the one job that is told about them. `now` is the clock, for the tests.
    # Whether the reply names a loop at all, read before the ledger applies
    # it: the fourth mention of a loop retires it, and that mention is still
    # the loop's to say (MAX_SAID), not a loop-less repeat.
    # The background pass: whether its sentence is said is decided BEFORE
    # the ledger applies its trailers, so a sentence held back (talking to
    # itself, or a repeat) and a reply that is only trailers move a loop's
    # raise without spending one of its four mentions. The trailers always
    # apply — a close or a reschedule of another loop is never lost.
    silenced = ""
    if job == LEDGER_JOB:
        now_ = now or datetime.now(timezone.utc)
        _brief_since(now_, now=now_)        # a pass that says nothing still saw the brief
        plain, found = strip_trailers(text)
        before = set(read_open())
        tomb = set(_read_closed(now_))
        named = [_fields(body)[0] for kind, body in found if kind == "open"]
        # A retired loop's slug is no loop: MAX_SAID let it go, and naming it
        # again must not let its sentence be said for ever (review of nag-hold).
        live = [n for n in named if n in before or n not in tomb]
        if plain.strip():
            if talks_to_itself(plain, before | tomb | set(named)
                               | {l for r in _read_said() for l in (r.get("loops") or []) if isinstance(l, str)}):
                silenced = "the background pass talked to itself"
            else:
                silenced = quiet_about(plain, live, now=now_)
        text, trailers, loops = apply_trailers(text, now=now, job=job,
                                               quiet=bool(silenced) or not plain.strip())
        if silenced:
            logger.info("delivery: the background pass is not saying it — %s: %s", silenced, plain[:160])
            return True, ""
    else:
        text, trailers, loops = apply_trailers(text, now=now, job=job)
    text = scrub(clean(text))[:MAX_CHARS]
    # An offer's fuller text for the chat apps carries words from other
    # people's conversations: the same trailer strip, clean-up, write-time
    # scrub and cap as the line itself (it used to skip all four).
    if channel_text:
        channel_text, _t, _l = apply_trailers(channel_text, now=now, job="")
        channel_text = scrub(clean(channel_text))[:MAX_CHARS]
    if not text:
        # Nothing but trailers: a loop was opened or closed and there was
        # nothing to say out loud. Delivering nothing is the right outcome.
        # On any other job `trailers` is 0 — a message that was only a
        # trailer quoted out of someone's mail is the empty delivery it is,
        # and says so, rather than passing as silent bookkeeping.
        return (True, "") if trailers else (False, "empty message")
    # The id is minted first because `write_inbox` has to carry it, but the
    # RECORD is written last, from the surfaces that actually took the
    # message. See `note_said`: a record written before the sending claims
    # a delivery that may not have happened.
    said = uuid.uuid4().hex[:12]
    reached = []
    # `skipped` is the SKIP SET — the platforms the scheduler is delivering
    # this job to itself — and not "those of them the person also ticked".
    # It used to be the intersection with `extra_channels(cfg)`, which on a
    # machine is empty (a machine's config.json ticks nothing; the channels
    # travel in the job), so a `deliver: moe,telegram` job was sent by the
    # scheduler AND held for the Mac to say again. S2's falsifier found it.
    skipped = sorted({str(s).strip().lower() for s in (skip or ()) if str(s).strip()})
    # On a runtime with no screen — the away machine — `hermes send` cannot
    # reach a chat app (docs/LOOPS.md §2 "Deliver" keeps the measurement):
    # `hermes_cli/send_cmd.py` takes the bot-token path for
    # Telegram, WhatsApp, Slack, Discord, Signal and SMS, and the machine
    # holds no such token by design (boot.sh unsets it once the relay dial
    # is written; the edge's relay is the only door). The channels a job on
    # the machine reaches are in its OWN `deliver` — `moe,telegram`, which
    # the scheduler carries over the relay and hands here in `skip` — never
    # in this file's fan-out. So the ticked channels are the Mac's fan-out
    # only; here, a `moe`-only job is held for the Mac, as before.
    channels = [c for c in extra_channels(cfg) if c not in skipped] if has_screen() else []
    if offer and channels and not offers_to_chats(cfg):
        logger.info("delivery: an offer stays on the island — offers to %s are not turned on",
                    ", ".join(channels))
        channels = []
    # Where they are. At the Mac, the island is the whole delivery and the
    # phone stays quiet; the ticked channels are for when they are not.
    # `here` is read once so the log and the choice cannot disagree.
    here = at_mac(now)
    if here and channels:
        logger.info("delivery: at the Mac — island only, not %s", ", ".join(channels))
        channels = []
    # `deliver: moe:telegram` — the owner, on the chat app he named ("message
    # me on Telegram"). The name is a CHANNEL and never an address: it goes to
    # his own chat there (`fan_out` → Memoe's cloud, then this Mac's own
    # forward), on this Mac and on the away machine alike, whether or not he
    # is at the Mac — he asked for it there. `rewrite_cron_deliver` turns a
    # Moe-made job's bare `telegram` into this, so a job can never resolve a
    # bare platform to some contact's chat (ticket #15).
    named = _channel_name(chat_id) if chat_id and chat_id != SCREEN else ""
    if named and named in CHAT_APPS and named not in skipped:
        channels = [named]
        chat_id = SCREEN
    # Quiet hours, for what Moe raises on its own: the phone waits for the
    # morning; the island (silent until tapped) still gets it. A reminder
    # the person set themselves is theirs and goes now. Only where the
    # release runs (moe-loop-check, a Mac job): a screenless runtime holds
    # nothing it cannot later send.
    if channels and has_screen() and is_moe_job(job) and is_quiet(now, cfg):
        # What is held is what would have gone: an offer's draft with it.
        if hold_for_morning(channel_text or text, channels, now=now, job=job):
            channels = []
    if has_screen():
        # `words` is injected, like `hold`: this module is stdlib-only and a
        # model call is not. It is asked only about text too long for its
        # first line to say what it is, and never costs the delivery.
        label = {}
        if words is not None and not offer:
            try:
                label = words(text, job) or {}
            except Exception:  # noqa: BLE001
                label = {}
        try:
            write_inbox(text, source=source, job=job, chat_id=chat_id,
                        said=said, job_id=job_id, loops=loops,
                        offer=offer, instruction=instruction,
                        title=label.get("title", ""), summary=label.get("summary", ""),
                        subject=subject_for(subject, offer, loops), options=options)
        except OSError as e:
            return False, "inbox: %s" % e
        reached.append(SCREEN)
    # A chat app has no card, so an offer carries its draft there in words
    # (`channel_text`), and "send it" in reply goes through the send gate.
    # ONE key for this message across everything below: the forward and the
    # screenless runtime's own cloud call are the same message, and the edge
    # must see them as one (review round 2, finding 4).
    words = channel_text or text
    msg_key, _prior = message_key(words, "deliver:%s:%s" % (job, occurrence))
    asked = {}
    errors = fan_out(words, channels, run=run, skip=(), key=msg_key, outcome=asked,
                     direct=set(extra_channels(cfg)) if named else None)
    reached += [c for c in channels if c not in errors]
    # A runtime with no screen (the away machine) is by definition one the
    # owner is not sitting at: a `moe` delivery goes to their own chat through
    # Memoe's cloud before anything is held for the Mac. Not when the
    # scheduler is already sending this job to a chat app itself (`skipped`),
    # not a nudge Moe raised on its own during quiet hours, and not a second
    # time when the forward above already asked the cloud.
    maybe = "it may have been delivered" if asked.get("maybe") else ""
    if not has_screen() and not reached and not skipped and not asked.get("asked") \
            and not (is_moe_job(job) and is_quiet(now, cfg)):
        cloud = notify_edge(words, key=msg_key)
        if cloud.get("delivered"):
            reached += list(cloud.get("channels") or [cloud.get("channel") or "memoe"])
        elif cloud.get("maybe"):
            maybe = cloud.get("error") or "it may have been delivered"
    # `skip` — the scheduler delivering to those platforms itself for this
    # same job — is deliberately NOT counted as reached. `_job_delivers_to`
    # reduces `telegram:-100123:45` to a bare `telegram`, so a job aimed at
    # a group or a topic would otherwise claim the person's own DM, which
    # is the one chat `attach_context` will match it against.
    note_said(text, job=job, job_id=job_id, loops=loops, to=reached,
              now=now, rec_id=said, note=instruction if offer else "")
    if job == LEDGER_JOB and reached:
        note_mention(text, now=now)
    if loops and reached:
        # The sentence itself goes into each loop's history, so the next
        # raise knows what was said last time and can say something else.
        note_history(loops, "Moe said: %s" % text, now=now)
    if maybe and not reached:
        # Possibly in front of them already; holding it too would say it twice.
        return True, maybe
    if not reached and not skipped:
        # Nobody at all. Either this runtime has no screen and no channels
        # ticked, or every channel it had refused. Held, never dropped.
        #
        # **`skipped` is why this is not `if not reached`.** A job with
        # `deliver: moe,telegram` has the SCHEDULER sending to Telegram
        # itself, and passes those platforms in `skip`. They are deliberately
        # not credited to `reached` — the comment above says why, and that
        # rule is about `attach_context`, not about delivery. `reached` was
        # bookkeeping until this branch made it a trigger, and reading it as
        # "nobody was reached" then held a sentence the person had ALREADY
        # read on Telegram, for the Mac to say to them again, labelled
        # `no-channels` while they had channels. Two different questions had
        # come to share one list.
        #
        # `note_said` above has already recorded it with `to=()` — offered to
        # no surface — which is the honest state and is what makes it safe to
        # hold rather than re-send: nothing downstream believes the person
        # has seen this.
        reason = _hold_reason(channels)
        held, why = _hold(hold, text, source=source, job=job, reason=reason)
        if held:
            # Held — and the connector failures that got us here are STILL
            # reported. Returning `(True, "")` threw them away, so on a
            # screenless machine "both my connectors have been dead for a
            # week" became silence: `fan_out` logs nothing of its own, and
            # this was the only place the errors existed. `hold.py`'s
            # docstring says "'held' and 'lost' must never look the same from
            # outside"; this is that symmetry in the other direction, where
            # "held after everything failed" and "held because there was
            # nothing to try" must not look the same either.
            return True, _errors_text(errors)
        # NOT a success. A caller that retries is the better failure here: a
        # screenless runtime with nothing to say to and no ledger to write to
        # has genuinely lost the message, and the log line is the only place
        # anyone will ever learn it existed.
        logger.warning("delivery: reached nobody and could not hold it (%s): %s",
                       reason, why)
        return False, "reached nobody and could not hold it: %s%s" % (
            why, ("; " + _errors_text(errors)) if errors else "")
    if errors:
        return True, _errors_text(errors)
    return True, ""


def _errors_text(errors):
    """`fan_out`'s failures as one line, in a stable order."""
    return "; ".join("%s: %s" % kv for kv in sorted(errors.items()))


def _hold_reason(channels):
    """Why nobody was reached, in the ledger's small fixed vocabulary.

    Two values, and not free text: this string travels in the CLEAR on a
    `say` record so a reader with no thread key can say what kind of thing is
    waiting, and a free-text reason here would be a second door for the
    person's own words to leave by.

    Two rather than three, and the third is worth naming because it was
    written and deleted. `no-surface` — "this runtime has no screen" — cannot
    fire: reaching nobody already implies no screen, since a screen that
    exists is written first and joins `reached`, and a screen that fails
    returns before this. A branch that cannot fire is §17.2's check that
    cannot fail, and this file has been the place that lesson was learned
    more than once."""
    return "send-failed" if channels else "no-channels"


def _hold(hold, text, source="", job="", reason="no-channels"):
    """Call the injected hold. Returns (took_it, why_not).

    Every exception is caught on purpose. `hold` reaches across a plugin
    boundary into a library that may not be installed yet — which is the
    ordinary state of a Mac between `scripts/install.sh` and the next app
    build — and a delivery must not raise out of this module because the
    ledger is missing. It must *report*, which is what the caller does."""
    if hold is None:
        return False, "no ledger on this runtime to hold it in"
    try:
        took = hold(text, source=source, job=job, reason=reason)
    except Exception as e:  # noqa: BLE001 — see the docstring
        return False, "%s: %s" % (type(e).__name__, e)
    return (True, "") if took else (False, "the ledger declined it")


# ── `deliver.py loop …`: the island's own buttons (owner, 2026-09-30) ──────
#
#   deliver.py loop done <slug>… [--text <what the card said>]
#   deliver.py loop close|mute|unmute <slug>
#   deliver.py loop snooze <slug> <when>
#
# One JSON object on stdout; exit 0 when it did what it says, 1 when there
# was nothing to do, 2 for a call it cannot read. `done` closes each loop and
# holds the subject until what it came from changes (`hold_subject`), and
# says which Apple Reminder it came from, if one, so the card can offer to
# tick that off too. The Memoe app calls this, never the brain: Done on the
# island used to reach the ledger as a note to the brain, which never closed
# anything (moe-inbox, 2026-09-30).

def _cli(argv):
    if len(argv) < 2 or argv[0] != "loop":
        print(json.dumps({"ok": False, "error": "usage: deliver.py loop done|close|mute|unmute|snooze …"}))
        return 2
    act, rest = argv[1], argv[2:]
    text = ""
    if "--text" in rest:
        i = rest.index("--text")
        text = rest[i + 1] if i + 1 < len(rest) else ""
        rest = rest[:i] + rest[i + 2:]
    bad = [r for r in rest if not _SLUG.match(r)]
    if bad and act != "snooze":
        print(json.dumps({"ok": False, "error": "not a follow-up name: %s" % ", ".join(bad)[:120]}))
        return 2
    slugs = [r for r in rest if _SLUG.match(r)]
    if act == "done":
        if not slugs and not text.strip():
            print(json.dumps({"ok": False, "error": "done needs a slug or --text"}))
            return 2
        out = hold_subject(slugs, text)
        ok = bool(out["closed"] or out["held"])
        print(json.dumps(dict(out, ok=ok)))
        return 0 if ok else 1
    if act == "snooze":
        if len(rest) != 2 or not _SLUG.match(rest[0]):
            print(json.dumps({"ok": False, "error": "snooze takes <slug> <when>"}))
            return 2
        new = snooze_loop(rest[0], rest[1])
        print(json.dumps({"ok": bool(new), "next": new or ""}))
        return 0 if new else 1
    fn = {"close": close_loop, "mute": mute_loop, "unmute": unmute_loop}.get(act)
    if fn is None or len(rest) != 1 or not slugs:
        print(json.dumps({"ok": False, "error": "%s takes one slug" % act}))
        return 2
    done = bool(fn(slugs[0]))
    print(json.dumps({"ok": done}))
    return 0 if done else 1


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
