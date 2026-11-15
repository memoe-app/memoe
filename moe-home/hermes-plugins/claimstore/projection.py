"""Projection of the claim half of Moe's ledger onto Hermes's memory files.

``MEMORY.md`` and ``USER.md`` stop being a store and become a *digest*: the
subset of the ledger's live claims that fits in the prompt, rendered in
exactly the shape the built-in memory tool writes itself.

Why the shape matters
---------------------
``tools/memory_tool.py:_detect_external_drift`` refuses ``replace`` and
``remove`` when the file on disk would not round-trip through the tool's own
parser, or when any single entry exceeds the store's whole-file character
limit. It is worth being precise about what that guard actually tests, because
it is easy to read it as "someone else wrote this file" when it is not
(``docs/ONE-AGENT.md`` §1.3, corrected 2026-08-31):

* it is a check on the file's **shape**, not on its **provenance**;
* it never runs on ``add`` (``_reload_target(skip_drift=True)``);
* the round-trip comparison is against ``raw.strip()``, so a trailing newline
  is fine, and free-form prose with no delimiter at all parses as one entry and
  passes as long as it is under the limit.

So an external writer is only rejected when it writes something the tool could
not have written. :func:`is_tool_shaped` is the exact inverse of that guard,
and :func:`project` refuses to write bytes that fail it. The projector is
therefore indistinguishable from the tool, by construction and by assertion —
not by hoping. ``memory_tool.py`` is not patched and does not need to be.

Reconciliation, and the one rule that is not obvious
----------------------------------------------------
Every projection *absorbs* first: text present in the file that the ledger has
never seen becomes a new claim. That makes the other writers first-class rather
than adversaries — the person editing ``MEMORY.md`` in an editor, or a
different tool appending to it, is a source of claims, not a desync to be
clobbered. Absorption happens under the same lock file the memory tool takes,
so it cannot interleave with a tool write.

**"Never seen" is by claim id, not by what is currently live**, and the
difference is load-bearing the moment a second device exists. A claim retracted
on the phone on Tuesday is still sitting in this machine's ``MEMORY.md`` until
the next projection rewrites it. Absorbing on "not live" would re-assert it and
undo the deletion on every single pass — which is precisely what §3.1's causal
tombstone amendment exists to prevent. Absorbing on "never seen" leaves the
deletion alone and still catches every genuinely new line a person types.

What that costs is written down rather than hidden: a person who deletes a fact
and later types *the same words* back into ``MEMORY.md`` by hand is not heard,
because the file carries no metadata that could tell "the person put it back"
apart from "this file is stale". Saying it to Moe works — a memory-tool write
carries a source, and §3.1 lets a person's assert revive. See §14.3.
"""

from __future__ import annotations

import logging
import json
import os
import re
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Dict, Iterable, List, Optional

logger = logging.getLogger(__name__)

TARGETS = ("memory", "user")

# What an absorbed entry's provenance is: the memory file itself. Deliberately
# not a reviving source (store.revives) — absorption never resurrects, see the
# module docstring.
ABSORB_SOURCE = "file"

#: What this projector last wrote into each memory file, as claim ids. In the
#: projector's own state directory (``$HERMES_HOME`` on a Mac, the vault on a
#: machine) rather than in the ledger, because it is a fact about this
#: projector and not about the store.
#:
#: It exists to answer one question absorption cannot otherwise ask: an entry
#: in the file whose claim is retracted is either *a person putting it back* or
#: *a file this projector wrote before the retraction arrived from somewhere
#: else*, and the bytes are identical. If we wrote it, it is stale and there is
#: nothing to ask anyone. If we did not, somebody typed it.
#:
#: Losing this file is harmless: an unknown answer means "ask", which is the
#: safe direction — a spurious question rather than a silent restore or a
#: silent drop.
DIGEST_MARKER = "claimstore-digest.json"

# Fallback limits, used only if the host's config lookup fails. The real values
# come from tools.memory_tool so this file never drifts from upstream.
_FALLBACK_LIMITS = {"memory": 2200, "user": 1375}


def _delimiter() -> str:
    from tools.memory_tool import ENTRY_DELIMITER

    return ENTRY_DELIMITER


def memory_path(target: str) -> Path:
    """Absolute path of the built-in file backing ``target``."""
    from tools.memory_tool import get_memory_dir

    return get_memory_dir() / ("USER.md" if target == "user" else "MEMORY.md")


def char_limit(target: str) -> int:
    """The built-in store's whole-file character budget for ``target``.

    Read from the host's memory config so a user who raised
    ``memory.memory_char_limit`` gets a projection that uses the extra room —
    and, more importantly, so the projector's idea of the budget can never
    disagree with the drift guard's.
    """
    try:
        from tools.memory_tool import get_builtin_memory_config

        section = get_builtin_memory_config() or {}
        key = "user_char_limit" if target == "user" else "memory_char_limit"
        return int(section.get(key, _FALLBACK_LIMITS[target]))
    except Exception:
        return _FALLBACK_LIMITS[target]


@contextmanager
def file_lock(path: Path):
    """Take the same advisory lock the built-in memory tool takes.

    Reuses ``MemoryStore._file_lock`` rather than reimplementing it: a second
    lock discipline over the same file would be no lock at all. Degrades to a
    no-op if a future Hermes renames it, which is no worse than the
    unsynchronised external writer this plugin replaces.
    """
    try:
        from tools.memory_tool import MemoryStore

        locker = getattr(MemoryStore, "_file_lock", None)
    except Exception:
        locker = None
    if locker is None:
        yield
        return
    with locker(path):
        yield


def parse_entries(raw: str) -> List[str]:
    """Split a memory file into entries using the tool's own rule."""
    return [e.strip() for e in (raw or "").split(_delimiter()) if e.strip()]


def is_tool_shaped(raw: str, limit: int) -> bool:
    """True when ``raw`` would pass ``_detect_external_drift`` for ``limit``.

    Kept as the literal inverse of that function's two signals so the two can
    be diffed against each other by eye.
    """
    if not (raw or "").strip():
        return True
    parsed = parse_entries(raw)
    if raw.strip() != _delimiter().join(parsed):
        return False
    return max((len(e) for e in parsed), default=0) <= limit


def pinned_texts(live: Iterable[object]) -> set:
    """The live claims a digest keeps first, whatever their age: the
    account's ``Name:`` line and anything the person stated or edited
    themselves (a reviving source, ``store.revives``). Those are who the
    person is, and were the first to go under oldest-first — the owner's
    USER.md held 19 of 36 facts on 2026-10-15 and no ``Name:`` at all."""
    from .store import revives

    out = set()
    for claim in live:
        text = (getattr(claim, "text", "") or "").strip()
        source = getattr(claim, "source", "") or ""
        if text and (source == ACCOUNT_SOURCE or revives(source) or text.startswith(NAME_PREFIX)):
            out.add(text)
    return out


def render(entries: Iterable[str], limit: int, pinned: Iterable[str] = ()) -> str:
    """Render claims as a drift-free memory file within ``limit`` characters.

    Order is preserved (first-asserted first) so the projection is stable
    across runs and does not needlessly invalidate a cached prompt prefix.

    When the claims overflow the budget, what stays is chosen, not cut by
    age: ``pinned`` entries first (:func:`pinned_texts`), then the rest
    newest first — and an entry that does not fit is passed over rather than
    ending the pass, so one long recent note no longer pushes out every
    shorter, older fact behind it. Deterministic in its inputs, so the same
    ledger renders the same bytes (a changed digest respawns Hermes's child).
    """
    delimiter = _delimiter()
    cleaned: List[str] = []
    seen = set()
    for entry in entries:
        entry = (entry or "").strip()
        if not entry or entry in seen:
            continue
        if len(entry) > limit:
            # Could never have been written by the tool, so writing it would
            # trip the drift guard on the next replace/remove. Drop it from the
            # digest; it stays in the ledger, which is the actual store.
            logger.debug("claimstore: claim of %d chars exceeds the %d-char digest budget",
                         len(entry), limit)
            continue
        seen.add(entry)
        cleaned.append(entry)

    pins = {(p or "").strip() for p in pinned}
    chosen = set()
    total = 0
    # The name first; then the person's own facts, newest first (when even
    # those overflow, a newer statement is the likelier correction); then
    # everything else, newest first.
    names = [e for e in cleaned if e in pins and e.startswith(NAME_PREFIX)]
    order = names + [e for e in reversed(cleaned) if e in pins and e not in names] \
        + [e for e in reversed(cleaned) if e not in pins]
    for entry in order:
        extra = len(entry) + (len(delimiter) if chosen else 0)
        if total + extra > limit:
            continue
        chosen.add(entry)
        total += extra
    return delimiter.join(e for e in cleaned if e in chosen)


def _marker_path(store) -> Path:
    return Path(store.state_dir) / DIGEST_MARKER


def last_digest(store, target: str) -> Optional[set]:
    """Claim ids this projector last wrote into ``target``'s file.

    ``None`` when we have never written it, or cannot tell — which absorption
    reads as "ask", not as "assume stale".
    """
    try:
        data = json.loads(_marker_path(store).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    held = data.get(target) if isinstance(data, dict) else None
    if not isinstance(held, list):
        return None
    return {str(x) for x in held}


def remember_digest(store, target: str, ids: Iterable[str]) -> None:
    """Record what the file now holds. Never raises: a marker we failed to
    write costs a question, not a memory."""
    path = _marker_path(store)
    try:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                data = {}
        except (OSError, ValueError):
            data = {}
        data[target] = sorted(ids)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(str(path), 0o600)
    except OSError:
        logger.debug("claimstore: could not record the %s digest marker", target, exc_info=True)


def absorb(store, target: str, *, source: str = ABSORB_SOURCE) -> List[str]:
    """Turn text in the file that the ledger has not accounted for into claims.

    Returns the claim ids minted. Call under :func:`file_lock`.

    Three outcomes per entry, and the middle one is the whole subtlety:

    * **already live** — nothing to do.
    * **already retracted** — the entry is a deleted fact sitting in the file.
      A record is appended anyway, and because ``file`` is not a person
      (``store.revives``) it does not restore the claim: it becomes a
      ``PendingRevival``, a question Moe can ask. Exactly one record per claim
      per device, because the next call sees the question already standing and
      leaves it alone.
    * **never seen** — an ordinary new claim.

    The second one is where an earlier version was simply wrong in two
    different directions. Absorbing on "not currently live" re-asserted
    anything a second device had retracted, on every single pass, forever —
    undoing the deletion silently. Absorbing on "never seen at all" fixed that
    and swallowed the person who types a deleted fact back into ``MEMORY.md``
    by hand. The file carries no metadata that could tell those two apart, so
    neither restoring nor dropping is honest; asking is (§14.3).
    """
    from .store import claim_id

    path = memory_path(target)
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return []
    except OSError:
        # An unreadable file is not an empty one. Absorbing nothing is right;
        # the caller's write is separately guarded (see project()).
        logger.debug("claimstore: could not read %s for absorption", path, exc_info=True)
        return []

    entries = parse_entries(raw)
    if not entries:
        return []
    # One resolve for the whole file rather than one per entry: this is the
    # first-run path, and it used to be quadratic in the size of the ledger.
    resolved = store.resolve(target)
    settled = {c.id for c in resolved.live} | {q.id for q in resolved.pending_revivals}
    # Entries we put in this file ourselves, before a retraction arrived from
    # somewhere else. Those are a stale file, not a person, and asking about
    # them would turn every ordinary cross-device deletion into a question.
    ours = last_digest(store, target) or set()
    fresh = []
    for entry in entries:
        cid = claim_id(target, entry)
        if cid in settled:
            continue
        if cid in ours:
            logger.debug("claimstore: %s still shows %s, which we wrote and something has "
                         "since retracted; the next write drops it", target, cid)
            continue
        fresh.append(entry)
    return store.assert_many(target, fresh, source=source)


def digest_entries(store, target: str) -> List[str]:
    """What the memory file holds, as this projector would render it.

    Not read from disk: computed from the ledger, which is what the last
    projection wrote and what the next one will write. Reading the file
    instead would make a stale file able to address a claim, which is the
    whole bug below.
    """
    resolved = store.resolve(target)
    return parse_entries(render(resolved.texts, char_limit(target), pinned_texts(resolved.live)))


def addressed_claims(store, target: str, needle: str):
    """The live claims a memory-tool ``old_text`` actually addressed.

    ``tools/memory_tool.py`` matches ``old_text`` as a substring against the
    *file's* entries and refuses the call when more than one matches. This is
    that rule, applied to the claims behind those entries, and it is
    deliberately narrower than "every live claim containing the needle":

    * a claim that is live but **not in the digest** was never in the file, so
      no tool call could have addressed it. The digest is a subset of the live
      set by design — ``prefetch`` exists precisely to surface what did not
      fit — so a substring sweep over the live set routinely reaches claims
      neither the person nor the model can see. Reproduced before this
      existed: two live claims containing "Kaplan", one of them in the digest,
      one ``remove`` and the ledger went from two live claims to zero.
    * more than one match is what the tool itself refuses, so it is refused
      here too rather than resolved by guessing. Returning both and letting
      the caller drop it is what keeps a *stale* file — which can produce an
      ambiguity the tool never saw — from deleting anything.
    """
    needle = (needle or "").strip()
    if not needle:
        return []
    digest = set(digest_entries(store, target))
    return [c for c in store.resolve(target).live if c.text in digest and needle in c.text]


#: A claim that is a label with nothing after it — "Name:", "What I do:".
#: The notes Moe ships on a fresh install are forms, and the day-one
#: distillation (``moe-home/hermes/migrate-memory.py``) used to hand every
#: unfilled line of the form to Hermes as a fact. Measured on the owner's own
#: Mac on 2026-09-20: six of nine ``user`` claims were these, seeded
#: 2026-09-16 and rendered into every system prompt since, so the model read
#: ``Name:`` followed by nothing for a week and answered that the profile was
#: blank. The seeder no longer writes them; this is how the ones already in a
#: ledger — and, through it, on a person's cloud machine — go away.
PLACEHOLDER = re.compile(r"^[^:]{1,80}:\s*$")
PLACEHOLDER_SOURCE = "moe:placeholder"


def is_placeholder(text: str) -> bool:
    """True for claim text that is only a label: ``Name:``, ``What I do:``."""
    return bool(PLACEHOLDER.match((text or "").strip()))


def retract_placeholders(store, targets: Iterable[str], *,
                         source: str = PLACEHOLDER_SOURCE) -> List[str]:
    """Retract every live claim that is an unfilled form label.

    Returns the claim ids retracted. Idempotent: a retracted claim is not
    live, so a second pass finds nothing. The retraction is a record like
    any other, so it reaches every device the claim reached (§3.1), and a
    person later *saying* their name is an ordinary new claim with different
    text — this touches nothing but the bare label.
    """
    retracted: List[str] = []
    for target in targets:
        try:
            live = list(store.resolve(target).live)
        except Exception:
            logger.debug("claimstore: could not resolve %s for placeholders", target, exc_info=True)
            continue
        for claim in live:
            if not is_placeholder(claim.text):
                continue
            cid = store.retract_id(target, claim.id, source=source)
            if cid:
                retracted.append(cid)
    if retracted:
        logger.info("claimstore: retracted %d unfilled form label(s) that had been seeded "
                    "as memory (%s)", len(retracted), ", ".join(retracted))
    return retracted


#: The one fact a Mac knows about its person before a word is said: the
#: account's full name (`id -F`, what macOS shows on the login screen).
#: Measured on the owner's Mac, 2026-09-20: in a week and 579 turns the name
#: was never spoken, nothing seeded it, and "who am I" came back blank.
#: docs/MEMORY.md §4 closed day-one seeding assuming conversation would do
#: it; it did not. Seeded ONCE, as a ``user`` claim under its own source, so
#: it is a record the person can see and correct: a "Name:" line they set
#: themselves wins, and one they removed is never put back.
ACCOUNT_SOURCE = "moe:mac-account"
NAME_PREFIX = "Name:"


def account_full_name() -> str:
    """The Mac account's full name, or "" anywhere that is not a Mac with
    one (a cloud machine, a CI runner, an account with no full name)."""
    if sys.platform != "darwin":
        return ""
    try:
        out = subprocess.run(["id", "-F"], capture_output=True, text=True, timeout=5)
    except Exception:
        return ""
    name = (out.stdout or "").strip() if out.returncode == 0 else ""
    # A name that is only the short account name ("javery") is not
    # a name anyone is called; macOS answers the full name when there is one.
    return name if " " in name or name.istitle() else ""


def seed_account_name(store, full_name: str, *, source: str = ACCOUNT_SOURCE) -> Optional[str]:
    """Assert ``Name: <full_name>`` on ``user`` once. Returns the claim id
    written, or None when nothing was.

    Nothing when there is no name; when any ``Name:`` claim is live (the
    person's, or this one already); or when this exact claim has EVER been
    in the ledger — asserted and since retracted — because a fact the
    person removed is not re-added by a machine. `assert_claim` dedupes a
    live repeat; the history check is what keeps a retracted one out.
    """
    full_name = (full_name or "").strip()
    if not full_name:
        return None
    text = "%s %s" % (NAME_PREFIX, full_name)
    from .store import claim_id, parse_claim
    cid = claim_id("user", text)
    try:
        keys = store.opening_keys
        for record in store.claim_records("user"):
            claim = parse_claim(record, keys)
            if claim and claim.get("claim") == cid:
                return None
        for claim in store.resolve("user").live:
            if (claim.text or "").startswith(NAME_PREFIX) and not is_placeholder(claim.text):
                return None
    except Exception:
        logger.debug("claimstore: could not read the ledger for the account name", exc_info=True)
        return None
    written = store.assert_claim("user", text, source=source)
    if written:
        logger.info("claimstore: seeded the person's name from the Mac account (%s)", written)
    return written


def retract_addressed(store, target: str, needle: str, *, source: str = "") -> List[str]:
    """Retract the one claim a memory-tool ``remove``/``replace`` addressed.

    Returns the claim ids retracted: exactly one, or none. Never more.
    """
    matches = addressed_claims(store, target, needle)
    if len(matches) != 1:
        # The needle is memory text; the log gets its length and the claim
        # ids it reached, never the words.
        if matches:
            logger.warning(
                "claimstore: an old_text of %d chars addresses %d entries in the %s digest "
                "(%s); retracting none (the memory tool refuses an ambiguous old_text and "
                "so does this)", len(needle or ""), len(matches), target,
                ", ".join(c.id for c in matches))
        else:
            logger.info("claimstore: an old_text of %d chars addresses nothing in the %s "
                        "digest; retracting nothing", len(needle or ""), target)
        return []
    cid = store.retract_id(target, matches[0].id, source=source)
    return [cid] if cid else []


def project(store, target: str, *, absorb_source: str = ABSORB_SOURCE) -> Dict[str, object]:
    """Reconcile the file with the ledger and rewrite it as the ledger's digest.

    Returns a small report: ``absorbed`` (ids minted from the file),
    ``entries`` (claims in the rendered digest), ``left_out`` (live claims the
    digest had no room for — still in the ledger, still reachable through
    ``prefetch``), ``disagreements`` (topics two sources read differently —
    §3.1's escalation, surfaced rather than resolved here), ``asked`` (deleted
    facts something has re-stated since), ``written`` (whether the file
    actually changed), and ``skipped`` (a reason string, when it did not).

    Never raises: a memory projection that can take the agent down with it is
    worse than a stale digest. But it is never *quiet* either — every branch
    that declines to write logs at warning, because this is the one file the
    person reads and several of these refusals are terminal for it.
    """
    report: Dict[str, object] = {
        "target": target, "absorbed": [], "placeholders": [], "seeded_name": None,
        "entries": 0, "left_out": 0,
        "disagreements": [], "asked": [], "written": False, "skipped": "",
    }
    from .store import claim_id

    try:
        path = memory_path(target)
        limit = char_limit(target)
        path.parent.mkdir(parents=True, exist_ok=True)
        with file_lock(path):
            store.refresh()
            report["absorbed"] = absorb(store, target, source=absorb_source)
            # After absorbing, so a label the file still carries is taken in
            # and retracted in the same pass rather than living one session.
            report["placeholders"] = retract_placeholders(store, [target])
            if target == "user":
                report["seeded_name"] = seed_account_name(store, account_full_name())
            resolved = store.resolve(target)
            report["disagreements"] = [
                {"key": d["key"], "sources": d["sources"]} for d in resolved.disagreements
            ]
            report["asked"] = [
                {"id": q.id, "source": q.source, "text": q.text}
                for q in resolved.pending_revivals
            ]
            content = render(resolved.texts, limit, pinned_texts(resolved.live))

            # The digest is a budget, and a file with more in it than the
            # budget allows gets shorter. That is correct — it is the same
            # direction the built-in tool pushes the model in when it asks for
            # consolidation, and nothing is lost, because the ledger is the
            # store and `prefetch` surfaces what did not fit. It must not be
            # silent, though: "same entries in the same order" is only true
            # while everything fits, and the case that proves it is a person
            # hand-editing a file past the budget.
            report["left_out"] = max(0, len(resolved.live) - len(parse_entries(content)))
            if report["left_out"]:
                logger.info(
                    "claimstore: %s digest holds %d of %d live claims (%d over the %d-char "
                    "budget, still in the ledger and still reachable by recall)",
                    target, len(parse_entries(content)), len(resolved.live),
                    report["left_out"], limit)

            # The invariant, asserted rather than assumed: we do not write
            # bytes that the drift guard would later reject.
            if not is_tool_shaped(content, limit):
                report["skipped"] = "rendered content is not tool-shaped"
                logger.warning("claimstore: refusing to project %s — rendered content failed "
                               "the shape check", path)
                return report

            existing: Optional[str] = None
            try:
                existing = path.read_text(encoding="utf-8")
            except FileNotFoundError:
                existing = None
            except OSError:
                report["skipped"] = "existing file unreadable"
                logger.warning("claimstore: refusing to project %s — existing file could not "
                               "be read", path)
                return report

            rendered = parse_entries(content)
            report["entries"] = len(rendered)
            # What the file holds, by claim id, so the next absorption can tell
            # "we wrote this and it was retracted since" from "somebody typed
            # this back in". Recorded on the no-change path too: the file holds
            # it either way.
            remember_digest(store, target, [claim_id(target, e) for e in rendered])
            if existing is not None and existing.strip() == content.strip():
                return report

            from utils import atomic_write_text

            atomic_write_text(path, content, tmp_prefix=".claim_")
            report["written"] = True
    except Exception as exc:  # pragma: no cover - defensive
        report["skipped"] = "%s: %s" % (type(exc).__name__, exc)
        logger.warning("claimstore: projection of %s failed and its memory file is now "
                       "stale: %s", target, report["skipped"], exc_info=True)
    if report["asked"]:
        logger.info("claimstore: %d %s claim(s) were deleted and have been stated again; "
                    "they are out of the digest until someone is asked: %s",
                    len(report["asked"]), target,
                    ", ".join(q["id"] for q in report["asked"]))
    return report


def report_summary(report: Dict[str, object]) -> Dict[str, object]:
    """A :func:`project` report with the memory text taken out — what may go
    in a log. ``asked`` entries carry the re-stated sentence; here they are
    claim ids and text lengths only."""
    asked = report.get("asked") or []
    return {
        "target": report.get("target"),
        "absorbed": list(report.get("absorbed") or []),
        "placeholders": list(report.get("placeholders") or []),
        "entries": report.get("entries", 0),
        "left_out": report.get("left_out", 0),
        "disagreements": [{"key": d.get("key"), "sources": d.get("sources")}
                          for d in (report.get("disagreements") or [])],
        "asked": [{"id": q.get("id"), "source": q.get("source"),
                   "chars": len(q.get("text") or "")} for q in asked],
        "written": report.get("written", False),
        "skipped": report.get("skipped", ""),
    }


def project_all(store, targets: Iterable[str], *,
                absorb_source: str = ABSORB_SOURCE) -> List[Dict[str, object]]:
    return [project(store, t, absorb_source=absorb_source) for t in targets]
