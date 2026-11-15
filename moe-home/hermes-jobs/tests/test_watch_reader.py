#!/usr/bin/env python3
"""moe-watch-reader.py and lib/mcp_read.py with Hermes stubbed — no
gateway, no MCP, no model.

Run: python3 moe-home/hermes-jobs/tests/test_watch_reader.py
What is tested is the contract the watch and gather passes both rely on:
the gates print "disabled" without reading, reads are exactly the recipe's,
one server is connected, output is stable across runs, a tool error is an
error and never a change.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
JOBS = os.path.normpath(os.path.join(HERE, ".."))
MOE_HOME_SRC = os.path.normpath(os.path.join(JOBS, ".."))
READER = os.path.join(JOBS, "moe-watch-reader.py")
LIB = os.path.join(MOE_HOME_SRC, "lib", "mcp_read.py")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeMcp(object):
    """The three things the read touches on tools.mcp_tool."""

    def __init__(self, servers):
        self.servers = servers
        self.registered = []

    def _load_mcp_config(self):
        return self.servers

    def register_mcp_servers(self, servers):
        self.registered.append(dict(servers))

    @staticmethod
    def mcp_prefixed_tool_name(server, tool):
        return "mcp_%s_%s" % (server, tool)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-watch-test-")
        os.environ["MOE_HOME"] = self.tmp
        os.makedirs(os.path.join(self.tmp, "watch"))
        os.makedirs(os.path.join(self.tmp, "learn"))
        os.makedirs(os.path.join(self.tmp, "lib"))
        shutil.copy(LIB, os.path.join(self.tmp, "lib", "mcp_read.py"))
        self.lib = load(LIB, "moe_mcp_read")
        self.reader = load(READER, "moe_watch_reader")
        self.calls = []

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        sys.modules.pop("mcp_read", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def hermes(self, replies, servers=None):
        mcp = FakeMcp(servers or {"pulse": {"url": "https://x"}, "vercel": {"url": "https://y"}})

        def call(name, args, task_id=None, **kw):
            self.calls.append((name, dict(args), task_id))
            return replies.get(name, json.dumps({"result": "ok"}))

        return mcp, call

    def recipe(self, **extra):
        r = {"connector": "pulse", "kind": "mcp", "label": "Pulse", "every": "30m",
             "reads": [{"tool": "my_calendar", "args": {"mode": "today"}},
                       {"tool": "search_messages", "args": {"mode": "recent"}}],
             "max_chars": 200}
        r.update(extra)
        with open(os.path.join(self.tmp, "watch", "pulse.json"), "w") as f:
            json.dump(r, f)
        return r


class LibTest(Base):
    def test_reads_exactly_these_on_one_server(self):
        h = self.hermes({"mcp_pulse_my_calendar": json.dumps({"result": "Standup 9:00\nLunch 12:00"}),
                         "mcp_pulse_search_messages": json.dumps({"result": "as of 09:41\nBob: hi\n\n\n\nAnn: ok  "})})
        reads = [{"tool": "my_calendar", "args": {"mode": "today"}}, {"tool": "search_messages", "args": {"mode": "recent"}}]
        out = self.lib.read_connector("pulse", reads, max_chars=200, hermes_pair=h, task="moe-gather")
        self.assertEqual([c[0] for c in self.calls], ["mcp_pulse_my_calendar", "mcp_pulse_search_messages"])
        self.assertEqual(self.calls[0], ("mcp_pulse_my_calendar", {"mode": "today"}, "moe-gather-pulse"))
        self.assertEqual(h[0].registered, [{"pulse": {"url": "https://x"}}])   # never vercel
        self.assertIn("## my_calendar {\"mode\": \"today\"}\n\nStandup 9:00\nLunch 12:00", out)
        # volatile line gone, blank runs collapsed, trailing space gone
        self.assertIn("## search_messages {\"mode\": \"recent\"}\n\nBob: hi\n\nAnn: ok\n", out)
        self.assertNotIn("as of", out)
        self.assertEqual(out, self.lib.read_connector("pulse", reads, max_chars=200, hermes_pair=h))  # stable

    def test_long_result_is_cut(self):
        h = self.hermes({"mcp_pulse_search_files": json.dumps({"result": "x" * 100})})
        out = self.lib.read_connector("pulse", [{"tool": "search_files"}], max_chars=20, hermes_pair=h)
        self.assertIn("x" * 20 + "\n[… cut at 20 characters]", out)
        self.assertNotIn("x" * 21, out)
        self.assertEqual(out.split("\n")[0], "## search_files")

    def test_tool_error_is_an_error_not_a_change(self):
        h = self.hermes({"mcp_pulse_my_calendar": json.dumps({"error": "token expired"})})
        with self.assertRaises(RuntimeError) as cm:
            self.lib.read_connector("pulse", [{"tool": "my_calendar"}], hermes_pair=h)
        self.assertIn("pulse.my_calendar: token expired", str(cm.exception))

    def test_unconfigured_server_and_bad_names_are_errors(self):
        mcp = FakeMcp({"vercel": {}})
        with self.assertRaises(RuntimeError):
            self.lib.read_connector("pulse", [{"tool": "x"}], hermes_pair=(mcp, lambda *a, **k: "{}"))
        with self.assertRaises(ValueError):
            self.lib.read_connector("../pulse", [{"tool": "x"}], hermes_pair=self.hermes({}))
        with self.assertRaises(ValueError):
            self.lib.read_connector("pulse", [{"args": {}}], hermes_pair=self.hermes({}))

    def test_source_flagged_fields_are_dropped_at_read_time(self):
        schema = ("[mssql] analytics.ARRehabClaimNotes ~3,362 rows\n"
                  "  - ClaimKey: text  (Identifier for the claim.)\n"
                  "  - PtName: text  (Patient/resident name — treat as PII and keep it off shared or scheduled surfaces)\n"
                  "  - Note: text  (Free-text note. Treat as PHI.)\n"
                  "  - ChgDOS: date  (The claim's charge date.)")
        h = self.hermes({"mcp_pulse_search_schema": json.dumps({"result": schema})})
        out = self.lib.read_connector("pulse", [{"tool": "search_schema", "args": {"patterns": ["%claim%"]}}], hermes_pair=h)
        self.assertNotIn("PtName", out)
        self.assertNotIn("Free-text note", out)
        self.assertIn("ClaimKey", out)
        self.assertIn("ChgDOS", out)
        self.assertIn("[2 field(s) the source marks as personal were left out]", out)

    def test_redact_helpers(self):
        redact = load(os.path.join(MOE_HOME_SRC, "lib", "redact.py"), "moe_redact")
        self.assertEqual(redact.drop_flagged("a\nb treat as PII here\nc"), "a\nc\n[1 field(s) the source marks as personal were left out]")
        self.assertEqual(redact.drop_flagged("plain"), "plain")
        s = redact.scrub_ids("SSN: 123-45-6789, patient id A-99, MRN 00123, v6, 2026-09-02, 3,362 rows, 1193 tables")
        self.assertNotIn("123-45-6789", s)
        self.assertNotIn("A-99", s)
        self.assertNotIn("00123", s)
        for keep in ("v6", "2026-09-02", "3,362 rows", "1193 tables"):
            self.assertIn(keep, s)

    def test_stable_keeps_content_dates(self):
        self.assertEqual(self.lib.stable("Meeting Tuesday 3pm\nGenerated at 09:41\n\n\n\nnext  "),
                         "Meeting Tuesday 3pm\n\nnext")

    def test_stable_drops_an_execution_id(self):
        """Composio's executor returns a log_id on every call. Left in, two
        identical reads a day apart differ by one line, the merge sees a
        change, and a source that has not moved is learned again nightly."""
        a = self.lib.stable('{\n "data": {"repos": 3},\n "log_id": "lg_aaa",\n "successful": true\n}')
        b = self.lib.stable('{\n "data": {"repos": 3},\n "log_id": "lg_bbb",\n "successful": true\n}')
        self.assertEqual(a, b)
        self.assertNotIn("lg_aaa", a)
        self.assertIn('"repos": 3', a)
        # A session id is a capability, not a name: never into a digest.
        self.assertNotIn("trs_x", self.lib.stable('{\n "session_id": "trs_x",\n "n": 1\n}'))

    def test_a_read_may_say_what_to_call_the_section(self):
        """A Composio toolkit's reads all go through one multiplexer tool, so
        without a label every section of a gather is headed
        COMPOSIO_MULTI_EXECUTE_TOOL and the text says nothing about what was
        read."""
        h = self.hermes({"mcp_composio_COMPOSIO_MULTI_EXECUTE_TOOL": json.dumps({"result": "two repos"})},
                        servers={"composio": {"url": "https://z"}})
        out = self.lib.read_connector(
            "composio",
            [{"tool": "COMPOSIO_MULTI_EXECUTE_TOOL", "label": "GITHUB_LIST_REPOSITORIES",
              "args": {"tools": [{"tool_slug": "GITHUB_LIST_REPOSITORIES", "arguments": {}}]}}],
            hermes_pair=h)
        self.assertIn("## GITHUB_LIST_REPOSITORIES\n\ntwo repos", out)
        self.assertNotIn("COMPOSIO_MULTI_EXECUTE_TOOL", out)
        # …and the call that was actually made is still the multiplexer's.
        self.assertEqual(self.calls[-1][0], "mcp_composio_COMPOSIO_MULTI_EXECUTE_TOOL")

    def test_result_text_shapes(self):
        self.assertEqual(self.lib.result_text('{"result": "a"}'), ("a", ""))
        self.assertEqual(self.lib.result_text('{"content": [1]}'), ("[\n 1\n]", ""))
        self.assertEqual(self.lib.result_text('{"error": "no"}'), ("", "no"))
        self.assertEqual(self.lib.result_text("plain"), ("plain", ""))


class AgentDirTest(Base):
    """S6: on the away image HERMES_HOME is the volume (/opt/data) and the
    checkout is /opt/hermes, not $HERMES_HOME/hermes-agent — so the lib
    looks in HERMES_AGENT_DIR, then the Mac's place, then /opt/hermes, for
    the directory that actually holds tools/mcp_tool.py."""

    def test_finds_the_checkout_where_the_image_keeps_it(self):
        agent = os.path.join(self.tmp, "checkout")
        os.makedirs(os.path.join(agent, "tools"))
        with open(os.path.join(agent, "tools", "__init__.py"), "w") as f:
            f.write("")
        with open(os.path.join(agent, "tools", "mcp_tool.py"), "w") as f:
            f.write("MARK = 'stub'\n")
        with open(os.path.join(agent, "model_tools.py"), "w") as f:
            f.write("def handle_function_call(*a, **k):\n    return 'stub'\n")
        saved = {k: sys.modules.pop(k) for k in list(sys.modules) if k == "tools" or k.startswith("tools.") or k == "model_tools"}
        old_env = {k: os.environ.get(k) for k in ("HERMES_HOME", "HERMES_AGENT_DIR")}
        try:
            os.environ["HERMES_HOME"] = os.path.join(self.tmp, "no-such-home")
            os.environ.pop("HERMES_AGENT_DIR", None)
            # Nothing anywhere: the Mac's default, so the import error names it.
            self.assertEqual(self.lib.agent_dir(), os.path.join(self.tmp, "no-such-home", "hermes-agent"))
            os.environ["HERMES_AGENT_DIR"] = agent
            self.assertEqual(self.lib.agent_dir(), agent)
            mcp_tool, call = self.lib.hermes()
            self.assertEqual(mcp_tool.MARK, "stub")
            self.assertEqual(call(), "stub")
        finally:
            for k, v in old_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            if agent in sys.path:
                sys.path.remove(agent)
            for k in list(sys.modules):
                if k == "tools" or k.startswith("tools.") or k == "model_tools":
                    sys.modules.pop(k)
            sys.modules.update(saved)


class ReaderTest(Base):
    def consent(self, script_body):
        p = os.path.join(self.tmp, "learn", "consent.sh")
        with open(p, "w") as f:
            f.write("#!/bin/bash\n" + script_body + "\n")
        os.chmod(p, 0o755)

    def config(self, **kw):
        with open(os.path.join(self.tmp, "config.json"), "w") as f:
            json.dump(kw, f)

    def run_main(self, env=None):
        e = dict(os.environ)
        e.setdefault("MOE_WATCH_CONNECTOR", "pulse")
        e.update(env or {})
        p = subprocess.run([sys.executable, READER], env=e, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, timeout=30)
        return p.returncode, p.stdout

    def test_no_consent_prints_disabled_and_reads_nothing(self):
        self.recipe()
        self.consent("exit 1")
        self.assertEqual(self.run_main(), (0, "disabled\n"))

    def test_nudges_off_prints_disabled(self):
        self.recipe()
        self.consent("exit 0")
        self.config(nudges=False)
        self.assertEqual(self.run_main(), (0, "disabled\n"))

    def test_missing_consent_script_is_a_no(self):
        self.recipe()
        self.assertEqual(self.run_main(), (0, "disabled\n"))

    def test_bad_connector_name_is_refused(self):
        rc, _ = self.run_main(env={"MOE_WATCH_CONNECTOR": "../x"})
        self.assertEqual(rc, 2)

    def test_consent_asks_for_the_watch_name(self):
        self.recipe()
        self.consent('[ "$1 $2" = "check watch:pulse" ] && exit 0; exit 1')
        # Consented, but no Hermes here: the read fails, which is exit 1
        # with the reason on stderr — never "disabled", never a change.
        rc, out = self.run_main(env={"HERMES_HOME": self.tmp})
        self.assertEqual((rc, out), (1, ""))

    def test_read_connection_uses_the_recipe(self):
        r = self.recipe(reads=[{"tool": "person_card"}], max_chars=50)
        h = self.hermes({})
        out = self.reader.read_connection(r, hermes_pair=h)
        self.assertEqual(self.calls[0], ("mcp_pulse_person_card", {}, "moe-watch-pulse"))
        self.assertEqual(out, "## person_card\n\nok\n")

    def test_recipe_validation(self):
        self.recipe(reads=[])
        with self.assertRaises(ValueError):
            self.reader.load_recipe("pulse")
        self.recipe(reads=[{"args": {}}])
        with self.assertRaises(ValueError):
            self.reader.load_recipe("pulse")
        self.recipe(connector="other")
        with self.assertRaises(ValueError):
            self.reader.load_recipe("pulse")


class ConfigLoaderMoved(Base):
    """Where the MCP server config lives, when Hermes moves it.

    Measured on the owner's Mac 2026-09-20 at pin ce81ae8305: the real
    `tools.mcp_tool` no longer carries `_load_mcp_config` (it is on
    `tools.mcp_tool_config`), and its `__getattr__` raises for anything that
    is not a lazy SDK symbol — so every read of every gather source was
    skipped with an AttributeError and the learning crawl returned nothing at
    all. Nothing here caught it, because `FakeMcp` above still has the method
    the real module had lost: the stub agreed with the code and both were
    wrong about Hermes. These drive the shapes Hermes actually presents.
    """

    class MovedOn(object):
        """A `tools.mcp_tool` of the current shape: raises, like the real one."""

        def __init__(self, servers):
            self.servers = servers
            self.registered = []

        def __getattr__(self, name):
            raise AttributeError("module 'tools.mcp_tool' has no attribute %r" % name)

        def register_mcp_servers(self, servers):
            self.registered.append(dict(servers))

    def _install_config_module(self, servers):
        """A stand-in `tools.mcp_tool_config` the fallback can import."""
        import types
        module = types.ModuleType("tools.mcp_tool_config")
        module._load_mcp_config = lambda: servers
        tools = sys.modules.get("tools")
        if tools is None:
            tools = types.ModuleType("tools")
            sys.modules["tools"] = tools
        self.addCleanup(sys.modules.pop, "tools.mcp_tool_config", None)
        sys.modules["tools.mcp_tool_config"] = module
        return module

    def test_config_read_from_the_module_it_moved_to(self):
        servers = {"pulse": {"url": "https://example.test/mcp"}}
        self._install_config_module(servers)
        mcp = self.MovedOn(servers)
        self.lib.connect("pulse", mcp)
        self.assertEqual(mcp.registered, [servers])

    def test_the_old_spelling_still_works(self):
        servers = {"pulse": {"url": "https://example.test/mcp"}}
        mcp = FakeMcp(servers)
        self.lib.connect("pulse", mcp)
        self.assertEqual(mcp.registered, [servers])

    def test_neither_spelling_is_a_failure_not_an_empty_read(self):
        """A Hermes with no config loader must say so. Reading as 'nothing
        configured' is what made this silent: an empty gather is not an error,
        so the crawl reported success and learned nothing, every night."""
        mcp = self.MovedOn({})
        # `None` in sys.modules, not a pop: a popped name is simply imported
        # again, and test-plugins.sh puts the real Hermes on PYTHONPATH — so
        # the real `tools.mcp_tool_config` came back, read this Mac's config,
        # and the test was answered "pulse is not configured" by a Hermes
        # that has the loader. `None` is what makes the import itself fail.
        had = "tools.mcp_tool_config" in sys.modules
        was = sys.modules.get("tools.mcp_tool_config")
        sys.modules["tools.mcp_tool_config"] = None

        def put_back():
            if had:
                sys.modules["tools.mcp_tool_config"] = was
            else:
                sys.modules.pop("tools.mcp_tool_config", None)
        self.addCleanup(put_back)
        with self.assertRaises(RuntimeError) as caught:
            self.lib.connect("pulse", mcp)
        self.assertIn("no MCP server configuration", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
