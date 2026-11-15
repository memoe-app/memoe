"""`moe`: the Mac's screen as a Hermes gateway platform.

Outbound only. Nothing ever arrives FROM this platform — Moe talks to Hermes
over the api_server — so there is no stream to subscribe to, no message
handler, no user identity. What the adapter has is a `send()`, and that is
what makes `deliver: moe` a real cron target: the scheduler resolves the
platform through the registry, finds the live adapter the gateway connected
at start-up (or, with no gateway in the process, calls
`standalone_sender_fn`) and hands over the job's final response.

Why a platform and not a file watcher on ~/.hermes/cron/output: the output
directory holds every run of every job, delivered or not, and "was this
already sent somewhere" is not written there. A platform is the seam Hermes
provides for exactly this — `all` expands to it, `hermes send --to moe`
reaches it, the dashboard lists it, and a job's `last_delivery_error` says
so if it failed.

The second thing registered here is a `pre_tool_call` hook on the `cronjob`
tool. A job created from a Moe conversation records an origin of
`api_server:<session id>`, and the api_server adapter's `send()` is a stub
that returns "API server uses HTTP request/response, not send()". Measured
2026-09-02 on a one-shot reminder: ran on time, reply produced, three
delivery errors, nothing reached the user. Hermes has no default-delivery
key to point at, so the hook rewrites `origin` to `moe` for jobs created
from surfaces that cannot receive one. A job made from a chat app becomes
`moe:<app>`: a reminder asked for on Telegram still comes back on Telegram,
through the one owner path that works whichever side fronts the app.
"""

import asyncio
import logging
import os
from typing import Any, Dict, Optional

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import BasePlatformAdapter, SendResult

from . import deliver as _deliver
from . import followups as _followups
from . import hold as _hold
from . import inboxwords as _inboxwords
from . import pushes as _pushes
from . import claim as _claim
from . import cronlist as _cronlist
from . import ran as _ran
from . import rearm as _rearm
from . import routine_health as _routine_health

logger = logging.getLogger(__name__)

#: Origins that cannot be delivered back to. `api_server` is the one that
#: matters (Moe); `""` is what a cron-spawned or otherwise unattributed
#: session reports; `cli` and `local` are Hermes's names for a terminal.
#:
#: The hook reads the platform from the same `get_session_env` that
#: `tools/cronjob_tools._origin_from_env` records the job's origin from, so
#: the two always agree — including on the claude-code runtime, where the
#: MCP child sees the environment of the turn that spawned it. If that is
#: stale, the origin Hermes records is stale in the same way: a job stamped
#: `telegram` is delivered to Telegram (reaches the user); one stamped
#: `api_server` is rewritten here to `moe` (reaches the user). Neither case
#: is a job that runs and reaches nobody, which is the failure this exists
#: to prevent.
_NO_SEND_PATH = frozenset({"", "api_server", "cli", "local"})

#: The cron tool's name on the wire. Hermes renamed `cronjob` to `cronjob_manage`
#: on 2026-08-29 (tool-search core deferral) and maps the old name to the new
#: one BEFORE plugin hooks see it, so a hook matching only `cronjob` matched
#: nothing from that day until 2026-09-18. Both names, so neither rename
#: silences this again.
_CRON_TOOL_NAMES = frozenset({"cronjob", "cronjob_manage"})

#: The fork's sentinel for a job that runs on the conversation's model and
#: provider, read at fire time (hermes-agent cron/scheduler.py CONVERSATION_MODEL).
CONVERSATION_MODEL = "conversation"

#: The toolset the follow-up tool is registered under. Kept in step with
#: `FOLLOWUPS_TOOLSET` in moe-home/hermes/configure-hermes.py, which is what
#: puts the name into `platform_toolsets` for the Mac and for every chat
#: platform; a tool in a toolset nobody lists is a tool the model never sees.
FOLLOWUPS_TOOLSET = "moe_followups"


def _job_delivers_to(job_id: str):
    """(job name, platforms the scheduler itself delivers this job to).

    Read from the job record so the fan-out can skip a connector the
    scheduler is already sending to: `deliver: moe,telegram`, or `all`,
    which expands to every platform with a home channel — this one
    included. Without this, ticking Telegram in Settings and asking for
    `all` would say everything twice."""
    if not job_id:
        return "", set()
    try:
        from cron.jobs import get_job
        job = get_job(str(job_id)) or {}
    except Exception:
        return "", set()
    name = str(job.get("name") or "")
    raw = job.get("deliver")
    tokens = raw if isinstance(raw, (list, tuple)) else str(raw or "").split(",")
    already = set()
    origin = job.get("origin") if isinstance(job.get("origin"), dict) else {}

    # A missing helper is logged at ERROR by home_target_helpers and then
    # counts as "not covered": Moe delivering a second copy is the
    # recoverable direction, nothing reaching the person is not.
    try:
        get_home, iter_homes = _followups.home_target_helpers()
    except ImportError:
        get_home = iter_homes = None

    def home(platform):
        if get_home is None:
            return False
        try:
            return bool(get_home(platform))
        except Exception:
            logger.warning("moe-screen: home channel for %s did not resolve", platform, exc_info=True)
            return False
    for t in tokens:
        t = str(t).strip().lower()
        if not t or t in ("origin", "local", _deliver.PLATFORM) or t.startswith("bot-chat"):
            continue
        if t == "all":
            if iter_homes is not None:
                try:
                    for p in iter_homes():
                        if p != _deliver.PLATFORM and get_home(p):
                            already.add(str(p).lower())
                except Exception:
                    logger.warning("moe-screen: deliver=all home channels did not resolve", exc_info=True)
            continue
        # `telegram:<chat>[:<thread>]` names a chat: the scheduler sends there.
        # A BARE `telegram` reaches something only through that platform's
        # home channel, or the job's own origin chat on it
        # (`scheduler_delivery._resolve_single_delivery_target`); with
        # neither the scheduler drops it without a word. Counting it anyway
        # told `deliver()` the phone was covered, so it skipped its own way
        # to the person: 2026-10-06, two reminders on the away machine
        # (`deliver: moe,telegram`, no home channel there) "delivered to
        # moe:screen" -- a machine with no screen -- and reached nobody.
        platform = t.split(":", 1)[0]
        if ":" in t or home(platform) or str(origin.get("platform") or "").lower() == platform:
            already.add(platform)
    return name, already


def _job_record(job_id: str) -> dict:
    """The cron job's record, or {}. Never raises."""
    if not job_id:
        return {}
    try:
        from cron.jobs import get_job
        return get_job(str(job_id)) or {}
    except Exception:
        return {}


def _note_ran(job_id: str) -> str:
    """The job record, to `ran.note_ran`. Never raises."""
    try:
        from cron.jobs import get_job
        job = get_job(str(job_id)) or {}
    except Exception:  # noqa: BLE001
        return ""
    # `ran-offline` when this Mac ran it without the edge's word (D4).
    return _ran.note_ran(job, status=_claim.status_for(job))


def _occurrence_of(job_id: str) -> str:
    """The ISO instant both sides call this firing, from the job record —
    what `deliver` checks against `ran-seen.json` (S2). "" when the job or
    its schedule cannot be read, which is "do not check". Never raises."""
    if not job_id:
        return ""
    try:
        from cron.jobs import get_job
        job = get_job(str(job_id)) or {}
        when = _ran.occurrence(job) if _ran.is_reported(job) else None
        return when.isoformat() if when is not None else ""
    except Exception:  # noqa: BLE001
        return ""


class MoeScreenAdapter(BasePlatformAdapter):
    """Delivers to the Mac in front of the user. See the module docstring."""

    MAX_MESSAGE_LENGTH = _deliver.MAX_CHARS

    def __init__(self, config: PlatformConfig):
        super().__init__(config=config, platform=Platform(_deliver.PLATFORM))

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        try:
            os.makedirs(_deliver.inbox_dir(), exist_ok=True)
        except OSError as e:
            logger.warning("[%s] cannot create %s: %s", self.name, _deliver.inbox_dir(), e)
            return False
        self._mark_connected()
        logger.info("[%s] Connected — inbox %s", self.name, _deliver.inbox_dir())
        if not is_reconnect:
            # A reminder the LAST gateway was killed in the middle of gets
            # armed again here, if its moment has not passed (`rearm.py` —
            # the window, the four kinds of "interrupted", and why Hermes's
            # own ledger is the detector rather than a second one of ours).
            #
            # **Here, and not on the interrupted notice.** Hermes does send
            # one — `gateway/run_shutdown.py` `_notify_interrupted_cron_jobs`
            # — and `deliver.is_machinery` drops it, which is right: it is
            # Hermes describing itself. But it is the wrong seam for this
            # even so, for two separate reasons. It is **opt-out**:
            # `platforms.<p>.gateway_restart_notification` silences it, and
            # the away machine's boot script sets exactly that to false for Telegram
            # and sixteen chat platforms. And it only exists on a *graceful*
            # shutdown — a SIGKILL, a panic or a power cut runs no shutdown
            # hook at all and sends nothing. Gateway start is the one moment
            # every interruption has in common.
            #
            # Off the event loop: it opens the cron store and the executions
            # ledger, which is real file and sqlite I/O. `send()` below has
            # the same rule and the same reason.
            #
            # `_mark_connected()` first, deliberately: re-arming is a thing
            # we do for the person, never a reason the `moe` platform fails
            # to come up. `rearm_interrupted` never raises.
            armed = await asyncio.to_thread(_rearm.rearm_interrupted)
            if armed:
                logger.info("[%s] armed %d reminder(s) a restart cut: %s", self.name, len(armed),
                            ", ".join("%s @ %s" % row for row in armed))
        return True

    async def disconnect(self) -> None:
        self._running = False
        self._mark_disconnected()

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        metadata = metadata or {}
        record = await asyncio.to_thread(_job_record, str(metadata.get("job_id") or ""))
        if _deliver.is_machinery(content):
            # A gateway broadcast or a cron failure notice: Moe's plumbing
            # describing itself, which is never something to put in front of
            # a person. Recorded in ~/.moe/logs/job-failures.log, and the
            # job still reads "needs a look" in Settings › Background.
            _deliver.note_machinery(content)
            # Except the person's own routine failing again: that is theirs
            # to hear, in Moe's words, at a few streaks (routine_health).
            telling = _routine_health.for_machinery(record, content)
            if not telling:
                logger.info("[%s] dropped machinery notice: %s", self.name, content[:120])
                return SendResult(success=True, message_id=_deliver.SCREEN)
            logger.info("[%s] routine failing, told the person: %s", self.name, content[:120])
            content = telling
        else:
            # A blocked run's reply carries Hermes's "pause it with `hermes
            # cron pause`" line from the third failure on; never for a person.
            content = _routine_health.for_reply(record, content)
        # The scheduler passes only the job id; the name and the job's own
        # targets come from the record. The NAME is also what arms the
        # open-loop ledger (deliver.LEDGER_JOB): trailer lines are applied
        # for that one job and stripped-and-logged for every other, so a
        # digest quoting `[[moe-open: …]]` out of somebody's mail cannot
        # write it. A job id that resolves to nothing gives "", which is
        # "do not parse" — the safe side.
        job_id = str(metadata.get("job_id") or "")
        job, already = _job_delivers_to(job_id)
        # `hermes send` is a subprocess per connector; keep it off the
        # gateway's event loop. **`hold` is assembled INSIDE the thread, not
        # in this argument list**, and both halves of that matter:
        #
        #  * `holder()` opens the vault and reads the device identity — real
        #    file I/O. Evaluated as an argument it runs on the event loop, two
        #    lines under the comment saying not to; measured at a 0.4 s stall
        #    of the whole gateway, once per message.
        #  * `_sibling.moeledger()` catches ImportError and nothing else, so a
        #    half-copied plugin directory (a SyntaxError — what a file-by-file
        #    copy leaves mid-flight) raised straight out of `send()`, ABOVE
        #    `deliver()`, where `_hold`'s catch-all could never see it. A
        #    boundary is only a boundary at the right frame.
        #
        # `_holder_if_needed` is a plain function so both are inside the
        # thread and inside `deliver()`'s reach.
        ok, err = await asyncio.to_thread(
            _deliver.deliver, content, source="cron", job=job, job_id=job_id,
            chat_id=chat_id or _deliver.SCREEN, skip=already,
            hold=_holder_if_needed(), occurrence=_occurrence_of(job_id),
            words=_inboxwords.words,
        )
        if ok and job_id:
            # "I ran it" (docs/LOOPS.md §4): queued for the app to tell the
            # edge, so a machine waking after this Mac fired is told `ran`.
            # Only for a job that travels; never a reason to fail a delivery.
            await asyncio.to_thread(_note_ran, job_id)
        if not ok:
            # `retryable=False`, deliberately. Hermes's `_send_with_retry`
            # decides by SUBSTRING-MATCHING the error text against
            # `_RETRYABLE_ERROR_PATTERNS`, and `_hold` formats an exception's
            # own words into that string — so a `ConnectionResetError` out of
            # the ledger would read as retryable and re-enter `deliver()`,
            # which is not idempotent and would re-run `fan_out`. A guard that
            # enumerates names is walked past by a new name; saying it
            # outright is the fix.
            return SendResult(success=False, error=err, retryable=False)
        if err:
            # The screen has it; a connector did not. Say so in the log —
            # a SendResult(success=False) would make Hermes retry the
            # screen and speak the reminder twice.
            logger.warning("[%s] delivered to screen; forwarding failed: %s", self.name, err)
        return SendResult(success=True, message_id=_deliver.SCREEN)

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        return None

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        return {"name": "This Mac", "type": "dm"}


def check_requirements() -> bool:
    # stdlib only, and the Mac is by definition here.
    return True


def validate_config(config) -> bool:
    return True


def is_connected(config) -> bool:
    # Connected means "Moe's home exists": that is where the inbox goes and
    # the app that reads it lives. A Hermes with no Moe beside it has no
    # screen to deliver to and should not offer one.
    return os.path.isdir(_deliver.moe_home())


def _env_enablement() -> Optional[dict]:
    """Seed the home channel so `deliver: moe` and `all` resolve.

    Hermes reads a platform's home channel from `<X>_HOME_CHANNEL` in the
    environment first and this seed second. There is nothing to configure —
    the screen has one chat — so the seed is unconditional and no env var
    is ever needed."""
    if not os.path.isdir(_deliver.moe_home()):
        return None
    return {"home_channel": {"chat_id": _deliver.SCREEN, "name": "This Mac"}}


async def _standalone_send(
    pconfig,
    chat_id: str,
    message: str,
    *,
    thread_id: Optional[str] = None,
    media_files=None,
    force_document: bool = False,
) -> Dict[str, Any]:
    """`deliver: moe` from a cron process that is not the gateway, and
    `hermes send --to moe` with no gateway running at all.

    No `job` is passed, deliberately: this path has no job record to read a
    name from, and `hermes send --to moe` is anyone on this Mac with a
    shell. So the open-loop ledger is never armed here — a trailer line in
    the text is stripped and logged, never applied."""
    ok, err = await asyncio.to_thread(
        _deliver.deliver, message, source="cron", chat_id=chat_id or _deliver.SCREEN,
        hold=_holder_if_needed(), words=_inboxwords.words,
    )
    if not ok:
        return {"error": "moe: %s" % err}
    if err:
        logger.warning("[moe] delivered to screen; forwarding failed: %s", err)
    return {"success": True, "platform": _deliver.PLATFORM, "chat_id": _deliver.SCREEN,
            "message_id": _deliver.SCREEN}


def _holder_if_needed():
    """A `hold` for `deliver()`, or None — assembled where it is safe to.

    A Mac reaches its own screen on every delivery, so `reached` is never
    empty there and a hold would never be consulted; not building one keeps
    the ledger closed on the runtime that does not need it.

    **Every failure is None, never an exception.** `_sibling.moeledger()`
    catches `ImportError` and nothing else, and a plugin directory caught
    mid-copy raises `SyntaxError`; `holder()` itself opens a vault. Both are
    below this line so that a ledger which cannot be opened costs a held
    message and never the send.
    """
    if _deliver.has_screen():
        return None
    try:
        return _hold.holder()
    except Exception:  # noqa: BLE001 — see the docstring
        logger.warning("[moe] could not prepare to hold a message; a delivery that "
                       "reaches nobody will be reported as failed", exc_info=True)
        return None


def _session_platform() -> str:
    try:
        from gateway.session_context import get_session_env
        return (get_session_env("HERMES_SESSION_PLATFORM") or "").strip().lower()
    except Exception:
        return ""


def owner_routed(tokens, no_send_path, words=None, origin_app=None):
    """A job's `deliver` tokens, with every target that means "the owner"
    pointed at the one path that can only reach them.

    * ``origin`` from a session with no send path (the island) is ``moe``;
    * ``origin`` from a chat-app session (`origin_app`, e.g. ``telegram``) is
      ``moe:<app>``: the owner, on the app they asked from. Kept as
      ``origin`` it named the platform itself, and on a Mac whose Telegram
      the edge relay fronts there is no native adapter to send on: two
      reminders made from Telegram on 2026-10-06 ran on the Mac and failed
      "platform 'telegram' not configured/enabled", reaching the person only
      because the cloud computer won the same occurrence;
    * a BARE chat-app name Memoe's cloud carries — ``telegram``, ``whatsapp``,
      ``slack``, ``discord``, ``line`` — is ``moe``: the owner, routed where
      they are when it fires (`deliver.reach_owner`'s rule). Left bare, Hermes
      resolves it to whatever that platform's home channel happens to be, and
      on 2026-09-24 a `deliver: whatsapp` job reached the owner's grandfather
      (ticket #15). It becomes ``moe:<app>`` — that app even while they are at
      the Mac — only when `words`, the person's own words in the turn that
      made the job, named it; the model choosing it is not enough;
    * anything that names a chat (``telegram:-100123``), ``all``, ``local``,
      and the apps the cloud does not carry (email, sms, signal) are left
      alone.

    Returns a new list; equal to `tokens` when nothing changed."""
    apps = [t.lower() for t in tokens if t.lower() in _deliver.CHAT_APPS]
    out = []
    for t in tokens:
        low = t.lower()
        if low == "origin" and no_send_path:
            name = _deliver.PLATFORM
        elif low == "origin" and origin_app in _deliver.CHAT_APPS:
            name = "%s:%s" % (_deliver.PLATFORM, origin_app)
        elif low in _deliver.CHAT_APPS:
            name = ("%s:%s" % (_deliver.PLATFORM, low) if _deliver.names_app(words or "", low)
                    else _deliver.PLATFORM)
        else:
            name = t
        if name not in out:
            out.append(name)
    if apps and _deliver.PLATFORM in out and any(o.startswith(_deliver.PLATFORM + ":")
                                                 for o in out):
        out.remove(_deliver.PLATFORM)     # `moe:<app>` writes the island as well
    return out


def rewrite_cron_deliver(tool_name=None, args=None, **kwargs):
    """pre_tool_call: point a Moe-made job somewhere that can be reached.

    Only the `cronjob` tool, only `create` (an `update` with no `deliver`
    means "leave it", and must), and only when the target is the origin —
    given or implied — of a session whose platform has no send path, or a
    bare `local` from such a session (see below). A bare chat-app name
    (`telegram`, `moe,whatsapp`) becomes `moe` — the owner, where they are —
    or `moe:<app>` when the person's own words named that app
    (`owner_routed` says why). Anything else
    the model chose is left alone: `all`, `telegram:<chat>` and `local` from a
    chat platform work as written. `origin,all` becomes `moe,all`; the `all`
    half already expands to the screen and every connected home channel, so
    the user is not told twice.

    The second thing it does, on `create` only: a job the person asked for in
    a conversation runs on the conversation's model. Hermes's `cron.model` is
    the fleet's cheap default, and Moe sets it to the provider's cheapest
    model so its own nudges never cost the plan (docs/DEFAULTS.md row 43).
    A job like "sign in to my X and follow two dozen accounts" is not a
    nudge; it acts in the person's name, and on 2026-09-18 it ran on haiku
    (ticket #5). `model: conversation` is the fork's word for "whatever the
    conversation runs on, read at fire time, provider included", so a later
    brain change carries the job along and nothing is pinned by name. A
    `model` the model itself chose is left alone.

    Returns the shape agent/tool_executor merges into the call, or None."""
    if tool_name not in _CRON_TOOL_NAMES or not isinstance(args, dict):
        return None
    action = str(args.get("action") or "").strip().lower()
    changes = {}
    if action == "create":
        model = args.get("model")
        if model is None or (isinstance(model, str) and not model.strip()):
            changes["model"] = CONVERSATION_MODEL
    raw = args.get("deliver")
    if raw is None or (isinstance(raw, str) and not raw.strip()):
        tokens = ["origin"] if action == "create" else []
    elif isinstance(raw, str):
        tokens = [t.strip() for t in raw.split(",") if t.strip()]
    elif isinstance(raw, (list, tuple)):
        tokens = [str(t).strip() for t in raw if str(t).strip()]
    else:
        tokens = []
    # `local` alone, asked for on the island, reaches nobody: it is a file
    # under ~/.hermes/cron/output that nothing in Moe opens. The owner's "X
    # daily growth" job was made that way on 2026-09-18 and ran nine times
    # before anyone could have known. A person who asked Moe for a routine
    # wants to hear from it, so on `create` it goes to the screen, which
    # keeps the file as well. `local` beside another target is left alone.
    if (action == "create" and [t.lower() for t in tokens] == ["local"]
            and _session_platform() in _NO_SEND_PATH):
        changes["deliver"] = _deliver.PLATFORM
        logger.info("cronjob create: deliver 'local' -> %r (a routine asked for on the "
                    "island reaches the person)", changes["deliver"])
    else:
        platform = _session_platform()
        out = owner_routed(tokens, platform in _NO_SEND_PATH,
                           words=_deliver._turn_words(), origin_app=platform)
        if out != tokens:
            changes["deliver"] = ",".join(out)
            logger.info("cronjob %s: deliver %r -> %r (the owner, routed where he is)",
                        action or "?", raw, changes["deliver"])
    if not changes:
        return None
    return {"action": "modify", "args": changes}


def register(ctx) -> None:
    ctx.register_platform(
        name=_deliver.PLATFORM,
        label="Moe on this Mac",
        adapter_factory=lambda cfg: MoeScreenAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=[],
        install_hint="",
        env_enablement_fn=_env_enablement,
        # What makes `deliver: moe` a valid cron target and puts the screen
        # in `all`. The variable is never set; the seed above is the home.
        cron_deliver_env_var="MOE_HOME_CHANNEL",
        standalone_sender_fn=_standalone_send,
        max_message_length=_deliver.MAX_CHARS,
        emoji="🖥️",
        # No one is identified by this platform: nothing arrives on it.
        pii_safe=True,
        # There is no chat on this platform to type /update into.
        allow_update_command=False,
        platform_hint="",
    )
    ctx.register_hook("pre_tool_call", rewrite_cron_deliver)
    # Every job is on both sides (D2): the list says what the other side
    # last saw a job say, and that a Mac-only one runs on the Mac.
    ctx.register_hook("transform_tool_result", _cronlist.annotate)
    # Both sides claim each run (D4): before a job of the person's fires
    # here, ask the edge through the app whether another device has it. A
    # Hermes without the seam simply never calls it, so it is registered
    # only where it is declared — no unknown-hook warning on an older pin.
    try:
        from hermes_cli.plugins import VALID_HOOKS as _valid
    except Exception:  # noqa: BLE001
        _valid = ()
    if "pre_cron_run" in _valid:
        ctx.register_hook("pre_cron_run", _claim.before_run)
    # The other half of `deliver: moe`: what happens when the person
    # answers. Both live in this plugin because both are the same seam —
    # one writes down what was said, the other hands it back — and because
    # `moe` is the only platform that knows a message was Moe's own idea.
    #
    # `pre_gateway_dispatch` fires once per inbound message on every chat
    # platform, before auth and before the agent, and it is the ONLY seam
    # Hermes offers that can put something in front of a turn that started
    # somewhere Moe cannot see. The api_server (the Mac) never enters this
    # path — it is HTTP request/response, not a gateway event — so the
    # island's half is `Conductor.playNudge`, reading the same spool out of
    # the inbox file. Two surfaces, one record.
    ctx.register_hook("pre_gateway_dispatch", _followups.attach_context)
    # An ask the person's Mac left open, sent here by the edge once the Mac
    # had been gone longer than the grace (docs/AWAY-HANDOFF.md slice 3):
    # the marker becomes their own words. The done report is moe-ledger's
    # (`sync_turn`), the one turn-end seam the claude-code runtime fires.
    from . import tasks as _tasks
    ctx.register_hook("pre_gateway_dispatch", _tasks.on_inbound)
    # The clock (ticket #9): the Now line at the head of every chat turn, in
    # the person's zone, on this Mac's gateway and on the away machine alike.
    # Registered after the two above and prepended, so it is the first line
    # the model reads whatever they attached. See nowline.py.
    from . import nowline as _nowline
    ctx.register_hook("pre_gateway_dispatch", _nowline.attach)
    # A handed-off job that finished while the person was doing something
    # else. The api_server cannot be pushed to, so without this the result
    # waits on the transcript for their next turn; with it, the island gets
    # a turn and Moe says the outcome. See completions.py.
    from . import completions as _completions
    ctx.register_hook("deliver_detached_completion", _completions.deliver_detached_completion)
    # And the tool that changes the state, so "stop reminding me about
    # that" has somewhere to land. Its own toolset name, listed in
    # configure-hermes.py's MOE_TOOLSETS and MOE_CHAT_TOOLSETS: a toolset
    # not named in an explicit `platform_toolsets` list is dropped, and
    # this one has to be present on the phone as well as on the Mac —
    # the phone is where the nudge that needs stopping arrived.
    ctx.register_tool(
        name=_followups.TOOL_SCHEMA["name"],
        toolset=FOLLOWUPS_TOOLSET,
        schema=_followups.TOOL_SCHEMA,
        handler=_followups.handle_tool,
        check_fn=_followups.available,
        description=_followups.TOOL_SCHEMA["description"],
        emoji="🔔",
    )
    # The brain opens the pane that fixes a failed tool, while the person is
    # at the Mac (docs/FIXABLE-FAILURES.md slice 4). Its own toolset, on the
    # Mac's list only: open_settings.py says why and what it refuses.
    from . import open_settings as _open_settings
    ctx.register_tool(
        name=_open_settings.TOOL_NAME,
        toolset=_open_settings.TOOLSET,
        schema=_open_settings.TOOL_SCHEMA,
        handler=_open_settings.handle_tool,
        check_fn=_open_settings.available,
        description=_open_settings.TOOL_SCHEMA["description"],
        emoji="⚙️",
    )
    # Memoe's own settings: find, change, open (docs/SETTINGS-ASSISTANT.md).
    # The same toolset as moe_open_settings, on the Mac's list only:
    # settings.py says what each refuses, and the app checks again.
    # One call each, by name, so the send gate's test reads all three.
    from . import settings as _settings
    ctx.register_tool(name=_settings.FIND_TOOL, toolset=_settings.TOOLSET,
                      schema=_settings.FIND_SCHEMA, handler=_settings.handle_find,
                      check_fn=_settings.available,
                      description=_settings.FIND_SCHEMA["description"], emoji="🔎")
    ctx.register_tool(name=_settings.CHANGE_TOOL, toolset=_settings.TOOLSET,
                      schema=_settings.CHANGE_SCHEMA, handler=_settings.handle_change,
                      check_fn=_settings.available,
                      description=_settings.CHANGE_SCHEMA["description"], emoji="🎚️")
    ctx.register_tool(name=_settings.SHOW_TOOL, toolset=_settings.TOOLSET,
                      schema=_settings.SHOW_SCHEMA, handler=_settings.handle_show,
                      check_fn=_settings.available,
                      description=_settings.SHOW_SCHEMA["description"], emoji="⚙️")
    # Where this Mac is, from macOS Location Services, when a question needs
    # a place (the weather, "near me"). Its own toolset, on the Mac's list
    # only: location.py says how the answer travels and what it refuses.
    from . import location as _location
    ctx.register_tool(
        name=_location.TOOL_NAME,
        toolset=_location.TOOLSET,
        schema=_location.TOOL_SCHEMA,
        handler=_location.handle_tool,
        check_fn=_location.available,
        description=_location.TOOL_SCHEMA["description"],
        emoji="📍",
    )
    # The one way the brain reaches the OWNER, and nobody else: words and at
    # most a chat app's name, never an address; the island while he is at the
    # Mac, his own chat through Memoe's cloud when he is not. In the
    # `connectors` toolset, which Hermes never defers, so it is in front of
    # the model on every turn. reach.py says why; deliver.reach_owner routes.
    from . import reach as _reach
    ctx.register_tool(
        name=_reach.TOOL_NAME,
        toolset=_reach.TOOLSET,
        schema=_reach.TOOL_SCHEMA,
        handler=_reach.handle_tool,
        check_fn=_reach.available,
        description=_reach.TOOL_SCHEMA["description"],
        emoji="📣",
    )
    # Slice E1: the edge's `ledger_moved` frame arrives on THIS process's
    # relay socket, and the app that pulls is another process. moe-ledger
    # would install the handler, but on a Mac its register() never runs (it
    # is not the memory provider here), so this plugin — loaded by every Mac
    # gateway at start — does. `pushes.py` says why, and stands aside on
    # the machine.
    _pushes.listen()
