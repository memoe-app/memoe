"""claimstore — Hermes's memory, stored in Moe's ledger.

What it changes
---------------
Normally ``MEMORY.md`` and ``USER.md`` *are* the memory. With this provider
active they become a **projection**: the store is ``~/.moe/ledger/*.jsonl`` —
the same append-only, causally ordered log Moe's Swift side writes
conversations into (``docs/ONE-AGENT.md`` §1.5) — and the two markdown files
are the slice of it that fits in the prompt. Three properties follow, and they
are the reason to want this at all:

1. **Another writer is the normal case.** Any process that can append a record
   — Moe itself, a sync daemon, a second device, another agent, a person in an
   editor — contributes memory. The provider reconciles at every session
   boundary.
2. **Nothing is lost to a rewrite.** Claims are content-addressed and
   retraction is a record, not an edit. Two devices that learn the same fact
   mint the same claim id and converge with no merge step. §3.1's claim rules
   decide what the *digest* shows; nothing decides what is kept.
3. **The built-in memory tool keeps working, untouched.** The model still calls
   ``memory(action=add|replace|remove)``; those writes are captured back into
   the ledger through ``on_memory_write``. No core file is patched, and the
   drift guard is respected rather than worked around (see ``projection.py``).
4. **It travels (LEDGER-WIRE §13).** Claims are written under the Mac's own
   device id, on the app's ``seq`` chain, with their text sealed under the
   ``moe:memory`` key, so the app pushes them to the person's other devices
   as its own; whole files the machine must have — ``SOUL.md``,
   ``~/.moe/CLAUDE.md``, the learned profile, ``skills.disabled`` — travel as
   ``document`` records, and what arrives from elsewhere is applied here at
   ``initialize`` and ``prefetch``. The sealing and the document rules come
   from the sibling ``moe-ledger`` plugin's library; without it, memory
   still works, plaintext and local.

Install
-------
Moe's installer does this: ``scripts/install.sh`` lays the directory down in
``~/.moe/hermes-plugins/`` and ``~/.moe/hermes/configure-hermes.py`` copies it
to ``$HERMES_HOME/plugins/claimstore/``, adds ``claimstore`` to
``plugins.enabled`` and writes::

    memory:
      provider: claimstore
      claimstore:
        ledger_dir: ~/.moe/ledger
        peers_path: ~/.moe/cloud/peers.json   # default: <ledger_dir>/../cloud/peers.json
        targets: [memory, user]
        recall_limit: 3

By hand it is a ``cp -R`` and those five lines. Installing onto a machine that
already has memory **adopts** it: the first projection absorbs whatever
``MEMORY.md`` and ``USER.md`` hold into the ledger before it writes anything,
so nothing a person or a previous Hermes wrote is lost.

Timing you should know about
----------------------------
The built-in memory snapshot that enters the system prompt is frozen at session
start, and Hermes loads it *before* memory providers initialize
(``agent/agent_init.py``: ``load_from_disk()`` precedes ``initialize_all()``).
A claim that arrives from elsewhere therefore reaches the **prompt** at the
next session start, not mid-session. That is Hermes's documented design — the
frozen snapshot is what keeps the prefix cache alive for a whole session — and
this provider does not fight it. What it does guarantee is that the *files on
disk* are current from the moment the provider initializes, so the memory tool
itself (which re-reads under lock on every mutation) and the next prompt build
both see the newest claims.
"""

from __future__ import annotations

import logging
import math
import re
from pathlib import Path
from typing import Any, Dict, List, Optional

from agent.memory_provider import MemoryProvider, RecallStatus, is_trivial_prompt

from ._sibling import moeledger as _moeledger
from . import store as _store_module
from .store import ClaimStore, MEMORY_KEY_ID, claim_id, normalise
from .projection import TARGETS, project_all, memory_path, report_summary, retract_addressed
from . import overflow as _overflow
from . import learn_turn as _learn_turn
from . import channel_spool as _channel_spool

logger = logging.getLogger(__name__)

PROVIDER_NAME = "claimstore"
DEFAULT_RECALL_LIMIT = 3
#: This projector's record of which document sha it last applied or wrote
#: (§13.5), beside the digest marker under ``$HERMES_HOME``.
DOCUMENTS_STATE = "claimstore-documents.json"
_WORD_RE = re.compile(r"[\w']+", re.UNICODE)

# Contexts whose writes must not reach a person's memory. The ABC asks
# providers to skip non-primary contexts; a cron or flush agent's system
# prompt is not the user talking.
_WRITE_CONTEXTS = {"primary", ""}


def _config() -> Dict[str, Any]:
    """Return the ``memory.claimstore`` config section (never raises)."""
    try:
        from hermes_cli.config import cfg_get, load_config_readonly

        section = cfg_get(load_config_readonly(), "memory", PROVIDER_NAME, default={})
        return section if isinstance(section, dict) else {}
    except Exception:
        logger.debug("claimstore: config unreadable", exc_info=True)
        return {}


def _default_ledger_dir() -> Path:
    """``$MOE_HOME/ledger``, or ``~/.moe/ledger``.

    Not under ``$HERMES_HOME``: the ledger is Moe's, it holds conversations as
    well as memory, and Hermes is one of several writers to it.
    """
    import os

    home = os.environ.get("MOE_HOME") or str(Path.home() / ".moe")
    return Path(home).expanduser() / "ledger"


def resolve_ledger_dir(config: Optional[Dict[str, Any]] = None) -> Path:
    """Where the ledger lives. Config-only — no init, no network.

    ``backup_paths()`` depends on this being resolvable from a cold start.
    """
    section = _config() if config is None else config
    raw = section.get("ledger_dir")
    if isinstance(raw, str) and raw.strip():
        return Path(raw.strip()).expanduser()
    return _default_ledger_dir()


def _sweep_module():
    """moe-screen's ``sweep`` beside this plugin, loaded as a package member
    so its ``from . import deliver`` resolves; None when it is not there.
    Cached on the synthetic package, so the ledger code is loaded once."""
    import importlib.util
    import sys
    import types

    d = Path(__file__).resolve().parent.parent / "moe-screen"
    if not (d / "sweep.py").is_file():
        return None
    name = "moe_screen_for_sweep"
    pkg = sys.modules.get(name)
    if pkg is None:
        pkg = types.ModuleType(name)
        pkg.__path__ = [str(d)]
        sys.modules[name] = pkg
    mod = sys.modules.get(name + ".sweep")
    if mod is None:
        spec = importlib.util.spec_from_file_location(name + ".sweep", str(d / "sweep.py"))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name + ".sweep"] = mod
        spec.loader.exec_module(mod)
    return mod


def _default_moe_home() -> Path:
    import os

    return Path(os.environ.get("MOE_HOME") or str(Path.home() / ".moe")).expanduser()


def resolve_peers_path(config: Optional[Dict[str, Any]] = None,
                       ledger_dir: Optional[Path] = None) -> Path:
    """Where the app's peer book is (§3.4): ``memory.claimstore.peers_path``,
    or ``<ledger dir>/../cloud/peers.json`` — ``~/.moe/cloud/peers.json`` on
    a Mac. Read only: by the §13.1 migration, to tell a legacy ``hermes-*``
    file of this plugin's from an enrolled machine's, and by the §13.2 mint
    guard, to tell a first run from a keyring that was lost."""
    section = _config() if config is None else config
    raw = section.get("peers_path")
    if isinstance(raw, str) and raw.strip():
        return Path(raw.strip()).expanduser()
    base = ledger_dir if ledger_dir is not None else resolve_ledger_dir(section)
    return base.parent / "cloud" / "peers.json"


def resolve_targets(config: Optional[Dict[str, Any]] = None) -> List[str]:
    section = _config() if config is None else config
    raw = section.get("targets")
    if isinstance(raw, str):
        raw = [part.strip() for part in raw.split(",")]
    if not isinstance(raw, (list, tuple)) or not raw:
        return list(TARGETS)
    targets = [str(t).strip() for t in raw if str(t).strip() in TARGETS]
    return targets or list(TARGETS)


#: Words that say nothing about which fact is wanted. Recall used to count
#: them: the top three claims by raw word overlap, so "what do you know about
#: the accountant" was answered with three claims that happened to contain
#: "what", "you" and "the", and the one about the accountant lost on count.
#:
#: Deliberately short and English-only. It is a floor, not the mechanism —
#: the mechanism is the rarity weighting in ``rank_claims``, which is computed
#: from the store and so finds the common words of whatever language and
#: whatever names the store is actually written in. This list is what makes a
#: store of twenty claims behave before it is big enough to say what is common.
STOP_WORDS = frozenset("""
a about after again all also am an and any are as at be because been before
being both but by can could did do does doing done for from get got had has
have having he her here hers him his how i if in into is it its just know let
like me more most my no not now of off on one only or other our ours out over
own she so some such tell than that the their theirs them then there these
they this those to too under up us very was we were what when where which
while who whom whose why will with would you your yours
""".split())

#: A word in more than this share of the live claims is common *in this
#: store* — the person's own name, usually — and cannot tell one claim from
#: another. Only once the store is big enough for a share to mean something.
COMMON_SHARE = 0.5
COMMON_MIN_CLAIMS = 8


def _stem(word: str) -> str:
    """"meetings" and "meeting", "Dana's" and "Dana": one word. Nothing
    cleverer — a real stemmer is a dependency, and the cost of this one being
    crude is a missed match, never a wrong claim rewritten: only the tokens
    are folded, the stored text is returned verbatim."""
    if word.endswith("'s") or word.endswith("’s"):
        word = word[:-2]
    if len(word) > 3 and word.endswith("s") and not word.endswith("ss"):
        word = word[:-1]
    return word


def _tokens(text: str) -> frozenset:
    """The words of ``text`` that could identify a fact: lowercased, folded,
    with the stop words and the one- and two-letter words gone."""
    out = set()
    for raw in _WORD_RE.findall(text or ""):
        low = raw.lower().strip("'")
        if len(low) <= 2 or low in STOP_WORDS:
            continue
        word = _stem(low)
        if len(word) > 2 and word not in STOP_WORDS:
            out.add(word)
    return frozenset(out)


def rank_claims(wanted, corpus, candidates, limit, tokens_of=_tokens):
    """The ``limit`` best of ``candidates`` for the words ``wanted``.

    ``corpus`` is every live claim's text — the store itself, which is where
    "rare" is measured: a word's weight is ``ln(1 + N / df)``, so a word in
    one claim of six hundred outweighs a dozen words that are in half of
    them, and a word in more than ``COMMON_SHARE`` of the store weighs
    nothing at all. ``candidates`` is ``[(target, text)]``, the claims that
    may be surfaced (those not already in the prompt).

    A claim's score is the weight of the query's words it holds. Ties keep
    the order they came in, oldest first, as before. Returns
    ``[(score, target, text)]`` — the text exactly as stored.
    """
    wanted = frozenset(wanted)
    if not wanted or limit <= 0:
        return []
    df: Dict[str, int] = {}
    n = 0
    for text in corpus:
        n += 1
        for word in tokens_of(text) & wanted:
            df[word] = df.get(word, 0) + 1
    if not df:
        return []
    weight: Dict[str, float] = {}
    for word, count in df.items():
        if n >= COMMON_MIN_CLAIMS and count > n * COMMON_SHARE:
            continue
        weight[word] = math.log(1.0 + n / count)
    if not weight:
        return []
    scored = []
    for target, text in candidates:
        score = sum(weight.get(word, 0.0) for word in tokens_of(text) & wanted)
        if score > 0:
            scored.append((score, target, text))
    scored.sort(key=lambda item: -item[0])
    return scored[:limit]


class ClaimStoreProvider(MemoryProvider):
    """Owns Hermes's end of the ledger; projects its claims onto the memory files."""

    def __init__(self, ledger_dir: Optional[Path] = None) -> None:
        self._store: Optional[ClaimStore] = None
        self._ledger_dir: Optional[Path] = ledger_dir
        self._targets: List[str] = list(TARGETS)
        self._recall_limit = DEFAULT_RECALL_LIMIT
        self._session_id = ""
        self._writes_enabled = True
        self._last_recall_count = 0
        self._disagreements: List[Dict[str, Any]] = []
        self._pending_revivals: List[Dict[str, Any]] = []
        self._keyring = None
        self._documents = None      # (Sources, State) once initialized with the library
        self._hermes_home: Optional[Path] = None
        self._peers_path: Optional[Path] = None

    @property
    def name(self) -> str:
        return PROVIDER_NAME

    # -- lifecycle ----------------------------------------------------------

    def is_available(self) -> bool:
        """Local-only: available unless explicitly disabled, or unwritable.

        No network and no imports beyond the standard library, per the ABC.
        """
        section = _config()
        if section.get("enabled") is False:
            return False
        try:
            path = resolve_ledger_dir(section)
            # Available if the ledger exists, or its parent can hold it.
            return path.exists() or path.parent.exists() or path.parent.parent.exists()
        except Exception:
            return False

    def unavailable_reason(self) -> str:
        section = _config()
        if section.get("enabled") is False:
            return "memory.claimstore.enabled is false in config.yaml"
        return (
            "the configured memory.claimstore.ledger_dir is not in a directory "
            "that can be created"
        )

    def initialize(self, session_id: str, **kwargs) -> None:
        section = _config()
        self._session_id = session_id or ""
        self._platform = str(kwargs.get("platform") or "")
        self._chat_id = str(kwargs.get("chat_id") or "")
        self._chat_type = str(kwargs.get("chat_type") or "")
        self._agent_context = str(kwargs.get("agent_context") or "")
        self._targets = resolve_targets(section)
        self._recall_limit = self._resolve_recall_limit(section)
        if self._ledger_dir is None:
            self._ledger_dir = resolve_ledger_dir(section)
        self._peers_path = resolve_peers_path(section, self._ledger_dir)
        home = kwargs.get("hermes_home")
        self._hermes_home = Path(str(home)).expanduser() if home else self._resolve_hermes_home()
        # §13.1: one device per Mac — the app's device.json and seq chain.
        # This projector's own state (digest marker, documents state) goes
        # under HERMES_HOME, because it is about this projector, not the store.
        self._keyring = self._open_keyring()
        self._store = ClaimStore(self._ledger_dir, state_dir=self._hermes_home,
                                 keyring=self._keyring)
        self._documents = self._open_documents()

        context = str(kwargs.get("agent_context") or "")
        self._writes_enabled = context in _WRITE_CONTEXTS
        if not self._writes_enabled:
            # A subagent/cron/flush run reads the same memory but must not
            # write into a person's ledger. What arrived from elsewhere is
            # still applied to the files: that is reading the ledger, not
            # writing it.
            self._store.refresh()
            self._apply_documents("session-start")
            return
        # Memory saves never fail (docs/DEFAULTS.md row 39): a memory-tool
        # write refused for want of room is taken into the ledger by the
        # middleware in overflow.py — only for a provider that may write.
        _overflow.bind(self)
        # §13.2: whichever writer first needs the memory key mints it
        # (``.fileWins``, so the app's wins if it got there first) — unless
        # the keyring looks like one that *had* the key and lost it.
        self._mint_memory_key()
        try:
            report = self._store.migrate_legacy(self._peers_path)
            if report.get("from"):
                logger.info("claimstore: §13.1 migration: %s", report)
        except Exception:
            logger.warning("claimstore: the legacy migration failed; it will be retried",
                           exc_info=True)
        # §15.1: adoption happens in Swift, in the courier, and says nothing
        # to this side — so this side has to NOTICE the situation instead of
        # being told about it, and session start is where the store already
        # walks its records for the migration above. It is idempotent by
        # construction rather than by a marker, which matters because
        # adoption can happen at any time, long after any marker was written.
        try:
            self._store.reassert_retired()
        except Exception:
            logger.warning("claimstore: re-asserting claims sealed under a retired key "
                           "failed; it will be retried next session", exc_info=True)
        # Reader before writer: what arrived is applied before local sources
        # are hashed, so a local edit never overwrites a newer record.
        self._apply_documents("session-start")
        self._project("session-start")
        self._write_documents("session-start")

    def _mint_memory_key(self) -> bool:
        """Mint ``moe:memory`` (§13.2) — or wait for it to come back.

        A second mint of one id is the one thing this key must never
        suffer: a peer that holds the first mint would seal under it while
        this Mac seals under the second, and every claim would be unreadable
        on one side for good. So minting is refused when the keyring looks
        like one that *had* a key and lost it **and** there is somebody to
        get it back from — ``peers.json`` names at least one non-revoked
        peer; the machine's hourly reseal (``Courier.redeliver``) returns
        every key it holds, including this one, and the app's next collect
        installs it. "Lost" is either of:

        * a ``thread-keys.json.damaged.*`` beside the keyring — the app set
          aside a keyring it could not parse; its keys are in that file and
          on every peer, not gone;
        * the keyring file *absent* — a tenant with a history and no keys is
          a file that was lost, not one never written.

        With no peer nobody can deliver, so a Mac mints even over a damaged
        marker (the alternative is memory that never starts). A keyring that
        is present — thread keys, a peer, no ``moe:memory`` yet — is the
        ordinary live tenant that has not needed memory before, and mints.
        Returns whether the key is held afterwards.
        """
        if self._keyring is None:
            return False
        # The rule itself lives in `moeledger.vault.mint_reserved` — it was
        # written out here and again in Swift, and a rule whose failure is
        # silent and permanent must not have three readings that can drift.
        # What stays here is what is particular to claims: the consequence.
        try:
            from moeledger.vault import mint_reserved
        except ImportError:
            return False
        return mint_reserved(
            self._keyring, MEMORY_KEY_ID, self._peers_path,
            log=lambda why: logger.warning(
                "claimstore: %s; claims stay plaintext and local until it does", why))

    @staticmethod
    def _resolve_hermes_home() -> Path:
        import os

        try:
            from hermes_constants import get_hermes_home

            return Path(str(get_hermes_home())).expanduser()
        except Exception:
            return Path(os.environ.get("HERMES_HOME") or "~/.hermes").expanduser()

    def _open_keyring(self):
        """``<ledger dir>/thread-keys.json`` under the §2.2 file protocol —
        ``moeledger.vault.Keyring`` rooted at the ledger dir, the same file
        and lock the app uses. None without the sibling library."""
        lib = _moeledger()
        if lib is None:
            return None
        try:
            return lib.vault.Keyring(Path(self._ledger_dir) / "thread-keys.json")
        except Exception:
            logger.warning("claimstore: could not open the keyring", exc_info=True)
            return None

    def _open_documents(self):
        lib = _moeledger()
        if lib is None or self._hermes_home is None:
            return None
        docs = lib.documents
        sources = docs.Sources(self._hermes_home, _default_moe_home(),
                               config_path=self._hermes_home / "config.yaml")
        # S2: a Mac applies a `cron/<id>` only from a CLOUD device. Without
        # this the default names none, every reminder said to the machine
        # was "ignored on a Mac" — and, until documents.py stopped
        # recording an ignored write as applied, then sealed as REMOVED,
        # which deleted it on the machine too (2026-09-25).
        sources.cloud_devices = self._cloud_device_ids
        state = docs.State(self._hermes_home / DOCUMENTS_STATE)
        return (sources, state)

    #: As moe-ledger's: asked only when a `cron/<id>` from another device
    #: arrives, so an ordinary turn costs nothing.
    _CLOUD_DEVICES_TTL_S = 3600.0

    def _cloud_device_ids(self) -> set:
        """The tenant's cloud device ids, from the edge's `GET /v1/devices`
        (it carries `runtime`), cached an hour. The Mac's own enrolment is
        what this reads — `cloudEdge` in ``$MOE_HOME/config.json`` and the
        token in ``$MOE_HOME/cloud/credential.json``, the pair
        `moe-ticket.py` and the relay rule read. Empty when either is
        missing or the edge cannot be asked, which keeps a foreign cron
        document unapplied and unremembered — tried again on the next pull,
        never sealed as removed."""
        import json
        import time

        now = time.time()
        cached = getattr(self, "_cloud_devices_cache", None)
        if cached is not None and now - cached[0] < self._CLOUD_DEVICES_TTL_S:
            return cached[1]
        lib = _moeledger()
        if lib is None:
            return set()
        home = _default_moe_home()
        try:
            from moeledger import relayconfig as _relay
            from moeledger.client import EdgeClient
            try:
                edge = json.loads((home / "config.json").read_text(encoding="utf-8")).get("cloudEdge")
            except (OSError, ValueError):
                edge = None
            token = _relay.credential_token(str(home / "cloud" / "credential.json"))
            if not edge or not token:
                return set()
            client = EdgeClient(_relay.check_edge_url(edge), token)
            found = {str(d.get("device_id")) for d in client.devices()
                     if d.get("runtime") == "cloud" and not d.get("revoked_at")
                     and d.get("device_id")}
        except Exception:  # noqa: BLE001
            logger.info("claimstore: could not read the device list to tell the machine's "
                        "reminders from another Mac's; none applied this time", exc_info=True)
            return cached[1] if cached is not None else set()
        self._cloud_devices_cache = (now, found)
        return found

    # -- documents (§13.5) --------------------------------------------------

    def _apply_documents(self, reason: str) -> List[str]:
        """The reader rule: the app's CloudSync pulls records into the ledger
        dir; ``refresh()`` sees them; the newest ``document`` of each name
        that this side has not applied or written is written to its file."""
        if self._store is None or self._documents is None:
            return []
        lib = _moeledger()
        sources, state = self._documents
        try:
            bodies = lib.documents.document_bodies(self._store.records())
            # `opening_keys`, not `key`: reading a document must try the key
            # this Mac retired when it joined a tenant as well as the
            # tenant's own (§15.1), or the `soul` and `profile` it sealed
            # while it ran free are unreadable here — and an unreadable
            # newest document shadows every older readable one.
            applied = lib.documents.apply_documents(bodies, sources, state,
                                                    self._store.opening_keys)
            if applied:
                logger.info("claimstore: applied document(s) %s (%s)", ", ".join(applied), reason)
            return applied
        except Exception:
            logger.warning("claimstore: applying documents failed (%s)", reason, exc_info=True)
            return []

    def _write_documents(self, reason: str) -> List[str]:
        """The writer rule: a source whose hash differs from what this side
        last applied or wrote becomes a new sealed ``document`` record.

        Two name sets are skipped at session START: the skills (D5), and
        the §14.4a capability tables. Reading them means asking every connector its own `status`,
        which is 2.25 s on a real Mac with twelve of them — nothing on a
        background pass, and far too much on the notch's first turn, which
        is the one path here that has to feel instant. They are written at
        session end and shutdown instead, where nobody is waiting, and the
        reader trusts a table for seven days so the delay costs nothing.
        """
        if self._store is None or self._documents is None or not self._writes_enabled:
            return []
        lib = _moeledger()
        sources, state = self._documents
        store = self._store
        names = None
        if reason == "session-start":
            capability_names = set(lib.documents.capability.CAPABILITY_NAMES)
            # Skills too (D5): every one is read and hashed, and a first pass
            # seals about 3 MB — session end and shutdown carry them.
            names = [n for n in sources.names() if n not in capability_names
                     and not n.startswith("skill/")]
            if lib.documents.capability.publishes_here():
                # A reminder that fired or was deleted is no longer listed, and
                # only a visit seals its removal. Left to session end and
                # shutdown — which on a Mac that stays up can be days apart —
                # the machine kept being handed reminders whose time had gone.
                names += lib.documents.remembered_to_visit(state, names, sources.hermes_home)
        try:
            written = lib.documents.write_documents(
                sources, state, store.key,
                lambda body: store.append(lib.records.KIND_DOCUMENT, body,
                                          after=store.frontier()),
                names=names)
            if written:
                logger.info("claimstore: wrote document(s) %s (%s)", ", ".join(written), reason)
            return written
        except Exception:
            logger.warning("claimstore: writing documents failed (%s)", reason, exc_info=True)
            return []

    @staticmethod
    def _resolve_recall_limit(section: Dict[str, Any]) -> int:
        try:
            value = int(section.get("recall_limit", DEFAULT_RECALL_LIMIT))
        except (TypeError, ValueError):
            return DEFAULT_RECALL_LIMIT
        return max(0, min(value, 20))

    def shutdown(self) -> None:
        _overflow.unbind(self)
        self._project("shutdown")
        self._write_documents("shutdown")

    # -- projection ---------------------------------------------------------

    def _project(self, reason: str) -> List[Dict[str, object]]:
        if self._store is None or not self._writes_enabled:
            return []
        reports = project_all(self._store, self._targets)
        self._disagreements = [
            dict(d, target=report["target"])
            for report in reports for d in (report.get("disagreements") or [])
        ]
        self._pending_revivals = [
            dict(q, target=report["target"])
            for report in reports for q in (report.get("asked") or [])
        ]
        unreadable = 0
        for target in self._targets:
            try:
                unreadable += len(self._store.unreadable(target))
            except Exception:
                pass
        if unreadable:
            logger.info("claimstore: %d claim(s) are sealed under a %s key this Mac does not "
                        "hold; counted, not projected", unreadable, MEMORY_KEY_ID)
        for report in reports:
            if report.get("skipped"):
                # Not debug. This is the one file the person reads, and a
                # refusal means it is now out of date with no other sign.
                logger.warning("claimstore: %s was not projected (%s); its memory file is "
                               "stale", report["target"], report["skipped"])
            elif report.get("written") or report.get("absorbed"):
                logger.debug("claimstore: projection (%s) %s", reason,
                             report_summary(report))
        if self._disagreements:
            # §3.2: the person is told, rather than one side quietly winning.
            # There is no queue to put this in yet — see ONE-AGENT §14.4.
            logger.info("claimstore: %d topic(s) two sources read differently: %s",
                        len(self._disagreements),
                        ", ".join(sorted({str(d["key"]) for d in self._disagreements})))
        return reports

    @property
    def store(self) -> Optional[ClaimStore]:
        """The live ledger, for tests and for a host embedding this plugin."""
        return self._store

    @property
    def disagreements(self) -> List[Dict[str, Any]]:
        """Topics two sources read differently, as of the last projection.

        Both readings are in the digest and both are in the ledger; this is
        the list that should reach a person (§3.2).
        """
        return list(self._disagreements)

    @property
    def pending_revivals(self) -> List[Dict[str, Any]]:
        """Deleted facts something has stated again since, as of the last
        projection.

        Each is a question — *"you deleted that before, want me to remember it
        again?"* — and not an entry: none of these is in the digest, and none
        of them will be until somebody with a real signal that the person said
        yes asserts it with a ``user`` source. The record is in the ledger
        either way, so nothing is restored silently and nothing is dropped
        silently. Building the asking is the next slice (§14.4); this is the
        seam it attaches to.
        """
        return list(self._pending_revivals)

    # -- reads --------------------------------------------------------------

    def system_prompt_block(self) -> str:
        if self._store is None:
            return ""
        return (
            "MEMORY STORE\n"
            "Your MEMORY.md and USER.md are a digest of a shared, append-only "
            "claim log that other writers (your other devices, background jobs, "
            "the user's own edits) also append to. Keep using the memory tool "
            "normally — every write you make is recorded as a claim. Facts that "
            "arrived from elsewhere appear at the start of a session, not "
            "mid-conversation. Write entries as facts about the person "
            "(\"Prefers action over explanation\"), never \"I\", \"me\" or "
            "\"my\": they read them as their own.\n\n"
            # Where this copy is. claimstore is the Mac's memory provider (the
            # cloud copy runs moe-ledger, which says its own), and a provider's
            # block reaches every route on the Mac — the notch and Telegram
            # alike — where AGENTS.md reaches only the notch.
            "WHERE YOU ARE\n"
            "You run on the person's own Mac and may use all of it: files, apps, "
            "browser, mail, calendar, messages, a shell and the screen. If they also "
            "have Moe in the cloud, that copy answers while the Mac sleeps and hands "
            "you what only the Mac can do. To them you are one Moe."
        )

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        """Surface claims that did not fit in the digest but match the query.

        The ledger holds more than the prompt budget allows, so a fact can be
        live and still be absent from ``MEMORY.md``. This is a cheap local
        keyword pass over exactly those claims — no network, no model call.
        """
        self._last_recall_count = 0
        if self._store is None or self._recall_limit <= 0 or is_trivial_prompt(query):
            return ""
        try:
            if self._store.refresh():
                # The app pulled something since we last looked: apply any
                # document that arrived before the next turn is built.
                self._apply_documents("prefetch")
            wanted = _tokens(self._persons_words(query))
            if not wanted:
                return ""
            corpus: List[str] = []
            candidates = []
            for target in self._targets:
                try:
                    projected = set(self._projected_entries(target))
                except Exception:
                    projected = set()
                for text in self._store.live(target):
                    corpus.append(text)
                    if text in projected:
                        continue  # already in the prompt via the digest
                    candidates.append((target, text))
            picked = rank_claims(wanted, corpus, candidates, self._recall_limit,
                                 tokens_of=self._claim_tokens)
            if not picked:
                return ""
            self._last_recall_count = len(picked)
            lines = [f"- ({target}) {text}" for _, target, text in picked]
            return "RECALLED CLAIMS (not in the memory digest):\n" + "\n".join(lines)
        except Exception:
            logger.debug("claimstore: prefetch failed", exc_info=True)
            return ""

    @staticmethod
    def _persons_words(query: str) -> str:
        """What the person said, out of the turn as Moe sent it.

        The turn Hermes hands over is the person's words wrapped in Moe's:
        the Now line, the brief, and several hundred to several thousand
        characters of "# Before you answer". Recall matched all of it, so
        every question was also a search for "spoken", "sentence", "answer"
        and "sources" — and any three claims holding those outranked the one
        that was asked about. moe-screen's sweep already knows how to cut a
        turn down to the person (it is how the learner finds their words);
        without it beside this plugin, the turn is used as it came."""
        try:
            mod = _sweep_module()
            reader = getattr(mod, "persons_words", None) if mod is not None else None
            if reader is None:
                return query
            # Nothing left is a turn the person did not write — a background
            # note, a scheduled job's prompt. Its own words are the query.
            return reader(query) or query
        except Exception:
            logger.debug("claimstore: could not cut the turn to the person's words", exc_info=True)
            return query

    def _claim_tokens(self, text: str) -> frozenset:
        """``_tokens`` of a claim, remembered. Claim texts are immutable and
        every prefetch reads all of them, so each is split once per process
        rather than once per question."""
        cache = self.__dict__.setdefault("_token_cache", {})
        found = cache.get(text)
        if found is None:
            if len(cache) > 20000:      # a bound, not a policy: start over
                cache.clear()
            found = cache[text] = _tokens(text)
        return found

    @staticmethod
    def _projected_entries(target: str) -> List[str]:
        from .projection import parse_entries

        try:
            return parse_entries(memory_path(target).read_text(encoding="utf-8"))
        except (FileNotFoundError, OSError):
            return []

    def recall_status(self) -> Optional[RecallStatus]:
        if not self._last_recall_count:
            return None
        return RecallStatus(provider_label="claimstore", count=self._last_recall_count)

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        """No tools. The built-in memory tool is the write surface.

        Adding a second one would put two ways to write memory in front of the
        model and cost tool-schema budget for nothing: everything the model
        writes through ``memory`` already lands in the ledger.
        """
        return []

    # -- writes -------------------------------------------------------------

    def on_memory_write(self, action: str, target: str, content: str,
                        metadata: Optional[Dict[str, Any]] = None) -> None:
        """Capture a built-in memory tool write as a claim.

        This is what keeps the ledger a superset of the files: the model's own
        edits become claims immediately, so the next projection reproduces them
        rather than overwriting them.

        **The ``hermes:`` source is provenance and nothing more.** It does not
        revive a retraction. It is tempting to read a memory-tool write as
        "the user told the Mac to remember it again", which is §3.1's own
        worked example — but the three ``write_origin`` values Hermes produces
        are ``assistant_tool`` (the default: the model, on its own
        initiative), ``background_review`` and ``side_question``, and none of
        them means a person asked. A fact somebody deleted about themselves
        being quietly restored because the assistant noticed it again is the
        worst thing this design could do. Such a write becomes a
        ``PendingRevival`` instead: the record is kept, the claim stays out of
        the digest, and Moe can ask.

        Removals retract what the tool *addressed* — the one digest entry its
        ``old_text`` matched — not every live claim containing that substring.
        See ``projection.retract_addressed``.
        """
        if self._store is None or not self._writes_enabled:
            return
        if target not in self._targets:
            return
        if _learn_turn.no_memory():  # "Don't remember this chat": no claim from this turn
            logger.info("claimstore: memory write not kept — %s", _learn_turn.NOT_REMEMBERED)
            return
        metadata = metadata or {}
        source = "hermes:" + str(metadata.get("write_origin") or "assistant_tool")
        old_text = str(metadata.get("old_text") or "")
        try:
            if action == "add":
                self._store.assert_claim(target, content, source=source)
            elif action == "replace":
                if old_text:
                    retract_addressed(self._store, target, old_text, source=source)
                self._store.assert_claim(target, content, source=source)
            elif action == "remove":
                needle = old_text or content
                retract_addressed(self._store, target, needle, source=source)
        except Exception:
            logger.debug("claimstore: on_memory_write(%s) failed", action, exc_info=True)

    def sync_turn(self, user_content: str, assistant_content: str, *,
                  session_id: str = "", messages: Optional[List[Dict[str, Any]]] = None,
                  **kwargs) -> None:
        """Per-turn learning (learn_turn.py): what the person just said, kept.

        Hermes runs this on its memory worker after the reply has gone, so a
        slow model call here costs the next turn's sync, never a reply. Only
        where this provider may write, only on a turn the person started
        (``learn_turn.refusal``: not a helper's result or any other turn the
        app sends on its own, not a cron run, not a bot), and never with
        Background thinking off.

        First, and whatever the learning gates say: a chat turn the Mac
        answered is queued for the ledger (``channel_spool``), so Away has the
        conversation too. History is not learning — Background thinking off
        does not take the words out of the person's own history."""
        self._spool_turn(user_content, assistant_content)
        if self._store is None or not self._writes_enabled:
            return
        why_not = _learn_turn.refusal(platform=getattr(self, "_platform", ""),
                                      turn_author=kwargs.get("turn_author"))
        if why_not:
            logger.info("claimstore: turn learning: not read — %s", why_not)
            return
        _learn_turn.learn_from_turn(self._store, user_content, assistant_content,
                                    targets=self._targets, call=self._turn_call(),
                                    sweep=_sweep_module())

    def _spool_turn(self, user_content: str, assistant_content: str) -> None:
        try:
            why_not = _channel_spool.wanted(getattr(self, "_platform", ""),
                                            getattr(self, "_chat_type", ""),
                                            getattr(self, "_agent_context", ""))
            if why_not:
                return
            if _learn_turn.no_memory():
                logger.info("claimstore: chat turn not queued — %s", _learn_turn.NOT_REMEMBERED)
                return
            if _channel_spool.append(_default_moe_home(), platform=self._platform,
                                     chat_id=getattr(self, "_chat_id", ""),
                                     user=user_content or "", assistant=assistant_content or ""):
                logger.info("claimstore: %s turn queued for the ledger", self._platform)
        except Exception as e:  # noqa: BLE001 — never out of sync_turn
            logger.warning("claimstore: chat turn not queued: %s: %s", type(e).__name__, e)

    @staticmethod
    def _turn_call():
        """The model call per-turn learning makes (a seam for tests)."""
        return _learn_turn.default_call

    def on_session_switch(self, new_session_id: str, *, parent_session_id: str = "",
                          reset: bool = False, rewound: bool = False, **kwargs) -> None:
        """Re-reconcile at a session boundary.

        A session boundary is exactly when a claim written elsewhere can reach
        the prompt, so it is exactly when the digest should be rebuilt.
        """
        self._session_id = new_session_id or self._session_id
        if self._store is None:
            return
        if self._store.refresh():
            self._apply_documents("session-switch")
        self._project("session-switch")

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        self._project("session-end")
        self._write_documents("session-end")
        # The sweep (docs/LOOPS.md §2): once the conversation is over, one
        # small-model read over what the person said, for the loops the
        # brain did not write down in the turn. It lives in moe-screen, which
        # owns the ledger; this is the one hook that is handed the messages.
        self._sweep_loops(messages)

    def _sweep_loops(self, messages) -> None:
        try:
            mod = _sweep_module()
            if mod is not None:
                mod.sweep(messages)
        except Exception as e:  # noqa: BLE001 — never out of a session-end hook
            logger.info("claimstore: loop sweep skipped: %s: %s", type(e).__name__, e)

    @property
    def keyring(self):
        """The §2.2 keyring at ``<ledger dir>/thread-keys.json`` (or None)."""
        return self._keyring

    # -- host integration ---------------------------------------------------

    def backup_paths(self) -> List[str]:
        """Declare the ledger, which lives in ``~/.moe`` rather than in HERMES_HOME."""
        try:
            path = resolve_ledger_dir()
            try:
                from hermes_constants import get_hermes_home

                home = Path(str(get_hermes_home())).resolve()
            except Exception:
                return [str(path)]
            resolved = path.expanduser().resolve()
            if home in resolved.parents:
                return []  # already inside the backup root
            return [str(resolved)]
        except Exception:
            return []

    def get_config_schema(self) -> List[Dict[str, Any]]:
        return [
            {
                "key": "ledger_dir",
                "description": "Moe's append-only ledger directory (one JSONL file per device)",
                "default": "~/.moe/ledger",
            },
            {
                "key": "peers_path",
                "description": "The app's peer book (§3.4), read by the §13.1 migration and "
                               "the §13.2 mint guard",
                "default": "~/.moe/cloud/peers.json",
            },
            {
                "key": "targets",
                "description": "Built-in stores to project onto",
                "default": "memory,user",
            },
            {
                "key": "recall_limit",
                "description": "Claims outside the digest to surface per turn (0 disables)",
                "default": str(DEFAULT_RECALL_LIMIT),
                "type": "integer",
                "minimum": 0,
                "maximum": 20,
            },
        ]

    def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
        """Write non-secret config to ``config.yaml`` under ``memory.claimstore``."""
        try:
            try:
                import yaml
            except ImportError:
                # Hermes's own venv has no PyYAML; hermes_yaml is its (ruamel) reader.
                import hermes_yaml as yaml
            from hermes_cli.config import read_user_config_raw

            config_path = Path(hermes_home) / "config.yaml"
            existing = read_user_config_raw(config_path) or {}
            memory_section = existing.setdefault("memory", {})
            if not isinstance(memory_section, dict):
                memory_section = {}
                existing["memory"] = memory_section
            current = memory_section.get(PROVIDER_NAME)
            merged = dict(current) if isinstance(current, dict) else {}
            merged.update(values or {})
            if isinstance(merged.get("targets"), str):
                merged["targets"] = [
                    t.strip() for t in merged["targets"].split(",") if t.strip()
                ]
            memory_section[PROVIDER_NAME] = merged
            with open(config_path, "w", encoding="utf-8") as handle:
                yaml.safe_dump(existing, handle, default_flow_style=False)
        except Exception:
            logger.debug("claimstore: save_config failed", exc_info=True)


def register(ctx) -> None:
    """Register claimstore as a memory provider plugin — and the middleware
    that turns a memory-tool save refused for want of room into a save
    (``overflow.py``, docs/DEFAULTS.md row 39)."""
    ctx.register_memory_provider(ClaimStoreProvider())
    _overflow.register(ctx)


__all__ = ["ClaimStoreProvider", "ClaimStore", "claim_id", "normalise", "register",
           "resolve_ledger_dir", "resolve_peers_path"]


# -- job-time travel (status #7, 2026-09-29) --------------------------------


def _mirror_peer_turns(lib: Any, store: Any, keyring: Any, home: Path) -> int:
    """D3: Away's turns into this Mac's own search index, a bounded batch
    per engine tick (moeledger/mirror.py). Never raises."""
    import importlib
    import os
    if os.environ.get("MOE_MIRROR_CHATS", "1") == "0":
        return 0
    try:
        mirror = importlib.import_module(lib.__name__ + ".mirror")
        me = getattr(store, "device", None)
        if not me:
            return 0
        done = mirror.mirror(store.records(), keyring.key, me, home)
        return done.get("mirrored", 0)
    except Exception:  # noqa: BLE001 — a job's extra, never its failure
        logger.warning("claimstore: mirroring Away's chats into search failed", exc_info=True)
        return 0


def travel(names: List[str], *, receive: bool = True, send: bool = True,
           hermes_home: Optional[Path] = None, ledger_dir: Optional[Path] = None) -> Dict[str, Any]:
    """The background engine's own documents, carried at JOB time on a Mac
    rather than only at a session boundary (sessions here last hours or
    days). ``receive``: what CloudSync already pulled into the ledger dir is
    applied — for ``names`` only, so a job never acts on anything else (a
    reminder, the soul) with less than the provider knows. ``send``: those
    names are sealed when they changed, and the app is asked to push now
    (the pull marker CloudSync watches runs a pull AND a push). Never raises;
    returns what it did."""
    out: Dict[str, Any] = {"applied": [], "written": [], "nudged": False, "error": ""}
    lib = _moeledger()
    if lib is None:
        out["error"] = "no moeledger library"
        return out
    try:
        home = Path(hermes_home) if hermes_home else ClaimStoreProvider._resolve_hermes_home()
        ledger = Path(ledger_dir) if ledger_dir else resolve_ledger_dir(_config())
        keyring = lib.vault.Keyring(ledger / "thread-keys.json")
        store = ClaimStore(ledger, state_dir=home, keyring=keyring)
        docs = lib.documents
        sources = docs.Sources(home, _default_moe_home(), config_path=home / "config.yaml")
        state = docs.State(home / DOCUMENTS_STATE)
        wanted = set(names)
        if receive:
            store.refresh()
            bodies = [b for b in docs.document_bodies(store.records())
                      if isinstance(b, dict) and (b.get("name") in wanted
                                                  or docs.travels_at_job_time(b.get("name")))]
            out["applied"] = docs.apply_documents(bodies, sources, state, store.opening_keys)
            out["mirrored"] = _mirror_peer_turns(lib, store, keyring, home)
        # A Mac with no Away has nobody to send to: nothing is sealed, or its
        # own ledger would gain a copy of every change for nothing (review
        # 2026-09-29 #4).
        enrolled = (_default_moe_home() / "cloud" / "credential.json").exists()
        if send and enrolled:
            # The Mac's jobs and their last results (D2) ride the engine's
            # tick too, so a job made or run here reaches Away in minutes.
            extra = [n for n in sources.names() if docs.travels_at_job_time(n, send=True)]
            out["written"] = docs.write_documents(
                sources, state, store.key,
                lambda body: store.append(lib.records.KIND_DOCUMENT, body, after=store.frontier()),
                names=list(names) + [n for n in extra if n not in names])
            if out["written"]:
                import importlib
                nudge = importlib.import_module(lib.__name__ + ".nudge")
                out["nudged"] = nudge.leave_marker(_default_moe_home(), None) is not None
    except Exception as e:  # noqa: BLE001 — a job's extra, never its failure
        out["error"] = "%s: %s" % (type(e).__name__, e)
        logger.warning("claimstore: job-time travel failed", exc_info=True)
    return out
