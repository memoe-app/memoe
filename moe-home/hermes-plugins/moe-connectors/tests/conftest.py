"""A person is at the screen, unless a test says otherwise.

`make_handler` holds a send for the owner when the fork's `turn_presence`
says nobody started this turn (hold_for_owner). Under pytest there is no
turn at all, so the real answer is "not live" and every send test would be
held rather than run. The held path has tests of its own that set the
verdict they need; everything else runs as a person's live turn — which is
the path where the card, not this plugin, is the gate.
"""

import pytest


@pytest.fixture(autouse=True)
def _hermes_home_is_not_this_macs(monkeypatch, tmp_path_factory):
    """HERMES_HOME is a scratch directory, unless a test sets its own.

    `tools/recipients.py` decides whether Hermes keeps recipient ledgers
    partly from the installed Hermes itself —
    `$HERMES_HOME/hermes-agent/agent/recipient_grounding.py` — and
    `hermes_home()` falls back to `~/.hermes`. Every `Home` here points
    MOE_HOME at a temp directory and left HERMES_HOME alone, so a send in a
    test was judged by whichever Hermes the developer happened to have
    installed: with none, or an old one, grounding read "off" and the send
    ran; with the pinned one it read "on", found no conversation key, and
    eight tests about argv, stdin and the origin label failed on "Moe could
    not check who asked for this recipient" (measured 2026-11-12).

    The tests that are about grounding set HERMES_HOME themselves and pin
    grounding on in the owner record; they are untouched by this.
    """
    monkeypatch.setenv("HERMES_HOME", str(tmp_path_factory.mktemp("hermes-home")))


@pytest.fixture(autouse=True)
def _a_person_is_present(monkeypatch):
    try:
        import tools.browser_chrome_extension as presence
    except Exception:
        return
    monkeypatch.setattr(presence, "turn_presence",
                        lambda: {"live": True, "why": "the person's own turn"})
