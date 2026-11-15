"""A chat turn the Mac answers is queued for the ledger (audit F1/F4/F5).

Before this the Mac wrote ledger turns only for the app's own conversations,
so a Telegram message the Mac answered, and every WhatsApp message, never
reached Away. The app drains the queue (ConversationLedger.importChannelTurns).
"""

import json

import pytest


@pytest.fixture
def enrolled(moe_home):
    (moe_home / "cloud").mkdir(parents=True, exist_ok=True)
    (moe_home / "cloud" / "credential.json").write_text("{}")
    return moe_home


def _provider(hermes_home, ledger_dir, monkeypatch, **kw):
    import claimstore
    monkeypatch.setattr(claimstore, "_config",
                        lambda: {"ledger_dir": str(ledger_dir), "targets": ["memory", "user"],
                                 "recall_limit": 3})
    monkeypatch.setattr(claimstore._learn_turn, "learn_from_turn", lambda *a, **k: None)
    p = claimstore.ClaimStoreProvider()
    p.initialize("session-1", hermes_home=str(hermes_home), **kw)
    return p


def _lines(moe_home):
    path = moe_home / "cloud" / "channel-turns.jsonl"
    if not path.exists():
        return []
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def test_a_telegram_turn_the_mac_answered_is_queued(enrolled, hermes_home, ledger_dir, monkeypatch):
    p = _provider(hermes_home, ledger_dir, monkeypatch, platform="telegram",
                  chat_id="100000001", chat_type="dm", agent_context="primary")
    p.sync_turn("hi", "Hello! What can I do for you?", session_id="s")
    got = _lines(enrolled)
    assert len(got) == 1, got
    assert got[0]["platform"] == "telegram" and got[0]["chat_id"] == "100000001"
    assert got[0]["you"] == "hi" and got[0]["moe"].startswith("Hello")
    assert got[0]["you_id"] != got[0]["moe_id"]
    assert oct((enrolled / "cloud" / "channel-turns.jsonl").stat().st_mode & 0o777) == "0o600"


def test_whatsapp_is_queued_even_with_background_thinking_off(enrolled, hermes_home, ledger_dir, monkeypatch):
    """History is not learning: the learning gates do not take the words out."""
    p = _provider(hermes_home, ledger_dir, monkeypatch, platform="whatsapp",
                  chat_id="15551234567@s.whatsapp.net", chat_type="dm", agent_context="primary")
    p._writes_enabled = False
    p.sync_turn("are we on for 6?", "Yes, 6 at the usual place.", session_id="s")
    assert [l["platform"] for l in _lines(enrolled)] == ["whatsapp"]


@pytest.mark.parametrize("kw,why", [
    (dict(platform="slack", chat_id="D1", chat_type="dm", agent_context="primary"), "slack"),
    (dict(platform="telegram", chat_id="-100", chat_type="group", agent_context="primary"), "group"),
    (dict(platform="telegram", chat_id="1", chat_type="dm", agent_context="cron"), "cron"),
    (dict(platform="api_server", chat_id="x", chat_type="dm", agent_context="primary"), "the app"),
])
def test_what_is_never_queued(enrolled, hermes_home, ledger_dir, monkeypatch, kw, why):
    p = _provider(hermes_home, ledger_dir, monkeypatch, **kw)
    p.sync_turn("hello", "hi", session_id="s")
    assert _lines(enrolled) == [], why


def test_nothing_is_queued_on_a_mac_with_nowhere_to_sync(moe_home, hermes_home, ledger_dir, monkeypatch):
    p = _provider(hermes_home, ledger_dir, monkeypatch, platform="telegram",
                  chat_id="1", chat_type="dm", agent_context="primary")
    p.sync_turn("hello", "hi", session_id="s")
    assert _lines(moe_home) == []


def test_a_chat_not_to_be_remembered_is_not_queued(enrolled, hermes_home, ledger_dir, monkeypatch):
    import claimstore
    monkeypatch.setattr(claimstore._learn_turn, "no_memory", lambda: True)
    p = _provider(hermes_home, ledger_dir, monkeypatch, platform="telegram",
                  chat_id="1", chat_type="dm", agent_context="primary")
    p.sync_turn("hello", "hi", session_id="s")
    assert _lines(enrolled) == []


def test_the_queue_is_capped(enrolled, monkeypatch):
    from claimstore import channel_spool as cs
    monkeypatch.setattr(cs, "MAX_LINES", 3)
    for i in range(5):
        cs.append(enrolled, platform="telegram", chat_id="1", user=f"m{i}", assistant="ok")
    assert [l["you"] for l in _lines(enrolled)] == ["m2", "m3", "m4"]


@pytest.mark.parametrize("platform", ["line", "moemail"])
def test_line_and_email_to_moe_answered_here_are_queued(enrolled, hermes_home, ledger_dir,
                                                        monkeypatch, platform):
    """Audit F7: relayed to the Mac under their own names now, so a private
    turn on either is the person talking and goes to the ledger."""
    p = _provider(hermes_home, ledger_dir, monkeypatch, platform=platform,
                  chat_id="c-1", chat_type="dm", agent_context="primary")
    p.sync_turn("can you move my 3pm?", "Moved to 4pm.", session_id="s")
    assert [l["platform"] for l in _lines(enrolled)] == [platform]
