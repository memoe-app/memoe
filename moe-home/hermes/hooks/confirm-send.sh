#!/bin/bash
# Hermes pre_tool_call hook: a confirmation dialog in front of Hermes's own
# send tools.
#
# Hermes pipes one JSON object on stdin for every tool call (contract:
# hermes-agent/agent/shell_hooks.py header). If the call is one of Hermes's
# NATIVE or MCP tools that sends something — a message, an email, a post —
# this script puts the same macOS dialog in its path that Moe's connectors
# already use (tools/confirm.sh) and blocks unless the human clicks Send.
# Anything else passes silently.
#
# What this hook guarantees, precisely
# ------------------------------------
# It gates tool calls whose NAME says they send (send_message, reply_email,
# mcp__slack__chat_postMessage, …). That layer is reliable: the name is
# chosen by the tool author, not the model, and cannot be obfuscated.
#
# The exemptions, in full — a list that has grown, so it is written out
# rather than counted: a `send_message(action == "list")` which enumerates
# targets and sends nothing, a tool whose NAME reads as a read unless it also
# says something is being made, and a shell or code tool actually carrying a
# command, which the layer below handles on its command text instead.
#
# And one ROUTE: a Telegram message to the owner's own id passes with no
# dialog — that is how meeting notes reach the owner's phone (is_self_telegram;
# the owner's ids come from the owner record, tools/recipients.py).
#
# Everything else addressed to a person must be GROUNDED before any dialog —
# named by the owner in this conversation, or returned by a real lookup — or it
# is refused back to the model; and a contact tool whose only recipient is the
# owner is refused unless the request asked to reach them (reach_owner is the
# door). See "Who this is going to" below.
#
# It does NOT and cannot gate arbitrary shell, code or browser use. The
# `terminal`/`execute_code` layer below is a denylist of a few well-known
# send paths, kept as belt-and-braces; a denylist over free-form text is
# bypassable by construction. Those surfaces are governed elsewhere:
#   - Moe's connectors' own confirm gates (whatsapp.sh `send` calls
#     confirm.sh itself, for every caller, with the resolved contact name)
#   - Claude Code's deny list in ~/.moe/.claude/settings.json
#   - Hermes's terminal approval policy
#
# Known bypasses (classes this hook cannot catch — do not rely on it here):
#   - HTTP sends from a shell or code tool: curl/requests to a bridge or API
#     (a WhatsApp bridge on localhost, Telegram's bot API, any webhook)
#   - and where a row DOES name an endpoint (the WhatsApp bridge's :3000/send
#     and /edit, api.telegram.org/…/sendMessage), the same endpoint reached
#     another way: a quoted or split URL, a port or path held in a variable,
#     a URL built in code, a raw socket. Telegram is equally blind; known.
#   - obfuscated command text: variables ($s send), split strings (se""nd),
#     base64 | bash, wrapper scripts, AppleScript files (osascript x.scpt)
#   - a send whose only visible evidence is the word "gmail" or "telegram"
#     inside a NON-code flag's quoted value (`--body "…gmail…send…"`). That is
#     deliberate: see strip_data_operands. A flag's value is the payload a
#     command carries, and every false dialog this gate has raised was payload
#     read as structure. The structural rows — real hosts, endpoints,
#     `tell application` clauses, sendmail, `mail -s` — still read those values.
#   - mail from the shell: sendmail, mail, mutt, `open mailto:`
#   - anything typed into a GUI via computer_use, and browser acts the call
#     does not describe (see "Browser: five moments")
#
# Failure policy is CLOSED. Malformed input, a missing python3, a missing
# confirm.sh, an interpreter crash — every one blocks. A gate that opens
# when it is confused is not a gate. (Pair with fail_closed: true in the
# config so Hermes treats a timeout the same way.)
#
# Bash 3.2 (macOS ships nothing newer) and no jq: python3 does the JSON.
set -u

# ---------------------------------------------------------------------------
# Locate confirm.sh. The hook is installed to ~/.moe/hermes/hooks/, so
# ../../tools/confirm.sh is the normal case; $MOE_HOME covers a relocated
# home; $MOE_CONFIRM_BIN exists so the tests can substitute a stub.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOE_HOME="${MOE_HOME:-$HOME/.moe}"
# The classifier reads these: the policy file lives under $MOE_HOME/gate, and
# the connector manifests beside this hook (repo layout) or under $MOE_HOME.
export MOE_HOME SCRIPT_DIR
gate_key() { # the same key the classifier will use, for the log line
  printf '%s' "$RAW_CALL" | python3 -c 'import json, os, sys
try:
    sid = str(json.load(sys.stdin).get("session_id") or "")
except Exception:
    sid = ""
sock = (os.environ.get("HERMES_TOOL_BRIDGE_SOCKET") or "").strip()
print(sid or ("cli:" + sock if sock else ""))' 2>/dev/null
}
# $MOE_CONFIRM_BIN replaces the dialog with a stub so the tests can assert
# what a human would have been shown. It is honoured ONLY alongside
# $MOE_HOOK_TEST=1, because on its own it is an open gate: one exported
# variable pointing at /usr/bin/true and every send goes through unasked.
# Two variables are not real security either — anything that can set one can
# set both — but it makes the bypass impossible to reach by accident, and it
# stops this file quietly contradicting confirm.sh, which says in as many
# words that no environment variable moves the dialog.
CONFIRM=""
if [ "${MOE_HOOK_TEST:-}" = "1" ]; then
  CONFIRM="${MOE_CONFIRM_BIN:-}"
fi
if [ -z "$CONFIRM" ]; then
  if [ -x "$SCRIPT_DIR/../../tools/confirm.sh" ]; then
    CONFIRM="$SCRIPT_DIR/../../tools/confirm.sh"
  else
    CONFIRM="$MOE_HOME/tools/confirm.sh"
  fi
fi

LOG_DIR="$MOE_HOME/logs"
LOG="$LOG_DIR/confirm-hook.log"
GATE_KEY=""

# Recipient and tool only — never the body. The log is for "why was I asked"
# and "what got blocked", and a log of message bodies is a liability. Even
# so, recipients are personal data: the file is created 0600.
log() { # decision, tool, recipient
  ( umask 077
    mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
    printf '%s\t%s\ttool=%s\tto=%s%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" "$3" \
      "${GATE_KEY:+	session=$GATE_KEY}" >>"$LOG" 2>/dev/null
  ) || true
}

block() { # reason
  # Escape for JSON by hand: the reason is ours and short, but backslashes
  # and quotes still have to be safe.
  # Control characters make the JSON invalid — and an invalid answer is read
  # as a malformed hook rather than as "you cancelled", so the person's own
  # refusal reaches the model as a generic failure. A tool name is not ours.
  local r
  r="$(printf '%s' "$1" | tr -d '\000-\037')"
  r="${r//\\/\\\\}"
  r="${r//\"/\\\"}"
  printf '{"decision":"block","reason":"%s"}\n' "$r"
  exit 2
}

if ! command -v python3 >/dev/null 2>&1; then
  log block "?" "?"
  block "confirm-send hook: python3 not found — refusing to let a possible send through"
fi

# ---------------------------------------------------------------------------
# Classify. python3 reads the hook JSON from our stdin and prints either
#   PASS
# or six lines:
#   SEND
#   <channel>
#   <tool id, verbatim>
#   <service, or empty>
#   <recipient>
#   <body, possibly multi-line, to end of output>
# Any other exit status or shape is a parse failure → block.
#
# The classifier is passed with -c, not on stdin: a `python3 - <<EOF`
# heredoc would *replace* stdin, and stdin is where Hermes's JSON arrives.
# Its output is held in a variable, not a temp file: Hermes SIGKILLs a hook
# that outlives its timeout, an EXIT trap never runs then, and a temp file
# holding the message body would be left behind.
# ---------------------------------------------------------------------------
CLASSIFIER=$(cat <<'PY'
import json, os, re, shlex, subprocess, sys, time, unicodedata

raw = "{}" if os.environ.get("MOE_GATE_MODE") == "inventory" else sys.stdin.read()
try:
    payload = json.loads(raw)
except ValueError:
    sys.exit(3)
if not isinstance(payload, dict):
    sys.exit(3)

session_id = str(payload.get("session_id") or "")
# Measured 2026-09-16: on the Claude Code brain every tool call reaches this
# hook from the CLI's tool server — a process with no Hermes agent in it, which
# hands over no session id. So `session_id` was "" on every call; the hour
# grant below was armed for nobody (an empty id is refused, rightly); and the
# owner approved seventeen browser sends in one day with none of them
# remembered, nine of those in four minutes. The same empty id left the gate
# with no memory of which site the conversation was on, so a bare "click the
# Post button" from a helper went out with no dialog at all.
#
# What IS stable across those calls is the process asking: one tool server
# per brain child, alive for the whole conversation, and handed the path of
# the bridge socket it talks to the brain through. That path is the key. It
# is a key to a grant that expires in an hour, not an identity. With neither
# an id nor a socket the key stays empty and every call asks, which is the
# old behaviour and the safe one.
if not session_id:
    _sock = (os.environ.get("HERMES_TOOL_BRIDGE_SOCKET") or "").strip()
    session_id = ("cli:" + _sock) if _sock else ""
tool = str(payload.get("tool_name") or "")
args = payload.get("tool_input")
if args is None:
    args = payload.get("args")          # Hermes-canonical name
if not isinstance(args, dict):
    args = {}


def _hermes_true(value):
    """What Hermes goes on to RUN as true for a boolean argument — which is
    not only a JSON true. This hook is handed the arguments as the model
    wrote them; Hermes coerces them to the schema's types afterwards
    (model_tools.handle_function_call → tools/arg_coercion.py, where
    _coerce_boolean maps the string "true", any case, padded or not, to True),
    and only then does the tool ask `is True` (tools/browser_use_cli.py,
    `allow_signed_out=args.get("allow_signed_out") is True`). A gate that
    read `is True` here would wave the string through to a tool that then
    runs it. Anything else — "yes", 1, "1" — the tool itself treats as false,
    so it is not asked about."""
    return value is True or (isinstance(value, str) and value.strip().lower() == "true")


# Hermes registers MCP tools as mcp__<server>__<name> (tools/mcp_tool.py).
# Match on the bare name: the server segment ("gmail", "slack") would make
# every read tool on a mail server look like a send.
#
# In a loop, because the prefixes nest. Hermes proxies MCP servers through its
# own bus, so a real tool id reaching this hook is
# mcp__hermes-tools__mcp__moe__gmail_send — one pass left "mcp__moe__gmail_send"
# behind, which is not a name the READ_ONLY prefix test can read.
# Peel every `mcp__<server>__` prefix. Hermes proxies can stack them
# (`mcp__hermes-tools__mcp__moe__gmail_send`), so the bare name is the
# innermost, and the server that actually runs the tool is the innermost
# segment. A call is Moe's OWN only when every segment is one of Moe's own
# surfaces — the hermes-tools bridge the brain talks to, and the `moe` name
# that bridge is registered under. One foreign segment anywhere in the chain
# makes it a third party's tool, whatever it is called.
OWN_SERVERS = ("hermes-tools", "hermes_tools", "moe")
bare = tool
segments = []
while True:
    peeled = re.match(r"^mcp__(.+?)__(.+)$", bare)
    if not peeled:
        break
    segments.append(peeled.group(1))
    bare = peeled.group(2)
server = segments[-1] if segments else ""
own = all(seg in OWN_SERVERS for seg in segments)

# ── Layer D: what the tool DECLARES itself to be ──────────────────────────────
#
# Before any word-matching, ask what is *declared* about this tool, in this
# order, first answer wins:
#
#   1. Your decision.   ~/.moe/gate/policy.json — set from the dialog's
#                       "Always allow" button or `~/.moe/tools/gate.sh`.
#                       A tool you allowed runs; a tool you marked "ask" asks.
#                       Nothing the agent can do writes this file (Layer 0).
#   2. Moe's manifests. ~/.moe/connectors/<name>.manifest declares `verbs=`
#                       and (optionally) `sends=`; `<name>_<verb>` is a send
#                       if the verb is in `sends` (default: the verb "send"),
#                       otherwise a read.
#   3. Hermes's tools.  A fixed table of every Hermes builtin and Moe plugin
#                       tool: read / local / shell / keys / send / act.
#   4. The server's own labels. MCP servers annotate tools with readOnlyHint.
#                       Honoured only when the server DISCRIMINATES — at least
#                       one tool marked read-only. Pulse and Cloudflare mark
#                       every tool `readOnlyHint: False`, searches included;
#                       a label that is the same on every tool says nothing,
#                       and such a server is "unlabelled".
#   5. Nothing.         Unknown tool, unlabelled server, or a server Hermes
#                       has not cached → "ask, don't guess": the dialog shows
#                       the tool and its arguments, and offers to remember.
#
# The word-matching layers that follow can only ADD a dialog on top of this
# (a declared read whose call carries a recipient and a body still asks);
# they never remove one. The one exception is a tool YOU allowed: your word
# is final for that tool, and the CLI says so when you allow something whose
# name reads like a send.
MOE_HOME = os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")
HERMES_HOME = os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")
SCRIPT_DIR = os.environ.get("SCRIPT_DIR") or ""
POLICY_PATH = os.path.join(MOE_HOME, "gate", "policy.json")
SCHEMA_CACHE = os.path.join(HERMES_HOME, "cache", "mcp_schema_cache.json")


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def sanitize(name):
    """Hermes's own rule for tool-name components: anything outside
    [A-Za-z0-9_] becomes `_` (tools/mcp_tool.py sanitize_mcp_name_component)."""
    return re.sub(r"[^A-Za-z0-9_]", "_", str(name or ""))


def manifests():
    """{connector_key: {"verbs": set, "sends": set}} from every *.manifest
    beside this hook (repo layout) and under $MOE_HOME; the first seen wins."""
    out = {}
    dirs = []
    if SCRIPT_DIR:
        dirs.append(os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "connectors")))
    dirs.append(os.path.join(MOE_HOME, "connectors"))
    for d in dirs:
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for fname in names:
            if not fname.endswith(".manifest"):
                continue
            fields = {}
            try:
                with open(os.path.join(d, fname), encoding="utf-8") as fh:
                    for line in fh:
                        line = line.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        k, v = line.split("=", 1)
                        fields[k.strip()] = v.strip()
            except OSError:
                continue
            name = fields.get("name") or fname[:-len(".manifest")]
            key = sanitize(name)
            if key in out:
                continue
            verbs = set(fields.get("verbs", "").split())
            sends = set(fields.get("sends", "").split()) if "sends" in fields else {"send"}
            out[key] = {"verbs": verbs, "sends": sends & verbs if verbs else sends}
    return out


def manifest_kind(bare_name):
    for key, m in manifests().items():
        if not bare_name.startswith(key + "_"):
            continue
        verb = bare_name[len(key) + 1:]
        if verb in m["sends"]:
            return "send"
        if verb in m["verbs"]:
            return "read"
    return None


# Every Hermes builtin (toolsets.py) and every Moe plugin tool, by what it
# does. Missing from this table = unknown = asks. Keep it complete rather
# than clever: a new Hermes tool shows up as a dialog until someone reads
# what it does and files it here.
#
# For MOE'S OWN plugin tools that is not good enough on its own — three have
# reached the dialog on a person's screen because nobody remembered this file
# when they were added. `test-confirm-hook.sh` now reads every
# `register_tool(...)` under moe-home/hermes-plugins and fails when one of
# them classifies as unknown, so the omission is caught here rather than in
# front of the owner.
BUILTIN = {}
for _n in ("read_file search_files session_search skills_list skill_view tool_search tool_describe "
           "web_search web_extract vision_analyze video_analyze x_search "
           # Hermes's browser since its rewire (the 0.3.26 pin): browser_exec does
           # every act as code (gate_browser reads it); browser_dialog only answers
           # a dialog the page raised. The structured browser_navigate / _click /
           # _type / _press ... tools were deleted upstream with agent-browser.
           "browser_dialog "
           "clarify memory todo todo_list kanban_list kanban_show kanban_attachments "
           "ha_get_state ha_list_entities ha_list_services "
           "spotify_search spotify_devices spotify_library spotify_albums spotify_playlists "
           "read_terminal read_window_below desktop_preview drive_preview focus_pane "
           "tip tour show_tip gui_tour annotate_preview close_preview apply_layout "
           "yb_query_group_info yb_query_group_members yb_search_sticker "
           "feishu_doc_read feishu_drive_list_comments feishu_drive_list_comment_replies "
           "moe_profile blueprint_list moe_away_status "
           # `connections_list` answers "are you connected to my Gmail?" — it reads
           # what is on record and starts no sign-in (its own description says so).
           # It was the THIRD Moe plugin tool to reach the "not a tool Moe
           # recognises" dialog (moe_followups 2026-09-06, cronjob_manage
           # 2026-09-11, this one 2026-09-20, on "are you connected to my gmail
           # and github?"). The test below now derives the list from the plugins
           # themselves, so a fourth forgotten name is a red suite, not a dialog.
           "connections_list "
           # moe-screen's two Mac readers: `moe_settings_find` reads the list of
           # Memoe's own settings the app publishes; `moe_location` returns where
           # the Mac is to the turn that asked, and stores and sends nothing. The
           # tool-name test never read moe-screen's registrations until
           # 2026-11-14, so moe_location ran on a decision the owner had made in
           # a dialog, and a fresh Mac would have asked (docs/SETTINGS-ASSISTANT.md).
           "moe_settings_find moe_location").split():
    BUILTIN[_n] = "read"
           # `cronjob_manage` is Hermes's scheduling tool — the name it has
           # carried since the cron toolset was consolidated; `cronjob` is the
           # old one and stays for any build that still has it. Only the old
           # name was here, so "check in on me in five minutes" reached the
           # dialog as "not a tool Moe recognises" on the owner's Mac
           # (2026-09-11 05:50) — a person being asked permission for Moe to
           # remember to do something. A reminder is Moe's own clock, local,
           # sends nothing; what the job DOES when it fires is gated then.
for _n in ("write_file patch delegate_task cronjob cronjob_manage skill_manage image_generate "
           "video_generate xai_video_edit xai_video_extend text_to_speech "
           "close_terminal setup_mcp desktop_project blueprint_create "
           "notes_create reminders_create "
           # Moe's own plugin tools. `moe_followups` is what "stop reminding
           # me about that" lands on — it closes, snoozes or mutes one of
           # Moe's own follow-ups in ~/.moe/proactive — and on 2026-09-06 it
           # raised the "not a tool Moe recognises" dialog because it was not
           # here. The `moe_away_*` four enrol THIS machine as a device of the
           # person's Moe, on a ticket the person typed themselves; the code
           # they compare goes to them, not to anyone else.
           "moe_followups moe_away_enrol moe_away_confirm moe_away_reset "
           # `reach_owner` messages the OWNER and nobody else: it takes words
           # and at most a chat app's name, never an address, and the edge
           # fixes the recipient to his own chat (moe-screen/reach.py). A
           # dialog asking him whether Moe may message him is the wrong
           # question; a contact-send is still gated as a send.
           "reach_owner "
           # `report_problem` files a support ticket with the Memoe team — the
           # moe-connectors tool around moe-ticket.py, which has always run
           # through the shell with no dialog (a ticket is not a send to a
           # contact). The person asked for it, and the script checks their
           # Settings › Privacy switch itself before anything leaves.
           "report_problem "
           # Opening Settings or System Settings on the person's own screen
           # (docs/SETTINGS-ASSISTANT.md). Changing a setting and connecting a
           # service are NOT here: see SETTINGS_DIRECT below.
           "moe_settings_show moe_open_settings "
           # The kanban board is Hermes's own sqlite file on this Mac: writing a
           # card or a comment there is local work, whatever the verb says.
           "kanban_create kanban_complete kanban_block kanban_unblock kanban_link "
           "kanban_attach kanban_attach_url kanban_request_changes kanban_request_review "
           "kanban_heartbeat kanban_comment").split():
    BUILTIN[_n] = "local"
for _n in "terminal process process_manage execute_code".split():
    BUILTIN[_n] = "shell"
# Asks by default; SETTINGS_DIRECT (below) lets a quieter settings change
# through. Filed here so the inventory and the plugin-tool test know them.
for _n in "moe_settings_change connect_service".split():
    BUILTIN[_n] = "act"
# The browser tools gate_browser reads, by what each call carries.
BROWSER_GATED = ("browser_cdp", "browser_exec")
# `tool_call` is the tool-search bridge: Hermes unwraps it to the underlying
# tool BEFORE hooks run (agent/tool_executor.py), so a call that still wears
# this name here is one Hermes has already refused to dispatch.
BUILTIN["tool_call"] = "local"
for _n in ("browser_cdp browser_exec computer_use "
           # Hermes 0.21's credential vault. Filling a login or a card is a
           # keystroke on a page; the vault asks the person itself before a
           # card fill and refuses in headless sessions (upstream's gate), so
           # nothing here doubles it.
           "browser_vault_fill browser_vault_enter_code").split():
    BUILTIN[_n] = "keys"
# Hermes 0.21 renamed five tools (cronjob → cronjob_manage, todo → todo_list,
# process → process_manage, tip → show_tip, tour → gui_tour) and added the
# vault. On 2026-09-11 the first cronjob_manage call after the port raised
# the "not a tool Moe recognises" dialog over a reminder. Both names stay
# listed: the table is read by the hook whichever Hermes is installed.
for _n in "browser_vault_list".split():
    BUILTIN[_n] = "read"
for _n in "browser_vault_unlock browser_vault_save_login manage_connections".split():
    BUILTIN[_n] = "local"
# The vault's account tools (the fork's 5e638f20c4). `browser_vault_login` is
# the one call the model is told to make for any login or signup form; its
# ARGUMENTS decide, ahead of this table and any policy (the account card,
# below): mode=signup is a new account in the person's name and is asked
# every time; mode=login fills a saved login or asks the person in Moe's own
# password window, which is its own consent. `confirm`, `regenerate` and
# `discard` finish or undo a signup the person already said yes to, on this
# Mac, and send nothing. None of them had a row, so on 2026-09-29 the owner
# was shown "This is not a tool Moe recognises… Tool: browser_vault_login"
# with an "Always allow" that would have silenced every signup after it.
for _n in ("browser_vault_login browser_vault_confirm browser_vault_regenerate "
           "browser_vault_discard").split():
    BUILTIN[_n] = "local"
# Shows the page Moe is working on to the person (a passkey, a CAPTCHA, "let me
# see it"): it raises a window on their screen or opens the page in their own
# browser, and types, clicks and sends nothing. Without this row the first
# hand-over would raise "not a tool Moe recognises" over the very page the
# person was about to finish.
BUILTIN["browser_handoff"] = "local"
# The cloud computer's sign-in link (moe-connectors signin.py): it mints a
# one-time link and opens a page in Moe's own browser there. The person types
# into that page on their phone; the tool itself types and sends nothing.
BUILTIN["browser_sign_in_link"] = "local"
for _n in ("send_message react_to_message yb_send_dm yb_send_sticker "
           "feishu_drive_add_comment feishu_drive_reply_comment").split():
    BUILTIN[_n] = "send"
# `discord` and `discord_admin` take an `action` — fetch_messages beside
# send_message — so they are acts: asked, and rememberable, not dressed up as
# a message with no recipient.
for _n in ("ha_call_service spotify_playback spotify_queue discord discord_admin").split():
    BUILTIN[_n] = "act"

# Moe's own connectors whose send verb runs tools/confirm.sh itself, right
# before the socket opens. The hook defers to that dialog rather than raising
# a second one. Membership is by name on purpose: a new connector's send is
# gated here until its script is known to ask.
SELF_CONFIRMING = frozenset({"gmail_send", "telegram_send", "whatsapp_send"})

_labels_cache = {}


def labels_for(server_name):
    """(hints, informative, cached) for one MCP server from Hermes's schema
    cache. hints: sanitized tool name → readOnlyHint (True/False/None) or the
    string "destructive". informative: the server marked at least one tool
    read-only, so its labels carry information."""
    if server_name in _labels_cache:
        return _labels_cache[server_name]
    entry = None
    for raw_name, candidate in load_json(SCHEMA_CACHE).items():
        if sanitize(raw_name) == server_name:
            entry = candidate
            break
    tools = entry.get("tools") if isinstance(entry, dict) else None
    hints = {}
    if isinstance(tools, list):
        for t in tools:
            if not isinstance(t, dict) or not t.get("name"):
                continue
            ann = t.get("annotations")
            ann = ann if isinstance(ann, dict) else {}
            ro = ann.get("readOnlyHint")
            if ann.get("destructiveHint") is True:
                hints[sanitize(t["name"])] = "destructive"
            else:
                hints[sanitize(t["name"])] = ro if isinstance(ro, bool) else None
    informative = any(v is True for v in hints.values())
    result = (hints, informative, bool(hints))
    _labels_cache[server_name] = result
    return result


def policy_key(tool_name, bare_name, server_name, is_own):
    """One name per tool, however many proxies it came through:
    `mcp__hermes-tools__mcp__cloudflare__x` and `mcp__cloudflare__x` are the
    same tool and share one policy entry; an own tool is its bare name."""
    return bare_name if is_own else "mcp__%s__%s" % (server_name, bare_name)


def declared(tool_name, bare_name, server_name, is_own, policy=None):
    """(kind, why). kind ∈ run read trusted local shell keys send defer act
    unlabelled unknown. Order: the connector's own dialog, your decision,
    Moe's table, Moe's manifests, the server's labels, nothing."""
    policy = load_json(POLICY_PATH) if policy is None else policy
    ptools = policy.get("tools")
    ptools = ptools if isinstance(ptools, dict) else {}
    pservers = policy.get("servers")
    pservers = pservers if isinstance(pservers, dict) else {}
    # A connector that asks at the socket asks whatever anyone says: a policy
    # `run` cannot silence it, a policy `ask` would only double it.
    if is_own and bare_name in SELF_CONFIRMING:
        return "defer", "this connector asks at the socket itself"
    canon = policy_key(tool_name, bare_name, server_name, is_own)
    rule = ptools.get(canon)
    if not isinstance(rule, dict):
        rule = ptools.get(tool_name)
    rule = rule if isinstance(rule, dict) else {}
    if rule.get("decision") == "run":
        return "run", "you allowed this tool"
    if rule.get("decision") == "ask":
        return "act", "you asked to be asked about this tool"
    if is_own:
        # The table before the manifests: a manifest is a file under ~/.moe,
        # and a planted one must not be able to re-describe a Hermes tool.
        if bare_name in BUILTIN:
            return BUILTIN[bare_name], "Moe's table of its own tools"
        mk = manifest_kind(bare_name)
        if mk:
            return mk, "its connector manifest declares it"
        return "unknown", "not a connector verb, and not one of Moe's own tools"
    srule = pservers.get(server_name)
    srule = srule if isinstance(srule, dict) else {}
    hints, informative, cached = labels_for(server_name)
    if srule.get("decision") == "run":
        return "trusted", "you trust this server (message-shaped calls still ask)"
    if informative and bare_name in hints:
        hint = hints[bare_name]
        if hint == "destructive":
            return "act", "the server marks it destructive"
        if hint is True:
            return "read", "the server marks it read-only"
        return "act", "the server does not mark it read-only"
    if cached:
        return "unlabelled", "%s labels every tool the same, which says nothing" % server_name
    if server_name:
        return "unknown", "Moe has not read what %s offers yet" % server_name
    return "unknown", "no declaration"


HUMAN = {"run": "runs (you allowed it)", "read": "runs", "local": "runs",
         "trusted": "runs (you trust its server)",
         "shell": "shell rules apply", "keys": "key rules apply",
         "send": "asks", "defer": "asks (the connector itself)", "act": "asks",
         "unlabelled": "asks", "unknown": "asks"}

if os.environ.get("MOE_GATE_MODE") == "inventory":
    policy = load_json(POLICY_PATH)
    rows = []
    for key, m in sorted(manifests().items()):
        for verb in sorted(m["verbs"]):
            name = "%s_%s" % (key, verb)
            k, why = declared(name, name, "", True, policy)
            rows.append((name, k, why))
    for name in sorted(BUILTIN):
        k, why = declared(name, name, "", True, policy)
        if name == "browser_vault_save_login":
            # Its arguments decide, ahead of any table or policy (ticket #17).
            why += "; generate=true (a new account, a password Moe makes) asks every time, per site"
        if name == "browser_vault_login":
            why += "; mode=signup (a new account, a password Moe makes) asks every time, per site"
        rows.append((name, k, why))
    for srv, entry in sorted(load_json(SCHEMA_CACHE).items()):
        tools = entry.get("tools") if isinstance(entry, dict) else None
        for t in tools or []:
            if not isinstance(t, dict) or not t.get("name"):
                continue
            b = sanitize(t["name"]); srv_s = sanitize(srv)
            full = "mcp__%s__%s" % (srv_s, b)
            k, why = declared(full, b, srv_s, srv_s in OWN_SERVERS, policy)
            rows.append((full, k, why))
    known = {r[0] for r in rows}
    for name, rule in sorted((policy.get("tools") or {}).items()):
        if name in known or not isinstance(rule, dict):
            continue
        rows.append((name, "run" if rule.get("decision") == "run" else "act",
                     "your decision (tool not currently offered)"))
    for name, k, why in rows:
        sys.stdout.write("%s\t%s\t%s\t%s\n" % (name, k, HUMAN.get(k, k), why))
    sys.exit(0)

# Layer 0: nothing touches the gate itself.
#
# approvals.deny in ~/.hermes/config.yaml carries the same two paths as
# fnmatch globs, which covers the `terminal` tool — Hermes matches those
# against the command string. It cannot cover write_file/patch, because there
# the path is an ARGUMENT and Hermes's own write-deny set (~/.ssh, ~/.aws,
# ~/.hermes/config.yaml, …) has never heard of ~/.moe. Measured before this
# layer existed: a write_file to ~/.moe/tools/confirm.sh with the body
# "#!/bin/bash\nexit 0" passed this hook and every Hermes guard, and would
# have turned confirm-before-send off permanently and silently — the log
# would have gone quiet rather than loud.
#
# This is a refusal, not a dialog. "Do you want to let Moe disable the thing
# that asks you these questions?" is not a question a person should be given
# the chance to click through, and no legitimate tool call names these files:
# the installer copies them, the tests run them by path from the repo, and
# neither of those is a tool call.
#
# Substring, not path resolution: `~`, `$HOME` and `/Users/...` are all
# spellings the model may emit, and resolving them here would need the very
# shell this hook is standing in front of. Over-matching is the safe
# direction — the cost of a false positive is one refused read.
# The two files, not the directories they live in. ~/.moe/tools/ is Moe's
# toolbelt — apple.sh, mac.sh, git.sh — and the model's own prompt tells it to
# run apple.sh by that path. A directory-level rule here blocked
# "~/.moe/tools/apple.sh calendar today", which is the most common thing Moe
# does. Measured, and reverted.
# No trailing slash on the directories: `mv ~/.moe/hermes/hooks /tmp/off`
# names the directory without one, and that single command removed the whole
# gate silently. And the Telegram allow-list lives in Hermes's .env — rewrite
# TELEGRAM_ALLOWED_USERS and the note-to-self exemption belongs to whoever
# wrote it, permanently, with no dialog ever again.
# The files themselves. `/.moe/hermes/hooks` carries no trailing slash on
# purpose: `mv ~/.moe/hermes/hooks /tmp/off` names the directory without one,
# and that single command removed the whole gate silently. The Telegram
# allow-list is here because rewriting TELEGRAM_ALLOWED_USERS in Hermes's
# .env hands the note-to-self exemption to whoever wrote it, permanently and
# with no dialog ever again; and Claude Code's deny list is one of the
# controls this file's own header names as governing what it cannot catch.
#
# `/.moe/tools` as a whole is deliberately NOT here: apple.sh, mac.sh, git.sh
# and name-numbers.py live there and are run constantly. Moving the directory
# out from under confirm.sh is caught by `uproots_the_gate` instead.
GATE_PATHS = ("/.moe/tools/confirm.sh", "/.moe/tools/gate.sh", "/.moe/hermes/hooks", "/.moe/gate",
              "/.hermes/.env", "/.hermes/config.yaml",
              "/.moe/.claude/settings.json",
              # The dialog inside the app. `rm` and `chmod 000` on it both
              # passed: with no dialog to run, confirm.sh falls through to the
              # AppleScript one, which is the weaker of the two and the one
              # nobody has hardened. Lowercase, because every comparison here
              # goes through fold() — the filesystem is case-insensitive and
              # so is this.
              "moe.app/contents/macos/moe-confirm",
              # The password window (ticket #17): the same program by another
              # name. What it prints is what the vault stores as the person's
              # own password; a stand-in there is a password Moe chose.
              "moe.app/contents/macos/moe-secret",
              # ~/.hermes/plugins/ is where Moe's own safety code LIVES: the
              # moe-connectors plugin is what wraps every mail and message the
              # model reads in <untrusted_tool_result>, and claimstore is what
              # the person's memory is written through. A write there removes
              # a control as completely as a write to this file does, and it
              # was gated by nothing — neither approvals.deny (which sees only
              # terminal COMMAND strings) nor Hermes's own write-deny set
              # (which covers /etc, ~/.ssh and its own config, never ~/.moe).
              "/.hermes/plugins/",
              # And the gateway hooks, which the gateway imports and runs.
              "/.hermes/hooks/",
              # The ask directories the away gate waits on (moe-connectors
              # awaygate: $HERMES_HOME/moe/asks/<nonce>/answer). One word
              # written into a live one — "approved" — is a send nobody
              # approved. Found by the away-ask review, 2026-09-25.
              "/.hermes/moe/asks",
              # The same controls on the away machine, where HERMES_HOME is
              # /opt/data and MOE_HOME is $HERMES_HOME/moe-home (its deploy
              # config and boot script) — every entry above spelled for the Mac missed them.
              "/opt/data/.env", "/opt/data/config.yaml", "/opt/data/plugins/",
              "/opt/data/hooks/", "/opt/data/moe/asks",
              "/moe-home/tools/confirm.sh", "/moe-home/tools/confirm-away.py",
              "/moe-home/tools/gate.sh", "/moe-home/hermes/hooks", "/moe-home/gate",
              "/.moe/tools/confirm-away.py",
              # Where Hermes writes down who the person named and what the
              # lookups returned. A tool call that wrote there could name
              # anybody on the person's behalf.
              "/.hermes/grounding",
              # A job's grounding_words are who asked for it. A tool call that
              # rewrote the jobs file could say anybody asked for anything.
              "/.hermes/cron/jobs.json",
              # …and both on the away machine (HERMES_HOME=/opt/data).
              "/opt/data/grounding", "/opt/data/cron/jobs.json")
# The two basenames, for the case where the directory is not in the argument
# at all — write_file(path="confirm.sh") after the model has already put its
# cwd there.
# `moe-confirm` is here because it IS the dialog. confirm.sh runs it and
# takes its exit status as the answer, so replacing it is not a step towards
# opening the gate — it is opening the gate.
# Lowercase, all of them: every comparison folds the haystack and not the
# needle, so "MoeConfirm" here could never match — and MoeConfirm is the
# actual name of the build product.
GATE_BASENAMES = ("confirm.sh", "confirm-send.sh", "moe-confirm", "moeconfirm", "moe-secret", "gate.sh")

# Files that may be RUN all day and never rewritten. The connectors are the
# second gate — each opens its own dialog before any socket — so replacing
# one is opening the gate, exactly as replacing confirm.sh is. But unlike
# confirm.sh they are invoked constantly and legitimately, so naming one
# cannot be the test; only writing to it can. `name-numbers.py` is here
# because its stdout IS the recipient string WhatsApp's dialog shows, and
# `gmail-accounts.json` because it names the SMTP host that an approved
# message and the mailbox password are handed to.
# Layer D reads two more things the agent must not be able to write: the
# connector manifests (a `sends=` line is what makes a verb a send) and
# Hermes's schema cache (where a server's read-only labels live). Reading
# them is fine; replacing them would let a later call declare itself safe.
# `composio-toolkits.json` joined this list on 2026-09-04, when the dialog
# started reading it for the name and mark it shows. It is the same argument
# as the two above: writing it would let a later call decide what the person
# is told they are approving.
# `tier.json`, `limits.json` and `budget.json` joined on 2026-09-06: the
# Composio gate (composio-budget.sh) decides from them, and a tool call that
# rewrote one would let the next call be on a tier it is not, at a cap it
# does not have, with a count it has not spent. HERMES-SURFACES §3.1a.
GATE_WRITE_ONLY = ("gmail.py", "telegram.py", "whatsapp.sh", "name-numbers.py",
                   "gmail-accounts.json", "drive.py", "drive-docs.py",
                   ".manifest", "mcp_schema_cache.json",
                   "composio-toolkits.json",
                   "tier.json", "limits.json", "budget.json",
                   # Who the owner is, and the code that asks. Rewriting either
                   # decides who a contact tool may never reach.
                   "recipients.py", "owner.json",
                   # The code that writes the ledgers: Moe decides grounding
                   # is on from its presence (tools/recipients.py).
                   "recipient_grounding.py", "jobs.json")
# What writing looks like, as a tool name or as a word in a command.
WRITING_TOOL = re.compile(r"write|edit|patch|create|replace|apply|save", re.I)
WRITING_SHELL = re.compile(
    r">>?|\btee\b|\bsed\s+-i|\bcp\b|\bmv\b|\brm\b|\bchmod\b|\bchown\b"
    r"|\bln\b|\bcurl\b.*-o|\bpatch\b|\btruncate\b|\bdd\b"
    r"|\binstall\b|\brsync\b|\bditto\b|\bfind\b.*-delete"
    # ...and the ways code writes a file, for execute_code and python -c.
    r"|open\s*\([\s\S]{0,300}?['\"][wax]['\"]|\.write\s*\(|json\.dump|os\.replace|os\.rename"
    r"|write_text|write_bytes"
    r"|shutil\.|Path\s*\(", re.I)


def rewrites_a_connector(args, tool_name):
    """True for a call that would REPLACE one of the files above."""
    strings = []
    collect_strings(args, strings)
    writing_tool = bool(WRITING_TOOL.search(tool_name or ""))
    for raw in with_deshell(strings):
        if not isinstance(raw, str):
            continue
        low = fold(raw)
        if not any(b.lower() in low for b in GATE_WRITE_ONLY):
            continue
        if writing_tool or WRITING_SHELL.search(raw):
            return True
    return False
# The directories the gate files live in. Used only in combination with a
# basename above — never on their own, because ~/.moe/tools/ is also the
# toolbelt (apple.sh, mac.sh, git.sh) the model is told to run.
#
# A command string that mentions BOTH the directory and the filename is
# touching the gate, however the two are joined. This is what catches the
# spellings a path check cannot see, because the join happens in a shell this
# process never runs:
#     cd ~/.moe/tools && echo x > confirm.sh
#     T=~/.moe/tools; echo x > $T/confirm.sh
# Neither contains the substring /.moe/tools/confirm.sh, and both name the
# directory and the file plainly.
GATE_DIRS = ("/.moe/tools", "/.moe/hermes/hooks")
# Argument names that carry a working directory, so a relative path can be
# resolved against one instead of being waved through.
CWD_KEYS = ("cwd", "working_dir", "workdir", "directory", "dir", "root")


def canonical(text):
    """A path string reduced to one spelling.

    Substring matching is only as good as the spelling it is handed, and an
    adversarial pass got past the first version of this check with nothing
    more exotic than redundant syntax — `~/.moe//tools/confirm.sh`,
    `~/.moe/./tools/confirm.sh`, `~/.moe/tools/../tools/confirm.sh` all name
    the real file and none of them contains the literal substring. These are
    not attacks; they are what a model emits when it joins paths carelessly.

    expanduser and expandvars first (so `~` and `$HOME` fold), then normpath,
    which collapses `//`, `/./` and resolves `..` lexically. Lexical is the
    right kind here: realpath would follow symlinks, and following a symlink
    the model just created is how a check gets talked out of its own answer."""
    try:
        expanded = os.path.expandvars(os.path.expanduser(text))
        return os.path.normpath(expanded)
    except Exception:
        return text


def deshell(text):
    """Approximate what the shell hands the kernel: undo backslash escapes,
    drop quotes, flatten command-substitution punctuation. Over-broad on
    purpose - Layer 0 fires only when a gate path actually appears. Built
    with chr() rather than literal quotes/backticks: this whole classifier is
    a quoted heredoc inside $(...), which bash 3.2 still scans for quotes."""
    if not isinstance(text, str):
        return text
    out = re.sub(r"\\(.)", r"\1", text)
    for ch in (chr(34), chr(39), chr(96)):        # doublequote, singlequote, backtick
        out = out.replace(ch, "")
    out = out.replace(chr(36) + chr(40), "")      # dollar-paren
    return out.replace(chr(41), "")               # close paren


def with_deshell(strings):
    marks = (chr(92), chr(34), chr(39), chr(96), chr(36) + chr(40))
    return strings + [deshell(x) for x in strings
                      if isinstance(x, str) and any(m in x for m in marks)]


def collect_strings(value, out, depth=0):
    if depth > 6 or len(out) > 512:
        return
    if isinstance(value, str):
        out.append(value)
    elif isinstance(value, dict):
        for v in value.values():
            collect_strings(v, out, depth + 1)
    elif isinstance(value, (list, tuple)):
        for v in value:
            collect_strings(v, out, depth + 1)


# Moving or deleting the DIRECTORY the gate lives in does not name the gate,
# and naming the directory on its own would refuse every ordinary use of the
# tools in it. So the directories are checked only in the company of a verb
# that would take them away.
UPROOTING = re.compile(r"\b(mv|rm|rmdir|cp|ln|chmod|chown|chflags|trash|find|xargs|install|rsync|ditto)\b", re.I)
# Killing the dialog is not moving it, and it has the same effect: confirm.sh
# reads any exit that is not 0 or 1 as "could not ask" and falls through to
# the AppleScript dialog, which is the weaker one. `pkill -f moe-confirm`
# named no path at all and passed.
KILLING = re.compile(r"\b(pkill|killall|kill)\b", re.I)
GATE_HOMES = ("/.moe/tools", "/.moe/hermes", "/.moe", "/.hermes", "/.hermes/cron",
              "/.hermes/grounding", "/.moe/gate")


def fold(text):
    """canonical(), then lowercased, because the filesystem is.

    macOS ships APFS case-INSENSITIVE by default, so ~/.MOE/tools/confirm.sh
    and ~/.moe/tools/confirm.sh are the same file — measured on this machine,
    both are inode 5783852. Every comparison below was case-sensitive, so
    write_file(path="~/.MOE/tools/confirm.sh") was refused by nothing: the
    deny globs cannot see a write_file ARGUMENT, and this hook was the only
    layer looking, and it was looking for the wrong spelling.

    NFKC then casefold, not `.lower()`. APFS is case-INSENSITIVE, and the
    equivalence it uses is full Unicode case-folding — which also collapses
    ligatures and the long s. `.lower()` does neither, so two spellings that
    name the SAME FILE walked straight through. Measured on this machine, all
    three of these are inode 5783852:

        ~/.moe/tools/confirm.sh
        ~/.moe/tools/confirm.\u017fh   (U+017F LATIN SMALL LETTER LONG S)
        ~/.moe/tools/con\ufb01rm.sh    (U+FB01 LATIN SMALL LIGATURE FI)

    and `"confirm.\u017fh".lower()` is unchanged while
    `unicodedata.normalize("NFKC", ...).casefold()` gives "confirm.sh". A
    `write_file` to either spelling was refused by NOTHING: approvals.deny
    only ever sees terminal COMMAND strings, and Hermes's own write-deny set
    covers /etc, ~/.ssh and its own config — never ~/.moe. This hook was the
    only layer, looking for the wrong spelling.

    The gate constants are all plain lowercase ASCII, so folding one side is
    enough. The unfolded string is kept for the refusal message — telling
    somebody their path was rejected in a spelling they did not type helps
    nobody."""
    try:
        return unicodedata.normalize("NFKC", canonical(text)).casefold()
    except (TypeError, ValueError):
        return canonical(text).lower()


# Two directories the send gate's verdicts depend on, and which no tool call
# may touch however it spells them: the grounding ledgers Hermes writes (who
# named whom, what lookups returned) and Moe's gate directory (the tickets the
# hook hands the connectors, the app's offers, your "always allow" decisions).
# Replacing a file there would let a later call name anybody; deleting one
# would turn a check off. Protected by what a call DOES to them, not by one
# spelling: the literal paths (GATE_PATHS), the real directories under
# whatever HERMES_HOME / MOE_HOME this is, their inodes (so a symlink to them
# is them), and the directory's name beside any way of naming its home.
GROUNDING_DIR = os.path.join(HERMES_HOME, "grounding")
MOE_GATE_DIR = os.path.join(MOE_HOME, "gate")
PROTECTED_DIRS = (
    (GROUNDING_DIR, re.compile(r"(?<![\w-])grounding(?![\w-])", re.I),
     re.compile(r"\.hermes\b|hermes_home|get_hermes_home", re.I)),
    (MOE_GATE_DIR, re.compile(r"(?<![\w.-])gate(?![\w.-])", re.I),
     re.compile(r"\.moe\b|moe_home|application support/moe", re.I)),
)


def touches_protected_dir(raw):
    """True when this string names one of PROTECTED_DIRS, however spelled."""
    if not isinstance(raw, str) or not raw:
        return False
    here = fold(raw)
    for directory, name_word, home_word in PROTECTED_DIRS:
        if fold(directory) in here:
            return True
        if name_word.search(raw) and home_word.search(raw):
            return True
        try:
            g = os.stat(directory)
        except OSError:
            continue
        for tok in re.split(r"[\s;|&()<>=,'\"]+", raw):
            tok = tok.strip()
            if not tok or "/" not in tok:
                continue
            path = os.path.expandvars(os.path.expanduser(tok))
            for candidate in (path, os.path.dirname(path.rstrip("/"))):
                try:
                    st = os.stat(candidate)
                except (OSError, ValueError):
                    continue
                if (st.st_dev, st.st_ino) == (g.st_dev, g.st_ino):
                    return True
    return False


_GLOB_CHARS = re.compile(r"[*?\[]")
# Word separators, built with chr() for the quote characters: this classifier
# is a quoted heredoc inside $(...), which bash 3.2 still scans for quotes.
_SPLIT_GLOB = r"[\s;|&<>()=,+" + chr(39) + chr(34) + chr(96) + "]+"
_SPLIT_WORDS = r"[\s;|&<>()=," + chr(39) + chr(34) + chr(96) + "]+"


def glob_expansions(raw, cwds=()):
    """Every existing path a glob-shaped word in raw would expand to, and,
    for a word whose last part does not exist yet (a file about to be
    written), its expanded directory joined with that last part. Bounded:
    this runs on every tool call."""
    import glob as _glob
    if not isinstance(raw, str) or not _GLOB_CHARS.search(raw):
        return []
    out = []
    for tok in re.split(_SPLIT_GLOB, raw):
        if not tok or not _GLOB_CHARS.search(tok) or len(out) > 200:
            continue
        tok = os.path.expandvars(os.path.expanduser(tok))
        bases = [tok] if os.path.isabs(tok) else [os.path.join(c, tok) for c in cwds]
        for pattern in bases[:8]:
            try:
                hits = _glob.glob(pattern)[:50]
                head, tail = os.path.split(pattern)
                if _GLOB_CHARS.search(head):
                    hits += [os.path.join(h, tail) for h in _glob.glob(head)[:50]]
            except Exception:
                continue
            out.extend(hits)
    return out


def resolves_to_gate(path):
    """True when `path` IS a gate file, whatever it is spelled like.

    The string checks above are a matcher over text, and text has more
    spellings than anyone enumerates. This asks the filesystem instead: two
    names that stat to the same inode are the same file, and no amount of
    normalisation trickery survives that. It only answers for a path that
    already exists — which is exactly the case that matters, because the gate
    files do — so it is a second layer under the string checks, not a
    replacement for them."""
    try:
        target = os.stat(os.path.expandvars(os.path.expanduser(path)))
    except (OSError, ValueError, TypeError):
        return False
    moe = os.path.expanduser(os.environ.get("MOE_HOME", "~/.moe"))
    for gate in (os.path.join(moe, "tools", "confirm.sh"),
                 os.path.join(moe, "hermes", "hooks", "confirm-send.sh")):
        try:
            g = os.stat(gate)
        except OSError:
            continue
        if (g.st_dev, g.st_ino) == (target.st_dev, target.st_ino):
            return True
    return False


# ---------------------------------------------------------------------------
# What a path RESOLVES to, not how it is spelled (W1-A, 2026-11-12).
#
# Everything above this line recognises the gate by the substring /.moe/ —
# and since 0.3.5 ~/.moe is only a link. The home is
# ~/Library/Application Support/Moe, the app exports THAT as MOE_HOME, and
# spelled that way all of these passed with no refusal and no dialog,
# measured against a scratch home:
#
#     echo x > "<home>/tools/confirm.sh"              (terminal)
#     echo x > "<home>/hermes/hooks/confirm-send.sh"  (terminal)
#     write_file <home>/hermes/hooks/composio-budget.sh
#     write_file <home>/.claude/settings.json
#     mv "<home>/hermes/hooks" /tmp/off
#     rm -rf "<home>/tools"      chmod 000 "<home>/tools"
#
# and so did any OTHER link pointing at the home, a relative path after
# `cd "<home>"`, and every one of them for a MOE_HOME that is neither spelling.
#
# Three layers, each only ever ADDING a refusal to the ones above:
#   1. the same substring tests, over every spelling of every home this
#      process can name — MOE_HOME, the link, the release path, and what each
#      of those resolves to (GATE_SPELLED);
#   2. every path-like word of every argument, worded the way a shell words
#      it (so a quoted or backslashed space stays inside its path), resolved,
#      and compared with the gate files by resolved path and by inode
#      (gate_class);
#   3. a directory that CONTAINS a gate file, as the operand of something
#      that moves, deletes or re-modes it.
#
# Files, not directories, exactly as above: <home>/tools is still the
# toolbelt and running apple.sh from it by any spelling passes. No dialog is
# added anywhere — these are refusals for gate files and nothing else.
GATE_REL_FILES = ("tools/confirm.sh", "tools/gate.sh", "tools/confirm-away.py",
                  ".claude/settings.json")
GATE_REL_TREES = ("hermes/hooks", "gate")
HERMES_REL_FILES = (".env", "config.yaml", "cron/jobs.json")
HERMES_REL_TREES = ("plugins", "hooks", "moe/asks", "grounding")
RELEASE_HOME_TAIL = "/Library/Application Support/Moe"


def _spellings(paths):
    """Each path as given and as resolved, once."""
    out = []
    for p in paths:
        if not p:
            continue
        both = [p]
        try:
            both.append(os.path.realpath(p))
        except (OSError, ValueError):
            pass
        for s in both:
            s = os.path.normpath(s)
            if s not in ("/", ".") and s not in out:
                out.append(s)
    return out


_USER_HOMES = _spellings([os.path.expanduser("~")])
MOE_HOMES = _spellings([MOE_HOME, os.path.expanduser("~/.moe"),
                        os.path.expanduser("~" + RELEASE_HOME_TAIL)])
HERMES_HOMES = _spellings([HERMES_HOME, os.path.expanduser("~/.hermes")])


def _tails(home):
    """A home, and the part of it after the user directory: the model may
    write ~, $HOME, ${HOME} or another variable in front of that part, and a
    substring test should not care which."""
    out = [home]
    for base in _USER_HOMES:
        if home.startswith(base.rstrip("/") + "/"):
            out.append(home[len(base.rstrip("/")):])
    return out


def _spelled(homes, rels):
    out = []
    for home in homes:
        for tail in _tails(home):
            for rel in rels:
                s = fold(tail + "/" + rel)
                if s not in out:
                    out.append(s)
    return tuple(out)


# Layer 1. GATE_PATHS, GATE_DIRS and GATE_HOMES again, for every home.
GATE_SPELLED = (_spelled(MOE_HOMES, GATE_REL_FILES + GATE_REL_TREES)
                + _spelled(HERMES_HOMES, HERMES_REL_FILES + HERMES_REL_TREES))
GATE_SPELLED_DIRS = _spelled(MOE_HOMES, ("tools", "hermes/hooks"))
# Not the home itself: "…/Application Support/Moe" followed by a space is
# also how "…/Application Support/Moe Dev/notes" begins. The home as a whole
# is judged by layer 3, where it is one word.
GATE_SPELLED_HOMES = (_spelled(MOE_HOMES, ("tools", "hermes", "hermes/hooks", "gate", ".claude"))
                      + _spelled(HERMES_HOMES, ("cron", "grounding")))

_GATE_INDEX = None
_STAT_MEMO = {}
_CLASS_MEMO = {}


def _inode(path):
    if path in _STAT_MEMO:
        return _STAT_MEMO[path]
    try:
        st = os.stat(path)
        got = (st.st_dev, st.st_ino)
    except (OSError, ValueError):
        got = None
    if len(_STAT_MEMO) < 20000:
        _STAT_MEMO[path] = got
    return got


def gate_index():
    """The gate files, the directories that are gate all the way down, the
    directories inside a home that hold one, and the directories above a
    home — each as folded paths and, where it exists, as an inode."""
    global _GATE_INDEX
    if _GATE_INDEX is not None:
        return _GATE_INDEX
    files, trees, inside, tools, above = set(), set(), set(), set(), set()
    for homes, rel_files, rel_trees in ((MOE_HOMES, GATE_REL_FILES, GATE_REL_TREES),
                                        (HERMES_HOMES, HERMES_REL_FILES, HERMES_REL_TREES)):
        for home in homes:
            inside.add(home)
            for rel in rel_files + rel_trees:
                full = os.path.join(home, rel)
                (trees if rel in rel_trees else files).add(full)
                parent = os.path.dirname(full)
                while len(parent) > len(home):
                    inside.add(parent)
                    parent = os.path.dirname(parent)
            parent = os.path.dirname(home)
            for _ in range(64):
                above.add(parent)
                if os.path.dirname(parent) == parent:
                    break
                parent = os.path.dirname(parent)
    for home in MOE_HOMES:
        tools.add(os.path.join(home, "tools"))
    inside -= trees
    above -= inside | trees

    def both(paths):
        return (frozenset(fold(p) for p in paths),
                frozenset(i for i in (_inode(p) for p in paths) if i))
    _GATE_INDEX = {"files": both(files), "trees": both(trees), "inside": both(inside),
                   "tools": both(tools), "above": both(above)}
    return _GATE_INDEX


def gate_class(path):
    """What an absolute path is to the gate: "gate" (a gate file, or anything
    in a directory that is gate all the way down), "tools" (the directory
    confirm.sh sits in), "inside" (another directory in a home that holds a
    gate file, or the home), "above" (a directory a home sits in), or "".

    By folded path first — which answers for a file that does not exist yet —
    and then by inode, which answers for a hard link, a case or Unicode
    variant, a firmlink, and anything else that names the same thing."""
    if path in _CLASS_MEMO:
        return _CLASS_MEMO[path]
    idx = gate_index()
    f = fold(path)
    ino = _inode(path)
    got = ""
    if (f in idx["files"][0] or f in idx["trees"][0]
            or any(f.startswith(t + "/") for t in idx["trees"][0])
            or (ino and (ino in idx["files"][1] or ino in idx["trees"][1]))):
        got = "gate"
    else:
        parent = path
        for _ in range(48):
            up = os.path.dirname(parent)
            if up == parent:
                break
            parent = up
            pin = _inode(parent)
            if pin and pin in idx["trees"][1]:
                got = "gate"
                break
    if not got:
        for name in ("tools", "inside", "above"):
            if f in idx[name][0] or (ino and ino in idx[name][1]):
                got = name
                break
    if len(_CLASS_MEMO) < 20000:
        _CLASS_MEMO[path] = got
    return got


_SHELL_PUNCT = "();<>|&"
_QUOTED = re.compile("([" + chr(34) + chr(39) + chr(96) + "])(.{1,2048}?)\\1", re.S)
_WORD_TRIM = chr(34) + chr(39) + chr(96) + " \t\r\n,;:()[]{}"
UPROOT_WORDS = frozenset(("mv", "rm", "rmdir", "cp", "ln", "chmod", "chown", "chflags", "trash",
                          "find", "xargs", "install", "rsync", "ditto", "unlink", "srm"))
DESTROY_WORDS = frozenset(("mv", "rm", "rmdir", "trash", "chmod", "chown", "chflags", "srm"))
# The same verbs as code writes them, for execute_code and python -c.
CODE_UPROOTING = re.compile(
    r"rmtree|shutil\.move|\bos\.(remove|unlink|rename|renames|replace|rmdir|removedirs|chmod|chown)\b"
    r"|\.(unlink|rename|replace|rmdir|chmod)\s*\(")


def shell_segments(raw):
    """raw, worded the way a shell words it: a list of simple commands, each
    a list of words with the quotes and backslashes already taken off — so
    "~/Library/Application Support/Moe" and Application\\ Support are one
    word each. A pipeline stays one segment (echo DIR | xargs rm -rf). The
    second value is False when a line could not be worded to its end."""
    segs, whole = [], True
    for line in raw[:65536].split("\n"):
        if not line.strip():
            continue
        cur = []
        try:
            lex = shlex.shlex(line, posix=True, punctuation_chars=True)
            lex.whitespace_split = True
            lex.commenters = ""
            for tok in lex:
                if tok and all(c in _SHELL_PUNCT for c in tok):
                    if ";" in tok or "&&" in tok or "||" in tok or tok == "&":
                        if cur:
                            segs.append(cur)
                        cur = []
                    continue
                cur.append(tok)
        except ValueError:
            whole = False
        if cur:
            segs.append(cur)
    return segs, whole


def resolved_paths(word, cwds, budget):
    """Every absolute path a word may name: as written and as resolved, each
    glob expanded, a relative one against each directory in play."""
    import glob as _glob
    if not isinstance(word, str):
        return []
    word = word.strip(_WORD_TRIM)
    if (not word or len(word) > 2048 or "://" in word or word.startswith("-")
            or chr(0) in word):
        return []
    out = []
    for piece in ([word] + word.split("=")[1:] if "=" in word else [word]):
        piece = os.path.expandvars(os.path.expanduser(piece))
        if os.path.isabs(piece):
            bases = [piece]
        elif cwds and piece and not piece.startswith(("$", "~")):
            bases = [os.path.join(c, piece) for c in cwds[:8]]
        else:
            continue
        for base in bases:
            if budget[0] <= 0:
                return out
            budget[0] -= 1
            names = [base]
            if _GLOB_CHARS.search(base):
                try:
                    names += _glob.glob(base)[:50]
                    head, tail = os.path.split(base)
                    if _GLOB_CHARS.search(head):
                        names += [os.path.join(h, tail) for h in _glob.glob(head)[:50]]
                except Exception:
                    pass
            for name in names:
                for p in (os.path.normpath(name),):
                    if p not in out:
                        out.append(p)
                try:
                    real = os.path.realpath(name)
                    if real not in out:
                        out.append(real)
                except (OSError, ValueError):
                    pass
    return out


def touches_the_gate_by_resolution(args):
    """True when any word of any argument RESOLVES to the gate (layer 2), or
    to a directory holding it in the hands of something that would move,
    delete or re-mode that directory (layer 3)."""
    strings = []
    collect_strings(args, strings)
    strings = [s for s in strings if isinstance(s, str) and s]
    if not strings:
        return False
    # Directories a relative word may be relative to: a cwd-ish argument and
    # every `cd`. Kept as written — a folded path is a different file on a
    # case-sensitive disk, which is what the away machine has.
    cwds = []

    def add_cwd(held):
        held = os.path.expandvars(os.path.expanduser(held.strip(_WORD_TRIM)))
        for cand in ([held] if os.path.isabs(held) else [os.path.join(c, held) for c in cwds[:4]]):
            if cand not in cwds:
                cwds.append(cand)

    if isinstance(args, dict):
        for key in CWD_KEYS:
            held = args.get(key)
            if isinstance(held, str) and held.strip():
                add_cwd(held)
    worded = []
    for raw in strings:
        segs, whole = shell_segments(raw)
        worded.append((raw, segs, whole))
        for seg in segs:
            for i, w in enumerate(seg[:-1]):
                if os.path.basename(w) in ("cd", "pushd"):
                    add_cwd(seg[i + 1])
    # Where Hermes says the call runs. Trusted to say what a relative path
    # names, and for nothing else: `find . -name x` in the home is not an
    # attempt on it.
    named_only = list(cwds)
    held = payload.get("cwd")
    if isinstance(held, str) and os.path.isabs(held.strip()) and held.strip() not in named_only:
        named_only.append(held.strip())
    budget = [6000]
    for raw, segs, whole in worded:
        low = fold(raw) if len(raw) <= 65536 else raw.lower()
        basename_named = any(b in low for b in GATE_BASENAMES)
        code_uproots = bool(CODE_UPROOTING.search(raw)) or (not whole and bool(UPROOTING.search(raw)))
        # Words no shell made: the argument as a whole (a write_file path is
        # one path, spaces and all), anything between quotes (code), and the
        # plain split, for text shlex could not word.
        loose = [raw] if len(raw) <= 2048 else []
        loose += [m.group(2) for m in _QUOTED.finditer(raw[:65536])]
        loose += [w for w in re.split(_SPLIT_WORDS, raw[:65536]) if "/" in w]
        for word in loose:
            for p in resolved_paths(word, named_only if word is raw else (), budget):
                kind = gate_class(p)
                if kind == "gate":
                    return True
                if kind in ("tools", "inside") and code_uproots:
                    return True
                if kind == "tools" and basename_named:
                    return True
        for seg in segs:
            names = [os.path.basename(w) for w in seg]
            uproots = any(n in UPROOT_WORDS for n in names)
            destroys = None
            for i, n in enumerate(names):
                if n in DESTROY_WORDS or (n == "find" and any(
                        w in ("-delete", "-exec", "-execdir", "-ok") for w in seg)):
                    destroys = (i, n)
                    break
            operands = [i for i, w in enumerate(seg)
                        if destroys and i > destroys[0] and not w.startswith("-")]
            for i, word in enumerate(seg):
                cd_target = i > 0 and names[i - 1] in ("cd", "pushd")
                for p in resolved_paths(word, cwds, budget):
                    kind = gate_class(p)
                    if kind == "gate":
                        return True
                    if cd_target:
                        continue
                    if kind in ("tools", "inside") and (uproots or code_uproots):
                        return True
                    if kind == "tools" and basename_named:
                        return True
                    if kind == "above" and destroys and i in operands:
                        # `mv a.pdf ~` puts something IN the directory; only
                        # a directory being moved is taken away.
                        if destroys[1] == "mv" and len(operands) > 1 and i == operands[-1]:
                            continue
                        return True
                if word not in (".", "..") and "/" not in word:
                    continue
                # A relative word against where Hermes says the call runs.
                for p in resolved_paths(word, [c for c in named_only if c not in cwds], budget):
                    if gate_class(p) == "gate":
                        return True
    return False


def uproots_the_gate(args):
    """True for a command that would move, delete or unarm the gate's home."""
    strings = []
    collect_strings(args, strings)
    for raw in with_deshell(strings):
        if not isinstance(raw, str):
            continue
        if KILLING.search(raw) and any(b.lower() in raw.lower() for b in GATE_BASENAMES):
            return True
        if not UPROOTING.search(raw):
            continue
        here = fold(raw)
        for home in GATE_HOMES + GATE_SPELLED_HOMES:
            # The directory as a whole word: `mv ~/.moe/hermes /tmp` yes,
            # `~/.moe/hermes/hooks/confirm-send.sh --help` is already covered
            # above, and `rm /tmp/moe-notes` is neither.
            if re.search(re.escape(home) + r"(\s|/?$|/\s)", here):
                return True
    return False


def names_the_gate(args):
    """True if any string anywhere in the tool's arguments names a gate file.

    Three shapes, because the path can arrive in three:
      - absolute or ~-relative, anywhere in the arguments
      - relative, with the directory in a sibling `cwd`-ish argument
      - a bare basename, with the directory established earlier by a `cd`
        this process never saw
    The last is why the basenames are checked on their own. It over-matches by
    design: refusing to write some unrelated file called confirm.sh is a cost
    worth paying to keep the one that gates every outbound message."""
    strings = []
    collect_strings(args, strings)
    strings = with_deshell(strings)
    if not strings:
        return False
    cwds = []
    if isinstance(args, dict):
        for key in CWD_KEYS:
            held = args.get(key)
            if isinstance(held, str) and held.strip():
                cwds.append(fold(held))
    # `cd ~/.moe && echo x > gate/policy.json`: the directory is in the
    # command, the file name is relative to it, and neither half alone names
    # the gate. Every `cd <dir>` in the text is a directory the rest of it
    # may be relative to.
    for raw in strings:
        if isinstance(raw, str):
            for m in re.finditer(r"\bcd\s+([^\s;&|)]+)", raw):
                cwds.append(fold(os.path.expanduser(m.group(1).strip("\"'"))))
    for raw in strings:
        if not raw:
            continue
        here = fold(raw)
        candidates = [here]
        if not os.path.isabs(here):
            candidates.extend(fold(os.path.join(c, here)) for c in cwds)
        # And each word of a command on its own, relative to each directory
        # in play: `gate/policy.json` after `cd ~/.moe` is the gate.
        if cwds and isinstance(raw, str):
            for tok in re.split(r"[\s;|&<>()]+", raw):
                tok = tok.strip("\"'")
                if tok and not tok.startswith(("/", "~", "-", "$")) and "/" in tok:
                    candidates.extend(fold(os.path.join(c, tok)) for c in cwds)
        # A shell glob names whatever it matches, and the shell expands it
        # where this hook cannot see: ~/.mo?/ga?e/session-sends.json named
        # the grant file and contained none of the strings above (measured,
        # security review S1, 2026-10-19). So expand each glob-shaped word
        # here and judge what it would have named.
        candidates.extend(fold(g) for g in glob_expansions(raw, cwds))
        for cand in candidates:
            if any(p in cand + "/" for p in GATE_PATHS):
                return True
            # …and the same files under every spelling of every home.
            if any(p in cand + "/" for p in GATE_SPELLED):
                return True
        # A bare filename, with no directory anywhere to disambiguate it.
        if os.path.basename(here) in GATE_BASENAMES and os.path.dirname(here) in ("", "."):
            return True
        # gate.sh edits ~/.moe/gate/policy.json wherever it is run from — the
        # installed copy, the repo copy, a copy in /tmp. The basename alone is
        # enough: an agent that wants a tool allowed asks the person, who runs
        # this in their own terminal.
        if any(os.path.basename(tok.strip("\"'").rstrip("/")) == "gate.sh"
               for tok in re.split(r"[\s;|&()<>]+", here) if tok):
            return True
        # The filesystem's own answer, for a path that exists.
        if resolves_to_gate(raw):
            return True
        # The ledgers and the gate directory, however named (touches_protected_dir).
        if touches_protected_dir(raw) or any(touches_protected_dir(c) for c in candidates):
            return True
        # Directory and filename both present, joined by a shell we cannot see.
        lowered = fold(raw)
        if (any(d in lowered for d in GATE_DIRS + GATE_SPELLED_DIRS)
                and any(b in lowered for b in GATE_BASENAMES)):
            return True
    # What each word resolves to, whatever it is spelled like.
    return touches_the_gate_by_resolution(args)


# notes_create / reminders_create write to Apple Notes and Reminders, not to
# the filesystem — their `body`/`notes` fields are free prose a person dictated,
# which legitimately mentions filenames ("review confirm.sh", "the gmail.py
# config"). Those tools CANNOT write to the gate, so the filesystem-gate scan
# below (which keys on WRITING_TOOL matching "create") only ever turned a
# perfectly safe note into a scary refusal — and pushed the model back to the
# raw osascript this verb exists to replace. Exempt them, but only under the
# trusted spellings, exactly as SELF_CONFIRMING does: a foreign
# mcp__other__notes_create is still scanned.
_gate_exempt = bare in ("notes_create", "reminders_create") and own
if not _gate_exempt and (
        names_the_gate(args) or uproots_the_gate(args) or rewrites_a_connector(args, tool)):
    sys.stdout.write(
        "confirm-send hook: refused — %s touches something Moe's send gate depends "
        "on: the dialog, the gate's own code and rules, who the owner is, the jobs "
        "and their record of who asked for them, or the record of who named whom. "
        "Nothing may change what decides whether Moe sends.\n" % (tool or "this call"))
    sys.exit(9)

# Layer 0s: the shell and the file tools never read Moe s secrets.
#
# A prompt injection that reaches terminal or read_file could read the
# tenant bearer (cloud/credential.json), the device s private identity and
# thread keys, the admin token of the owner over every tenant (cloud/admin-token,
# on the owner's Mac only), the Hermes .env, or ask security to print a
# Keychain password (Moe s items are created trusting /usr/bin/security, so
# that read is silent) — and then post it anywhere (security review S2,
# 2026-10-19). Hermes s own read_file already refuses its .env; nothing
# refused the rest. Moe s connectors read these themselves, inside their own
# processes, and never through a command the model wrote.
#
# A heuristic over text plus the answer of the filesystem for paths that exist
# (inode, and globs expanded here). It is a guard rail, not a sandbox: a
# script the model writes and runs can still assemble the path at run time.
# The boundary is a different user or a sandbox profile for the agent shell.
SECRET_BASENAMES = ("admin-token", "thread-keys.json", "device-identity.json",
                    "credential.json")
SECRET_FRAGMENTS = ("/.hermes/.env", "/opt/data/.env", "/.hermes/auth.json",
                    "/opt/data/auth.json")
KEYCHAIN_READ = re.compile(
    r"\bsecurity\b[\s\S]{0,300}?\b(find-generic-password|find-internet-password"
    r"|find-key|dump-keychain|export)\b", re.I)
READING_TOOL = re.compile(r"terminal|shell|bash|exec|process|read|search_files|file|code|run",
                          re.I)


def _secret_inodes():
    out = set()
    homes = [MOE_HOME, os.path.expanduser("~/.moe"),
             os.path.expanduser("~/Library/Application Support/Moe")]
    for home in homes:
        for name in ("admin-token", "credential.json", "device-identity.json"):
            out.add(os.path.join(home, "cloud", name))
    out.add(os.path.join(HERMES_HOME, ".env"))
    inodes = set()
    for path in out:
        try:
            st = os.stat(path)
            inodes.add((st.st_dev, st.st_ino))
        except OSError:
            pass
    return inodes


def reads_a_secret(args, tool_name):
    if not READING_TOOL.search(tool_name or ""):
        return False
    strings = []
    collect_strings(args, strings)
    strings = with_deshell(strings)
    inodes = None
    for raw in strings:
        if not isinstance(raw, str) or not raw:
            continue
        if KEYCHAIN_READ.search(raw):
            return True
        names = [fold(raw)] + [fold(g) for g in glob_expansions(raw, ())]
        for here in names:
            if any(f in here for f in SECRET_FRAGMENTS):
                return True
            words = re.split(_SPLIT_WORDS, here)
            if any(os.path.basename(w.rstrip("/")) in SECRET_BASENAMES for w in words if w):
                return True
        if inodes is None:
            inodes = _secret_inodes()
        if inodes:
            for tok in re.split(_SPLIT_WORDS, raw):
                if "/" not in tok:
                    continue
                for cand in [tok] + glob_expansions(tok, ()):
                    try:
                        st = os.stat(os.path.expandvars(os.path.expanduser(cand)))
                    except (OSError, ValueError):
                        continue
                    if (st.st_dev, st.st_ino) in inodes:
                        return True
    return False


if reads_a_secret(args, tool):
    sys.stdout.write(
        "confirm-send hook: refused — %s would read one of Moe s secrets (an API key, "
        "a sign-in token, a Keychain password or this Mac s identity). Moe s own tools "
        "use those themselves; nothing the model runs may read them.\n" % (tool or "this call"))
    sys.exit(9)

# Layer 1: the tool's own name says it sends.
SEND_NAME = re.compile(
    r"send|reply|forward|post_?message|create_draft.*send|email|sms|imessage|whatsapp"
    r"|telegram|tweet|publish|notify|react|a2a_call|\bdm\b|_dm(_|$)|^dm_|message_create"
    # Sends that carry no recipient and no body, so the shape layer cannot
    # see them at all: committing a draft, launching a campaign, enrolling
    # somebody in a sequence, flushing an outbox. The name is the only
    # evidence there is, and a false dialog on a `commit` is cheaper than a
    # silent one on somebody's mailing list.
    r"|commit|launch|trigger|enroll|dispatch|deliver|blast|outbox|campaign",
    re.I)
# A read-only verb prefix on a name with no send verb in it (search_email,
# list_whatsapp_chats) is exempted; without this the agent could not read a
# mailbox without a dialog per call.
READ_ONLY = re.compile(r"^(read|get|list|search|fetch|find|check|count|show)_", re.I)
# A channel word is not a verb. SEND_NAME above matches "telegram" and
# "whatsapp" wherever they appear, which is right for telegram_send_message
# and wrong for telegram_status — and a dialog headed "Moe wants to send a
# message", naming "(unknown recipient)" and showing `{"args": []}`, in front
# of a status check is both false and the kind of false that teaches people
# to click Send without reading. So a name carrying a plainly read-only word
# and NO send verb is exempt, wherever that word sits in the name (READ_ONLY
# above only ever matched a prefix).
# `download`, `export`, `view`, `describe`, `preview`, `retrieve` and `query`
# were added 2026-09-04 after the owner screenshotted a dialog asking whether
# GOOGLEDRIVE_DOWNLOAD_FILE could run. It fetches a file: nothing is changed,
# sent or deleted, and a confirmation for that is the kind people learn to
# click through — which costs the confirmations that matter.
#
# They are safe to add for the reason the list works at all: a read word only
# ever *permits* when WRITE_VERB finds nothing beside it, so
# GOOGLEDRIVE_DOWNLOAD_AND_UPLOAD still asks. And they are only reached for a
# tool the server has already labelled read-only — this list decides whether
# to believe an honest label, never whether to skip one that is absent.
#
# Why they were missing: the list was written when every MCP label on this Mac
# was uninformative, for the unrelated reason that Hermes read `readOnlyHint`
# by its pydantic alias and got None for all 2,029 cached tools (fork
# b5a7cc0a88). With that fixed the labels are informative and the name test
# was second-guessing correct data, against this file's own rule that the gate
# DECLARES rather than guesses. (An earlier version of this comment cited
# `docs/SEND-GATE.md`, which does not exist in this repo — a citation to a
# document nobody can open is worse than none, because it reads as authority.)
READ_ONLY_WORD = re.compile(
    r"(^|_)(status|state|health|info|history|chats|messages|unread|list|search"
    r"|read|get|fetch|find|check|count|show|pull|crawl|voice|accounts"
    r"|view|describe|preview)(_|$)", re.I)
# `download`, `export` and `retrieve` are reads — and they are also the three
# verbs that mean DATA LEAVES. A skeptical review found that putting them in
# the list above silenced `export_report({"to": …, "body": …})` completely:
# it used to raise the send dialog naming the recipient, and it passed
# silently instead. The commit's safety argument was that a read word only
# permits when WRITE_VERB finds nothing beside it — true, and beside the
# point, because WRITE_VERB is a test on the NAME and what had been disarmed
# was the test on the ARGUMENTS.
#
# So they live here instead: they make a name read-like for the purpose of
# believing an honest read-only label, and they never buy the exemption from
# `message_shaped()`. A download with a file id runs; a download with a
# recipient and a body asks, as it always did.
#
# `query` was in that list and has been dropped outright. It is the tool name
# of the reference Postgres MCP server and of most GraphQL bridges, where a
# "query" endpoint accepts mutations through the same field —
# `query({"sql": "DROP TABLE users"})` passed silently. A server author who
# marks "the query tool" read-only is describing intent, not enforcement, and
# this branch exists precisely to keep a second opinion about that.
MOVES_DATA = re.compile(r"(^|_)(download|export|retrieve)(_|$)", re.I)
#: Servers that carry OTHER people's services and therefore should be named by
#: the service rather than by themselves. Composio is one MCP server standing
#: in front of ~500 toolkits. Anything not on this list is named by its own
#: server name, which is the honest answer for a server that is only itself.
BROKERS = ("composio",)
SEND_VERB = re.compile(r"send|reply|forward|post|publish|notify|react|tweet", re.I)
# Words that mean something is being *made*, used only by the shape layer far
# below to overrule READ_ONLY_WORD. `messages_create` is why it exists: the
# read-word list has "messages" in it, correctly, so that a Telegram tool
# reading messages does not raise a dialog — and that exemption swallowed
# Twilio's send tool whole. "update" is deliberately absent: get_updates is
# how half the chat APIs spell "read".
WRITE_VERB = re.compile(
    r"create|write|compose|draft|\badd|upload|share|invite|deliver|broadcast"
    r"|push|submit|enqueue|dispatch|emit|new"
    # A name ENDING in `_message` is doing something to one, and the
    # shape layer only consults this when a recipient and a body are
    # both already in hand: `find_contact_and_message({"to", "body"})`
    # was passing silently on the strength of its first word. Plural
    # `_messages` is deliberately not matched — that is what
    # `search_messages(chat_id, text)` is called, and it is a read.
    # And a read prefix must not launder an effect: `get_delete`,
    # `list_purge`, `search_execute`, `count_down_and_launch` — a third-party
    # server names and labels its own tools, so a read word in front of a
    # destructive one is how a lying server dresses a write as a read.
    # `\b` never fires between `t` and `delete` in `get_delete` (both are
    # word chars), so the destructive set is anchored to start-or-underscore
    # instead: it must catch `_delete`, `_purge`, `_launch` after a read
    # prefix, which is the whole point.
    r"|(?:^|_)(?:delete|remove|drop|purge|wipe|revoke|disable|deactivate"
    r"|transfer|pay|charge|execute|run|launch|kill|shutdown|reset|grant"
    r"|approve|replace|move|rename|erase|destroy|terminate|cancel|deploy|publish)"
    r"|_message$|^message$", re.I)

# Layer 2 (belt-and-braces only — see header): a shell or code tool whose
# command text reaches a known send path. Connector `send` verbs confirm
# themselves (whatsapp.sh calls confirm.sh with the resolved contact name,
# for every caller), so they are deliberately absent; the hook owns
# Hermes-native/MCP tools and raw osascript/API sends.
SHELL_TOOL = re.compile(r"terminal|shell|bash|command|exec|process|code", re.I)
# The word `send` and its inflections — send, sendmail, send_email,
# send_message, sendMessage — but matched against the command with its HEREDOC
# BODIES REMOVED (strip_heredocs below). That is the whole fix for the false
# positive that started this: a note dictated for Apple Notes whose body read
# "Send agent alerts to the team, not one person's Gmail" was carried to
# osascript inside `<<'EOF' … EOF`, and the old rule read the note's own words
# as a Gmail send. The command STRUCTURE — `python3 telegram.py send @bob`,
# `s.sendmail(…)`, `curl …/messages/send` — is never inside a heredoc body, so
# stripping the body keeps every real send matchable while dropping the prose.
# (A quoted string that is NOT a heredoc, like "smtp.gmail.com" in real
# smtplib code, is deliberately kept: that IS a send.) Layer 2 stays a
# denylist over free text and stays bypassable by construction — see header.
SEND_WORD = r"\bsend\w*"
# The osascript rows match the AppleScript that addresses the app — `tell
# application "Mail"`, `tell app "Messages"`, `application id "com.apple.mail"`
# — not the word anywhere. A note whose body says `open the "Mail" app` is a
# note. Both spellings of the app name Apple accepts, either quote.
APP_MAIL = r"\bapp(?:lication)?\s+(?:id\s+)?[\"'](?:mail|com\.apple\.mail)[\"']"
APP_MESSAGES = r"\bapp(?:lication)?\s+(?:id\s+)?[\"'](?:messages|com\.apple\.(?:messages|ichat|mobilesms))[\"']"
#: An AppleScript that NAMES Mail or Messages is not thereby a send. The
#: owner hit this: he asked Moe to find an Apple Developer email and fill in a
#: reply on screen, and got a dialog headed "Email — Moe wants to send this"
#: over
#:
#:     osascript -e 'tell application "Mail" to set foundMsgs to
#:                   (messages of inbox whose subject contains "Apple Developer")'
#:
#: which reads. The tell was the recipient line: it said "(see command)",
#: because there was no recipient to find. A gate that calls a read a send
#: teaches people to click through send dialogs, which costs the ones that
#: matter — the same argument that removed the read-nag from the broker's
#: download tool.
#:
#: So the osascript rows need a third condition: an actual send verb.
#: `\bsend\b` does not match "sender", which is what a search by sender is
#: called, and that is tested. Without a verb the command falls through to the
#: ordinary path, where a read-only AppleScript passes silently — exactly as
#: the same script against Finder already does.
#:
#: WHICH verbs, measured rather than guessed. The first draft of this list
#: read `send|make new outgoing message|reply|forward|redirect|bounce`, on the
#: reasoning that those are the mail-ish verbs. Five of the six create a draft
#: and deliver nothing, and the owner hit it the same way he hit the row above
#: — he asked Moe to open a reply to an email on screen, and got a dialog
#: headed "Email — Moe wants to send this" over
#:
#:     osascript -e 'tell application "Mail"
#:                   set m to item 1 of (selection)
#:                   reply m opening window yes
#:                   end tell'
#:
#: which opens a reply window and sends nothing at all. Apple's own dictionary
#: on this Mac says so — /System/Applications/Mail.app/Contents/Resources/
#: Mail.sdef, quoted verbatim in the test:
#:
#:     reply     "Creates a reply message."       → outgoing message
#:     forward   "Creates a forwarded message."   → outgoing message
#:     redirect  "Creates a redirected message."  → outgoing message
#:     bounce    "Does nothing at all (deprecated)."
#:     send      "Sends a message."               → boolean
#:
#: and Messages.sdef has exactly one command that reaches a person, `send`.
#:
#: So: THE GATE FIRES ON DELIVERY, NOT COMPOSITION. A draft on screen is not
#: a send — it is the person's to read, edit and cancel — and nothing is lost
#: by letting it through, because the send that may follow arrives back here
#: as `send` and is gated then. `make new outgoing message` goes for the same
#: reason: its own result type is `outgoing message`, a draft.
#:
#: If a future macOS adds a delivery verb, add it here WITH ITS SDEF LINE.
#: The list is measured from the artefact, not from what the words sound like.
APPLE_SEND_VERB = r"\bsend\b"
SHELL_PATTERNS = [
    # (label, first regex, second regex[, third]) — all must appear.
    ("Messages", r"apple\.sh", r"messages"),
    ("Messages", r"osascript", APP_MESSAGES, APPLE_SEND_VERB),
    ("Messages", r"\bimsg\b", r"."),
    ("Mail",     r"osascript", APP_MAIL, APPLE_SEND_VERB),
    ("Mail",     r"\bsendmail\b", r"."),
    ("Mail",     r"\bmail\s+-s\b", r"."),
    ("Mail",     r"open\s+mailto:", r"."),
    # A real Gmail send by host, not by the ambiguous word "gmail". Structural
    # (an API endpoint / SMTP host), so it is matched against the WHOLE command
    # — a curl to gmail.googleapis.com/.../messages/send or an smtplib to
    # smtp.gmail.com inside `bash <<EOF … EOF` is a send however it is wrapped.
    ("Gmail",    r"gmail\.googleapis\.com|smtp\.gmail\.com", SEND_WORD),
    # Two deliberate narrowings on this row; connectors/gmail-send-patterns.md
    # has the measurements behind both.
    #
    # gmail(?!\.py) — Moe's own connector confirms itself, with the resolved
    # recipients, for every caller, so `gmail.py send` matching here only ever
    # added a SECOND dialog. The message travels on stdin (nothing about a
    # private message belongs in `ps`), so that first dialog could say nothing
    # but "(see command)" — the uninformative one, shown first, and the one
    # that teaches people to click Send unread. Same rule that already keeps
    # whatsapp.sh out of this list.
    #
    # \bsend, not \bsend\b — the trailing \b did not match s.send_message(m),
    # and dropping it picks up sendMail and send_email too. This NARROWS the
    # raw-smtplib path; it does not close it. Layer 2 is a denylist over
    # free-form text and stays bypassable by construction (see "Known
    # bypasses" in the header). What stands in front of that path is the
    # terminal approval policy, and nothing here changes that.
    # PROSE rows — the service name is an ordinary word, so these two (and
    # ONLY these two) match the command with here-doc BODIES STRIPPED. That is
    # the whole "a note is not a send" fix: a note whose body says "Send … one
    # person's Gmail", carried to osascript inside `<<'EOF' … EOF`, no longer
    # reads as a send. Everything else in this list is structural — a real
    # host, endpoint, command or `tell application` clause that a note body
    # does not plausibly contain — and is matched against the FULL command so
    # a send wrapped in an interpreter heredoc (`bash <<EOF … curl
    # api.telegram.org/…/sendMessage … EOF`) stays caught. The 4th field marks
    # a row as prose; see the loop below.
    # (?<!@) — an ADDRESS is data, not the service. 2026-10-06: the owner's
    # marketing monitor appended "Mail (someone@gmail.com…): no replies from
    # watched senders" to a notes file with printf, and this row read
    # "@gmail" + "senders" as a Gmail send and put a dialog in front of him.
    # A send still names the service (a gmail CLI, an API host above).
    ("Gmail",    r"(?<!@)gmail(?!\.py)", SEND_WORD, "prose"),
    ("Telegram", r"telegram", SEND_WORD, "prose"),
    # `send\w*` rather than six named methods: sendSticker, sendAnimation,
    # sendPoll, sendContact, sendLocation, sendMediaGroup and sendInvoice all
    # reach a person, and forwardMessage and copyMessage put somebody else's
    # words in front of them. A denylist over free text stays bypassable by
    # construction; being bypassable is not a reason to be incomplete.
    ("Telegram", r"api\.telegram\.org", r"send\w*|forwardMessage|copyMessage"),
    # Two bridges' worth of endpoints: lharries/whatsapp-mcp's Go bridge
    # (/api/send on :8080, what the reader used until 2026-09-11) and the
    # bundled bridge.js the reader sends through now. Every bridge.js route
    # that puts words in front of somebody or changes words already there:
    # /send, /send-media, /send-poll, /send-location, and /edit — which
    # rewrites a message the person has already been sent, so it is a send
    # of new words under an old timestamp. Not here, on purpose: /typing (a
    # "typing…" indicator, no message) and /read (a read receipt for a
    # message that arrived); /history/download, /messages, /chat/:id and
    # /health are reads.
    ("WhatsApp", r"/api/send\b|localhost:8080|:3000/(send(-media|-poll|-location)?|edit)\b", r"."),
]

RECIPIENT_KEYS = ("to", "recipient", "recipients", "chat_id", "chat", "phone",
                  "number", "email", "address", "user", "channel", "peer", "target")
# Every key a recipient can hide in, not just the first one the dialog shows.
# The self-send exemption has to look at ALL of them: "to: me, cc: someone
# else" and "to: me, recipients: [them]" are sends to other people with the
# owner's id on the front, and `to` alone would have exempted both.
RECIPIENT_ANY = RECIPIENT_KEYS + (
    "cc", "bcc", "to_list", "tos", "chat_ids", "chats", "user_id", "user_ids",
    "users", "peers", "targets", "recipient_id", "recipient_ids", "emails",
    "numbers", "phones", "addresses", "channels", "channel_id", "group",
    "group_id", "room", "room_id", "conversation", "conversation_id", "destination",
    "destinations", "send_to", "to_number", "to_email", "audience")
# A tool that names a channel of its own. The model picks both the tool and
# the recipient string, so a "telegram:" prefix handed to a WhatsApp, mail or
# Slack tool proves nothing about where the message goes.
OTHER_CHANNEL = re.compile(
    r"whatsapp|slack|discord|signal|imessage|messages|sms|mms|mail|gmail|smtp"
    r"|tweet|twitter|teams|matrix|twilio|sendgrid|linkedin|instagram|facebook"
    r"|messenger|wechat|line|viber|zulip|mastodon|bluesky|webhook", re.I)
BODY_KEYS = ("body", "message", "text", "content", "html", "caption", "msg")


# Some MCP servers take positional arguments, so the whole call arrives as
# {"args": ["dad@example.com", "Running late"]} and every key above misses.
# That is what put "(unknown recipient)" over a wall of raw JSON in front of
# people. There is no schema here to say which position is which, so the only
# thing claimed is the one that can be checked: a first element shaped like an
# address, a number or a handle is the recipient. Anything else and the
# recipient stays unnamed and every argument goes in the body — unlabelled is
# survivable, mislabelled is not.
POSITIONAL_KEYS = ("args", "arguments", "params", "positional", "input")
ADDRESSY = re.compile(r"^(?:[^@\s]+@[^@\s]+\.[A-Za-z]{2,}|[+#@][^\s]{1,64}|\d[\d ()+.-]{4,31})$")


def positional(args):
    """(recipient, body) read out of a positional argument list, or (None, None)."""
    for key in POSITIONAL_KEYS:
        value = args.get(key)
        if not isinstance(value, (list, tuple)) or not value:
            continue
        items = [v for v in value if not isinstance(v, (list, dict))]
        if len(items) != len(value):
            return "", "\n\n".join(stringify(v) for v in value)
        first = str(items[0]).strip()
        if ADDRESSY.match(first) and len(items) > 1:
            return first, "\n\n".join(str(v) for v in items[1:])
        return "", "\n\n".join(str(v) for v in items)
    return None, None


# How deep a recipient can hide. Microsoft Graph's sendMail is the case that
# forced this: the whole call is one `message` envelope, and the addresses are
# at message.toRecipients[].emailAddress.address — four levels down. A flat
# scan of the top-level keys found no recipient at all and fell back to
# printing the raw JSON, so the dialog asking a person to approve an email to
# their client showed "(unknown recipient)" over a wall of braces. Anything
# that nests deeper than this is not a shape a person can read anyway.
NEST_DEPTH = 5
# Enough for a real cc list; a cap only so a malformed structure cannot make
# the dialog unbounded.
MAX_LEAVES = 60


def norm(key):
    """`toRecipients`, `to_recipients` and `TORECIPIENTS` are one key."""
    return re.sub(r"[^a-z0-9]", "", str(key).lower())


# The same key sets as above, normalised, plus the names that only ever appear
# nested — Graph's envelope, and the id fields Teams and Slack address with.
RECIPIENT_NORM = {norm(k) for k in RECIPIENT_ANY} | {
    "torecipients", "ccrecipients", "bccrecipients", "replyto",
    "emailaddress", "teamid", "threadid", "topicid",
    # Names taken from the products themselves rather than guessed: Zoom Chat
    # (`to_contact`, `to_channel`), Discord webhooks, Linear, Notion, the CRMs
    # whose "send" is enrolling a person in a sequence, and the phone-number
    # spellings the SMS APIs use. Each of these was a silent pass.
    "tocontact", "tochannel", "webhookid", "webhookurl", "issueid", "pageid",
    "contactid", "leadid", "subscriberid", "listid", "toaddresses",
    "entityid", "handle", "username", "mobile", "msisdn", "personalizations",
    "conversationsid", "recipientemail", "recipientphone", "sendto",
    "phonenumber", "touser", "memberid", "participants", "participantids",
    "assignee", "assignees", "watchers", "mentions", "audienceid",
    # The people on a calendar invitation. An event with guests sends each
    # of them an invitation the moment it is created, which is a message
    # with their address on it, whatever the tool is called.
    "attendees", "guests", "invitees"}
# Where a reply LANDS, as opposed to who it reaches. These are recipient keys
# for the shape test — a reply into a thread with nobody else named is still
# a send — and are never shown as people. Gmail's thread ids are sixteen hex
# characters, and one led the To line of a real dialog on 2026-09-06,
# unlabelled and first, ahead of the two addresses the mail was actually for:
# "1a05a812ba8f8b99, recipient_email: …, cc: …".
CONTEXT_NORM = {"threadid", "topicid"}
BODY_NORM = {norm(k) for k in BODY_KEYS} | {
    # What a message is called when it is not called "body". `value` is
    # SendGrid's — `content: [{type, value}]` — where the recipient WAS being
    # found and the words were not, so the whole call went through silently.
    "payload", "markdown", "md", "richtext", "plaintext", "value", "note",
    "comment", "summary", "blocks", "attachments", "pretext", "fallback",
    "description", "templateid", "template", "htmlbody", "textbody",
    "messagetext", "messagebody", "bodytext", "bodyhtml", "contenttext"}


def flatten(value, out, depth=0):
    """Every scalar under `value`, in order. Used for recipients, where a
    container is a list of people and all of them have to be shown."""
    if len(out) >= MAX_LEAVES or depth > NEST_DEPTH:
        return
    if isinstance(value, dict):
        for item in value.values():
            flatten(item, out, depth + 1)
    elif isinstance(value, (list, tuple)):
        for item in value:
            flatten(item, out, depth + 1)
    elif value is not None and value is not True and value is not False and value != "":
        # `not in (None, "", True, False)` dropped the integers 0 and 1,
        # because 1 == True in Python. A chat id of 1 is a chat id.
        out.append(str(value))


def deep_collect(value, depth=0, recipients=None, bodies=None, subjects=None, trail=()):
    """Recipients, a body and a subject, from anywhere in the call.

    A recipient key is flattened wherever it is found — a list of address
    objects is still a list of people. A body key is only believed when it
    holds *text*: `{"body": {"contentType": "Text", "content": "…"}}` is an
    envelope, not a message, so it is walked into rather than printed as JSON.
    That one distinction is what turns Graph's sendMail from a wall of braces
    into a subject, a recipient and the words.

    Each body is (priority, depth, text, path) and each subject (text, path):
    `path` is the list of keys and indexes from the top of the call down to
    the field, so that a message a person REWROTE in the dialog can be put
    back exactly where it came from. A body that was assembled — a list of
    scalars joined with newlines — has no single place to go back to, and
    its path is None.
    """
    recipients = [] if recipients is None else recipients
    bodies = [] if bodies is None else bodies
    subjects = [] if subjects is None else subjects
    if depth > NEST_DEPTH or not isinstance(value, dict):
        return recipients, bodies, subjects
    for key, item in value.items():
        if item in (None, "", [], {}, ()):
            continue
        name = norm(key)
        here = list(trail) + [key]
        if name in RECIPIENT_NORM:
            leaves = []
            flatten(item, leaves)
            if leaves:
                recipients.append((key, ", ".join(leaves)))
            continue
        if name == "subject" and isinstance(item, str):
            subjects.append((item, here))
            continue
        # Not `isinstance(item, str)`: a body arriving as ["hi"] or as 12345
        # was invisible to the shape layer, and both are what a real client
        # sends. A container under a body key is still walked (an envelope is
        # not a message), but a list of scalars is a message in pieces.
        if name in BODY_NORM and isinstance(item, (str, int, float)):
            bodies.append((BODY_KEYS.index(key.lower()) if key.lower() in BODY_KEYS
                           else len(BODY_KEYS), depth, str(item),
                           here if isinstance(item, str) else None))
            continue
        if name in BODY_NORM and isinstance(item, (list, tuple)) \
                and item and all(isinstance(x, (str, int, float)) for x in item):
            bodies.append((len(BODY_KEYS), depth,
                           "\n".join(str(x) for x in item), None))
            continue
        if isinstance(item, dict):
            deep_collect(item, depth + 1, recipients, bodies, subjects, here)
        elif isinstance(item, (list, tuple)):
            for index, entry in enumerate(item[:MAX_LEAVES]):
                if isinstance(entry, dict):
                    deep_collect(entry, depth + 1, recipients, bodies, subjects, here + [index])
    return recipients, bodies, subjects


def readable(value, indent=0):
    """`{"emoji": "❤️"}` as `emoji: ❤️`, not as JSON.

    What a tool with no recognisable body is passing still has to be readable:
    a person approving `react_to_message` was being shown a pair of braces and
    a quoted key, which is a dialog that tells them nothing they can act on.
    """
    pad = "  " * indent
    if isinstance(value, dict):
        lines = []
        for key, item in value.items():
            if isinstance(item, (dict, list, tuple)):
                lines.append("%s%s:" % (pad, key))
                lines.append(readable(item, indent + 1))
            else:
                lines.append("%s%s: %s" % (pad, key, item))
        return "\n".join(lines)
    if isinstance(value, (list, tuple)):
        return "\n".join(readable(item, indent) for item in value)
    return "%s%s" % (pad, value)


# `send_message` addresses every platform through one string — "teams:#eng",
# "slack:#general", "signal:+1555…". The prefix is the service, and without it
# the dialog headed every cross-platform send "Send message" with no mark on
# it, whatever it was going out on. Teams, Slack, Discord, Matrix, ntfy and
# the rest all arrive this way.
#
# The list is closed, and it is Hermes's own: plugins/platforms/*. A prefix is
# only a service if it names one. Accepting any word before a colon meant the
# dialog took the label off a composed recipient line — "cc: a@b.com" was
# headed "Cc", over a monogram, with the word "cc" then STRIPPED from the To
# line, so a person could no longer tell a cc from a primary recipient. A
# "mailto:" or "https:" recipient did the same. The dialog removes what this
# says the service is, so this may only ever say something true.
PLATFORMS = {
    "a2a", "buzz", "dingtalk", "discord", "email", "feishu", "google_chat",
    "homeassistant", "imessage", "irc", "line", "matrix", "mattermost", "ntfy",
    "photon", "raft", "signal", "simplex", "slack", "sms", "teams", "telegram",
    "wecom", "whatsapp", "yuanbao", "gmail", "outlook",
}
PLATFORM_PREFIX = re.compile(r"^([A-Za-z][A-Za-z0-9_.-]{1,24}):")


def service_of(recipient, tool_name):  # noqa: C901 — reads top to bottom
    """The platform named by the recipient itself, or "".

    Given the FIRST raw recipient, never the composed "to" line the dialog
    shows — that line carries our own `cc:`/`bcc:` labels, and reading a
    label as a service is how the dialog came to be headed "Cc".
    """
    hit = PLATFORM_PREFIX.match((recipient or "").strip())
    if not hit:
        return ""
    name = hit.group(1).lower()
    if name not in PLATFORMS:
        return ""
    # And it must not contradict the tool. `gmail_send_email` with a
    # recipient of "telegram:dad@example.com" drew Telegram's mark and name
    # over an email — the model wrote both halves, so a prefix that disagrees
    # with the tool proves nothing.
    other = OTHER_CHANNEL.search(tool_name or "")
    if other and other.group(0).lower() != name:
        return ""
    return name


def stringify(v):
    if isinstance(v, (list, tuple)):
        return ", ".join(stringify(x) for x in v)
    if isinstance(v, dict):
        return json.dumps(v, ensure_ascii=False)
    return str(v)


def telegram_self_ids():
    """The owner's Telegram ids, from the owner record (tools/recipients.py):
    the first id in Hermes's TELEGRAM_ALLOWED_USERS and a private home channel,
    only when a bot token is configured at all — the same rule as Moe's
    TelegramSelf.target (Sources/MoeMeeting/MeetingLive.swift). An unreadable
    record means no owner route, which is the closed direction."""
    try:
        R = _recipients()
        return [t for t in R.load_owner().get("telegram", []) if t and not t.startswith("-")]
    except Exception:
        return []


def is_self_telegram(tool_name, args, recipient):
    """True for a Telegram message addressed to the owner themselves — the owner
    ROUTE, which needs no dialog and is never refused.

    Why this one hole exists: after a meeting, Moe pushes the notes the
    agent just wrote to the user's own Telegram, so they are on the phone
    without having to ask. A dialog there confirms nothing — the human is
    the sender AND the only recipient, and being asked "send your own notes
    to yourself?" after every call teaches people to click Send without
    reading, which is exactly what makes the gate worthless for the sends
    that matter. Every other recipient still gets the dialog.

    Deliberately narrow, and every test below is a way it was widened:

      - EXACTLY ONE recipient field may be present, out of every key a
        recipient can hide in (RECIPIENT_ANY, cc/bcc included), and it must
        hold exactly one scalar id. `{"to": "555", "cc": "999"}` is a send
        to 999.
      - The id must be that one string, whole: no internal whitespace to
        reassemble, no comma, no second colon, no "+"/leading zeros — only
        an exact match against the FIRST entry in TELEGRAM_ALLOWED_USERS.
      - A negative id is a Telegram group or channel, i.e. other people,
        never the owner — never exempt however it is configured.
      - The channel must be Telegram AND must not be anything else: a
        "telegram:555" recipient on send_whatsapp_message or
        gmail_send_email is asked, because the model wrote both halves.

    moe-home/hermes/tests/test-confirm-hook.sh pins all of these.
    """
    owns = [o.lstrip("@") for o in telegram_self_ids() if o.lstrip("@")]
    if not owns:
        return False

    # One recipient, in one field — counted the way the rest of this file now
    # counts, which is at every depth. Checking only the top level while the
    # dialog walked the whole structure meant
    # `{"chat_id": <you>, "payload": {"cc": [<someone else>], "text": …}}`
    # was a note to self with a stranger on the cc, and it passed without a
    # dialog. The exemption is for a message to yourself and nobody else; one
    # recipient anywhere else in the call ends it.
    deep_to, _, _ = deep_collect(args)
    if len(deep_to) != 1:
        return False
    present = [k for k in RECIPIENT_ANY if args.get(k) not in (None, "", [], {}, ())]
    if len(present) != 1:
        return False
    value = args[present[0]]
    if isinstance(value, (list, tuple)):
        if len(value) != 1:
            return False
        value = value[0]
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return False
    text = str(value).strip()
    # Anything that has to be normalised to match is not a match: a space,
    # a comma or a semicolon can hide a second recipient.
    if not text or re.search(r"[\s,;]", text):
        return False
    # The recipient the dialog would have shown must be this same one — if
    # the classifier picked a different field, we are not looking at the
    # send the exemption is about.
    if re.sub(r"\s+", " ", recipient or "").strip() != text:
        return False

    tl = (tool_name or "").lower()
    if OTHER_CHANNEL.search(tl):
        return False
    prefixed = text.lower().startswith("telegram:")
    if not prefixed and "telegram" not in tl:
        return False
    ident = text.split(":", 1)[1] if prefixed else text
    if not ident or ":" in ident or ident.startswith("-"):
        return False
    return ident.lstrip("@") in owns


def _plain_site(host):
    return re.sub(r"^www\.", "", host or "") or "this site"


def _headed(headline, body):
    """The card's one-line headline ahead of its body. The shell takes it off
    by the leading \\x1d, which no body can start with (every writer strips
    the body, and \\x1d is whitespace to str.strip)."""
    line = re.sub(r"[\s\x1d\x1e]+", " ", headline or "").strip()[:160]
    return ("\x1d%s\n%s" % (line, body)) if line else body


def emit(channel, to, body, raw="", first_recipient="", edits=None, headline=""):
    # Recipient on one line no matter what came in; body may span lines.
    # `raw` is the tool id verbatim: the dialog prints it small, under the
    # buttons, so what asked is findable without being the headline. The
    # service line is which mark and name the dialog draws.
    #
    # `edits` is where the words live in the call — {"body": path,
    # "subject": path, "composed_subject": bool} — written as one line of
    # JSON between the recipient and the body. The shell reads it only for a
    # SEND, hands the dialog "edit=no" when there is no body path, and when
    # the person rewrites the message puts the new words back at that path
    # and answers Hermes with a modified call. A send with nowhere to write
    # the words back to is still shown, read-only.
    #
    # That used to be read off the recipient's platform prefix alone, "since
    # one tool sends to all of them" — true of the Telegram/Slack/Signal
    # senders and FALSE of a broker, where the recipient is a bare email
    # address with no prefix at all. Which is why this path kept saying
    # "Composio" after the act dialog had been taught otherwise: the fix was
    # only ever applied to one of the two.
    to = re.sub(r"\s+", " ", to).strip() or "(unknown recipient)"
    body = body.strip() or "(empty message)"
    kit_slug, kit_label = broker_toolkit()
    where = {"body": None, "subject": None, "composed_subject": False}
    where.update(edits or {})
    if globals().get("PROVENANCE"):
        # Who named this person, for the dialog (confirm.sh hands it on as
        # MOE_CONFIRM_PROVENANCE). Rides in this JSON line so the SEND
        # record keeps its shape.
        where["provenance"] = globals()["PROVENANCE"]
    sys.stdout.write("SEND\n%s\n%s\n%s\n%s\n%s\n%s" % (
        (kit_label or channel).replace("\n", " "),
        (raw or tool).replace("\n", " "),
        kit_slug or service_of(first_recipient or to, tool),
        to, json.dumps(where, ensure_ascii=True), _headed(headline, body)))
    sys.exit(0)


# Layer 3: computer_use (Hermes's eyes-and-hands tool). A click cannot be
# told from a send — the hook sees "click at 812,640", not "the Send button"
# — so what IS gated here is the keyboard: Return/Enter (what sends in Mail,
# Messages, Slack, WhatsApp Web, every chat box) and typed text containing a
# newline (the same key by another route). Everything else is on the model:
# CLAUDE.md tells it to ask before Return and before Send-like buttons.
# Also gated, in every mode: quitting the front app (cmd+q) and the Force
# Quit dialog (cmd+option+esc) — the native backend refuses the latter
# outright, but cua-driver does not, and quitting loses unsaved work.
#   MOE_COMPUTER_USE_CONFIRM=every    also gate click/drag/scroll/type/set_value
#   MOE_COMPUTER_USE_CONFIRM=shortcuts gate only cmd/ctrl+Return, not plain Return
#   MOE_COMPUTER_USE_CONFIRM=return   (default) gate every Return/Enter + newlines
# The browser presses keys too: `press_key("Enter")` inside browser_exec (or
# Input.dispatchKeyEvent through browser_cdp) is the same act `computer_use
# key` is gated for, through a different door. Typed text with a newline in
# it is the same key by another route, exactly as it is for computer_use.

# ── A broker's multiplexer: judged by what is inside it ──────────────────────
#
# COMPOSIO_MULTI_EXECUTE_TOOL is one tool name carrying any of ~500 services'
# tools, so its own name and label say nothing about a given call. The server
# marks it "not read-only", which is true of the envelope and false of most
# of what travels in it. Judged as one tool, every Gmail search and Drive
# lookup through it raised the act dialog ("Google Drive changes things"),
# and the one answer that silenced those — "Always allow" on the multiplexer
# — would have silenced a Sheets rewrite and a calendar invitation with
# them. So the envelope is opened and each tool inside is judged by ITS
# name and ITS arguments, with a policy entry of its own:
#
#   a send verb in the slug, or a share, or an invitation                → send
#   a recipient and something to say in its arguments (not a read)      → send
#   a draft — written, not sent, even with a recipient and a body       → act
#   a read word in the slug and no write verb                           → runs
#   anything else                                                       → act,
#      remembered per slug: allowing GOOGLESHEETS_BATCH_UPDATE says
#      nothing about GMAIL_SEND_EMAIL
#
# The verdict for the batch is the strongest of its parts: one send in the
# list and the Send sheet is shown; otherwise one act and the act dialog is;
# only a list of nothing but reads runs unasked. An item with no slug cannot
# be judged, so the batch asks. A whole-multiplexer allow from before this
# existed still covers the acts inside it, as it did; it never covered sends.
BROKER_SEND = re.compile(
    r"(^|_)(send|reply|forward|post|publish|notify|react|tweet"
    r"|share|sharing|invite|invitation)(_|$)", re.I)
BROKER_DRAFT = re.compile(r"(^|_)drafts?(_|$)", re.I)


def batch_items():
    """[(slug, arguments)] declared in a broker multiplexer call; [] when
    this is not one; None when an item carries no slug to judge it by."""
    if server not in BROKERS:
        return []
    listed = args.get("tools")
    if not isinstance(listed, list) or not listed:
        return []
    out = []
    for item in listed:
        if not isinstance(item, dict):
            return None
        slug = item.get("tool_slug") or item.get("slug") or item.get("name")
        if not isinstance(slug, str) or not slug.strip():
            return None
        inner = item.get("arguments")
        out.append((slug.strip(), inner if isinstance(inner, dict) else {}))
    return out


def shaped(inner):
    """The same test message_shaped() makes, on one tool's own arguments."""
    found_to, found_body, _ = deep_collect(inner)
    if found_to and found_body:
        return True
    pos_to, pos_body = positional(inner)
    return bool(pos_to and pos_body)


def slug_kind(slug, inner, policy, envelope_allowed):
    """(kind, policy key, why) for one tool inside a broker's batch."""
    key = "mcp__%s__%s" % (server, sanitize(slug))
    ptools = policy.get("tools")
    rule = (ptools if isinstance(ptools, dict) else {}).get(key)
    rule = rule if isinstance(rule, dict) else {}
    allowed = rule.get("decision") == "run" or envelope_allowed
    reads = bool((READ_ONLY.match(slug) or READ_ONLY_WORD.search(slug)
                  or MOVES_DATA.search(slug)) and not WRITE_VERB.search(slug))
    if BROKER_SEND.search(slug):
        return "send", key, "its name says it sends"
    if BROKER_DRAFT.search(slug):
        if allowed:
            return "run", key, "you allowed this tool"
        return "act", key, "it writes a draft — nothing is sent"
    if shaped(inner) and not reads:
        return "send", key, "it carries a recipient and something to say"
    if rule.get("decision") == "ask":
        return "act", key, "you asked to be asked about this tool"
    if reads:
        return "read", key, "its name reads like a read"
    if allowed:
        return "run", key, "you allowed this tool"
    return "act", key, "it is not a read, and nothing has said it only reads"


# ── Who this is going to, and who named them ─────────────────────────────────
#
# Incident, 2026-09-25: a scheduled job told "send ONE WhatsApp message to
# Jordan" (the owner) called whatsapp_send(to="Walter Brennan") — the
# owner's grandfather, the one WhatsApp contact the memory in the system
# prompt mentioned. No lookup came first. Every layer of this file judged
# the call correctly as a send, and the connector would have shown a dialog
# naming a real chat. Nothing could see that nobody had asked for him.
#
# So two questions, before any message is shown to anybody, answered by
# tools/recipients.py for this hook and for the connectors alike:
#
#   * Is every recipient the OWNER? Then it is refused: a contact tool never
#     messages the owner; `reach_owner` does. The owner is data — owner.json
#     and the accounts this Mac is linked as — not a Telegram special case.
#   * Is each recipient GROUNDED? Named in the person's own words for this
#     conversation (the job's words, for a job), or returned by a lookup
#     during it. A name that exists only in memory or the system prompt is
#     refused back to the model: look it up, or ask.
#
# The words and lookups are written by Hermes (agent/recipient_grounding.py)
# under the conversation's key. With no ledger for this call — an older
# Hermes, or a runtime that does not keep one — nothing is refused for
# grounding, and the dialog says Moe could not check where the name came from.
#
# Only keys that address a PERSON are grounded. A thread, a channel id, an
# issue or a webhook is where a message lands, not somebody chosen.
PERSON_NORM = {norm(k) for k in (
    "to", "recipient", "recipients", "chat_id", "chat", "phone", "number", "email",
    "address", "user", "peer", "target", "cc", "bcc", "to_list", "tos", "chat_ids",
    "chats", "user_id", "user_ids", "users", "peers", "targets", "recipient_id",
    "recipient_ids", "emails", "numbers", "phones", "addresses", "destination",
    "destinations", "send_to", "to_number", "to_email", "toRecipients", "ccRecipients",
    "bccRecipients", "emailAddress", "to_contact", "handle", "username", "mobile",
    "msisdn", "recipient_email", "recipient_phone", "phone_number", "to_user",
    "attendees", "guests", "invitees", "participants", "participant_ids")}
PROVENANCE = None


def _recipients():
    """tools/recipients.py, beside the hook's toolbelt. A helper that cannot be
    found is an ImportError, and the hook's answer to an exception is to block."""
    tools_dirs = []
    if SCRIPT_DIR:
        tools_dirs.append(os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "tools")))
    tools_dirs.append(os.path.join(MOE_HOME, "tools"))
    for d in tools_dirs:
        if os.path.isfile(os.path.join(d, "recipients.py")):
            if d not in sys.path:
                sys.path.insert(0, d)
            break
    import recipients
    return recipients


# Hermes's own send_message takes a `target`. Bare, it is a DELIVERY ROUTE —
# `telegram` (that platform's home channel), `moe`, `origin`, `local` — where
# Hermes already delivers to its owner, and it is not grounded. But
# `platform:<chat id or name>` addresses somebody chosen, exactly as a
# connector's `to` does, so it is grounded like one; the only exemption is
# the platform's own home channel (TELEGRAM_HOME_CHANNEL, … in Hermes's .env)
# when that home is the owner's own chat — the route spelled out. (The owner's own Telegram id is the owner
# route and passes with no dialog — is_self_telegram.)
ROUTE_KEYS = {"send_message": {"target"}}
ROUTE_ONLY = {"moe", "origin", "local", "cli"}


def home_channels():
    """{platform: {home refs}} from Hermes's .env and this process's environment."""
    R = _recipients()
    henv = R._env_file(os.path.join(HERMES_HOME, ".env")) if HERMES_HOME else {}
    out = {}
    for src in (henv, os.environ):
        for key, value in src.items():
            m = re.fullmatch(r"([A-Z0-9_]+?)_HOME_(?:CHANNEL|ADDRESS)", str(key))
            if not m or not str(value).strip():
                continue
            plat = m.group(1).lower()
            if plat.endswith("_cloud"):
                plat = plat[:-len("_cloud")]
            for v in R.split_recipients(value):
                out.setdefault(plat, set()).update({v.strip(), v.strip().split(":")[0]})
    return out


def route_person(value):
    """The person a send_message target addresses, or None for a route."""
    t = str(value or "").strip()
    plat, sep, ref = t.partition(":")
    plat, ref = plat.strip().lower(), ref.strip()
    if not sep or not ref or plat in ROUTE_ONLY:
        return None
    homes = home_channels().get(plat, set())
    chat = ref.split(":")[0]
    if (ref in homes or chat in homes) and owner_home(plat, chat):
        return None
    return t


def owner_home(plat, chat):
    """Whether a home channel is the OWNER's own chat. A home channel is
    only where Hermes delivers — it can be a group or a contact — so it is
    exempt from grounding only when it is one of the owner's own addresses."""
    try:
        R = _recipients()
        return bool(R.owner_match("%s:%s" % (plat, chat), R.load_owner()))
    except Exception:
        return False


# A Slack DM is addressed by `channel` (a D… conversation, or a U…/W… user id
# Slack opens one for), which is otherwise where a message lands: on a Slack
# send, a `channel` holding one of those ids is a person.
SLACK_DM_ID = re.compile(r"^[DUW][A-Z0-9]{8,}$")
SLACK_CHANNEL_KEYS = {"channel", "channel_id", "channelid", "conversation", "conversation_id"}


def slack_call():
    names = [bare] + [str((i or {}).get("tool_slug") or (i or {}).get("slug") or "")
                      for i in (args.get("tools") if isinstance(args.get("tools"), list) else [])
                      if isinstance(i, dict)]
    return any(re.match(r"(?i)^slack_", n or "") for n in names)


def person_recipients():
    """Every person this call addresses, one address each."""
    R = _recipients()
    found_to, _, _ = deep_collect(args)
    routes = ROUTE_KEYS.get(bare, set()) if own else set()
    vals = []
    for key, value in found_to:
        if key in routes:
            for v in R.split_recipients(value):
                person = route_person(v)
                if person:
                    vals.append(person)
        elif norm(key) in PERSON_NORM:
            vals.extend(R.split_recipients(value))
    if slack_call():
        for key, value in deep_pairs(args):
            if norm(key) in SLACK_CHANNEL_KEYS and isinstance(value, str) and SLACK_DM_ID.match(value.strip()):
                vals.append(value.strip())
    if not found_to:
        pos_to, _ = positional(args)
        if pos_to:
            vals.extend(R.split_recipients(pos_to))
    out = []
    for v in vals:
        if v not in out:
            out.append(v)
    return out


def deep_pairs(value, depth=0):
    """Every (key, value) in a structure, at every depth."""
    if depth > 8:
        return
    if isinstance(value, dict):
        for k, v in value.items():
            yield k, v
            yield from deep_pairs(v, depth + 1)
    elif isinstance(value, list):
        for v in value[:200]:
            yield from deep_pairs(v, depth + 1)


def recipient_gate(people=None):
    """Refuse a message to the owner, or to someone nobody named; otherwise
    note who named them for the dialog. Does not return on a refusal. A
    helper that cannot be found or crashes is an exception, and the hook's
    answer to an exception is to block. (A connector send is judged again, and
    its ticket minted in memory, by the moe-connectors plugin that starts the
    connector — tools/recipients.py, "tickets".)"""
    global PROVENANCE
    R = _recipients()
    people = person_recipients() if people is None else people
    if not people:
        return
    verdict = R.gate(people, session_id=str(payload.get("session_id") or ""))
    if verdict["verdict"] == "refuse":
        refuse_send(people[0], verdict["message"])
    PROVENANCE = verdict["provenance"]


def refuse_send(who, message):
    sys.stdout.write("REFUSE\n%s\n%s\n-\n%s\n%s\n" % (
        bare.replace("\n", " "), tool.replace("\n", " "),
        re.sub(r"\s+", " ", str(who)).strip()[:200], message))
    sys.exit(0)


def message_text():
    """The words of a send, as the connector will receive them."""
    for key in ("text", "body", "message", "content"):
        value = args.get(key)
        if isinstance(value, str):
            return value
    return ""


# ── A connector send, run from a shell or from code ────────────────────────
#
# Refused, always: `whatsapp.sh send`, `gmail.py send`, `telegram.py send` and
# `whatsapp.sh send-offer` from a shell or a code tool, however it is quoted,
# wrapped or prefixed. The tools (whatsapp_send, gmail_send, telegram_send) are
# the one door: the plugin behind them judges the send and mints its ticket in
# memory. From a shell there is no ticket, so the connector would refuse anyway
# — but refusing here also stops the rest of a compound command riding along
# (`whatsapp.sh send-offer o1; osascript …`), which one pass for the whole line
# would have let through.
CONNECTOR_NAMED = re.compile(r"(whatsapp\.sh|gmail\.py|telegram\.py)", re.I)
SEND_AS_WORD = re.compile(r"(?<![\w-])send(?:-offer)?(?![\w-])", re.I)
CONNECTOR_TOOL = {"whatsapp": "whatsapp_send", "gmail": "gmail_send", "telegram": "telegram_send"}
# Who asked for a job is recorded only from the app's Jobs card.
JOB_GROUNDING = re.compile(r"set_job_grounding|grounding_words|job-grounding\.py|reminders\.py[^\n;|&]*\bkeep\b",
                           re.I)


# The WhatsApp bridge Hermes runs has an HTTP door of its own on loopback
# (bridge.js: POST /send, /send-media, /send-poll, /send-location, /edit on
# port 3000, or the configured bridge_port). A request to it from a shell or
# from code is a send with no gate at all, so it is refused by WHAT it does —
# any client (curl, wget, python, node, nc) naming a loopback host and one of
# those paths — never by the name of the tool that does it. A port spelled
# out that is not the bridge's is some other server.
LOOPBACK = r"(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[?::1\]?|0x7f000001|2130706433)"
BRIDGE_HOST = re.compile(r"(?<![\w.-])" + LOOPBACK + r"(?::(\d{1,5}))?", re.I)
BRIDGE_PATH = re.compile(r"/(?:send(?:-media|-poll|-location)?|edit)(?![\w-])", re.I)


def bridge_ports():
    ports = {"3000"}
    for key in ("MOE_WHATSAPP_BRIDGE_URL", "WHATSAPP_BRIDGE_URL"):
        m = re.search(r":(\d{1,5})(?:/|$)", os.environ.get(key, ""))
        if m:
            ports.add(m.group(1))
    for key in ("WHATSAPP_BRIDGE_PORT",):
        if os.environ.get(key, "").isdigit():
            ports.add(os.environ[key])
    return ports


def bridge_send(cmd):
    """Whether a command talks to the WhatsApp bridge's send endpoints."""
    text = cmd or ""
    if not BRIDGE_PATH.search(text):
        return False
    ports = bridge_ports()
    for m in BRIDGE_HOST.finditer(text):
        if m.group(1) is None or m.group(1) in ports:
            return True
    return False


def connector_send(cmd):
    """The connector a command runs the send verb of, or ""."""
    m = CONNECTOR_NAMED.search(cmd or "")
    if not m or not SEND_AS_WORD.search(cmd or ""):
        return ""
    name = m.group(1).split(".")[0].lower()
    # gmail.py and telegram.py are common names; they are Moe's only where the
    # command says so (its connectors directory, or Moe's home).
    if name != "whatsapp" and not re.search(r"connectors|\.moe\b|application support/moe", cmd, re.I):
        return ""
    return name


def one_door(cmd):
    """Refuse the shell or code calls that would send around the tools: a
    connector's send verb, the WhatsApp bridge's HTTP door, and writing who
    asked for a job."""
    _conn = connector_send(cmd)
    if _conn:
        refuse_send("(%s send from a shell)" % _conn,
                    "Not sent: a connector send is never run from a shell or from code. Use the %s "
                    "tool (or whatsapp_send / gmail_send / telegram_send), which checks who it goes to "
                    "and asks the person." % CONNECTOR_TOOL.get(_conn, _conn + "_send"))
    if bridge_send(cmd):
        refuse_send("(the WhatsApp bridge from a shell)",
                    "Not sent: the WhatsApp bridge is never called directly from a shell or from code. "
                    "Use the whatsapp_send tool, which checks who it goes to and asks the person.")
    if JOB_GROUNDING.search(cmd):
        refuse_send("(who asked for a job)",
                    "Not done: who asked for a scheduled job is recorded only when the person answers on "
                    "the Jobs card in the Memoe app. Nothing Moe runs may write it.")



# The same, one step removed: a file written now and run later. write_file
# and patch carry the program as their content, and a script that POSTs to
# the bridge (or runs the send verb of a connector) is refused when it is
# written, since the run that follows may look like nothing at all.
WRITE_TOOL = re.compile(r"^(?:write_file|patch|edit_file|str_replace\w*|apply_patch|create_file|append_file)$", re.I)
WRITE_CONTENT_KEYS = ("content", "contents", "text", "new_string", "new_str", "patch", "diff",
                      "replacement", "new_text", "data", "body")
if WRITE_TOOL.match(bare):
    one_door("\n".join(stringify(v) for k, v in deep_pairs(args)
                       if norm(k) in {norm(x) for x in WRITE_CONTENT_KEYS} and isinstance(v, str)))

# ── Browser: a new account, with a password Moe makes (ticket #17) ────────────
#
# Two calls make one: `browser_vault_login` with mode=signup (the entry point
# the fork tells the model to use for any sign-up form) and
# `browser_vault_save_login` with generate=true (the older route). Either way
# Moe makes a strong password itself and keeps it, to sign the person up
# somewhere new. Nobody typed anything, so nothing has been agreed — and an
# account in their name on a site they never saw is not something a model
# gets to decide. Asked EVERY time, as a plain send card: no "Always allow",
# no one-hour class grant, and ahead of Layer D, so no policy entry can wave it
# through either. One yes is one site.
#
# Only a call that can work is asked about. The fork refuses a signup with no
# page address or no email/username, and a mode it does not know, without
# doing anything (tools/browser_vault_tool.py); a card for one of those is a
# yes to something that then fails, which is what the owner met on
# 2026-09-29 ("Was there a password created? Why didn't it work?"). Those run
# unasked, fail on their own, and the model is told why.
#
# Everything else the vault does needs no card here: mode=login fills a saved
# login or asks the person in Moe's own password window (moe-secret), which
# names the site and saves nothing unless they type and press Save; a login
# the person typed (save_login without generate) is the same window;
# confirm/regenerate/discard finish or undo a signup already agreed to; and
# `browser_vault_fill` / `browser_vault_enter_code` type a saved login or a
# code, rows in BUILTIN ("keys").
_SIGNUP_MODES = frozenset({"signup", "sign-up", "sign_up", "new", "register", "create"})


def _truthy(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v != 0
    return isinstance(v, str) and v.strip().lower() in ("1", "true", "yes", "on")


def _vault_account_site(a):
    """The host of the call's own page address, or "" — the fork binds the
    new login to exactly that page and refuses without one."""
    v = a.get("url")
    if isinstance(v, str):
        m = re.search(r"^\s*https?://([^/\s?#'\"<>]+)", v)
        if m:
            return m.group(1).lower()
    return ""


def _vault_new_account(name, a):
    """(site, account) when this call makes a new account with a password
    Moe makes and can actually do so; None otherwise."""
    if not isinstance(a, dict):
        return None
    if name == "browser_vault_login":
        mode = str(a.get("mode") or "login").strip().lower()
        if mode not in _SIGNUP_MODES:
            return None   # a sign-in, or a mode the fork refuses
    elif name == "browser_vault_save_login":
        if not _truthy(a.get("generate")):
            return None   # the person types it, in Moe's own window
    else:
        return None
    site = _vault_account_site(a)
    who = a.get("username")
    who = re.sub(r"\s+", " ", who).strip() if isinstance(who, str) else ""
    if not site or not who:
        return None       # the fork refuses this and does nothing
    return site, who[:120]


_account = _vault_new_account(bare, args)
if _account:
    _site, _who = _account
    _where = _plain_site(_site)
    _body = ("Moe will make a strong password and keep it for you — you won\u2019t need to type it. "
             "Saying yes covers %s only.\n\n"
             "Email or username: %s" % (_where, _who))
    sys.stdout.write("SEND\n%s\n%s\n%s\n%s\n%s\n%s" % (
        "browser account", bare, "chrome", _site,
        json.dumps({"body": None, "subject": None, "composed_subject": False}),
        _headed("Create an account on %s?" % _where, _body)))
    sys.exit(0)


# ── Moe's own settings, and connecting a service ─────────────────────────────
# Text Moe read (a page, an email, a chat message) can ask for a tool call. So
# a change to one of Memoe's settings runs without a dialog only when it makes
# Moe do, say or listen less, or only changes how an answer is shown; any
# other change — speech or nudges on, quiet hours off, a longer listening
# window, a new talk key — asks the person, as a send does. Connecting a
# service always asks. moe-bd's review, 2026-11-14 (docs/SETTINGS-ASSISTANT.md).
#
# A copy of SettingsCatalogue.direct, held HERE rather than read from the
# catalogue file under the home, which whatever wrote there could rewrite.
# SettingsCatalogueTests.theGateHoldsTheSameTable keeps the two equal.
SETTINGS_DIRECT = {
    "replyChime": ("off",), "instantAck": ("off",), "spokenProgress": ("off",),
    "speakSpokenReplies": ("off",), "speakTypedReplies": ("off",), "speakReplies": ("screen",),
    "nudges": ("off",), "quietHours": ("on",), "situationOffers": ("off",),
    "closeOffer": ("off", "shown"), "meetingAutoStopOnCallEnd": ("on",),
    "calendarHeadsUpMinutes": ("0",), "followUpSeconds": ("8",),
    "replyLength": ("short", "balanced", "detailed"),
    "replyReadingSeconds": ("6", "12", "30", "0"),
    "typedRepliesReadAsText": ("on", "off"),
    "panelOnReply": ("always", "silent", "never"),
    "typedAnswersOpenChat": ("on", "off"),
    "notchHoverOpens": ("on", "off"),
    "tenMinuteCheck": ("off",),
}
_SETTING_ON = ("on", "true", "yes", "1", "enable", "enabled")
_SETTING_OFF = ("off", "false", "no", "0", "disable", "disabled")
#: Ids whose values are on/off, so "true" and "on" are one value.
SETTINGS_TOGGLES = frozenset((
    "replyChime", "instantAck", "spokenProgress", "speakSpokenReplies", "speakTypedReplies",
    "nudges", "quietHours", "situationOffers", "meetingAutoStopOnCallEnd",
    "typedRepliesReadAsText", "typedAnswersOpenChat", "notchHoverOpens", "tenMinuteCheck"))


def settings_change_is_direct(a):
    """True only for a change SETTINGS_DIRECT lists. Anything unreadable asks."""
    if not isinstance(a, dict):
        return False
    sid, raw = a.get("id"), a.get("value")
    if not isinstance(sid, str) or not isinstance(raw, (str, int, float, bool)) or sid not in SETTINGS_DIRECT:
        return False
    v = str(raw).strip().lower()
    if sid in SETTINGS_TOGGLES:
        v = "on" if v in _SETTING_ON else "off" if v in _SETTING_OFF else v
    return v in SETTINGS_DIRECT[sid]


# ── Layer D applied ───────────────────────────────────────────────────────────
kind, why = declared(tool, bare, server, own)
if own and bare == "moe_settings_change":
    if settings_change_is_direct(args):
        kind, why = "local", "it only makes Moe do or say less, or changes how answers are shown"
    else:
        kind, why = "act", "it lets Moe do, say or listen more, so the person is asked first"
elif own and bare == "connect_service":
    kind, why = "act", "connecting a service widens what Moe can reach, so the person is asked first"
canon = policy_key(tool, bare, server, own)
# What the act dialog calls the tool: the bare name, or for a broker batch
# the slug inside it — "Tool: COMPOSIO_MULTI_EXECUTE_TOOL" tells a person
# nothing about what is being done to their spreadsheet.
act_name = bare
# True once a broker batch has been judged item by item: the name and shape
# layers below are then about the ENVELOPE, and must not re-judge it — the
# shape test would see a draft's recipient and body and show it as a send.
batch_decided = False
batch = batch_items()
if batch is None:
    kind, why = "unknown", "a tool in this batch carries no name to judge it by"
    batch_decided = True
elif batch:
    batch_decided = True
    _policy = load_json(POLICY_PATH)
    _judged = [(slug, inner) + slug_kind(slug, inner, _policy, kind == "run")
               for slug, inner in batch]
    _sends = [j for j in _judged if j[2] == "send"]
    _acts = [j for j in _judged if j[2] == "act"]
    if _sends:
        kind, why = "send", _sends[0][4]
        canon = _sends[0][3]
    elif _acts:
        kind, why = "act", _acts[0][4]
        canon, act_name = _acts[0][3], _acts[0][0]
    else:
        sys.stdout.write("PASS\n")
        sys.exit(0)
# The word layers, as a FLOOR under every declaration. A declaration can say
# "run" — and then these can still add a dialog, never take one away:
#   name_hit        the bare name says send (and does not also say read)
#   message_shaped  the call carries a recipient and something to say
#   read_named      the bare name reads like a read and does not say "make"
name_hit = bool(SEND_NAME.search(bare) and not (
    (READ_ONLY.match(bare) or READ_ONLY_WORD.search(bare)) and not SEND_VERB.search(bare)))
read_named = bool((READ_ONLY.match(bare) or READ_ONLY_WORD.search(bare))
                  and not WRITE_VERB.search(bare))


def message_shaped():
    """The call actually carries a recipient and something to say — by named
    keys, or positionally (`args: ["dad@x", "hi"]`). Distinct from name_hit,
    which is about the tool's name, not its arguments."""
    found_to, found_body, _ = deep_collect(args)
    if found_to and found_body:
        return True
    pos_to, pos_body = positional(args)
    return bool(pos_to and pos_body)


force_ask = False   # → the SEND dialog, below, once ask() exists
soft_name = False   # a name-only hit on a labelled read → the ACT dialog, not a fake send
if kind == "run":
    # Your "allow" silences acts. It never silences a message: a call that
    # carries a recipient and a body — or a send-NAMED call with neither, the
    # outbox/commit shape SEND_NAME lists — is shown as the message it is,
    # which is also what a forged policy entry buys: nothing, for messages.
    if message_shaped() or name_hit:
        force_ask = True
    elif bare in BROWSER_GATED and _hermes_true(args.get("allow_signed_out")):
        # Nor the question of WHO the browser is. "Always allow" on a browser
        # tool was an answer about what it presses; whether it may carry on
        # signed in as nobody was never asked then. On to gate_browser.
        pass
    else:
        sys.stdout.write("PASS\n")
        sys.exit(0)
elif kind == "defer":
    # The connector asks at the socket, with the name it resolved — but who
    # named this person is a question only this conversation can answer, so
    # it is asked here first.
    recipient_gate()
    sys.stdout.write("DEFER\n%s\n%s\n%s\n-\n" % (bare, tool, bare.split("_")[0]))
    sys.exit(0)
elif own and kind in ("read", "local"):
    # Our own declaration: `memory` carries target+content, `todo` carries
    # items — shapes that look like a message and are not one, so the shape
    # layer does not apply. The NAME still does: a manifest planted under
    # ~/.moe that re-describes `send_message` as a read declares nothing.
    if name_hit:
        force_ask = True
    else:
        sys.stdout.write("PASS\n")
        sys.exit(0)
elif kind == "trusted":
    if message_shaped() or name_hit:
        force_ask = True
    else:
        sys.stdout.write("PASS\n")
        sys.exit(0)
elif kind == "read":
    # A third party's own label. It is honoured only where the name agrees
    # with it: a read-named tool marked read-only runs, whatever its
    # arguments (chat_id + text is a search). Anything else the label alone
    # cannot silence — a lying server can mark `wipe_database` read-only; it
    # gets the act dialog, not a pass. A send-shaped call is a send.
    # `read_named` alone is what may skip the shape test — MOVES_DATA never
    # does, which is the whole reason the two lists are separate.
    reads_like = read_named or bool(MOVES_DATA.search(bare)
                                    and not WRITE_VERB.search(bare))
    if message_shaped() and not read_named:
        force_ask = True
    elif name_hit or not reads_like:
        kind, why = "act", why + " — but its name does not read like a read"
        soft_name = True
    else:
        sys.stdout.write("PASS\n")
        sys.exit(0)


def broker_toolkit():
    """(slug, label) for a broker's tool — ("googledrive", "Google Drive") —
    or ("", "").

    A broker is one server carrying hundreds of other people's services, so
    naming the SERVER names the plumbing: the owner screenshotted a dialog
    headed "Composio" that said "the composio server" and "This composio tool
    changes things", about a file in his Google Drive. Composio is not the
    thing being touched and is not a word he should have to know.

    Every one of those tools carries its toolkit in its slug —
    `GOOGLEDRIVE_DOWNLOAD_FILE`, `GMAIL_SEND_EMAIL` — and `composio.py`
    already keeps a day-long cache of slug -> display name and logo for the
    Connections screen. This reads that cache rather than growing a second
    catalogue of service names, which is the duplication
    `Service.identified` was cut back to avoid.

    Deliberately narrow: the segment before the first underscore must be an
    EXACT key in that cache. A tool from a service nobody has looked up falls
    back to the server name, which is honest — better a dull true word than a
    confident wrong one. Never raises: a missing, empty or corrupt cache is
    the ordinary case on a Mac that has connected nothing.
    """
    # ONLY for a server that is actually a broker. Without this the slug is
    # simply the tool's own first segment, which the tool's author controls:
    # a hostile `mcp__evilcorp__GMAIL_DELETE_ALL` was measured presenting as
    # **Gmail**, with Gmail's mark, on the strength of a cache entry the real
    # connector had written. `Sources/MoeConfirm/ConfirmRequest.swift` states
    # the invariant this broke, in its own comment: when the tool id and the
    # hint disagree, the one chosen by the tool's author must not win.
    if server not in BROKERS:
        return "", ""
    heads = []
    # A MULTIPLEXER carries no service in its own name.
    # `COMPOSIO_MULTI_EXECUTE_TOOL` is the tool the model reaches for most, and
    # its slug says "composio" — the wrong answer arriving by a mechanism that
    # looks right, which is worse than no answer. The service is DECLARED in
    # the call: the schema requires `tools: [{tool_slug, arguments}]`, so read
    # it there. That is a declaration, not a guess over names — the same rule
    # the rest of this file follows.
    for item in (args.get("tools") if isinstance(args.get("tools"), list) else []):
        if not isinstance(item, dict):
            continue
        slug = item.get("tool_slug") or item.get("slug") or item.get("name")
        if isinstance(slug, str) and "_" in slug:
            h = slug.split("_")[0].lower()
            if h and h not in heads:
                heads.append(h)
    if not heads:
        heads = [bare.split("_")[0].lower()]
    if not heads or not heads[0]:
        return "", ""
    home = os.environ.get("MOE_HOME") or os.path.join(os.path.expanduser("~"), ".moe")
    try:
        with open(os.path.join(home, "cache", "composio-toolkits.json"),
                  encoding="utf-8") as fh:
            kits = (json.load(fh) or {}).get("toolkits") or {}
        labels = []
        for h in heads:
            label = (kits.get(h) or {}).get("label")
            if not (isinstance(label, str) and label.strip()):
                # One unknown service in the list and the whole answer is a
                # guess. Say nothing rather than name some of them.
                return "", ""
            labels.append(label.strip())
        if not labels:
            return "", ""
        if len(labels) == 1:
            return heads[0], labels[0]
        # Several at once. Name them ALL — naming one of two is the confident
        # wrong answer this function exists to avoid — and return no slug, so
        # the dialog does not draw one service's mark over another's.
        if len(labels) == 2:
            return "", "%s and %s" % (labels[0], labels[1])
        return "", "%s and %s" % (", ".join(labels[:-1]), labels[-1])
    except Exception:
        pass
    return "", ""


def act():
    """Not a message: a tool that changes things, or one nobody has vouched
    for. Show what it is and what it is being given; the dialog offers to
    remember a yes. Does not return."""
    TARGET_KEYS = ("id", "name", "path", "url", "zone", "zone_id", "project",
                   "project_id", "target", "resource", "channel", "repo", "key",
                   "account", "account_id", "entity_id", "domain", "file")
    target = ""
    for k in TARGET_KEYS:
        v = args.get(k)
        if isinstance(v, (str, int, float)) and str(v).strip():
            target = re.sub(r"\s+", " ", str(v)).strip()
            break
    if len(target) > 120:
        target = target[:117] + "…"
    # Name the service, not the broker. `service` is what draws the mark —
    # Resources/ServiceIcons carries googledrive.svg and googlecalendar.svg,
    # and ServiceIcons.art falls back to a symbol then a monogram for anything
    # it has no art for, so an unknown slug costs nothing.
    kit_slug, kit_label = broker_toolkit()
    # The person is told WHOSE tool this is, in a name they know. A broker
    # toolkit names its service, an MCP call names its server, and one of
    # Moe's own tools is Moe's — never "Hermes", which is the engine's name
    # and appears nowhere a person can see (owner, 2026-09-20, screenshot of
    # this dialog titled "Hermes" over `connections_list`).
    # Moe's own tools are Moe's, whichever proxy carried them: a card
    # headed "hermes-tools" names the engine's plumbing, not anything a
    # person has heard of.
    where = kit_label or ("" if own else server) or "Moe"
    # The card, in plain words (the owner, 2026-09-29: "why do they look so
    # technical and unsimple? There is no idea what's going on"). The
    # headline says what is being asked and where; the body says why Moe is
    # asking and what saying yes does; the tool's own name, the reason code
    # and every argument go behind "Show details", never in the body. The
    # name is still in the body once, tidied ("Update file"), because for a
    # tool nobody has described it is the only thing a person can judge by.
    plain = _tidy_tool(act_name)
    if kit_slug and act_name.lower().startswith(kit_slug + "_"):
        # "GOOGLESHEETS_BATCH_UPDATE" in Google Sheets is "Batch update":
        # the heading already names the service.
        plain = _tidy_tool(act_name[len(kit_slug) + 1:])
    mine = where == "Moe"
    if kind == "unknown":
        headline = ("Let Moe try something it hasn\u2019t done before?" if mine
                    else "Let Moe use %s for something new?" % where)
        lead = ("Moe hasn\u2019t used \u201c%s\u201d before and can\u2019t tell what it does, "
                "so it is checking with you first." % plain)
    elif kind == "unlabelled":
        headline = "Let Moe use %s?" % where
        lead = ("%s doesn\u2019t say whether \u201c%s\u201d only looks at things or also "
                "changes them, so Moe is checking with you first." % (where, plain))
    elif why == "you asked to be asked about this tool":
        headline = ("Let Moe do this?" if mine else "Let Moe use %s?" % where)
        lead = "You asked Moe to check with you before it uses \u201c%s\u201d." % plain
    else:
        headline = ("Let Moe make a change?" if mine else "Let Moe make a change in %s?" % where)
        lead = ("\u201c%s\u201d changes things rather than just looking, so Moe is "
                "checking with you first." % plain)
    body = lead
    if target:
        body += "\n\nIt works on: %s" % target
    detail = ("Tool: %s\nFrom: %s\nWhy Moe asks: %s\n\nWhat Moe is passing to it:\n%s" % (
        act_name, where, why, readable(args) if args else "(nothing)"))
    detail = detail.replace("\x1e", " ").strip()
    sys.stdout.write("ACT\n%s\n%s\n%s\n%s\n%s%s" % (
        where.replace("\n", " "), canon.replace("\n", " "),
        kit_slug or ("" if own else server) or service_of(target, tool),
        target or where,
        _headed(headline, body), _DETAIL_SEP + detail))
    sys.exit(0)


def _tidy_tool(name):
    """`browser_vault_login` → "Browser vault login"; a broker slug
    `GOOGLEDRIVE_UPDATE_FILE` → "Googledrive update file". The last resort
    for a name nobody described — it still beats showing an identifier."""
    text = re.sub(r"^mcp__.*__", "", name or "")
    text = re.sub(r"[_\-]+", " ", text).strip()
    if text.isupper():
        text = text.lower()
    return (text[:1].upper() + text[1:])[:80] if text else "this tool"


# Actions that put input on the screen. The hands-off guard is armed for
# these and only these: reading the screen is not something to be interrupted.
_SESSION_GRANT_TTL = 3600.0


def _session_grant_path():
    return os.path.join(os.environ.get("MOE_HOME") or
                        os.path.expanduser("~/.moe"), "gate", "session-sends.json")


def _grant_state():
    """The grant file as a dict, expired entries dropped. {} when absent."""
    try:
        with open(_session_grant_path(), encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception:
        d = {}
    if not isinstance(d, dict):
        d = {}
    now = time.time()
    grants = d.get("grants") if isinstance(d.get("grants"), dict) else {}
    d["grants"] = {k: v for k, v in grants.items()
                   if isinstance(v, (int, float)) and now - v <= _SESSION_GRANT_TTL}
    return d


def _write_pending(session, mutate):
    """Write the would-be grant to the .pending file the shell promotes on a
    yes. It carries the WHOLE grant state — the computer_use session grant
    and every browser class grant — merged, so the shell's rename cannot
    drop a grant given earlier. `asking` names the key this dialog is for,
    which is what "Allow everything this session" is written against."""
    if not session:
        return
    try:
        d = _grant_state()
        d["asking"] = session
        mutate(d)
        path = _session_grant_path() + ".pending"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(d, fh)
    except Exception:
        pass


def _refresh_grant(key):
    """Push a grant's clock forward: "this session" ends an hour after the
    LAST thing Moe did, not an hour after the click. Best effort — a lost
    refresh means one extra dialog, never an extra send."""
    try:
        d = _grant_state()
        if key not in d["grants"]:
            return
        d["grants"][key] = time.time()
        path = _session_grant_path()
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(d, fh)
        os.replace(tmp, path)
    except Exception:
        pass


#: An offer's draft is being sent (the island's "Use draft" wrote this, the
#: moment before it asked Moe to send it): no session or class grant answers
#: for it. The person approves THAT send, in a dialog, every time — even
#: after "Allow everything this session" in the same conversation (review of
#: the offer path #5). Fresh for 15 minutes, then it is only a file.
_OFFER_SEND_TTL = 15 * 60


def _offer_marker_paths():
    """Where the app writes the marker (SituationOffer.markerURL:
    `<its home>/gate/offer-send.json`), read from every name that home
    goes by — $MOE_HOME, the ~/.moe link resolved, and the release app's
    own folder — so the two agree without resting on the link alone."""
    app = os.environ.get("MOE_APP_HOMES")
    homes = [MOE_HOME] + ([h for h in app.split(os.pathsep) if h] if app is not None else
                          [os.path.realpath(os.path.expanduser("~/.moe")),
                           os.path.expanduser("~/Library/Application Support/Moe")])
    out = []
    for h in homes:
        p = os.path.realpath(os.path.join(h, "gate", "offer-send.json"))
        if p not in out:
            out.append(p)
    return out


def _offer_send_pending():
    """`{"at", "until"}`: in date until `until` (the app ties it to the turn
    carrying the send, and removes it when that turn ends); a marker with
    only `at` is in date for _OFFER_SEND_TTL."""
    now = time.time()
    for path in _offer_marker_paths():
        try:
            with open(path, encoding="utf-8") as fh:
                d = json.load(fh) or {}
            at = float(d.get("at") or 0)
            until = float(d.get("until") or (at + _OFFER_SEND_TTL))
        except Exception:
            continue
        if at - 60 <= now <= until:
            return True
    return False


def _session_send_allowed(session):
    """Has this computer-use session already been authorised to send?

    One dialog per session, which is what the owner asked for after being
    asked once per message while Moe held a conversation in a chat window:
    "For a computer use session there should be one pop-up that will allow for
    that session."

    Scoped to the session id and expiring an hour after it was given, because
    a session id can outlive the person's attention. Never a permanent grant
    and never per-tool: the `act` path has one of those and a send must not.
    """
    if not session or _offer_send_pending():
        return False
    # "Allow everything this session" covers screen sends too.
    if _class_grant_allowed(session, "all"):
        return True
    try:
        with open(_session_grant_path(), encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception:
        return False
    if not isinstance(d, dict) or d.get("session") != session:
        return False
    try:
        return (time.time() - float(d.get("at") or 0)) <= _SESSION_GRANT_TTL
    except (TypeError, ValueError):
        return False


def _arm_session_grant(session):
    """Leave the session id where the shell can promote it after approval.

    The dialog is run by the shell, so the grant cannot be written here — it
    would authorise a session the person has not answered for yet.
    """
    def _set(d):
        d["session"] = session
        d["at"] = time.time()
    _write_pending(session, _set)


# The body and the code are two different things to a reader, and until
# 2026-09-16 they arrived as one: a sentence, two newlines, then four hundred
# characters of Python squashed onto one line. The owner's verdict was
# "technical, very ugly, and very unclear". The record separator below is how
# the classifier hands the shell a second field without changing the header
# lines every other verdict is parsed by; the shell splits it off and the
# dialog draws it as code, under the sentence, in its own quiet block.
_DETAIL_SEP = "\n\x1e\n"


def emit_session(channel, to, body, raw="", tool_name="computer_use", detail="", headline=""):
    """A send that, once approved, covers the rest of this session — except
    while an offer's send is pending: then it is a plain SEND, with no
    "Allow everything this session" and no grant armed (re-review #8)."""
    if _offer_send_pending():
        try:
            os.remove(_session_grant_path() + ".pending")
        except OSError:
            pass
        emit(channel, to, ((body or "") + ("\n\n" + detail if detail else "")), raw=raw,
             headline=headline)
    body = (body or "").strip() or "(empty message)"
    detail = (detail or "").strip().replace("\x1e", " ")
    sys.stdout.write("SESSION\n%s\n%s\n%s\n%s\n%s%s" % (
        channel.replace("\n", " "), (raw or "").replace("\n", " "),
        tool_name, to, _headed(headline, body), (_DETAIL_SEP + detail) if detail else ""))
    sys.exit(0)


def _draft_path():
    return os.path.join(os.environ.get("MOE_HOME") or
                        os.path.expanduser("~/.moe"), "last-typed.json")


def _remember_typed(where, text):
    """Keep the last thing Moe typed, so the Return dialog can quote it.

    The gate sees `type` and `key` as two unrelated calls, and only the second
    one asks the person anything. So on 2026-09-06 the owner was shown "Press
    return in Google Chrome. This is what sends in mail, messages and chat
    windows." — a description of a keystroke — twenty-four seconds after Moe
    had typed the actual sentence into a chat box. He was being asked to
    approve a send whose content was on screen but not in the dialog.

    One entry, overwritten each time, mode 600, and expired hard on read. It
    is the user's own text on the user's own machine, and the dialog is about
    to show it to them anyway — but it is still text on disk, so it lives for
    a couple of minutes and no longer.
    """
    if not isinstance(text, str) or not text.strip():
        return
    try:
        path = _draft_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"where": where, "text": text[:4000],
                       "at": time.time()}, fh)
    except Exception:
        pass


_DRAFT_TTL = 180.0


def _recent_typed(where):
    """The text Moe last typed here, if it was recent enough to be this send."""
    try:
        with open(_draft_path(), encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception:
        return None
    try:
        if time.time() - float(d.get("at") or 0) > _DRAFT_TTL:
            return None
    except (TypeError, ValueError):
        return None
    # Same target, or no target named on either side. A draft typed into Mail
    # must not be shown as the body of a Return pressed in Chrome.
    a = (d.get("where") or "").strip().lower()
    b = (where or "").strip().lower()
    if a and b and a != b:
        return None
    text = d.get("text")
    return text if isinstance(text, str) and text.strip() else None


def _app_for_pid(pid):
    """The app name behind a pid, for the dialog's TO line.

    "TO: the frontmost window" is not a recipient anybody can judge, and it
    is what the owner was shown on 2026-09-06 when Moe asked to press return
    in a chat box: the question was "may I send this", and the answer needed
    to know where. `computer_use` calls carry `pid` and `window_id` far more
    often than they carry `app` — the model gets the pid from a capture and
    passes that — so the gate was reading the one field that was usually
    absent and falling back to a placeholder.

    Best-effort by design. A dialog that cannot name the app still has to
    appear; naming it is an improvement to the question, not a precondition
    for asking it.
    """
    try:
        n = int(pid)
    except (TypeError, ValueError):
        return None
    if n <= 0:
        return None
    try:
        done = subprocess.run(["ps", "-p", str(n), "-o", "comm="],
                              capture_output=True, text=True, timeout=2)
    except Exception:
        return None
    path = (done.stdout or "").strip()
    if not path:
        return None
    # /Applications/Google Chrome.app/Contents/MacOS/Google Chrome -> the
    # bundle name, which is what a person calls it. Falls back to the
    # executable's own name for a plain binary.
    marker = ".app/Contents/MacOS/"
    if marker in path:
        return path.split(marker)[0].rsplit("/", 1)[-1]
    return path.rsplit("/", 1)[-1] or None


# ── Browser: five moments ask; everything else runs ──────────────────────────
#
# Until 2026-09-10 any browser_exec script that contained "click" or "enter"
# raised a dialog: thirteen of them in seven minutes for one date picker on
# Hostelworld, and the owner's verdict was that a consent per click "doesn't
# make any sense". Every shipped browser agent — Operator, Claude in Chrome,
# Comet, Mariner — gates the same short list instead, and so does this one:
#
#   pay        paying, buying, booking, subscribing
#   send       sending a message, an email, a post
#   delete     deleting or cancelling something that does not come back
#   secret     entering a password, a card number, a CVV, an SSN
#   grant      authorizing an app or granting a permission on a consent page
#
# And a sixth, which is not about what the page is asked to do but about WHO
# is doing it (owner decision, 2026-11-12, "ask, then continue"):
#
#   signed-out a call that carries allow_signed_out — "run this in a fresh
#              browser signed in as nobody", which Hermes offers only after the
#              person's own signed-in profile failed to open
#
# Hermes's rule is that the model sets it "only after the person answered
# yes". That made the person's yes the model's word for it: nothing stopped a
# model passing the flag unasked, on a first call, in a scheduled job. Here
# the yes is a tap. It is read off the call's ARGUMENT, not the script and not
# the tool's name, so a read-only script asks too — signed out, "read my
# orders" quietly returns a stranger's empty page — and so does a call the
# person "always allowed" (see the run branch of Layer D).
#
# One yes covers that class for the rest of this conversation, for an hour —
# Comet's "once per task" — written to the same grant file computer_use uses,
# and promoted by the shell only after the person answered.
#
# Detection is STRUCTURAL: what the call itself carries. A browser_exec
# script names the URL it opens, the selector or text it clicks and the keys
# it presses; the structured browser_* tools carry a ref, a selector, a key.
# The last URL each conversation opened is remembered for the calls that do
# not repeat it (a press of Enter in a chat box opened two calls ago).
# Comment lines are ignored — "# Searching Booking.com" is narration, not an
# action, and on 2026-09-09 that exact comment is what a word-match would
# have asked about. What this cannot see is a page the call never describes;
# that limit is in the header's bypass list, not papered over.

_BROWSER_URL_TTL = 3600.0


def _browser_url_path():
    return os.path.join(MOE_HOME, "gate", "browser-last-url.json")


def _remember_browser_url(sess, url):
    if not sess or not url:
        return
    try:
        try:
            with open(_browser_url_path(), encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception:
            d = {}
        if not isinstance(d, dict):
            d = {}
        now = time.time()
        d = {k: v for k, v in d.items()
             if isinstance(v, dict) and now - float(v.get("at") or 0) <= _BROWSER_URL_TTL}
        d[sess] = {"url": url[:2000], "at": now}
        os.makedirs(os.path.dirname(_browser_url_path()), exist_ok=True)
        fd = os.open(_browser_url_path(), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(d, fh)
    except Exception:
        pass


def _recent_browser_url(sess):
    if not sess:
        return ""
    try:
        with open(_browser_url_path(), encoding="utf-8") as fh:
            d = json.load(fh)
        v = d.get(sess) if isinstance(d, dict) else None
        if isinstance(v, dict) and time.time() - float(v.get("at") or 0) <= _BROWSER_URL_TTL:
            return str(v.get("url") or "")
    except Exception:
        pass
    return ""


def _class_grant_allowed(sess, cls):
    """Has this class already been approved for this conversation?

    "all" — the dialog's "Allow everything this session" — answers for every
    class, and its clock is pushed forward on each use: the session ends an
    hour after Moe's last action, not an hour after the click.
    """
    if not sess or _offer_send_pending():
        return False
    try:
        grants = _grant_state()["grants"]
        key = sess + "|" + cls
        if key not in grants and cls != "all":
            key = sess + "|all"
        ok = (time.time() - float(grants[key])) <= _SESSION_GRANT_TTL
    except Exception:
        return False
    if ok and key.endswith("|all"):
        _refresh_grant(key)
    return ok


def _arm_class_grant(sess, cls):
    """Write the would-be class grant to the .pending file (see _write_pending)."""
    def _set(d):
        d["grants"][sess + "|" + cls] = time.time()
    _write_pending(sess, _set)


_SIGNED_OUT = "signed_out"
_SIGNED_OUT_CHANNEL = "browser signed-out"   # the shell matches this, verbatim
_SIGNED_OUT_NOTE = ("Moe\u2019s browser is signed out here, so this would be done as nobody, "
                    "not as you.")


def _signed_out_allowed(sess):
    """Has the person said yes to a signed-out browser in THIS conversation?

    Its own key and nothing else. "Allow everything this session" pressed on a
    payment or a post does not answer it: that was a yes to what Moe presses,
    given while the browser was them. (Pressed on the signed-out card itself
    it does cover it — the shell promotes the pending class grant with it.)
    The clock is pushed forward on each use, as for "all": one yes covers the
    conversation while it is going, and lapses an hour after it goes quiet.
    """
    if not sess:
        return False
    key = sess + "|" + _SIGNED_OUT
    try:
        ok = (time.time() - float(_grant_state()["grants"][key])) <= _SESSION_GRANT_TTL
    except Exception:
        return False
    if ok:
        _refresh_grant(key)
    return ok


# What the model does in a browser_exec script that COUNTS as acting on the
# page. Reading — page_info(), js("document.title"), capture_screenshot() —
# never asks, whatever the page.
_BROWSER_ACTS = re.compile(
    r"(\bclick\w*\s*\(|\.click\s*\(|\bpress\w*\s*\(|\bkey\w*\s*\(|\btype\w*\s*\(|"
    r"\bfill\w*\s*\(|\bselect\w*\s*\(|dispatchKeyEvent|dispatchMouseEvent|insertText|"
    r"requestSubmit|\.submit\s*\(|\bsubmit\b|set_value|\.value\s*=|\.checked\s*=|"
    r"dispatchEvent|\bupload\w*\s*\()", re.I)
_BROWSER_TYPES = re.compile(
    r"(\btype\w*\s*\(|\bfill\w*\s*\(|insertText|set_value|\.value\s*=|Input\.insertText)", re.I)

_PAY = re.compile(
    r"(?i)(\bpay\s?now\b|\bconfirm\s+(and|&)\s+pay\b|\bplace\s+(your\s+|my\s+|the\s+)?order\b|"
    r"\bcomplete\s+(my\s+|your\s+|the\s+)?(booking|purchase|order|reservation|payment)\b|"
    r"\bconfirm\s+(booking|reservation|purchase|order|payment)\b|"
    r"\bbook\s?now\b|\breserve\s?now\b|\bbuy\s?now\b|\bpurchase\b|\bsubscribe\s?now\b|"
    r"\bstart\s+(your\s+|my\s+)?(free\s+)?trial\b|\bupgrade\s+(plan|now)\b|"
    r"/(checkout|payment|pay|purchase)(\b|/|\?)|/book(ing)?/(confirm|pay|review|complete)(\b|/|\?))")
_SEND_HOSTS = ("mail.google.com", "outlook.live.com", "outlook.office.com",
               "outlook.office365.com", "mail.yahoo.com", "mail.proton.me",
               "web.whatsapp.com", "web.telegram.org", "slack.com", "discord.com",
               "messenger.com", "x.com", "twitter.com", "linkedin.com/messaging",
               "teams.microsoft.com", "messages.google.com", "chat.google.com",
               "reddit.com/submit", "facebook.com", "instagram.com/direct",
               "threads.net", "bsky.app", "mastodon")
_SEND_WORDS = re.compile(
    r"(?i)(\bsend\s?(now|message|email|mail|reply)?\b|\bpost\s?(now|comment|reply)?\b|"
    r"\btweet\b|\bpublish\b|\breply\s?(all)?\b|\bsubmit\s+(comment|reply|post|review)\b|"
    # x.com's own controls, by the test ids its pages carry: clicking
    # tweetButtonInline IS posting, whatever words the script uses.
    r"tweetButton\w*|tweetTextarea\w*)")
_DELETE = re.compile(
    r"(?i)(\bdelete\s+(account|permanently|forever|repository|repo|project|workspace|everything)\b|"
    r"\bpermanently\s+(delete|remove)\b|\bempty\s+(trash|bin)\b|"
    r"\bcancel\s+(subscription|membership|plan|order|booking|reservation|account)\b|"
    r"\bclose\s+(my\s+)?account\b|\bdeactivate\b|\bremove\s+payment\s+method\b|\brevoke\b|"
    r"\bunlink\s+account\b|\bfactory\s+reset\b|\bwipe\b)")
# A secret is a VALUE going into a page, not a word on it. `_SECRET` used to
# match "password" anywhere in the call, so on 2026-09-29 a call that typed
# the owner's EMAIL and clicked a button labelled "Forget Password" was shown
# as "Moe is about to enter a password, a card number or another secret".
# Now the class fires when a password/card field is the TARGET of the typing
# (a selector that names one, a labelled field), or when what is typed looks
# like a card number or a password. Button text, links and clicks never do.
_SECRET_FIELD = re.compile(
    r"(?i)(password|passwd|\bpwd\b|\bpw\b|passcode|\bpin\b|card[_\s-]?(number|num|no)\b|cardnumber|"
    r"\bcc-?(number|num|csc|exp)|\bcvv|\bcvc|\bcsc\b|security[_\s-]?code|\bssn\b|social[_\s-]?security|"
    r"routing[_\s-]?number|account[_\s-]?number|\biban\b)")
# What a selector looks like, as opposed to the words on a button.
_SELECTOR_FORM = re.compile(r"(?i)(\[|#|^\.|\binput\b|\btextarea\b|name\s*=|type\s*=|id\s*=|autocomplete|placeholder|@e\d)")
_STRING_LIT = re.compile(r"\"((?:[^\"\\\n]|\\.){0,400})\"|'((?:[^'\\\n]|\\.){0,400})'")
_TYPE_CALL = re.compile(
    r"(?i)\b(fill\w*|type\w*|insert_?text|set_value|send_keys)\s*\(([^()\n]*)\)")
_VALUE_SET = re.compile(r"(?i)([^;\n]{0,200})\.value\s*=\s*\\?([\x22\x27])((?:(?!\\?\2).){0,400})\\?\2")
_CDP_TEXT = re.compile(
    r"(?i)Input\.insertText[\x22\x27]\s*,\s*(?:text\s*=\s*|\{\s*[\x22\x27]text[\x22\x27]\s*:\s*)([\x22\x27])((?:(?!\1).){0,400})\1")
# A field's own label, whole: "Password", "Confirm password", "Card number".
_SECRET_LABEL = re.compile(
    r"(?i)^\s*((new|current|confirm|repeat|your)\s+)?(password|passcode|pin|cvv|cvc|card\s+number|"
    r"security\s+code)\s*[:*]?\s*$")


def _literals(text):
    return [m.group(1) if m.group(1) is not None else m.group(2)
            for m in _STRING_LIT.finditer(text or "")]


def _luhn(digits):
    total, odd = 0, True
    for ch in reversed(digits):
        d = int(ch)
        if not odd:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
        odd = not odd
    return total % 10 == 0


def _card_like(value):
    d = re.sub(r"[\s-]", "", value or "")
    return d.isdigit() and 13 <= len(d) <= 19 and _luhn(d)


def _password_like(value):
    v = value or ""
    if not (8 <= len(v) <= 64) or re.search(r"\s", v) or "@" in v or "://" in v:
        return False
    kinds = sum(bool(re.search(p, v)) for p in (r"[a-z]", r"[A-Z]", r"\d", r"[^A-Za-z0-9]"))
    return kinds >= 3 and not v.isdigit()


def _typed_items(bare, args, acted):
    """[(target, value)] for every place this call types: target is the
    selector or label it types into ("" when it types into whatever has
    focus), value the words (None when they are not a literal)."""
    out = []
    if bare == "browser_cdp" and str(args.get("method") or "") == "Input.insertText":
        params = args.get("params") if isinstance(args.get("params"), dict) else {}
        out.append(("", str(params.get("text")) if isinstance(params.get("text"), str) else None))
    for m in _TYPE_CALL.finditer(acted or ""):
        name, inner = m.group(1).lower(), m.group(2)
        lits = _literals(inner)
        if not lits:
            out.append(("", None))
        elif name.startswith("fill") or name == "set_value" or len(lits) >= 2:
            out.append((lits[0], lits[-1] if len(lits) >= 2 else None))
        else:
            # type("…") with one literal: the words, into whatever has focus —
            # unless the chained receiver named the field (locator("#pw").type).
            out.append((acted[max(0, m.start() - 120):m.start()].splitlines()[-1] if m.start() else "", lits[0]))
    for m in _VALUE_SET.finditer(acted or ""):
        out.append((m.group(1), m.group(3)))
    # The raw CDP door: cdp("Input.insertText", text="…") types into whatever
    # has focus.
    for m in _CDP_TEXT.finditer(acted or ""):
        out.append(("", m.group(2)))
    return out


def _secret_field(target):
    t = target or ""
    return bool(_SECRET_LABEL.search(t) or (_SECRET_FIELD.search(t) and _SELECTOR_FORM.search(t)))


def _types_a_secret(bare, args, acted):
    """Does this call put a password, a card number or another secret into a
    page? True for a secret FIELD being typed into, or a secret-looking
    value being typed — never for the word on a button or a link."""
    items = _typed_items(bare, args, acted)
    for target, value in items:
        if _secret_field(target) or (value is not None and (_card_like(value) or _password_like(value))):
            return True
    if items:
        # Typing into whatever has focus, after the call focused a secret
        # field by selector: click("input[type=password]") then type("…").
        # The words being typed are not selectors, whatever they say.
        typed = {v for _t, v in items if v is not None}
        for s in _short_strings(acted) + [str(args.get(k)) for k in ("selector", "label", "name") if isinstance(args.get(k), str)]:
            if s not in typed and _secret_field(s):
                return True
    return False


# The label of what a call presses, in the page's own words.
# Quote characters spelled \x22 and \x27: this program sits inside a bash
# command substitution, and bash 3.2 counts quotes in it (see the top).
_Q = r"\\?[\x22\x27]"
_NQ = r"[^\x22\x27\\\n]"
_CLICK_LABELS = (
    re.compile(r"(?i)text\s*=\s*" + _Q + r"?(" + _NQ[:-1] + r")]{1,60})"),
    re.compile(r"(?i)has-text\(\s*" + _Q + r"(" + _NQ + r"{1,60})"),
    re.compile(r"(?i)get_by_text\(\s*" + _Q + r"(" + _NQ + r"{1,60})"),
    re.compile(r"(?i)get_by_role\([^)\n]*name\s*=\s*" + _Q + r"(" + _NQ + r"{1,60})"),
    re.compile(r"(?i)(?:innerText|textContent)(?:\.trim\(\))?(?:\.toLowerCase\(\))?\s*===?\s*"
               + _Q + r"(" + _NQ + r"{1,60})"),
    re.compile(r"(?i)(?:innerText|textContent)[^;\n]{0,30}\.includes\(\s*" + _Q + r"(" + _NQ + r"{1,60})"),
    re.compile(r"(?i)aria-label\s*=\s*" + _Q + r"(" + _NQ + r"{1,60})"),
)
_CLICKS = re.compile(r"(?i)(\bclick\w*\s*\(|\.click\s*\(|\btap\s*\()")
_KEYS = re.compile(r"(?i)\b(?:press\w*|key\w*)\s*\(\s*(?:[^,()\n]*,\s*)?[\x22\x27](Enter|Return|Tab|Escape|Space)[\x22\x27]")


def _clean_label(text):
    t = re.sub(r"\s+", " ", (text or "").strip().strip("?!.:").strip())
    return t[:40]


def _what_typed(target, value):
    if _card_like(value or "") or re.search(r"(?i)card|cvv|cvc|csc|iban|routing|account", target or "") and _secret_field(target):
        return "a card number" if not re.search(r"(?i)cvv|cvc|csc|security", target or "") else "a card security code"
    if _secret_field(target) or _password_like(value or ""):
        return "a password"
    v = re.sub(r"\s+", " ", value or "").strip()
    if v and len(v) <= 40:
        return "\u201c%s\u201d" % v
    if re.search(r"(?i)e-?mail", target or ""):
        return "an email address"
    return "some text"


def _and(items):
    items = [x for x in items if x]
    if len(items) <= 1:
        return "".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]


def _describe_browser(bare, args, acted, site):
    """What the call does, in a sentence a person reads in two seconds:
    "Type “me@x.com” into fazier.com and press “Forget Password”". None
    when nothing in the call says what it presses or types."""
    whats = []
    for target, value in _typed_items(bare, args, acted):
        w = _what_typed(target, value)
        if w not in whats:
            whats.append(w)
    labels = []
    if _CLICKS.search(acted or ""):
        for rx in _CLICK_LABELS:
            for m in rx.finditer(acted or ""):
                lab = _clean_label(m.group(1))
                if lab and lab not in labels:
                    labels.append(lab)
    keys = [m.group(1) for m in _KEYS.finditer(acted or "")]
    steps = []
    if labels:
        steps.append("press " + _and(["\u201c%s\u201d" % l for l in labels[:2]]))
    elif _CLICKS.search(acted or ""):
        steps.append("click a button")
    if keys:
        steps.append("press " + _and(list(dict.fromkeys(keys))[:2]))
    if re.search(r"requestSubmit|\.submit\s*\(", acted or "") and not labels:
        steps.append("send the form")
    if re.search(r"(?i)\bselect_option\s*\(", acted or ""):
        steps.append("choose an option")
    if re.search(r"(?i)\bupload\w*\s*\(", acted or ""):
        steps.append("upload a file")
    if whats:
        head = "Type %s into %s" % (_and(whats[:3]), site)
        return head + (" and " + _and(steps) if steps else "")
    if steps:
        first = steps[0][:1].upper() + steps[0][1:]
        return first + " on %s" % site + (" and " + _and(steps[1:]) if steps[1:] else "")
    return None


_GRANT = re.compile(
    r"(?i)(accounts\.google\.com/o/oauth2|/oauth2?/(authorize|consent)|/authorize(\b|\?)|/consent(\b|\?)|"
    r"\ballow\s+access\b|\bauthorize\s+(app|access)\b|\bgrant\s+(access|permission)\b|\bapprove\s+access\b)")

# A form that goes out with words in it. On 2026-09-24 Moe filled Hacker
# News's submit form — title, url, text — and clicked its button, and the
# post went live under the owner's account with no dialog (ticket #11).
# news.ycombinator.com was on no list and its button says only "submit",
# which _SEND_WORDS rightly does not take on its own. A list of sites is
# walked past by the next site, so this asks about what the call DOES:
# typing into a page, then submitting what was typed. That is posting on
# any site. The typing may come a call earlier (fill, then submit), so it is
# remembered for the conversation for a quarter of an hour.
_BROWSER_SUBMITS = re.compile(
    r"(requestSubmit|\.submit\s*\(|type\s*=\s*\\*[\"']?submit|\[type=\\*[\"']?submit|"
    r"text=\\*[\"']?(submit|post|publish|send|reply|comment)\b|"
    r"(press\w*|key\w*)\s*\(\s*[^)]*\\*[\"']Enter\\*[\"']|dispatchKeyEvent[^\n]*Enter)", re.I)
# What a search box or a sign-in form looks like: typing there and pressing
# Enter is how the web is read, not a post. Matched against the page's URL
# and the call's short strings (selectors, keys), never its long ones — a
# post titled "a search engine for your notes" is still a post.
_NOT_A_POST = re.compile(
    r"(?i)(search|\bfind\b|[?&](q|query|ss|k|keyword|term)=|"
    r"name=\\*[\"']?(q|query|search|ss|keyword)\b|role=\\*[\"']?searchbox|type=\\*[\"']?search|#q\b|"
    r"/log_?in|/sign_?in|/signin|/session|/auth\b|log\s?in|sign\s?in|username|password|"
    r"one-?time|verification|\botp\b)")
_TYPED_TTL = 900.0


def _short_strings(code):
    """The literals a person would call selectors: short, no sentences."""
    out = []
    for m in re.finditer(r"\"((?:[^\"\\\n]|\\.){0,60})\"|'((?:[^'\\\n]|\\.){0,60})'", code or ""):
        v = m.group(1) if m.group(1) is not None else m.group(2)
        if v is not None and len(v.split()) <= 3:
            out.append(v)
    return out


def _typed_path():
    return os.path.join(MOE_HOME, "gate", "browser-typed.json")


def _typed_recently(sess, mark=False):
    """Did this conversation type into a page in the last quarter hour?"""
    if not sess:
        return False
    try:
        with open(_typed_path(), encoding="utf-8") as fh:
            d = json.load(fh)
        if not isinstance(d, dict):
            d = {}
    except Exception:
        d = {}
    now = time.time()
    d = {k: v for k, v in d.items() if isinstance(v, (int, float)) and now - v <= _TYPED_TTL}
    was = sess in d
    if mark:
        d[sess] = now
        try:
            os.makedirs(os.path.dirname(_typed_path()), exist_ok=True)
            fd = os.open(_typed_path(), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(d, fh)
        except Exception:
            pass
    return was


def _posts_a_form(acted, typing, page, session_id):
    """Does this browser_exec call submit words typed into a page?"""
    reading = bool(_NOT_A_POST.search(page or "")) or any(
        _NOT_A_POST.search(s) for s in _short_strings(acted))
    if reading:
        return False
    typed_before = _typed_recently(session_id, mark=typing)
    return bool(_BROWSER_SUBMITS.search(acted)) and (typing or typed_before)


# (class, what a yes lets Moe go on doing, why Moe asks, the headline when
# the call's own words do not say what it presses or types).
_BROWSER_CLASSES = (
    ("pay", "pay, buy or book", "This may pay for, buy or book something.",
     "Pay, buy or book something on %s"),
    ("send", "send or post", "This may send or post something in your name.",
     "Send or post something on %s"),
    ("delete", "delete or cancel", "This may delete or cancel something that can\u2019t be brought back.",
     "Delete or cancel something on %s"),
    ("secret", "enter a password or card", "This puts a password, a card number or another secret into the page.",
     "Enter a password or card number on %s"),
    ("grant", "grant access", "This gives an app access to one of your accounts.",
     "Give an app access to your account on %s"),
)


def _browser_domain(text):
    m = re.search(r"https?://([^/\s'\"()<>]+)", text or "")
    return m.group(1).lower() if m else ""


# A call that opens a page names the page it opens.
_NAV_CALL = re.compile(
    r"(?:goto_url|new_tab|navigate|goto|open_url|visit|go_to)\s*\(\s*[\"'](https?://[^\"'\s]+)", re.I)


def _acting_domain(corpus, recent, hits):
    """The site being ACTED ON, which is not the first link in sight.

    On 2026-09-16 the dialog said "www.producthunt.com" over a reply Moe was
    posting on x.com, because the first URL in the script was the Product
    Hunt link inside the reply's own text. In order: the page the call opens;
    a URL on a site that matches the class that fired (a send on x.com is on
    x.com); the page the conversation last opened; and only then the first
    URL anywhere in the call.
    """
    m = _NAV_CALL.search(corpus or "")
    if m:
        return _browser_domain(m.group(0))
    if "send" in hits:
        for u in re.findall(r"https?://[^\s'\"()<>]+", corpus or ""):
            h = _browser_domain(u)
            if any(s in h for s in _SEND_HOSTS):
                return h
    return _browser_domain(recent) or _browser_domain(corpus) or "this page"


# The mark the dialog draws. The keys are rows the dialog knows (see
# Sources/MoeConfirm/ConfirmRequest.swift, `known`); "chrome" is any other
# site, drawn with the browser's own mark rather than a letter.
_BRAND = (("x.com", "twitter"), ("twitter.com", "twitter"), ("linkedin.com", "linkedin"),
          ("slack.com", "slack"), ("discord.com", "discord"), ("mail.google.com", "gmail"),
          ("web.whatsapp.com", "whatsapp"), ("web.telegram.org", "telegram"),
          ("reddit.com", "reddit"), ("facebook.com", "facebook"), ("messenger.com", "messenger"),
          ("instagram.com", "instagram"), ("threads.net", "threads"), ("bsky.app", "bluesky"),
          ("outlook.", "outlook"), ("teams.microsoft.com", "teams"),
          ("chat.google.com", "google_chat"), ("mastodon", "mastodon"))


def _brand_of(domain):
    for host, key in _BRAND:
        if host in (domain or ""):
            return key
    return "chrome"


def gate_browser(bare, args, session_id):
    code = args.get("code") if isinstance(args.get("code"), str) else ""
    # Narration is not an action: drop comment lines before matching.
    acted = "\n".join(l for l in code.splitlines() if not l.lstrip().startswith("#"))
    if bare == "browser_cdp":
        # The CDP door names its act in `method` and its keys in `params`.
        acted += "\n%s\n%s" % (args.get("method") or "",
                                json.dumps(args.get("params") or {}, ensure_ascii=False))
    parts = [acted]
    for k in ("text", "key", "keys", "ref", "selector", "value", "url", "label", "name"):
        v = args.get(k)
        if isinstance(v, (str, int, float)):
            parts.append(str(v))
        elif isinstance(v, (list, tuple)):
            parts.append(" ".join(str(x) for x in v))
    corpus = "\n".join(p for p in parts if p)
    # The page the conversation is on: read BEFORE this call is remembered,
    # and remember only a page this call OPENS — a link inside the text of a
    # reply is not where the conversation went (2026-09-16: it made the
    # gate believe a thread on x.com was on producthunt.com).
    recent = _recent_browser_url(session_id)
    nav = _NAV_CALL.search(acted)
    opened = nav.group(1) if nav else (
        str(args.get("url")) if isinstance(args.get("url"), str) and args.get("url").startswith("http") else "")
    if opened:
        _remember_browser_url(session_id, opened)
    ctx = corpus + "\n" + recent
    # A browser_cdp call acts through its method (Input.*), read by _BROWSER_ACTS like code.
    structured_act = False
    typing = bool(_BROWSER_TYPES.search(acted))
    signed_out = _hermes_true(args.get("allow_signed_out"))

    def ask_signed_out(also=()):
        """The signed-out card. `also`: what else this same call would do that
        has its own card (pay, send, …) — said here, because one yes runs the
        whole call. Only the signed-out grant is armed: the next payment still
        asks, as a payment."""
        # No reason is shown, because none reaches this hook: Hermes gave it
        # to the model in the result of the call BEFORE this one, and a
        # pre-tool hook sees only this call. A reason printed here would be
        # the model's retelling, on a card whose point is not to take the
        # model's word.
        body = ("Moe\u2019s browser could not open with your logins. If you say yes, Moe carries "
                "on in a fresh browser that is signed in to nothing: what it does there is "
                "done as nobody, not as you.")
        for line in also:
            body += "\n\n" + line
        body += ("\n\nIf you say yes, Moe can keep browsing signed out in this conversation "
                 "for the next hour without asking again.")
        detail = acted.strip() or json.dumps(
            {k: v for k, v in args.items() if k != "code"}, ensure_ascii=False, indent=1)
        detail = "\n".join(l.rstrip() for l in detail.splitlines() if l.strip())[:1200]
        _arm_class_grant(session_id, _SIGNED_OUT)
        emit_session(_SIGNED_OUT_CHANNEL, "a signed-out browser", body, raw=bare,
                     tool_name="chrome", detail=detail,
                     headline="Moe can\u2019t open your signed-in browser. Continue signed out?")

    ask_identity = signed_out and not _signed_out_allowed(session_id)
    if not (structured_act or _BROWSER_ACTS.search(acted)):
        if ask_identity:
            ask_signed_out()
        sys.stdout.write("PASS\n")
        sys.exit(0)
    low = ctx.lower()
    hits = []
    if _PAY.search(ctx):
        hits.append("pay")
    if any(h in low for h in _SEND_HOSTS) and (bare != "browser_exec" or _SEND_WORDS.search(acted)
                                               or re.search(r"(?i)\benter\b|\\r|\\n|dispatchKeyEvent", acted)):
        hits.append("send")
    elif bare == "browser_exec" and _posts_a_form(acted, typing, opened or recent, session_id):
        hits.append("send")
    if _DELETE.search(ctx):
        hits.append("delete")
    if typing and _types_a_secret(bare, args, acted):
        hits.append("secret")
    if _GRANT.search(ctx):
        hits.append("grant")
    if ask_identity:
        ask_signed_out([why_ask for cls, _verb, why_ask, _fb in _BROWSER_CLASSES
                        if cls in hits and not _class_grant_allowed(session_id, cls)])
    for cls, verb, why_ask, fallback in _BROWSER_CLASSES:
        if cls not in hits or _class_grant_allowed(session_id, cls):
            continue
        if signed_out:
            # The card's own words imply the person's account ("in your
            # name"). Signed out, that is not whose it is.
            why_ask = why_ask + " " + _SIGNED_OUT_NOTE
        domain = _acting_domain(corpus, recent, hits)
        site = _plain_site(domain) if domain != "this page" else domain
        # The card says what will happen, in the page's own words, and why
        # Moe is asking; the code goes behind "Show details" (the owner,
        # 2026-09-29: "why do they look so technical and unsimple?").
        # Trimmed lines, not squashed ones.
        headline = _describe_browser(bare, args, acted, site) or fallback % site
        detail = acted.strip() or json.dumps(
            {k: v for k, v in args.items() if k != "code"}, ensure_ascii=False, indent=1)
        detail = "\n".join(l.rstrip() for l in detail.splitlines() if l.strip())[:1200]
        _arm_class_grant(session_id, cls)
        emit_session(
            "browser " + cls, domain,
            "%s\n\nIf you say yes, Moe can %s again in this "
            "conversation for the next hour without asking." % (why_ask, verb),
            raw=bare, tool_name=_brand_of(domain), detail=detail, headline=headline)
    sys.stdout.write("PASS\n")
    sys.exit(0)


if bare in BROWSER_GATED:
    gate_browser(bare, args, session_id)


def gate_computer_use(args, mode):
    # "Stay out of the way" is a setting, and it is enforced here rather than
    # asked for in the prompt: the model picks `delivery_mode` itself, so a
    # rule that lives in prose is a request. Background input never trips
    # this — it moves no pointer, steals no focus, and is most of what Moe
    # does. What it stops is the escalation: fronting a window, or raising one
    # on another Space, which on a full-screen app pulls the person's desktop
    # out from under them mid-sentence.
    if (os.environ.get("MOE_COMPUTER_USE_TAKEOVER") or "1").strip() != "0":
        pass
    else:
        act = str(args.get("action") or "").strip().lower()
        # invoke_menu is a takeover, and the DRIVER is what says so, not a
        # guess: crates/platform-macos/src/tools/invoke_menu.rs calls AXRaise,
        # AXMain and AXFocused, and refuses with "target window N did not
        # become stably key and frontmost". It carries no delivery_mode to ask
        # for anything gentler, and unlike click/type/key in `foreground` mode
        # — which briefly front and then "restore the prior frontmost" — it
        # never puts the previous app back. macOS gives the menu bar to the
        # active app, so this is not wiring we are missing: menu INVOCATION
        # cannot be background-first, even though menu READING works on any
        # app on any Space.
        #
        # Third time for this exact shape. A guard that enumerates names is
        # walked past by a new name; the first two were `invoke_menu` missing
        # from the send gate and `steps` presenting as one unknown verb. This
        # one was in the guard written to close those two.
        wants_front = (
            str(args.get("delivery_mode") or "").strip().lower() == "foreground"
            or bool(args.get("bring_to_front"))
            or (act == "focus_app" and bool(args.get("raise_window")))
            or act == "invoke_menu"
        )
        if wants_front:
            # REFUSE, not a dialog: the person already answered this question
            # in Settings, and asking again every time is how a setting turns
            # into a nag. The reason is written for the model, because the
            # model is the one that has to choose differently.
            # Five header lines then the body, like every other verdict:
            # the shell reads a fixed header before the body, so a short
            # message lands in the CHANNEL slot and the reason comes out
            # empty. It did, the first time.
            #
            # The reason has to name THIS call's route to the screen. A
            # refusal that says "delivery_mode=foreground" about an
            # invoke_menu names an argument the call does not carry, and an
            # error naming the wrong cause sends the reader somewhere there
            # is nothing to find — which is how the Calendar window one Space
            # away had the model re-spelling "Calendar" for ninety seconds.
            if act == "invoke_menu":
                why = ("invoking a menu item brings the app to the front — "
                       "macOS gives the menu bar to the active app, so there "
                       "is no background way to do it")
                instead = ("READING menus is unaffected, and most items have "
                           "a keyboard shortcut that CAN be delivered in the "
                           "background: `bash ~/.moe/tools/mac.sh menus <app>` "
                           "prints the shortcut beside the item — send that "
                           "with `key` instead.")
            else:
                why = ("this asked to take the screen over "
                       "(delivery_mode=foreground, bring_to_front or "
                       "raise_window)")
                instead = ("Background input is unaffected — do it without "
                           "fronting the window.")
            sys.stdout.write(
                "REFUSE\n-\ncomputer_use\n-\n-\n"
                "Not done: " + why + ", and Moe is set to stay in the "
                "background on this Mac. " + instead + " If it genuinely "
                "cannot be done that way, say what you could not reach and "
                "why; the user can allow taking over in Settings. Do not "
                "retry this call.\n")
            sys.exit(0)

    # `.strip()` because the tool does: computer_use/tool.py does
    # `(args.get("action") or "").strip().lower()`. Comparing more strictly
    # than the dispatcher is the same hole as `action == "List"` was, pointing
    # the other way — `{"action": " key ", "keys": "Return"}` was a silent
    # pass here and a Return pressed in Messages there.
    action = str(args.get("action") or "").strip().lower()
    keys = str(args.get("keys") or "").lower()
    text = args.get("text")
    if text is not None and not isinstance(text, str):
        # A non-string `text` (list, dict) hides newlines from a substring
        # check — str(["a\n"]) is the repr. Fail closed: treat it as a send.
        text = "\n" + json.dumps(text, ensure_ascii=False)
    text = text or ""
    where = str(args.get("app") or _app_for_pid(args.get("pid")) or
                "the frontmost window")
    if action == "type":
        _remember_typed(where, text)
    combo = [k for k in re.split(r"[+\-\s]+", keys) if k]
    MODS = ("cmd", "command", "ctrl", "control", "meta", "super", "win", "windows",
            "alt", "option", "opt", "shift", "fn")
    # Return/Enter anywhere in the combo (not only last: "return+shift" is
    # shift-Return to some parsers) and the control-code spellings of the same
    # key: ctrl+m is CR and ctrl+j is LF in Terminal and every readline box.
    ENTER_NAMES = ("return", "enter", "kp_enter", "numpad_enter", "keypad_enter", "cr", "lf", "newline")
    non_mods = [k for k in combo if k not in MODS]
    is_return = any(k in ENTER_NAMES for k in non_mods)
    if not is_return and non_mods in (["m"], ["j"]) and any(k in ("ctrl", "control") for k in combo):
        is_return = True
    modified = is_return and any(k in ("cmd", "command", "ctrl", "control", "meta", "super") for k in combo)
    if action == "key" and is_return and (mode != "shortcuts" or modified):
        # Show the WORDS when we have them. "Press return in Google Chrome"
        # asks a person to approve a send without telling them what is being
        # sent; the sentence was typed by the previous call and is the only
        # thing they actually need to read.
        # Already answered for, this session. One dialog per computer-use
        # session, not one per message — asked for after Moe held a
        # conversation in a chat window and every turn needed a click.
        if not _session_send_allowed(session_id):
            draft = _recent_typed(where)
            lead = ("%s\n\n" % draft) if draft else ""
            _arm_session_grant(session_id)
            emit_session(
                "computer_use key", where,
                # One line, deliberately. The confirm stub logs its
                # arguments tab-separated with the body inline, so several
                # tests count dialogs with `wc -l` on that log — a body
                # carrying its own newlines counts as three dialogs and the
                # count assertions go red. The draft above may still be
                # multi-line; that is the person's own text and it stays as
                # they typed it.
                lead + "Pressing %s in %s sends this. Approving also lets "
                "Moe send in this computer-use session without asking "
                "again, for up to an hour." % (keys, where),
                raw="computer_use")
    is_quit = (non_mods == ["q"] and any(k in ("cmd", "command", "meta", "super") for k in combo)) or (
        non_mods in (["esc"], ["escape"]) and any(k in ("cmd", "command") for k in combo)
        and any(k in ("option", "alt", "opt") for k in combo))
    if action == "key" and is_quit:
        emit("computer_use key", where,
             "Press %s in %s. This quits (or force-quits) the app — unsaved work is lost." % (keys, where))
    if action == "type" and ("\n" in text or "\r" in text):
        emit("computer_use type", where, "Type text containing a line break (acts as Return):\n\n" + text)
    # invoke_menu fires a menu item straight through the accessibility API.
    # Every gate above keys on an action NAME, so a capability added later
    # under a new name walks past all of them: measured, ["Terminal","Quit
    # Terminal"], ["Edit","Delete"] and ["Message","Send"] all passed ungated
    # while the identical cmd+Q and Return were stopped. That is the guard
    # this file exists to be, undone by a synonym.
    #
    # Matching menu labels is guessing, and this file prefers declaring — so
    # the match is deliberately narrow and its failure mode is a dialog, not a
    # silent pass. Two honest limits: menu titles are LOCALIZED, so a French
    # "Quitter" or "Envoyer" is not caught by these English words; and an app
    # may name a destructive item something else entirely. Neither is a reason
    # to gate nothing — cmd+Q is caught by its keystroke whatever the menu
    # says, and MOE_COMPUTER_USE_CONFIRM=every gates the rest.
    if action == "invoke_menu":
        path = args.get("path")
        if not isinstance(path, list):
            # A malformed path is not a safe path: fail closed rather than
            # reasoning about a shape the tool has not validated yet.
            emit("computer_use invoke_menu", where,
                 "Invoke a menu item with a path Moe could not read:\n\n"
                 + json.dumps(args, ensure_ascii=False, indent=1))
            trail = ""
        else:
            pretty = " > ".join(str(p) for p in path)
            # The invoked item is the last segment; the ones above it are
            # containers ("File", "Edit") and must not trigger on their own.
            trail = str(path[-1]).strip().rstrip("\u2026.").lower() if path else ""
        SEND_ITEMS = ("send", "send now", "send message", "send email", "reply",
                      "reply all", "forward", "publish", "post", "share",
                      "submit", "tweet", "buy", "purchase", "pay", "order",
                      "confirm order", "place order")
        DESTRUCTIVE_ITEMS = ("quit", "delete", "move to trash", "move to bin",
                             "empty trash", "empty bin", "erase", "erase all",
                             "remove", "discard", "log out", "sign out",
                             "shut down", "restart", "reset", "uninstall",
                             "delete account", "revoke")
        if trail:
            if any(trail == k or trail.startswith(k + " ") for k in SEND_ITEMS):
                emit("computer_use invoke_menu", where,
                     "Invoke the menu item %s in %s. This is what sends."
                     % (pretty, where))
            if any(trail == k or trail.startswith(k + " ") for k in DESTRUCTIVE_ITEMS):
                emit("computer_use invoke_menu", where,
                     "Invoke the menu item %s in %s. This quits, deletes or "
                     "signs out — it may lose unsaved work." % (pretty, where))

    if mode == "every" and action in ("click", "double_click", "right_click", "middle_click",
                                      "drag", "scroll", "type", "key", "set_value",
                                      "invoke_menu"):
        emit("computer_use " + action, where, json.dumps(args, ensure_ascii=False, indent=1))
    return


# Layer 3b: an AppleScript that drives the screen is computer use wearing a
# different name.
#
# `osascript -e 'tell application "Freeform" to activate'` fronts an app just
# as surely as bring_to_front does, and `tell process … keystroke` types just
# as surely as computer_use type. Both go through the `terminal` tool, so on
# 2026-09-04 neither the hands-off guard nor the "stay in the background"
# setting saw them: the owner watched Moe pull him back to Freeform over and
# over, pressed the stop twice, and it kept happening — because the thing
# doing it was not the tool any of those controls watch.
#
# The third instance today of a guard that enumerates names being walked past
# by a new one. The rule has to be what the command DOES.
_AS_ACTIVATE = re.compile(
    r"(?i)"
    r"(?:tell\s+app(?:lication)?\s+[^\n]{0,80}?\s+to\s+activate"
    r"|\bactivate\s*$"
    r"|set\s+frontmost\s+(?:of\s+[^\n]{0,60}?\s+)?to\s+true"
    r"|perform\s+action\s+\"AXRaise\""
    r"|\bopen\s+-a\b)")
_AS_DRIVES_UI = re.compile(
    r"(?i)\b(?:keystroke"
    r"|key\s+code"
    r"|click\s+(?:menu\s+item|button|at\b)"
    r"|perform\s+action\s+\"AXPress\")")


def gate_applescript_screen(cmd):
    """Refuse a screen takeover done through the shell, and arm the guard."""
    if not cmd:
        return
    drives = bool(_AS_DRIVES_UI.search(cmd))
    fronts = bool(_AS_ACTIVATE.search(cmd))
    if not (drives or fronts):
        return

    # Same setting, same reason: the person said keep out of the way, and the
    # route the request took does not change the answer.
    if fronts and (os.environ.get("MOE_COMPUTER_USE_TAKEOVER") or "1").strip() == "0":
        sys.stdout.write(
            "REFUSE\n-\nterminal\n-\n-\n"
            "Not done: this brings an app to the front (an AppleScript "
            "`activate`, `set frontmost` or `open -a`), and Moe is set to stay "
            "in the background on this Mac. That is the same takeover as "
            "bring_to_front and it gets the same answer whichever tool asks. "
            "Do it without fronting the window, or say what you cannot reach. "
            "Do not retry this call.\n")
        sys.exit(0)

    # Anything that types or clicks through System Events is input on the
    # person's screen and belongs under the same take-over watch as a click.


if SHELL_TOOL.search(bare):
    _cmd = ""
    for _k in ("command", "cmd", "script", "code", "input"):
        if args.get(_k):
            _cmd = stringify(args[_k])
            break
    gate_applescript_screen(_cmd)

if bare == "computer_use":
    mode = (os.environ.get("MOE_COMPUTER_USE_CONFIRM") or "return").strip().lower()
    # `steps` runs several actions in one tool call. Every gate below reads
    # `args["action"]`, so a batch would present itself as one unknown verb
    # and carry a Return, a cmd+Q or a Send menu item past all of them — the
    # same synonym hole invoke_menu opened, at one remove. Flatten it: each
    # step is judged exactly as if it had been sent on its own.
    if str(args.get("action") or "").strip().lower() == "steps":
        steps = args.get("steps")
        if not isinstance(steps, list):
            emit("computer_use steps", "the frontmost window",
                 "Run a batch of actions Moe could not read:\n\n"
                 + json.dumps(args, ensure_ascii=False, indent=1))
            sys.stdout.write("PASS\n")
            sys.exit(0)
        for st in steps:
            # A non-dict step is not something to reason about.
            if not isinstance(st, dict):
                emit("computer_use steps", "the frontmost window",
                     "Run a batch containing an unreadable step:\n\n"
                     + json.dumps(args, ensure_ascii=False, indent=1))
                continue
            gate_computer_use(dict(st), mode)
        sys.stdout.write("PASS\n")
        sys.exit(0)
    gate_computer_use(args, mode)
    sys.stdout.write("PASS\n")
    sys.exit(0)



# Hermes's own cross-platform tool does four things, and one of them —
# `action="list"` — enumerates the channels and contacts it could send to.
# It sends nothing, and a dialog in front of it is the worst kind: frequent,
# meaningless, and exactly the training that gets a real one waved through.
# Matched EXACTLY as Hermes matches it — `action == "list"`, no strip, no
# lower (tools/send_message_tool.py:250). Normalising here and not there is a
# send: `{"action": "List"}` was a listing to this hook and a send to the
# tool, and the model writes that field, so text Moe reads could pick the
# capitalisation. Any comparison here that is looser than the dispatch it
# mirrors is a hole with a shape.
if bare == "send_message" and args.get("action") == "list":
    sys.stdout.write("PASS\n")
    sys.exit(0)

# memory and todo write to the user's OWN local stores. Nothing leaves the
# machine, so neither is ever a send — but a `memory` call is shaped
# {"target": "memory", "content": "…"}, and `target` is a recipient key and
# `content` a body key, so the shape layer below reads it as "a message to
# somebody called memory" and puts up "Moe wants to send this. Read it first."
# That was harmless while the model almost never saved anything; now that
# memory actually works (tools are no longer deferred, and background review
# runs) every saved fact raised a dialog. A save to yourself needs no
# permission. Tied to the trusted spellings, like SELF_CONFIRMING: a foreign
# mcp__other__memory is still classified normally.

# The three connector sends that confirm for themselves. gmail.py opens the
# dialog before it opens a socket; telegram.py and whatsapp.sh call
# confirm.sh — each with the RESOLVED recipient, which this hook cannot know.
# Asking here as well put the same question up twice for every email and
# message Moe sends, and the header says what a repeated dialog teaches. So
# this hook stands down for exactly those three, and only when the call
# reaches them DIRECTLY: the bare name (Hermes' own loop) or one hermes-tools
# hop (the claude-code child re-exporting Hermes' registry).
# mcp__hermes-tools__mcp__<other>__gmail_send is somebody else's tool wearing
# the name and is asked as before; so is gmail_send_email or any other
# spelling. Safe only because the second gate cannot be removed from
# underneath: GATE_PATHS refuses writes to /.hermes/plugins/ (the plugin that
# runs these scripts) and GATE_WRITE_ONLY refuses writes to gmail.py,
# telegram.py and whatsapp.sh themselves. Logged as "deferred", so "why was I
# not asked" has an answer.

def ask():
    """Put this call in front of the human. Does not return."""
    to = first = next((stringify(args[k]) for k in RECIPIENT_KEYS if args.get(k)), "")
    # The dialog has to name EVERY recipient, not only the first field: a
    # cc, a bcc or a second id list is somebody else on the message, and a
    # human who approved "to: Dan" never approved them.
    extra = ["%s: %s" % (k, stringify(args[k])) for k in RECIPIENT_ANY
             if args.get(k) not in (None, "", [], {}, ()) and stringify(args[k]) != to]
    if extra:
        to = ", ".join([to] + extra) if to else ", ".join(extra)
    # A body key holding a container is an envelope, not a message — Graph's
    # `body` is {contentType, content}. Printing that as the message is how a
    # person ends up approving JSON.
    body_key = next((k for k in BODY_KEYS if isinstance(args.get(k), str) and args[k]), None)
    body = args[body_key] if body_key else ""
    # Where the words live, for putting a rewritten message back. None for
    # a body that was assembled from positional arguments — there is no one
    # field it came out of — and the dialog is then read-only.
    body_path = [body_key] if body_key else None
    if not to and not body:
        pos_to, pos_body = positional(args)
        if pos_body is not None:
            to, body = pos_to, pos_body
    subject = args.get("subject")
    subject_path = ["subject"] if isinstance(subject, str) and subject else None

    # The deep walk always runs, and its recipients are always merged in.
    # Gating it on "only if we found nobody at the top level" meant a call
    # with a plain `to` and a nested bcc showed the `to` and hid the bcc —
    # while taking its body from the same walk that had just found them. A
    # human who approved "to: Dan" never approved the address they were not
    # shown, and where that address hides is not their problem.
    found_to, found_body, found_subject = deep_collect(args)
    if found_to:
        # `seen` holds the RAW values, not fragments of the composed line.
        # Splitting the line on ", " could never match a joined value like
        # "a@x.com, b@y.com", so every list recipient was appended a second
        # time labelled `to: …` — the dialog read
        # "a@x.com, b@y.com, to: a@x.com, b@y.com", a person could no longer
        # count the recipients, and at about 24 addresses the doubled line
        # crossed confirm.sh's 900-character refusal and blocked a send that
        # was perfectly legitimate.
        seen = [v for v in [to.strip()] if v]
        # People first, and a thread or topic id only when nothing names a
        # person — labelled, so it never reads as an address.
        people = [(k, v) for k, v in found_to if norm(k) not in CONTEXT_NORM]
        for key, value in (people or found_to):
            if value in seen or ("%s: %s" % (key, value)) in seen:
                continue
            person = norm(key) not in CONTEXT_NORM
            if not first and person:
                first = value
            label = value if (not to and not seen and person) else "%s: %s" % (key, value)
            to = ", ".join([to, label]) if to else label
            seen.append(value)
    if not body and found_body:
        # Shallowest first, then the order BODY_KEYS puts them in: a
        # `content` beside a `caption` is the message, the caption is not.
        found_body.sort(key=lambda row: (row[1], row[0]))
        body = found_body[0][2]
        body_path = found_body[0][3]
    if not subject and found_subject:
        # Its own condition. Nested under the body it only appeared when the
        # body had also come out of the deep walk, so a call with a plain
        # `text` and a nested subject showed no subject at all.
        subject, subject_path = found_subject[0]

    composed = False
    if subject:
        body = "Subject: %s\n\n%s" % (subject, body)
        composed = True
    if not body.strip():
        # Nothing recognisable to show, so show what there is — as something
        # a person can read, not as JSON. Not a message a person can rewrite.
        body = readable(args)
        body_path = None
    if is_self_telegram(tool, args, to):
        # The owner's own Telegram: the owner ROUTE (meeting notes to their
        # phone). No dialog, never refused; logged "self" so "why was I not
        # asked" has an answer.
        sys.stdout.write("SELF\n%s\n%s\n%s\n%s\n" % (
            tool, tool, "telegram", re.sub(r"\s+", " ", to).strip()))
        sys.exit(0)
    recipient_gate()
    emit(tool, to, body, first_recipient=first,
         edits={"body": body_path, "subject": subject_path, "composed_subject": composed})


if (name_hit and not soft_name) or kind == "send" or force_ask:
    ask()

# Layer 1b: the call's SHAPE says it sends, even when its name does not.
#
# Layer 1 reads names, and names are written by tool authors who owe us
# nothing. Measured against the hook as it stood: mcp__slack__chat_postMessage
# was asked, and mcp__discord__create_message, mcp__twilio__messages_create,
# broadcast_update, deliver_invoice, share_document, push_update and
# submit_form all went through without a word — every one of them carrying a
# recipient and a message body. "Anything whose name says send" is not the
# same promise as "anything that sends".
#
# So a second question, about the call rather than its name: does it carry a
# recipient — any of the keys one hides in, at any depth, cc and bcc included
# — AND something to say to them? That is what sending *is*, whatever the
# verb. The same recursive walk that finds them for the dialog finds them
# here, which is the point: detection and display must not disagree about
# what a recipient is.
#
# Two exemptions, both narrow, and deliberately narrower than layer 1's:
#
#   * a READ-ONLY PREFIX (`search_`, `get_`, `list_`…). A name that *begins*
#     with a read verb is a read, and this is what keeps
#     search_messages(chat_id=…, text=…) from raising a dialog per query.
#     Layer 1's mid-name read WORDS (`status`, `messages`, `voice`…) are
#     deliberately NOT honoured here: at this point we already have positive
#     evidence — a recipient and a body — and a read does not carry a body.
#     Honouring them let `bulk_messages`, `accounts_transfer` and
#     `crawl_and_ping` through with a recipient and the words in hand.
#   * a shell or code tool that is actually carrying a command, handled below
#     on its command text rather than twice. Matching the NAME alone let
#     `execute_campaign(to=…, body=…)` out through a door meant for
#     `terminal(command=…)`.
# Not `input`: that is the standard MCP envelope key, so
# `execute_action({"input": {"to": …, "body": …}})` took a door meant for
# `terminal({"command": …})`. And the value has to be a STRING — a command is
# text; a dict under `code` is somebody's arguments.
COMMAND_KEYS = ("command", "cmd", "script", "code")


def carrying_a_command(args):
    return any(isinstance(args.get(k), str) and args.get(k) for k in COMMAND_KEYS)


# The read-only prefix is honoured only when the name does not also say
# something is being made. `get_or_create_conversation({"user_id", "message"})`
# and `find_contact_and_message({"to", "body"})` both passed silently on the
# strength of their first word — and `get_or_create_*` is a common MCP naming
# pattern. WRITE_VERB is exactly the predicate for this; its own docstring
# described this fix, which had never been wired up.
reads_only = READ_ONLY.match(bare) and not WRITE_VERB.search(bare)
if not batch_decided and not reads_only \
        and not (SHELL_TOOL.search(bare) and carrying_a_command(args)):
    found_to, found_body, _ = deep_collect(args)
    if found_to and found_body:
        ask()

def strip_heredocs(text):
    """The command with every here-document BODY removed, delimiters kept.

    `foo <<EOF\n…body…\nEOF` and its `<<'EOF'`, `<<"EOF"`, `<<-EOF` (leading
    tabs stripped from the closing line) spellings. The body is DATA the model
    is writing THROUGH the shell — a note, a file, an AppleScript string — and
    matching a send verb against it is what raised a Gmail dialog over an Apple
    Notes note. What stays is the command structure, where a real send lives.
    Unterminated (no closing delimiter) strips to end of string, the safe way:
    an unclosed heredoc body is still data, not a command line.
    """
    # <<  optional -  optional quote  WORD  matching-quote
    # (?<!<): a `<<<` here-string is not a here-document; without this the
    # opener latched onto the 2nd+3rd `<`, read the next word as a delimiter,
    # found no closing line, and dropped the rest of the command — hiding a
    # real send on a following line.
    opener = re.compile(r"(?<!<)<<-?\s*([\"\']?)([A-Za-z_][A-Za-z0-9_]*)\1")
    pos, result = 0, []
    while True:
        m = opener.search(text, pos)
        if not m:
            result.append(text[pos:])
            break
        dash = text[m.start():m.start() + 3] == "<<-"
        word = m.group(2)
        line_end = text.find("\n", m.end())
        if line_end == -1:
            # Opener with no newline after it — no body to strip.
            result.append(text[pos:])
            break
        result.append(text[pos:line_end + 1])   # keep through the opener's line
        close = re.compile(r"^" + ("\t*" if dash else "") + re.escape(word) + r"[ \t]*$", re.M)
        cm = close.search(text, line_end + 1)
        if not cm:
            break  # unterminated: the rest is body — drop it
        result.append(" ")                       # separator so tokens do not fuse
        pos = cm.end()
    return "".join(result)


# Option flags whose VALUE is a program rather than prose: `osascript -e '…'`,
# `python3 -c '…'`, `bash -lc '…'`, `perl -E '…'`, `node --eval '…'`. The
# quoted string after one of these IS the command and must stay visible to
# every row below.
#
# This is the list that has to be GENEROUS, because getting it wrong in the
# other direction hides a real send: any SHORT flag or cluster containing c or
# e counts (-c, -e, -E, -lc, -ec, -xc), plus a handful of long spellings. A
# long flag not named here carries prose — that is the safe default, and the
# structural rows still read the whole command anyway.
CODE_FLAG = re.compile(
    r"^-[A-Za-z]*[ceE][A-Za-z]*$"
    r"|^--(?:eval|exec|execute|command|code|script|program|run|expression|inline)$")


QUOTE_D = chr(34)   # a bare `"` inside this here-doc confuses bash 3.2's
                    # command-substitution parser; the file is $(cat <<'PY').


def strip_data_operands(text):
    """The command with quoted OPERAND VALUES emptied — its payload removed.

    A command line carries two kinds of text. What it DOES: the program, the
    subcommand, the flag names, the hosts and endpoints, the `tell application`
    clause. And what it CARRIES: a note, a ticket body, a commit message, an
    email draft somebody dictated. This gate exists to read the first kind, and
    every false dialog it has ever raised was the second kind read as the
    first — a note whose body said "Send agent alerts … not one person's
    Gmail", a support ticket whose body said "I called GMAIL_SEND_EMAIL", a
    search for an email *about* sending.

    `strip_heredocs` above was the first half of this rule, written when the
    only payload carrier anyone had hit was a here-doc. The second half is
    this: a quoted string that follows an option flag which is not a
    code-bearing one (CODE_FLAG) is that flag's VALUE. `--body "…"`,
    `--title "…"`, `-m "…"`, `--message "…"` — the words inside belong to the
    person, not to the shell.

    What is deliberately NOT touched, because it is structure:
      * a bare quoted operand with no flag in front of it —
        `telegram.py send "hi"` still reads as a send;
      * the value of a code-bearing flag — `osascript -e '…send…'` and
        `python3 -c '…smtplib…'` are programs;
      * anything unquoted at all.

    The quotes are kept and their contents dropped, so the shape of the line
    survives for anything that re-reads it.
    """
    out, i, n = [], 0, len(text)
    word = ""       # the token being read right now
    last_word = ""  # the token before it
    while i < n:
        ch = text[i]
        if ch == "'" or ch == QUOTE_D:
            q = ch
            j = i + 1
            while j < n:
                if q == QUOTE_D and text[j] == "\\":
                    j += 2
                    continue
                if text[j] == q:
                    break
                j += 1
            end = j + 1 if j < n else n
            # Which token carries this string? The one it is glued to
            # (`--body="…"`), else the one before the space (`--body "…"`).
            carrier = ""
            if word.startswith("-"):
                carrier = word.split("=", 1)[0]
            elif not word and last_word.startswith("-"):
                carrier = last_word.split("=", 1)[0]
            if carrier and not CODE_FLAG.match(carrier):
                out.append(q + q)          # the flag's value: the person's words
            else:
                out.append(text[i:end])    # structure, or a bare operand
            if word:
                last_word, word = word, ""
            i = end
            continue
        if ch in " \t\n\r;|&()":
            if word:
                last_word, word = word, ""
            out.append(ch)
            i += 1
            continue
        word += ch
        out.append(ch)
        i += 1
    return "".join(out)


def strip_py_strings(code):
    """`execute_code` is Python, and a Python string literal is data: a list of
    search queries that says "Google Yahoo bulk sender requirements" and
    "Gmail …" is a web search, not a send (2026-09-29: exactly that list
    raised a Gmail send dialog over research a background helper ran). The
    PROSE rows read the code with every literal emptied; the structural rows
    still read it whole, so a real send — an API host, smtplib — is caught
    wherever it is written. Code that does not tokenize is returned as is."""
    import io, tokenize
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(code).readline))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        return code
    out = []
    for t in toks:
        if t.type == tokenize.STRING:
            out.append((t.start, t.end, chr(34) * 2))
        elif getattr(tokenize, "FSTRING_MIDDLE", None) == t.type:
            out.append((t.start, t.end, ""))
    if not out:
        return code
    lines = code.splitlines(keepends=True)
    offs, pos = [0], 0
    for ln in lines:
        pos += len(ln)
        offs.append(pos)
    res, last = [], 0
    for (sr, sc), (er, ec), rep in out:
        a, b = offs[sr - 1] + sc, offs[er - 1] + ec
        res.append(code[last:a]); res.append(rep); last = b
    res.append(code[last:])
    return "".join(res)


if SHELL_TOOL.search(bare):
    cmd = ""
    for k in ("command", "cmd", "script", "code", "input"):
        if args.get(k):
            cmd = stringify(args[k])
            break
    one_door(cmd)
    # Match against the command with here-doc bodies removed; DISPLAY still
    # uses the whole command below, so `send @bob "hi"` still shows the human
    # the recipient and the words.
    # Structural rows see the whole command; the two prose rows see it with
    # here-doc bodies removed (see SHELL_PATTERNS). Matching structural rows
    # against the full command is what keeps a real send caught when it is
    # wrapped in a `bash <<EOF`/`python3 <<EOF` body — the body IS the command
    # there, not data, so it must not be stripped for them.
    # Two haystacks, and the difference between them is one question: is a
    # here-doc body data or code?
    #
    #   STRUCTURAL rows (a real host, endpoint, `tell application` clause,
    #   `sendmail`, `mail -s`) read the command with here-doc bodies KEPT,
    #   because `bash <<EOF … curl api.telegram.org/…/sendMessage … EOF` is a
    #   send and the body IS the command there.
    #
    #   PROSE rows (the two whose service name is an ordinary English word —
    #   "gmail", "telegram") read it with here-doc bodies REMOVED, because a
    #   note dictated into `osascript <<'EOF'` is somebody's words.
    #
    # Both read it with QUOTED FLAG VALUES emptied, because a flag's value is
    # payload under either reading: `moe-ticket.py --body "…GMAIL_SEND_EMAIL…"`
    # is a ticket about a send, not a send, and no interpreter ever sees those
    # words as a program. See strip_data_operands.
    cmd_structural = strip_data_operands(cmd)
    cmd_prose = strip_data_operands(strip_heredocs(cmd))
    if bare == "execute_code":
        cmd_prose = strip_py_strings(cmd)
    for row in SHELL_PATTERNS:
        label, a, b = row[0], row[1], row[2]
        haystack = cmd_prose if (len(row) > 3 and row[3] == "prose") else cmd_structural
        # A fourth element that is not the "prose" marker is a REQUIRED third
        # condition — the send verb for the AppleScript rows. It reads the same
        # haystack as its row: a verb found only in a ticket body is that
        # ticket's word, not this command's.
        extra = row[3] if (len(row) > 3 and row[3] != "prose") else None
        if extra and not re.search(extra, haystack, re.I):
            continue
        if re.search(a, haystack, re.I) and re.search(b, haystack, re.I):
            to, body = "", cmd
            # "<script> send <to> <message…>" is Moe's verb shape; show the
            # human those parts instead of a shell line.
            try:
                argv = shlex.split(cmd)
            except ValueError:
                argv = []
            if "send" in argv:
                i = argv.index("send")
                if len(argv) > i + 1:
                    to = argv[i + 1]
                if len(argv) > i + 2:
                    body = " ".join(argv[i + 2:])
            emit(label + " via " + tool, to or "(see command)", body)

if kind in ("act", "unlabelled", "unknown"):
    act()
sys.stdout.write("PASS\n")
PY
)

# The classifier as a private file (mode 600 under mktemp), for the reason
# given where the verdict is asked for below. Empty output means it could not.
classifier_file() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/moe-confirm-classifier.XXXXXX") || return 1
  printf '%s\n' "$CLASSIFIER" > "$f" || { rm -f "$f"; return 1; }
  printf '%s' "$f"
}

if [ "${1:-}" = "--inventory" ]; then
  # Every tool Moe knows of and what the gate does with it. tools/gate.sh
  # formats this for people; the doctor counts it.
  CLS_FILE=$(classifier_file) || exit 2
  MOE_GATE_MODE=inventory python3 "$CLS_FILE" </dev/null
  STATUS=$?
  rm -f "$CLS_FILE"
  exit $STATUS
fi
# The call itself is kept: a message the person rewrites in the dialog goes
# back into it, and Hermes is answered with the modified call.
RAW_CALL="$(cat)"
# **The program goes in as a file, never as `python3 -c "$CLASSIFIER"`.** Linux
# caps ONE argv string at 128 KiB (MAX_ARG_STRLEN) and the classifier passed
# that before it reached the away machine (153 KB at d048ebc9, 173 KB by
# 2026-09-29): exec failed with "Argument list too long", bash said 126, and
# this hook — failing closed, as it must — blocked EVERY tool call on the
# cloud computer for four days, while every test on macOS (no per-argument
# limit) stayed green. A private temp file has no such limit on either OS
# (a program on /dev/fd/3 was tried first: macOS's bash 3.2 then runs NOTHING
# when stdin is a pipe, exit 0 — a gate that silently says nothing); stdin
# stays the call. test-confirm-hook.sh runs the hook under a python3
# that refuses any argument over 128 KiB, the way Linux does.
CLS_FILE=$(classifier_file) || block "confirm-send hook: could not stage its classifier — blocked, not guessed"
VERDICT_OUT=$(printf '%s' "$RAW_CALL" | python3 "$CLS_FILE" 2>/dev/null)
STATUS=$?
rm -f "$CLS_FILE"

# 9 is Layer 0: the call names the gate's own files. The classifier already
# wrote the reason, and this one is refused outright rather than offered as a
# dialog — see GATE_PATHS above.
if [ "$STATUS" -eq 9 ]; then
  # No ${VAR:-prose} here: bash reopens quote parsing inside a default value,
  # so an apostrophe in the fallback text is a syntax error in this file.
  GATE_REASON="$VERDICT_OUT"
  if [ -z "$GATE_REASON" ]; then
    GATE_REASON="confirm-send hook: refused — this call names the confirmation gate itself"
  fi
  log block "gate-self-protect" "-"
  block "$GATE_REASON"
fi

if [ "$STATUS" -ne 0 ]; then
  log block "?" "?"
  block "confirm-send hook: could not parse the tool call (python exit $STATUS) — blocked, not guessed"
fi

# Bash 3.2 has no mapfile; read the fixed header lines, then the body.
{
  IFS= read -r VERDICT || VERDICT=""
  IFS= read -r CHANNEL || CHANNEL=""
  IFS= read -r TOOL || TOOL=""
  IFS= read -r SERVICE || SERVICE=""
  IFS= read -r TO || TO=""
  # A SEND carries one more line: where in the call the words live.
  EDIT_MAP="{}"
  if [ "$VERDICT" = "SEND" ]; then
    IFS= read -r EDIT_MAP || EDIT_MAP="{}"
  fi
  BODY="$(cat)"
} <<<"$VERDICT_OUT"
# A SESSION may carry code to show under the sentence, after a record
# separator (see emit_session). Split it off: the body is what a person
# reads, the detail is what the dialog draws as code.
DETAIL=""
case "$BODY" in
  *$'\n\x1e\n'*) DETAIL="${BODY#*$'\n\x1e\n'}"; BODY="${BODY%%$'\n\x1e\n'*}" ;;
esac
# And a card may lead with a one-line headline — what is being asked, where —
# marked by a leading \x1d (the classifier's _headed). No body can start with
# one: every writer strips the body, and \x1d is whitespace to str.strip.
HEADLINE=""
case "$BODY" in
  $'\x1d'*) HEADLINE="${BODY%%$'\n'*}"; HEADLINE="${HEADLINE#$'\x1d'}"; BODY="${BODY#*$'\n'}" ;;
esac

case "$VERDICT" in
  PASS)
    exit 0
    ;;
  SELF)
    # The owner route: the owner's own Telegram (is_self_telegram in the
    # classifier). No dialog; logged so the trail has no gap.
    log self "${TOOL:-${CHANNEL##* via }}" "$TO"
    exit 0
    ;;
  DEFER)
    # A connector send that opens its own dialog (SELF_CONFIRMING in the
    # classifier). Not asked here; logged so the trail has no gap.
    log deferred "${TOOL:-$CHANNEL}" "-"
    exit 0
    ;;
  REFUSE)
    # A policy the user set, or a recipient nobody may be sent to (the owner,
    # or someone nobody named) — not a question. No dialog.
    log refused "${TOOL:-computer_use}" "${TO:--}"
    block "$(printf '%s' "$BODY" | tr '\n' ' ')"
    ;;
  SEND)
    KIND=send
    ;;
  SESSION)
    # A send that, once approved, covers the rest of this computer-use
    # session. Still a send in every way that matters — no "Always allow"
    # button (that is honoured for `act` only), the body is shown in full,
    # and cancelling blocks the call. The differences: saying yes also
    # writes a grant keyed to this session, so Moe holding a conversation in
    # a chat window asks once instead of once per message; and the dialog
    # offers "Allow everything this session" (exit 6), which grants every
    # class for the same session.
    KIND=session
    # The key the grant is written against, so the log can say which
    # conversation was granted — and so an install can be checked against
    # the log rather than believed: a run of `approved` with no
    # `allowed-session` is the 2026-09-16 bug.
    GATE_KEY="$(gate_key)"
    ;;
  ACT)
    KIND=act
    ;;
  *)
    log block "?" "?"
    block "confirm-send hook: unexpected classifier output — blocked"
    ;;
esac

# Tool name for the log, without shelling back into python.
TOOL_NAME="${TOOL:-${CHANNEL##* via }}"

if [ ! -x "$CONFIRM" ]; then
  log block "$TOOL_NAME" "$TO"
  block "confirm-send hook: confirm.sh not found at $CONFIRM — cannot ask, so not sending"
fi

# ---------------------------------------------------------------------------
# A turn nobody is at the screen for asks; it never waits on a card.
#
# Ticket #19, 2026-10-01: the scheduled "X daily growth" job pressed Follow
# with click_at_xy, this hook put a card up on a Mac nobody was looking at,
# and Hermes killed the hook at its 300-second ceiling. The model was told
# "hook … failed closed: timed out after 300s", read that as the site
# ignoring its clicks, and reported "page-script clicks didn't register" —
# the gate's wait, blamed on X. The owner's rule (2026-09-25, decision 5):
# unattended jobs ask instead of opening a card. moe-connectors already does
# this for the connector sends it runs (unattended_route / hold_for_owner);
# this is the same rule for everything that reaches a card through here.
#
# Who started the turn is known only to the process that owns it, so the
# question goes there, over the tool bridge this hook's parent (the
# hermes-tools server) was handed — the same `__turn_presence__` question
# the browser asks. Only the reasons moe-connectors' HOLDABLE_REASONS names
# count as "nobody started this": no bridge, no answer, an unfamiliar reason
# or a live turn all leave the card exactly as it was. Then, as there:
#   owner at the Mac (presence.json fresh and active) → the card, labelled
#     with who asked, with a deadline inside this hook's own budget;
#   owner away → held in their inbox (moe-connectors' held-send note), and
#     the model is told at once, in words that name the gate, not the site.
# Not on a machine with no screen at all: there confirm.sh already asks on
# the phone (confirm-away.py), and an inbox there is read by nobody.
# ---------------------------------------------------------------------------
# Hermes's ceiling for this hook (config-fragment.yaml `timeout: 300`, which
# is also agent/shell_hooks.MAX_TIMEOUT_SECONDS). A card must give up before
# it, or the model hears "timed out" instead of "nobody answered".
HOOK_BUDGET_SECONDS=300
CARD_MARGIN_SECONDS=20
turn_unattended() { # prints "card<TAB>why" or "hold<TAB>why", or nothing
  python3 - "$MOE_HOME" <<'PY' 2>/dev/null
import json, os, socket, sys, time
HOLDABLE = {  # moe-connectors HOLDABLE_REASONS — the same list, on purpose
    "a scheduled job", "a background helper started earlier", "a background worker",
    "a background note from the app", "a webhook turn", "a msgraph webhook turn",
    "a turn that has already ended",
}
path = (os.environ.get("HERMES_TOOL_BRIDGE_SOCKET") or "").strip()
token = (os.environ.get("HERMES_TOOL_BRIDGE_TOKEN") or "").strip()
if not path or not token:
    sys.exit(0)
try:
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(10)
    conn.connect(path)
    conn.sendall(json.dumps({"token": token, "tool": "__turn_presence__", "args": {}},
                            ensure_ascii=True).encode("ascii") + b"\n")
    buf = b""
    while b"\n" not in buf and len(buf) < 65536:
        chunk = conn.recv(65536)
        if not chunk:
            break
        buf += chunk
    conn.close()
    reply = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    verdict = json.loads(reply.get("result") or "") if reply.get("ok") else None
except Exception:
    sys.exit(0)
if not isinstance(verdict, dict) or verdict.get("live") is not False:
    sys.exit(0)
why = str(verdict.get("why") or "").strip()
if why not in HOLDABLE:
    sys.exit(0)
at_mac = False
try:
    with open(os.path.join(sys.argv[1], "presence.json"), encoding="utf-8") as fh:
        p = json.load(fh)
    at = p.get("at")
    at_mac = (p.get("active") is True and not isinstance(at, bool)
              and isinstance(at, (int, float)) and 0 <= time.time() - float(at) <= 180)
except Exception:
    at_mac = False
print(("card" if at_mac else "hold") + "\t" + why)
PY
}
hold_for_owner() { # why — the moe-connectors held-send note, in the owner's inbox
  python3 - "$MOE_HOME" "$1" "$CHANNEL" "$TO" "$TOOL" "$KIND" "$HEADLINE" "$BODY" <<'PY' 2>/dev/null
import json, os, re, secrets, sys, time
home, why, channel, to, tool, kind, headline, body = sys.argv[1:9]
steer = re.compile("[\x00-\x1f\x7f؜​-‏  ‪-‮⁦-⁩﻿]")
def clean(text, limit):
    text = " ".join(steer.sub(" ", str(text or "")).split())
    return text if len(text) <= limit else text[:limit - 1] + "…"
why, channel, to, tool = clean(why, 80), clean(channel, 40), clean(to, 80), clean(tool, 60)
if kind == "send":
    what = "send a %s message to “%s”: “%s”" % (channel, to, clean(body, 160))
elif headline:
    what = "“%s”" % clean(headline, 120).rstrip("?")
else:
    what = "do a %s step on %s" % (channel, to or "a site")
text = "Waiting on you: %s wanted to %s. Nothing was done." % (why, what)
inbox = os.path.join(home, "inbox")
key = "%s|%s|%s" % (tool, channel, to)
now = time.time()
os.makedirs(inbox, mode=0o700, exist_ok=True)
# One note per thing per hour: a job pressing Follow twenty times asks once.
for name in os.listdir(inbox):
    try:
        with open(os.path.join(inbox, name), encoding="utf-8") as fh:
            old = json.load(fh)
    except Exception:
        continue
    if (isinstance(old, dict) and old.get("source") == "held-send" and old.get("held_key") == key
            and now - float(old.get("at") or 0) < 3600):
        print("already")
        sys.exit(0)
instruction = (
    "This is a step that %s wanted to take while the person was away from the Mac (%s, %s on "
    "%s), held for their yes. Nothing was done. If — and only if — they now say to go ahead, "
    "do that step again with them; the confirmation card will show it before anything happens. "
    "If they say no, or say nothing about it, do not do it." % (why, tool, channel, to or "-"))
expired = "That %s step%s was never answered, so it expired — nothing was done." % (
    channel, (" on %s" % to) if to else "")
note = {"text": text, "at": now, "source": "held-send", "job": "", "chat_id": "screen",
        "said": "", "job_id": "", "loops": [], "instruction": instruction,
        "expired_text": expired, "held_key": key}
path = os.path.join(inbox, "%d-%s.json" % (int(now * 1000), secrets.token_hex(4)))
old = os.umask(0o077)
try:
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(note, fh)
finally:
    os.umask(old)
os.replace(path + ".tmp", path)
print("held")
PY
}
UNATTENDED_ROUTE=""; UNATTENDED_WHY=""
if [ -x /usr/bin/osascript ] || [ "${MOE_HOOK_TEST:-}" = "1" ]; then
  _route="$(turn_unattended)"
  case "$_route" in
    card$'\t'*|hold$'\t'*) UNATTENDED_ROUTE="${_route%%$'\t'*}"; UNATTENDED_WHY="${_route#*$'\t'}" ;;
  esac
fi
# The signed-out card (the classifier's _SIGNED_OUT_CHANNEL): a question about
# who the browser is, not a step on a site, and worded as that below.
SIGNED_OUT_CARD=""
[ "$CHANNEL" = "browser signed-out" ] && SIGNED_OUT_CARD=1
if [ "$UNATTENDED_ROUTE" = hold ] && [ -n "$SIGNED_OUT_CARD" ]; then
  # Refused, and quiet: no note in the inbox. A held send is a prepared thing
  # one tap finishes; "may the job that already ended browse signed out?" is
  # not — a yes tomorrow has nothing left to run, and the job's own report is
  # where what is waiting gets said (docs/INBOX-QUIET.md: every card carries a
  # do-it, or it stays out).
  log refused "$TOOL_NAME" "$TO"
  block "Not done — Moe's browser could not open signed in, and carrying on signed out needs the owner's yes. This came from $UNATTENDED_WHY while the owner is away from the Mac, so nobody could be asked and nothing ran. This was Moe's gate, not the site. Do not call it again with allow_signed_out and do not try another way to browse signed out in this run: report what is waiting, and that it needs their signed-in browser or their yes."
fi
if [ "$UNATTENDED_ROUTE" = hold ]; then
  if HELD="$(hold_for_owner "$UNATTENDED_WHY")" && [ -n "$HELD" ]; then
    ASKED="Moe asked the owner for their OK in their inbox on the Mac"
    [ "$HELD" = already ] && ASKED="the owner has already been asked for their OK in their inbox on the Mac"
  else
    ASKED="Moe could not put the question in the owner's inbox either"
  fi
  log held "$TOOL_NAME" "$TO"
  case "$KIND" in
    send) DID="the $CHANNEL message to $TO was not sent" ;;
    *)    DID="nothing was typed, pressed or sent on ${TO:-the page}" ;;
  esac
  block "Not done — this needs the owner's OK, and $DID. It came from $UNATTENDED_WHY while the owner is away from the Mac, so Moe's send gate held it instead of waiting on a confirmation card; $ASKED. This was the gate, not the site: the step never ran, so do not conclude the page ignored it, and do not retry it or try another way (another click method, page script or tool) in this run. Report that it is waiting on the owner's OK."
fi
# Background work with the owner at the Mac: the card, saying who asked, and
# giving up inside this hook's budget so the answer is "nobody answered".
CARD_DEADLINE=$(( $(/bin/date +%s) + HOOK_BUDGET_SECONDS - CARD_MARGIN_SECONDS ))
case "${MOE_CONFIRM_DEADLINE:-}" in
  ''|*[!0-9]*) ;;
  *) [ "$MOE_CONFIRM_DEADLINE" -lt "$CARD_DEADLINE" ] && CARD_DEADLINE="$MOE_CONFIRM_DEADLINE" ;;
esac
CARD_ORIGIN="${MOE_CONFIRM_ORIGIN:-}"
[ "$UNATTENDED_ROUTE" = card ] && CARD_ORIGIN="$UNATTENDED_WHY"

remember_session_all() { # "Allow everything this session": every class, this key
  ( umask 077
    d="$MOE_HOME/gate"
    mkdir -p "$d" || exit 1
    python3 - "$d" <<'PY'
import json, os, sys, time
d = sys.argv[1]
pending = os.path.join(d, "session-sends.json.pending")
current = os.path.join(d, "session-sends.json")
state = None
for path in (pending, current):
    try:
        with open(path, encoding="utf-8") as fh:
            state = json.load(fh)
        break
    except Exception:
        continue
if not isinstance(state, dict):
    sys.exit(1)
sess = state.get("asking") or state.get("session") or ""
if not sess:
    sys.exit(1)
grants = state.get("grants") if isinstance(state.get("grants"), dict) else {}
grants[sess + "|all"] = time.time()
state["grants"] = grants
tmp = current + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(state, fh)
os.replace(tmp, current)
try:
    os.remove(pending)
except OSError:
    pass
PY
  )
}

remember_session() { # promote the pending session grant, after approval
  # The classifier wrote the session id to a .pending file before asking; it
  # could not write the grant itself, because at that point the person had
  # not answered. Promoting it here is what makes "yes" mean the session
  # rather than the message.
  ( umask 077
    d="$MOE_HOME/gate"
    [ -f "$d/session-sends.json.pending" ] || exit 1
    mv "$d/session-sends.json.pending" "$d/session-sends.json"
  )
}

remember_allowed() { # tool — "Always allow" was pressed in the dialog
  ( umask 077
    mkdir -p "$MOE_HOME/gate" || exit 1
    python3 - "$MOE_HOME/gate/policy.json" "$1" <<'PY'
import datetime, json, os, sys
path, tool = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    data = {}
if not isinstance(data, dict):
    data = {}
data.setdefault("version", 1)
tools = data.setdefault("tools", {})
tools[tool] = {"decision": "run", "by": "you, in the dialog",
               "when": datetime.datetime.now().isoformat(timespec="seconds")}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=1, sort_keys=True)
    fh.write("\n")
os.replace(tmp, path)
PY
  )
}
# The dialog may hand the message back rewritten. Whether it is offered the
# chance depends on whether the words can be put back: a body found at a
# path in the call can be; one assembled from positional arguments, or a
# call shown as "what Moe is passing", cannot, and is shown read-only.
EDIT_ARG=no
case "$EDIT_MAP" in *'"body": ['*) EDIT_ARG=yes ;; esac
EDIT_OUT="$(mktemp "${TMPDIR:-/tmp}/moe-confirm-edit.XXXXXX")" || EDIT_OUT=/dev/null
# confirm.sh's stderr is kept, for one reason: on a runtime with no screen it
# says WHY nothing was sent — nobody could be asked from here, the person did
# not approve it, nobody answered — as one "not sent — …" line. Discarded, the
# model was told "you cancelled the confirmation dialog" about a dialog that
# never existed, and repeated it to a person who was never asked.
ERR_OUT="$(mktemp "${TMPDIR:-/tmp}/moe-confirm-err.XXXXXX")" || ERR_OUT=/dev/null
TEMPS=""  # never /dev/null: that is not ours to remove
[ "$EDIT_OUT" != /dev/null ] && TEMPS="$EDIT_OUT"
[ "$ERR_OUT" != /dev/null ] && TEMPS="$TEMPS $ERR_OUT"
[ -n "$TEMPS" ] && trap 'rm -f $TEMPS' EXIT
# Who named this recipient, as the classifier found it (tools/recipients.py),
# for the dialog to say. Data, not prose: confirm.sh hands it to the dialog as
# a record of its own. Empty when the classifier said nothing about it.
PROVENANCE=""
if [ "$KIND" = send ]; then
  case "$EDIT_MAP" in
    *'"provenance"'*)
      PROVENANCE="$(printf '%s' "$EDIT_MAP" | python3 -c 'import json, sys
try:
    p = json.load(sys.stdin).get("provenance")
except Exception:
    p = None
sys.stdout.write(json.dumps(p, ensure_ascii=True) if isinstance(p, dict) else "")' 2>/dev/null)" || PROVENANCE=""
      ;;
  esac
fi
MOE_CONFIRM_PROVENANCE="$PROVENANCE" MOE_CONFIRM_DEADLINE="$CARD_DEADLINE" \
MOE_CONFIRM_ORIGIN="$CARD_ORIGIN" \
"$CONFIRM" "$CHANNEL" "$TO" "$BODY" "$TOOL" "$SERVICE" "$KIND" "$EDIT_ARG" "$DETAIL" "$HEADLINE" >"$EDIT_OUT" 2>"$ERR_OUT"
ANSWER=$?
# The last "not sent — <why>" line, without its prefix. Only that shape: the
# dialog's other stderr ("cancelled by user", osascript noise) is not a reason
# a model should repeat.
NOT_SENT_WHY=""
if [ "$ERR_OUT" != /dev/null ]; then
  NOT_SENT_WHY="$(grep -a '^not sent — ' "$ERR_OUT" 2>/dev/null | tail -n 1 | sed 's/^not sent — //' | cut -c1-300)"
fi
if [ "$ANSWER" -eq 0 ]; then
  if [ "$KIND" = session ] && remember_session; then
    log allowed-session "$TOOL_NAME" "$TO"
  else
    log approved "$TOOL_NAME" "$TO"
  fi
  exit 0
fi
if [ "$ANSWER" -eq 6 ] && [ "$KIND" = session ]; then
  # "Allow everything this session". Every browser class and every screen
  # send, for this conversation, until it has been quiet for an hour. Never
  # another tool's sends (gmail still asks) and never for good.
  if remember_session_all; then
    log allowed-everything "$TOOL_NAME" "$TO"
  else
    log approved "$TOOL_NAME" "$TO"
    printf 'confirm-send hook: could not save "allow everything" for this session; it ran this once\n' >&2
  fi
  exit 0
fi
if [ "$ANSWER" -eq 5 ] && [ "$KIND" = "send" ] && [ "$EDIT_ARG" = "yes" ]; then
  # Send, as rewritten: the new words go back where the old ones were, and
  # Hermes is handed the modified call. Every way this can fail — a record
  # that did not come back, a path that no longer resolves, a subject
  # rewritten where the call has no subject field — is a refusal, not a
  # send of the original: the person approved the words they typed, not
  # the ones they replaced.
  # The call goes in through a file, not stdin: the script below arrives on
  # stdin as a here-document, and a pipe into the same python would be the
  # heredoc's — the exact mistake the classifier's own comment warns about.
  CALL_FILE="$(mktemp "${TMPDIR:-/tmp}/moe-confirm-call.XXXXXX")" || CALL_FILE=""
  [ -n "$CALL_FILE" ] && trap 'rm -f $TEMPS "$CALL_FILE"' EXIT
  printf '%s' "$RAW_CALL" >"${CALL_FILE:-/dev/null}"
  MODIFIED="$(python3 - "$EDIT_MAP" "$EDIT_OUT" "$CALL_FILE" <<'PY'
import json, re, sys
try:
    payload = json.loads(open(sys.argv[3], encoding="utf-8").read())
    where = json.loads(sys.argv[1] or "{}")
    records = open(sys.argv[2], "rb").read().split(b"\0")
except (ValueError, OSError, IndexError):
    sys.exit("the dialog's answer could not be read")
args = payload.get("tool_input")
if args is None:
    args = payload.get("args")
if not isinstance(args, dict):
    sys.exit("the call has no arguments to rewrite")
bad = re.compile("[\x00-\x08\x0b-\x1f\x7f\u2028\u2029\u202a-\u202e\u2066-\u2069]")
edits = {}
for rec in records:
    key, sep, value = rec.partition(b"=")
    if sep and key in (b"body", b"subject"):
        text = value.decode("utf-8", "replace")
        if bad.search(text.replace("\n", "").replace("\t", "")):
            sys.exit("the rewritten text carries a character that cannot be shown")
        edits[key.decode("ascii")] = text
if not edits:
    sys.exit("the dialog said the message was rewritten but handed nothing back")
body = edits.get("body")
subject = edits.get("subject")
# The hook put "Subject: …" on the front of the body it showed. A dialog
# that drew that as a Subject field returns the two apart; one that drew it
# as the first line of the message returns them together, and they are
# taken apart here so the subject goes back to its own field.
if body is not None and subject is None and where.get("composed_subject"):
    first, nl, rest = body.partition("\n")
    if first.startswith("Subject: ") and rest.startswith("\n"):
        subject, body = first[len("Subject: "):], rest[1:]
def put(path, value):
    node = args
    for step in path[:-1]:
        node = node[step]
    node[path[-1]] = value
try:
    if body is not None:
        if not where.get("body"):
            sys.exit("the message was rewritten, but this call has no one field it can be put back into")
        put(where["body"], body)
    if subject is not None:
        if not where.get("subject"):
            sys.exit("the subject was rewritten, but this call has no subject field")
        put(where["subject"], subject)
except (KeyError, IndexError, TypeError):
    sys.exit("the rewritten words could not be put back into the call")
sys.stdout.write(json.dumps({"decision": "modify", "tool_input": args}, ensure_ascii=False))
PY
  )"
  MODIFY_STATUS=$?
  if [ "$MODIFY_STATUS" -eq 0 ] && [ -n "$MODIFIED" ]; then
    log approved-edited "$TOOL_NAME" "$TO"
    printf '%s\n' "$MODIFIED"
    exit 0
  fi
  log block "$TOOL_NAME" "$TO"
  block "Not sent: you rewrote the message in the confirmation dialog, but Moe could not put the new words into this call. Tell the user what they typed was not sent, and offer to send it again with that wording."
fi
if [ "$ANSWER" -eq 4 ] && [ "$KIND" = "act" ]; then
  if remember_allowed "$TOOL"; then
    log allowed-always "$TOOL_NAME" "$TO"
  else
    log approved "$TOOL_NAME" "$TO"
    printf 'confirm-send hook: could not save your "always allow" for %s; it ran this once\n' "$TOOL" >&2
  fi
  exit 0
fi
if [ "$ANSWER" -eq 7 ]; then
  # Withdrawn: nobody answered before the card's deadline (CARD_DEADLINE,
  # inside this hook's budget) or whoever asked went away. Said as that, and
  # as the gate's doing — never "timed out", which a model reads as the site.
  log expired "$TOOL_NAME" "$TO"
  case "$KIND" in
    send) DID="the $CHANNEL message to $TO was not sent" ;;
    *)    DID="nothing was typed, pressed or sent on ${TO:-the page}" ;;
  esac
  [ -n "$SIGNED_OUT_CARD" ] && DID="nothing ran in a signed-out browser"
  block "Not done — nobody answered Moe's confirmation card on the Mac in time, so $DID. This was the send gate waiting for the owner's OK, not the site: the step never ran. Tell the user it is waiting on their OK, and do not retry it or try another way unless they ask."
fi
if [ -n "$NOT_SENT_WHY" ]; then
  # A surface that was not a dialog refused, and said why. Its words, not
  # "you cancelled": on the away machine "there is no way to ask you about
  # this from here" means nobody was asked at all.
  log not-sent "$TOOL_NAME" "$TO"
  if [ -n "$SIGNED_OUT_CARD" ]; then
    block "Not done (continuing in a signed-out browser): $NOT_SENT_WHY. Nothing ran. Tell the user exactly that, and do not call it again with allow_signed_out unless they say yes."
  fi
  if [ "$KIND" = "act" ]; then
    block "Not done ($CHANNEL action, $TOOL): $NOT_SENT_WHY. Tell the user exactly that, and do not retry unless they ask."
  fi
  block "Not sent (the $CHANNEL message to $TO): $NOT_SENT_WHY. Tell the user exactly that, and do not retry unless they ask."
fi
log cancelled "$TOOL_NAME" "$TO"
if [ "$KIND" = "act" ]; then
  # Name the SERVICE first, then the tool id in brackets. $CHANNEL is the
  # dialog's heading — "Google Drive" for a broker's tool, the server's own
  # name otherwise — and it is what the model will repeat to the person. The
  # tool id stays, because it is what makes the event findable in a log.
  block "Not done: you cancelled the confirmation dialog for this $CHANNEL action ($TOOL). Tell the user, and do not retry unless they ask."
fi
# The browser's own cards are not messages: say what did NOT happen, in the
# words the model will repeat to the person (2026-09-29: "Was there a
# password created? Why didn't it work?").
case "$CHANNEL" in
  "browser account")
    block "Not done: you cancelled the confirmation card, so no account was created on $TO and no password was made. Tell the user that, and do not retry unless they ask." ;;
  "browser signed-out")
    block "Not done: the person said no to carrying on signed out, so nothing ran. Do not call it again with allow_signed_out and do not try another way to browse signed out in this conversation unless they ask. Tell them what is waiting on their signed-in browser." ;;
  browser\ *)
    block "Not done: you cancelled the confirmation card for this step on $TO, so nothing was typed, pressed or sent. Tell the user, and do not retry unless they ask." ;;
esac
block "Not sent: you cancelled the confirmation dialog for the $CHANNEL message to $TO. Tell the user, and do not retry unless they ask."
