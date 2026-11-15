#!/usr/bin/env python3
"""Tests for configure-hermes.py against scratch HERMES_HOME / MOE_HOME dirs.

Run with the Hermes venv (PyYAML and the Hermes loader live there):
  ~/.hermes/hermes-agent/.venv/bin/python -m unittest moe-home/hermes/tests/test_configure_hermes.py

The real ~/.hermes and ~/.moe are never read or written: every run gets
explicit --hermes-home/--moe-home, HOME is pointed at the scratch dir, and
`security` is replaced by a stub (MOE_SECURITY_BIN) driven by env vars.
"""

import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import types
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "configure-hermes.py")
FIXTURE = os.path.join(HERE, "fixture-memory")


def _load_configure():
    """configure-hermes.py as a module, for the few facts a test needs to
    READ rather than re-state.

    The suite runs the script as a subprocess on purpose — that is what a
    user runs — and this does not change that. It exists so a constant like
    `HOOK_BASENAMES` has ONE spelling. A test fixture that lists the hooks
    itself is a second copy of a shipped decision, and the two drift in the
    direction nobody is looking: the day a third hook is added, every test in
    this file fails with "hook script … is missing", which reads as a bug in
    the script and is a bug in the fixture.
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location("configure_hermes", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


configure = _load_configure()

# ── a `hermes` that downloads nothing ────────────────────────────────────────
# configure-hermes.py shells out to the `hermes` CLI for two things: five
# `hermes skills install <id> --yes` on any home that lacks them, and
# `hermes computer-use install`. Every test here starts from an empty home,
# so every run_script() paid for five real CLI start-ups, and the Skills Hub
# reaches the network. Measured 2026-11-12: 202 tests in 1096 seconds — 21 of
# the 47 minutes the whole shell gate took — and one failure that was the
# network, not the code.
#
# MOE_HERMES_BIN is the seam the script already has for this (hermes_cli()).
# It is set for the whole module, by assignment rather than setdefault: a
# value inherited from somebody's shell must not put a real binary back. A
# test that wants its own stub still passes hermes_bin= and wins.
#
# The stub does what the hub does that the script can observe: it makes
# $HERMES_HOME/skills/<category…>/<name>/ — install_skills() treats the
# DIRECTORY as the proof, never the exit code — and exits 0 either way, as
# the real CLI does when it fails. MOE_STUB_SKILLS_FAIL=1 is that failure.
_STUB_DIR = tempfile.mkdtemp(prefix="moe-configure-hermes-stub-")
HERMES_STUB = os.path.join(_STUB_DIR, "hermes")
HERMES_STUB_CALLS = os.path.join(_STUB_DIR, "calls")
with open(HERMES_STUB, "w") as _f:
    _f.write("""#!/bin/bash
printf '%%s\\t%%s\\n' "${HERMES_HOME:-}" "$*" >> "%s"
if [ "${1:-} ${2:-}" = "skills install" ]; then
  id="${3:-}"
  if [ "${MOE_STUB_SKILLS_FAIL:-}" = 1 ] || [ -z "${HERMES_HOME:-}" ]; then
    echo "Error: Could not fetch '$id' from any source."
    exit 0
  fi
  dest="$HERMES_HOME/skills/${id#*/}"
  mkdir -p "$dest" && printf '# a stub skill\\n' > "$dest/SKILL.md"
  echo "Installed $id"
fi
exit 0
""" % HERMES_STUB_CALLS)
os.chmod(HERMES_STUB, 0o755)
os.environ["MOE_HERMES_BIN"] = HERMES_STUB


def tearDownModule():
    shutil.rmtree(_STUB_DIR, ignore_errors=True)


def hermes_stub_calls(hermes_home):
    """What the stub `hermes` was asked to do for this scratch home."""
    try:
        with open(HERMES_STUB_CALLS, encoding="utf-8") as f:
            return [line.rstrip("\n").split("\t", 1)[1] for line in f
                    if line.split("\t", 1)[0] == hermes_home]
    except OSError:
        return []

# Answers like /usr/bin/security for the two lookups the script makes.
SECURITY_STUB = """#!/bin/bash
# $FAKE_TG: telegram token to return for -s moe-telegram-bot -w
# $FAKE_OAUTH: "1" if the moe-child-oauth item exists
args="$*"
case "$args" in
  *"-s moe-telegram-bot -w"*)
    [ -n "${FAKE_TG:-}" ] || exit 44
    printf '%s\\n' "$FAKE_TG"; exit 0 ;;
  *"-a moe -s moe-child-oauth"*)
    [ "${FAKE_OAUTH:-}" = 1 ] && exit 0 || exit 44 ;;
  *"-s moe-composio-scoped"*)
    # $FAKE_COMPOSIO: the Composio key the Keychain holds; unset = no item.
    [ -n "${FAKE_COMPOSIO:-}" ] || exit 44
    case "$args" in *" -w"*) printf '%s\\n' "$FAKE_COMPOSIO" ;; esac
    exit 0 ;;
esac
exit 44
"""


def aux_tasks_decided():
    """AUX_TEXT_TASKS + AUX_TASKS_ON_THE_BRAIN + AUX_TASKS_NOT_OURS as the
    script defines them.

    Read out of the source rather than imported, the way `plugin_keep` does
    and for the same reason — the file name has a hyphen, and a copy of the
    list in this file could drift from the one that is actually used."""
    src = open(SCRIPT, encoding="utf-8").read()
    names = set()
    for const in ("AUX_TEXT_TASKS", "AUX_TASKS_ON_THE_BRAIN", "AUX_TASKS_NOT_OURS"):
        m = re.search(const + r"\s*=\s*\((.*?)\)", src, re.S)
        if not m:
            raise AssertionError("%s not found in configure-hermes.py" % const)
        names.update(re.findall(r'"([a-z_]+)"', m.group(1)))
    return names


def plugin_keep():
    """KEEP_BACKUPS as the script defines it, so the test cannot drift."""
    with open(SCRIPT, encoding="utf-8") as f:
        for line in f:
            if line.startswith("KEEP_BACKUPS = "):
                return int(line.split("=", 1)[1].strip())
    raise AssertionError("KEEP_BACKUPS not found in configure-hermes.py")


class ConfigureFixture(unittest.TestCase):
    """setUp, tearDown and the helpers — no tests of its own.

    Split out from ConfigureHermesTest so a second test class can reuse the
    scratch tree without inheriting (and re-running) fifty unrelated tests:
    subclassing a TestCase that has tests runs them again, which cost five
    minutes a suite before this was noticed.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-configure-test-")
        self.hermes_home = os.path.join(self.tmp, "hermes")
        self.moe_home = os.path.join(self.tmp, "moe")
        shutil.copytree(FIXTURE, os.path.join(self.moe_home, "memory"))
        os.makedirs(os.path.join(self.moe_home, "connectors"))
        with open(os.path.join(self.moe_home, "connectors", "telegram-bot.json"), "w") as f:
            json.dump({"allowed_chat_ids": [123456789], "bot_username": "test_bot"}, f)
        os.makedirs(os.path.join(self.moe_home, ".claude"))
        with open(os.path.join(self.moe_home, ".claude", "settings.json"), "w") as f:
            json.dump({"permissions": {"deny": ["Bash(sudo *)", "Bash(rm -rf *)"]}}, f)
        self.stub = os.path.join(self.tmp, "security")
        with open(self.stub, "w") as f:
            f.write(SECURITY_STUB)
        os.chmod(self.stub, 0o755)
        # Every hook the config points at must exist and be executable for
        # --check. There are two now: the confirm-before-send gate and the
        # Composio clock/budget gate (HERMES-SURFACES §3.1a). The list is
        # taken from configure-hermes's own HOOK_BASENAMES rather than spelled
        # again here, so a third hook arrives in the fixture the moment it is
        # shipped instead of failing every test in this file with a missing
        # file — which is a fixture problem wearing a bug's clothes.
        hook_dir = os.path.join(self.moe_home, "hermes", "hooks")
        os.makedirs(hook_dir)
        self.hooks = {}
        for basename in configure.HOOK_BASENAMES:
            path = os.path.join(hook_dir, basename)
            with open(path, "w") as f:
                f.write("#!/bin/bash\nexit 0\n")
            os.chmod(path, 0o755)
            self.hooks[basename] = path
        # Kept as the send gate specifically: the tests that make a hook
        # unreadable or non-executable are about THAT gate.
        self.hook = self.hooks["confirm-send.sh"]
        self.cfg_path = os.path.join(self.hermes_home, "config.yaml")
        self.env_path = os.path.join(self.hermes_home, ".env")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, *extra, **kw):
        env = dict(os.environ)
        env.update({
            "MOE_SECURITY_BIN": self.stub,
            "FAKE_TG": kw.get("tg", "123:FAKE-TOKEN"),
            "FAKE_OAUTH": "1" if kw.get("oauth", True) else "",
            # Belt and braces: even a code path that forgot --hermes-home
            # would land in the scratch dir, not the real one.
            "HOME": self.tmp,
            # The driver probe resolves the hermes-agent checkout from the
            # running venv when the scratch HERMES_HOME has none, so without
            # this a test run could reach the real Hermes and start a real
            # cua-driver download. Tests that want the step set it to "".
            "MOE_SKIP_DRIVER_INSTALL": kw.get("driver_env", "1"),
        })
        if kw.get("hermes_bin"):
            env["MOE_HERMES_BIN"] = kw["hermes_bin"]
        env.update(kw.get("env_extra") or {})
        if kw.get("no_driver"):
            # Hermes's own resolver honours this and does not fall back, so the
            # readiness probe reports "no driver" on a machine that has one.
            env["HERMES_CUA_DRIVER_CMD"] = os.path.join(self.tmp, "no-such-cua-driver")
        env.pop("HERMES_HOME", None)
        env.pop("MOE_HOME", None)
        p = subprocess.run(
            [sys.executable, SCRIPT, "--hermes-home", self.hermes_home,
             "--moe-home", self.moe_home] + list(extra),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, env=env)
        return p.returncode, p.stdout

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def cfg(self):
        return yaml.safe_load(self.read(self.cfg_path))

    def env_values(self):
        out = {}
        for line in self.read(self.env_path).splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                out[k] = v
        return out

    def write_env(self, updates):
        """Set keys in the scratch .env the way a connect script would."""
        lines = [l for l in self.read(self.env_path).splitlines()
                 if "=" not in l or l.split("=", 1)[0] not in updates]
        lines += ["%s=%s" % (k, v) for k, v in updates.items()]
        with open(self.env_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def mode(self, path):
        return stat.S_IMODE(os.stat(path).st_mode)



class TheHermesCliIsAStub(ConfigureFixture):
    """The skills step, which nothing here covered — and the proof that no
    test in this module reaches the real `hermes` CLI or the network."""

    IDS = list(configure.MOE_SKILLS)

    def test_a_fresh_home_installs_each_skill_once_through_the_cli(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        calls = [c for c in hermes_stub_calls(self.hermes_home) if c.startswith("skills install ")]
        self.assertEqual(calls, ["skills install %s --yes" % i for i in self.IDS])
        for ident in self.IDS:
            parts = ident.split("/")
            self.assertTrue(os.path.isdir(os.path.join(self.hermes_home, "skills", *parts[1:])), ident)
            self.assertIn("skill %s" % parts[-1], out)

    def test_a_second_run_asks_the_cli_for_nothing(self):
        """`a steady state costs nothing`: the directory is checked first."""
        self.run_script()
        before = len(hermes_stub_calls(self.hermes_home))
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(len(hermes_stub_calls(self.hermes_home)), before, "the CLI was called again")

    def test_a_skill_the_hub_cannot_fetch_is_a_note_not_a_tick(self):
        """The CLI exits 0 when it fails. The directory is the proof."""
        code, out = self.run_script(env_extra={"MOE_STUB_SKILLS_FAIL": "1"})
        self.assertEqual(code, 0, out)
        name = self.IDS[0].split("/")[-1]
        self.assertIn("skill %s not installed" % name, out)
        self.assertIn("Could not fetch", out)
        self.assertFalse(os.path.isdir(os.path.join(self.hermes_home, "skills", *self.IDS[0].split("/")[1:])))

    def test_dry_run_does_not_call_the_cli(self):
        code, out = self.run_script("--dry-run")
        self.assertEqual(code, 0, out)
        self.assertEqual(hermes_stub_calls(self.hermes_home), [])
        self.assertFalse(os.path.isdir(os.path.join(self.hermes_home, "skills")), "a dry run made a skills directory")

    def test_the_seam_is_what_every_run_in_this_module_uses(self):
        self.assertEqual(os.environ.get("MOE_HERMES_BIN"), HERMES_STUB)
        self.assertEqual(configure.hermes_cli("/no/such/agent"), HERMES_STUB)


class EraseAndDeleteTest(ConfigureFixture):
    """Slice F of consent (CLOUD-REMAINING D9.11, D9.12): what configure-hermes
    does for Delete my account and Erase Memoe from this Mac."""

    KEY = "ak_" + "1" * 24

    def env_text(self):
        return self.read(self.env_path) if os.path.exists(self.env_path) else ""

    def seed_env(self, text):
        os.makedirs(self.hermes_home, exist_ok=True)
        with open(self.env_path, "w") as f:
            f.write(text)

    def deny(self):
        with open(self.cfg_path, encoding="utf-8") as f:
            return (yaml.safe_load(f).get("approvals") or {}).get("deny") or []

    def test_a_copied_composio_key_leaves_env_when_its_keychain_item_goes(self):
        """After a 202, CloudSync removes moe-composio-scoped and re-runs this
        script. The copy it made in .env — and the URL made with it — must go,
        or Hermes goes on calling a deleted project."""
        self.seed_env("COMPOSIO_MCP_URL=https://example.invalid/mcp\n")
        _, out = self.run_script(env_extra={"FAKE_COMPOSIO": self.KEY})
        text = self.env_text()
        self.assertIn("COMPOSIO_API_KEY=" + self.KEY, text, out)
        self.assertIn("MOE_COMPOSIO_KEY_SOURCE=keychain", text, out)
        _, out = self.run_script()          # the item is gone: the stub answers 44
        text = self.env_text()
        for name in ("COMPOSIO_API_KEY", "COMPOSIO_MCP_URL", "MOE_COMPOSIO_KEY_SOURCE"):
            self.assertNotIn(name, text, "%s survived the deletion:\n%s\n%s" % (name, text, out))

    def test_render_env_removes_a_key_on_none(self):
        """The one writer of .env: None drops the line (every copy of it) and
        writes nothing for a key that is not there; "" still writes KEY=."""
        text, changed = configure.render_env("A=1\nB=2\nA=3\n", {"A": None, "C": None})
        self.assertEqual(text, "B=2\n")
        self.assertEqual(changed, ["A"])
        text, changed = configure.render_env("B=2\n", {"C": None})
        self.assertEqual((text, changed), ("B=2\n", []))
        text, _ = configure.render_env("A=1\n", {"A": ""})
        self.assertEqual(text, "A=\n")

    def test_a_key_a_person_put_in_env_is_left(self):
        """No marker: the key is not Moe's copy, and nothing removes it."""
        self.seed_env("COMPOSIO_API_KEY=%s\nCOMPOSIO_MCP_URL=https://example.invalid/mcp\n" % self.KEY)
        self.run_script()
        self.assertIn("COMPOSIO_API_KEY=" + self.KEY, self.env_text())

    def test_a_keychain_that_cannot_be_read_is_not_absent(self):
        """A locked keychain or a failing tool must not cost the key."""
        failing = os.path.join(self.tmp, "security-fails")
        with open(failing, "w") as f:
            f.write("#!/bin/bash\nexit 1\n")
        os.chmod(failing, 0o755)
        self.seed_env("COMPOSIO_API_KEY=%s\nCOMPOSIO_MCP_URL=https://example.invalid/mcp\n"
                      "MOE_COMPOSIO_KEY_SOURCE=keychain\n" % self.KEY)
        self.run_script(env_extra={"MOE_SECURITY_BIN": failing})
        self.assertIn("COMPOSIO_API_KEY=" + self.KEY, self.env_text())

    def test_the_eraser_is_denied_to_hermess_shell(self):
        """`Moe --erase-mac` is started by the app alone; the shell gate refuses
        it outright, however the path to the binary is spelled."""
        import fnmatch
        self.run_script()
        deny = self.deny()

        def denied(cmd):
            return any(fnmatch.fnmatch(cmd.lower(), str(r).lower()) for r in deny)

        for cmd in ("/Applications/Memoe.app/Contents/MacOS/Moe --erase-mac",
                    "'/Applications/Memoe Dev.app/Contents/MacOS/Moe' --erase-mac < /tmp/request",
                    "echo {} | Moe --erase-mac",
                    ".build/debug/Moe --erase-mac-spawn"):
            self.assertTrue(denied(cmd), "the eraser is reachable from the shell: %r" % cmd)
        for cmd in ("Moe --erase-plan", "ls -la ~/Library/Application\\ Support/Moe"):
            self.assertFalse(denied(cmd), "a deny rule blocks ordinary work: %r" % cmd)


class ConfigureHermesTest(ConfigureFixture):
    # -- fresh install --------------------------------------------------

    def test_fresh_install_writes_everything(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        # provider and default, not the whole dict: `model` also carries
        # `context_length` (1792b81) and will carry more. Every other
        # assertion in this file names the keys it means; this one pinned the
        # object and broke the next time somebody added one, which is how a
        # test ends up describing history instead of intent.
        self.assertEqual(cfg["model"]["provider"], "claude-code-cli")
        self.assertEqual(cfg["model"]["default"], "sonnet")
        api = cfg["platforms"]["api_server"]
        self.assertTrue(api["enabled"])
        self.assertEqual((api["host"], api["port"]), ("127.0.0.1", 8642))
        self.assertEqual(len(api["key"]), 32)
        self.assertTrue(cfg["platforms"]["telegram"]["enabled"])
        # Both of Moe's pre_tool_call gates are installed, and BOTH are
        # fail_closed. Indexed by name rather than by position: the order in
        # the fragment is not a shipped decision and a test that pins it fails
        # for the wrong reason the day one is reordered.
        hooks = {os.path.basename(h["command"]): h
                 for h in cfg["hooks"]["pre_tool_call"]}
        self.assertEqual(sorted(hooks), sorted(configure.HOOK_BASENAMES))
        for basename, hook in hooks.items():
            self.assertTrue(hook["fail_closed"],
                            "%s must be fail_closed: a gate that opens when it "
                            "is confused is not a gate" % basename)
        # The send gate waits on a human reading a dialog; the budget gate
        # reads two small files. Different numbers, and the reason each is
        # what it is belongs with the number.
        self.assertEqual(hooks["confirm-send.sh"]["timeout"], 300)
        self.assertEqual(hooks["composio-budget.sh"]["timeout"], 15)
        self.assertTrue(cfg["hooks_auto_accept"])
        self.assertEqual(cfg["tools"]["terminal"]["security_mode"], "auto")
        self.assertEqual(cfg["claude_code"]["oauth_token_env"], "CLAUDE_CODE_OAUTH_TOKEN")
        self.assertEqual(cfg["claude_code"]["deny"], ["Bash(sudo *)", "Bash(rm -rf *)"])

        env = self.env_values()
        self.assertEqual(env["API_SERVER_KEY"], api["key"])
        self.assertEqual(env["TELEGRAM_BOT_TOKEN"], "123:FAKE-TOKEN")
        self.assertEqual(env["TELEGRAM_ALLOWED_USERS"], "123456789")
        self.assertEqual(env["HERMES_TERMINAL_SECURITY_MODE"], "auto")
        self.assertEqual(self.mode(self.env_path), 0o600)
        self.assertEqual(self.mode(os.path.join(self.hermes_home, "claude-code")), 0o700)
        self.assertFalse(os.path.exists(os.path.join(self.hermes_home, "claude-code", "settings.json")))

        self.assertTrue(os.path.exists(os.path.join(self.hermes_home, "memories", "USER.md")))
        self.assertTrue(os.path.exists(os.path.join(self.hermes_home, "moe-migration.json")))
        # Secrets never appear in the output.
        self.assertNotIn("FAKE-TOKEN", out)
        self.assertNotIn(api["key"], out)
        self.assertIn("Moe starts Hermes and supplies the sign-in from the Keychain", out)
        self.assertIn('export CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -a moe '
                      '-s moe-child-oauth -w)" && hermes gateway --accept-hooks run', out)
        # The token is never written to .env — the Keychain is its home.
        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", self.env_values())
        self.assertIn("Hermes loaded api_server on 127.0.0.1:8642", out)
        self.assertIn("claude_code.deny (2 rules from ~/.moe/.claude/settings.json) (applies on first start)", out)

    def test_deny_seed_reports_existing_settings_json(self):
        os.makedirs(os.path.join(self.hermes_home, "claude-code"))
        with open(os.path.join(self.hermes_home, "claude-code", "settings.json"), "w") as f:
            f.write("{}")
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("settings.json already exists → unchanged", out)

    def test_model_flag(self):
        code, out = self.run_script("--model", "sonnet")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["model"]["default"], "sonnet")
        # The alias Hermes drops on load is never left behind.
        self.assertNotIn("model", self.cfg()["model"])

    # -- idempotence ---------------------------------------------------------

    def test_rerun_changes_nothing(self):
        self.run_script()
        before_cfg, before_env = self.read(self.cfg_path), self.read(self.env_path)
        cfg_mtime = os.stat(self.cfg_path).st_mtime_ns
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.read(self.cfg_path), before_cfg)
        self.assertEqual(self.read(self.env_path), before_env)
        self.assertEqual(os.stat(self.cfg_path).st_mtime_ns, cfg_mtime)
        self.assertFalse([f for f in os.listdir(self.hermes_home) if f.endswith(".bak")])
        self.assertIn("config.yaml (already merged)", out)
        self.assertIn("already migrated", out)

    # -- user edits survive -------------------------------------------------

    def test_user_edits_preserved(self):
        os.makedirs(self.hermes_home)
        with open(self.cfg_path, "w") as f:
            f.write(
                "# my note\n"
                "model:\n  provider: openrouter\n  model: some/other-model\n"
                "tools:\n  terminal:\n    security_mode: approval-required\n"
                "hooks:\n  pre_tool_call:\n"
                "    - matcher: terminal\n      command: ~/mine/audit.sh\n"
                "compression:\n  enabled: true\n"
            )
        with open(self.env_path, "w") as f:
            f.write("OPENROUTER_API_KEY=keep-me\nAPI_SERVER_KEY=0123456789abcdef0123456789abcdef\n")
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        # A provider the user (or Moe's Brain pane) already chose is kept,
        # and so is its model; only an explicit --provider switches it.
        self.assertEqual(cfg["model"]["provider"], "openrouter")
        self.assertEqual(cfg["model"]["default"], "some/other-model")
        self.assertNotIn("setup-token", out.split("Notes")[0])
        code, out = self.run_script("--provider", "claude-code-cli")
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        # Provider switched, and with it the model, since "some/other-model"
        # was a choice about openrouter.
        self.assertEqual(cfg["model"]["provider"], "claude-code-cli")
        self.assertEqual(cfg["model"]["default"], "sonnet")
        # Everything the user chose that Moe has no reason to change.
        self.assertEqual(cfg["tools"]["terminal"]["security_mode"], "approval-required")
        self.assertEqual(cfg["compression"], {"enabled": True})
        # The user's own hook survives, FIRST, and Moe's are appended after
        # it. That ordering is the shipped decision this pins: merge_hooks
        # matches Moe's entries by basename and leaves every other hook alone,
        # so a hook somebody added by hand is never displaced or dropped.
        hooks = cfg["hooks"]["pre_tool_call"]
        self.assertEqual(len(hooks), 1 + len(configure.HOOK_BASENAMES))
        self.assertEqual(hooks[0]["command"], "~/mine/audit.sh")
        self.assertEqual(
            sorted(os.path.basename(h["command"]) for h in hooks[1:]),
            sorted(configure.HOOK_BASENAMES))
        env = self.env_values()
        self.assertEqual(env["OPENROUTER_API_KEY"], "keep-me")
        self.assertEqual(env["API_SERVER_KEY"], "0123456789abcdef0123456789abcdef")
        self.assertEqual(cfg["platforms"]["api_server"]["key"], env["API_SERVER_KEY"])
        # The env mirror follows the user's YAML choice, not Moe's default.
        self.assertEqual(env["HERMES_TERMINAL_SECURITY_MODE"], "approval-required")
        self.assertIn("Kept your value", out)
        # Comments were lost, so a backup was taken and announced.
        baks = [f for f in os.listdir(self.hermes_home) if f.startswith("config.yaml.") and f.endswith(".bak")]
        # Two runs in the same second share a name; the first backup holds the note.
        self.assertTrue(baks)
        self.assertTrue(any("# my note" in self.read(os.path.join(self.hermes_home, b)) for b in baks))
        self.assertTrue(any(b in out for b in baks))

    def test_env_duplicates_dropped_and_style_preserved(self):
        os.makedirs(self.hermes_home)
        with open(self.env_path, "w", newline="") as f:
            f.write("export API_SERVER_KEY='0123456789abcdef0123456789abcdef'\r\n"
                    "OTHER=1\r\n"
                    "API_SERVER_KEY=stale-duplicate-that-dotenv-would-prefer\r\n")
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        with open(self.env_path, newline="") as f:
            raw = f.read()
        lines = raw.split("\r\n")
        self.assertNotIn("\n", raw.replace("\r\n", ""))          # CRLF kept throughout
        # dotenv is last-wins, so the duplicate was the key Hermes actually
        # used; that value survives, in the first line's style.
        self.assertEqual(lines[0], "export API_SERVER_KEY='stale-duplicate-that-dotenv-would-prefer'")
        self.assertEqual(lines[1], "OTHER=1")
        self.assertEqual(sum(1 for l in lines if l.startswith(("API_SERVER_KEY", "export API_SERVER_KEY"))), 1)
        self.assertEqual(self.env_values()["TELEGRAM_BOT_TOKEN"], "123:FAKE-TOKEN")
        # A second run finds the styled line unchanged and rewrites nothing.
        before = raw
        code, out = self.run_script()
        with open(self.env_path, newline="") as f:
            self.assertEqual(f.read(), before)
        self.assertIn(".env (all keys present)", out)

    def test_refresh_telegram_prefers_keychain(self):
        self.run_script(tg="111:OLD")
        self.assertEqual(self.env_values()["TELEGRAM_BOT_TOKEN"], "111:OLD")
        self.run_script(tg="222:NEW")
        self.assertEqual(self.env_values()["TELEGRAM_BOT_TOKEN"], "111:OLD")   # default: .env kept
        code, out = self.run_script("--refresh-telegram", tg="222:NEW")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.env_values()["TELEGRAM_BOT_TOKEN"], "222:NEW")
        self.assertNotIn("222:NEW", out)

    def test_second_model_run_keeps_user_model(self):
        self.run_script()
        cfg = self.cfg()
        cfg["model"]["default"] = "sonnet"
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["model"]["default"], "sonnet")

    def test_stale_model_alias_is_migrated_not_lost(self):
        """`model: opus` in config.yaml is a key Hermes DELETES on load.

        Its loader canonicalises to `model.default` and pops `model`/`name`,
        so a value written to the alias is invisible to the runtime and gone
        on the next Hermes write. Measured on the developer's own machine:
        config.yaml said `model: opus` while load_config_readonly() returned
        {"provider": "claude-code-cli", "default": "haiku"} and all 66 log
        lines read model=haiku. Moe wrote the alias, so Moe's model choice had
        never once taken effect, and --check reported a value nothing honoured.

        The value moves rather than being replaced: an alias still on disk is
        the last thing somebody chose, and that intent should survive the
        move to the key that works."""
        self.run_script()
        cfg = self.cfg()
        del cfg["model"]["default"]
        cfg["model"]["model"] = "some-deliberate-choice"
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        after = self.cfg()["model"]
        self.assertEqual(after["default"], "some-deliberate-choice")
        self.assertNotIn("model", after)
        self.assertNotIn("name", after)

    def test_refused_keys_are_removed_from_a_config_that_has_them(self):
        """The enforced profile (§6), tested on a config that actually holds them.

        The `assertNotIn` further down used to run on a config that never had
        the keys, and Moe never writes them, so it asserted that a thing nobody
        did did not happen — this repo's own worst pattern, a check that
        reports PASS forever. So this test PUTS the keys there first. Break
        apply_refused_keys and it fails; delete a REFUSED_KEYS entry and it
        fails.

        `agent.disabled_toolsets` is deliberately NOT among the removals — see
        test_disabled_toolsets_is_never_stripped for why removing it would be
        a capability loss, not a tidy-up."""
        self.run_script()
        cfg = self.cfg()
        cfg.setdefault("code_execution", {})["kernel_mode"] = "per-call"
        cfg["custom_toolsets"] = {"mine": ["web"]}
        cfg["toolsets"] = ["web", "kanban"]
        cfg["compression"] = {"threshold": 0.9}
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertIn(code, (0, 2), out)
        after = self.cfg()

        # Removed, and said so — a silent deletion of somebody's key is worse
        # than the confusion it fixes.
        self.assertNotIn("kernel_mode", after.get("code_execution") or {})
        self.assertIn("code_execution.kernel_mode REMOVED", out)
        self.assertNotIn("custom_toolsets", after)
        self.assertIn("custom_toolsets REMOVED", out)

        # Not removed: something reads them, so they stay and are reported.
        self.assertEqual(after.get("toolsets"), ["web", "kanban"])
        self.assertIn("toolsets is set and left alone", out)
        self.assertEqual(after.get("compression"), {"threshold": 0.9})
        self.assertIn("does nothing on claude-code-cli", out)

    def test_disabled_toolsets_is_never_stripped(self):
        """`agent.disabled_toolsets` must survive a run. It is a REGRESSION
        TEST, and this docstring is the reason it exists.

        This file used to assert the OPPOSITE — that the key was removed on
        every launch — on the stated ground that it is "inert on the
        claude-code-cli child". That was measured on 2026-09-04 and it is
        false. The key is the ONLY config lever that removes a tool from the
        model on this runtime, and the path the earlier measurement missed is:

            gateway/platforms/api_server.py
              -> hermes_cli/tools_config.py::_get_platform_tools, which reads
                 platform_toolsets.<platform> and then subtracts
                 agent.disabled_toolsets LAST
              -> agent/agent_init.py: agent.tools -> agent.valid_tool_names
              -> agent/claude_code_runtime.py::bridged_tools_for, which filters
                 BRIDGED_TOOLS by valid_tool_names
              -> $HERMES_TOOL_BRIDGE_TOOLS -> the child's tools_to_offer(bridge=)

        Measured against the live install: `agent.disabled_toolsets:
        [memory, delegation]` takes `memory` and `delegate_task` off the model
        and changes nothing else.

        So a person who set this key meant it, and stripping it on every launch
        took a capability away silently — which is the exact failure the
        REFUSED_KEYS table exists to prevent, committed by the table itself.
        If a future change puts the key back in REFUSED_KEYS, this test is what
        says so. Do not "fix" it by deleting it.

        The falsifier for the consequence, on the real surface rather than on
        the file, is `./scripts/check-toolsurface.sh` — its check 5 fails when
        a bridged tool goes missing."""
        self.run_script()
        cfg = self.cfg()
        cfg.setdefault("agent", {})["disabled_toolsets"] = ["connectors", "clarify"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertIn(code, (0, 2), out)
        after = self.cfg()

        # Kept, byte for byte — not reordered, not trimmed, not emptied.
        self.assertEqual((after.get("agent") or {}).get("disabled_toolsets"),
                         ["connectors", "clarify"], out)
        # And never silently: a kept value that cancels a Moe feature is
        # exactly what a person needs told.
        self.assertIn("agent.disabled_toolsets is set and left alone", out)
        self.assertNotIn("agent.disabled_toolsets REMOVED", out)
        # The platform lists it can cancel are still written in full, so the
        # contradiction is visible in one file rather than resolved by us.
        self.assertIn("connectors", after["platform_toolsets"]["api_server"])
        self.assertIn("clarify", after["platform_toolsets"]["api_server"])

    def test_an_empty_disabled_toolsets_is_not_reported_as_set(self):
        """`[]` is Hermes's own default shape, not somebody's setting.

        `DEFAULT_CONFIG["agent"]["disabled_toolsets"]` is literally `[]`, so
        warning about it would put a line on the checklist for every stock
        config — and a warning that fires on the default is one people learn to
        scroll past, which is how the real one gets missed."""
        self.run_script()
        cfg = self.cfg()
        cfg.setdefault("agent", {})["disabled_toolsets"] = []
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertIn(code, (0, 2), out)
        self.assertNotIn("agent.disabled_toolsets is set and left alone", out)
        self.assertNotIn("agent.disabled_toolsets REMOVED", out)

    # There is deliberately NO test here pinning that apply_refused_keys runs
    # after apply_toolsets.
    #
    # There used to be one — test_refused_keys_are_stripped_after_the_toolset_
    # lists_are_written — and its stated reason was that "Hermes subtracts
    # agent.disabled_toolsets LAST, so it has to be removed last here too".
    # That is a non-sequitur: Hermes does subtract it last, and it says nothing
    # about the order of two independent edits in this script.
    #
    # A replacement WAS written — asserting that the platform_toolsets line
    # precedes the disabled_toolsets note — and then thrown away, because
    # mutation testing showed it could not fail.
    #
    # Measured 2026-09-04 by actually reversing the two calls in main():
    #   - all five disabled_toolsets tests above stayed green;
    #   - running the script on this fixture's scratch tree in both orders
    #     produced the same config.yaml and the same printed checklist, apart
    #     from the per-run temp path and a freshly generated claim-store key.
    # The mechanism: the two edits touch disjoint keys (apply_toolsets writes
    # platform_toolsets.*; apply_refused_keys touches only REFUSED_KEYS /
    # SUSPECT_KEYS), and the checklist prints in fixed SECTIONS — Report.emit
    # always prints "Written" before "Notes" — so the call order does not even
    # reach the output.
    #
    # So the order is not load-bearing, and a test asserting it would report
    # PASS forever while pinning nothing. This comment is the finding; adding
    # the test back would be adding a fifth member to the family of
    # cannot-fail checks this repo has been paying for.

    def test_keep_toolsets_does_not_change_the_disabled_toolsets_verdict(self):
        """The flag used to except this key from a strip. There is no strip.

        `--keep-toolsets` means "the toolset lists in this file are mine", and
        while `agent.disabled_toolsets` was in REFUSED_KEYS the flag was what
        spared it. It is in SUSPECT_KEYS now and is never removed, so the
        exception has nothing left to except — the key is kept either way, and
        this asserts the flag makes no difference rather than leaving a dead
        branch that reads like a live guard."""
        self.run_script()
        cfg = self.cfg()
        cfg.setdefault("agent", {})["disabled_toolsets"] = ["connectors"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script("--keep-toolsets")
        self.assertIn(code, (0, 2), out)
        self.assertEqual(self.cfg()["agent"]["disabled_toolsets"], ["connectors"])
        self.assertIn("agent.disabled_toolsets is set and left alone", out)
        # The two keys that ARE refused are still removed under the flag:
        # there is nothing to keep about a key nothing reads.
        cfg = self.cfg()
        cfg.setdefault("code_execution", {})["kernel_mode"] = "per-call"
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script("--keep-toolsets")
        self.assertIn(code, (0, 2), out)
        self.assertNotIn("kernel_mode", self.cfg().get("code_execution") or {})

    def test_removing_a_key_does_not_leave_an_empty_section(self):
        """`code_execution: {}` left behind reads as a section somebody set."""
        self.run_script()
        cfg = self.cfg()
        cfg.pop("code_execution", None)
        cfg["code_execution"] = {"kernel_mode": "session"}
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertIn(code, (0, 2), out)
        self.assertNotIn("code_execution", self.cfg())

    def test_platform_toolsets_keeps_mcp_scoping(self):
        """A bare MCP server name in platform_toolsets is an allowlist.

        Hermes reads a name there that is not a toolset as "scope this MCP
        server to this platform", and `no_mcp` as "no MCP servers here" — its
        own writer preserves them for exactly that reason. Moe's force_set
        replaced the whole list, so a user who scoped a server lost it on the
        next launch, silently, with the checklist reporting success."""
        self.run_script()
        cfg = self.cfg()
        cfg["mcp_servers"] = {"cloudflare": {"url": "https://example.invalid", "enabled": True}}
        cfg["platform_toolsets"]["api_server"] = ["web", "cloudflare"]
        cfg["platform_toolsets"]["telegram"] = ["hermes-telegram", "no_mcp"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        after = self.cfg()["platform_toolsets"]
        self.assertIn("cloudflare", after["api_server"])
        self.assertIn("no_mcp", after["telegram"])
        # Moe's own list is still fully applied around what it carried.
        self.assertIn("computer_use", after["api_server"])

    def test_upstream_migration_45s_connections_is_taken_back_once(self):
        """Hermes's config migration 45 (upstream, Sept 2026) appends the
        `connections` toolset — manage_connections, the tool that replaced
        `setup_mcp` and connects MCP servers on the model's say-so — to every
        explicit platform_toolsets list, once, and stamps the version. Moe's
        lists are a decision (a toolset Hermes ships later stays off until it
        is added to MOE_TOOLSETS), and "I'll connect an MCP for you" is one
        that was made against. So the next launch takes it back, and the one
        after that changes nothing: the migration does not run twice, so the
        two never fight."""
        self.run_script()
        cfg = self.cfg()
        for platform in ("api_server", "telegram"):
            cfg["platform_toolsets"][platform] = sorted(
                set(cfg["platform_toolsets"][platform]) | {"connections"})
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        first = self.cfg()["platform_toolsets"]
        for platform in ("api_server", "telegram"):
            self.assertNotIn("connections", first[platform])
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["platform_toolsets"], first)

    def test_gate_paths_are_denied(self):
        """approvals.deny protects the confirm gate's own files.

        Before this, Hermes's evaluator returned `allow` for
        `echo exit 0 > ~/.moe/tools/confirm.sh` while denying rm -rf, sudo and
        a write to Hermes's own config.yaml — one ungated call could turn
        confirm-before-send off for good."""
        self.run_script()
        deny = self.cfg()["approvals"]["deny"]
        self.assertIn("*/.moe/tools/confirm.s*", deny)
        self.assertIn("*/.moe/hermes/hooks/*", deny)
        # Assert the BEHAVIOUR, not the strings. fnmatch is what Hermes
        # evaluates these with (tools/approval.py), and a rule that matches
        # nothing would satisfy a string assertion perfectly.
        import fnmatch

        def denied(cmd):
            return any(fnmatch.fnmatch(cmd.lower(), r.lower()) for r in deny)

        for cmd in ("echo exit 0 > ~/.moe/tools/confirm.sh",
                    "echo exit 0 > $HOME/.moe/tools/confirm.sh",
                    "echo exit 0 > /Users/someone/.moe/tools/confirm.sh",
                    "echo x > ~/.moe/tools/confirm.s?",
                    "tee ~/.moe/tools/confirm.sh < /tmp/evil",
                    "cat /dev/null > ~/.moe/hermes/hooks/confirm-send.sh"):
            self.assertTrue(denied(cmd), "the gate is reachable: %r" % cmd)

        # ~/.moe/tools/ is the TOOLBELT, not the gate. apple.sh, mac.sh, git.sh
        # live beside confirm.sh, and Moe's own system prompt tells the model to
        # run apple.sh by that path. A directory-level rule here shipped once and
        # blocked the most common thing Moe does; nothing caught it because every
        # test named the gate. These are why the protection is file-level.
        for cmd in ("~/.moe/tools/apple.sh calendar today",
                    "$HOME/.moe/tools/mac.sh screenshot",
                    "bash ~/.moe/tools/git.sh status",
                    "python3 ~/.moe/tools/name-numbers.py",
                    "ls -la ~/.moe/tools",
                    "cat ~/.moe/context/messages.md",
                    "python3 ~/.moe/connectors/gmail.py status"):
            self.assertFalse(denied(cmd), "a deny rule blocks ordinary work: %r" % cmd)

    def test_gate_paths_are_denied_under_the_real_home_too(self):
        """W1-A (2026-11-12). ~/.moe is a link; the home is
        ~/Library/Application Support/Moe and the app exports that as
        MOE_HOME. Every gate rule spelled the link, and three of ten had a
        second spelling, so `echo x > "<real home>/tools/confirm.sh"` was
        allowed by this layer while the ~/.moe spelling of the same file was
        refused. Each protected path must be denied under BOTH."""
        import fnmatch
        self.run_script()
        deny = self.cfg()["approvals"]["deny"]

        def denied(cmd):
            return any(fnmatch.fnmatch(cmd.lower(), str(r).lower()) for r in deny)

        tails = ("tools/confirm.sh", "tools/confirm.s?", "tools/gate.sh",
                 "hermes/hooks/confirm-send.sh", "hermes/hooks/composio-budget.sh",
                 "gate/policy.json", "connectors/gmail.manifest",
                 ".claude/settings.json", "cloud/tier.json", "composio/limits.json")
        spellings = ("echo x > ~/Library/Application\\ Support/Moe/%s",
                     'echo x > "$HOME/Library/Application Support/Moe/%s"',
                     "echo x > '/Users/someone/Library/Application Support/Moe/%s'",
                     'echo x > "$HOME/Library/Application Support/Moe"/%s',
                     'cd "$HOME/Library/Application Support/Moe/notes" && tee ../%s < /tmp/evil',
                     # Moe Dev keeps its own home beside it.
                     'echo x > "$HOME/Library/Application Support/Moe Dev/%s"')
        for tail in tails:
            # The link spelling first: the control. If THIS is not denied the
            # loop below proves nothing about the real home.
            self.assertTrue(denied("echo x > ~/.moe/%s" % tail), "control: ~/.moe/%s" % tail)
            for spelling in spellings:
                cmd = spelling % tail
                self.assertTrue(denied(cmd), "the gate is reachable: %r" % cmd)
        self.assertTrue(denied('mv "$HOME/Library/Application Support/Moe/hermes/hooks/" /tmp/off'))

        # The toolbelt and the person's own files, by the real path.
        for cmd in ('"$HOME/Library/Application Support/Moe/tools/apple.sh" calendar today',
                    "~/Library/Application\\ Support/Moe/tools/mac.sh screenshot",
                    'ls -la "$HOME/Library/Application Support/Moe/tools"',
                    'cat "$HOME/Library/Application Support/Moe/context/messages.md"',
                    'python3 "$HOME/Library/Application Support/Moe/connectors/gmail.py" status',
                    'ls "$HOME/Library/Application Support"'):
            self.assertFalse(denied(cmd), "a deny rule blocks ordinary work: %r" % cmd)

    def test_a_relocated_home_gets_the_gate_rules_too(self):
        """A MOE_HOME that is neither spelling — the away machine's
        $HERMES_HOME/moe-home, a test home — had no rule at all."""
        import fnmatch
        self.run_script()
        deny = self.cfg()["approvals"]["deny"]

        def denied(cmd):
            return any(fnmatch.fnmatch(cmd.lower(), str(r).lower()) for r in deny)

        for home in (self.moe_home, os.path.realpath(self.moe_home)):
            for tail in ("tools/confirm.sh", "hermes/hooks/confirm-send.sh",
                         ".claude/settings.json", "gate/policy.json"):
                cmd = "echo x > %s/%s" % (home, tail)
                self.assertTrue(denied(cmd), "the gate is reachable: %r" % cmd)
            self.assertFalse(denied("%s/tools/apple.sh calendar today" % home))
            self.assertFalse(denied("cat %s/context/messages.md" % home))
        # …and nothing is written for a home the constants already cover.
        self.assertEqual(configure.home_deny_globs("/Users/someone/.moe"), [])
        self.assertEqual(
            configure.home_deny_globs("/Users/someone/Library/Application Support/Moe"), [])
        self.assertEqual(
            configure.home_deny_globs("/Users/someone/Library/Application Support/Moe Dev"), [])
        self.assertIn("*/opt/data/moe-home/tools/confirm.s*",
                      configure.home_deny_globs("/opt/data/moe-home"))

    def test_secrets_are_denied_to_the_shell(self):
        """Security review S2 (2026-10-19): the model's shell could read every
        secret Moe keeps. Asserted against Hermes's own matcher when it is
        importable (its de-obfuscated variants), else fnmatch as above."""
        self.run_script()
        deny = self.cfg()["approvals"]["deny"]
        import fnmatch
        try:
            sys.path.insert(0, os.environ.get("MOE_TEST_HERMES_AGENT")
                            or os.path.expanduser("~/.hermes/hermes-agent"))
            from tools import approval_floors as floors
            def denied(cmd):
                saved = floors._ctx._get_approval_config
                floors._ctx._get_approval_config = lambda: {"deny": deny}
                try:
                    return floors._match_user_deny_rule(cmd) is not None
                finally:
                    floors._ctx._get_approval_config = saved
        except Exception:
            def denied(cmd):
                return any(fnmatch.fnmatch(cmd.lower(), r.lower()) for r in deny)
        for cmd in ("cat ~/.moe/cloud/admin-token",
                    "cd ~/.moe && cat cloud/admin-token",
                    "cat ~/Library/Application\\ Support/Moe/cloud/admin-token",
                    'cat "$HOME/Library/Application Support/Moe/cloud/credential.json"',
                    "grep KEY ~/.hermes/.e?v",
                    "cat ~/.hermes/.env.bak-20261009T170804Z",
                    "security find-generic-password -s moe-composio-scoped -w",
                    "/usr/bin/security find-internet-password -gs example.com",
                    "security dump-keychain -d",
                    "security export -k login.keychain -o /tmp/k.p12",
                    "cat ~/.moe/thread-keys.json",
                    "cat ~/Library/Application\\ Support/Moe/gate/session-sends.json"):
            self.assertTrue(denied(cmd), "a secret is reachable from the shell: %r" % cmd)
        for cmd in ("~/.moe/tools/apple.sh calendar today",
                    "security list-keychains",
                    "export PATH=$PATH:/opt/bin && ls",
                    "cat ~/Library/Application\\ Support/Moe/context/messages.md",
                    "ls ~/Documents"):
            self.assertFalse(denied(cmd), "a deny rule blocks ordinary work: %r" % cmd)

    def test_withdrawn_gate_rules_are_pruned(self):
        """approvals.deny is append-only, so a rule Moe got wrong is forever.

        `*/.moe/tools*` is exactly that: it shipped, it blocked the toolbelt,
        and appending its replacement did not remove it. Moe prunes its own
        withdrawn rules by exact string; anything else in the list is the
        user's and is left alone."""
        self.run_script()
        cfg = self.cfg()
        cfg["approvals"]["deny"] = (["*/.moe/tools*", "mv */.moe*", "my own rule *"]
                                    + list(cfg["approvals"]["deny"]))
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        deny = self.cfg()["approvals"]["deny"]
        self.assertNotIn("*/.moe/tools*", deny)
        self.assertNotIn("mv */.moe*", deny)
        self.assertIn("my own rule *", deny)
        self.assertIn("*/.moe/tools/confirm.s*", deny)

    def test_runtime_bounds_are_set(self):
        """Hermes ships these unset; an always-on assistant needs them bounded."""
        self.run_script()
        cfg = self.cfg()
        self.assertEqual(cfg["claude_code"]["max_sessions"], 4)
        self.assertEqual(cfg["agent"]["max_turns"], 200)
        self.assertEqual(cfg["cron"]["model"], "haiku")
        self.assertEqual(cfg["tools"]["tool_search"]["listing_max_tokens"], 8000)
        # set_if_absent throughout: a value the user chose is theirs.
        cfg["claude_code"]["max_sessions"] = 1
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        self.run_script()
        self.assertEqual(self.cfg()["claude_code"]["max_sessions"], 1)

    def test_no_prewarmed_spares_and_the_old_one_is_retracted(self):
        """Measured 7 spares minted, 0 taken: Moe keeps none warm. An
        install carrying Moe's earlier 1 is moved to 0; another value is the
        person's."""
        self.run_script()
        cfg = self.cfg()
        self.assertEqual(cfg["claude_code"]["prewarm_spares"], 0)
        cfg["claude_code"]["prewarm_spares"] = 1
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.cfg()["claude_code"]["prewarm_spares"], 0)
        cfg["claude_code"]["prewarm_spares"] = 3
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        self.run_script()
        self.assertEqual(self.cfg()["claude_code"]["prewarm_spares"], 3)

    def test_turn_timeout_is_a_ceiling_and_the_old_leash_is_repaired(self):
        """300 was Moe's own default until 2026-09-02 and cut a five-minute
        research turn off mid-step; it is moved to 1800. A value a person set
        is not touched, and the silence guard stays what it was."""
        self.run_script()
        cfg = self.cfg()
        self.assertEqual(cfg["claude_code"]["turn_timeout"], 1800)
        self.assertEqual(cfg["claude_code"]["silence_timeout"], 120)
        # An install written by the earlier Moe: repaired.
        cfg["claude_code"]["turn_timeout"] = 300
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.cfg()["claude_code"]["turn_timeout"], 1800)
        self.assertIn("was 300, Moe's earlier default", out)
        # A value the user chose: theirs.
        cfg["claude_code"]["turn_timeout"] = 900
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        self.run_script()
        self.assertEqual(self.cfg()["claude_code"]["turn_timeout"], 900)

    def test_telegram_home_channel_from_the_owner(self):
        """Cron's only route to a person.

        `deliver: all` / `origin` resolve through TELEGRAM_HOME_CHANNEL, and
        connect-telegram-bot.sh writes TELEGRAM_ALLOWED_USERS and stops there —
        so every proactive path degraded to a file under ~/.hermes/cron/output/
        that nobody opens. The first allowed id is the owner, because that
        script seeds the list with getMe's owner before anyone else is added."""
        self.run_script()
        env = self.env_values()
        self.assertEqual(env["TELEGRAM_HOME_CHANNEL"], env["TELEGRAM_ALLOWED_USERS"].split(",")[0])
        # Theirs once they have set it.
        self.write_env({"TELEGRAM_HOME_CHANNEL": "999"})
        self.run_script()
        self.assertEqual(self.env_values()["TELEGRAM_HOME_CHANNEL"], "999")

    def use_api_key_brain(self, provider="deepseek", model="deepseek-chat"):
        """Switch the scratch config to an API-key brain.

        The vision-pinning tests below need one. Moe's default brain is
        `claude-code-cli`, and since 2026-09-07 a CLI-subscription brain is
        deliberately NOT given a pinned auxiliary vision provider — it serves
        its own vision through the CLI, and a pin written on the user's behalf
        turns a fallback chain into the one thing that can fail. That is the
        behaviour `test_a_cli_subscription_brain_is_not_pinned` asserts.

        So these tests say what they mean: they are about which provider gets
        pinned WHEN one is pinned at all.
        """
        cfg = self.cfg()
        cfg.setdefault("model", {})["provider"] = provider
        cfg["model"]["default"] = model
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)

    def test_vision_needs_a_key_it_can_reach(self):
        """The lane is worth nothing without a key, and writing a provider Moe
        cannot reach only moves the failure later."""
        code, out = self.run_script(env_extra={"MOE_SKIP_VISION": "1"})
        self.assertEqual(code, 0, out)
        self.assertNotIn("vision", self.cfg().get("auxiliary", {}))
        self.use_api_key_brain()
        # And with no key reachable at all, the lane stays off and says why.
        code, out = self.run_script(env_extra={"OPENAI_API_KEY": ""})
        self.assertEqual(code, 0, out)
        if "vision" not in (self.cfg().get("auxiliary") or {}):
            self.assertIn("vision_analyze stays off", out)

    def test_vision_repairs_a_missing_model(self):
        """An empty model resolves to the MAIN model's name, which the provider
        rejects — so a config that lost the line has to be repaired, not
        reported as somebody's choice and skipped."""
        # Written into the scratch .env rather than inherited, so the branch is
        # exercised on every machine instead of on whichever developer happens
        # to export the key in their shell.
        self.run_script()
        self.use_api_key_brain()
        self.write_env({"OPENAI_API_KEY": "sk-scratch-not-a-real-key"})
        self.run_script()
        cfg = self.cfg()
        self.assertEqual(cfg["auxiliary"]["vision"]["provider"], "openai")
        del cfg["auxiliary"]["vision"]["model"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertTrue(self.cfg()["auxiliary"]["vision"].get("model"),
                        "the model line was not repaired")
        # And Moe's own value is never reported back as the user's choice.
        self.assertNotIn("auxiliary.vision.provider = 'openai' — left alone", out)

    def test_the_auxiliary_text_lanes_need_a_key_they_can_reach(self):
        """No usable DEEPSEEK_API_KEY, no lanes — and it says why.

        The lanes exist because Hermes's auto chain reached nothing here:
        `claude-code-cli` cannot serve step 1, and OpenRouter and Nous are not
        configured on this machine. Writing a provider Moe cannot reach would
        only move the failure from configure time into the middle of a turn,
        which is `vision_key_present`'s lesson one lane over."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        aux = self.cfg().get("auxiliary") or {}
        self.assertNotIn("compression", aux)
        self.assertNotIn("session_search", aux)
        self.assertIn("auxiliary text lanes stay on `auto`", out)

    def test_a_placeholder_deepseek_key_does_not_enable_the_text_lanes(self):
        """The name being present is not the same as a key.

        Exactly the mistake `vision_key_present` documents having made once
        already, on this machine, where OPENAI_API_KEY is the literal string
        `not-a-real-key-proxy-ignores-it`. A lane configured on a placeholder
        is worse than no lane: the failure moves from a line a person can read
        to the middle of a turn, where they cannot."""
        self.run_script()   # the scratch .env does not exist until it has run once
        self.write_env({"DEEPSEEK_API_KEY": "not-a-real-key-either"})
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        aux = self.cfg().get("auxiliary") or {}
        self.assertNotIn("compression", aux)
        self.assertIn("auxiliary text lanes stay on `auto`", out)

    def test_a_real_deepseek_key_configures_the_text_lanes_and_the_cost_guard(self):
        """Both lanes get a provider AND a model, and the paid lane is capped.

        The model line is not optional: an empty one resolves to the MAIN
        model's name — `sonnet` here — which DeepSeek rejects. And
        `auxiliary.free_only` is what stops Hermes's OpenRouter fallback
        running a paid SKU; the gateway log carried `PAID lane engaged …
        'google/gemini-3.6-flash' is not a :free SKU` eight times on
        2026-09-04 because this file wrote no `auxiliary:` section at all."""
        self.run_script()   # the scratch .env does not exist until it has run once
        self.write_env({"DEEPSEEK_API_KEY": "sk-scratch-not-a-real-deepseek-key"})
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        aux = self.cfg()["auxiliary"]
        self.assertIs(aux["free_only"], True)
        for task in ("compression", "session_search"):
            self.assertEqual(aux[task]["provider"], "deepseek")
            self.assertTrue(aux[task].get("model"),
                            "%s lost its model line; an empty one resolves to "
                            "the main model's name" % task)

    def test_the_text_lanes_keep_a_value_somebody_else_chose(self):
        """Somebody's provider is theirs. This file's standing contract is
        `set_if_absent`, and a lane the owner pointed elsewhere must be
        reported and kept rather than quietly overwritten on the next run."""
        self.run_script()   # the scratch .env does not exist until it has run once
        self.write_env({"DEEPSEEK_API_KEY": "sk-scratch-not-a-real-deepseek-key"})
        self.run_script()
        cfg = self.cfg()
        cfg["auxiliary"]["compression"]["provider"] = "openrouter"
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["auxiliary"]["compression"]["provider"], "openrouter")

    def test_vision_falls_back_to_deepseek_when_openai_is_a_placeholder(self):
        """OpenAI is the preferred vision lane; DeepSeek is what this Mac has.

        `deepseek-v4-flash-vision-exp` was measured serving on the live key
        rather than read off a docs page. It is EXPERIMENTAL, so the note has
        to say so — if DeepSeek retires the slug, vision must go back to OFF
        rather than start failing inside turns."""
        self.run_script()   # the scratch .env does not exist until it has run once
        self.use_api_key_brain()
        self.write_env({"OPENAI_API_KEY": "not-a-real-key-proxy-ignores-it",
                        "DEEPSEEK_API_KEY": "sk-scratch-not-a-real-deepseek-key"})
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        vision = self.cfg()["auxiliary"]["vision"]
        self.assertEqual(vision["provider"], "deepseek")
        self.assertIn("vision", vision["model"])
        self.assertIn("EXPERIMENTAL", out)

    def test_every_hermes_auxiliary_task_is_decided(self):
        """A task Hermes routes must be one we configured or one we excused.

        This exists because the first version of the fix set three lanes —
        compression, session_search, vision — and Hermes routes nine. The one
        that mattered most was missing: `title_generation` runs on essentially
        every conversation, so the chain kept walking into the two
        unconfigured providers and the log kept complaining. The fix looked
        applied and the symptom stayed, which is the worst way for a fix to be
        wrong.

        It reads the names out of the INSTALLED Hermes rather than a list
        copied into this file, so a task added upstream fails here instead of
        silently defaulting to a chain that reaches nothing on this machine.
        Same shape as the RLS roster test that named its tables exhaustively
        and caught `composio_projects` the day it appeared.

        Skips rather than fails when Hermes is not installed: this suite runs
        on machines that have no checkout, and a test that cannot see its
        subject must say so rather than pass."""
        agent_dir = os.path.join(os.path.expanduser("~"), ".hermes", "hermes-agent")
        if not os.path.isdir(agent_dir):
            self.skipTest("no hermes-agent checkout to read task names from")
        names = set()
        for root, _dirs, files in os.walk(agent_dir):
            if ".venv" in root or "/tests" in root or "/.git" in root:
                continue
            for fn in files:
                if not fn.endswith(".py"):
                    continue
                try:
                    with open(os.path.join(root, fn), encoding="utf-8") as fh:
                        text = fh.read()
                except OSError:
                    continue
                names.update(re.findall(r'task=["\']([a-z_]+)["\']', text))
        self.assertTrue(names, "read no auxiliary task names — the pattern has rotted")
        names.discard("task")   # `task=task`, a pass-through, not a name
        decided = aux_tasks_decided() | {"vision"}
        undecided = sorted(names - decided)
        self.assertEqual(undecided, [], "Hermes routes auxiliary tasks nothing has "
                         "decided about: %s. Add them to AUX_TEXT_TASKS, or to "
                         "AUX_TASKS_NOT_OURS with a reason." % undecided)


    def test_a_cli_subscription_brain_is_not_pinned_to_a_vision_provider(self):
        """A brain that is a CLI login serves its own vision.

        This file used to pin one unconditionally, and the owner found what
        that costs: DeepSeek's balance ran out, and because the lane was
        PINNED, every computer_use screenshot came back `402 Insufficient
        Balance`. Moe could not see the screen at all, and the error named a
        service the owner had never chosen.

        A pin answers "which lane". Writing one on the user's behalf turns a
        fallback chain into a single point of failure — so for a CLI
        subscription there is no pin, and Hermes reaches the CLI itself.
        """
        self.run_script()
        self.write_env({"OPENAI_API_KEY": "sk-" + "x" * 40,
                        "DEEPSEEK_API_KEY": "sk-" + "y" * 40})
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["model"]["provider"], "claude-code-cli",
                         "this test is only meaningful on a CLI brain")
        self.assertNotIn("vision", self.cfg().get("auxiliary", {}),
                         "a CLI-subscription brain must not be pinned to a "
                         "third-party vision provider")
        self.assertIn("subscription", out)

    def test_an_api_key_brain_that_sees_is_not_pinned_either(self):
        """Hermes's `auto` vision lane tries the main provider first, so a
        brain whose model reads images — OpenAI, Gemini, Anthropic, xAI,
        OpenRouter — needs no pin, and one written in front of it with a key
        that happens to be lying in .env is the second bill the CLI test
        above describes. DeepSeek is the exception (its chat model is
        text-only) and keeps the pin logic; and the "stays off" line, when it
        is said, names the brain that is there rather than blaming
        claude-code-cli."""
        self.run_script()
        # OpenAI brain, with a DeepSeek key lying around: not pinned to DeepSeek.
        self.use_api_key_brain("openai-api", "gpt-5.5")
        self.write_env({"OPENAI_API_KEY": "sk-" + "x" * 40,
                        "DEEPSEEK_API_KEY": "sk-" + "y" * 40})
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertNotIn("vision", self.cfg().get("auxiliary", {}), out)
        self.assertIn("vision runs on your openai-api brain", out)
        # Gemini brain, no other key at all: not "off", it sees on its own.
        self.use_api_key_brain("gemini", "gemini-3-pro")
        self.write_env({"OPENAI_API_KEY": "", "DEEPSEEK_API_KEY": "",
                        "GEMINI_API_KEY": "AI" + "z" * 37})
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertNotIn("vision", self.cfg().get("auxiliary", {}), out)
        self.assertNotIn("stays off", out)
        self.assertIn("vision runs on your gemini brain", out)
        # DeepSeek brain, no key it can use for vision: off, and honest about
        # which brain is there.
        self.use_api_key_brain()
        self.write_env({"GEMINI_API_KEY": "", "DEEPSEEK_API_KEY": ""})
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("vision_analyze stays off", out)
        self.assertIn("your deepseek brain", out)
        self.assertNotIn("claude-code-cli has no HTTP client", out)

    def test_a_vision_pin_the_owner_wrote_is_never_removed(self):
        """The new rule must not reach past Moe's own defaults."""
        self.run_script()
        cfg = self.cfg()
        cfg.setdefault("auxiliary", {})["vision"] = {
            "provider": "openai", "model": "gpt-4o"}
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["auxiliary"]["vision"]["provider"], "openai")

    def test_a_placeholder_key_does_not_enable_vision(self):
        """A key's NAME being present is not the same as a key.

        ~/.hermes/.env on the machine this was found on held
        OPENAI_API_KEY=not-a-real-key-proxy-ignores-it — a placeholder that
        says so in words. A non-empty test accepted it and wrote
        auxiliary.vision, which moved vision_analyze from ABSENT to
        PRESENT-AND-ALWAYS-401. A tool that cannot work is worse than a tool
        that is not offered: the failure moves from configure time, where a
        person can read it, into the middle of a turn, where they cannot."""
        self.run_script()
        self.use_api_key_brain()
        self.write_env({"OPENAI_API_KEY": "not-a-real-key-proxy-ignores-it",
                        "DEEPSEEK_API_KEY": ""})
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertNotIn("vision", self.cfg().get("auxiliary", {}))
        self.assertIn("vision_analyze stays off", out)
        # A real-shaped key does enable it.
        self.write_env({"OPENAI_API_KEY": "sk-" + "x" * 40})
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["auxiliary"]["vision"]["provider"], "openai")

    def test_gate_boundary_does_not_call_a_missing_gate_protected(self):
        """The status loop skipped paths it could not stat, so a home with no
        gate at all reported "root-owned end to end" — a security line that
        says "safe" loudest when there is nothing there."""
        self.run_script()
        code, out = self.run_script("--check")
        self.assertIn("send gate:", out)
        # This scratch home has no ~/.moe/tools/confirm.sh installed — the
        # payload copied in is the plugin and job trees, not the gate itself.
        line = [l for l in out.splitlines() if l.startswith("send gate:")][0]
        self.assertNotIn("root-owned end to end", line)
        self.assertIn("missing", line)

    def test_show_reports_a_model_written_to_the_alias(self):
        """--show feeds Moe's Brain pane. A config holding only the alias must
        not report an empty model to it."""
        self.run_script()
        cfg = self.cfg()
        cfg["model"] = {"provider": "claude-code-cli", "model": "sonnet"}
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_brain("--show")
        self.assertEqual(code, 0, out)
        shown = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(shown["model"], "sonnet")

    def test_old_config_backups_are_pruned(self):
        """One backup is written per run that changes anything, and nothing
        ever removed them — 27 had accumulated on the development machine, 15
        of them in a single day."""
        self.run_script()
        for stamp in range(20):
            name = "%s.202601%02d-000000.bak" % (os.path.basename(self.cfg_path), stamp + 1)
            with open(os.path.join(self.hermes_home, name), "w") as f:
                f.write("old\n")
        # Force a real write so the prune runs.
        cfg = self.cfg()
        cfg["agent"]["max_turns"] = 123
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        # Not the default model (`sonnet` since 2026-09-15), or nothing changes.
        self.run_script("--model", "opus")
        left = sorted(n for n in os.listdir(self.hermes_home)
                      if n.startswith(os.path.basename(self.cfg_path) + ".")
                      and n.endswith(".bak"))
        self.assertLessEqual(len(left), plugin_keep(), left)
        # The newest survive: lexical order on the timestamp is chronological.
        self.assertIn("config.yaml.20260120-000000.bak", left)
        self.assertNotIn("config.yaml.20260101-000000.bak", left)

    # -- brain settings (--set-*, --show) -----------------------------------

    def run_brain(self, *extra, secret=None):
        """--set-* with the secret on stdin, the way Moe's Brain pane calls it."""
        env = dict(os.environ)
        env.update({"MOE_SECURITY_BIN": self.stub, "FAKE_OAUTH": "1", "HOME": self.tmp})
        env.pop("HERMES_HOME", None)
        p = subprocess.run(
            [sys.executable, SCRIPT, "--hermes-home", self.hermes_home,
             "--moe-home", self.moe_home] + list(extra),
            input=secret, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            universal_newlines=True, env=env)
        return p.returncode, p.stdout

    def test_set_model_only_touches_model(self):
        self.run_script()
        before = self.cfg()
        # Not the default (`sonnet` since 2026-09-15): setting the model a
        # fresh install already has writes nothing, so there is no backup.
        code, out = self.run_brain("--set-model", "opus")
        self.assertEqual(code, 0, out)
        after = self.cfg()
        # The two keys --set-model is about. NOT an exact-dict comparison:
        # `model` legitimately carries other keys the provider defaults own
        # (`context_length`, since 1792b81), and a test that pins the whole
        # dict fails the next time one is added while saying nothing about
        # what it is named for.
        self.assertEqual(after["model"]["provider"], "claude-code-cli")
        self.assertEqual(after["model"]["default"], "opus")
        # And this is the actual subject: nothing outside `model` moved, and
        # inside it only `default` did.
        before["model"]["default"] = "opus"
        self.assertEqual(after, before)
        self.assertIn("brain: claude-code-cli / opus", out)
        # A backup of the previous file is kept.
        self.assertTrue(any(n.startswith("config.yaml.") and n.endswith(".bak")
                            for n in os.listdir(self.hermes_home)))

    def test_set_provider_and_key_from_stdin(self):
        self.run_script()
        code, out = self.run_brain("--set-provider", "anthropic", "--set-model", "claude-sonnet-4-6",
                                   "--set-key", "ANTHROPIC_API_KEY", secret="sk-ant-TESTKEY-123\n")
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        self.assertEqual(cfg["model"]["provider"], "anthropic")
        self.assertEqual(cfg["model"]["default"], "claude-sonnet-4-6")
        env = self.env_values()
        self.assertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-TESTKEY-123")
        self.assertEqual(self.mode(self.env_path), 0o600)
        # The API_SERVER_KEY and everything else in .env survive.
        self.assertEqual(env["API_SERVER_KEY"], cfg["platforms"]["api_server"]["key"])
        self.assertEqual(env["TELEGRAM_BOT_TOKEN"], "123:FAKE-TOKEN")
        self.assertNotIn("TESTKEY", out)
        # --show reports presence, never the value.
        code, out = self.run_brain("--show")
        self.assertEqual(code, 0, out)
        shown = json.loads(out.strip().splitlines()[-1])
        self.assertEqual((shown["provider"], shown["model"]), ("anthropic", "claude-sonnet-4-6"))
        self.assertTrue(shown["keys"]["ANTHROPIC_API_KEY"])
        self.assertFalse(shown["keys"]["OPENAI_API_KEY"])
        self.assertTrue(shown["claude_signed_in"])
        self.assertFalse(shown["codex_signed_in"])
        self.assertNotIn("TESTKEY", out)
        # A later full re-run keeps the chosen provider instead of resetting it.
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["model"]["provider"], "anthropic")
        self.assertNotIn("setup-token", out.split("Notes")[0])

    def _jobs(self):
        with open(os.path.join(self.hermes_home, "cron", "jobs.json"), encoding="utf-8") as f:
            data = json.load(f)
        raw = data.get("jobs", data) if isinstance(data, dict) else data
        return {j["name"]: j for j in (raw if isinstance(raw, list) else raw.values())}

    def test_scheduled_work_never_asks_an_api_brain_for_haiku(self):
        """Audited 2026-09-11: `cron.model: haiku` was written for every
        provider, and only ChatGPT had been special-cased. Anthropic,
        OpenRouter, OpenAI, DeepSeek and a custom endpoint know no model
        called `haiku`, so every one of Moe's jobs failed on every tick.
        Since 2026-09-15 (DEFAULTS row 43) each provider gets its OWN
        cheapest model from model-tiers.json instead of the conversation's."""
        self.run_script()
        self.assertEqual(self.cfg()["cron"]["model"], "haiku")         # the CLI's cheapest
        code, out = self.run_brain("--set-provider", "anthropic", "--set-model", "claude-sonnet-4-6",
                                   "--set-key", "ANTHROPIC_API_KEY", secret="sk-ant-TESTKEY-123\n")
        self.assertEqual(code, 0, out)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        self.assertEqual(cfg["cron"]["model"], "claude-haiku-4-5-20251001")  # never `haiku`
        # And Hermes's own background calls (a watch's triage, a title) with it,
        # unless the DeepSeek lane already serves them (apply_background_aux_tier).
        monitor = (cfg.get("auxiliary") or {}).get("monitor") or {}
        self.assertIn((monitor.get("provider"), monitor.get("model")),
                      [("anthropic", "claude-haiku-4-5-20251001"),
                       (configure.AUX_PROVIDER, configure.AUX_MODEL)], monitor)
        self.assertTrue(monitor, "the watch triage was left on the conversation's model")
        for name, job in self._jobs().items():
            self.assertEqual((job.get("provider"), job.get("model")),
                             ("anthropic", "claude-haiku-4-5-20251001"), name)
        # A cron model the person set themselves is theirs, and is the pin.
        cfg["cron"] = {"model": "claude-sonnet-4-6"}
        with open(self.cfg_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["cron"]["model"], "claude-sonnet-4-6")
        self.assertEqual(self._jobs()["moe-proactive"]["model"], "claude-sonnet-4-6")
        # Back on the CLI, haiku is right again and is restored.
        code, out = self.run_brain("--set-provider", "claude-code-cli", "--set-model", "opus")
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        cfg.get("cron", {}).pop("model", None)
        with open(self.cfg_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(cfg, f)
        self.run_script()
        self.assertEqual(self.cfg()["cron"]["model"], "haiku")
        self.assertEqual(self._jobs()["moe-proactive"]["model"], "haiku")

    def test_cron_model_for_every_kind_of_brain(self):
        mod = _load_script()
        def cfg(provider, default="m", cron=None):
            c = {"model": {"provider": provider, "default": default}}
            if cron is not None:
                c["cron"] = {"model": cron}
            return c
        # Every provider with a table entry gets its own cheap name — never
        # another provider's (haiku on Codex is a hard 400, met 2026-09-09).
        cheap = {"claude-code-cli": "haiku", "openai-codex": "gpt-5.4-mini",
                 "anthropic": "claude-haiku-4-5-20251001", "openai-api": "gpt-5.4-nano",
                 "openrouter": "deepseek/deepseek-v4-flash",
                 "gemini": "gemini-3.1-flash-lite-preview", "deepseek": "deepseek-v4-flash",
                 "xai": "grok-4.20-0309-non-reasoning"}
        for provider, model in cheap.items():
            self.assertEqual(mod.cron_model_for(cfg(provider)), model, provider)
            # Moe's own earlier value, or another provider's entry, follows the brain.
            self.assertEqual(mod.cron_model_for(cfg(provider, cron="haiku")), model, provider)
            self.assertEqual(mod.cron_model_for(cfg(provider, cron="gpt-5.4-nano")), model, provider)
            self.assertEqual(mod.cron_model_for(cfg(provider, cron="their-own")), "their-own", provider)
        # No list to choose from: the conversation's model.
        for provider in ("custom", mod.MOE_CUSTOM, "lmstudio"):
            self.assertEqual(mod.cron_model_for(cfg(provider)), "m", provider)
            self.assertEqual(mod.cron_model_for(cfg(provider, cron="haiku")), "m", provider)
            self.assertEqual(mod.cron_model_for(cfg(provider, cron="their-own")), "their-own", provider)

    def test_the_tier_table_is_the_one_the_app_reads(self):
        """model-tiers.json is read from beside the script, and it is not empty.
        An unreadable table silently puts every job back on the conversation's
        model, which is the cost this exists to cut."""
        mod = _load_script()
        self.assertTrue(os.path.isfile(mod.MODEL_TIERS_FILE), mod.MODEL_TIERS_FILE)
        self.assertEqual(mod.cheapest_model_for("claude-code-cli"), "haiku")
        self.assertIsNone(mod.cheapest_model_for("custom"))

    def test_apply_cron_model_follows_the_brain_and_keeps_a_choice(self):
        mod = _load_script()
        def run(provider, cron=None):
            c = {"model": {"provider": provider, "default": "m"}}
            if cron is not None:
                c["cron"] = {"model": cron}
            mod.apply_cron_model(c, mod.Report())
            return c.get("cron", {}).get("model")
        self.assertEqual(run("claude-code-cli"), "haiku")
        self.assertEqual(run("openai-codex", cron="haiku"), "gpt-5.4-mini")
        self.assertEqual(run("openai-api", cron="their-own"), "their-own")
        self.assertIsNone(run("custom", cron="haiku"))
        self.assertIsNone(run("custom"))

    def test_background_review_follows_the_conversations_model(self):
        """2026-09-15 routed the review to the provider's cheapest model (7% of
        the plan); 2026-09-20 reversed it after the memory deep dive: the
        cheap reviewer said facts instead of saving them and mis-attributed a
        designed persona to the person. Hermes's own default — the review runs
        on the conversation's model — is provider-agnostic by construction, so
        Moe writes nothing here and removes what it wrote before."""
        mod = _load_script()
        def run(provider, review=None):
            c = {"model": {"provider": provider, "default": "m"}}
            if review is not None:
                c["auxiliary"] = {"background_review": dict(review)}
            mod.apply_background_review_model(c, mod.Report())
            return c.get("auxiliary", {}).get("background_review")
        # A fresh config gets nothing of Moe's, whatever the brain.
        for provider in ("claude-code-cli", "openai-codex", "anthropic", "gemini", "custom"):
            self.assertIsNone(run(provider), provider)
        # What 2026-09-15 wrote is taken out, on every brain, and other keys stay.
        self.assertEqual(run("anthropic", {"provider": "anthropic", "model": "claude-haiku-4-5-20251001",
                                           "max_input_tokens": 1000}), {"max_input_tokens": 1000})
        self.assertIsNone(run("claude-code-cli", {"provider": "claude-code-cli", "model": "haiku"}))
        self.assertIsNone(run("gemini", {"provider": "gemini", "model": "gemini-3.1-flash-lite-preview"}))
        self.assertIsNone(run("openai-codex", {"provider": "deepseek", "model": "deepseek-v4-flash"}))
        # The person's own choice is kept, whichever brain they are on.
        mine = {"provider": "openrouter", "model": "anthropic/claude-opus-4.5"}
        self.assertEqual(run("claude-code-cli", mine), mine)
        self.assertEqual(run("custom", {"provider": "claude-code-cli", "model": "haiku",
                                        "enabled": True}), {"enabled": True})

    def test_set_key_rejects_argv_style_and_unknown_names(self):
        self.run_script()
        code, out = self.run_brain("--set-key", "SOME_OTHER_KEY", secret="x\n")
        self.assertEqual(code, 1, out)
        code, out = self.run_brain("--set-key", "OPENAI_API_KEY", secret="")
        self.assertEqual(code, 1, out)
        code, out = self.run_brain("--set-provider", "not-a-provider")
        self.assertEqual(code, 1, out)
        code, out = self.run_brain("--set-reasoning", "extreme")
        self.assertEqual(code, 1, out)
        self.assertNotIn("OPENAI_API_KEY", self.env_values())

    def test_local_server_base_url_and_reasoning(self):
        self.run_script()
        code, out = self.run_brain("--set-provider", "custom", "--set-model", "llama3.1",
                                   "--set-base-url", "http://127.0.0.1:11434/v1",
                                   "--set-reasoning", "low")
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        self.assertEqual(cfg["model"]["base_url"], "http://127.0.0.1:11434/v1")
        self.assertEqual(cfg["agent"]["reasoning_effort"], "low")
        code, out = self.run_brain("--set-base-url", "ftp://nope")
        self.assertEqual(code, 1, out)
        # Switching to an API provider drops the localhost base_url and clears reasoning on request.
        code, out = self.run_brain("--set-provider", "openai-api", "--set-model", "gpt-5.5",
                                   "--set-reasoning", "")
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        self.assertNotIn("base_url", cfg["model"])
        # Clearing reasoning removes the KEY, not the section: `agent` also
        # carries the run bounds apply_runtime_limits sets, and emptying it
        # would take max_turns and run_budget_seconds with it.
        self.assertNotIn("reasoning_effort", cfg.get("agent", {}))
        code, out = self.run_brain("--show")
        shown = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(shown["base_url"], "")
        self.assertEqual(shown["reasoning_effort"], "")

    def test_codex_sign_in_seen_in_show(self):
        self.run_script()
        with open(os.path.join(self.hermes_home, "auth.json"), "w") as f:
            json.dump({"version": 1, "providers": {"openai-codex": {"tokens": {"access_token": "t"}}}}, f)
        code, out = self.run_brain("--show")
        self.assertEqual(code, 0, out)
        self.assertTrue(json.loads(out.strip().splitlines()[-1])["codex_signed_in"])
        self.assertNotIn("access_token", out)

    def test_codex_pool_entry_seen_in_show(self):
        """The fork's `hermes auth add openai-codex` writes a credential_pool
        entry and no providers block; a dead entry is not a sign-in."""
        self.run_script()
        auth = os.path.join(self.hermes_home, "auth.json")
        with open(auth, "w") as f:
            json.dump({"version": 1, "providers": {}, "credential_pool": {"openai-codex": [
                {"id": "a1", "source": "manual:device_code", "auth_type": "oauth",
                 "access_token": "t", "refresh_token": "r", "last_status": None}]}}, f)
        code, out = self.run_brain("--show")
        self.assertEqual(code, 0, out)
        self.assertTrue(json.loads(out.strip().splitlines()[-1])["codex_signed_in"])
        self.assertNotIn("access_token", out)
        with open(auth, "w") as f:
            json.dump({"version": 1, "providers": {}, "credential_pool": {"openai-codex": [
                {"id": "a1", "source": "manual:device_code", "auth_type": "oauth",
                 "access_token": "t", "last_status": "dead"}]}}, f)
        code, out = self.run_brain("--show")
        self.assertEqual(code, 0, out)
        self.assertFalse(json.loads(out.strip().splitlines()[-1])["codex_signed_in"])

    # -- setup-token ---------------------------------------------------------

    def test_missing_setup_token_exits_2_after_writing(self):
        code, out = self.run_script(oauth=False)
        self.assertEqual(code, 2, out)
        self.assertTrue(os.path.exists(self.cfg_path))
        self.assertTrue(os.path.exists(self.env_path))
        self.assertTrue(os.path.isdir(os.path.join(self.hermes_home, "claude-code")))
        self.assertIn("scripts/hermes-signin.sh", out)
        # And the re-run after signing in completes.
        code, out = self.run_script(oauth=True)
        self.assertEqual(code, 0, out)

    def test_no_telegram_token_leaves_telegram_off(self):
        code, out = self.run_script(tg="")
        self.assertEqual(code, 0, out)
        self.assertNotIn("telegram", self.cfg()["platforms"])
        self.assertNotIn("TELEGRAM_BOT_TOKEN", self.env_values())
        self.assertIn("TELEGRAM_BOT_TOKEN in ~/.hermes/.env", out)

    # -- dry run -------------------------------------------------------------

    def test_dry_run_writes_nothing(self):
        code, out = self.run_script("--dry-run")
        self.assertEqual(code, 0, out)
        self.assertFalse(os.path.exists(self.hermes_home))
        self.assertIn("+  provider: claude-code-cli", out)
        self.assertIn("API_SERVER_KEY", out)
        self.assertNotIn("FAKE-TOKEN", out)
        # The generated key must not leak through the diff either.
        self.assertIn("key: <redacted>", out)

    # -- check ---------------------------------------------------------------

    def test_check_passes_after_install_and_fails_on_broken_file(self):
        self.run_script()
        code, out = self.run_script("--check")
        self.assertEqual(code, 0, out)
        self.assertIn("present in Keychain (Moe injects it at launch)", out)
        self.assertIn("manual-launch ready: no", out)
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "x"
        try:
            code, out = self.run_script("--check")
        finally:
            del os.environ["CLAUDE_CODE_OAUTH_TOKEN"]
        self.assertIn("manual-launch ready: yes", out)

        cfg = self.cfg()
        cfg["model"]["provider"] = "auto"
        cfg["platforms"]["api_server"]["enabled"] = False
        del cfg["hooks_auto_accept"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        os.chmod(self.env_path, 0o644)
        code, out = self.run_script("--check")
        self.assertEqual(code, 1, out)
        for needle in ("model.provider", "api_server.enabled", "hooks_auto_accept", ".env is mode 644"):
            self.assertIn(needle, out)

    def test_computer_use_on_by_default_and_off_by_flag(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cu = self.cfg().get("computer_use") or {}
        self.assertEqual(cu.get("enabled"), True)
        self.assertEqual(cu.get("backend"), "auto")
        # A user's own backend choice survives a re-run.
        text = self.read(self.cfg_path).replace("backend: auto", "backend: cua")
        with open(self.cfg_path, "w") as f:
            f.write(text)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["computer_use"]["backend"], "cua")
        code, out = self.run_script("--no-computer-use")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["computer_use"]["enabled"], False)
        self.assertIn("computer_use.enabled", out)

    def test_driver_install_is_skipped_when_computer_use_is_off(self):
        """--no-computer-use returns before the probe, so the driver step is
        safe to reach with the test guard off: nothing is downloaded."""
        code, out = self.run_script("--no-computer-use", driver_env="")
        self.assertEqual(code, 0, out)
        self.assertIn("cua-driver (computer_use backend)", out)
        self.assertIn("--no-computer-use", out)

    def test_driver_install_honours_the_test_guard(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("MOE_SKIP_DRIVER_INSTALL", out)

    def test_driver_install_is_detached_when_moe_is_the_caller(self):
        """Moe gives this script 60s and then SIGKILLs it, which is less than a
        driver download needs. Run without a tty, the install must be handed off
        rather than waited on — and it must really be handed off, not skipped.

        MOE_HERMES_BIN stands in for the `hermes` CLI so nothing is downloaded;
        it also answers the readiness probe, so the step sees "no driver yet".
        """
        marker = os.path.join(self.tmp, "hermes-calls")
        stub = os.path.join(self.tmp, "hermes-stub")
        with open(stub, "w") as f:
            f.write('#!/bin/bash\nprintf "%s\\n" "$*" >> "%s"\n' % ("$*", marker))
        os.chmod(stub, 0o755)
        code, out = self.run_script(driver_env="", hermes_bin=stub, no_driver=True)
        self.assertEqual(code, 0, out)
        self.assertIn("installing in the background", out)
        for _ in range(50):
            if os.path.exists(marker):
                break
            time.sleep(0.1)
        self.assertTrue(os.path.exists(marker), "the stub hermes was never invoked\n" + out)
        self.assertIn("computer-use install", self.read(marker))

    def test_dry_run_says_what_it_would_do_about_the_driver(self):
        code, out = self.run_script("--dry-run", "--no-computer-use", driver_env="")
        self.assertEqual(code, 0, out)
        self.assertIn("cua-driver: computer_use is off", out)

    def test_explicit_api_server_toolsets_without_computer_use_is_flagged(self):
        """A hand-edited (or `hermes tools`-saved) list that omits computer_use.

        Moe's own list always has it, so this can only be reached with
        --keep-toolsets — which is exactly the flag that promises not to
        overwrite the user's list, and therefore the one that owes them the
        warning that their list is hiding the tool computer_use.enabled just
        turned on. Without the flag the same list is simply replaced."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        cfg["platform_toolsets"]["api_server"] = ["web", "file"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f, sort_keys=False)
        code, out = self.run_script("--keep-toolsets")
        self.assertEqual(code, 0, out)
        self.assertIn("omits computer_use", out)
        self.assertEqual(self.cfg()["platform_toolsets"]["api_server"], ["web", "file"])
        # …and without the flag Moe's list wins, which is the whole point of
        # forcing the key: `hermes tools` writes the same one.
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("clarify", self.cfg()["platform_toolsets"]["api_server"])

    def test_session_search_is_offered_not_deferred(self):
        """"Search my past conversations" needs session_search in front of
        the model. Deferred (Hermes's default), the claude-code runtime could
        only reach it through tool_search → tool_call, outside the agent loop,
        where it refuses: 0 calls in 443 transcripts on the owner's Mac,
        2026-09-25."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        defer = self.cfg()["tools"]["tool_search"]["defer"]
        self.assertNotIn("session_search", defer)
        self.assertNotIn("todo_list", defer)
        # The rest of Hermes's list is kept: the key replaces it wholesale,
        # and dropping it would put ~16 GUI tools back in every prompt.
        self.assertIn("computer_use", defer)

    @staticmethod
    def hermes_default_defer(agent):
        """Hermes's default deferral list, read off a hermes-agent checkout.

        It has lived in two places. Up to pin ce81ae8305 it was a literal in
        tools/tool_search.py; at eb8e427cd1 it is
        DEFAULT_CONFIG["tools"]["tool_search"]["defer"] in
        hermes_cli/config_defaults.py, and tool_search.py reads that
        (`_DEFAULT_DEFERRED_TOOLS = frozenset(DEFAULT_CONFIG[...])`). This
        test knew only the first, so when the list moved it failed on "no
        longer declares" and stopped comparing anything — while the list
        itself had changed underneath (2026-11-12). None when neither shape
        is there: a third move must fail, not skip."""
        def read(*parts):
            path = os.path.join(agent, *parts)
            if not os.path.isfile(path):
                return ""
            with open(path, encoding="utf-8") as f:
                return f.read()
        m = re.search(r"_DEFAULT_DEFERRED_TOOLS\s*=\s*frozenset\(\{(.*?)\}\)",
                      read("tools", "tool_search.py"), re.S)
        if m is None:
            defaults = read("hermes_cli", "config_defaults.py")
            block = defaults.find('"tool_search": {')
            if block >= 0:
                m = re.search(r'"defer":\s*\[(.*?)\]', defaults[block:], re.S)
        if m is None:
            return None
        # Comments inside the list are not names.
        code = "\n".join(line.split("#", 1)[0] for line in m.group(1).splitlines())
        return set(re.findall(r'"([a-z_]+)"', code))

    def test_tool_search_defer_tracks_installed_hermes(self):
        """TOOL_SEARCH_DEFER is Hermes's default minus the two bridged tools.
        Read off a Hermes checkout AT THE PIN (MOE_TEST_HERMES_AGENT, else the
        installed one), so an upstream change to its list fails here instead
        of silently drifting. A checkout at another commit is not evidence
        about the pin, in either direction: the test skips and says which
        commit it found, rather than failing on a stale install or passing
        on one the pin has moved past."""
        agent = os.environ.get("MOE_TEST_HERMES_AGENT") or os.path.join(
            os.path.expanduser("~"), ".hermes", "hermes-agent")
        if not os.path.isfile(os.path.join(agent, "tools", "tool_search.py")):
            self.skipTest("no hermes-agent checkout to read the default list from")
        installer = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(SCRIPT)),
                                                  "..", "..", "scripts", "install-hermes.sh"))
        pm = re.search(r'^HERMES_COMMIT="\$\{HERMES_COMMIT-([0-9a-f]{40})\}"',
                       open(installer, encoding="utf-8").read(), re.M)
        self.assertIsNotNone(pm, "the pin line in install-hermes.sh changed shape")
        pin = pm.group(1)
        if os.path.exists(os.path.join(agent, ".git")):  # a worktree's .git is a file
            head = subprocess.run(["git", "-C", agent, "rev-parse", "HEAD"],
                                  capture_output=True, text=True).stdout.strip()
        else:
            try:
                head = open(os.path.join(agent, ".moe-seed-commit")).read().strip()
            except OSError:
                head = ""
        if head != pin:
            self.skipTest("%s is at %s, not the pin %s — point MOE_TEST_HERMES_AGENT "
                          "at a checkout of the pin" % (agent, head[:10] or "unknown", pin[:10]))
        upstream = self.hermes_default_defer(agent)
        self.assertIsNotNone(
            upstream, "Hermes's default deferral list is in neither tools/tool_search.py "
                      "nor hermes_cli/config_defaults.py — find where it moved")
        # An empty read is a parser that found the place and none of the names.
        self.assertIn("computer_use", upstream)
        self.assertIn("session_search", upstream)
        ours_src = open(SCRIPT, encoding="utf-8").read()
        mo = re.search(r"^TOOL_SEARCH_DEFER\s*=\s*\((.*?)\)", ours_src, re.S | re.M)
        ours = set(re.findall(r'"([a-z_]+)"', mo.group(1)))
        self.assertEqual(ours, upstream - {"session_search", "todo_list"})

    def test_the_defer_list_moe_wrote_for_the_last_pin_is_moved(self):
        """`tools.tool_search.defer` replaces Hermes's list wholesale, and an
        install keeps whatever this script wrote first. So when the list
        tracks a new pin, an install carrying exactly the old one is carrying
        Moe's earlier default and is moved; a list the person edited is kept."""
        self.run_script()
        cfg = self.cfg()
        self.assertIn("manage_catalog", cfg["tools"]["tool_search"]["defer"])
        self.assertNotIn("setup_mcp", cfg["tools"]["tool_search"]["defer"])
        prior = ["computer_use", "image_generate", "process_manage", "cronjob_manage",
                 "drive_preview", "gui_tour", "desktop_preview", "annotate_preview",
                 "show_tip", "setup_mcp", "desktop_project", "close_terminal",
                 "apply_layout", "read_terminal", "read_window_below", "focus_pane"]
        cfg["tools"]["tool_search"]["defer"] = list(prior)
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        moved = self.cfg()["tools"]["tool_search"]["defer"]
        self.assertIn("manage_catalog", moved)
        self.assertNotIn("setup_mcp", moved)
        self.assertNotIn("session_search", moved)
        # The list written for pins up to 0.3.25 moves too (v0.23.1 swapped
        # apply_layout for set_theme), not only the oldest one.
        cfg["tools"]["tool_search"]["defer"] = [
            "computer_use", "image_generate", "process_manage", "cronjob_manage",
            "drive_preview", "gui_tour", "desktop_preview", "annotate_preview",
            "manage_catalog", "show_tip", "desktop_project", "close_terminal",
            "apply_layout", "read_terminal", "read_window_below", "focus_pane"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        moved = self.cfg()["tools"]["tool_search"]["defer"]
        self.assertIn("set_theme", moved)
        self.assertNotIn("apply_layout", moved)
        cfg["tools"]["tool_search"]["defer"] = ["computer_use"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f)
        self.run_script()
        self.assertEqual(self.cfg()["tools"]["tool_search"]["defer"], ["computer_use"])

    def test_toolsets_plugin_and_cron_job(self):
        """The keys and payloads the learn-me pipeline needs to be alive."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        api = cfg["platform_toolsets"]["api_server"]
        for name in ("clarify", "computer_use", "kanban", "video", "x_search"):
            self.assertIn(name, api)
        # Left Hermes core for catalog plugins; listed only while the plugin
        # is installed, or Hermes tries to fetch it at every start.
        for name in ("spotify", "homeassistant"):
            for platform, row in cfg["platform_toolsets"].items():
                self.assertNotIn(name, row, platform)
        self.assertEqual(cfg["platform_toolsets"]["telegram"][0], "hermes-telegram")
        self.assertIs(cfg["tools"]["tool_search"]["enabled"], True)
        self.assertIn("moe-profile", cfg["plugins"]["enabled"])
        # Neither of the keys the docs call dead, and no disabled_toolsets —
        # the last of those is about what Moe WRITES, not about what it
        # strips: Moe must never author a key that can cancel the lists above,
        # even though it now leaves a user's own value alone
        # (test_disabled_toolsets_is_never_stripped).
        #
        # All three run on a config that never had the keys, so they can only
        # catch Moe writing one — they say nothing about a key that arrives
        # from a Hermes upgrade or a `hermes tools` run, which is the way it
        # actually happens. That is
        # test_refused_keys_are_removed_from_a_config_that_has_them, and these
        # are not a substitute for it.
        self.assertNotIn("toolsets", cfg)
        self.assertNotIn("custom_toolsets", cfg)
        self.assertNotIn("disabled_toolsets", cfg.get("agent") or {})
        self.assertTrue(os.path.exists(
            os.path.join(self.hermes_home, "plugins", "moe-profile", "__init__.py")))
        script = os.path.join(self.hermes_home, "scripts", "moe-learn-deep.sh")
        self.assertTrue(os.access(script, os.X_OK))
        self.assertEqual(self.mode(script), 0o755)

    def test_the_followups_toolset_reaches_the_mac_and_the_phone(self):
        """"Stop reminding me about that" is usually typed on a phone.

        The moe-screen plugin registers `moe_followups` under its own
        toolset, and a toolset absent from an explicit platform_toolsets
        list is dropped silently — so a tool that exists reaches nobody.
        Both lists, not one: the nudge is spoken on the Mac and read on the
        phone, and the answer comes back wherever the person is."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        self.assertIn("moe_followups", cfg["platform_toolsets"]["api_server"])
        self.assertIn("moe_followups", cfg["platform_toolsets"]["telegram"])
        self.assertIn("moe-screen", cfg["plugins"]["enabled"])
        # The tool has to be in the plugin that is INSTALLED, not only in
        # the checkout, and it has to be registered under the same name
        # this file writes into platform_toolsets — two files, one string,
        # and a mismatch is a toolset entry that resolves to nothing.
        plugin = os.path.join(self.hermes_home, "plugins", "moe-screen")
        self.assertTrue(os.path.exists(os.path.join(plugin, "followups.py")))
        with open(os.path.join(plugin, "adapter.py")) as f:
            adapter = f.read()
        with open(SCRIPT) as f:
            configure = f.read()
        spelling = 'FOLLOWUPS_TOOLSET = "moe_followups"'
        self.assertIn(spelling, adapter)
        self.assertIn(spelling, configure)
        self.assertIn("toolset=FOLLOWUPS_TOOLSET", adapter)
        self.assertIn("    FOLLOWUPS_TOOLSET,\n", configure)

    def test_the_settings_toolset_reaches_the_mac_and_never_a_phone(self):
        """`moe_open_settings` opens System Settings on this Mac
        (docs/FIXABLE-FAILURES.md slice 4). It is on the Mac's list, and on
        no chat platform's: a person on their phone is not at the Mac."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        self.assertIn("moe_settings", cfg["platform_toolsets"]["api_server"])
        for platform, sets in cfg["platform_toolsets"].items():
            if platform != "api_server":
                self.assertNotIn("moe_settings", sets, platform)
        plugin = os.path.join(self.hermes_home, "plugins", "moe-screen")
        with open(os.path.join(plugin, "open_settings.py")) as f:
            tool = f.read()
        with open(SCRIPT) as f:
            configure = f.read()
        self.assertIn('TOOLSET = "moe_settings"', tool)
        self.assertIn('SETTINGS_TOOLSET = "moe_settings"', configure)
        self.assertIn("    SETTINGS_TOOLSET,\n]", configure)

    def test_the_location_toolset_reaches_the_mac_and_never_a_phone(self):
        """`moe_location` reads where this Mac is. On the Mac's list, and on
        no chat platform's: a person on their phone is not where the Mac is."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        self.assertIn("moe_location", cfg["platform_toolsets"]["api_server"])
        for platform, sets in cfg["platform_toolsets"].items():
            if platform != "api_server":
                self.assertNotIn("moe_location", sets, platform)
        plugin = os.path.join(self.hermes_home, "plugins", "moe-screen")
        with open(os.path.join(plugin, "location.py")) as f:
            tool = f.read()
        with open(SCRIPT) as f:
            configure = f.read()
        self.assertIn('TOOLSET = "moe_location"', tool)
        self.assertIn('LOCATION_TOOLSET = "moe_location"', configure)

    def test_the_two_bundled_standalone_plugins_are_enabled(self):
        """security-guidance and disk-cleanup are the only two §4.6 items
        that `plugins.enabled` actually gates.

        Measured 2026-09-05 against the live install: of the six plugins the
        plan says to turn on, four are `kind: backend` and BUNDLED, which
        auto-load — naming those here would read like a change and do
        nothing, which is the silently-inert-key failure this repo keeps
        finding. What gates them is a credential, not a switch.
        """
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        enabled = self.cfg()["plugins"]["enabled"]
        self.assertIn("security-guidance", enabled)
        self.assertIn("disk-cleanup", enabled)

    def test_a_bundled_plugin_this_hermes_lacks_is_not_enabled(self):
        """A name Hermes cannot find warns on every gateway start, forever.

        The pin can be older than the plugin, so the enable is guarded on the
        directory existing. The guard needs this test specifically: written
        without passing --hermes-agent through, `hermes_agent_dir` falls back
        to the checkout owning the running interpreter's venv — the REAL
        install — so it consulted a tree the caller never named and passed no
        matter what. It enabled both against an empty checkout before this
        test existed.
        """
        # A REAL checkout with only plugins/ emptied: the script validates the
        # merged config by importing Hermes out of the directory it is given,
        # so a stub with a bare hermes_cli/ fails the run for an unrelated
        # reason and proves nothing about the guard.
        # The same last-resort candidate hermes_agent_dir uses: the checkout
        # that owns the running interpreter's venv.
        real = os.path.dirname(sys.prefix)
        if not os.path.isdir(os.path.join(real, "hermes_cli")):
            self.skipTest("no hermes-agent checkout to mirror")
        fake = os.path.join(self.tmp, "agent-without-plugins")
        os.makedirs(fake, exist_ok=True)
        for entry in os.listdir(real):
            if entry == "plugins":
                continue
            link = os.path.join(fake, entry)
            if not os.path.exists(link):
                os.symlink(os.path.join(real, entry), link)
        os.makedirs(os.path.join(fake, "plugins"), exist_ok=True)
        code, out = self.run_script("--hermes-agent", fake)
        self.assertEqual(code, 0, out)
        enabled = self.cfg()["plugins"]["enabled"]
        self.assertNotIn("security-guidance", enabled)
        self.assertNotIn("disk-cleanup", enabled)
        self.assertIn("bundled plugin security-guidance not found", out)

    def test_the_claim_store_plugin_installs_without_a_human_step(self):
        """Hermes's memory, pointed at Moe's ledger, by running the installer.

        Three things have to be true together or the plugin is inert: the
        files are in ~/.hermes/plugins/, the name is in plugins.enabled (user
        plugins are opt-in), and memory.provider names it (Hermes loads no
        memory backend from plugins/ otherwise). Two out of three is a
        silently ordinary Hermes.
        """
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        self.assertIn("claimstore", cfg["plugins"]["enabled"])
        self.assertEqual(cfg["memory"]["provider"], "claimstore")
        self.assertEqual(cfg["memory"]["claimstore"]["ledger_dir"],
                         os.path.join(self.moe_home, "ledger"))
        self.assertEqual(cfg["memory"]["claimstore"]["targets"], ["memory", "user"])
        for name in ("__init__.py", "store.py", "projection.py", "plugin.yaml"):
            self.assertTrue(os.path.exists(
                os.path.join(self.hermes_home, "plugins", "claimstore", name)), name)

    def test_the_claim_store_is_not_a_toolset(self):
        """It registers no tools, so its name must not join platform_toolsets.

        An unknown toolset name earns a warning from Hermes's config
        validation, and the built-in `memory` tool is deliberately still the
        only way the model writes memory.
        """
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertNotIn("claimstore", self.cfg()["platform_toolsets"]["api_server"])

    def test_a_rerun_changes_nothing_about_the_claim_store(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("~/.hermes/plugins/claimstore/", out)
        self.assertNotIn("(updated)", out)
        self.assertEqual(self.cfg()["memory"]["provider"], "claimstore")

    def test_a_relocated_ledger_is_kept(self):
        """set-if-absent: a person who moved their ledger made a choice."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        cfg["memory"]["claimstore"]["ledger_dir"] = "/somewhere/else/ledger"
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f, sort_keys=False)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["memory"]["claimstore"]["ledger_dir"],
                         "/somewhere/else/ledger")

    def test_a_memory_provider_somebody_else_configured_is_never_taken(self):
        """Seizing a memory store is a bigger act than rewriting a toolset list.

        This was a force_set, on the reasoning that memory.provider is the
        point of the exercise the way model.provider is. It is not the same
        act: a user already on honcho or mem0 would have lost their backend to
        a Moe upgrade — silently, on a run they started for some other reason,
        with install.sh passing no flag that could stop it. No flag is needed
        to keep it now; the checklist says what it costs instead.
        """
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        cfg["memory"]["provider"] = "someone-elses"
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f, sort_keys=False)

        code, out = self.run_script()          # no flag at all — what install.sh does
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["memory"]["provider"], "someone-elses")
        self.assertIn("left alone", out)
        self.assertIn("NOT backing it", " ".join(out.split()))

    def test_a_machine_with_no_memory_provider_gets_moes(self):
        """The fresh-install case the key exists for."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.cfg()["memory"]["provider"], "claimstore")

    def test_check_does_not_fail_a_machine_on_another_memory_provider(self):
        """Somebody chose it. Not a broken install — but not silent either."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        cfg["memory"]["provider"] = "someone-elses"
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f, sort_keys=False)
        code, out = self.run_script("--check")
        self.assertEqual(code, 0, out)
        self.assertIn("not on Moe's ledger", out)

    def test_dry_run_says_it_would_leave_another_provider_alone(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        cfg["memory"]["provider"] = "someone-elses"
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f, sort_keys=False)
        code, out = self.run_script("--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("LEAVE ALONE", out)

    def test_check_notices_a_memory_store_that_is_not_wired_up(self):
        """Half-installed is the failure worth catching: the files are there,
        the provider names them, and plugins.enabled does not — so Hermes
        loads nothing and everything looks fine."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        cfg["plugins"]["enabled"] = [p for p in cfg["plugins"]["enabled"] if p != "claimstore"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f, sort_keys=False)
        code, out = self.run_script("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("plugins.enabled does not list claimstore", out)

    def test_check_notices_no_memory_provider_at_all(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        del cfg["memory"]["provider"]
        with open(self.cfg_path, "w") as f:
            yaml.safe_dump(cfg, f, sort_keys=False)
        code, out = self.run_script("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("memory.provider is not set", out)

    def test_dry_run_says_what_it_would_do_about_memory(self):
        code, out = self.run_script("--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("claimstore plugin:", out)
        self.assertIn("memory store:", out)
        self.assertIn("adopted, not", out)
        self.assertFalse(os.path.exists(
            os.path.join(self.hermes_home, "plugins", "claimstore")))

    def test_check_reports_unparseable_yaml(self):
        os.makedirs(self.hermes_home)
        with open(self.cfg_path, "w") as f:
            f.write("model: [unclosed\n")
        code, out = self.run_script("--check")
        self.assertEqual(code, 1, out)
        self.assertIn("does not parse", out)



class EnvValueRule(unittest.TestCase):
    """**§18.30 B4.** `.env` has two writers — this file on the Mac and
    `moeledger.relayconfig` on both runtimes — and §18.30 S1 claimed
    `merge_env_keys` was "the one answer in this payload to what a `.env` line
    is". It was not: this file was still on `any(c in value for c in
    "\r\n\x00")`, three characters, while every reader splits with
    `str.splitlines()`, which splits on **ten**.

    Eight got through, and `render_env`'s own docstring says the LAST
    assignment wins — so `DEEPSEEK_API_KEY=sk-real<U+2028>API_SERVER_KEY=x`
    overrode the real `API_SERVER_KEY`, reachable from Moe's own Brain pane.

    The two are spelled separately (this file runs before the plugin is
    installed and must not depend on it) and pinned here by BEHAVIOUR over the
    same inputs, which is what this repository already does for the delivery
    strings it needs identical on two runtimes.
    """

    def rule(self):
        root = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))), "hermes-plugins", "moe-ledger")
        path = os.path.join(root, "moeledger", "relayconfig.py")
        spec = importlib.util.spec_from_file_location("relayrule_pin", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def cases(self):
        splitters = [chr(c) for c in list(range(0x20)) + [0x85, 0x2028, 0x2029]
                     if len(("a" + chr(c) + "b").splitlines()) > 1]
        bad = ["a" + c + "API_SERVER_KEY=attacker" for c in splitters]
        bad += ["a\x00b", "", "   ", "abc\n"]
        good = ["sk-fixture-not-a-real-key", "a b c", "x" * 400, "%s", "a=b"]
        return bad, good

    def test_both_writers_agree_about_every_separator(self):
        theirs = self.rule()
        bad, good = self.cases()
        self.assertGreaterEqual(len(bad), 14, "splitlines splits on fewer than expected")
        for value in bad:
            self.assertIsNotNone(configure.env_value_problem(value), repr(value))
            self.assertIsNotNone(theirs.env_value_problem(value), repr(value))
        for value in good:
            self.assertIsNone(configure.env_value_problem(value), repr(value))
            self.assertIsNone(theirs.env_value_problem(value), repr(value))

    def test_the_writer_refuses_rather_than_writing_two_lines(self):
        """The funnel, not only the front door — `render_env` is where every
        write on this side passes."""
        _, _ = self.cases()
        with self.assertRaises(ValueError):
            configure.render_env("", {"DEEPSEEK_API_KEY": "a\u2028API_SERVER_KEY=attacker"})
        # and the removal contract is untouched: an empty value still removes.
        text, changed = configure.render_env("FOO=1\n", {"FOO": ""})
        self.assertNotIn("FOO=1", text)


class OwnJobsAreUpkeepTest(unittest.TestCase):
    def test_every_job_moe_installs_is_listed_as_moes_own(self):
        """A job missing from reminders.UPKEEP shows in Settings › Reminders
        under Yours, with Pause and Delete — which happened twice
        (RemindersPane.swift's header). Held against JOB_SPECS itself."""
        import importlib.util
        path = os.path.join(os.path.dirname(SCRIPT), "reminders.py")
        spec = importlib.util.spec_from_file_location("moe_reminders_upkeep", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        missing = [name for _, _, name in configure.JOB_SPECS
                   if name not in mod.UPKEEP and not name.startswith(mod.UPKEEP_PREFIX)]
        self.assertEqual(missing, [])


class MemoryReviewIntervalTest(unittest.TestCase):
    """Through `apply_claim_store` itself, the way a run reaches it: a test of
    `set_if_absent` alone passed whatever apply_claim_store did (review
    2026-09-24 §13)."""

    def apply(self, cfg):
        args = types.SimpleNamespace(moe_home="/tmp/not-a-moe-home")
        configure.apply_claim_store(cfg, args, configure.Report())
        return cfg

    def test_the_review_runs_every_twenty_turns_unless_the_person_chose(self):
        self.assertEqual(self.apply({})["memory"]["nudge_interval"], 20)
        self.assertEqual(self.apply({"memory": {"nudge_interval": 5}})["memory"]["nudge_interval"], 5)

    def test_a_person_on_another_memory_provider_is_left_alone(self):
        cfg = self.apply({"memory": {"provider": "honcho"}})
        self.assertNotIn("nudge_interval", cfg["memory"])


class BackgroundAuxTierTest(unittest.TestCase):
    """Hermes's own background auxiliary calls (a watch job's triage, a
    conversation's title, ...) on the cheapest model the person's provider
    serves. Unpinned they run on the MAIN model on every non-Claude brain
    (auxiliary_client's auto chain, step 1: main provider + main model)."""

    def tiers(self):
        with open(configure.MODEL_TIERS_FILE, encoding="utf-8") as f:
            return json.load(f)["cheapest"]

    def run_on(self, cfg):
        configure.apply_background_aux_tier(cfg, configure.Report())
        return cfg.get("auxiliary") or {}

    def test_each_provider_gets_its_own_cheapest_model(self):
        for provider, cheap in self.tiers().items():
            if provider in configure.CLAUDE_CLI_PROVIDERS:
                continue
            aux = self.run_on({"model": {"provider": provider, "default": "the-big-one"}})
            for task in configure.BACKGROUND_AUX_TASKS:
                self.assertEqual(aux[task], {"provider": provider, "model": cheap}, (provider, task))
            self.assertNotIn("compression", aux, "an in-conversation task is not moved")
            self.assertNotIn("background_review", aux, "the owner put the review on the main model")

    def test_a_custom_endpoint_keeps_the_chosen_model(self):
        aux = self.run_on({"model": {"provider": "custom", "default": "qwen-32b",
                                     "base_url": "http://localhost:1234/v1"}})
        self.assertEqual(aux, {})

    def test_the_claude_cli_brain_is_left_to_its_lane(self):
        self.assertEqual(self.run_on({"model": {"provider": "claude-code-cli", "default": "sonnet"}}), {})

    def test_a_persons_own_value_and_the_deepseek_lane_are_kept(self):
        cfg = {"model": {"provider": "openrouter", "default": "big"},
               "auxiliary": {"monitor": {"provider": "openrouter", "model": "my/own-choice"},
                             "title_generation": {"provider": configure.AUX_PROVIDER,
                                                  "model": configure.AUX_MODEL}}}
        aux = self.run_on(cfg)
        self.assertEqual(aux["monitor"]["model"], "my/own-choice")
        self.assertEqual(aux["title_generation"]["model"], configure.AUX_MODEL)

    def test_moes_pin_follows_the_brain(self):
        t = self.tiers()
        cfg = {"model": {"provider": "openai-codex", "default": "big"}}
        self.run_on(cfg)
        cfg["model"] = {"provider": "openai-api", "default": "big"}
        aux = self.run_on(cfg)
        self.assertEqual(aux["monitor"], {"provider": "openai-api", "model": t["openai-api"]})
        cfg["model"] = {"provider": "custom", "default": "local", "base_url": "http://x"}
        self.assertNotIn("monitor", self.run_on(cfg), "a custom brain drops Moe's old pin")


class PersonJobRepairTest(unittest.TestCase):
    """A routine made before moe-screen's creation rules is brought up to
    them: the owner's "X daily growth" (made 2026-09-18) ran nine times on
    haiku with `deliver: local`, reaching nobody. Records below are shaped
    like the owner's ~/.hermes/cron/jobs.json, read 2026-09-24."""

    OWN = tuple(name for _, _, name in configure.JOB_SPECS)

    def job(self, **kw):
        base = {"id": "711b145c4ed2", "name": "X daily growth", "model": None,
                "deliver": "local", "no_agent": False, "origin": {"platform": "api_server"}}
        base.update(kw)
        return base

    def test_an_island_routine_on_the_cheap_model_and_a_dead_end_is_repaired(self):
        self.assertEqual(configure.person_job_repairs(self.job(), self.OWN),
                         {"model": "conversation", "deliver": "moe"})

    def test_only_what_is_missing_is_changed(self):
        self.assertEqual(configure.person_job_repairs(self.job(deliver="moe"), self.OWN),
                         {"model": "conversation"})
        self.assertEqual(configure.person_job_repairs(self.job(model="opus"), self.OWN),
                         {"deliver": "moe"})
        self.assertEqual(configure.person_job_repairs(self.job(model="opus", deliver="moe"), self.OWN), {})

    def test_a_bare_chat_app_is_migrated_to_the_owner_once(self):
        """Ticket #15 and the reach-owner review (finding 5): a routine made to
        `deliver: whatsapp` reaches whatever that platform's home chat is. A job
        whose creating words were recorded becomes `moe` — the owner, where
        they are — or `moe:<app>` when those words named the app. Jobs with no
        recorded words are left alone, as are the apps the cloud cannot carry
        (email, sms, signal), and a second pass changes nothing."""
        # Review round 2: a job with no recorded words is the owner's own and
        # is left EXACTLY as it is — `moe,telegram` stays `moe,telegram`.
        for d in ("moe,telegram", "telegram", "whatsapp"):
            self.assertEqual(configure.person_job_repairs(self.job(model="opus", deliver=d),
                                                          self.OWN), {}, d)
        asked = [{"origin": "person", "text": "remind me every Friday"}]
        self.assertEqual(configure.person_job_repairs(
            self.job(model="opus", deliver="moe,telegram", grounding_words=asked), self.OWN),
            {"deliver": "moe"})
        said = [{"origin": "person", "text": "text me on WhatsApp every Friday"},
                {"origin": "model", "text": "telegram"}]
        self.assertEqual(configure.person_job_repairs(
            self.job(model="opus", deliver="whatsapp,telegram", grounding_words=said), self.OWN),
            {"deliver": "moe:whatsapp"})
        for d in ("email", "sms", "signal:+1555", "telegram:-100123", "moe:telegram"):
            self.assertEqual(configure.person_job_repairs(self.job(model="opus", deliver=d),
                                                          self.OWN), {}, d)
        # What the repairer runs is the function's SOURCE, alone: it must work there.
        import inspect
        ns = {}
        exec(("PERSON_JOB_PLATFORMS = %r\nCONVERSATION_MODEL = %r\n"
              % (configure.PERSON_JOB_PLATFORMS, configure.CONVERSATION_MODEL))
             + inspect.getsource(configure.person_job_repairs), ns)
        self.assertEqual(ns["person_job_repairs"](self.job(model="opus", deliver="telegram",
                                                           grounding_words=asked)),
                         {"deliver": "moe"})

    def test_moes_own_jobs_chat_platform_jobs_and_scripts_are_never_touched(self):
        self.assertEqual(configure.person_job_repairs(
            self.job(name="moe-proactive", model="haiku", deliver="moe", origin=None), self.OWN), {})
        self.assertEqual(configure.person_job_repairs(self.job(name=self.OWN[0]), self.OWN), {})
        self.assertEqual(configure.person_job_repairs(self.job(origin=None), self.OWN), {})
        self.assertEqual(configure.person_job_repairs(
            self.job(origin={"platform": "telegram"}), self.OWN), {})
        self.assertEqual(configure.person_job_repairs(self.job(no_agent=True, deliver="moe"), self.OWN), {})

    def test_the_rule_matches_the_adapters_no_send_path(self):
        """Two copies of one list drift; hold them equal."""
        import re as _re
        adapter = open(os.path.join(os.path.dirname(SCRIPT), os.pardir,
                                    "hermes-plugins", "moe-screen", "adapter.py")).read()
        m = _re.search(r"_NO_SEND_PATH = frozenset\(\{([^}]*)\}\)", adapter)
        self.assertIsNotNone(m)
        self.assertEqual(set(_re.findall(r'"([^"]*)"', m.group(1))), set(configure.PERSON_JOB_PLATFORMS))
        self.assertIn('CONVERSATION_MODEL = "%s"' % configure.CONVERSATION_MODEL, adapter)

if __name__ == "__main__":
    unittest.main()


class ShellDenyMirrorTests(unittest.TestCase):
    def test_bash_rules_become_globs(self):
        import importlib.util, pathlib
        spec = importlib.util.spec_from_file_location(
            "ch", pathlib.Path(__file__).resolve().parent.parent / "configure-hermes.py")
        ch = importlib.util.module_from_spec(spec); spec.loader.exec_module(ch)
        globs = ch.shell_deny_globs(["Bash(rm -rf *)", "Bash(sudo *)", "mcp__x__send", "Bash(git push *)"])
        self.assertEqual(globs, ["rm -rf *", "sudo *", "git push *"])


# ---------------------------------------------------------------------------
# The persona split — docs/CLOUD-PLAN.md §7, §14.
#
# SOUL.md travels: slice 2½ publishes it to the ledger as the `soul` document
# and the away machine writes it into its own HERMES_HOME. So a delivery rule
# left in this file is a delivery rule enforced on a Linux VM with no speaker,
# which is exactly how the owner found it — "it should know that it's Moe".
#
# These pin the two halves apart: identity in the document, delivery on the
# channel, and the machine's copy of the delivery text byte-identical to the
# Mac's so the two runtimes cannot drift into disagreeing about it.

_TOOLS_FIRST = ("Before you hand a step to them, look at what your tools say they "
                "can do — read their descriptions, search for one that fits — and try "
                "that first: your tools can do more than you remember, and a step is "
                "theirs only once you have checked that none of them can do it.")


# 2026-11-12, "ask, then continue": what the soul says when the browser cannot
# open signed in as the person. As it reads once the line continuations are
# gone, with the space that joins it to the sentence after it.
_SIGNED_OUT_ASK = (
    "When your browser cannot open signed in as them, it tells you why and does "
    "nothing. That choice is theirs: say the reason in a line and ask — \"I'm "
    "not logged in, I'm having an issue opening your signed-in browser. Do you "
    "want me to still continue, signed out?\" — and go on signed out only after "
    "they say yes; with nobody there to ask, report what is waiting and stop. "
    "Whatever you then do signed out was done as nobody: say so, and never tell "
    "them it was done as them. ")


# 2026-11-13 (7efc9c47): the first paragraph gained this sentence, and the
# soul without it was filed last in MOE_SOUL_PRIOR. Tests that pin a filed
# soul by position compare against the soul before it.
_THEIR_WORDS = (" Talk to them in their words, not the machine's: no file paths, "
                "command or tool names, error codes or settings keys in what you "
                "say — \"the marketing notes\", not the file's path; \"the posting "
                "service turned me away\", not its error. When they ask for the "
                "detail, or are working on the technical side with you, give it "
                "exactly.")


def _before_their_words(soul):
    assert _THEIR_WORDS in soul, "the their-words sentence moved"
    return soul.replace(_THEIR_WORDS, "", 1)


def _script_constant(name):
    """Read a module-level constant out of configure-hermes.py without
    importing it (the filename has a dash, and importing runs argparse)."""
    import ast
    with open(SCRIPT, encoding="utf-8") as f:
        tree = ast.parse(f.read())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise AssertionError("%s not found in configure-hermes.py" % name)


class PersonaSplitTests(ConfigureFixture):
    """Identity travels; delivery rules stay with the channel."""

    SPEAKER_WORDS = ("spoken", "aloud", "read back", "for the ear",
                     "markdown", "bullets", "code fences", "this Mac")

    def soul(self):
        return self.read(os.path.join(self.hermes_home, "SOUL.md"))

    def test_seeded_soul_is_identity_only(self):
        """A fresh install's SOUL.md says who Moe is and nothing about how a
        reply is delivered — because this file is read by a runtime that has
        no microphone."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        soul = self.soul()
        self.assertIn("You are Moe", soul)
        self.assertIn("you are Moe", soul)          # "if asked what you are"
        self.assertIn("never discuss, name, or allude to the software", soul)
        for word in self.SPEAKER_WORDS:
            self.assertNotIn(word, soul,
                             "%r is a delivery rule and must not travel: %r" % (word, soul))

    def test_hermes_default_identity_is_replaced(self):
        """Unchanged from before the split: Hermes's own name in the cached
        identity slot is the thing this was written to fix."""
        os.makedirs(self.hermes_home, exist_ok=True)
        with open(os.path.join(self.hermes_home, "SOUL.md"), "w", encoding="utf-8") as f:
            f.write("You are Hermes Agent, built by Nous Research.\n")
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn("You are Moe", self.soul())

    def test_moes_own_earlier_soul_is_upgraded(self):
        """The case the split lives or dies on. Every Mac that has run Moe
        already has a SOUL.md Moe wrote, full of spoken-aloud rules, and it is
        already on the ledger. If that counted as "the person's", the split
        would reach no existing install at all."""
        prior = _script_constant("MOE_SOUL_PRIOR")
        self.assertTrue(prior, "no prior persona recorded")
        os.makedirs(self.hermes_home, exist_ok=True)
        with open(os.path.join(self.hermes_home, "SOUL.md"), "w", encoding="utf-8") as f:
            f.write(prior[0])
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        soul = self.soul()
        self.assertNotIn("spoken", soul)
        self.assertEqual(soul.strip(), _script_constant("MOE_SOUL").strip())

    def test_every_earlier_soul_moe_wrote_is_upgraded_to_the_current_one(self):
        """Each time MOE_SOUL changes, the text it replaces joins
        MOE_SOUL_PRIOR — or every existing install reads its own copy as
        "the person's" and never gets the change. 2026-09-10's "you do
        things" paragraph reaches nobody unless the 09-03 text upgrades."""
        prior = _script_constant("MOE_SOUL_PRIOR")
        self.assertGreaterEqual(len(prior), 2)
        for old in prior:
            with self.subTest(old=old[:60]):
                os.makedirs(self.hermes_home, exist_ok=True)
                with open(os.path.join(self.hermes_home, "SOUL.md"), "w", encoding="utf-8") as f:
                    f.write(old)
                code, out = self.run_script()
                self.assertEqual(code, 0, out)
                self.assertEqual(self.soul().strip(), _script_constant("MOE_SOUL").strip())

    def test_the_soul_says_do_it_rather_than_explain_it(self):
        """2026-09-09: a rejected upload got a Preview how-to instead of
        being fixed. The rule that prevents it must be in the one slot
        every model reads."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn("do it for them", soul)
        self.assertIn("waits for their", soul)

    def test_the_soul_reaches_every_brokered_service_through_the_router(self):
        """2026-09-20: the owner's cloud copy, asked about his Cloudflare,
        ran a lexical search over its tool list, found no `cloudflare_*`
        tool and said "No Cloudflare integration available" — then called
        COMPOSIO_MANAGE_CONNECTIONS to check Gmail, which minted a sign-in.
        Nothing in its prompt said the ~500 brokered services live behind
        COMPOSIO_SEARCH_TOOLS. The SOUL is the one slot that travels to the
        machine as a ledger document with no new image, so the rule lives
        here; the Mac reads it too, where it agrees with the connections
        block it already has. Self-conditioned, so a Mac with no broker is
        not told to call a tool it does not have."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn("COMPOSIO_SEARCH_TOOLS", soul)
        self.assertIn("COMPOSIO_MULTI_EXECUTE_TOOL", soul)
        self.assertIn("never means it is unavailable", soul)
        self.assertIn("COMPOSIO_MANAGE_CONNECTIONS starts a sign-in and is never a status check",
                      soul)
        self.assertIn("If no COMPOSIO_SEARCH_TOOLS is in your reach", soul)
        # The text it replaced is filed, so every existing install upgrades
        # (test_every_earlier_soul_moe_wrote_is_upgraded_to_the_current_one
        # is the proof; this pins that the newest prior is the pre-broker
        # soul and not a copy of the current one).
        prior = _script_constant("MOE_SOUL_PRIOR")
        pre_broker = [p for p in prior if "COMPOSIO" not in p]
        self.assertTrue(pre_broker, "the pre-broker soul is not filed")
        self.assertTrue(soul.startswith(pre_broker[-1].rstrip("\n")[:200]))

    def test_the_soul_reaches_the_owner_only_through_reach_owner(self):
        """2026-09-25: "message me on Telegram" became a cron job told to
        WhatsApp him, and it messaged a contact. The rule is channel-agnostic
        on purpose — no app is named — and slice B's contact-send refusal
        points at the same tool name."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn("reach_owner", soul)
        self.assertIn("Never use a tool that sends to a contact to reach them", soul)
        self.assertIn("a job that delivers to moe", soul)
        para = soul[soul.index("You can reach them yourself"):]
        for app in ("telegram", "whatsapp", "slack", "imessage", "sms"):
            self.assertNotIn(app, para.lower())
        prior = _script_constant("MOE_SOUL_PRIOR")
        pre_reach = [p for p in prior if "reach_owner" not in p and "Most checks that ask whether" not in p]
        self.assertTrue(pre_reach)
        self.assertNotIn("reach_owner", pre_reach[-1])
        # The pre-reach_owner soul is the same text up to where the new paragraph begins.
        self.assertTrue(pre_reach[-1].rstrip("\n").endswith("none of this applies."))

    def test_human_checks_are_the_browsers_and_the_rest_go_to_them(self):
        """2026-09-25, owner: Moe gets past "are you human?" checks itself
        where its browser can (the fork's CAPTCHA ladder); anything else is the
        hand-over above. Never from a screenshot, and a ticket-selling site
        always goes to the person (US BOTS Act)."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn("Most checks that ask whether you are human", soul)
        self.assertIn("your browser gets past by itself", soul)
        self.assertIn("never try to solve one by looking at a screenshot", soul)
        self.assertIn("a ticket-selling site always goes to them", soul)
        self.assertIn("a CAPTCHA your browser could not get past", soul)
        # Filed, so every install running the soul before it is upgraded.
        prior = _script_constant("MOE_SOUL_PRIOR")
        before = [x for x in prior if "Most checks that ask whether you are human" not in x]
        self.assertIn("reach_owner", before[-1])
        self.assertIn("Most checks that ask whether you are human", prior[-1],
                      "the human-checks soul is itself filed once the recipient rule replaced it")

    def test_the_soul_finishes_what_it_starts(self):
        """Ticket #10, 2026-09-23. Asked for the exact fare of a nonstop, the
        brain said "let me check China Eastern directly for a real fare",
        ran ONE web search, and ended the turn by its own choice (stop_reason
        end_turn, 100 s into a 30-minute work limit, ~84k tokens of context)
        with "that same route has been running $160 to $220 one-way lately —
        so figure around there". No limit stopped it; nothing it read said a
        failed route is a reason to take the next one, and the honesty
        paragraph told it to hand the lookup back ("how it could be found
        out"). The rule is general on purpose — nothing about flights."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn("You finish what you start.", soul)
        self.assertIn("A route that fails is not an answer", soul)
        self.assertIn("Never trade the real answer for an approximation", soul)
        self.assertIn("Pause only when the next step truly needs them", soul)
        self.assertIn("you go and find it out", soul)
        self.assertNotIn("how it could be found out", soul)
        # The send gate still stands beside it.
        self.assertIn("still waits for their yes", soul)
        # It agrees with the per-turn delivery reminder, which tells the
        # brain to say what it is about to do: announcing is allowed, and the
        # announcement is a promise.
        self.assertNotIn("Never say what you are about to do", soul)
        self.assertIn("they are a promise", soul)
        for word in ("flight", "fare", "airline"):
            self.assertNotIn(word, soul.lower())
        # The text it replaced is filed, or every install already running
        # reads its own SOUL.md as the person's and never gets this.
        prior = _script_constant("MOE_SOUL_PRIOR")
        before = [p for p in prior if "You finish what you start" not in p]
        self.assertIn("how it could be found out", before[-1])
        self.assertIn("COMPOSIO_SEARCH_TOOLS", before[-1])

    def test_an_either_or_yes_is_asked_about_not_guessed(self):
        """Ticket #11, 2026-09-24. Moe asked "want me to open the Show HN
        page so you just hit submit, or are you posting it yourself?", heard
        "yes and also its memoe.app", and submitted the post itself under
        the owner's account. The yes answered neither branch; the brain took
        the one where it finished the job. The rule is general — nothing
        about Hacker News — and leans toward leaving the last click to them."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn("That yes must answer the question you actually asked", soul)
        self.assertIn("ask which one in a single line before you act", soul)
        self.assertIn("leaves the final click to them", soul)
        self.assertIn("still waits for their yes", soul)
        for word in ("hacker news", "show hn", "ycombinator"):
            self.assertNotIn(word, soul.lower())
        prior = _script_constant("MOE_SOUL_PRIOR")
        before = [x for x in prior if "That yes must answer" not in x]
        self.assertIn("You finish what you start.", before[-1])
        self.assertIn("That yes must answer", prior[-1], "the either/or text is filed when it is replaced")

    def test_their_chrome_is_reached_only_through_the_extension(self):
        """Ticket #13, 2026-09-24. The paragraph said "Never open, script or
        drive the person's own browser" — added by a session on 2026-09-11
        (3f8d8a09); the owner never asked for it and wants the opposite. What
        must survive is the ban that stopped the 2026-09-20 Launch Services
        hijack: no second copy of their Chrome from the shell, no debugging
        port, no copied profile. And it has to be true whether or not the
        lane is on, because SOUL.md does not change when the switch does."""
        soul = _script_constant("MOE_SOUL")
        self.assertNotIn("Never open, script or drive", soul)
        self.assertIn("Never start a second copy of the person's browser from the shell", soul)
        self.assertIn("never launch their Chrome with a debugging port or a copied profile", soul)
        self.assertIn("only through the Memoe extension, and only while it is connected", soul)
        self.assertIn('in your own "Moe" tab group', soul)
        self.assertIn("Never read, move, close or type into a tab outside that group", soul)
        self.assertIn("leave their focus where it is", soul)
        self.assertIn("If the extension is not connected", soul)
        # The rest of the paragraph is kept: the profile rule and "not done".
        self.assertIn("Settings › Permissions › Browse as", soul)
        self.assertIn("Work that did not happen is never reported as done", soul)
        # Filed, so every install running the 09-24 soul is upgraded.
        # (Found by content, not position: later changes file their own
        # priors after it — 2026-09-25's reach_owner paragraph is one.)
        prior = _script_constant("MOE_SOUL_PRIOR")
        before = [p for p in prior if "Memoe extension" not in p]
        self.assertIn("Never open, script or drive the person's", before[-1])
        self.assertIn("That yes must answer the question you actually asked", before[-1])

    def test_a_page_only_they_can_finish_is_handed_to_them_and_devices_are_grounded(self):
        """2026-09-24/25. A Google sign-in in Moe's out-of-sight browser asked
        for a passkey; the owner said "open the page so I can do it", nothing
        could be shown, and Moe told him three times to "approve it on your
        phone" -- nothing had been sent to a phone. When he read a sign-in code
        aloud, Moe refused to enter it. The rule is general: no site, no
        vendor, no tool name."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn("Only tell them that something was sent, or is waiting for them on their phone "
                      "or another device, when a tool result shows it", soul)
        self.assertIn("a passkey, a security key, an identity check, a CAPTCHA your browser could not get past", soul)
        self.assertIn("bringing that page up in front of them", soul)
        self.assertIn("waiting for them to say they are done", soul)
        # Until recipient-ground lands the fork refuses a stated code, so the soul promises only this.
        self.assertIn("A sign-in code they read out to you, they type into that page themselves", soul)
        self.assertNotIn("you enter for them", soul)
        self.assertIn("when they are away from the Mac, it means telling them what is waiting for them", soul)
        for word in ("google", "tinylaunch", "browser_handoff"):
            self.assertNotIn(word, soul.lower())
        # The text it replaced is filed, and it is the extension-lane soul.
        # (By content, not position: the reach_owner paragraph files the soul
        # it replaced after this one.)
        prior = _script_constant("MOE_SOUL_PRIOR")
        filed = [p for p in prior if "only through the Memoe extension" in p
                 and "Only tell them that something was sent" not in p]
        self.assertTrue(filed, "the extension-lane soul is not filed")
        self.assertTrue(any("Only tell them that something was sent" in p for p in prior),
                        "the hand-off soul was not filed when reach_owner replaced it")

    def test_people_in_memory_are_context_never_recipients(self):
        """2026-09-25: a scheduled job told "send ONE WhatsApp message to
        Jordan" (the owner) sent it to his grandfather, the one WhatsApp
        contact its memory named. The engine now refuses such a send; the
        rule is also in the one slot every model reads. General on purpose —
        nothing about WhatsApp or family."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn("People in your memory are context, never recipients.", soul)
        self.assertIn("when the person names them in this request", soul)
        self.assertIn("If you do not know who to send to, look it up or ask", soul)
        for word in ("whatsapp", "grandfather", "grandpa", "moshe"):
            self.assertNotIn(word, soul.lower())
        prior = _script_constant("MOE_SOUL_PRIOR")
        before = [x for x in prior if "never recipients" not in x]
        self.assertIn("Most checks that ask whether you are human", before[-1],
                      "the soul it replaced is filed")

    def test_a_step_it_cannot_do_is_asked_about_never_dropped(self):
        """2026-09-29, owner: Moe met a step it could not do alone (a passcode
        only the person knows), said it could not, and moved on to the next
        thing without asking. The owner's rule, kept general on purpose because
        it must hold for any task: question your own approach first, then ask
        the person for exactly what is missing — never skip part of what they
        asked for without their say."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn("first \\\nsuspect your own approach".replace("\\\n", ""), soul)
        self.assertIn("never a reason to drop it", soul)
        self.assertIn("do not skip part of what they asked for, or quietly move on", soul)
        self.assertIn("keep going on the rest while you wait", soul)
        self.assertIn("saying what you tried", soul)
        for word in ("passcode", "encrypted", "x.com", "twitter", "direct message"):
            self.assertNotIn(word, soul.lower())
        prior = _script_constant("MOE_SOUL_PRIOR")
        # By content, not position: the "earlier can't" sentence files the
        # soul it replaced after this one.
        before = [x for x in prior if "never a reason to drop it" not in x]
        self.assertIn("never recipients", before[-1], "the soul it replaced is filed")

    def test_an_earlier_cant_is_tried_again(self):
        """2026-09-29, owner: having decided earlier in the conversation that a
        step was the person's to do, Moe repeated that conclusion when the task
        came back to it instead of trying again with the tools it had by then.
        Its own earlier "can't" is not evidence. General on purpose — nothing
        about any site, check or kind of code."""
        soul = _script_constant("MOE_SOUL")
        sentence = ('An earlier "can\'t" is not a standing fact. Something that '
                    "failed before, or that you concluded earlier was theirs to do, "
                    "you try again when the task comes back to it: your tools, the "
                    "page in front of you and their situation all change, and your "
                    "own earlier conclusion is not evidence that it cannot be done.")
        self.assertIn(sentence, soul)
        # It sits with finishing what you start, after the ask-don't-drop rule.
        self.assertLess(soul.index("never a reason to drop it"), soul.index(sentence))
        self.assertLess(soul.index("You finish what you start."), soul.index(sentence))
        for word in ("google", "captcha", "passcode", "x.com"):
            self.assertNotIn(word, sentence.lower())
        for word in ("google", "passcode", "x.com"):
            self.assertNotIn(word, soul.lower())
        prior = _script_constant("MOE_SOUL_PRIOR")
        # Only a soul filed by a later sentence may still carry this one.
        self.assertEqual([x for x in prior if "is not a standing fact" in x], list(prior[-4:]))
        filed = [x for x in prior if "never a reason to drop it" in x
                 and "is not a standing fact" not in x]
        self.assertEqual(len(filed), 1, "the soul it replaced is filed, once")
        pre = _before_their_words(soul)
        before_jobs = pre[:pre.index("\n\nA scheduled job runs wherever they are")] + "\n"
        self.assertEqual(filed[0], before_jobs.replace(sentence + " ", "").replace(_TOOLS_FIRST + " ", "")
                         .replace(_SIGNED_OUT_ASK, ""),
                         "the filed soul is the current one without this sentence")

    def test_tools_are_checked_before_a_step_is_handed_over(self):
        """2026-09-30, owner: Moe handed the person steps its own tools could do,
        going by what it remembered they could do. Before anything becomes the
        person's, it reads what its tools say. General on purpose."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn(_TOOLS_FIRST, soul)
        self.assertLess(soul.index("never a reason to drop it"), soul.index(_TOOLS_FIRST))
        for word in ("google", "captcha", "passkey", "account", "browser"):
            self.assertNotIn(word, _TOOLS_FIRST.lower())
        prior = _script_constant("MOE_SOUL_PRIOR")
        # Only a soul filed by a later change may carry it: the 2026-11-12
        # "ask, then continue" text filed the soul that had it.
        # The 2026-11-13 jobs paragraph (D2) filed the next one after it.
        # Then 7efc9c47's their-words sentence filed the soul after that.
        self.assertEqual([x for x in prior if _TOOLS_FIRST in x], list(prior[-3:]))
        pre = _before_their_words(soul)
        self.assertEqual(prior[-1], pre, "the their-words sentence is the only change")
        jobs = pre[pre.index("\n\nA scheduled job runs wherever they are"):]
        self.assertEqual(prior[-2], pre.replace(jobs, "\n"), "the D2 paragraph is the only change")
        self.assertEqual(prior[-4], prior[-2].replace(_TOOLS_FIRST + " ", "").replace(_SIGNED_OUT_ASK, ""),
                         "the soul it replaced is filed, and differs only by this sentence")

    def test_a_browser_that_cannot_open_signed_in_is_asked_about_not_assumed(self):
        """2026-11-12, owner: "ask, then continue". Hermes's browser, when the
        person's signed-in profile cannot load, now runs nothing and hands the
        choice back. The soul said the browser "is signed in as they are" and
        had no word for when it is not; these sentences carry the question and
        the two rules — only after their yes, and never reported as them."""
        soul = _script_constant("MOE_SOUL")
        self.assertIn(_SIGNED_OUT_ASK, soul)
        self.assertIn("Do you want me to still continue, signed out?", soul)
        self.assertIn("go on signed out only after they say yes", soul)
        self.assertIn("with nobody there to ask, report what is waiting and stop", soul)
        self.assertIn("never tell them it was done as them", soul)
        # It sits in the browser paragraph, ahead of "not done".
        self.assertLess(soul.index("Settings › Permissions › Browse as"), soul.index(_SIGNED_OUT_ASK))
        self.assertLess(soul.index(_SIGNED_OUT_ASK),
                        soul.index("Work that did not happen is never reported as done"))
        # No tool or argument name: the soul is read by every model on every
        # surface, and the mechanism is the tool's to describe.
        for word in ("allow_signed_out", "browser_exec", "signed_out_available"):
            self.assertNotIn(word, soul)
        # The soul it replaced is filed LAST and differs only by these
        # sentences — or every Mac running it reads as "customised" and
        # never gets them.
        prior = _script_constant("MOE_SOUL_PRIOR")
        # Filed before the jobs paragraph (D2, 2026-11-13) and the their-words
        # sentence (7efc9c47), which are filed after it.
        pre = _before_their_words(soul)
        self.assertEqual(prior[-1], pre)
        before_jobs = pre[:pre.index("\n\nA scheduled job runs wherever they are")] + "\n"
        self.assertEqual(prior[-3], before_jobs.replace(_SIGNED_OUT_ASK, ""))
        self.assertFalse(any("still continue, signed out" in x for x in prior[:-2]))

    def test_writing_the_owner_never_waits_on_a_slow_composio(self):
        """configure-hermes runs at every launch; Composio answers over the
        network. The owner's Composio mail is refreshed in a detached process,
        so a Composio that takes 20 s costs the launch nothing."""
        import time
        import types
        module = _load_script()
        moe = tempfile.mkdtemp()
        hermes = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, moe, True)
        self.addCleanup(shutil.rmtree, hermes, True)
        os.makedirs(os.path.join(moe, "connectors"))
        with open(os.path.join(moe, "connectors", "composio.py"), "w") as fh:
            fh.write("import time\ntime.sleep(20)\ndef rows():\n    return []\n")
        report = types.SimpleNamespace(written=[], skipped=[])
        saved = {k: os.environ.get(k) for k in ("MOE_HOOK_TEST", "MOE_TEST_COMPOSIO_DETACHED")}
        os.environ.update({"MOE_HOOK_TEST": "1", "MOE_TEST_COMPOSIO_DETACHED": "1"})
        try:
            t = time.monotonic()
            module.write_owner_identity(moe, hermes, report)
            took = time.monotonic() - t
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.assertEqual(report.skipped, [])
        self.assertLess(took, 2.0, "configure waited on Composio")
        self.assertTrue(os.path.isfile(os.path.join(moe, "owner.json")))

    def test_owner_identity_is_written_from_the_linked_accounts(self):
        """The owner as data: owner.json under Moe's home, from what this Mac
        is linked as — the gate and every connector read it (tools/recipients.py)."""
        os.makedirs(self.hermes_home, exist_ok=True)
        with open(os.path.join(self.hermes_home, ".env"), "a", encoding="utf-8") as f:
            f.write("TELEGRAM_BOT_TOKEN=1:x\nTELEGRAM_ALLOWED_USERS=4242,99\n")
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        with open(os.path.join(self.moe_home, "owner.json"), encoding="utf-8") as f:
            owner = json.load(f)
        self.assertEqual(owner["telegram"], ["4242"])
        self.assertIn("never messages these unasked", owner["README"])

    def test_a_persons_own_soul_is_never_rewritten(self):
        """The standing rule, and the owner's explicit condition on the split:
        a customised SOUL.md is theirs."""
        mine = "You are Ada. You speak in couplets and you never apologise.\n"
        os.makedirs(self.hermes_home, exist_ok=True)
        with open(os.path.join(self.hermes_home, "SOUL.md"), "w", encoding="utf-8") as f:
            f.write(mine)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self.soul(), mine)

    # -- the other half: delivery, per channel ------------------------------

    def test_chat_platforms_get_the_written_delivery_rule(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        hints = self.cfg().get("platform_hints") or {}
        written = _script_constant("MOE_DELIVERY_WRITTEN")
        for platform in _script_constant("MOE_DELIVERY_PLATFORMS"):
            self.assertEqual(hints.get(platform), {"append": written},
                             "%s did not get the written delivery rule" % platform)
        # Append, never replace: Hermes's own hint knows the platform's
        # markdown subset and message limits, and we do not.
        for value in hints.values():
            self.assertNotIn("replace", value)

    def test_the_notch_is_not_given_a_chat_rule(self):
        """The spoken rules are injected per turn by the app
        (Sources/Moe/Brain/BrainPrompt.swift). Telling the notch it is being
        read on a phone would be the same mistake in the other direction."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        hints = self.cfg().get("platform_hints") or {}
        self.assertNotIn("moe", hints)
        self.assertNotIn("api_server", hints)

    def test_a_persons_own_platform_hint_is_left_alone(self):
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        cfg["platform_hints"]["telegram"] = {"append": "Always answer in Dutch."}
        cfg["platform_hints"]["whatsapp"] = {"replace": "Only emoji."}
        with open(self.cfg_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(cfg, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        hints = self.cfg()["platform_hints"]
        self.assertEqual(hints["telegram"], {"append": "Always answer in Dutch."})
        self.assertEqual(hints["whatsapp"], {"replace": "Only emoji."})

    def _set_reply_length(self, value):
        path = os.path.join(self.moe_home, "config.json")
        try:
            with open(path, encoding="utf-8") as f:
                moe = json.load(f)
        except OSError:
            moe = {}
        moe["replyLength"] = value
        with open(path, "w", encoding="utf-8") as f:
            json.dump(moe, f)

    def test_the_reply_length_setting_reaches_the_chat_channels_and_back(self):
        """Settings › Replies › How much Moe says. The notch gets it per
        turn from the app; a Telegram message never passes through that
        code, so its only carrier is the hint this script writes."""
        by_length = _load_script().MOE_DELIVERY_BY_LENGTH
        self.assertEqual(by_length["balanced"], _script_constant("MOE_DELIVERY_WRITTEN"))
        for length in ("detailed", "short", "balanced"):
            with self.subTest(length=length):
                self._set_reply_length(length)
                code, out = self.run_script()
                self.assertEqual(code, 0, out)
                hints = self.cfg().get("platform_hints") or {}
                for platform in _script_constant("MOE_DELIVERY_PLATFORMS"):
                    self.assertEqual(hints.get(platform), {"append": by_length[length]})

    def test_a_persons_own_hint_survives_a_reply_length_change(self):
        self.assertEqual(self.run_script()[0], 0)
        cfg = self.cfg()
        cfg["platform_hints"]["telegram"] = {"append": "Always answer in Dutch."}
        with open(self.cfg_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(cfg, f)
        self._set_reply_length("detailed")
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        hints = self.cfg()["platform_hints"]
        self.assertEqual(hints["telegram"], {"append": "Always answer in Dutch."})
        self.assertEqual(hints["whatsapp"], {"append": _load_script().MOE_DELIVERY_BY_LENGTH["detailed"]})

    def test_rerunning_changes_nothing(self):
        self.assertEqual(self.run_script()[0], 0)
        first = (self.soul(), self.cfg().get("platform_hints"))
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual((self.soul(), self.cfg().get("platform_hints")), first)


class DeliveryRuleAgreesAcrossRuntimes(unittest.TestCase):
    """The Mac writes its chat hint through configure-hermes.py; the away
    machine never runs that script and writes its own in its boot script.
    Two runtimes, two writers, one rule — so the strings have to be the same
    string, and nothing but a test will keep them that way."""

    def test_boot_sh_telegram_hint_matches_the_mac(self):
        written = _script_constant("MOE_DELIVERY_WRITTEN")
        boot = os.path.join(HERE, "..", "..", "..", "deploy", "away", "boot.sh")
        with open(boot, encoding="utf-8") as f:
            text = f.read()
        line = [l for l in text.splitlines()
                if l.startswith("posture platform_hints.telegram ")]
        self.assertEqual(len(line), 1, "boot.sh sets the telegram hint exactly once")
        payload = json.loads(line[0].split("'", 1)[1].rsplit("'", 1)[0])
        self.assertEqual(payload, {"append": written},
                         "the machine's Telegram delivery rule has drifted from the Mac's")


def _load_script():
    """configure-hermes.py as a module, without running it.

    The filename has a dash and importing it runs argparse, so it is loaded by
    path with `sys.argv` neutered — the same trick the script itself uses to
    load the relay rule out of the payload.
    """
    import importlib.util
    spec = importlib.util.spec_from_file_location("configure_hermes_under_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = ["configure-hermes.py"]
    try:
        spec.loader.exec_module(module)
    except SystemExit:
        pass
    finally:
        sys.argv = saved
    return module


class RelaySettingsRule(unittest.TestCase):
    """`relay_settings` on its own, because the end-to-end class costs ~25s a
    case and the states that matter are combinations.

    **Every case here is one a review found the first version getting wrong.**
    That version compared what it was about to write against `.env` and treated
    any difference as the person's preference, with no record of what it had
    written itself — so de-enrolling and re-enrolling bricked the relay
    permanently, a changed `cloudEdge` never propagated, and an unenrolled Mac
    had the person's own settings wiped on every launch. The three keys are
    owned outright now, and these are the states that proves.
    """

    @classmethod
    def setUpClass(cls):
        cls.script = _load_script()
        import base64
        cls.token = base64.b64encode(b"\x33" * 32).decode()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-relay-rule-")
        os.makedirs(os.path.join(self.tmp, "cloud"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def enrol(self, edge="https://edge.example", sync=None):
        """`sync=None` leaves the key out, the way every credential written
        before 2026-09-04 (and every machine credential still) is."""
        body = {"tenant": "t", "device": "d", "token": self.token}
        if sync is not None:
            body["sync"] = sync
        with open(os.path.join(self.tmp, "cloud", "credential.json"), "w") as f:
            json.dump(body, f)
        with open(os.path.join(self.tmp, "config.json"), "w") as f:
            json.dump({"cloudEdge": edge}, f)

    def de_enrol(self):
        os.unlink(os.path.join(self.tmp, "cloud", "credential.json"))

    def settings(self, env):
        return self.script.relay_settings(self.tmp, env)

    # -- consent (§18.29j): a credential is an identity, not a yes -----------

    def test_a_connections_only_mac_gets_no_dial(self):
        """`"sync": false` is a Mac that enrolled to be given its Composio
        project and agreed to send nothing. A relay socket is the edge handing
        it the person's turns to answer, so: nothing written, and quietly,
        because this runs on every launch."""
        self.enrol(sync=False)
        self.assertEqual(self.settings({}), ({}, None))

    def test_a_connections_only_mac_has_an_existing_dial_cleared(self):
        """The de-enrolment shape for a Mac that is still enrolled: consent
        withdrawn, the dial goes — and the note says which of the two facts
        this is, because "not enrolled" would send somebody to re-enrol."""
        self.enrol()
        first, _ = self.settings({})
        self.enrol(sync=False)
        cleared, note = self.settings(dict(first))
        self.assertEqual(set(cleared), set(first))
        self.assertTrue(all(v == "" for v in cleared.values()))
        self.assertIn("connections only", note)
        self.assertNotIn("not enrolled", note)

    def test_consent_given_later_brings_the_dial_back_whole(self):
        self.enrol(sync=False)
        self.assertEqual(self.settings({}), ({}, None))
        self.enrol(sync=True)
        values, note = self.settings({})
        # Whatever `relay_env` writes — four since main's f47e4a5 added the
        # platform rule beside the dial — comes back whole, not a hand-kept
        # three. The consent rule gates the write; it does not choose the keys.
        self.assertEqual(values, {"GATEWAY_RELAY_URL": "https://edge.example",
                                  "GATEWAY_RELAY_SECRET": self.token,
                                  "GATEWAY_RELAY_AUTH_MODE": "raw",
                                  "GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS": "true"})
        self.assertIsNone(note)

    def test_a_mac_never_claims_to_front_a_channel_over_the_relay(self):
        """Review of reach-owner, finding 1: stamping GATEWAY_RELAY_PLATFORMS on
        the Mac made `deliver: telegram` go to whatever TELEGRAM_HOME_CHANNEL
        said — which a contact's /sethome can move — and changed the hello the
        edge's routing expects. The owner is reached through `moe` ->
        reach_owner -> the edge's own owner record instead. Even with the
        cloud holding a channel, the Mac writes no stamp."""
        self.enrol()
        with open(os.path.join(self.tmp, "cloud", "channel-telegram.json"), "w") as f:
            json.dump({"channel": "telegram", "webhook_url": "/v1/channels/telegram/webhook/h"}, f)
        values, _ = self.settings({})
        self.assertNotIn("GATEWAY_RELAY_PLATFORMS", values)

    def test_a_sync_field_this_build_cannot_read_clears_the_dial_and_says_so(self):
        """Finding 3 of the §18.29j review. `"sync": "yes"` is a file this
        build did not write; Swift's reader would take it as consent. The
        first version RAISED, returned `{}`, and said "the relay is not
        configured" — while the dial sat in `.env` untouched. Now: treated as
        not syncing, the dial cleared exactly as for `sync: false`, and the
        note names the value and says the settings are cleared."""
        self.enrol()
        first, _ = self.settings({})
        self.enrol(sync="yes")
        cleared, note = self.settings(dict(first))
        self.assertEqual(set(cleared), set(first))
        self.assertTrue(all(v == "" for v in cleared.values()))
        self.assertIn("'yes'", note)
        self.assertIn("neither true nor false", note)
        self.assertIn("cleared", note)
        self.assertNotIn("not configured", note)
        # And quiet when there is nothing to clear: it runs on every launch.
        self.assertEqual(self.settings({}), ({}, None))
        # The string "true" is the spelling most likely to be hand-typed as a
        # yes, and it is a no here — Swift's reader would say yes.
        self.enrol(sync="true")
        cleared, note = self.settings(dict(first))
        self.assertTrue(all(v == "" for v in cleared.values()))
        self.assertIn("'true'", note)

    def test_enrolling_writes_the_dial_and_the_platform_rule(self):
        """Four, not three, since 2026-09-07. The fourth keeps the gateway
        running the channels the owner already configured: the fork switches
        every direct platform off when a relay is configured, and Moe's edge
        does not carry Telegram yet, so writing the dial alone silently took
        a working bot off the air. relayconfig owns the reasoning."""
        self.enrol()
        values, note = self.settings({})
        self.assertEqual(values, {"GATEWAY_RELAY_URL": "https://edge.example",
                                  "GATEWAY_RELAY_SECRET": self.token,
                                  "GATEWAY_RELAY_AUTH_MODE": "raw",
                                  "GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS": "true"})
        self.assertIsNone(note)

    def test_de_enrol_then_re_enrol_comes_back_whole(self):
        """The worst of the review's findings. The first version blanked the
        keys on de-enrolment and then, on the NEXT enrolment, read its own
        blanks back as the person's preference — keeping them and writing the
        secret with no URL. A live credential in `.env` doing nothing, for
        ever, while the script reported it was respecting a choice it had
        invented. There was no way out but hand-editing the file."""
        self.enrol()
        first, _ = self.settings({})
        self.de_enrol()
        cleared, note = self.settings(dict(first))
        self.assertEqual(set(cleared), set(first))
        self.assertTrue(all(v == "" for v in cleared.values()))
        self.assertIn("not enrolled", note)
        env_after = dict(first)
        env_after.update(cleared)
        self.enrol()
        again, note = self.settings(env_after)
        self.assertEqual(again, first, "re-enrolment did not restore all three")
        self.assertIsNone(note)

    def test_a_changed_edge_is_followed(self):
        """`cloudEdge` is the control. The first version pinned the relay to
        whatever it wrote first while CloudSync moved to the new edge."""
        self.enrol(edge="https://edge-old.example")
        first, _ = self.settings({})
        self.enrol(edge="https://edge-new.example")
        second, _ = self.settings(dict(first))
        self.assertEqual(second["GATEWAY_RELAY_URL"], "https://edge-new.example")

    def test_an_unenrolled_mac_leaves_a_hand_written_config_alone(self):
        """The majority case — a Mac that never turned Away on — and the first
        version wiped the person's own relay settings on every launch, in a
        function whose docstring promised the opposite. The tell is the SECRET:
        nothing but this writes one."""
        theirs = {"GATEWAY_RELAY_URL": "ws://localhost:9000",
                  "GATEWAY_RELAY_AUTH_MODE": "token"}
        values, note = self.settings(theirs)
        self.assertEqual(values, {})
        self.assertIsNone(note)

    def test_an_unenrolled_mac_clears_a_credential_we_left(self):
        """...but a secret IS ours, and a stale one that still dials is a
        device the edge refuses for ever rather than one that stops asking."""
        self.enrol()
        first, _ = self.settings({})
        self.de_enrol()
        values, note = self.settings(dict(first))
        self.assertEqual(values["GATEWAY_RELAY_SECRET"], "")
        self.assertIn("cleared", note)

    def test_clearing_happens_once_and_not_on_every_launch(self):
        self.enrol()
        first, _ = self.settings({})
        self.de_enrol()
        env = dict(first)
        env.update(self.settings(env)[0])
        self.assertEqual(self.settings(env), ({}, None))

    def test_clearing_touches_only_the_keys_that_are_there(self):
        """Blanking a key that was never in the file ADDS it — `render_env`
        appends what it does not find — so a Mac that de-enrols would gain
        `GATEWAY_RELAY_URL=` and `GATEWAY_RELAY_AUTH_MODE=` lines it never had.
        Cosmetic on its own, and it is also the difference between clearing
        what we wrote and writing something new on the way out."""
        self.enrol()
        values, _ = self.settings({})
        self.de_enrol()
        only_secret = {"GATEWAY_RELAY_SECRET": values["GATEWAY_RELAY_SECRET"]}
        cleared, note = self.settings(only_secret)
        self.assertEqual(set(cleared), {"GATEWAY_RELAY_SECRET"})
        self.assertIn("cleared", note)

    def test_a_credential_that_will_not_parse_is_reported_not_silent(self):
        """'not enrolled yet' is the ordinary state of a fresh install and must
        be quiet; a credential.json that exists and will not parse is a broken
        install. Reading the second as the first drops a device off the relay
        silently and for ever — which is the distinction `credential_token`
        raises for, and it needs a caller that says so."""
        self.enrol()
        with open(os.path.join(self.tmp, "cloud", "credential.json"), "w") as f:
            f.write("{not json")
        values, note = self.settings({})
        self.assertEqual(values, {})
        self.assertIsNotNone(note, "a broken credential.json was silent")
        self.assertIn("not configured", note)

    def test_the_mode_is_never_kept_from_the_env(self):
        """`relayconfig` says in as many words that the mode is not a
        preference: this edge stores only a digest and cannot verify a
        signature, ever. The first version kept it, and the Mac and the machine
        then disagreed about the same key."""
        self.enrol()
        values, _ = self.settings({"GATEWAY_RELAY_AUTH_MODE": "token"})
        self.assertEqual(values["GATEWAY_RELAY_AUTH_MODE"], "raw")

    def test_a_url_in_the_env_does_not_override_cloudEdge(self):
        self.enrol()
        values, _ = self.settings({"GATEWAY_RELAY_URL": "wss://mine.example/relay"})
        self.assertEqual(values["GATEWAY_RELAY_URL"], "https://edge.example")

    def test_no_edge_configured_says_so(self):
        self.enrol(edge=None) if False else None
        with open(os.path.join(self.tmp, "cloud", "credential.json"), "w") as f:
            json.dump({"tenant": "t", "device": "d", "token": self.token}, f)
        values, note = self.settings({})
        self.assertEqual(values, {})
        self.assertIn("does not know where its edge is", note)

    def test_a_cleartext_edge_says_so(self):
        self.enrol(edge="http://edge.example")
        values, note = self.settings({})
        self.assertEqual(values, {})
        self.assertIn("permanent credential", note)

    def test_a_payload_that_will_not_load_is_reported_not_silent(self):
        """`except Exception: return None` made a broken payload
        byte-identical to 'Away was never turned on'. The rule module's
        docstring promises the breakage surfaces as an ImportError about a
        module nobody was thinking about; it surfaced as nothing."""
        self.enrol()
        payload = os.path.join(self.tmp, "hermes-plugins", "moe-ledger", "moeledger")
        os.makedirs(payload)
        with open(os.path.join(payload, "relayconfig.py"), "w") as f:
            f.write("from .identity import unb64\n")   # the exact breakage it warns of
        values, note = self.settings({})
        self.assertEqual(values, {})
        self.assertIsNotNone(note, "a payload that will not load was silent")
        self.assertIn("would not load", note)

    def test_no_payload_at_all_is_silent(self):
        """Absent is not broken. A Moe installed without the payload is
        reported elsewhere, not made noisy here on every launch.

        `moe_payload_dir` is patched rather than relied on: it falls back to
        the checkout's own `moe-home/hermes-plugins` one level up from the
        script, so in a source tree the payload is ALWAYS found and this branch
        is unreachable — which is how the first version of this test asserted
        silence and got all three keys instead.
        """
        self.enrol()
        original = self.script.moe_payload_dir
        self.script.moe_payload_dir = lambda name, moe_home: None
        try:
            self.assertEqual(self.settings({}), ({}, None))
        finally:
            self.script.moe_payload_dir = original

    def test_the_source_tree_fallback_finds_the_payload(self):
        """The other half: a run from a checkout, where `--moe-home` is a
        scratch directory with no payload in it, still finds the rule beside
        the script. That fallback is what makes every test in this class work,
        so it is asserted rather than assumed."""
        self.enrol()
        self.assertIsNotNone(self.script.moe_payload_dir("hermes-plugins", self.tmp))
        values, note = self.settings({})
        self.assertIn("GATEWAY_RELAY_SECRET", values)
        self.assertIsNone(note)


class ChannelHolderRule(unittest.TestCase):
    """One holder per chat app, decided here and applied to `config.yaml`.

    **What went wrong, on the owner's own account, 2026-09-14.** Their cloud
    machine was paired at 01:17Z. `channels.py migrate` gave the edge their
    Telegram app and `setWebhook` pointed the bot at it. This Mac's gateway was
    still polling with `getUpdates`, because
    `GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS=true` was a constant written on every
    dial. Telegram permits a webhook OR polling and never both: the poll came
    back 409, and the fork's adapter "recovered" by calling `deleteWebhook` —
    deleting the EDGE's webhook. The machine they pay for could not receive one
    message after that, and BOTH halves went on reporting themselves connected,
    because each was reading its own config and neither was reading the
    provider.

    So the decision is made from state, in two places that have to agree: the
    blunt permission (`relayconfig.direct_platforms_setting`, tested there) and
    the exact one, `platforms.<name>.enabled`, which is this class.
    """

    @classmethod
    def setUpClass(cls):
        cls.script = _load_script()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-holder-")
        os.makedirs(os.path.join(self.tmp, "cloud"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def hold(self, *channels):
        for channel in channels:
            with open(os.path.join(self.tmp, "cloud",
                                   "channel-%s.json" % channel), "w") as f:
                json.dump({"channel": channel, "webhook_url": "/v1/x"}, f)

    def apply(self, cfg):
        report = self.script.Report()
        moved = self.script.apply_channel_holder(cfg, self.tmp, report)
        return moved, report

    def test_with_no_machine_nothing_is_taken_off_this_mac(self):
        """The free account, which is most of them. No marker means the cloud
        carries nothing, and a script that switched a platform off on that
        evidence would take a working bot away from somebody who never bought
        anything."""
        self.assertEqual(self.script.channels_the_edge_holds(self.tmp), ())
        cfg = {"platforms": {"telegram": {"enabled": True},
                             "slack": {"enabled": True}}}
        moved, report = self.apply(cfg)
        self.assertFalse(moved)
        self.assertTrue(cfg["platforms"]["telegram"]["enabled"])
        self.assertTrue(cfg["platforms"]["slack"]["enabled"])
        self.assertEqual(report.written, [])

    def test_a_channel_the_cloud_holds_is_switched_off_by_name(self):
        """The fix. Slack here rather than Telegram because Telegram's key is
        written by `build_config` itself (both ways); this is the loop that
        covers the other four."""
        self.hold("slack")
        self.assertEqual(self.script.channels_the_edge_holds(self.tmp), ("slack",))
        cfg = {"platforms": {"slack": {"enabled": True}, "discord": {"enabled": True}}}
        moved, report = self.apply(cfg)
        self.assertTrue(moved, "a channel changed hands and nothing said so")
        self.assertIs(cfg["platforms"]["slack"]["enabled"], False)
        self.assertIs(cfg["platforms"]["discord"]["enabled"], True,
                      "a channel the cloud does not hold must be left alone")
        self.assertTrue(any("platforms.slack.enabled" in w for w in report.written))

    def test_a_platform_nobody_enabled_is_left_absent(self):
        """Moe's own one-click Slack app leaves no keys on this Mac at all, so
        there is nothing to take away — and writing `enabled: false` for a
        platform that was never on is a line nobody can explain later."""
        self.hold("slack")
        cfg = {"platforms": {}}
        moved, _ = self.apply(cfg)
        self.assertFalse(moved)
        self.assertNotIn("slack", cfg["platforms"])

    def test_it_does_not_move_a_platform_twice(self):
        """It runs on every launch. A second run must be silent, or Moe
        restarts the gateway every time somebody opens it — five to seven
        seconds of the brain child, for nothing."""
        self.hold("slack")
        cfg = {"platforms": {"slack": {"enabled": True}}}
        self.assertTrue(self.apply(cfg)[0])
        self.assertFalse(self.apply(cfg)[0])

    def test_the_cloud_giving_a_channel_back_is_a_move_too(self):
        """`channels.py forget` removes the marker. Telegram comes back on by
        itself (the `force_set` in `build_config` asks the question rather than
        asserting True), and this is the state that proves the question is
        asked at all rather than only asked once."""
        self.hold("telegram")
        self.assertEqual(self.script.channels_the_edge_holds(self.tmp), ("telegram",))
        os.unlink(os.path.join(self.tmp, "cloud", "channel-telegram.json"))
        self.assertEqual(self.script.channels_the_edge_holds(self.tmp), ())

    def test_a_marker_naming_another_edge_takes_no_channel_away(self):
        """The half of the rule that lives here: `cloudEdge` is what a marker
        has to name, and this is the call site that supplies it.

        Two markers naming `http://127.0.0.1:58220` and `…:57298` were found
        in the owner's own home on 2026-09-14 — fake edges from a test suite
        that had been running without a scratch `MOE_HOME`, on ports nothing
        is listening on. Read as holders they would have switched a working
        Telegram and Slack off on this Mac.
        """
        with open(os.path.join(self.tmp, "config.json"), "w") as f:
            json.dump({"cloudEdge": "https://edge.example"}, f)
        with open(os.path.join(self.tmp, "cloud", "channel-slack.json"), "w") as f:
            json.dump({"channel": "slack",
                       "webhook_url": "http://127.0.0.1:57298/v1/channels/slack/webhook/x"}, f)
        self.assertEqual(self.script.channels_the_edge_holds(self.tmp), ())
        cfg = {"platforms": {"slack": {"enabled": True}}}
        moved, _ = self.apply(cfg)
        self.assertFalse(moved)
        self.assertIs(cfg["platforms"]["slack"]["enabled"], True,
                      "a dead 127.0.0.1 port took somebody's Slack off this Mac")
        # And the real one, written by `channels.py` against this account.
        with open(os.path.join(self.tmp, "cloud", "channel-slack.json"), "w") as f:
            json.dump({"channel": "slack",
                       "webhook_url": "https://edge.example/v1/channels/slack/webhook/x"}, f)
        self.assertEqual(self.script.channels_the_edge_holds(self.tmp), ("slack",))

    def test_the_permission_is_derived_from_the_markers_not_from_the_file(self):
        """`relay_settings` reads `.env` for nothing here. A value a past
        session set by hand — which is how the owner's Mac got into this state
        — is overwritten on the next run, and that is the whole point of
        deriving it."""
        import base64
        hermes = os.path.join(self.tmp, "hermes")
        os.makedirs(hermes)
        with open(os.path.join(hermes, ".env"), "w") as f:
            f.write("TELEGRAM_BOT_TOKEN=1:x\n")
        with open(os.path.join(self.tmp, "cloud", "credential.json"), "w") as f:
            json.dump({"tenant": "t", "device": "d",
                       "token": base64.b64encode(b"\x33" * 32).decode()}, f)
        with open(os.path.join(self.tmp, "config.json"), "w") as f:
            json.dump({"cloudEdge": "https://edge.example"}, f)
        was = {"GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS": "true"}
        values, note = self.script.relay_settings(self.tmp, was, hermes)
        self.assertIsNone(note)
        self.assertEqual(values["GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS"], "true",
                         "no marker: this Mac still holds Telegram")
        self.hold("telegram")
        values, _ = self.script.relay_settings(self.tmp, was, hermes)
        self.assertEqual(values["GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS"], "false",
                         "the cloud holds the only chat app this Mac had, and "
                         "the Mac must stop taking it")


class MoeEmailIsNotTheImapEmailPlatform(unittest.TestCase):
    """Slice G3. Moe's email address rides the edge as the channel `moemail`,
    and Hermes has a platform literally named `email` -- the person's OWN
    mailbox, over IMAP. The holder rule writes `platforms.<name>.enabled:
    false` for every channel the edge holds, so an edge channel called `email`
    would one day switch somebody's own mailbox off. Proved here by doing the
    damage the other way: markers under BOTH names, the person's email
    platform on, and the rule run."""

    @classmethod
    def setUpClass(cls):
        cls.script = _load_script()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-moemail-")
        os.makedirs(os.path.join(self.tmp, "cloud"))
        with open(os.path.join(self.tmp, "config.json"), "w") as f:
            json.dump({"cloudEdge": "https://edge.example"}, f)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_holder_rule_never_switches_off_the_persons_own_email(self):
        for name in ("moemail", "email"):
            with open(os.path.join(self.tmp, "cloud", "channel-%s.json" % name), "w") as f:
                json.dump({"app": "moe", "channel": name, "available": True,
                           "address": "sam@in.moebot.app",
                           "webhook_url": "/v1/channels/%s/resend" % name}, f)
        # The positive control: a channel the edge DOES hold, in the same run,
        # is switched off -- so the rule loaded and ran, and the email result
        # below is its answer rather than the silence of a rule that never
        # loaded (which also leaves `platforms.email` on).
        with open(os.path.join(self.tmp, "cloud", "channel-slack.json"), "w") as f:
            json.dump({"channel": "slack", "webhook_url": "/v1/channels/slack/socket"}, f)
        self.assertEqual(self.script.channels_the_edge_holds(self.tmp), ("slack",))
        cfg = {"platforms": {"email": {"enabled": True}, "slack": {"enabled": True}}}
        report = self.script.Report()
        moved = self.script.apply_channel_holder(cfg, self.tmp, report)
        self.assertTrue(moved)
        self.assertIs(cfg["platforms"]["slack"]["enabled"], False)
        self.assertIs(cfg["platforms"]["email"]["enabled"], True,
                      "a marker switched the person's own IMAP email off")
        self.assertNotIn("moemail", cfg["platforms"])

    def test_neither_name_is_a_chat_channel_the_edge_can_hold(self):
        rule = self.script.load_relay_rule(self.tmp) or _relay_rule_from_repo()
        self.assertNotIn("email", rule.CHAT_CHANNELS)
        self.assertNotIn("moemail", rule.CHAT_CHANNELS)


def _relay_rule_from_repo():
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "..", "hermes-plugins", "moe-ledger", "moeledger",
                        "relayconfig.py")
    spec = importlib.util.spec_from_file_location("relayconfig_for_moemail", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RelayRestartTrigger(unittest.TestCase):
    """`relay_state`, `relay_problems` and the marker — CLOUD-PLAN 4a.2.

    The finding these close: the gateway loads `.env` into its environment
    once, at boot, and `register_relay_adapter()` runs once, at startup. So a
    relay dial written while the gateway is up reaches **nothing**, and the
    gateway is always up when somebody enrols in Settings > Away. Writing the
    file was 4a.1; telling Moe the file moved, so it restarts the gateway, is
    this.

    Fast, like `RelaySettingsRule` and for the same reason: the end-to-end
    class costs ~35s a case and the states that matter are combinations.
    """

    @classmethod
    def setUpClass(cls):
        cls.script = _load_script()
        import base64
        cls.token = base64.b64encode(b"\x44" * 32).decode()

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-relay-trigger-")
        os.makedirs(os.path.join(self.tmp, "cloud"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def enrol(self, edge="https://edge.example", sync=None):
        body = {"tenant": "t", "device": "d", "token": self.token}
        if sync is not None:
            body["sync"] = sync
        with open(os.path.join(self.tmp, "cloud", "credential.json"), "w") as f:
            json.dump(body, f)
        if edge is not None:
            with open(os.path.join(self.tmp, "config.json"), "w") as f:
                json.dump({"cloudEdge": edge}, f)

    def dialled(self, edge="https://edge.example"):
        """A `.env` for a Mac whose gateway is correctly dialling `edge`."""
        return {"GATEWAY_RELAY_URL": edge,
                "GATEWAY_RELAY_SECRET": self.token,
                "GATEWAY_RELAY_AUTH_MODE": "raw"}

    # -- consent (§18.29j) ---------------------------------------------------

    def test_state_tells_enrolled_from_syncing(self):
        """Two facts, so `--show` can say why an enrolled Mac has no dial."""
        self.enrol(sync=False)
        state = self.script.relay_state(self.tmp, {})
        self.assertIs(state["enrolled"], True)
        self.assertIs(state["syncing"], False)
        self.enrol()
        self.assertIs(self.script.relay_state(self.tmp, {})["syncing"], True)

    def test_a_connections_only_mac_with_no_dial_is_not_a_problem(self):
        """The rule working is reported as a fact, never as a problem: a
        `--check` line that fires on every connections-only Mac, every launch,
        about something they cannot fix is a warning people learn to skip."""
        self.enrol(sync=False)
        self.assertEqual(self.script.relay_problems(self.tmp, {}), [])

    def test_a_connections_only_mac_still_dialling_is_a_problem(self):
        """A gateway serving turns this Mac never agreed to — the one thing
        worth saying, and it names the fact rather than "not enrolled"."""
        self.enrol(sync=False)
        problems = self.script.relay_problems(self.tmp, self.dialled())
        self.assertEqual(len(problems), 1)
        self.assertIn("connections only", problems[0])
        self.assertIn("relay secret", problems[0])

    def test_a_sync_field_this_build_cannot_read_is_not_syncing_and_is_named(self):
        """Enrolled: yes (the token is fine). Syncing: no (the only reading of
        `"yes"` that cannot relay somebody's conversations). And a problem
        line that names the value — a file this build did not write is one to
        look at — with the leftover-secret clause only when there is one."""
        self.enrol(sync="yes")
        state = self.script.relay_state(self.tmp, {})
        self.assertIs(state["enrolled"], True)
        self.assertIs(state["syncing"], False)
        self.assertIn("'yes'", state["sync_problem"])
        problems = self.script.relay_problems(self.tmp, {})
        self.assertEqual(len(problems), 1)
        self.assertIn("neither true nor false", problems[0])
        self.assertNotIn("relay secret", problems[0])
        problems = self.script.relay_problems(self.tmp, self.dialled())
        self.assertEqual(len(problems), 1)
        self.assertIn("neither true nor false", problems[0])
        self.assertIn("relay secret", problems[0])

    # -- the marker ---------------------------------------------------------

    def test_the_marker_is_the_same_string_on_both_sides(self):
        """A pin, and it is a pin rather than a measurement — say so.

        §18.29d-review's worst test was `assert '"raw"' in <source>`, which the
        fork satisfied with EITHER value because both literals sit on one line.
        So this asserts the whole assignment line, not that the string appears
        somewhere: changing either side's value breaks it, and changing both
        together is the only edit that should pass.

        What it cannot catch is Moe parsing it wrongly, which is why
        `scripts/test-hermes-supervisor.sh` restarts a real gateway off a real
        marker rather than trusting this.
        """
        swift = os.path.join(HERE, "..", "..", "..",
                             "Sources", "Moe", "Brain", "HermesSupervisor.swift")
        self.assertTrue(os.path.isfile(swift), "%s is not there any more; this pin is "
                                               "asserting nothing" % swift)
        with open(swift, encoding="utf-8") as fh:
            lines = [line.rstrip() for line in fh]
        want = '    static let relayChangedMarker = "%s"' % self.script.RELAY_CHANGED_MARKER
        self.assertIn(want, lines)

    def test_the_marker_is_one_line_and_carries_nothing(self):
        """Moe matches it as a WHOLE line. A marker with a value in it would
        make that impossible and would put the value in Moe's log."""
        self.assertEqual(self.script.RELAY_CHANGED_MARKER.splitlines(),
                         [self.script.RELAY_CHANGED_MARKER])
        self.assertNotIn("=", self.script.RELAY_CHANGED_MARKER)

    # -- relay_state --------------------------------------------------------

    def test_state_reports_the_secret_as_a_word_and_never_as_itself(self):
        """This feeds `--show`'s JSON, which is a thing people paste."""
        self.enrol()
        state = self.script.relay_state(self.tmp, self.dialled())
        self.assertEqual(state["secret"], "present")
        self.assertNotIn(self.token, json.dumps(state))

    def test_state_says_absent_when_there_is_no_secret(self):
        self.enrol()
        state = self.script.relay_state(self.tmp, {})
        self.assertEqual(state["secret"], "absent")

    def test_state_with_no_payload_says_so_rather_than_guessing(self):
        """`load_relay_rule` is stubbed rather than the payload hidden: in a
        checkout the loader falls back to the tree beside the script, so there
        is no directory layout that reaches this branch — and a test that
        cannot reach the branch it names is §17.2 with extra steps."""
        real = self.script.load_relay_rule
        self.script.load_relay_rule = lambda _home: None
        try:
            state = self.script.relay_state(self.tmp, {})
            self.assertIs(state["rule"], False)
            # A payload that is PRESENT but will not load is NOT "Away was
            # never turned on", and this is where the two are told apart.
            # Running from the checkout, the payload is always found — so the
            # rule failing to load here is the unreadable case, and it must be
            # reported rather than pass quietly.
            self.assertIs(state["unreadable"], True)
            problems = self.script.relay_problems(self.tmp, self.dialled())
            self.assertEqual(len(problems), 1)
            self.assertIn("would not load", problems[0])
        finally:
            self.script.load_relay_rule = real

    def test_no_payload_at_all_stays_quiet(self):
        """The other half, and the one that must NOT fire: a Mac with no Moe
        payload has nothing to say about a relay. Both halves, because
        reporting always and reporting never are the same bug twice."""
        real_rule = self.script.load_relay_rule
        real_payload = self.script.moe_payload_dir
        self.script.load_relay_rule = lambda _home: None
        self.script.moe_payload_dir = lambda _name, _home: None
        try:
            state = self.script.relay_state(self.tmp, {})
            self.assertIs(state["unreadable"], False)
            self.assertEqual(self.script.relay_problems(self.tmp, self.dialled()), [])
        finally:
            self.script.load_relay_rule = real_rule
            self.script.moe_payload_dir = real_payload

    def test_an_unreadable_credential_is_not_reported_as_not_enrolled(self):
        """"Cannot tell" and "no" are the two answers this must never merge:
        one is a broken install, the other is a Mac that never turned Away on,
        and clearing the dial is right for exactly one of them."""
        with open(os.path.join(self.tmp, "cloud", "credential.json"), "w") as f:
            f.write("{not json")
        state = self.script.relay_state(self.tmp, {})
        self.assertIsNone(state["enrolled"])

    # -- relay_problems -----------------------------------------------------

    def test_enrolled_with_no_dial_is_a_problem(self):
        """The exact state a Mac sat in between enrolling and its next launch.
        Before 4a.2 nothing anywhere could see it: the gateway simply never
        dialled, and silence is what a working relay looks like too."""
        self.enrol()
        problems = self.script.relay_problems(self.tmp, {})
        self.assertEqual(len(problems), 1)
        self.assertIn("will not dial", problems[0])

    def test_enrolled_and_dialling_is_no_problem(self):
        """The other half of the one above. A check that only ever fires is
        the §17.2 shape read backwards, and just as useless."""
        self.enrol()
        self.assertEqual(self.script.relay_problems(self.tmp, self.dialled()), [])

    def test_a_dial_left_pointing_at_the_old_edge_is_a_problem(self):
        """§18.29d-review's second defect: `CloudSync` moved to the new edge
        and the relay stayed on the old one, holding a credential the old edge
        still honoured — so nothing anywhere reported an error."""
        self.enrol(edge="https://new.example")
        problems = self.script.relay_problems(self.tmp, self.dialled("https://old.example"))
        self.assertEqual(len(problems), 1)
        self.assertIn("wrong place", problems[0])

    def test_a_dial_left_in_the_forks_default_mode_is_a_problem(self):
        """The mode is not a preference: this edge stores only a digest of the
        secret and can never verify a signature. A gateway left on `token`
        sends a signed upgrade nothing can check, and the refusal is an HTTP
        status with no explanation."""
        self.enrol()
        env = self.dialled()
        env["GATEWAY_RELAY_AUTH_MODE"] = "token"
        problems = self.script.relay_problems(self.tmp, env)
        self.assertEqual(len(problems), 1)
        self.assertIn("wrong place", problems[0])

    def test_an_edge_the_relay_refuses_is_reported_not_swallowed(self):
        """§18.29e-review's worst finding. This returned `[]` on the reasoning
        that "the run that tried to write it already reported this" — false for
        `--check`, which never runs the writer and so never says it at all. An
        enrolled Mac whose `cloudEdge` is cleartext reported **ok** with a live
        dial still pointing at the old edge."""
        self.enrol(edge="http://new.example")
        problems = self.script.relay_problems(self.tmp, self.dialled("https://old.example"))
        self.assertEqual(len(problems), 1)
        self.assertIn("refuses", problems[0])

    def test_an_unparseable_edge_is_reported_too(self):
        """The likeliest typo of the lot: a forgotten `https://`."""
        self.enrol(edge="not a url")
        problems = self.script.relay_problems(self.tmp, self.dialled("https://old.example"))
        self.assertEqual(len(problems), 1)
        self.assertIn("refuses", problems[0])

    def test_a_dial_holding_a_previous_enrolments_secret_is_a_problem(self):
        """The secret is the only field that authenticates, and the check
        deliberately never *holds* it — but it does not need to print a value
        to know it is the wrong one. A current URL with a stale secret is
        refused by the edge with nothing here to say why."""
        import base64
        self.enrol()
        env = self.dialled()
        env["GATEWAY_RELAY_SECRET"] = base64.b64encode(b"\x99" * 32).decode()
        problems = self.script.relay_problems(self.tmp, env)
        self.assertEqual(len(problems), 1)
        self.assertIn("secret", problems[0])
        # And it still does not disclose either value.
        self.assertNotIn(self.token, problems[0])
        self.assertNotIn(env["GATEWAY_RELAY_SECRET"], problems[0])

    def test_a_rule_that_stops_loading_mid_check_reports_rather_than_crashes(self):
        """`relay_state` guards `rule is None`; the second load did not, and
        `except ValueError` does not catch the `AttributeError` that follows —
        so `--check` produced a traceback instead of a report. The transient
        that does it is the one this file already knows about."""
        real = self.script.load_relay_rule
        calls = []

        def once(home):
            calls.append(home)
            return real(home) if len(calls) == 1 else None

        self.script.load_relay_rule = once
        try:
            self.enrol()
            problems = self.script.relay_problems(self.tmp, self.dialled())
        finally:
            self.script.load_relay_rule = real
        self.assertEqual(len(problems), 1)
        self.assertIn("stopped loading", problems[0])

    def test_a_leftover_secret_on_an_unenrolled_mac_is_a_problem(self):
        """A stale secret that still dials is a device the edge has to refuse
        for ever instead of one that stops asking."""
        problems = self.script.relay_problems(self.tmp, self.dialled())
        self.assertEqual(len(problems), 1)
        self.assertIn("not enrolled", problems[0])

    def test_an_unenrolled_mac_with_nothing_set_is_quiet(self):
        """The majority case — Away was never turned on — on every `--check`."""
        self.assertEqual(self.script.relay_problems(self.tmp, {}), [])

    def test_an_enrolled_mac_with_no_edge_is_told_which_thing_is_missing(self):
        self.enrol(edge=None)
        problems = self.script.relay_problems(self.tmp, {})
        self.assertEqual(len(problems), 1)
        self.assertIn("no cloudEdge", problems[0])


class RelayDialSettings(ConfigureFixture):
    """The three keys that make this Mac's gateway dial the edge (§18.29d).

    The RULE lives in `moeledger/relayconfig.py` and is tested there; what these
    pin is the half that only exists here — that the script finds it, feeds it
    this Mac's own credential and edge, and lets the person's own value win.

    `run_script` returns `(returncode, output)` with stderr folded into stdout,
    so there is one stream to assert against and no way to check the wrong one.
    """

    def _enrol(self, token=None, edge="https://edge.example", sync=None):
        import base64
        cloud = os.path.join(self.moe_home, "cloud")
        os.makedirs(cloud, exist_ok=True)
        token = token or base64.b64encode(b"\x11" * 32).decode()
        body = {"tenant": "t", "device": "d", "token": token}
        if sync is not None:
            body["sync"] = sync
        with open(os.path.join(cloud, "credential.json"), "w") as f:
            json.dump(body, f)
        if edge is not None:
            with open(os.path.join(self.moe_home, "config.json"), "w") as f:
                json.dump({"cloudEdge": edge}, f)
        return token

    def marker(self):
        """The script's own constant, never a copy of it here: a second
        spelling of a shared string is a thing that drifts silently, which is
        the whole reason `relayconfig` exists."""
        return _load_script().RELAY_CHANGED_MARKER

    def _env(self):
        if not os.path.exists(self.env_path):
            return {}
        with open(self.env_path, encoding="utf-8") as f:
            body = f.read()
        return dict(
            line.split("=", 1) for line in body.splitlines()
            if "=" in line and not line.strip().startswith("#"))

    def test_a_channel_the_cloud_holds_is_off_in_the_config_the_gateway_reads(self):
        """End to end, because the two halves of this only matter together.

        A Mac with a Telegram token and a cloud that has taken the bot over:
        `config.yaml` must come out with `platforms.telegram.enabled: false`,
        `.env` with the permission derived to `false`, and the restart marker
        printed — the gateway reads both files once, at start, so a run that
        changes them without asking for a restart leaves the Mac polling a bot
        the edge already holds. That is the state that produced a 409 on every
        poll and an adapter that deleted the edge's webhook to recover.

        One run, three assertions: each run of the script costs ~35 seconds.
        """
        self._enrol()
        cloud = os.path.join(self.moe_home, "cloud")
        with open(os.path.join(cloud, "channel-telegram.json"), "w") as f:
            json.dump({"channel": "telegram", "webhook_url": "/v1/x"}, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        cfg = self.cfg()
        self.assertIs(cfg["platforms"]["telegram"]["enabled"], False,
                      "the Mac would still start the Telegram adapter, and the "
                      "adapter is what deletes the edge's webhook")
        self.assertEqual(self._env()["GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS"], "false")
        self.assertIn(self.marker(), out,
                      "nothing asked Moe to restart the gateway, so the running "
                      "one keeps polling until somebody quits and reopens Moe")

    def test_a_holder_change_alone_still_asks_for_a_restart(self):
        """The case the `.env` half cannot cover, and the reason the marker
        asks two questions rather than one.

        A person with Telegram in the cloud and a WhatsApp device linked to
        this Mac keeps `GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS=true` — "false"
        would take the WhatsApp away too, and the QR session is bound to this
        hardware and can never move. So NO relay key changes on the run that
        takes Telegram off this Mac, and the only record of it is
        `platforms.telegram.enabled`. If the marker asked only about `.env`,
        the running gateway would go on polling a bot the edge already holds
        until somebody quit and reopened Moe — which is precisely the window
        the 409s and the deleted webhook happened in.

        Two runs, because the second is what makes the first mean anything.
        """
        self._enrol()
        session = os.path.join(self.hermes_home, "whatsapp", "session")
        os.makedirs(session, exist_ok=True)
        with open(os.path.join(session, "creds.json"), "w") as f:
            f.write("{}")
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self._env()["GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS"], "true")
        self.assertIs(self.cfg()["platforms"]["telegram"]["enabled"], True)

        with open(os.path.join(self.moe_home, "cloud", "channel-telegram.json"), "w") as f:
            json.dump({"channel": "telegram", "webhook_url": "/v1/x"}, f)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertEqual(self._env()["GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS"], "true",
                         "the blunt permission must not take the linked WhatsApp away")
        self.assertIs(self.cfg()["platforms"]["telegram"]["enabled"], False,
                      "the channel the cloud holds is the only one switched off")
        self.assertIn(self.marker(), out,
                      "no relay key moved, so nothing asked Moe to restart the "
                      "gateway — and the Mac keeps polling a bot the edge holds")

    def test_an_unenrolled_mac_gets_no_relay_settings(self):
        """The common case — Away was never turned on — and it must be silent."""
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        env = self._env()
        for key in ("GATEWAY_RELAY_URL", "GATEWAY_RELAY_SECRET", "GATEWAY_RELAY_AUTH_MODE"):
            self.assertNotIn(key, env)
        self.assertNotIn("relay", out.lower())

    def test_an_enrolled_mac_gets_all_three_and_never_prints_the_secret(self):
        """Two assertions in one run because each run of the script costs ~35
        seconds: the keys land, and the credential is not in the output. They
        are checked together rather than in two runs of the same setup."""
        token = self._enrol()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        env = self._env()
        self.assertEqual(env["GATEWAY_RELAY_URL"], "https://edge.example")
        self.assertEqual(env["GATEWAY_RELAY_AUTH_MODE"], "raw")
        # The secret is `credential.json`'s token verbatim — already
        # base64(secret), the same bytes this device presents on every other
        # edge route. Nothing derived, nothing minted (§18.25 rule 6).
        self.assertEqual(env["GATEWAY_RELAY_SECRET"], token)
        self.assertNotIn(token, out)

    def test_the_marker_is_printed_when_the_dial_moves_and_not_when_it_does_not(self):
        """CLOUD-PLAN 4a.2. Two runs in one test because each costs ~35s, and
        because the SECOND is what makes the first mean anything.

        Moe restarts the Hermes gateway when it sees this line, and a restart
        costs the brain child five to seven seconds. An implementation that
        printed it whenever a relay key was merely *set* would pass the first
        assertion and stall every launch of every enrolled Mac; the second
        assertion is the one that fails on it.
        """
        self._enrol()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn(self.marker(), out.splitlines())

        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertNotIn(self.marker(), out.splitlines())
        # And the settings are still there — "nothing changed" must not be
        # reached by writing nothing.
        self.assertEqual(self._env()["GATEWAY_RELAY_URL"], "https://edge.example")

    def test_de_enrolling_prints_the_marker_too(self):
        """Leaving is a dial change as much as joining is, and it is the one
        that matters more: until the gateway is restarted it keeps dialling
        with a credential the person has revoked."""
        self._enrol()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        os.unlink(os.path.join(self.moe_home, "cloud", "credential.json"))
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertIn(self.marker(), out.splitlines())

    def test_check_and_show_can_both_see_the_relay(self):
        """§18.29d-review left this open in as many words: both commands
        returned before the relay block, so the two ways of asking "what is
        this Mac set to" could not answer it about the thing 4a added."""
        self._enrol()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)

        code, out = self.run_script("--show")
        self.assertEqual(code, 0, out)
        shown = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(shown["relay"]["url"], "https://edge.example")
        self.assertEqual(shown["relay"]["mode"], "raw")
        self.assertEqual(shown["relay"]["secret"], "present")
        self.assertIs(shown["relay"]["enrolled"], True)
        # --show's JSON is a thing people paste.
        self.assertNotIn(self._env()["GATEWAY_RELAY_SECRET"], out)

        # Now break it the way a Mac between enrolling and its next launch is
        # broken, and require --check to say so.
        self.write_env({"GATEWAY_RELAY_URL": "", "GATEWAY_RELAY_SECRET": "",
                        "GATEWAY_RELAY_AUTH_MODE": ""})
        code, out = self.run_script("--check")
        # The state, in the failure message. This test failed once inside the
        # full suite and passed alone, and "0 != 1" said nothing about why —
        # which is an hour of bisecting a run that takes seven minutes.
        state = _load_script().relay_state(self.moe_home, self._env())
        self.assertEqual(code, 1, "--check did not report the blanked dial.\n"
                                  "state=%r\ncredential=%s\n%s"
                         % (state,
                            os.path.exists(os.path.join(self.moe_home, "cloud",
                                                        "credential.json")),
                            out))
        self.assertIn("will not dial", out)

    def _identity(self):
        """The device identity enrolment leaves in the vault, so the two
        sealing settings have something real to name."""
        import base64
        path = os.path.join(self.moe_home, "cloud", "device-identity.json")
        with open(path, "w") as f:
            json.dump({"device": "d",
                       "agreement_private": base64.b64encode(bytes(range(32))).decode(),
                       "agreement_public": base64.b64encode(bytes(range(32, 64))).decode()}, f)
        return path

    def test_the_sealing_settings_reach_the_env_the_gateway_reads(self):
        """§18.29h: without these two in `.env` the fork's opener is dead code.
        Asserted against the FILE, not against the function that computes them."""
        self._enrol()
        identity = self._identity()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        env = self._env()
        self.assertEqual(env.get("GATEWAY_RELAY_INBOUND_KEYS"), identity)
        opener = env.get("GATEWAY_RELAY_INBOUND_OPENER", "")
        self.assertTrue(opener.endswith("inbound.py"), opener)
        self.assertTrue(os.path.isfile(opener),
                        "the .env names an opener that is not there: %r" % opener)

    def test_an_enrolled_mac_with_no_identity_file_names_no_opener(self):
        """Absence beats a name that resolves to nothing. A device with a
        credential but no identity yet must write NEITHER key rather than a
        path to a file it does not have."""
        self._enrol()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        env = self._env()
        self.assertNotIn("GATEWAY_RELAY_INBOUND_KEYS", env)
        self.assertNotIn("GATEWAY_RELAY_INBOUND_OPENER", env)
        self.assertEqual(
            _load_script().relay_state(self.moe_home, env)["sealing"], "off")

    def test_sealing_is_reported_on_once_it_really_is(self):
        self._enrol()
        self._identity()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        code, out = self.run_script("--show")
        self.assertEqual(code, 0, out)
        shown = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(shown["relay"]["sealing"], "on")

    def test_a_sealing_path_that_resolves_to_nothing_is_a_check_failure(self):
        """The well-formed identifier that names a file which is gone. NOT the
        same finding as `sealing: off`, which is the ordinary state — this is
        the input that used to end the fork's socket reader outright, so
        `--check` has to see it."""
        self._enrol()
        identity = self._identity()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        os.unlink(identity)
        code, out = self.run_script("--check")
        self.assertEqual(code, 1, "--check passed with .env naming a missing "
                                  "identity file.\n%s" % out)
        self.assertIn("the file is not there", out)

    def test_a_cleartext_edge_is_refused_and_nothing_is_written(self):
        """In raw mode the bearer is the secret and does not expire, so a
        cleartext dial leaks a permanent credential."""
        self._enrol(edge="http://edge.example")
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertNotIn("GATEWAY_RELAY_SECRET", self._env())
        self.assertIn("permanent credential", out)

    def test_an_enrolled_mac_with_no_edge_configured_says_so(self):
        self._enrol(edge=None)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertNotIn("GATEWAY_RELAY_SECRET", self._env())
        self.assertIn("does not know where its edge is", out)

    def test_un_enrolling_clears_the_settings(self):
        """A stale secret that still dials is a device the edge has to refuse
        for ever, instead of one that stops asking."""
        self._enrol()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertTrue(self._env()["GATEWAY_RELAY_SECRET"])
        os.unlink(os.path.join(self.moe_home, "cloud", "credential.json"))
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        env = self._env()
        # Blanked, not deleted: render_env replaces in place and has no remove.
        # A blank IS absent to the fork — `relay_url()` and
        # `relay_connection_auth()` both strip and test truthiness — so the
        # relay does not register, which is the outcome wanted.
        self.assertEqual(env.get("GATEWAY_RELAY_SECRET", ""), "")
        self.assertEqual(env.get("GATEWAY_RELAY_URL", ""), "")

    def test_the_env_does_not_override_cloudEdge(self):
        """These three keys are owned outright. An earlier version let a
        hand-edited value win, compared it against what it was about to write,
        and — having no record of what it had written itself — treated its own
        output as the person's preference. `RelaySettingsRule` covers the
        states; this is the one end-to-end pass that proves the whole script
        behaves that way and not just the function."""
        self._enrol()
        os.makedirs(self.hermes_home, exist_ok=True)
        with open(self.env_path, "w") as f:
            f.write("GATEWAY_RELAY_URL=wss://mine.example/relay\n")
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        env = self._env()
        self.assertEqual(env["GATEWAY_RELAY_URL"], "https://edge.example")
        self.assertNotIn("kept your own", out)
        self.assertTrue(env["GATEWAY_RELAY_SECRET"])

    def test_a_connections_only_mac_never_dials_and_show_says_why(self):
        """§18.29j end to end, against the file the gateway reads. An Away Mac
        withdraws consent (the credential is still there, `sync` is now false):
        the dial is cleared, the marker fires so the running gateway is
        restarted and stops dialling, `--show` reports the fact, and
        `relay_problems` on the resulting file has nothing to say — because a
        connections-only Mac with no dial is the rule working."""
        self._enrol()
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        self.assertTrue(self._env()["GATEWAY_RELAY_SECRET"])

        self._enrol(sync=False)
        code, out = self.run_script()
        self.assertEqual(code, 0, out)
        env = self._env()
        self.assertEqual(env.get("GATEWAY_RELAY_SECRET", ""), "")
        self.assertEqual(env.get("GATEWAY_RELAY_URL", ""), "")
        self.assertIn(self.marker(), out, "the gateway would keep dialling until its next launch")
        self.assertIn("connections only", out)

        code, out = self.run_script("--show")
        self.assertEqual(code, 0, out)
        shown = json.loads(out.strip().splitlines()[-1])
        self.assertIs(shown["relay"]["enrolled"], True)
        self.assertIs(shown["relay"]["syncing"], False)
        self.assertEqual(shown["relay"]["secret"], "absent")
        self.assertEqual(_load_script().relay_problems(self.moe_home, self._env()), [],
                         "a connections-only Mac with no dial was reported as a problem")

    def test_a_rerun_changes_nothing(self):
        self._enrol()
        self.run_script()
        with open(self.env_path, encoding="utf-8") as f:
            first = f.read()
        self.run_script()
        with open(self.env_path, encoding="utf-8") as f:
            self.assertEqual(first, f.read())


class ChromeExtensionLane(ConfigureFixture):
    """Connections › Chrome: the three calls the app makes. The status half
    runs the pinned Hermes's own `tools.browser_chrome_extension status`
    (the venv's checkout — HERMES_HOME is the scratch dir, so the bridge file
    it reads is the one written here), not a stand-in for it."""

    MANIFEST = os.path.join("Library", "Application Support", "Google", "Chrome",
                            "NativeMessagingHosts", "app.memoe.chrome_bridge.json")

    def setUp(self):
        super().setUp()
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.agent = configure.hermes_agent_dir(self.hermes_home)
        if not configure.chrome_extension_source(self.agent):
            self.skipTest("this venv's Hermes has no extensions/chrome")

    def status(self):
        rc, out = self.run_script("--chrome-extension-status")
        self.assertEqual(rc, 0, out)
        return json.loads(out.strip().splitlines()[-1])

    def flag(self):
        return (((self.cfg().get("browser") or {}).get("chrome_extension") or {}).get("enabled"))

    def write_bridge(self, file_access):
        d = os.path.join(self.hermes_home, "chrome-bridge")
        os.makedirs(d, exist_ok=True)
        os.chmod(d, 0o700)
        path = os.path.join(d, "bridge.json")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            # The shape the relay writes (browser_chrome_bridge._serve_socket);
            # this process stands in for its pid, which the reader requires alive.
            json.dump({"protocol": 1, "ws_url": "ws://127.0.0.1:1/devtools/browser/t", "pid": os.getpid(),
                       "extension_origin": "chrome-extension://ljblhmlmgflmbffbfelamefleikodmjh",
                       "extension": {"extensionId": "ljblhmlmgflmbffbfelamefleikodmjh",
                                     "fileAccess": file_access, "version": "0.2.1"}}, f)

    def test_the_flag_is_written_by_set_and_survives_a_full_run(self):
        self.assertIsNone(self.flag(), "a fresh install never turns the lane on by itself")
        rc, out = self.run_script("--set-chrome-extension", "on")
        self.assertEqual(rc, 0, out)
        self.assertIs(self.flag(), True)
        rc, out = self.run_script()
        self.assertEqual(rc, 0, out)
        self.assertIs(self.flag(), True, "a re-run of configure keeps the person's switch")
        rc, out = self.run_script("--set-chrome-extension", "off")
        self.assertEqual(rc, 0, out)
        self.assertIs(self.flag(), False)
        before = self.read(self.cfg_path)
        rc, out = self.run_script("--set-chrome-extension", "yes")
        self.assertNotEqual(rc, 0)
        self.assertEqual(self.read(self.cfg_path), before, "a bad value writes nothing")

    def test_status_walks_not_installed_then_waiting_then_connected(self):
        s = self.status()
        self.assertEqual((s["host_installed"], s["enabled"], s["connected"]), (False, False, False))
        dest = os.path.join(self.moe_home, "chrome-extension")
        rc, out = self.run_script("--install-chrome-extension", dest)
        self.assertEqual(rc, 0, out)
        # Staged: a copy of the pinned extension, with the key that fixes its id.
        with open(os.path.join(dest, "manifest.json")) as f:
            staged = json.load(f)
        with open(os.path.join(configure.chrome_extension_source(self.agent), "manifest.json")) as f:
            self.assertEqual(staged, json.load(f))
        self.assertIn("key", staged)
        # The host: in the scratch HOME's Chrome dir, allowing only our id,
        # pointing at a launcher in the scratch Hermes home.
        with open(os.path.join(self.tmp, self.MANIFEST)) as f:
            host = json.load(f)
        # Both ids since the fork's b62f5983d6: the Chrome Web Store build first, the unpacked dev id
        # (the key this staged copy carries) beside it (tools/browser_chrome_extension.EXTENSION_IDS).
        self.assertEqual(host["allowed_origins"], ["chrome-extension://nmdhnfjfpipnjbfbiligpbdnpfdkojjn/",
                                                   "chrome-extension://ljblhmlmgflmbffbfelamefleikodmjh/"])
        self.assertTrue(host["path"].startswith(self.hermes_home), host["path"])
        # Installed again over itself: still one folder, nothing left beside it.
        rc, out = self.run_script("--install-chrome-extension", dest)
        self.assertEqual(rc, 0, out)
        self.assertEqual(sorted(os.listdir(self.moe_home)).count("chrome-extension"), 1)
        self.assertFalse([n for n in os.listdir(self.moe_home) if n.startswith(".chrome-extension-")])

        s = self.status()
        self.assertEqual((s["host_installed"], s["connected"]), (True, False))
        self.run_script("--set-chrome-extension", "on")
        self.write_bridge(file_access=True)
        s = self.status()
        self.assertEqual((s["host_installed"], s["enabled"], s["connected"]), (True, True, True))
        self.assertEqual([w["code"] for w in s["warnings"]], ["file_access_on"])
        self.write_bridge(file_access=False)
        self.assertEqual(self.status()["warnings"], [])

    def test_status_never_writes(self):
        before = self.read(self.cfg_path)
        self.status()
        self.assertEqual(self.read(self.cfg_path), before)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, self.MANIFEST)))


class BrowseAsRule(unittest.TestCase):
    """Settings › Permissions › "Browse as" → `browser.real_profile_pin`
    (ticket #5: with seven Chrome profiles, Hermes copied whichever was
    used last, and a daily X job found the copy signed out)."""

    PROFILES = {"browser": "chrome", "last_used": "Profile 4", "snapshot": "Profile 4",
                "profiles": [{"dir": "Default", "name": "Jordy", "account": "s@x.com"},
                             {"dir": "Profile 4", "name": "Pulse", "account": ""}]}

    def setUp(self):
        self.mod = _load_script()
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.moe_home = os.path.join(self.tmp, "moe")
        os.makedirs(self.moe_home)
        self.mod.browser_profiles = lambda hermes_home, browser: dict(self.PROFILES) if browser else None

    def choose(self, value):
        with open(os.path.join(self.moe_home, "config.json"), "w") as f:
            json.dump({} if value is None else {"browseAsProfile": value}, f)

    def run_it(self, cfg, chromium="chrome", wanted=None):
        report = self.mod.Report()
        problem = self.mod.apply_browse_as(cfg, self.tmp, self.moe_home, chromium, report, wanted=wanted)
        return problem, report, cfg.get("browser", {}).get("real_profile_pin")

    def facts(self):
        with open(os.path.join(self.moe_home, "hermes", self.mod.BROWSE_AS_FILE)) as f:
            return json.load(f)

    def test_a_choice_pins_and_the_facts_file_says_so(self):
        self.choose("Default")
        problem, report, pin = self.run_it({"browser": {"use_real_profile": True}})
        self.assertIsNone(problem)
        self.assertEqual(pin, "Default")
        self.assertTrue(any("Jordy (s@x.com)" in w for w in report.written), report.written)
        facts = self.facts()
        self.assertEqual(facts["pinned"], "Default")
        self.assertEqual([p["dir"] for p in facts["profiles"]], ["Default", "Profile 4"])
        self.assertEqual(facts["snapshot"], "Profile 4")
        self.assertIsNone(facts["problem"])

    def test_last_used_removes_a_pin_and_never_chosen_leaves_one(self):
        self.choose("")
        _, _, pin = self.run_it({"browser": {"real_profile_pin": "Default"}})
        self.assertIsNone(pin)
        self.choose(None)
        _, report, pin = self.run_it({"browser": {"real_profile_pin": "Default"}})
        self.assertEqual(pin, "Default")
        self.assertFalse(report.written)

    def test_a_name_that_is_not_a_profile_is_refused_not_written(self):
        """Hermes fails closed on a missing pin — every browser task would
        error — so a stale choice is dropped, noted, and shown in the app."""
        self.choose("Profile 9")
        problem, report, pin = self.run_it({"browser": {"real_profile_pin": "Profile 9"}})
        self.assertIn("Profile 9", problem)
        self.assertIsNone(pin)
        self.assertEqual(self.facts()["problem"], problem)
        # --set-browse-as with the same bad name: the same refusal, by return value.
        problem2, _, pin2 = self.run_it({"browser": {}}, wanted="Profile 9")
        self.assertIn("not a profile", problem2)
        self.assertIsNone(pin2)

    def test_set_browse_as_overrides_config_json(self):
        self.choose("Default")
        _, _, pin = self.run_it({"browser": {}}, wanted="Profile 4")
        self.assertEqual(pin, "Profile 4")

    def test_no_chromium_means_a_facts_file_with_nothing_to_choose(self):
        self.choose("Default")
        problem, _, pin = self.run_it({"browser": {}}, chromium=None)
        self.assertIsNone(pin)
        self.assertIn("not a profile", problem)
        self.assertIsNone(self.facts()["browser"])
        self.assertEqual(self.facts()["profiles"], [])

    def test_browser_profiles_reads_chromes_own_local_state(self):
        """The real reader, against a fake Chrome tree and a stub of Hermes's
        path helpers: Default first, a listed profile whose directory is gone
        is skipped, the account and the snapshot marker come through."""
        mod = _load_script()
        agent = os.path.join(self.tmp, "hermes-agent")
        os.makedirs(os.path.join(agent, "hermes_cli"))
        chrome = os.path.join(self.tmp, "Chrome")
        copy = os.path.join(self.tmp, "copy")
        for d in ("Default", "Profile 2"):
            os.makedirs(os.path.join(chrome, d))
        os.makedirs(copy)
        with open(os.path.join(chrome, "Local State"), "w") as f:
            json.dump({"profile": {"last_used": "Profile 2", "info_cache": {
                "Profile 2": {"name": "Work", "user_name": "w@x.com"},
                "Default": {"name": "Me"},
                "Profile 7": {"name": "Gone"}}}}, f)
        with open(os.path.join(copy, ".hermes-snapshot-complete"), "w") as f:
            f.write("Profile 2")
        stub = type(sys)("hermes_cli.browser_connect")
        stub.real_profile_data_dir = lambda browser: chrome
        stub.real_profile_copy_dir = lambda browser: copy
        pkg = type(sys)("hermes_cli"); pkg.browser_connect = stub
        saved = {k: sys.modules.get(k) for k in ("hermes_cli", "hermes_cli.browser_connect")}
        sys.modules["hermes_cli"] = pkg; sys.modules["hermes_cli.browser_connect"] = stub
        try:
            mod.hermes_agent_dir = lambda home, explicit=None: agent
            facts = mod.browser_profiles(self.tmp, "chrome")
        finally:
            for k, v in saved.items():
                if v is None: sys.modules.pop(k, None)
                else: sys.modules[k] = v
        self.assertEqual(facts["profiles"], [{"dir": "Default", "name": "Me", "account": ""},
                                             {"dir": "Profile 2", "name": "Work", "account": "w@x.com"}])
        self.assertEqual(facts["last_used"], "Profile 2")
        self.assertEqual(facts["snapshot"], "Profile 2")
        self.assertIsNone(mod.browser_profiles(self.tmp, None))
