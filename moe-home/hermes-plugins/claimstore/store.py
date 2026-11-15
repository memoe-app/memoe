"""Moe's ledger, read and written from Python.

The store is ``~/.moe/ledger/*.jsonl`` — the same append-only log Moe's Swift
side writes conversations into (``docs/ONE-AGENT.md`` §1.5). One JSONL file
per device, one immutable record per line::

    {"after":[],"at":"2026-08-31T09:14:02.000Z","body":{"claim":"8f14e45fce77",
     "enc":"aes-gcm-256.v1","key":"job","op":"assert","source":"user",
     "target":"memory","text_enc":"<base64 nonce‖ct‖tag>"},"device":"mac-9f3c1a2b",
     "id":"b3f0…","kind":"claim","prev":"a91e…","seq":41}

Design notes that matter to anyone reading this later:

* **Two ids, and they do different jobs.** ``id`` is the *record* address —
  sha256 over every field but itself — and makes replaying a record twice a
  no-op. ``body.claim`` is the *claim* address — ``sha256(target + "\\n" +
  normalised text)[:12]`` — and is what makes two devices that learn the same
  fact converge with no merge step. Only the second one has to agree across
  languages, and ``Sources/MoeLedger/Claims.swift`` is the other half of that
  agreement. ``tests/claim-conformance.json`` is the shared vector file; both
  sides assert against it, so a drift in either fails a test rather than
  quietly splitting one person's memory in two.

* **Append-only, causal, never last-write-wins on a clock.** §3.1's rules are
  applied in :func:`resolve`, and the causality they turn on comes from
  ``prev`` and ``after`` by id — never from ``seq`` (two runtimes over one
  ``~/.moe`` fork it, §13.5) and never from ``at`` (two machines, two clocks,
  §1.5).

* **One device per Mac (LEDGER-WIRE §13.1).** The id is the app's
  ``<ledger dir>/device.json`` (``mac-…``); if the app has never run, this
  store mints one in exactly the app's form so whoever is first is the author
  for both. Both writers append to ``<device>.jsonl`` and share its
  ``seq``/``prev`` chain under one protocol: ``flock`` on
  ``<device>.jsonl.lock``, the head re-derived from the file — its highest
  ``seq`` — unless the file is untouched since our own last append, one
  ``O_APPEND`` write, ``fsync``. The app signs at push time as the device, so
  nothing here opens a private key. (Until this slice the plugin had its own
  ``hermes-`` id; :meth:`ClaimStore.migrate_legacy` re-asserts what was live
  there, once.)

* **The text is sealed (§13.2–13.4).** ``text`` travels as ``enc``/``text_enc``
  under the reserved ``moe:memory`` keyring entry, the same primitive as a
  turn's text (§1.7, ``moeledger.threadcrypto``). The claim id is still over
  the plaintext, so two devices that learn one sentence converge, and a reader
  without the key can see *that* a claim exists — it is counted, matched to
  its retracts, never projected and never retracted on the person's behalf —
  but not what it says. ``key`` and ``source`` stay in the clear: labels, not
  facts.

* **Torn lines are skipped, not fatal.** Another appender may be mid-write.
  Everything after the last newline in a file is not a record yet, and a line
  that does not parse is ignored on this pass and picked up on the next
  ``refresh()``.

Nothing here imports Hermes. It is the piece a host application — a sync
daemon, a second device, an editor plugin — can use directly. The sealing
comes from the sibling ``moe-ledger`` plugin's library (``_sibling``); without
it, claims are written in plaintext, which §13.3 keeps off the network.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import logging
import os
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple, Union

logger = logging.getLogger(__name__)

# Length of the truncated sha256 used as a claim id. 12 hex chars = 48 bits;
# collision probability stays negligible for personal-scale stores and the id
# is short enough to read aloud in a bug report.
CLAIM_ID_LENGTH = 12
# Length of the truncated sha256 used as a record id (Sources/MoeLedger/
# LedgerRecord.swift: 128 bits).
RECORD_ID_LENGTH = 32

KIND_CLAIM = "claim"
ASSERT = "assert"
RETRACT = "retract"

#: §13.2: the reserved keyring entry every claim's text is sealed under.
MEMORY_KEY_ID = "moe:memory"
#: §1.7 / §13.4: the scheme named in ``enc``.
SEAL_SCHEME = "aes-gcm-256.v1"

# The source names a person's own statement carries. §3.1's tombstone
# amendment: an assert causally after a retraction revives the claim only when
# a *person* made it.
#
# **Only the person. Not the model, not a crawl, not a background pass.** This
# started wider — ``hermes:`` was on the list, because a memory-tool write is
# what "the user tells the Mac to remember it again" looks like from here, and
# that is §3.1's own worked example. It is not what it looks like from
# Hermes. There are exactly three ``write_origin`` values upstream —
# ``assistant_tool`` (the default, and precisely the model deciding on its own
# initiative), ``background_review`` and ``side_question`` — and **none of them
# means a person asked for anything.** Accepting them meant a fact somebody
# deleted about themselves could be silently restored by the assistant
# noticing it again, with nobody in the loop.
#
# Nor is ``agent_context`` a safety net: it has one producer in Hermes core
# (``agent/agent_init.py``) and it is hardcoded ``"primary"``, so the
# non-primary branch this plugin also guards is one production never takes.
#
# So the rule is narrow and the burden is on the caller: a source counts as
# the person only when it says so, which a writer may claim only when it
# actually has that signal. Everything else that re-states a deleted fact
# becomes a pending revival and is asked about rather than applied.
#
# Mirrored exactly by ``Claim.revives`` in Sources/MoeLedger/Claims.swift.
USER_SOURCE = "user"
USER_SOURCE_PREFIX = "user:"

# Whitespace, enumerated rather than asked for. Python's ``str.split()`` and
# Swift's ``Character.isWhitespace`` do not agree at the edges, and a claim id
# that differs across the two runtimes for one sentence in a million is the
# one failure this design cannot have. Matched character for character by
# ``Claim.whitespace`` in Sources/MoeLedger/Claims.swift.
_WHITESPACE = " \t\n\r\x0b\x0c"


def normalise(text: str) -> str:
    """Collapse whitespace runs to single spaces and trim.

    Deliberately weak: "the same fact" means "the same words".
    """
    if not text:
        return ""
    parts: List[str] = []
    current: List[str] = []
    for ch in text:
        if ch in _WHITESPACE:
            if current:
                parts.append("".join(current))
                current = []
        else:
            current.append(ch)
    if current:
        parts.append("".join(current))
    return " ".join(parts)


def claim_id(target: str, text: str) -> str:
    """The content address of ``text`` within ``target``.

    Scoped by target so the same sentence filed as a user-profile fact and as
    an agent note are two claims, which is what a reader would expect: they
    mean different things and are retracted independently.

    **Mirrored exactly by ``Claim.id`` in Sources/MoeLedger/Claims.swift.**
    """
    digest = hashlib.sha256(("%s\n%s" % (target, normalise(text))).encode("utf-8"))
    return digest.hexdigest()[:CLAIM_ID_LENGTH]


def revives(source: str) -> bool:
    """Whether an assert from ``source`` may undo a retraction (§3.1)."""
    source = source or ""
    return source == USER_SOURCE or source.startswith(USER_SOURCE_PREFIX)


# ---------------------------------------------------------------------------
# The record
# ---------------------------------------------------------------------------

def format_timestamp(epoch: float) -> str:
    """``2026-08-31T09:14:02.123Z`` — Swift's ISO8601 with fractional seconds.

    Milliseconds, always three digits, always UTC, always ``Z``. The record id
    is a hash of this string, so the format is part of the wire.
    """
    moment = datetime.fromtimestamp(epoch, timezone.utc)
    return "%s.%03dZ" % (moment.strftime("%Y-%m-%dT%H:%M:%S"), moment.microsecond // 1000)


def parse_timestamp(text: str) -> Optional[float]:
    """Epoch seconds from a record's ``at``. Fractional seconds optional — a
    record written by another runtime, or by hand, may not have them."""
    if not isinstance(text, str) or not text:
        return None
    raw = text.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(raw).timestamp()
    except ValueError:
        return None


def canonical_json(obj: Any) -> str:
    """The bytes a record id is taken over.

    Sorted keys, no spaces, non-ASCII left as UTF-8 and slashes unescaped —
    matching Swift's ``JSONSerialization`` with ``[.sortedKeys,
    .withoutEscapingSlashes]``.
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def record_id(unsigned: Dict[str, Any]) -> str:
    """sha256 over the canonical form of every field but ``id``, truncated to
    128 bits — ``LedgerRecord.hash`` in Swift."""
    return hashlib.sha256(canonical_json(unsigned).encode("utf-8")).hexdigest()[:RECORD_ID_LENGTH]


def unsigned_fields(kind: str, at: str, device: str, seq: int,
                    prev: Optional[str], after: Sequence[str],
                    body: Dict[str, Any]) -> Dict[str, Any]:
    out: Dict[str, Any] = {
        "kind": kind,
        "at": at,
        "device": device,
        "seq": seq,
        "after": list(after),
        "body": body,
    }
    if prev:
        out["prev"] = prev
    return out


def sort_key(record: Dict[str, Any]) -> Tuple[float, str, int]:
    """The seed order records are considered in: wall clock, then the writing
    device, then its own sequence. Never the id, which is a hash and would
    shuffle records written in the same millisecond into an order nobody wrote
    them in. ``Ledger.SortKey`` in Swift."""
    return (record.get("_at", 0.0), str(record.get("device") or ""), int(record.get("seq") or 0))


def parents_of(record: Dict[str, Any]) -> List[str]:
    """Everything this record's author had already seen, as far as the record
    says: what it named, plus its own previous write."""
    after = record.get("after")
    parents = [str(p) for p in after] if isinstance(after, list) else []
    prev = record.get("prev")
    if isinstance(prev, str) and prev:
        parents.append(prev)
    return parents


def ordered(records: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """A stable topological order: each record after everything it names in
    ``after`` (and in ``prev``) that we actually hold.

    ``Ledger.ordered`` in Swift, iteratively — a device's ``prev`` chain is as
    long as its history, and a recursive walk of it would hit Python's stack
    limit on a ledger a person could plausibly own.
    """
    by_id: Dict[str, Dict[str, Any]] = {}
    for record in records:
        by_id.setdefault(record["id"], record)

    out: List[Dict[str, Any]] = []
    placed: Set[str] = set()
    visiting: Set[str] = set()

    for seed in sorted(records, key=sort_key):
        if seed["id"] in placed:
            continue
        # (record, parents-not-yet-walked). A record is emitted when its
        # parents have been.
        stack: List[Tuple[Dict[str, Any], List[Dict[str, Any]]]] = [
            (seed, sorted((by_id[p] for p in parents_of(seed) if p in by_id),
                          key=sort_key)[::-1])
        ]
        visiting.add(seed["id"])
        while stack:
            record, pending = stack[-1]
            if pending:
                parent = pending.pop()
                pid = parent["id"]
                # A cycle can only come from a corrupt or hostile file; break
                # it rather than recurse forever.
                if pid in placed or pid in visiting:
                    continue
                visiting.add(pid)
                stack.append((parent, sorted((by_id[p] for p in parents_of(parent) if p in by_id),
                                             key=sort_key)[::-1]))
                continue
            stack.pop()
            visiting.discard(record["id"])
            if record["id"] not in placed:
                placed.add(record["id"])
                out.append(record)
    return out


def causally_after(pivot: Dict[str, Any], sequence: Sequence[Dict[str, Any]]) -> Set[str]:
    """Which records in ``sequence`` are causally after ``pivot``.

    One forward pass from the pivot's own position; ``sequence`` must already
    be in :func:`ordered` order, which places every record after the parents
    it holds. ``Ledger.causallyAfter`` in Swift — and, as there, **there is no
    ``seq`` comparison here and there must not be.**
    """
    start = None
    for index, record in enumerate(sequence):
        if record["id"] == pivot["id"]:
            start = index
            break
    if start is None:
        return set()
    after: Set[str] = set()
    for record in sequence[start + 1:]:
        for parent in parents_of(record):
            if parent == pivot["id"] or parent in after:
                after.add(record["id"])
                break
    return after


# ---------------------------------------------------------------------------
# What §3.1 says about claims
# ---------------------------------------------------------------------------

class Live(object):
    """One live memory fact, as the projection sees it."""

    __slots__ = ("id", "target", "key", "source", "text", "record_id")

    def __init__(self, id, target, key, source, text, record_id):  # noqa: A002
        self.id = id
        self.target = target
        self.key = key
        self.source = source
        self.text = text
        self.record_id = record_id

    def __repr__(self):
        return "Live(%s, key=%s, source=%s, text=%r)" % (self.id, self.key, self.source, self.text)

    def __eq__(self, other):
        return isinstance(other, Live) and all(
            getattr(self, f) == getattr(other, f) for f in self.__slots__)

    def __hash__(self):
        return hash(tuple(getattr(self, f) for f in self.__slots__))


class PendingRevival(object):
    """A fact somebody deleted, re-stated afterwards by something that is not
    the person, *knowing* it had been deleted.

    Not a bug and not an error: a crawl re-derives what it derived before, and
    the model notices the same thing twice. §3.1 says such an assert does not
    revive, and this build agrees — but "does not revive" used to mean the
    record was written and then silently ignored forever, and a person who
    typed a fact back into ``MEMORY.md`` by hand vanished into the same hole.

    So the third answer, which is this product's posture everywhere else:
    **ask**. The claim stays out of the digest, the record stays in the ledger,
    and it surfaces here so Moe can say "you deleted that before, want me to
    remember it again?" Answering yes is a ``user``-sourced assert, which
    revives it by the ordinary rule. Nothing here restores anything, and
    nothing here drops anything.
    """

    __slots__ = ("claim", "retracted_by")

    def __init__(self, claim, retracted_by):
        self.claim = claim
        self.retracted_by = retracted_by

    @property
    def id(self):
        return self.claim.id

    @property
    def text(self):
        return self.claim.text

    @property
    def source(self):
        return self.claim.source

    def __repr__(self):
        return "PendingRevival(%s, source=%s, text=%r)" % (
            self.claim.id, self.claim.source, self.claim.text)


class Projection(object):
    """What :meth:`ClaimStore.resolve` produces: what the digest should show,
    what it should ask about, and what it is deliberately leaving out."""

    __slots__ = ("live", "disagreements", "superseded", "pending_revivals", "unreadable")

    def __init__(self, live, disagreements, superseded, pending_revivals=None,
                 unreadable=None):
        self.live = live
        self.disagreements = disagreements
        self.superseded = superseded
        self.pending_revivals = pending_revivals or []
        #: Claim ids that stand (or would be asked about) but whose text is
        #: sealed under a key this reader does not hold (§13.4): counted,
        #: never projected, never retracted on the person's behalf.
        self.unreadable = list(unreadable or [])

    @property
    def texts(self) -> List[str]:
        return [c.text for c in self.live]


def open_text(encoded: str, key: Optional[Union[bytes, Sequence[bytes]]]) -> Optional[str]:
    """``ThreadCrypto.open`` (§1.7) via the sibling library; None without it,
    without a key, or when the tag does not verify.

    ``key`` may be **one key or several** (CLOUD-PLAN §15.1). A Mac that ran
    Moe free before joining a tenant has a retired `moe:memory` key beside its
    current one, and the claims it wrote while free open only under the old
    one. Every key is tried, current first; the first that verifies wins.

    Trying several is safe because GCM authenticates: a wrong key does not
    produce plausible plaintext, it produces nothing. So this cannot silently
    return the wrong text, only the right text or None.
    """
    lib = _threadcrypto()
    if lib is None or key is None:
        return None
    candidates: Sequence[bytes] = [key] if isinstance(key, (bytes, bytearray)) else key
    for candidate in candidates:
        opened = lib.open_sealed(encoded, candidate)
        if opened is not None:
            return opened
    return None


def seal_text(text: str, key: bytes) -> str:
    lib = _threadcrypto()
    if lib is None:
        raise RuntimeError("claimstore: cannot seal without the moe-ledger plugin beside it")
    return lib.seal(text, key)


def _threadcrypto():
    try:
        from ._sibling import moeledger
    except ImportError:            # loaded as a bare module, not a package
        return None
    lib = moeledger()
    return lib.threadcrypto if lib is not None else None


def parse_claim(record: Dict[str, Any],
                key: Optional[Union[bytes, Sequence[bytes]]] = None) -> Optional[Dict[str, Any]]:
    """The claim a record carries, or None for a record that is not one this
    build understands. Never raises: an unreadable claim is one fact missing
    from a digest, not a memory that fails to load.

    A sealed assert (``text_enc``, §13.4) opens with ``key``; without one, or
    with the wrong one, it comes back with ``text`` None and ``readable``
    False — present but unreadable. A retract carries no text either way.
    """
    if record.get("kind") != KIND_CLAIM:
        return None
    body = record.get("body")
    if not isinstance(body, dict):
        return None
    op = body.get("op")
    if op not in (ASSERT, RETRACT):
        return None
    # ``claim`` is what Claims.swift and this store write; §13.4's sketch
    # names the field ``id``. Read both, write ``claim``.
    cid = body.get("claim")
    if not isinstance(cid, str) or not cid:
        cid = body.get("id")
    target = body.get("target")
    if not isinstance(cid, str) or not cid or not isinstance(target, str) or not target:
        return None
    text: Optional[str] = None
    readable = True
    if "text_enc" in body:
        sealed = body.get("text_enc")
        # A ``text_enc`` that is present but empty (or not a string) is
        # malformed, not a removal — only a ``document`` has that form
        # (§13.5). The record is ignored; Swift's ``Claim`` does the same.
        if not isinstance(sealed, str) or not sealed:
            return None
        text = open_text(sealed, key)
        readable = text is not None
    else:
        plain = body.get("text")
        text = plain if isinstance(plain, str) else ""
    if op == ASSERT and readable and not text:
        return None
    if op == RETRACT:
        text, readable = "", True
    key_label = body.get("key")
    source = body.get("source")
    return {
        "op": op,
        "claim": cid,
        "target": target,
        "key": key_label if isinstance(key_label, str) and key_label else cid,
        "source": source if isinstance(source, str) and source else "unknown",
        "text": text,
        "readable": readable,
    }


def resolve(records: Sequence[Dict[str, Any]], target: str,
            key: Optional[Union[bytes, Sequence[bytes]]] = None) -> Projection:
    """§3.1's claim rules, applied to an already-ordered ledger.

    The same five rules, in the same order, as ``ClaimLedger.resolve`` in
    Sources/MoeLedger/Claims.swift — and identical answers on the same
    records is what ``tests/test_conformance.py`` and
    ``Tests/MoeLedgerTests/ClaimConformanceTests.swift`` assert against one
    shared fixture. Two implementations of one rule set is a risk taken
    knowingly (Swift cannot run inside Hermes and Python cannot run inside the
    app); the fixture is what keeps it a risk rather than a bug.
    """
    position = {record["id"]: index for index, record in enumerate(records)}

    asserts: Dict[str, List[Tuple[Dict[str, Any], Dict[str, Any]]]] = {}
    retracts: Dict[str, List[Dict[str, Any]]] = {}
    id_order: List[str] = []
    for record in records:
        claim = parse_claim(record, key)
        if not claim or claim["target"] != target:
            continue
        cid = claim["claim"]
        if cid not in asserts and cid not in retracts:
            id_order.append(cid)
        if claim["op"] == ASSERT:
            asserts.setdefault(cid, []).append((record, claim))
        else:
            retracts.setdefault(cid, []).append(record)

    # :func:`causally_after`, once per tombstone, over parents read once. A
    # ledger of ~9,000 records with ~70 retractions a target made 2.7 million
    # ``parents_of`` calls a resolve that way — a quarter of a second each,
    # and a session start resolves fourteen times (measured 2026-11-08).
    parent_lists = [parents_of(record) for record in records]
    first: Dict[str, int] = {}
    for index, record in enumerate(records):
        first.setdefault(record["id"], index)
    after_retraction: Dict[str, Set[str]] = {}
    for tombstones in retracts.values():
        for tombstone in tombstones:
            tid = tombstone["id"]
            if tid in after_retraction:
                continue
            start = first.get(tid)
            after: Set[str] = set()
            if start is not None:
                for index in range(start + 1, len(records)):
                    for parent in parent_lists[index]:
                        if parent == tid or parent in after:
                            after.add(records[index]["id"])
                            break
            after_retraction[tid] = after

    standing: List[Live] = []
    pending: List[PendingRevival] = []
    unreadable: List[str] = []
    for cid in id_order:
        entries = asserts.get(cid)
        if not entries:
            continue
        tombstones = retracts.get(cid, [])
        # One claim id is one normalised sentence, so any readable assert of
        # it can lend its text to a sealed one we cannot open — which is what
        # keeps a migrated (plaintext legacy + sealed copy) claim readable
        # everywhere, and a fact learned on two devices readable with either
        # copy.
        lent = next((c["text"] for _, c in entries if c["readable"]), None)
        survivors = []
        for record, claim in entries:
            # The tombstone this assert came after, if it came after them all.
            # None means at least one retraction it is causally before or
            # concurrent with, which suppresses it outright: whoever wrote it
            # had not heard, and there is nothing to ask them about.
            knew_about = None
            suppressed = False
            for tombstone in tombstones:
                if record["id"] not in after_retraction.get(tombstone["id"], set()):
                    suppressed = True
                    break
                knew_about = tombstone["id"]
            if suppressed:
                continue
            if knew_about and not revives(claim["source"]):
                # Causally after every retraction, but not the person. It does
                # not revive — and it is not silently discarded either. It
                # becomes a question (ONE-AGENT §14.3).
                text = claim["text"] if claim["readable"] else lent
                if text is None:
                    if cid not in unreadable:
                        unreadable.append(cid)
                    continue
                pending.append(PendingRevival(
                    Live(cid, target, claim["key"], claim["source"], text, record["id"]),
                    knew_about))
                continue
            survivors.append((record, claim))
        if not survivors:
            continue
        winner = max(survivors, key=lambda e: position.get(e[0]["id"], 0))
        text = winner[1]["text"] if winner[1]["readable"] else lent
        if text is None:
            if cid not in unreadable:
                unreadable.append(cid)
            continue
        standing.append(Live(cid, target, winner[1]["key"], winner[1]["source"],
                             text, winner[0]["id"]))
    standing.sort(key=lambda c: position.get(c.record_id, 0))

    key_order: List[str] = []
    by_key: Dict[str, List[Live]] = {}
    for claim in standing:
        if claim.key not in by_key:
            key_order.append(claim.key)
            by_key[claim.key] = []
        by_key[claim.key].append(claim)

    live: List[Live] = []
    superseded: List[Live] = []
    disagreements: List[Dict[str, Any]] = []
    for key in key_order:
        readings = by_key[key]
        if len(readings) == 1:
            live.extend(readings)
            continue
        # Rule 4, per source: one source with two readings of one topic is a
        # source that changed its mind, and the newer reading is the better one.
        newest: Dict[str, Live] = {}
        source_order: List[str] = []
        for reading in readings:
            if reading.source in newest:
                superseded.append(newest[reading.source])
            else:
                source_order.append(reading.source)
            newest[reading.source] = reading
        kept = [newest[s] for s in source_order]
        live.extend(kept)
        # Rule 5: what is left is one reading per source, and more than one
        # source left means they genuinely disagree.
        if len(kept) > 1:
            disagreements.append({"target": target, "key": key, "readings": kept,
                                  "sources": [c.source for c in kept]})
    live.sort(key=lambda c: position.get(c.record_id, 0))
    superseded.sort(key=lambda c: position.get(c.record_id, 0))
    # Newest question first: one claim re-stated three times is one question,
    # about the most recent time somebody said it.
    newest_pending: Dict[str, PendingRevival] = {}
    for item in pending:
        held = newest_pending.get(item.id)
        if held is None or position.get(held.claim.record_id, 0) < position.get(
                item.claim.record_id, 0):
            newest_pending[item.id] = item
    # A claim that is live again is not a question. The person may have
    # answered yes, or said it themselves; either way there is nothing left to
    # ask, and an outstanding question about a fact Moe currently remembers
    # would be worse than no question at all.
    live_ids = {c.id for c in live}
    questions = sorted((q for q in newest_pending.values() if q.id not in live_ids),
                       key=lambda q: position.get(q.claim.record_id, 0))
    return Projection(live, disagreements, superseded, questions,
                      [cid for cid in unreadable if cid not in live_ids])


# ---------------------------------------------------------------------------
# The store
# ---------------------------------------------------------------------------

#: §13.1: one device per Mac. The id is the app's, read from (or minted into)
#: the ledger directory itself, in exactly the app's form
#: (``Ledger.resolveDevice``): ``{"createdAt": …, "id": "mac-<8 hex>"}``.
DEVICE_FILE = "device.json"
DEVICE_PREFIX = "mac-"
#: What this plugin minted for itself before §13.1. Files under it stay
#: readable (their claims are still local memory) and are never pushed; what
#: was live in them is re-asserted once under the shared id.
LEGACY_DEVICE_FILE = "claimstore-device.json"
LEGACY_DEVICE_PREFIX = "hermes-"
MIGRATION_MARKER = "claimstore-migrated.json"


def _moeledger():
    try:
        from ._sibling import moeledger
    except ImportError:
        return None
    return moeledger()


class _flock(object):
    """``flock(LOCK_EX)`` on a 0600 lock file, held for the block."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.fd = -1

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(str(self.path), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        finally:
            os.close(self.fd)
            self.fd = -1


def _read_peer_book(path: Optional[Path]) -> Tuple[Set[str], bool]:
    """The device ids in a §3.4 ``peers.json`` and whether it was readable.
    Absent is readable-and-empty (nobody enrolled); unparseable is not. A
    device in the book's ``revoked`` list is not a peer, as ``PeerBook`` in
    Swift reads it: nobody can deliver from a revoked device."""
    if path is None:
        return set(), True
    try:
        data = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return set(), True
    except (OSError, ValueError):
        return set(), False
    peers = data.get("peers") if isinstance(data, dict) else None
    if not isinstance(peers, dict):
        return set(), False
    revoked = data.get("revoked")
    revoked_ids = {str(r) for r in revoked} if isinstance(revoked, list) else set()
    return {str(k) for k in peers} - revoked_ids, True


def safe_device(device: str) -> str:
    """A device id from a file someone else wrote must not escape the ledger
    directory — the same sanitisation ``Ledger.file(for:)`` applies."""
    kept = "".join(ch for ch in device if ch.isalnum() or ch in "-_")
    return kept or "unknown"


class ClaimStore(object):
    """Moe's ledger directory, read whole and appended to by this runtime.

    ``state_dir`` is where this projector's own state lives (the digest
    marker, the documents state): ``$HERMES_HOME`` on a Mac, the vault on a
    machine — a fact about this projector, not about the store. ``keyring``
    is a ``moeledger.vault.Keyring`` (or anything with ``key(id)``) holding
    ``moe:memory``; ``key`` is the raw 32 bytes for a caller that has them in
    hand. ``appender`` lets a host that owns the device's chain (the machine's
    ``LocalLedger``) do the append; by default this store appends itself
    under the §13.1 protocol.
    """

    def __init__(self, directory, device: Optional[str] = None,
                 state_dir=None, keyring=None, key: Optional[bytes] = None,
                 appender=None, identity_dir=None) -> None:
        self.directory = Path(directory).expanduser()
        self._device = device
        self._state_dir = state_dir if state_dir is not None else identity_dir
        self._keyring = keyring
        self._key = key
        self._appender = appender
        self._files: Dict[str, Dict[str, Any]] = {}
        self._ordered: Optional[List[Dict[str, Any]]] = None
        self._ids: Set[str] = set()
        # Where this device's seq/prev chain has got to, and the file's
        # (size, mtime_ns) right after our own last append — the cache is
        # only trusted while the file still looks like that (§13.1 step 2).
        self._head_cached: Optional[Tuple[int, Optional[str]]] = None
        self._head_stamp: Optional[Tuple[int, int]] = None
        self._loaded = False
        #: The cache below (``_files``, ``_ordered``, ``_ids``) is shared by
        #: every thread in the process — Hermes's memory worker, a prefetch,
        #: a tool call, and per-turn learning's own thread on the away
        #: machine. A re-read that swaps it while an append folds a record
        #: into the old one hides that record until the file changes again.
        self._cache_lock = threading.RLock()
        #: How many times the whole ledger has been re-read and re-sorted.
        #: Not a statistic — a test asserts on it. Adoption of a memory file
        #: used to cost one of these *per absorbed entry*, which on a real
        #: ledger is seconds, synchronously, inside ``initialize()``.
        self.full_reads = 0
        #: Bumped whenever ``_ordered`` changes (a re-read or an append);
        #: what :meth:`resolve`'s memo is keyed on.
        self._generation = 0
        self._resolved: Dict[str, Tuple[Any, Projection]] = {}

    # -- identity -----------------------------------------------------------

    @property
    def device(self) -> str:
        if self._device is None:
            self._device = self._resolve_device()
        return self._device

    @property
    def identity_path(self) -> Path:
        """§13.1: the app's ``<ledger dir>/device.json``, shared by every writer."""
        return self.directory / DEVICE_FILE

    @property
    def state_dir(self) -> Path:
        """Where this projector keeps what is its own (the digest marker).

        ``$HERMES_HOME`` unless told otherwise; the ledger directory only for
        a standalone reader or a test with no Hermes home to belong to.
        """
        if self._state_dir is not None:
            return Path(self._state_dir).expanduser()
        home = os.environ.get("HERMES_HOME")
        return Path(home).expanduser() if home else self.directory

    @property
    def key(self) -> Optional[bytes]:
        """The ``moe:memory`` key, live from the keyring (so one delivered by
        the courier mid-session is seen), or the bytes given at construction."""
        if self._keyring is not None:
            try:
                held = self._keyring.key(MEMORY_KEY_ID)
            except Exception:
                logger.warning("claimstore: the keyring could not be read", exc_info=True)
                held = None
            if held is not None:
                return held
        return self._key

    @property
    def opening_keys(self) -> List[bytes]:
        """Every key that may open a claim this device can read (§15.1).

        The current `moe:memory` key first, then any retired under it — the
        keys a Mac sealed with while it ran free, before it joined a tenant
        and adopted the tenant's. **Reads use this; `key` is what sealing
        uses**, and keeping them separate is the whole safety property: a
        retired key that could still seal would put new claims beyond the
        reach of every other device in the tenant.

        Falls back to the single key when there is no keyring — a standalone
        reader, or a test — so nothing that worked before needs a keyring now.
        """
        if self._keyring is not None:
            try:
                held = self._keyring.opening_keys(MEMORY_KEY_ID)
            except Exception:
                logger.warning("claimstore: the keyring could not be read", exc_info=True)
                held = []
            if held:
                return held
        single = self._key
        return [single] if single is not None else []

    @property
    def seals(self) -> bool:
        """Whether a claim written now would be sealed (§13.4)."""
        return self.key is not None and _threadcrypto() is not None

    def forked_seqs(self) -> List[int]:
        """Sequence numbers this device wrote more than once. Empty is healthy.

        Two writers of one chain that skip the §13.1 lock — or two processes
        with stale cached heads — both write ``seq`` 7, which leaves no gap
        and no complaint and quietly retires §1.5's guarantee that a gap
        means loss. The sync layer tolerates it (``forkedDevices``, §6.10)
        by sending everything, every time; this makes it visible, as
        ``Ledger.forkedSeqsForThisDevice`` does on the Swift side.
        """
        seen: Dict[int, str] = {}
        forked: Set[int] = set()
        for record in self._read_file(self.path):
            seq = int(record.get("seq") or 0)
            first = seen.get(seq)
            if first is not None and first != record["id"]:
                forked.add(seq)
            seen[seq] = record["id"]
        return sorted(forked)

    def _resolve_device(self) -> str:
        path = self.identity_path
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("id"), str) and data["id"]:
                return data["id"]
        except (OSError, ValueError):
            pass
        # Hermes ran before the app ever did: mint in exactly the app's form
        # (``Ledger.resolveDevice``) so whoever is first is the author for
        # both. Random rather than a hash of the hostname: hostnames change,
        # repeat across machines, and are not ours to put in a file that will
        # one day be uploaded.
        device = DEVICE_PREFIX + uuid.uuid4().hex[:8]
        body = {"id": device, "createdAt": format_timestamp(time.time())}
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            try:
                os.chmod(str(self.directory), 0o700)
            except OSError:
                pass
            lib = _moeledger()
            if lib is not None:
                text = lib.records.foundation_pretty_json(body)
            else:
                text = json.dumps(body, indent=2, sort_keys=True)
            tmp = path.with_name(path.name + ".%d.tmp" % os.getpid())
            tmp.write_text(text, encoding="utf-8")
            os.chmod(str(tmp), 0o600)
            os.replace(str(tmp), str(path))
            logger.info("claimstore: minted device %s into %s (the app will use it too)",
                        device, path)
        except OSError:
            logger.warning("claimstore: could not persist a device id at %s", path,
                           exc_info=True)
        return device

    @property
    def path(self) -> Path:
        """The device's file — shared with the app (§13.1)."""
        return self.directory / (safe_device(self.device) + ".jsonl")

    @property
    def lock_path(self) -> Path:
        return self.directory / (safe_device(self.device) + ".jsonl.lock")

    # -- reading ------------------------------------------------------------

    def _jsonl(self) -> List[Path]:
        try:
            return sorted((p for p in self.directory.iterdir() if p.suffix == ".jsonl"),
                          key=lambda p: p.name)
        except OSError:
            return []

    @staticmethod
    def _decode(line: str) -> Optional[Dict[str, Any]]:
        try:
            record = json.loads(line)
        except ValueError:
            # A torn or hand-mangled line. Skip it; a later refresh sees the
            # completed write. Never abort the replay over one line.
            return None
        if not isinstance(record, dict):
            return None
        for field in ("id", "kind", "at", "device"):
            if not isinstance(record.get(field), str) or not record[field]:
                return None
        if not isinstance(record.get("seq"), int):
            return None
        at = parse_timestamp(record["at"])
        if at is None:
            return None
        record["_at"] = at
        if not isinstance(record.get("after"), list):
            record["after"] = []
        if not isinstance(record.get("body"), dict):
            record["body"] = {}
        return record

    @classmethod
    def _read_file(cls, path: Path) -> List[Dict[str, Any]]:
        try:
            raw = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return []
        # Everything after the last newline is not a record yet: either
        # nothing, or half a line another appender is still writing.
        cut = raw.rfind("\n")
        if cut < 0:
            return []
        out = []
        for line in raw[:cut].splitlines():
            line = line.strip()
            if not line:
                continue
            record = cls._decode(line)
            if record is not None:
                out.append(record)
        return out

    def refresh(self) -> bool:
        """Re-read the ledger if anything changed on disk. True if it did."""
        with self._cache_lock:
            return self._refresh()

    def _refresh(self) -> bool:
        signature: Dict[str, Any] = {}
        files = self._jsonl()
        for path in files:
            try:
                st = path.stat()
            except OSError:
                continue
            signature[path.name] = (st.st_size, st.st_mtime_ns)
        if self._loaded and signature == {k: v["stat"] for k, v in self._files.items()}:
            return False

        seen: Set[str] = set()
        records: List[Dict[str, Any]] = []
        fresh: Dict[str, Dict[str, Any]] = {}
        for path in files:
            if path.name not in signature:
                continue
            parsed = self._read_file(path)
            fresh[path.name] = {"stat": signature[path.name], "records": parsed}
            for record in parsed:
                if record["id"] in seen:
                    continue
                seen.add(record["id"])
                records.append(record)
        self._files = fresh
        self._ordered = ordered(records)
        self._ids = seen
        self._loaded = True
        self._generation += 1
        self.full_reads += 1
        return True

    def records(self) -> List[Dict[str, Any]]:
        """Every readable record from every device, in ledger order."""
        with self._cache_lock:
            if not self._loaded:
                self._refresh()
            return list(self._ordered or [])

    def claim_records(self, target: Optional[str] = None) -> List[Dict[str, Any]]:
        out = []
        # Once, not per record: each read opens the keyring file, and on a
        # 9,000-record ledger that was 0.4 s of a session start.
        keys = self.opening_keys
        for record in self.records():
            claim = parse_claim(record, keys)
            if claim and (target is None or claim["target"] == target):
                out.append(record)
        return out

    def resolve(self, target: str) -> Projection:
        """:func:`resolve` over this store, remembered until the ledger or the
        keys change. A session start asks fourteen times and every prefetch
        twice, nearly always of a ledger nothing has touched in between. The
        Projection is shared: read it, never mutate it."""
        keys = self.opening_keys
        with self._cache_lock:
            if not self._loaded:
                self._refresh()
            memo = (self._generation, tuple(keys) if isinstance(keys, (list, tuple)) else keys)
            held = self._resolved.get(target)
            if held is not None and held[0] == memo:
                return held[1]
            projection = resolve(list(self._ordered or []), target, keys)
            self._resolved[target] = (memo, projection)
            return projection

    def live(self, target: str) -> List[str]:
        """Text of every claim still asserted for ``target``, oldest first."""
        return self.resolve(target).texts

    def is_live(self, target: str, cid: str) -> bool:
        return any(c.id == cid for c in self.resolve(target).live)

    def targets(self) -> List[str]:
        out: List[str] = []
        for record in self.records():
            claim = parse_claim(record)
            if claim and claim["target"] not in out:
                out.append(claim["target"])
        return out

    # -- writing ------------------------------------------------------------

    def frontier(self) -> List[str]:
        """The last record of every device other than this one — what a write
        says it had already seen. ``prev`` already carries our own."""
        last: Dict[str, str] = {}
        for record in self.records():
            if record.get("device") != self.device:
                last[str(record.get("device"))] = record["id"]
        return sorted(last.values())

    def _file_stamp(self) -> Optional[Tuple[int, int]]:
        try:
            st = os.stat(str(self.path))
        except OSError:
            return None
        return (st.st_size, st.st_mtime_ns)

    def _head(self) -> Tuple[int, Optional[str]]:
        """§13.1 step 2: the chain's head **from the file** — the record with
        the highest ``seq`` (not the last line: on a file a pre-slice writer
        already forked, last-line would fork it again; highest-seq closes the
        fork, and Swift does the same) — unless the file's ``(size,
        mtime_ns)`` is exactly what it was after our own last append. Call
        under :meth:`_locked`."""
        if self._head_cached is not None and self._head_stamp is not None \
                and self._head_stamp == self._file_stamp():
            return self._head_cached
        mine = self._read_file(self.path)
        head: Tuple[int, Optional[str]] = (0, None)
        for record in mine:
            if int(record.get("seq") or 0) > head[0]:
                head = (int(record["seq"]), record["id"])
        self._head_cached = head
        self._head_stamp = self._file_stamp()
        return head

    def _locked(self):
        """§13.1 step 1: ``flock(LOCK_EX)`` on ``<device>.jsonl.lock`` (0600)."""
        return _flock(self.lock_path)

    def append(self, kind: str, body: Dict[str, Any], after: Optional[Sequence[str]] = None,
               at: Optional[float] = None) -> Dict[str, Any]:
        """Append one record, durably, and return it with its id filled in.

        The §13.1 protocol, shared with the app: lock, head from the file,
        ``seq = head + 1``, ``prev = head.id``, one ``write(2)`` on an
        ``O_APPEND`` descriptor, ``fsync``, release. A host that owns the
        chain (``appender``) does the same in its own code.
        """
        if self._appender is not None:
            record = self._appender(kind, body, list(after or []), at)
            self._extend_with(record)
            return record
        self.directory.mkdir(parents=True, exist_ok=True)
        with self._locked():
            seq, prev = self._head()
            # The file as it is *now*, under the lock, against the file as the
            # cache last saw it. A record the app appended between our last
            # refresh and this append is in the head we just took but not in
            # ``_ordered``, and ``_extend_with`` would then re-stamp the cache
            # to a file it has not read — hiding the app's record until the
            # stamp changed again. A mismatch here drops the cache instead;
            # the next read rebuilds it.
            if self._loaded:
                entry = self._files.get(self.path.name)
                if (entry["stat"] if entry is not None else None) != self._file_stamp():
                    self._loaded = False
            stamp = format_timestamp(time.time() if at is None else at)
            unsigned = unsigned_fields(kind, stamp, self.device, seq + 1, prev,
                                       list(after or []), body)
            record = dict(unsigned)
            record["id"] = record_id(unsigned)

            payload = ""
            if self._ends_mid_line():
                # A previous crash can have left half a line. Starting on a
                # new one keeps that damage to the record that was lost.
                payload += "\n"
            payload += canonical_json(record) + "\n"
            # One record, one ``write(2)``, on a file opened ``O_APPEND``: the
            # kernel picks the offset and performs the write as one operation,
            # so even a writer that skipped the lock cannot interleave with
            # this one or overwrite an earlier record.
            #
            # It is deliberately **not** a retry loop. A second ``os.write``
            # is a second append, and another writer can land between the
            # two. A short write fails loudly with the record's own id.
            data = payload.encode("utf-8")
            fd = os.open(str(self.path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                written = os.write(fd, data)
                if written != len(data):
                    raise IOError(
                        "claimstore: short append of record %s (%d of %d bytes). Retrying "
                        "would append a second time and split the record; the tail of %s "
                        "is now a partial line and will be skipped on the next read."
                        % (record["id"], written, len(data), self.path))
                os.fsync(fd)
            finally:
                os.close(fd)
            self._head_cached = (record["seq"], record["id"])
            self._head_stamp = self._file_stamp()
        self._extend_with(record)
        return record

    def _extend_with(self, record: Dict[str, Any]) -> None:
        """Fold a record this process just wrote onto the order it already has.

        Only when that is provably the same answer a full re-read would give:
        the record must sort after everything already placed, and every parent
        it names that we hold must already be placed. Otherwise the cache is
        dropped and the next read rebuilds it — always correct, merely slower.

        This is the Python twin of ``Ledger.appendable`` in Swift, and it
        exists for the same reason: without it every append costs a re-parse
        and a re-sort of the whole ledger, so adopting a thirty-entry
        ``MEMORY.md`` cost thirty of them.
        """
        with self._cache_lock:
            self._extend_with_locked(record)

    def _extend_with_locked(self, record: Dict[str, Any]) -> None:
        if not self._loaded or self._ordered is None:
            return
        decoded = self._decode(canonical_json({k: v for k, v in record.items()
                                               if not k.startswith("_")}))
        if decoded is None:
            self._loaded = False
            return
        if decoded["id"] in self._ids:
            # A re-read that ran after the write already holds it.
            return
        if self._ordered and sort_key(decoded) < sort_key(self._ordered[-1]):
            self._loaded = False
            return
        # Its causal parents need no check: ``_ids`` and ``_ordered`` hold
        # exactly the same records, so a parent we hold is a parent already
        # placed. (A parent we do not hold is ignored by ``ordered`` too.)
        self._ordered.append(decoded)
        self._ids.add(decoded["id"])
        self._generation += 1
        name = self.path.name
        entry = self._files.get(name)
        if entry is None:
            self._loaded = False
            return
        entry["records"].append(decoded)
        try:
            st = self.path.stat()
            entry["stat"] = (st.st_size, st.st_mtime_ns)
        except OSError:
            self._loaded = False

    def _ends_mid_line(self) -> bool:
        try:
            with open(str(self.path), "rb") as handle:
                handle.seek(0, os.SEEK_END)
                if handle.tell() == 0:
                    return False
                handle.seek(-1, os.SEEK_END)
                return handle.read(1) != b"\n"
        except OSError:
            return False

    # -- claims -------------------------------------------------------------

    def assert_claim(self, target: str, text: str, *, source: str = "",
                     key: Optional[str] = None,
                     after: Optional[Sequence[str]] = None) -> Optional[str]:
        """Record ``text`` as true for ``target``. Returns the claim id.

        A no-op (returning the id, appending nothing) when the claim is
        already live and says the same thing — the log records changes of
        belief, not repetitions of one.
        """
        text = (text or "").strip()
        if not text:
            return None
        cid = claim_id(target, text)
        resolved = self.resolve(target)
        standing = {c.id: c for c in resolved.live}.get(cid)
        if standing is not None and standing.text == text and (key is None or standing.key == key):
            return cid
        if cid in resolved.unreadable and not self.seals:
            # Live under a key we do not hold, and we could only add a
            # plaintext copy: the fact is already there; leave it.
            return cid
        self.append(KIND_CLAIM, self.claim_body(ASSERT, cid, target, source, text, key),
                    after=self.frontier() if after is None else after)
        return cid

    def claim_body(self, op: str, cid: str, target: str, source: str,
                   text: Optional[str] = None, key: Optional[str] = None) -> Dict[str, Any]:
        """The §13.4 body: ``text`` sealed under ``moe:memory`` when the key
        is at hand, plaintext otherwise (local-only, §13.3). ``key`` here is
        the topic label, not the cipher key."""
        body: Dict[str, Any] = {"op": op, "claim": cid, "target": target,
                                "source": source or "unknown"}
        if key:
            body["key"] = key
        if op == ASSERT:
            secret = self.key
            if secret is not None and _threadcrypto() is not None:
                body["enc"] = SEAL_SCHEME
                body["text_enc"] = seal_text(text or "", secret)
            else:
                body["text"] = text or ""
        return body

    def assert_many(self, target: str, texts: Sequence[str], *, source: str = "",
                    after: Optional[Sequence[str]] = None) -> List[str]:
        """Assert several claims, resolving the ledger once for all of them.

        Returns the claim ids minted, in order. Skips anything already live and
        anything already awaiting an answer — see :func:`projection.absorb` for
        why "already asked about" is a reason not to ask again.

        This exists for adoption. ``assert_claim`` resolves the whole ledger to
        decide whether one claim is already live, which is right for one call
        and quadratic for thirty: absorbing a thirty-entry ``MEMORY.md`` on a
        twenty-thousand-record ledger took seconds, synchronously, inside
        ``initialize()`` — on exactly the first-run path adoption is about.
        """
        resolved = self.resolve(target)
        standing = {c.id: c for c in resolved.live}
        asked = {q.id for q in resolved.pending_revivals}
        frontier = self.frontier() if after is None else list(after)
        minted: List[str] = []
        for text in texts:
            text = (text or "").strip()
            if not text:
                continue
            cid = claim_id(target, text)
            if cid in asked:
                continue
            held = standing.get(cid)
            if held is not None and held.text == text:
                continue
            if cid in resolved.unreadable and not self.seals:
                continue
            self.append(KIND_CLAIM, self.claim_body(ASSERT, cid, target, source, text),
                        after=frontier)
            minted.append(cid)
            # Two identical entries in one file are one claim, and the second
            # must not append a second record.
            standing[cid] = Live(cid, target, cid, source or "unknown", text, "")
        return minted

    def retract_claim(self, target: str, text: str, *, source: str = "",
                      after: Optional[Sequence[str]] = None) -> Optional[str]:
        """Retract the claim whose text is exactly ``text``."""
        return self.retract_id(target, claim_id(target, (text or "").strip()),
                               source=source, after=after)

    def retract_id(self, target: str, cid: str, *, source: str = "",
                   after: Optional[Sequence[str]] = None) -> Optional[str]:
        projection = self.resolve(target)
        candidates = (list(projection.live) + list(projection.superseded)
                      # A claim awaiting an answer can be retracted too — that
                      # is what "no, forget it" is, and it must land as a
                      # record rather than as the question quietly going away.
                      + [q.claim for q in projection.pending_revivals])
        standing = None
        for candidate in candidates:
            if candidate.id == cid:
                standing = candidate
                break
        if standing is None:
            return None
        self.append(KIND_CLAIM, self.claim_body(RETRACT, cid, target, source, key=standing.key),
                    after=self.frontier() if after is None else after)
        return cid

    def unreadable(self, target: str) -> List[str]:
        """Claim ids standing for ``target`` that this reader cannot open —
        sealed under a ``moe:memory`` key it does not hold (§13.4)."""
        return list(self.resolve(target).unreadable)

    def reassert_retired(self, targets: Optional[Sequence[str]] = None) -> List[str]:
        """Re-assert, under the CURRENT key, every claim only a retired key opens.

        CLOUD-PLAN §15.1, the half that makes memory actually converge. A Mac
        that ran Moe free sealed its claims under the key it honestly minted
        for itself; joining a tenant adopts the tenant's key and retires that
        one, so this Mac still reads its own past — and **nobody else ever
        will.** The record sits on the shared chain sealed under a key that
        exists on exactly one device: the founder says "I don't know" about a
        fact this Mac remembers, and if this Mac dies the fact is gone. §15.1
        said that content reached the tenant "through the document path",
        which it does not: ``MEMORY.md`` is a projection, not one of the
        ``document`` names, so nothing carried it.

        What this appends is a NEW ``claim`` record carrying the same text
        sealed under the current key. It is **not** a re-seal: the signed,
        append-only chain is untouched and the old records stay exactly as
        they are. The claim id is a hash of the normalised words, so the
        re-assertion carries the SAME id, and §3.1's rules then treat it as
        the same claim with a newer record — which is the mechanism this
        leans on rather than one it works around. ``after`` names the record
        being re-stated, so the two are causally ordered rather than
        concurrent, and ``source`` and the topic label are preserved, so a
        re-asserted claim resolves exactly as the original did.

        **Idempotent by construction, and deliberately with no marker.** The
        condition acted on is "a device holding only the current key cannot
        read this claim's text" — which the re-assertion itself makes false,
        because the newest record of that id then opens under the current
        key. Run it twice and the second run finds nothing. A once-only
        marker, which is what :meth:`migrate_legacy` needs, would have been
        wrong here: adoption happens in Swift and can happen at any time,
        including long after such a marker was written, and the flag would
        then skip the very claims it exists for.

        Returns the claim ids re-asserted.
        """
        if not self.seals:
            # Nothing to seal WITH: a plaintext copy would never be pushed
            # (§13.3), so it would not reach the founder either.
            return []
        opening = self.opening_keys
        if len(opening) < 2:
            # No retired history, so there is nothing this can find — and
            # this runs on the session-start path, where two extra resolves
            # per target on a twenty-thousand-record ledger is a cost worth
            # not paying for the Macs that never joined from free.
            return []
        current = self.key
        records = self.records()
        done: List[str] = []
        for target in (self.targets() if targets is None else targets):
            # What a device holding only the tenant's key makes of the same
            # records. Its `unreadable` is precisely "stands, and says
            # nothing to anybody else": `resolve` already lends one readable
            # record's text to every other record of the same claim id, so a
            # claim that any current-key record also carries is not in it.
            theirs = resolve(records, target, [current])
            stranded = set(theirs.unreadable)
            if not stranded:
                continue
            for claim in resolve(records, target, opening).live:
                if claim.id not in stranded:
                    continue
                # Only what STANDS. A claim awaiting an answer (§3.1's
                # pending revival) is a question this device has to put to
                # the person, not a fact — re-asserting it would move the
                # question to another device rather than answer it, and that
                # is a decision for whoever builds the question queue.
                label = claim.key if claim.key != claim.id else None
                self.append(KIND_CLAIM,
                            self.claim_body(ASSERT, claim.id, target, claim.source,
                                            claim.text, label),
                            after=[claim.record_id])
                done.append(claim.id)
        if done:
            logger.info("claimstore: re-asserted %d claim(s) that only a retired %s key "
                        "opened, so every device in the tenant can read them (§15.1)",
                        len(done), MEMORY_KEY_ID)
        return done

    # -- §13.1 migration ----------------------------------------------------

    def migrate_legacy(self, peers_path: Optional[Path] = None) -> Dict[str, Any]:
        """Re-assert, once, what was live under this plugin's old ``hermes-``
        ids as sealed claims under the shared device id.

        A ``hermes-*.jsonl`` is legacy when its device is not this one, is
        not in the peer book (an enrolled machine's own prefix is ``hermes-``
        too — the peer book is what tells them apart), holds claim records
        and holds no turns. With an unreadable peer book the last two tests
        stand alone, and the log says so. Each live claim whose winning
        record is legacy is re-asserted with ``after`` naming that record and
        ``source``/``key`` preserved; the same claim id makes old and new one
        claim, so nothing is doubled. Each claim id whose winning state is
        *retracted* by a legacy tombstone gets one ``retract`` (no text) with
        ``after`` naming that tombstone, so the deletion travels as well as
        the fact — otherwise a machine that never held the old file would
        take the model's restatement as new. ``claimstore-migrated.json``
        (``from``, ``at``, ``claims``, ``retractions``) is written either
        way, so this never runs twice.
        """
        marker = self.directory / MIGRATION_MARKER
        report: Dict[str, Any] = {"from": [], "claims": 0, "retractions": 0, "skipped": ""}
        if marker.exists():
            report["skipped"] = "already migrated"
            return report
        if not self.seals:
            report["skipped"] = "no moe:memory key to seal with"
            logger.warning("claimstore: legacy hermes-* claims are not migrated yet: %s",
                           report["skipped"])
            return report
        peers, peers_readable = _read_peer_book(peers_path)
        if not peers_readable:
            logger.warning("claimstore: the peer book at %s is unreadable; migrating only "
                           "hermes-* files that hold claims and no turns", peers_path)
        self.refresh()
        legacy: List[str] = []
        for name, entry in sorted(self._files.items()):
            if not name.startswith(LEGACY_DEVICE_PREFIX):
                continue
            records = entry["records"]
            devices = {str(r.get("device")) for r in records}
            if not devices or self.device in devices or devices & peers:
                continue
            if any(r.get("kind") == "turn" for r in records):
                continue
            if not any(parse_claim(r) for r in records):
                continue
            legacy.extend(sorted(devices))
        records = self.records()
        legacy_ids = {r["id"] for r in records if r.get("device") in legacy}
        migrated = 0
        retracted = 0
        for target in self.targets():
            projection = self.resolve(target)
            for live in projection.live:
                if live.record_id not in legacy_ids:
                    continue
                label = live.key if live.key != live.id else None
                self.append(KIND_CLAIM, self.claim_body(ASSERT, live.id, target, live.source,
                                                        live.text, label),
                            after=[live.record_id])
                migrated += 1
            # The deletions travel too. A fact the person retracted under
            # the old id would otherwise exist nowhere the machine can see:
            # the model restates it there, it is live on the machine, and the
            # Mac sees a restatement causally after a tombstone the machine
            # never held — a question on one side, a fact on the other. One
            # ``retract`` per legacy claim id whose winning state is
            # retracted, ``after`` naming the legacy tombstone, ``source``
            # preserved, no text (a retract seals nothing, §13.4), puts the
            # tombstone on the shared chain; a restatement anywhere is then
            # causally after a tombstone both sides hold.
            standing = ({c.id for c in projection.live}
                        | {c.id for c in projection.superseded}
                        | {q.id for q in projection.pending_revivals}
                        | set(projection.unreadable))
            tombstones: Dict[str, Tuple[Dict[str, Any], Dict[str, Any]]] = {}
            for record in records:
                claim = parse_claim(record)
                if not claim or claim["op"] != RETRACT or claim["target"] != target:
                    continue
                # The newest retract of each id, in ledger order.
                tombstones[claim["claim"]] = (record, claim)
            for cid, (tombstone, claim) in tombstones.items():
                if tombstone["id"] not in legacy_ids or cid in standing:
                    continue
                label = claim["key"] if claim["key"] != cid else None
                self.append(KIND_CLAIM, self.claim_body(RETRACT, cid, target, claim["source"],
                                                        key=label),
                            after=[tombstone["id"]])
                retracted += 1
        report["from"] = legacy
        report["claims"] = migrated
        report["retractions"] = retracted
        try:
            marker.write_text(json.dumps({"from": legacy, "at": format_timestamp(time.time()),
                                          "claims": migrated, "retractions": retracted},
                                         indent=2, sort_keys=True) + "\n",
                              encoding="utf-8")
            os.chmod(str(marker), 0o600)
        except OSError:
            logger.warning("claimstore: could not write %s; the migration will be retried "
                           "(harmless: same claim ids)", marker, exc_info=True)
        if legacy:
            logger.info("claimstore: migrated %d live claim(s) and %d retraction(s) from %s "
                        "under device %s", migrated, retracted, ", ".join(legacy), self.device)
        return report

    # There is deliberately no ``retract_matching`` here.
    #
    # It used to sweep the whole live set for a substring, which looked like
    # the memory tool's own addressing and is not: the tool removes exactly one
    # *file* entry and refuses when several match, and the file is a digest —
    # a deliberate subset of the live set (that is what ``prefetch`` exists
    # for). So one ``memory(remove, old_text="Kaplan")`` could reach claims
    # neither the person nor the model could see, and take the ledger from two
    # live claims to zero.
    #
    # Retracting what was *addressed* needs the digest, so it lives with the
    # projection: ``projection.retract_addressed``.
