"""`connect_service`: the person asks to connect a service, Moe hands them the
sign-in link (docs/SETTINGS-ASSISTANT.md).

It runs composio.py's own `connect` — what the Connect button runs, so a
duplicate is not minted and stale pending sign-ins are freed — only on the
person's own turn, and every outcome is a sentence. Refusals assert the side
effect: the script never ran.
"""

import importlib.util
import json
import os
import shutil
import sys
import tempfile
import types
import unittest

_PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "connect_serviceors_connect_under_test", os.path.join(_PKG, "__init__.py"))
plugin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(plugin)

#: Records its argv beside itself and answers as composio.py does.
FAKE = r'''
import json, os, sys
with open(os.path.join(os.path.dirname(__file__), "argv.json"), "w") as f:
    json.dump(sys.argv[1:], f)
slug = sys.argv[2]
if slug == "gmail":
    print("already connected")
elif slug == "notion":
    print("https://connect.composio.dev/link/abc123")
else:
    print("Composio could not start a sign-in for %s: unknown toolkit" % slug, file=sys.stderr)
    sys.exit(1)
'''


class Ctx:
    def __init__(self):
        self.tools = {}

    def register_hook(self, *_a, **_kw):
        pass

    def register_tool(self, name, toolset, schema, handler, check_fn=None, description="", emoji="", **kw):
        self.tools[name] = {"toolset": toolset, "schema": schema, "handler": handler}


class Case(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.moe = os.path.join(self.dir, "moe")
        os.makedirs(os.path.join(self.moe, "connectors"))
        self.saved = {k: os.environ.get(k) for k in ("MOE_HOME", "HERMES_HOME", "MOE_RUNS_IN")}
        os.environ["MOE_HOME"] = self.moe
        os.environ["HERMES_HOME"] = os.path.join(self.dir, "hermes")
        os.environ.pop("MOE_RUNS_IN", None)
        self.saved_tools = {k: sys.modules.get(k) for k in ("tools", "tools.browser_chrome_extension")}

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        for k, v in self.saved_tools.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v
        shutil.rmtree(self.dir, ignore_errors=True)

    def presence(self, verdict):
        fake = types.ModuleType("tools.browser_chrome_extension")
        fake.turn_presence = lambda: verdict
        sys.modules["tools"] = sys.modules.get("tools") or types.ModuleType("tools")
        sys.modules["tools.browser_chrome_extension"] = fake

    def script(self):
        with open(os.path.join(self.moe, "connectors", "composio.py"), "w") as f:
            f.write(FAKE)

    def argv(self):
        path = os.path.join(self.moe, "connectors", "argv.json")
        return json.load(open(path)) if os.path.exists(path) else None

    def call(self, **args):
        return json.loads(plugin.connect_handler(args))


class Connect(Case):
    def test_a_link_for_what_the_person_asked_for(self):
        self.presence({"live": True, "why": "the person's own turn"})
        self.script()
        out = self.call(service="Notion")
        self.assertTrue(out["success"])
        self.assertEqual(out["result"]["link"], "https://connect.composio.dev/link/abc123")
        self.assertEqual(self.argv(), ["connect", "notion"])

    def test_from_a_phone_chat_too(self):
        self.presence({"live": True, "why": "the person's message"})
        self.script()
        self.assertTrue(self.call(service="notion")["success"])

    def test_already_connected_is_said_not_minted_again(self):
        self.presence({"live": True, "why": "the person's own turn"})
        self.script()
        out = self.call(service="email")
        self.assertTrue(out["success"] and out["result"]["connected"])
        self.assertEqual(self.argv(), ["connect", "gmail"])

    def test_a_second_account_only_when_asked(self):
        self.presence({"live": True, "why": "the person's own turn"})
        self.script()
        self.call(service="gmail", another_account=True)
        self.assertEqual(self.argv(), ["connect", "gmail", "--another"])
        self.call(service="gmail", another_account="yes")
        self.assertEqual(self.argv(), ["connect", "gmail"])

    def test_names_people_use(self):
        self.assertEqual(plugin.connect_slug("Google Calendar"), "googlecalendar")
        self.assertEqual(plugin.connect_slug("google  drive"), "googledrive")
        self.assertEqual(plugin.connect_slug("GitHub"), "github")
        self.assertEqual(plugin.connect_slug("x"), "twitter")

    def test_composios_reason_is_passed_on(self):
        self.presence({"live": True, "why": "the person's own turn"})
        self.script()
        out = self.call(service="frobnitz")
        self.assertFalse(out["success"])
        self.assertIn("unknown toolkit", out["error"])
        self.assertIn("Connections", out["error"])

    def test_nobodys_turn_starts_nothing(self):
        for verdict in ({"live": False, "why": "a scheduled job"}, {}, None):
            self.presence(verdict)
            self.script()
            out = self.call(service="notion")
            self.assertFalse(out["success"])
            self.assertEqual(out["status"], "refused")
            self.assertIsNone(self.argv(), verdict)

    def test_no_script_says_where_to_go(self):
        self.presence({"live": True, "why": "the person's own turn"})
        out = self.call(service="notion")
        self.assertEqual(out["status"], "unavailable")


class Registered(Case):
    def test_on_a_mac_only(self):
        ctx = Ctx()
        plugin.register(ctx)
        self.assertIn(plugin.CONNECT_TOOL, ctx.tools)
        self.assertIn(plugin.CONNECT_TOOL, plugin.NOT_CONNECTOR_TOOLS)
        os.environ["MOE_RUNS_IN"] = "cloud"
        ctx = Ctx()
        plugin.register(ctx)
        self.assertNotIn(plugin.CONNECT_TOOL, ctx.tools)


if __name__ == "__main__":
    unittest.main()
