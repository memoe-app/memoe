"""`report_problem`: filing a ticket with the Memoe team is a TOOL.

2026-09-25 and 2026-09-29, the owner, answering from the away machine: told
to report a bug to the Memoe team, Moe said there was "no ticket/feedback tool
in my toolkit, and search turned up nothing", and kept it in its notes. Filing
existed only as a skill (moe-tickets: SKILL.md + moe-ticket.py through the
shell), and the claude-code child searches tools. These pin the tool: it is
registered on both runtimes where a tool search reaches it, it hands
moe-ticket.py the right argv and relays its answer, and every failure is a
sentence rather than an exception.
"""

import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

_PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "moe_connectors_report_under_test", os.path.join(_PKG, "__init__.py"))
plugin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(plugin)

#: The words a person, or a model searching its tools, uses for this.
SEARCH_WORDS = ("ticket", "report", "bug", "feedback", "support", "problem")


class Ctx:
    def __init__(self):
        self.tools = {}

    def register_hook(self, *_a, **_kw):
        pass

    def register_tool(self, name, toolset, schema, handler, check_fn=None,
                      description="", emoji="", **kwargs):
        assert name not in self.tools, "registered %s twice" % name
        self.tools[name] = {"toolset": toolset, "schema": schema, "handler": handler,
                            "check_fn": check_fn, "description": description, "emoji": emoji}


class Env:
    """MOE_HOME, HERMES_HOME and MOE_RUNS_IN for one test, all restored."""

    KEYS = ("MOE_HOME", "HERMES_HOME", "MOE_RUNS_IN")

    def __init__(self, runs_in=None):
        self.runs_in = runs_in

    def __enter__(self):
        self.dir = tempfile.mkdtemp()
        self.moe = os.path.join(self.dir, "moe")
        self.hermes = os.path.join(self.dir, "hermes")
        os.makedirs(os.path.join(self.moe, "connectors"))
        os.makedirs(self.hermes)
        self.previous = {k: os.environ.get(k) for k in self.KEYS}
        os.environ["MOE_HOME"] = self.moe
        os.environ["HERMES_HOME"] = self.hermes
        if self.runs_in is None:
            os.environ.pop("MOE_RUNS_IN", None)
        else:
            os.environ["MOE_RUNS_IN"] = self.runs_in
        return self

    def __exit__(self, *exc):
        for k, v in self.previous.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.dir, ignore_errors=True)

    def script(self, body, under="hermes"):
        """A stand-in moe-ticket.py where the skill lands."""
        root = (os.path.join(self.hermes, "skills") if under == "hermes"
                else os.path.join(self.moe, "hermes-skills"))
        path = os.path.join(root, "support", "moe-tickets", "moe-ticket.py")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(body)
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        return path

    def tool(self):
        ctx = Ctx()
        plugin.register(ctx)
        return ctx.tools[plugin.REPORT_TOOL]


#: Records its argv beside itself and answers as the real script does.
RECORDS = r'''
import json, os, sys
with open(os.path.join(os.path.dirname(__file__), "argv.json"), "w") as f:
    json.dump(sys.argv[1:], f)
print("Filed ticket #42. The person has been emailed.")
'''


class Registered(unittest.TestCase):
    def test_on_both_runtimes_in_the_direct_toolset_with_the_words_a_search_reads(self):
        for runs_in in (None, "mac", "cloud"):
            with Env(runs_in) as env:
                tool = env.tool()
            self.assertEqual(tool["toolset"], plugin.TOOLSET, runs_in)
            self.assertEqual(tool["toolset"], "connectors", runs_in)
            self.assertTrue(tool["check_fn"](), runs_in)
            self.assertTrue(tool["emoji"])
            text = (plugin.REPORT_TOOL + " " + tool["description"]).lower()
            for word in SEARCH_WORDS:
                self.assertIn(word, text, "%r not findable by %r" % (runs_in, word))
            self.assertIn("Memoe team", tool["description"])
            self.assertEqual(tool["schema"]["name"], plugin.REPORT_TOOL)
            params = tool["schema"]["parameters"]
            self.assertEqual(sorted(params["required"]), ["body", "title"])
            self.assertEqual(sorted(params["properties"]),
                             ["anonymous", "body", "context", "source", "title"])

    def test_offered_even_with_no_script_installed(self):
        """A search that finds nothing is what happened; the tool must be
        there to answer in words."""
        with Env("cloud") as env:
            self.assertTrue(env.tool()["check_fn"]())

    def test_connectors_is_on_hermes_direct_surface(self):
        """The toolset is chosen so the tool is not deferred. That is Hermes's
        list, so read it where Hermes is installed."""
        path = os.path.expanduser("~/.hermes/hermes-agent/tools/tool_search.py")
        if not os.path.exists(path):
            self.skipTest("hermes-agent is not installed beside this checkout")
        self.assertIn('"connectors"', direct_surface_literal(open(path, encoding="utf-8").read()))

    def test_the_send_gate_knows_it(self):
        """A plugin tool missing from confirm-send.sh's table is a "not a tool
        Moe recognises" dialog; a ticket has never had one."""
        hook = os.path.join(_PKG, os.pardir, os.pardir, "hermes", "hooks", "confirm-send.sh")
        self.assertIn('"report_problem "', open(hook, encoding="utf-8").read())


def direct_surface_literal(source):
    """The set literal Hermes assigns to `_DIRECT_SURFACE_TOOLSETS`.

    It was `_DIRECT_SURFACE_TOOLSETS = frozenset({...})`; at pin eb8e427cd1 it
    is `_GUI_SURFACE_TOOLSETS | frozenset({...})`, and the test that looked
    for the first spelling died on `str.index` instead of checking anything.
    Either way the plugin toolsets are the names inside the first
    `frozenset(` after the assignment — the part this returns. The GUI half
    is session platforms, and `connectors` was never one of those."""
    start = source.index("\n_DIRECT_SURFACE_TOOLSETS = ")
    start = source.index("frozenset(", start)
    return source[start:source.index(")", start)]


class DirectSurfaceLiteral(unittest.TestCase):
    """The reader above, against both spellings and against a Hermes that
    dropped the toolset — so it cannot pass by reading the wrong span."""

    OLD = '\n_DIRECT_SURFACE_TOOLSETS = frozenset({\n    "setup", "connectors",\n})\n'
    NEW = ('# moe-connectors registers "connectors" tools\n'
           '\n_DIRECT_SURFACE_TOOLSETS = _GUI_SURFACE_TOOLSETS | frozenset({\n'
           '    "setup", "connectors", "moe_profile",\n})\n'
           '_OTHER = frozenset({"connectors"})\n')

    def test_both_spellings_are_read(self):
        self.assertIn('"connectors"', direct_surface_literal(self.OLD))
        self.assertIn('"connectors"', direct_surface_literal(self.NEW))

    def test_a_hermes_that_dropped_it_is_not_read_as_having_it(self):
        gone = self.NEW.replace('"setup", "connectors", "moe_profile"', '"setup", "moe_profile"')
        self.assertNotIn('"connectors"', direct_surface_literal(gone))


class Files(unittest.TestCase):
    def test_hands_the_script_its_flags_and_returns_its_answer(self):
        with Env("cloud") as env:
            path = env.script(RECORDS)
            out = json.loads(env.tool()["handler"]({
                "title": "  Calendar invite   never sent ",
                "body": "The person asked me to invite Sara. I said it was sent. It was not.",
                "context": "Person: invite Sara\nMoe: Done.",
                "source": "user",
                "anonymous": True,
            }, task_id="t1"))
            argv = json.load(open(os.path.join(os.path.dirname(path), "argv.json")))
        self.assertEqual(out, {"success": True,
                               "result": "Filed ticket #42. The person has been emailed."})
        self.assertEqual(argv, [
            "--title=Calendar invite never sent",
            "--body=The person asked me to invite Sara. I said it was sent. It was not.",
            "--context=Person: invite Sara\nMoe: Done.",
            "--source=user",
            "--anonymous",
        ])

    def test_optional_flags_are_left_out_and_a_leading_dash_stays_a_value(self):
        with Env() as env:
            path = env.script(RECORDS)
            env.tool()["handler"]({"title": "-h", "body": "--list", "source": "nonsense",
                                   "anonymous": False})
            argv = json.load(open(os.path.join(os.path.dirname(path), "argv.json")))
        self.assertEqual(argv, ["--title=-h", "--body=--list"])

    def test_the_copy_in_moes_home_is_the_fallback(self):
        with Env() as env:
            path = env.script(RECORDS, under="moe")
            out = json.loads(env.tool()["handler"]({"title": "t", "body": "b"}))
            self.assertTrue(os.path.exists(os.path.join(os.path.dirname(path), "argv.json")))
        self.assertTrue(out["success"])

    def test_real_script_parses_those_flags(self):
        """The argv above is only right if moe-ticket.py's own parser reads it
        the same way: parse it with the real argparse, sending nothing."""
        real = os.path.join(_PKG, os.pardir, os.pardir, "hermes-skills", "support",
                            "moe-tickets", "moe-ticket.py")
        spec = importlib.util.spec_from_file_location("moe_ticket_real", real)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        seen = {}

        class Stop(Exception):
            pass

        def fake_discard():
            raise Stop()

        import argparse
        original = argparse.ArgumentParser.parse_args

        def capture(self, args=None, namespace=None):
            ns = original(self, args, namespace)
            seen.update(vars(ns))
            return ns

        argv, _ = plugin.report_argv({"title": "-h", "body": "b --x", "context": "c",
                                      "source": "user", "anonymous": True})
        argparse.ArgumentParser.parse_args = capture
        module.discard_pending = fake_discard
        try:
            with self.assertRaises(Stop):
                module.main(argv)
        finally:
            argparse.ArgumentParser.parse_args = original
        self.assertEqual((seen["title"], seen["body"], seen["context"], seen["source"],
                          seen["anonymous"]), ("-h", "b --x", "c", "user", True))


class NeverRaises(unittest.TestCase):
    def call(self, env, params):
        return json.loads(env.tool()["handler"](params))

    def test_no_script_is_a_sentence(self):
        with Env("cloud") as env:
            out = self.call(env, {"title": "t", "body": "b"})
        self.assertFalse(out["success"])
        self.assertIn("was not sent", out["error"])
        self.assertIn("not installed", out["error"])

    def test_missing_title_or_body_is_a_sentence(self):
        with Env() as env:
            env.script(RECORDS)
            for params in ({}, {"title": "t"}, {"body": "b"}, {"title": "  ", "body": "b"}):
                out = self.call(env, params)
                self.assertFalse(out["success"], params)
                self.assertIn("needs a title", out["error"])
            self.assertFalse(os.path.exists(os.path.join(
                env.hermes, "skills", "support", "moe-tickets", "argv.json")))

    def test_not_a_dict_is_a_sentence(self):
        with Env() as env:
            out = json.loads(env.tool()["handler"](None))
        self.assertFalse(out["success"])

    def test_reports_off_line_is_relayed_word_for_word(self):
        line = ("Problem reports are off, so I haven't written or kept this report. "
                "Turn it on in Settings.")
        with Env() as env:
            env.script("print(%r)\nimport sys; sys.exit(3)\n" % line)
            out = self.call(env, {"title": "t", "body": "b"})
        self.assertFalse(out["success"])
        self.assertTrue(out["not_sent"])
        self.assertEqual(out["say_to_the_person"], line)

    def test_a_failed_script_gives_its_reason(self):
        with Env() as env:
            env.script('import json\nprint(json.dumps({"outcome": "failed", '
                       '"why": "moe-ticket: the edge said 500"}))\nimport sys; sys.exit(1)\n')
            out = self.call(env, {"title": "t", "body": "b"})
        self.assertEqual(out, {"success": False,
                               "error": "The report was not sent: moe-ticket: the edge said 500"})

    def test_a_script_that_exits_with_a_message_gives_it(self):
        with Env() as env:
            env.script('import sys\nsys.exit("moe-ticket: this Mac is not signed in")\n')
            out = self.call(env, {"title": "t", "body": "b"})
        self.assertIn("this Mac is not signed in", out["error"])

    def test_a_crash_is_a_sentence(self):
        with Env() as env:
            env.script("raise RuntimeError('boom')\n")
            out = self.call(env, {"title": "t", "body": "b"})
        self.assertFalse(out["success"])
        self.assertIn("was not sent", out["error"])

    def test_a_timeout_is_a_sentence(self):
        with Env() as env:
            env.script("import time\ntime.sleep(5)\n")
            previous = plugin.REPORT_TIMEOUT
            plugin.REPORT_TIMEOUT = 0.5
            try:
                out = self.call(env, {"title": "t", "body": "b"})
            finally:
                plugin.REPORT_TIMEOUT = previous
        self.assertFalse(out["success"])
        self.assertIn("did not answer", out["error"])
        self.assertTrue(out.get("maybe_sent"), "it may have gone: never invite a second ticket")
        self.assertIn("Do not file it again", out["error"])

    def test_the_same_report_twice_and_a_fourth_in_a_day_are_not_filed(self):
        """Review 2026-09-30: every ticket emails the person, and the tool has
        no dialog — a loop or an injected "report a problem" must not flood
        their inbox."""
        with Env() as env:
            path = env.script(RECORDS)
            first = self.call(env, {"title": "Calendar invite never sent", "body": "b"})
            again = self.call(env, {"title": "  calendar invite NEVER sent", "body": "b"})
            second = self.call(env, {"title": "Island stays amber", "body": "b"})
            third = self.call(env, {"title": "Voice cuts out", "body": "b"})
            fourth = self.call(env, {"title": "Mail reader empty", "body": "b"})
        self.assertTrue(first["success"] and second["success"] and third["success"])
        self.assertFalse(again["success"])
        self.assertIn("already with the Memoe team", again["error"])
        self.assertFalse(fourth["success"])
        self.assertIn("tomorrow", fourth["error"])

    def test_an_internal_error_is_a_sentence(self):
        with Env() as env:
            previous = plugin.ticket_script
            plugin.ticket_script = lambda: (_ for _ in ()).throw(ValueError("bad"))
            try:
                out = self.call(env, {"title": "t", "body": "b"})
            finally:
                plugin.ticket_script = previous
        self.assertFalse(out["success"])
        self.assertIn("ValueError", out["error"])


if __name__ == "__main__":
    unittest.main()
