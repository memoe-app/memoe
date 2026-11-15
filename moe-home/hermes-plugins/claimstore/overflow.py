"""Memory saves never fail (docs/DEFAULTS.md row 39).

Hermes's memory tool refuses an ``add`` or ``replace`` that would push
``MEMORY.md`` / ``USER.md`` past ``memory_char_limit`` / ``user_char_limit``
(``tools/memory_tool.py`` at the checkout, ``tools/memory_tool_store.py`` at
the pin: "… would exceed the limit. Consolidate now …"). Under claimstore that
refusal is wrong twice over: the files are not the store — the ledger is, and
it has no cap — and the projection already knows how to fit the ledger into
the files (``projection.render``: newest kept, oldest out of the digest and
still reachable by recall). But a refused write never reaches the ledger,
because ``on_memory_write`` fires only on success. So the person heard "I
couldn't save that".

The seam, without touching the fork: Hermes's ``tool_execution`` middleware
(``hermes_cli/middleware.py``), which wraps the ``memory`` tool on both the
sequential and the concurrent agent paths (``agent/tool_executor.py``,
``agent/agent_runtime_helpers.invoke_tool``) — the Claude Code brain's bridged
``memory`` calls land in that same ``invoke_tool`` — and is handed the result
before the model sees it. A plugin registers it from ``register(ctx)``; a
memory provider's collector forwards every ``register_*`` to a real
``PluginContext``.

What it does, and only this:

1. run the tool (``next_call``), untouched;
2. if the tool refused for want of room — its own words, **and** the file it
   reads really would overflow with this write (so a refusal for any other
   reason — no match, an approval denied, a batch — is never turned into a
   save) — and the content passes the tool's own injection scan;
3. take the write into the ledger the way a successful write would have been
   (``ClaimStoreProvider.on_memory_write``), re-project the file under the
   cap, and confirm the claim is live;
4. answer the model with the tool's own success shape, so it never sees
   "exceeds the char limit" and never loops consolidating.

Anything it cannot do cleanly returns Hermes's original result: this can make
a refusal into a save, never a save into a refusal.

Four rules the review of 2026-09-15 added, each with its test:

* **Only the session's own provider.** The call's ``session_id`` must be the
  session a writing provider was initialized for. There is no "the only live
  provider" fallback: a cron job keeps the memory tool, and its refusal must
  not be written into the person's memory by the chat's provider — a refusal
  must never become a save a success would not have made.
* **A refusal leaves the ledger exactly as it was.** Everything that could
  make the save fail (a restated deleted fact, which becomes a question; a
  replace whose ``old_text`` addresses no single digest entry) is checked
  *before* anything is written, so a replace is never told "refused" after
  its old fact was already retracted.
* **A kept claim is a save.** If re-projecting the file fails after the claim
  is live, the answer is still success — the next projection fits the file.
* **The wording is checked by arithmetic too.** A refusal that is "no room" by
  the numbers but not in the words is logged once at WARNING, so a Hermes
  wording change cannot switch this off silently.
"""

from __future__ import annotations

import json
import logging
import weakref
from typing import Any, Dict, Optional

from .projection import _delimiter, addressed_claims, char_limit, memory_path, parse_entries
from .store import RETRACT, claim_id, parse_claim

logger = logging.getLogger(__name__)

#: Hermes's middleware kind for wrapping a tool's execution.
MIDDLEWARE_KIND = "tool_execution"

#: The tool's words for "no room", identical at the pin and the checkout.
#: The last is what the same refusal becomes after three in one turn.
ROOM_ERRORS = (
    "would exceed the limit",
    "Replacement would put memory at",
    # Hermes 0.21.7+: `replace` left the tool for `patch` (tools/memory_tool_store.py, _patch).
    "Patch would put memory at",
    "Memory consolidation failed",
)

#: The ``note`` the memory tool puts on every successful write
#: (``MemoryStore._success_response``: tools/memory_tool.py at the checkout,
#: tools/memory_tool_store.py at the pin). The success shape below is the
#: tool's own, field for field; ``test_the_success_is_the_tools_own_shape``
#: compares it with a real one.
SUCCESS_NOTE = "Write saved. This update is complete — do not repeat it."

# Providers that may write the ledger right now (initialized in a writing
# context), weakly held: a provider that is gone is never answered for.
_bound: "weakref.WeakSet" = weakref.WeakSet()
# Registries whose middleware chain cannot be read, and that this module has
# already registered with. A readable chain is asked directly instead.
_registered_on: "weakref.WeakSet" = weakref.WeakSet()
# The wording warning is logged once per process.
_warned_wording = False


def bind(provider) -> None:
    _bound.add(provider)


def unbind(provider) -> None:
    _bound.discard(provider)


def provider_for(session_id: str = ""):
    """The writing provider initialized for exactly this session, or None.

    Never "the only live one": a cron job, a subagent or any other session
    with the memory tool is not the chat whose provider happens to be bound.
    """
    if not session_id:
        return None
    for p in list(_bound):
        if (getattr(p, "_store", None) is not None and getattr(p, "_writes_enabled", False)
                and getattr(p, "_session_id", "") == session_id):
            return p
    return None


def _middleware_map(ctx) -> Optional[Dict[str, Any]]:
    """The plugin manager's middleware dict this ``ctx`` registers into: a
    ``PluginContext``'s ``_manager``, or the one a memory provider's collector
    forwards to (``_plugin_context()``). None when neither is readable."""
    reaches = (lambda: ctx._manager, lambda: ctx._plugin_context()._manager)
    for reach in reaches:
        try:
            middleware = getattr(reach(), "_middleware", None)
        except Exception:  # noqa: BLE001 — a shape this Hermes does not have
            continue
        if isinstance(middleware, dict):
            return middleware
    return None


def register(ctx) -> bool:
    """Register the middleware with this registry unless it is already in its
    chain. Idempotent per registry, not per process: a rebuilt plugin manager
    gets it again. True when it registered."""
    hook = getattr(ctx, "register_middleware", None)
    if not callable(hook):
        logger.info("claimstore: this Hermes has no tool middleware; a memory save past the cap "
                    "is still refused by the tool")
        return False
    chain = _middleware_map(ctx)
    if chain is not None:
        if any(getattr(cb, "_moe_claimstore", False) for cb in chain.get(MIDDLEWARE_KIND) or ()):
            return False
    else:
        try:
            if ctx in _registered_on:
                return False
        except TypeError:
            pass
    try:
        hook(MIDDLEWARE_KIND, memory_never_full)
    except Exception as e:  # noqa: BLE001 — never out of register()
        logger.info("claimstore: could not register the memory middleware: %s", e)
        return False
    if chain is None:
        try:
            _registered_on.add(ctx)
        except TypeError:
            pass
    return True


def memory_never_full(tool_name: str = "", args: Any = None, next_call=None,
                      session_id: str = "", **_: Any) -> Any:
    """Hermes ``tool_execution`` middleware. See the module docstring."""
    result = next_call(args)
    if tool_name != "memory":
        return result
    try:
        taken = take_overflow(args, result, session_id=session_id)
    except Exception:  # noqa: BLE001 — Hermes's answer stands
        logger.warning("claimstore: a memory save past the cap could not be taken into the ledger",
                       exc_info=True)
        return result
    return result if taken is None else taken


def _failure(result: Any) -> Optional[Dict[str, Any]]:
    """The tool's result as a dict when it is a refusal (``success`` False)."""
    if isinstance(result, dict):
        data = result
    elif isinstance(result, str):
        try:
            data = json.loads(result)
        except ValueError:
            return None
    else:
        return None
    if not isinstance(data, dict) or data.get("success") is not False:
        return None
    return data


def _says_no_room(failure: Dict[str, Any]) -> bool:
    error = str(failure.get("error") or "")
    return any(marker in error for marker in ROOM_ERRORS)


def _room_failure(result: Any) -> Optional[Dict[str, Any]]:
    data = _failure(result)
    return data if data is not None and _says_no_room(data) else None


def _warn_wording_once(action: str, target: str, limit: int, total: int) -> None:
    global _warned_wording
    if _warned_wording:
        return
    _warned_wording = True
    # The error is not logged: it can quote memory text (an old_text).
    logger.warning(
        "claimstore: Hermes refused a memory %s that would not fit the %s file (%d/%d chars by "
        "arithmetic), but its error matched none of the known 'no room' wordings (%s). If Hermes "
        "changed that wording, saves past the cap are being refused again — update "
        "overflow.ROOM_ERRORS.", action, target, total, limit, " | ".join(ROOM_ERRORS))


def _scan_refuses(content: str) -> bool:
    """The tool's own injection/exfiltration scan. Unavailable is a refusal:
    this path must never be a way around it."""
    try:
        from tools.memory_tool import _scan_memory_content
    except Exception:  # noqa: BLE001
        return True
    try:
        return bool(_scan_memory_content(content))
    except Exception:  # noqa: BLE001
        return True


def _write_origin() -> str:
    try:
        from tools.skill_provenance import get_current_write_origin

        return str(get_current_write_origin() or "assistant_tool")
    except Exception:  # noqa: BLE001
        return "assistant_tool"


def _would_be_live(store, target: str, cid: str) -> bool:
    """Whether asserting ``cid`` from the memory tool would leave it live.

    Already live: yes. Retracted at any point: no — a ``hermes:`` source
    never revives a retraction, so the assert would become a question
    (``PendingRevival``) or be suppressed, and either way it is not a save.
    Asked before writing, so that answer never costs a write."""
    if store.is_live(target, cid):
        return True
    keys = store.opening_keys
    for record in store.claim_records(target):
        claim = parse_claim(record, keys)
        if claim and claim.get("claim") == cid and claim.get("op") == RETRACT:
            return False
    return True


def take_overflow(args: Any, result: Any, *, session_id: str = "", provider=None) -> Any:
    """The success result for a write the tool refused for room, or None."""
    if not isinstance(args, dict) or args.get("operations"):
        return None
    action = args.get("action")
    if action not in ("add", "replace", "patch"):
        return None
    failure = _failure(result)
    if failure is None:
        return None
    target = args.get("target") or "memory"
    content = args.get("content")
    if content is None:
        content = args.get("new_text")
    content = str(content or "").strip()
    # A patch's span keeps its whitespace, as the tool's own does ("tea " -> "coffee ").
    raw_old = str(args.get("old_text") or "")
    old_text = raw_old if action == "patch" else raw_old.strip()
    if not content or (action != "add" and not old_text.strip()):
        return None
    if _scan_refuses(content):
        return None

    # Really about room? Measured on the file the tool itself measured, with
    # the tool's own limit — independently of the error's words.
    path = memory_path(target)
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raw = ""
    entries = parse_entries(raw)
    limit = char_limit(target)
    delimiter = _delimiter()
    if action == "add":
        if content in entries:
            return None
        after = entries + [content]
    else:
        matches = [i for i, e in enumerate(entries) if old_text in e]
        if not matches or len({entries[i] for i in matches}) > 1:
            return None
        if action == "patch":
            # Since Hermes 0.21.7 the model edits a span, not the entry: the saved entry is the
            # matched one with that one span spliced, exactly as the tool would have written it
            # (tools/memory_tool_store.py, _patch_entry), and to the ledger that is a replace of
            # the whole entry — the same mirror MemoryManager.notify_memory_tool_write makes.
            entry = entries[matches[0]]
            if entry.count(old_text) != 1:
                return None
            span = args.get("content") if args.get("content") is not None else args.get("new_text")
            content = entry.replace(old_text, str(span or ""), 1).strip()
            if not content or content == entry or _scan_refuses(content):
                return None
        after = list(entries)
        after[matches[0]] = content
    total = len(delimiter.join(after))
    if total <= limit:
        return None
    if not _says_no_room(failure):
        _warn_wording_once(action, target, limit, total)
        return None

    provider = provider or provider_for(session_id)
    if provider is None:
        return None
    if target not in getattr(provider, "_targets", ()):
        return None
    store = provider._store
    cid = claim_id(target, content)

    # Everything that could make this not a save is decided before the first
    # write, so a refusal leaves the ledger exactly as it found it.
    if not _would_be_live(store, target, cid):
        # A deleted fact the assistant restated becomes a question, not a
        # claim (on_memory_write) — not a save to report as one.
        return None
    if action != "add" and len(addressed_claims(store, target, old_text)) != 1:
        # on_memory_write would retract nothing and leave the old fact live
        # beside the new one: not what the tool was asked to do.
        return None

    provider.on_memory_write("add" if action == "add" else "replace", target, content,
                             {"write_origin": _write_origin(), "old_text": old_text})
    if not store.is_live(target, cid):
        logger.warning("claimstore: a %s past the %s cap did not become a live claim; Hermes's "
                       "refusal stands", action, target)
        return None

    projected = True
    try:
        provider._project("memory-full")
    except Exception:  # noqa: BLE001 — the claim is kept; the file catches up
        projected = False
        logger.warning("claimstore: a %s past the %s cap is kept in the ledger, but the file could "
                       "not be re-fitted; the next projection will", action, target, exc_info=True)

    try:
        now = parse_entries(path.read_text(encoding="utf-8"))
    except OSError:
        now = []
    current = len(delimiter.join(now))
    pct = min(100, int(current * 100 / limit)) if limit > 0 else 0
    done = {"add": "Entry added.", "patch": "Entry patched."}.get(action, "Entry replaced.")
    if content in now:
        message = (f"{done} Memory was full, so the oldest entries were moved out of this file to "
                   "make room — they are all still kept and recalled when relevant. Nothing to "
                   "consolidate; this save is done.")
    elif not projected:
        message = (f"{done} It is kept and recalled when relevant; the memory file catches up on "
                   "its next update. Nothing to consolidate; this save is done.")
    else:
        message = (f"{done} It is longer than the memory file holds, so it is kept outside the file "
                   "and recalled when relevant. This save is done.")
    logger.info("claimstore: a %s past the %s cap was saved to the ledger%s (%d/%d chars)", action,
                target, " and the file re-fitted" if projected else "", current, limit)
    # MemoryStore._success_response, field for field.
    response = {
        "success": True,
        "done": True,
        "target": target,
        "usage": f"{pct}% — {current:,}/{limit:,} chars",
        "entry_count": len(now),
        "message": message,
        "note": SUCCESS_NOTE,
    }
    return response if isinstance(result, dict) else json.dumps(response, ensure_ascii=False)


memory_never_full._moe_claimstore = True  # type: ignore[attr-defined]
