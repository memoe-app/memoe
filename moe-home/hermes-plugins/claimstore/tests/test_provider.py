"""The provider against the MemoryProvider seam: lifecycle, hooks, discovery."""

import shutil

import pytest

import claimstore
from claimstore import projection
from claimstore.store import ClaimStore


def test_provider_projects_on_initialize(provider, hermes_home):
    provider.store.assert_claim("memory", "learned elsewhere", source="other-device")
    provider.on_session_switch("session-2")
    entries = projection.parse_entries(
        (hermes_home / "memories" / "MEMORY.md").read_text(encoding="utf-8")
    )
    assert entries == ["learned elsewhere"]


def test_a_change_from_another_writer_between_turns_is_not_drift(
    provider, ledger_dir, hermes_home, memory_store
):
    """The scenario the whole design is for."""
    provider.store.assert_claim("memory", "fact from this device", source="hermes")
    provider.on_session_switch("session-2")

    # Another process appends while this one is idle.
    ClaimStore(ledger_dir, device="cloud-w7").assert_claim(
        "memory", "fact from the other device", source="other")

    # Next session boundary: reconcile.
    provider.on_session_switch("session-3")

    builtin = memory_store()
    assert builtin.memory_entries == ["fact from this device", "fact from the other device"]
    result = builtin.replace("memory", "other device", "fact from the other device (revised)")
    assert result["success"] is True, result.get("error")
    assert list((hermes_home / "memories").glob("*.bak.*")) == []


def test_on_memory_write_captures_builtin_writes(provider):
    provider.on_memory_write("add", "memory", "a fact", {"write_origin": "assistant_tool"})
    assert provider.store.live("memory") == ["a fact"]

    provider.on_memory_write(
        "replace", "memory", "a revised fact",
        {"write_origin": "assistant_tool", "old_text": "a fact"},
    )
    assert provider.store.live("memory") == ["a revised fact"]

    provider.on_memory_write(
        "remove", "memory", "", {"write_origin": "user", "old_text": "revised"},
    )
    assert provider.store.live("memory") == []


def test_on_memory_write_records_provenance(provider):
    provider.on_memory_write("add", "user", "likes terse answers",
                             {"write_origin": "background_review"})
    record = provider.store.claim_records("user")[-1]
    assert record["body"]["source"] == "hermes:background_review"
    assert record["body"]["target"] == "user"


def test_a_memory_tool_write_cannot_revive_what_the_person_deleted(provider, ledger_dir):
    """The one this design must not get wrong.

    Delete a fact about yourself; later the model calls ``memory(add)`` on its
    own initiative with the same words. It must not come back. ``write_origin``
    defaults to ``assistant_tool`` — the model deciding unprompted — and
    ``background_review`` and ``side_question`` are the only other producers.
    None of them is a person asking.

    Nor is ``agent_context`` a safety net for this: it has one producer in
    Hermes core and it is hardcoded ``"primary"``, so the branch that refuses
    non-primary writes is one production never takes.

    The write is still recorded. It becomes a question.
    """
    provider.on_memory_write("add", "memory", "I work at Kaplan", {})
    # The other device holds moe:memory (the courier delivered it), so it
    # can read the sealed claim and retract it.
    ClaimStore(ledger_dir, device="cloud-w7", keyring=provider.keyring).retract_claim(
        "memory", "I work at Kaplan", source="user")
    provider.store.refresh()
    assert provider.store.live("memory") == []

    provider.on_memory_write("add", "memory", "I work at Kaplan",
                             {"write_origin": "assistant_tool"})
    assert provider.store.live("memory") == [], (
        "the assistant restored a fact the person deleted, unasked"
    )
    pending = provider.store.resolve("memory").pending_revivals
    assert [q.source for q in pending] == ["hermes:assistant_tool"]

    # …and it never reaches the file either.
    provider.on_session_switch("s2")
    assert "Kaplan" not in projection.memory_path("memory").read_text(encoding="utf-8")
    assert [q["text"] for q in provider.pending_revivals] == ["I work at Kaplan"]


def test_no_write_origin_hermes_produces_counts_as_the_person(provider, ledger_dir):
    """The matrix, at the seam that produces these sources."""
    for origin in ("assistant_tool", "background_review", "side_question"):
        text = "deleted then restated by %s" % origin
        provider.on_memory_write("add", "memory", text, {"write_origin": origin})
        ClaimStore(ledger_dir, device="cloud-w7", keyring=provider.keyring).retract_claim(
            "memory", text, source="user")
        provider.store.refresh()
        provider.on_memory_write("add", "memory", text, {"write_origin": origin})
        assert text not in provider.store.live("memory"), origin
        assert text in [q.text for q in provider.store.resolve("memory").pending_revivals]


def test_a_removal_reaches_only_the_entry_the_tool_addressed(provider, hermes_home, monkeypatch):
    """Blocker: one ``remove`` used to sweep the whole live set.

    The digest is a deliberate subset of the live set, so a substring sweep
    routinely reaches claims neither the person nor the model can see.
    """
    import tools.memory_tool as memory_tool

    monkeypatch.setattr(memory_tool, "get_builtin_memory_config",
                        lambda config=None: {"memory_char_limit": 40, "user_char_limit": 40})
    provider.on_memory_write("add", "memory", "I work at Kaplan", {})
    provider.on_memory_write("add", "memory", "the Kaplan deadline is in March", {})
    provider.on_session_switch("s2")
    assert projection.digest_entries(provider.store, "memory") == [
        "the Kaplan deadline is in March"]

    provider.on_memory_write("remove", "memory", "", {"old_text": "Kaplan"})
    assert provider.store.live("memory") == ["I work at Kaplan"], (
        "a removal reached a claim that was never in the file"
    )


def test_on_memory_write_ignores_untracked_targets(hermes_home, ledger_dir, monkeypatch):
    monkeypatch.setattr(
        claimstore, "_config",
        lambda: {"ledger_dir": str(ledger_dir), "targets": ["memory"]},
    )
    provider = claimstore.ClaimStoreProvider()
    provider.initialize("s", hermes_home=str(hermes_home), agent_context="primary")
    provider.on_memory_write("add", "user", "not tracked", {})
    assert provider.store.live("user") == []


def test_non_primary_context_never_writes(hermes_home, ledger_dir, monkeypatch):
    """A cron or subagent run reads the same memory but must not write to it."""
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    ClaimStore(ledger_dir, device="cloud-w7").assert_claim(
        "memory", "pre-existing", source="test")

    provider = claimstore.ClaimStoreProvider()
    provider.initialize("s", hermes_home=str(hermes_home), agent_context="cron")

    assert provider.store.live("memory") == ["pre-existing"], "still reads"
    assert not (hermes_home / "memories" / "MEMORY.md").exists(), "but projects nothing"

    provider.on_memory_write("add", "memory", "from cron", {})
    assert provider.store.live("memory") == ["pre-existing"], "and writes nothing"


def test_provider_exposes_no_tools(provider):
    assert provider.get_tool_schemas() == []


def test_system_prompt_block_is_static_and_short(provider):
    block = provider.system_prompt_block()
    assert "MEMORY STORE" in block
    assert block == provider.system_prompt_block(), "must be stable within a session"
    assert len(block) < 800


def test_disagreements_are_surfaced_rather_than_resolved(provider):
    provider.store.assert_claim("memory", "Izzy works at Kaplan", source="imessage", key="job")
    provider.store.assert_claim("memory", "Izzy works at Anthropic", source="gmail", key="job")
    provider.on_session_switch("s2")
    assert len(provider.disagreements) == 1
    assert provider.disagreements[0]["key"] == "job"
    assert sorted(provider.disagreements[0]["sources"]) == ["gmail", "imessage"]
    assert provider.disagreements[0]["target"] == "memory"


def test_prefetch_surfaces_claims_that_did_not_fit_in_the_digest(provider, hermes_home):
    provider.store.assert_claim("memory", "the staging cluster is in Frankfurt", source="test")
    provider.on_session_switch("s2")
    # Simulate a digest too small to hold it: empty the projected file.
    (hermes_home / "memories" / "MEMORY.md").write_text("", encoding="utf-8")

    out = provider.prefetch("where is the staging cluster hosted?")
    assert "Frankfurt" in out
    status = provider.recall_status()
    assert status is not None and status.count == 1


def test_prefetch_skips_claims_already_in_the_digest(provider):
    provider.store.assert_claim("memory", "the staging cluster is in Frankfurt", source="test")
    provider.on_session_switch("s2")
    assert provider.prefetch("where is the staging cluster?") == ""
    assert provider.recall_status() is None


def test_prefetch_ignores_trivial_prompts(provider):
    provider.store.assert_claim("memory", "thanks for the cluster in Frankfurt", source="test")
    assert provider.prefetch("thanks") == ""


def test_backup_paths_declares_the_ledger(provider, ledger_dir, monkeypatch):
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    assert provider.backup_paths() == [str(ledger_dir.resolve())]


def test_backup_paths_is_empty_for_a_ledger_inside_hermes_home(hermes_home, monkeypatch):
    inside = hermes_home / "ledger"
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(inside)})
    assert claimstore.ClaimStoreProvider().backup_paths() == []


def test_backup_paths_needs_no_initialize(hermes_home, ledger_dir, monkeypatch):
    """The ABC requires this to work from a cold start, config only."""
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    assert claimstore.ClaimStoreProvider().backup_paths() == [str(ledger_dir.resolve())]


def test_the_default_ledger_dir_is_moes_and_not_hermess(monkeypatch):
    monkeypatch.setattr(claimstore, "_config", lambda: {})
    monkeypatch.setenv("MOE_HOME", "/tmp/some-moe")
    assert str(claimstore.resolve_ledger_dir()) == "/tmp/some-moe/ledger"


def test_is_available_honours_the_disable_switch(hermes_home, ledger_dir, monkeypatch):
    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    assert claimstore.ClaimStoreProvider().is_available() is True
    monkeypatch.setattr(
        claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir), "enabled": False},
    )
    p = claimstore.ClaimStoreProvider()
    assert p.is_available() is False
    assert "enabled is false" in p.unavailable_reason()


def test_config_schema_is_well_formed(provider):
    keys = {field["key"] for field in provider.get_config_schema()}
    assert keys == {"ledger_dir", "peers_path", "targets", "recall_limit"}
    assert all("description" in field for field in provider.get_config_schema())


def test_save_config_writes_under_memory_claimstore(hermes_home, tmp_path):
    yaml = pytest.importorskip("yaml")
    provider = claimstore.ClaimStoreProvider()
    provider.save_config(
        {"ledger_dir": "/tmp/ledger", "targets": "memory,user", "recall_limit": 5},
        str(hermes_home),
    )
    written = yaml.safe_load((hermes_home / "config.yaml").read_text(encoding="utf-8"))
    section = written["memory"]["claimstore"]
    assert section["ledger_dir"] == "/tmp/ledger"
    assert section["targets"] == ["memory", "user"]
    assert section["recall_limit"] == 5


def test_shutdown_projects_a_final_time(provider, hermes_home):
    provider.store.assert_claim("memory", "learned late in the session", source="test")
    provider.shutdown()
    assert "learned late" in (hermes_home / "memories" / "MEMORY.md").read_text(encoding="utf-8")


# --- the real discovery path -------------------------------------------------

def test_provider_loads_through_hermes_plugin_discovery(hermes_home, monkeypatch):
    """Installed to $HERMES_HOME/plugins/, Hermes finds and loads it."""
    from agent.memory_provider import MemoryProvider

    src = __import__("pathlib").Path(claimstore.__file__).resolve().parent
    dest = hermes_home / "plugins" / "claimstore"
    shutil.copytree(src, dest, ignore=shutil.ignore_patterns("tests", "__pycache__"))

    import plugins.memory as memory_plugins

    assert "claimstore" in memory_plugins.list_memory_provider_names()
    loaded = memory_plugins.load_memory_provider("claimstore")
    assert isinstance(loaded, MemoryProvider)
    assert loaded.name == "claimstore"


def test_memory_manager_accepts_the_provider(provider):
    """It satisfies the manager's contract, including the write bridge."""
    from agent.memory_manager import MemoryManager

    manager = MemoryManager()
    manager.add_provider(provider)
    assert manager.providers == [provider]
    assert "MEMORY STORE" in manager.build_system_prompt()
    assert manager.get_all_tool_schemas() == []

    manager.notify_memory_tool_write(
        {"success": True},
        {"action": "add", "target": "memory", "content": "via the bridge"},
    )
    assert "via the bridge" in provider.store.live("memory")


def test_first_run_adopts_an_existing_memory_file_without_losing_it(
    hermes_home, ledger_dir, monkeypatch, memory_store
):
    """Installing the plugin on a machine that already has memory must not wipe it."""
    (hermes_home / "memories" / "MEMORY.md").write_text(
        "an existing fact\n§\nanother existing fact", encoding="utf-8"
    )
    (hermes_home / "memories" / "USER.md").write_text("prefers tea", encoding="utf-8")

    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")

    assert p.store.live("memory") == ["an existing fact", "another existing fact"]
    assert p.store.live("user") == ["prefers tea"]
    builtin = memory_store()
    assert builtin.memory_entries == ["an existing fact", "another existing fact"]
    assert builtin.user_entries == ["prefers tea"]


def test_adoption_reads_the_ledger_a_bounded_number_of_times(
    hermes_home, ledger_dir, monkeypatch
):
    """Adoption used to cost one full re-read and re-sort *per absorbed entry*.

    Measured before this test existed: 2.54 s for thirty entries against a
    twenty-thousand-record ledger, synchronously inside ``initialize()`` — on
    exactly the first-run path adoption is about, on exactly the machine that
    has enough history for it to hurt.

    Asserting on work rather than on wall-clock, so it is a regression test
    and not a flaky benchmark: ``assert_claim`` resolves the whole ledger to
    decide one claim, and ``append`` used to throw the parsed order away, so
    the count is what actually changed.
    """
    import json as _json

    ledger_dir.mkdir(parents=True)
    lines = []
    prev = None
    for i in range(400):
        body = {"op": "assert", "claim": "%012x" % i, "target": "user",
                "source": "crawl", "text": "background fact %d" % i}
        unsigned = {"kind": "claim", "at": "2026-08-30T10:%02d:%02d.000Z" % (i // 60, i % 60),
                    "device": "mac-9f3c1a2b", "seq": i + 1, "after": [], "body": body}
        if prev:
            unsigned["prev"] = prev
        from claimstore.store import record_id
        rid = record_id(unsigned)
        record = dict(unsigned, id=rid)
        prev = rid
        lines.append(_json.dumps(record, sort_keys=True, separators=(",", ":")))
    (ledger_dir / "mac-9f3c1a2b.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")

    entries = ["adopted fact %d" % i for i in range(30)]
    (hermes_home / "memories" / "MEMORY.md").write_text("\n\u00a7\n".join(entries),
                                                        encoding="utf-8")

    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")

    assert p.store.live("memory") == entries, "adoption still has to work"
    assert p.store.full_reads <= 4, (
        "adoption re-read the whole ledger %d times for 30 entries" % p.store.full_reads
    )


def test_first_run_alongside_an_existing_conversation_ledger(
    hermes_home, ledger_dir, monkeypatch, memory_store
):
    """The ledger is not empty on a real Mac — it is full of conversations.

    Records of kinds this plugin does not read must be carried, ordered and
    left alone, and must not become memory.
    """
    import json

    ledger_dir.mkdir(parents=True)
    (ledger_dir / "mac-9f3c1a2b.jsonl").write_text("\n".join(json.dumps(r) for r in [
        {"id": "aaaa", "kind": "turn", "at": "2026-08-30T10:00:00.000Z",
         "device": "mac-9f3c1a2b", "seq": 1, "after": [],
         "body": {"thread": "th-1", "turn_id": "t1", "role": "you",
                  "at": "2026-08-30T10:00:00.000Z", "text": "hello"}},
        {"id": "bbbb", "kind": "thread.delete", "at": "2026-08-30T10:05:00.000Z",
         "device": "mac-9f3c1a2b", "seq": 2, "prev": "aaaa", "after": ["aaaa"],
         "body": {"thread": "th-2"}},
    ]) + "\n", encoding="utf-8")
    (hermes_home / "memories" / "MEMORY.md").write_text("an existing fact", encoding="utf-8")

    monkeypatch.setattr(claimstore, "_config", lambda: {"ledger_dir": str(ledger_dir)})
    p = claimstore.ClaimStoreProvider()
    p.initialize("s1", hermes_home=str(hermes_home), agent_context="primary")

    assert p.store.live("memory") == ["an existing fact"]
    carried = [r for r in p.store.records() if r["kind"] != "document"]
    assert len(carried) == 3, "the conversation records are still there"
    # §13.1: no device.json, so the plugin minted the Mac's id and its own
    # file; the app's file (from a device that is not this one) is untouched.
    assert (ledger_dir / "mac-9f3c1a2b.jsonl").read_text(encoding="utf-8").count("\n") == 2
    assert p.store.device.startswith("mac-") and p.store.device != "mac-9f3c1a2b"
    assert (ledger_dir / "device.json").exists()


# ── recall: stop words, rarity, and the person's own words ──────────────────
#
# Recall was the top three claims by raw word overlap. "What do you know about
# the accountant" matched every claim holding "what", "you" or "the", and the
# one about the accountant lost on count. And the query was the turn as Moe
# sent it — the person's words plus the whole "# Before you answer" reminder —
# so every question was also a search for "spoken" and "sentence".

def _undigested(provider, hermes_home, *texts, target="memory"):
    """Claims that are live but did not fit the digest — what recall is for."""
    for text in texts:
        provider.store.assert_claim(target, text, source="test")
    provider.on_session_switch("s2")
    for name in ("MEMORY.md", "USER.md"):
        (hermes_home / "memories" / name).write_text("", encoding="utf-8")


FILLER = [f"{who} asked about what you sent the {what} (note {i})"
          for i, (who, what) in enumerate(
              (w, x) for w in ("Dana", "Marcus", "the client", "the landlord")
              for x in ("team", "office", "board", "bank", "school"))]


def test_recall_is_not_won_by_the_words_every_claim_has(provider, hermes_home):
    _undigested(provider, hermes_home, *FILLER,
                "Priya is the accountant and prefers email over calls")
    out = provider.prefetch("what do you know about the accountant")
    lines = out.splitlines()[1:]
    assert lines == ["- (memory) Priya is the accountant and prefers email over calls"], out
    assert provider.recall_status().count == 1


def test_a_question_made_only_of_stop_words_recalls_nothing(provider, hermes_home):
    _undigested(provider, hermes_home, *FILLER)
    assert provider.prefetch("what about the other one, and then what did you do") == ""
    assert provider.recall_status() is None


def test_the_rare_word_outranks_the_common_one(provider, hermes_home):
    """Weight is measured in the store: "penicillin" is in one claim, "Dana"
    in five. By raw overlap they tie at one word each, the tie goes to the
    oldest, and the five "Dana" claims fill all three places — the claim
    about penicillin is never recalled at all. Weighted, it comes first."""
    _undigested(provider, hermes_home, *FILLER, "allergic to penicillin since childhood")
    out = provider.prefetch("does Dana know about penicillin")
    assert out.splitlines()[1] == "- (memory) allergic to penicillin since childhood", out


def test_a_word_in_most_of_the_store_weighs_nothing(provider, hermes_home):
    """The person's own name is in half their memory. It cannot pick a claim."""
    _undigested(provider, hermes_home, *[f"Dana {i} likes item {i}" for i in range(12)],
                "the cabin wifi password is on the fridge")
    assert provider.prefetch("Dana") == "" or provider.prefetch("tell me about Dana") == ""
    assert "fridge" in provider.prefetch("Dana wants the wifi password")
    assert len(provider.prefetch("Dana wants the wifi password").splitlines()) == 2


def test_plurals_and_possessives_meet(provider, hermes_home):
    _undigested(provider, hermes_home, "Dana's dentist is Dr. Okafor", "the weekly meetings moved to Tuesday")
    assert "Okafor" in provider.prefetch("who is the dentist for Dana")
    assert "Tuesday" in provider.prefetch("when is the weekly meeting")


def test_recall_reads_the_persons_words_not_moes_wrapping(provider, hermes_home):
    """The turn as Moe sends it. Nothing in the reminder may recall a claim."""
    reminder = ("\n\n# Before you answer\n\nNow: Thursday 12 November 2026, 9:04 AM.\n\n"
                "You are spoken aloud; say a plain sentence before you go quiet, and "
                "pages are markdown links with a Sources: line after a web lookup.")
    _undigested(provider, hermes_home,
                "prefers a plain spoken sentence to markdown links and sources",
                "the staging cluster is hosted in Frankfurt")
    out = provider.prefetch("where is the staging cluster hosted" + reminder)
    assert out.splitlines()[1:] == ["- (memory) the staging cluster is hosted in Frankfurt"], out


def test_what_is_recalled_is_the_stored_text_verbatim(provider, hermes_home):
    """Tokens are folded to match; the claim is never rewritten."""
    text = "Dana's  Meetings — the WEEKLY ones — are on Tuesdays"
    _undigested(provider, hermes_home, text)
    stored = provider.store.live("memory")[-1]
    out = provider.prefetch("when are the weekly meetings")
    assert out.splitlines()[1] == f"- (memory) {stored}"


def test_recall_keeps_the_limit_and_the_oldest_first_tie_break(provider, hermes_home):
    _undigested(provider, hermes_home, *[f"the Lisbon trip needs item {i}" for i in range(5)],
                *[f"unrelated fact number {i} here" for i in range(20)])
    lines = provider.prefetch("what does the Lisbon trip need").splitlines()[1:]
    assert lines == [f"- (memory) the Lisbon trip needs item {i}" for i in range(3)]


def test_rank_claims_is_pure_and_dependency_free():
    import claimstore
    corpus = ["alpha beta", "alpha gamma", "alpha delta", "epsilon zeta"]
    got = claimstore.rank_claims(claimstore._tokens("alpha zeta"), corpus,
                                 [("memory", t) for t in corpus], 2)
    assert [t for _, _, t in got] == ["epsilon zeta", "alpha beta"]
    assert claimstore.rank_claims(set(), corpus, [("memory", "alpha beta")], 3) == []
    assert claimstore.rank_claims({"alpha"}, corpus, [], 3) == []
    assert claimstore._tokens("What do YOU know about the") == frozenset()
