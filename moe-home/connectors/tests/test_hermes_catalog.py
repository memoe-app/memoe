#!/usr/bin/env python3
"""`hermes-catalog.py` — the brokered (Composio) services, with and without a key.

The bug this holds shut: on a Mac that has never signed in there is no
Composio key, `composio.py list` has nothing to say, and the catalogue used
to list no brokered service at all — a stranger opened Connections and found
no Gmail, no Calendar, no Drive, only the app-password mailbox, and nothing
said that signing in would change it (2026-09-07). The release now carries a
snapshot of what a session offers; the live list wins for the slugs it
names and the snapshot fills in the rest.

Run: python3 -m unittest moe-home/connectors/tests/test_hermes_catalog.py
"""

import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "hermes-catalog.py")
spec = importlib.util.spec_from_file_location("moe_hermes_catalog", SRC)
cat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cat)

GOOGLE = ("gmail", "googlecalendar", "googledrive", "googledocs", "googlesheets",
          "googletasks", "googlemeet", "youtube")


class FakeRun:
    """A `subprocess.run` that answers `composio.py list --json` with rows."""

    def __init__(self, rows):
        self.rows = rows
        self.calls = 0

    def __call__(self, argv, **kw):
        self.calls += 1
        assert argv[-2:] == ["list", "--json"], argv

        class R:
            stdout = json.dumps({"connections": self.rows})
        return R()


class TestComposioEntries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["HERMES_HOME"] = self.tmp.name
        self._snapshot = cat.COMPOSIO_SNAPSHOT
        self._ranking = cat.COMPOSIO_RANKING
        self._run = cat.subprocess.run

    def tearDown(self):
        cat.COMPOSIO_SNAPSHOT = self._snapshot
        cat.COMPOSIO_RANKING = self._ranking
        cat.subprocess.run = self._run
        os.environ.pop("HERMES_HOME", None)
        self.tmp.cleanup()

    def _config_with_composio(self):
        with open(os.path.join(self.tmp.name, "config.yaml"), "w") as fh:
            fh.write("mcp_servers:\n  composio:\n    url: https://example.invalid\n")

    def test_the_shipped_snapshot_lists_every_google_service_without_a_key(self):
        # No config.yaml at all: the live path is never even attempted.
        cat.subprocess.run = lambda *a, **k: self.fail("composio.py must not run without a server")
        names = {e["name"]: e for e in cat.composio_entries()}
        for slug in GOOGLE:
            self.assertIn(slug, names, "the shipped snapshot has no %s" % slug)
            e = names[slug]
            self.assertEqual(e["kind"], "composio")
            self.assertEqual(e["auth"], "oauth")
            self.assertEqual(e["install"], "connect.sh composio/%s" % slug)
            self.assertEqual(e["source"], "composio-snapshot")
        self.assertGreater(len(names), 100, "the snapshot is a copy of Composio's answer, not a short list of ours")

    def test_the_live_list_wins_and_the_snapshot_fills_in_the_rest(self):
        self._config_with_composio()
        run = FakeRun([{"slug": "gmail", "label": "Gmail (live)"}, {"slug": "notion", "label": "Notion"}])
        cat.subprocess.run = run
        entries = cat.composio_entries()
        by = {e["name"]: e for e in entries}
        self.assertEqual(run.calls, 1)
        self.assertEqual(by["gmail"]["label"], "Gmail (live)")
        self.assertEqual(by["gmail"]["source"], "composio")
        self.assertEqual(by["googlecalendar"]["source"], "composio-snapshot")
        self.assertEqual([e["name"] for e in entries[:2]], ["gmail", "notion"], "live rows come first")
        self.assertEqual(len([e for e in entries if e["name"] == "gmail"]), 1, "one Gmail, not one per source")

    # The catalogue has a THIRD source since composio-ranking.json shipped:
    # composio_entries() ends by listing what the ranking names and neither
    # the live list nor the snapshot has (`"composio-ranking"`, hermes-catalog.py).
    # These two cases removed the snapshot only, so "the live list alone" came
    # back as 181 ranked rows and both failed. They take the ranking away too,
    # and the case after them says what the ranking adds when it is there.
    def _no_ranking(self):
        cat.COMPOSIO_RANKING = os.path.join(self.tmp.name, "no-ranking.json")

    def test_no_snapshot_means_the_live_list_alone_and_no_error(self):
        self._no_ranking()
        cat.COMPOSIO_SNAPSHOT = os.path.join(self.tmp.name, "missing.json")
        self.assertEqual(cat.composio_entries(), [])
        self._config_with_composio()
        cat.subprocess.run = FakeRun([{"slug": "slack", "label": "Slack"}])
        self.assertEqual([e["name"] for e in cat.composio_entries()], ["slack"])

    def test_a_broken_snapshot_is_a_shorter_list_not_an_error(self):
        broken = os.path.join(self.tmp.name, "broken.json")
        with open(broken, "w") as fh:
            fh.write("{not json")
        cat.COMPOSIO_SNAPSHOT = broken
        self._no_ranking()
        self.assertEqual(cat.composio_entries(), [])

    def test_with_no_snapshot_the_ranking_still_lists_what_it_names(self):
        cat.COMPOSIO_SNAPSHOT = os.path.join(self.tmp.name, "missing.json")
        entries = cat.composio_entries()
        self.assertTrue(entries, "the shipped ranking lists nothing")
        self.assertEqual({e["source"] for e in entries}, {"composio-ranking"})
        self.assertEqual(len({e["name"] for e in entries}), len(entries), "a service listed twice")

    def test_the_snapshot_carries_no_session_and_no_key(self):
        with open(cat.COMPOSIO_SNAPSHOT, encoding="utf-8") as fh:
            text = fh.read()
        doc = json.loads(text)
        # An exact list, not a subset: this is a leak test, so a field nobody
        # here has read is exactly what it is looking for. Adding a snapshot
        # field is therefore meant to fail here once, and to be added below by
        # someone who has looked at what it contains.
        #
        # `shown_by_default`, `managed_auth` and `auth_schemes` were added
        # 2026-09-07 by the curation work: which services Composio itself holds
        # the sign-in for, so the pane can stop telling 1,259 of them that
        # connecting is "one sign-in, nothing to paste" when Composio has no
        # app registered with them. All three are Composio's own published
        # facts about a product, carry nothing about this Mac or its owner, and
        # `shown_by_default` is a sentence naming the rule.
        self.assertEqual(sorted(doc),
                         ["generated_at", "shown_by_default", "source", "toolkits"])
        for kit in doc["toolkits"]:
            self.assertEqual(sorted(kit), ["auth_schemes", "description", "label",
                                           "logo", "managed_auth", "no_auth", "slug"])
        # A session id is a capability and a key is a key; neither belongs in a
        # file every install carries.
        self.assertNotRegex(text, r"\bak_[A-Za-z0-9_-]{8,}")
        self.assertNotIn("session_id", text)


if __name__ == "__main__":
    unittest.main()
