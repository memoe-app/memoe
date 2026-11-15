"""Which sites the cloud computer's browser stays signed in to (browsersites.py).

What must hold: the person's list, made on the Mac, is enforced exactly — the empty list
included — on the kept profile's real cookie store (a Chromium-shaped SQLite table); a Mac
that never offered the choice prunes nothing; a malformed list prunes nothing; a running
browser's store is never written; and nothing but ``host_key`` is read.
"""

import importlib.util
import json
import os
import sqlite3
import tempfile
import unittest

_PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("moe_connectors_browsersites_test",
                                               os.path.join(_PKG, "browsersites.py"))
bs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bs)

HOSTS = [".x.com", "api.x.com", ".google.com", "accounts.google.com", ".doubleclick.net",
         "shop.example.org", ".nytimes.com"]


class Machine:
    def __init__(self, sites=None, layout=os.path.join("Default", "Network", "Cookies")):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.hermes = os.path.join(root, "hermes")
        self.moe = os.path.join(root, "moe-home")
        self.proc = os.path.join(root, "proc")
        os.makedirs(self.moe)
        os.makedirs(self.proc)
        self.store = os.path.join(bs.kept_dir(self.hermes), layout)
        os.makedirs(os.path.dirname(self.store))
        db = sqlite3.connect(self.store)
        db.execute("CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB)")
        for h in HOSTS:
            db.execute("INSERT INTO cookies VALUES (?, 'sid', '', x'763130')", (h,))
        db.commit()
        db.close()
        if sites is not None:
            self.config({"cloudBrowserSites": sites, "nudges": True})

    def config(self, cfg):
        with open(os.path.join(self.moe, "config.json"), "w") as fh:
            json.dump(cfg, fh)

    def hosts(self):
        db = sqlite3.connect(self.store)
        try:
            return sorted(r[0] for r in db.execute("SELECT host_key FROM cookies"))
        finally:
            db.close()

    def running(self):
        os.makedirs(os.path.join(self.proc, "77"))
        with open(os.path.join(self.proc, "77", "cmdline"), "wb") as fh:
            fh.write(b"/opt/chrome\0--user-data-dir=" + bs.kept_dir(self.hermes).encode() + b"\0")

    def prune(self):
        return bs.prune(self.hermes, self.moe, proc_root=self.proc)


class SiteList(unittest.TestCase):
    def test_only_listed_sites_and_their_subdomains_stay(self):
        m = Machine(["x.com", "https://accounts.google.com/signin"])
        out = m.prune()
        self.assertTrue(out["pruned"])
        self.assertEqual(m.hosts(), sorted([".x.com", "api.x.com", "accounts.google.com"]))

    def test_listing_the_parent_keeps_its_sign_in_hosts(self):
        m = Machine(["google.com"])
        m.prune()
        self.assertEqual(m.hosts(), sorted([".google.com", "accounts.google.com"]))

    def test_the_empty_list_keeps_nothing(self):
        m = Machine([])
        m.prune()
        self.assertEqual(m.hosts(), [])

    def test_a_mac_that_never_offered_the_choice_prunes_nothing(self):
        m = Machine(None)
        m.config({"nudges": True})
        self.assertFalse(m.prune()["pruned"])
        self.assertEqual(m.hosts(), sorted(HOSTS))

    def test_a_malformed_list_prunes_nothing(self):
        m = Machine(None)
        m.config({"cloudBrowserSites": "x.com"})
        self.assertFalse(m.prune()["pruned"])
        self.assertEqual(m.hosts(), sorted(HOSTS))

    def test_a_running_browser_is_never_written_under(self):
        m = Machine([])
        m.running()
        out = m.prune()
        self.assertEqual(out, {"pruned": False, "why": "the browser is running"})
        self.assertEqual(m.hosts(), sorted(HOSTS))

    def test_the_older_cookie_layout_is_held_too(self):
        m = Machine(["x.com"], layout=os.path.join("Default", "Cookies"))
        m.prune()
        self.assertEqual(m.hosts(), sorted([".x.com", "api.x.com"]))

    def test_a_lookalike_is_not_a_subdomain(self):
        self.assertFalse(bs.host_allowed("evilx.com", ["x.com"]))
        self.assertFalse(bs.host_allowed("x.com.evil.net", ["x.com"]))
        self.assertTrue(bs.host_allowed(".www.x.com", ["x.com"]))

    def test_sites_are_cleaned_and_junk_dropped(self):
        self.assertEqual(bs.clean_site("HTTPS://www.X.com/login?next=1"), "x.com")
        self.assertEqual(bs.clean_site("user@mail.example.org:443"), "mail.example.org")
        self.assertIsNone(bs.clean_site("not a site"))
        self.assertIsNone(bs.clean_site("localhost"))

    def test_the_sign_in_tool_says_whether_it_stays(self):
        m = Machine(["x.com"])
        self.assertIn("stays", bs.kept_note("x.com", m.moe))
        note = bs.kept_note("linkedin.com", m.moe)
        self.assertIn("only for this task", note)
        self.assertIn("Settings › Away › Cloud browser", note)

    def test_only_browser_tools_trigger_it(self):
        self.assertTrue(bs.is_browser_tool("browser_exec"))
        self.assertTrue(bs.is_browser_tool("mcp__hermes-tools__browser_cdp"))
        self.assertFalse(bs.is_browser_tool("gmail_send"))


if __name__ == "__main__":
    unittest.main()


class ThePluginHoldsTheList(unittest.TestCase):
    """The send gate's hook runs the pruning first for browser calls, and only for them."""

    def test_the_gate_hook_prunes_before_a_browser_call_and_never_decides(self):
        import sys
        sys.path.insert(0, os.path.dirname(_PKG))
        spec = importlib.util.spec_from_file_location("moe_connectors_plugin_sites_test",
                                                      os.path.join(_PKG, "__init__.py"),
                                                      submodule_search_locations=[_PKG])
        plugin = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(plugin)
        m = Machine(["x.com"])
        calls = []
        plugin._BROWSERSITES = type("Stub", (), {
            "is_browser_tool": staticmethod(bs.is_browser_tool),
            "prune": staticmethod(lambda h, mh: calls.append((h, mh)) or bs.prune(m.hermes, m.moe, m.proc)),
        })
        self.assertIsNone(plugin.away_browser_sites(tool_name="gmail_send"))
        self.assertEqual(calls, [])
        self.assertIsNone(plugin.away_browser_sites(tool_name="browser_exec"))
        self.assertEqual(len(calls), 1)
        self.assertEqual(m.hosts(), sorted([".x.com", "api.x.com"]))
        plugin._BROWSERSITES = type("Boom", (), {"is_browser_tool": staticmethod(lambda n: True),
                                                 "prune": staticmethod(lambda h, mh: 1 / 0)})
        self.assertIsNone(plugin.away_browser_sites(tool_name="browser_exec"))  # logged, never raised

    def test_away_send_gate_calls_it(self):
        src = open(os.path.join(_PKG, "__init__.py"), encoding="utf-8").read()
        body = src[src.index("def away_send_gate("):src.index("away_send_gate.__hermes_hook_timeout__")]
        self.assertIn("away_browser_sites(**kwargs)", body)
