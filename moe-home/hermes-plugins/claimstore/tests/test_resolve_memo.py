"""ClaimStore.resolve is remembered until the ledger or the keys change.

A session start resolved fourteen times and every prefetch twice, each a full
§3.1 pass — a quarter of a second apiece on a 9,000-record ledger (measured
2026-11-08). These pin both halves: an unchanged ledger is not resolved
again, and any change — this writer's, another writer's, a retraction — is.
"""

from claimstore.store import ClaimStore


def test_an_unchanged_ledger_is_not_resolved_twice(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "fact one", source="user")
    first = store.resolve("memory")
    assert store.resolve("memory") is first


def test_this_writers_own_assert_and_retract_are_seen(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "fact one", source="user")
    assert store.live("memory") == ["fact one"]
    store.assert_claim("memory", "fact two", source="user")
    assert store.live("memory") == ["fact one", "fact two"]
    store.retract_claim("memory", "fact one", source="user")
    assert store.live("memory") == ["fact two"]


def test_another_writers_append_is_seen_after_a_refresh(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "fact one", source="user")
    assert store.live("memory") == ["fact one"]

    other = ClaimStore(ledger_dir, device="mac-00000002")
    other.assert_claim("memory", "from elsewhere", source="user")

    assert store.refresh() is True
    assert store.live("memory") == ["fact one", "from elsewhere"]


def test_targets_are_remembered_separately(ledger_dir):
    store = ClaimStore(ledger_dir)
    store.assert_claim("memory", "a memory", source="user")
    store.assert_claim("user", "a user fact", source="user")
    assert store.live("memory") == ["a memory"]
    assert store.live("user") == ["a user fact"]
    store.assert_claim("user", "another user fact", source="user")
    assert store.live("memory") == ["a memory"]
    assert store.live("user") == ["a user fact", "another user fact"]
