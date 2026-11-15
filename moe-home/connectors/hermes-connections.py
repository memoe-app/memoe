#!/usr/bin/env python3
"""What is connected through Hermes on this machine, with real status.

The companion of hermes-catalog.py (what *could* be connected). This one
reads the live Hermes state under $HERMES_HOME —

  config.yaml        mcp_servers.<name>, platforms.<name>.enabled
  .env               which keys are set (names only; a value never leaves
                     this process, and the one we use — API_SERVER_KEY, to
                     ask the gateway — is sent to 127.0.0.1 and nothing else)
  mcp-tokens/*.json  OAuth token presence and expiry
  auth.json          provider logins Hermes keeps itself (spotify)
  <credential files> skills' required_credential_files (a token beside .env …)

— and one file under $MOE_HOME: watch/.skipped.json, the table the person's
cloud computer sends back naming the watches it holds a recipe for but could
not schedule because the connection never reached it (docs/LOOPS.md §4, S6).
A connection named there gets one more sentence on its row, and loses it the
moment the table no longer names it.

— and then, where it is cheap, asks for the truth rather than trusting a
file: `hermes mcp test <name>` for an MCP server, the gateway's
/health/detailed for a platform. A token on disk is not a connection;
PRODUCT.md §4.4 calls the real check the strength worth keeping.

  hermes-connections.py [list] [--live] [--json]
        one line per configured connection:  <kind>/<name>\t<state>: <detail>
        --live adds the real checks (a few seconds); default is files only
        --json: {"connections": [...one object per line above...],
                 "pending_pairings": [...]} — the pairing requests waiting
        for an Approve (hermeslib.pending_pairings: platform, request_id,
        user_name, user_id, age_minutes, created_at), so the app shows the
        button without a second call. Was a bare array before 2026-08-30.
  hermes-connections.py names           just "<kind>/<name>": files, plus
        Composio's list (its last one when under five minutes old)
  hermes-connections.py status <kind>/<name>
        the connector contract: prints "ok: …" | "needs-setup: …" |
        "unavailable: …", exit 0 / 1 / 3 — what doctor.sh and
        lib/connectors.sh run for a virtual connector. Always live.
  hermes-connections.py manifest <kind>/<name>
        KEY=value lines in the connectors/*.manifest format, so
        connector_field works on a virtual connector. Offline for anything
        but a Composio service, and that from Composio's last answer when it
        is under five minutes old (MOE_COMPOSIO_CACHE_SECONDS).
  hermes-connections.py brief           the same list as a few lines for the
        model's system prompt (what sync.sh writes to context/_connections.md)
  hermes-connections.py refresh         write that to
        $MOE_HOME/context/_connections.md now, atomically — and the same
        facts as JSON to _connections.json beside it, which travels to the
        person's cloud computer (the `context/connections` document) so a
        machine with no Mac knows what is behind COMPOSIO_SEARCH_TOOLS.
        connect.sh runs this after anything that changes a connection, so Moe
        knows about a mailbox the moment it is added instead of on the next
        ten-minute sync.
  hermes-connections.py pull …          exit 1, nothing: Hermes's tools are
        live, not cached context — sync.sh never pulls these.
  hermes-connections.py crawl <kind>/<name> [--since N]
        read-only GATHER of any MCP connection: lib/mcp_autoread discovers the
        connection's tools, keeps only safe metadata reads, a no-tools turn
        picks the calls, and lib/mcp_read executes them — the gathered text on
        stdout, flag-stripped and bounded. Nothing (exit 0) if nothing readable.

$HOME / $HERMES_HOME / $HERMES_BIN redirect everything (tests). No browser
is ever opened: every hermes subprocess runs with SSH_TTY set and stdin
closed, which is what makes Hermes's OAuth code print a URL instead of
launching one.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hermeslib as H  # noqa: E402

H.ensure_yaml()

# Import the catalog for the skill/platform credential lists. It is a
# script, not a module, so load it by path.
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("hermes_catalog", os.path.join(HERE, "hermes-catalog.py"))
CAT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(CAT)

MCP_TEST_TIMEOUT = int(os.environ.get("MOE_MCP_TEST_TIMEOUT", "20"))
GATEWAY_TIMEOUT = 3
# `list --live` runs one check per connection; ten stalled MCP servers must
# not turn into minutes. Past the budget the rest are reported unchecked.
LIVE_BUDGET = int(os.environ.get("MOE_LIVE_BUDGET", "60"))
CONNECT = "run ~/.moe/scripts/connect.sh"
# `list --live` no longer opens an OAuth session of its own for every
# signed-in MCP server. Each `hermes mcp test` is a fresh process holding its
# own copy of the token; when the access token has run out (Cloudflare's
# lasts an hour) that process refreshes it — and the gateway, which loaded
# the same token at start-up, is then refreshing with a refresh token the
# server may already have retired. Whichever of the two loses reports
# "sign-in needed", and the person signs in to Cloudflare again for the
# third time that day. The gateway is the one process that should ever
# renew a token; a status check reads the files it keeps and asks its log
# whether it has given up on the server (`gateway_parked`). Set
# MOE_MCP_LIVE_OAUTH=1 to get the old behaviour for one deliberate check.
LIVE_OAUTH = os.environ.get("MOE_MCP_LIVE_OAUTH") == "1"


#: Moe's own Slack app's marker, written by `channels.py slack-status`. Its own
#: file on purpose: `channel-slack.json` means a migrated Slack app of the
#: person's OWN and is read by `cloud_holder_row`; neither reader falls back to
#: the other file (channels.py `MOE_SLACK_MARKER` says why).
MOE_SLACK_MARKER = "channel-slack-moe.json"


#: Moe's email address's marker (slice G3), written by `channels.py
#: email-status`. `moemail`, never `email`: the Hermes platform called `email`
#: is the person's own mailbox and has its own row.
MOE_EMAIL_MARKER = "channel-moemail.json"
#: What the Email row says when mail from the person's own address could not
#: be verified (the edge's `email_app.OWNER_UNVERIFIED_SENTENCE`, the same words).
MOE_EMAIL_UNVERIFIED = ("An email from you couldn't be verified. Mail forwarded from another "
                        "account often fails this check, or someone may be pretending to be "
                        "you. Send it to Moe directly.")


def moe_email_connections():
    """The Email row for Moe's own address -- not a Hermes platform at all, so
    it is not in the catalog and gets its row here, as `platform/moemail`.

    From the marker alone: no marker is no row (the screen draws "not
    connected" and *Choose my address*); `available` false is "not available
    yet"; an address is connected, and the row carries it as `address` for the
    screen's Copy button."""
    try:
        with open(os.path.join(moe_home(), "cloud", MOE_EMAIL_MARKER), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    row = {"kind": "platform", "name": "moemail", "label": "Email", "auth": "one-click",
           "credentials": []}
    if data.get("available", True) is False:
        return [dict(row, state="unavailable", address="",
                     detail="not available yet — Moe's cloud isn't set up for email")]
    address = H.one_line(str(data.get("address") or ""), 80)
    if not address:
        return []
    owners = [H.one_line(str(a), 80) for a in (data.get("owner_addresses") or [])
              if isinstance(a, str)][:3]
    detail = "Write to Moe at %s" % address
    if owners:
        detail += (" — mail from %s is yours; anyone else has to be let in first"
                   % ", ".join(owners))
    # Mail from the person's own address that the cloud could not verify, in
    # the last week (slice G3): never delivered, and said here, where they look.
    unverified = data.get("unverified") if isinstance(data.get("unverified"), dict) else None
    if unverified and unverified.get("events"):
        detail += ". " + moe_email_unverified_line(unverified)
    replies = data.get("replies") if isinstance(data.get("replies"), dict) else {}
    said = moe_email_replies_lines(replies)
    if said:
        detail += ("" if detail.endswith(".") else ".") + " " + " ".join(said)
    return [dict(row, state="ok", detail=detail, address=address)]


#: Why an email from the person's own address failed the check, in their terms.
MOE_EMAIL_UNVERIFIED_WHY = {
    "no_signature": "it wasn't signed",
    "bad_signature": "its signature didn't match",
    "misaligned": "it was signed by a different address",
    "dns_timeout": "its signature couldn't be checked in time",
    "weak_algorithm": "it was signed the old, weak way",
    "wrong_recipient": "it was written to a different address, not to your Moe address",
    # Kept for a row written before reply-to-confirm (D1): such mail is now
    # asked about by email rather than refused.
    "unsigned_recipient": "your email provider doesn't sign who an email is sent to, so Moe "
                          "can't tell it was written to Moe",
    # Only a line the signature covers appearing twice, since D2: an unsigned
    # extra line is ignored, not refused.
    "unsigned_header": "a line it was signed with appears in it twice",
    "stale": "it was sent more than two days ago, or its date is wrong or unsigned",
}

#: For `provider_domain` the usual advice is wrong: nothing was forwarded and
#: nobody is pretending. A Google Workspace domain with no DKIM of its own is
#: signed as `<domain>.<date>.gappssmtp.com`, and Moe cannot take that as the
#: domain's own signature. So the row says what signed it and what to do.
MOE_EMAIL_PROVIDER_DOMAIN = ("An email from you couldn't be verified: your email provider signs "
                             "mail as %s rather than as %s. Set up DKIM for %s in Google "
                             "Workspace (admin.google.com › Apps › Google Workspace › Gmail › "
                             "Authenticate email), or write to Moe from an address that is "
                             "signed as its own domain.")


def moe_email_replies_lines(replies, now=None):
    """What became of Moe's email replies this week, one sentence each, only
    for what happened (docs/EMAIL-SETUP.md §10)."""
    def n(key):
        try:
            return max(0, int(replies.get(key) or 0))
        except (TypeError, ValueError, AttributeError):
            return 0

    def when(key):
        text = _moe_email_when(str(replies.get(key) or ""), now)
        return " (the last at %s)" % text if text else ""

    lines = []
    if n("confirm_waiting"):
        lines.append("Moe emailed to check %s came from the address it says; the answer is a "
                     "reply saying YES." % ("an email" if n("confirm_waiting") == 1
                                            else "%d emails" % n("confirm_waiting")))
    if n("confirm_held"):
        lines.append("%s this week had to wait to be checked because too many arrived in an "
                     "hour%s; each is tried again for about a day and a half."
                     % (_moe_count(n("confirm_held"), "email", "emails").capitalize(),
                        when("confirm_held_at")))
    if n("approvals"):
        lines.append("Moe needed your OK for something while answering an email, and it doesn't "
                     "ask for that by email, so that step wasn't done%s." % when("approvals_at"))
    if n("unsent"):
        lines.append("%s of Moe's email replies this week couldn't be sent%s."
                     % (_moe_count(n("unsent")), when("unsent_at")))
    if n("late_parts"):
        lines.append("%s of Moe's email replies this week came too late to send%s."
                     % (_moe_count(n("late_parts"), "part", "parts"), when("late_at")))
    if n("follow_ups"):
        lines.append("%s this week took Moe more than two minutes and came in a second email%s."
                     % (_moe_count(n("follow_ups"), "reply", "replies"), when("follow_up_at")))
    if n("held_back"):
        lines.append("Moe kept %s about its own work (like \"still on it\") out of your email "
                     "this week." % _moe_count(n("held_back"), "status note", "status notes"))
    return lines


def _moe_count(k, one="", many=""):
    """"One" / "2" on their own, or "one part" / "2 parts"."""
    if not one:
        return "One" if k == 1 else str(k)
    return "one %s" % one if k == 1 else "%d %s" % (k, many)


def _moe_email_when(raw, now=None):
    try:
        import datetime as _dt
        at = _dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone()
        today = (_dt.datetime.now().astimezone() if now is None else now).date()
        return at.strftime("%H:%M") if at.date() == today else at.strftime("%b %d, %H:%M")
    except (ValueError, TypeError):
        return ""


def moe_email_unverified_line(unverified, now=None):
    """The row's sentence with what the cloud said on THIS read: how many this
    week, when the last one came, and why -- so a second failure shows even
    when the alert stays silent."""
    try:
        events = int(unverified.get("events") or 0)
    except (TypeError, ValueError):
        events = 0
    if str(unverified.get("reason") or "") == "provider_domain":
        signer = H.one_line(str(unverified.get("signer") or "its own domain"), 80)
        domain = H.one_line(str(unverified.get("domain") or "your domain"), 80)
        return MOE_EMAIL_PROVIDER_DOMAIN % (signer, domain, domain)
    when = ""
    raw = str(unverified.get("at") or "")
    try:
        import datetime as _dt
        at = _dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone()
        today = (_dt.datetime.now().astimezone() if now is None else now).date()
        when = at.strftime("%H:%M") if at.date() == today else at.strftime("%b %d, %H:%M")
    except (ValueError, TypeError):
        when = ""
    why = MOE_EMAIL_UNVERIFIED_WHY.get(str(unverified.get("reason") or ""),
                                       "it couldn't be checked")
    count = "%d this week" % events if events != 1 else "one this week"
    head, _, rest = MOE_EMAIL_UNVERIFIED.partition(". ")
    return "%s (%s, the last%s: %s). %s" % (head, count, " at " + when if when else "", why, rest)


def _slack_app_marker():
    try:
        with open(os.path.join(moe_home(), "cloud", MOE_SLACK_MARKER), encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return None


def _slack_app_linked():
    """Whether Moe's own Slack app is LINKED in some workspace. A marker from
    before the field existed was only ever written when linked. An install
    waiting for this Mac's word is not linked, and reaches nothing."""
    data = _slack_app_marker()
    return data is not None and data.get("linked", True) is not False


def _slack_app_unavailable():
    """Whether Moe's cloud said Add to Slack cannot work there yet (third
    review of slice G1): no Google web client for the install page to prove the
    account with, or no Slack app. `channels.py` writes `available` from the
    cloud's answer; a marker without the field is taken as available."""
    data = _slack_app_marker()
    return data is not None and data.get("available", True) is False


def _slack_app_trouble():
    """What Moe's cloud said went wrong per Slack workspace (fourth review of
    slice G1): `removed` — Moe was revoked there because Slack refused its key —
    and `last_failure`, the latest reason a reply there was given up on."""
    data = _slack_app_marker() or {}
    return [t for t in (data.get("trouble") or []) if isinstance(t, dict)]


#: How often the live pass may ask the cloud again whether Add to Slack has
#: become available, while the row says it is not (fourth review of slice G1).
#: `channels.py slack-status` rewrites the marker's `at` on every answer, so a
#: cloud that is still not ready is asked at most once per this interval.
SLACK_RECHECK_S = 180


def recheck_slack_availability(now=None):
    """**The Connections refresh re-reads whether Add to Slack is available.**

    The row flipped to "not available yet" on the cloud's word and nothing
    ever asked again except `connect.sh --status platform/slack`, which the
    screen runs only while connecting — so an owner who added the Google web
    client left every Mac's row saying "not available yet" for ever. Called by
    `list --live` (the second pass of every Connections load and Re-check):
    one quiet `channels.py slack-status`, only while the marker says
    unavailable, and only when its answer is older than `SLACK_RECHECK_S`.
    Returns whether it asked."""
    data = _slack_app_marker()
    if data is None or data.get("available", True) is not False:
        return False
    now = time.time() if now is None else now
    try:
        at = float(data.get("at") or 0)
    except (TypeError, ValueError):
        at = 0.0
    if now - at < SLACK_RECHECK_S:
        return False
    # The ask is stamped HERE, before it is made: a cloud that answers with an
    # error (503, a timeout) leaves the marker as it was, and without this
    # every refresh would ask again.
    path = os.path.join(moe_home(), "cloud", MOE_SLACK_MARKER)
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(dict(data, at=int(now)), fh)
        os.replace(tmp, path)
    except OSError:
        return False
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "channels.py")
    try:
        subprocess.run([script, "slack-status", "--quiet"], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return True
    return True


def slack_install_pairings():
    """Installs of Moe's own Slack app waiting for this Mac's word, in the
    `pending_pairings` shape Connections already renders with an Approve
    button (`Pairing.parse`): platform `slack_link`, the 16-hex id, and the
    workspace and Slack name as the one line a person reads. `pairing.sh
    approve slack_link <id>` is what the button runs."""
    data = _slack_app_marker() or {}
    out = []
    for p in data.get("pending") or []:
        if not isinstance(p, dict):
            continue
        pid = str(p.get("id") or "")
        if len(pid) != 16 or any(c not in "0123456789abcdef" for c in pid):
            continue
        who = "Slack workspace %s" % (" ".join(str(p.get("workspace") or "").split())[:80]
                                       or "(unnamed)")
        name = " ".join(str(p.get("as") or "").split())[:60]
        out.append({"platform": "slack_link", "request_id": pid,
                    "user_name": who + (" as %s" % name if name else ""), "user_id": ""})
    return out


def cloud_channel_knocks():
    """Somebody who messaged a channel the cloud holds and is waiting to be
    let in, in the `pending_pairings` shape (`Pairing.parse`): platform
    `cloud_<channel>`, the chat id zero-padded to the 16 digits the button
    carries, and the sender's name. `pairing.sh approve cloud_<channel> <id>`
    runs `channels.py approve`. Without this the Telegram sheet span on
    "Finish in Telegram…" with the owner's own hello waiting behind it and no
    button anywhere to let it in (2026-11-13). A group (negative id) or an id
    longer than 16 digits is left to `channels.py knocks`."""
    try:
        with open(os.path.join(moe_home(), "cloud", "channel-holder.json"),
                  encoding="utf-8") as fh:
            held = json.load(fh) or {}
    except (OSError, ValueError):
        return []
    out = []
    for w in held.get("waiting") or []:
        if not isinstance(w, dict):
            continue
        channel, chat = str(w.get("channel") or ""), str(w.get("chat_id") or "")
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,24}", channel) \
                or not chat.isdigit() or len(chat) > 16:
            continue
        who = " ".join(str(w.get("sender") or "").split())[:60]
        out.append({"platform": "cloud_" + channel, "request_id": chat.zfill(16),
                    "user_name": who, "user_id": ""})
    return out


def _slack_app_receiving():
    """Whether Moe's own Slack app's marker says the cloud's socket is open.

    `channels.py slack-status` writes `receiving` from the edge's answer. A
    marker without the field (an older edge) is taken as receiving, and an
    unreadable one too: this screen must open offline, and the field only
    ever turns a green row amber, never the other way round.
    """
    try:
        with open(os.path.join(moe_home(), "cloud", MOE_SLACK_MARKER), encoding="utf-8") as fh:
            return json.load(fh).get("receiving", True) is not False
    except (OSError, ValueError, AttributeError):
        return True


def moe_home():
    """Moe's home. `MOE_HOME` redirects it, which is how the tests run."""
    return os.environ.get("MOE_HOME") or os.path.expanduser("~/.moe")


GATEWAY_LOG = os.path.join(moe_home(), "logs", "hermes-gateway.log")

#: What the row says when the cloud computer skipped this connection's watch.
#: One sentence, the person's words, and nothing about which machine or why
#: — the why is on the machine's own log line; here the fact is what matters.
WATCH_MAC_ONLY = "Watched on your Mac only — your cloud computer doesn't hold this connection."


def watch_skipped():
    """{connection: why} from $MOE_HOME/watch/.skipped.json — the document
    the cloud computer writes (moeledger/watches.py) and the Mac applies at
    the same dotfile. Absent, empty or unreadable: nothing is skipped."""
    path = os.path.join(moe_home(), "watch", ".skipped.json")
    try:
        with open(path, encoding="utf-8") as f:
            table = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(table, dict):
        return {}
    return {str(k): str(v) for k, v in table.items() if isinstance(k, str)}


def note_watch_skips(conns):
    """Add WATCH_MAC_ONLY to the row of every connection the table names.
    After make_live, never before: a live check REPLACES the detail, and the
    sentence must survive it. The row keeps its state — a skipped watch is
    not a fault in the connection, which is working here on the Mac."""
    skipped = watch_skipped()
    if not skipped:
        return conns
    for c in conns:
        if c.get("name") not in skipped:
            continue
        detail = (c.get("detail") or "").rstrip().rstrip(".")
        c["detail"] = (detail + ". " if detail else "") + WATCH_MAC_ONLY
        c["watch"] = "mac-only"
    return conns


def signal_status():
    """`connect-signal.sh --status`, as (ok, its line). The link on disk is not
    enough to call Signal connected: the daemon also needs Signal support that
    fetch-signal-cli.sh calls ready, and a Moe release that moves the pinned
    signal-cli makes the old copy not ready — signal-daemon.sh then exits "not
    downloaded" and nothing answers, while this row, which used to look only
    at signal/account, said Connected. --status asks both questions, the same
    ones the daemon starts from. No script to ask is not a yes."""
    here = os.path.dirname(os.path.abspath(__file__))
    for d in (os.path.join(moe_home(), "scripts"),
              os.path.join(os.path.dirname(here), "scripts"),
              os.path.join(os.path.dirname(os.path.dirname(here)), "scripts")):
        script = os.path.join(d, "connect-signal.sh")
        if os.path.isfile(script):
            rc, out, err = H.run(["/bin/bash", script, "--status"], 20)
            line = next((l for l in (out or "").splitlines() if l.strip()), "") or H.one_line(err, 120)
            return rc == 0 and line.startswith("ok:"), line
    return False, "connect-signal.sh is missing"
GATEWAY_LOG_TAIL = 400_000   # bytes of the gateway log worth reading for a verdict


# ── Gather: any connected MCP connection is a read-only learn source ──────
# A connection is gatherable just by being connected — nothing about which one
# lives in code or in the shipped payload. This provider advertises `crawl`
# (cmd_crawl) for every MCP connection; learn.sh visits it under the daily deep
# pass once the person has consented. lib/mcp_autoread discovers the
# connection's own tools, keeps only the safe metadata reads, and a no-tools
# model turn picks the calls — so there is no per-connector recipe to write.


# ── State under HERMES_HOME ───────────────────────────────────────────────


CONFIG_PATH = os.path.join(H.hermes_home(), "config.yaml")


def config():
    cfg = H.load_yaml_file(CONFIG_PATH)
    return cfg if isinstance(cfg, dict) else {}


def config_unreadable():
    """config.yaml exists but could not be parsed — by PyYAML, or by the
    stdlib fallback on a construct it does not implement. Everything under
    mcp_servers/platforms is then unknown, which must read as "unavailable",
    never as "not connected" (a user would re-run a sign-in for nothing)."""
    return os.path.isfile(CONFIG_PATH) and H.load_yaml_file(CONFIG_PATH) is None


def env_keys():
    return H.env_keys(os.path.join(H.hermes_home(), ".env"))


def env_value(key):
    """One value, for the gateway bearer only. Kept out of every print."""
    try:
        with open(os.path.join(H.hermes_home(), ".env"), encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:].lstrip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return os.environ.get(key, "")


def platform_section(cfg, name):
    """platforms.<name>, also accepting gateway.platforms.<name> and
    gateway.<name> like Hermes's loader does."""
    for holder in (cfg.get("platforms"), (cfg.get("gateway") or {}).get("platforms"), cfg.get("gateway")):
        if isinstance(holder, dict) and isinstance(holder.get(name), dict):
            return holder[name]
    return {}


def mcp_token(name):
    """(present, expires_at or None, has_refresh) for an OAuth MCP server."""
    safe = "".join(ch if (ch.isalnum() or ch in "_-") else "_" for ch in name).strip("_") or "default"
    path = os.path.join(H.hermes_home(), "mcp-tokens", safe + ".json")
    try:
        with open(path, encoding="utf-8") as f:
            tok = json.load(f)
    except (OSError, ValueError):
        return False, None, False
    if not isinstance(tok, dict) or not tok.get("access_token"):
        return False, None, False
    exp = tok.get("expires_at")
    if exp is None and tok.get("expires_in") is not None:
        try:
            exp = os.stat(path).st_mtime + float(tok["expires_in"])
        except (OSError, TypeError, ValueError):
            exp = None
    return True, exp, bool(tok.get("refresh_token"))


def mcp_token_mtime(name):
    safe = "".join(ch if (ch.isalnum() or ch in "_-") else "_" for ch in name).strip("_") or "default"
    try:
        return os.stat(os.path.join(H.hermes_home(), "mcp-tokens", safe + ".json")).st_mtime
    except OSError:
        return None


_GATEWAY_LOG_LINES = None


def gateway_log_tail():
    """The last part of the gateway log, once per process."""
    global _GATEWAY_LOG_LINES
    if _GATEWAY_LOG_LINES is None:
        try:
            with open(GATEWAY_LOG, "rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - GATEWAY_LOG_TAIL))
                _GATEWAY_LOG_LINES = f.read().decode("utf-8", "replace").splitlines()
        except OSError:
            _GATEWAY_LOG_LINES = []
    return _GATEWAY_LOG_LINES


_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")


def _log_ts(line):
    m = _TS_RE.match(line)
    if not m:
        return None
    try:
        return time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    except (ValueError, OverflowError):
        return None


def gateway_parked(name, since):
    """True when the running gateway has parked MCP server `name` for an
    authentication failure *after* `since` (the token file's mtime) and has
    not reported it connected again. The gateway logs both transitions
    ("state: connecting → parked" / "parked → connected"); a park older
    than the token file was cured by the sign-in that wrote the file. The
    gateway re-reads the token file when it changes, so this is the one
    verdict that means "signed in, and the thing that uses it agrees"."""
    tag = "'%s'" % name
    verdict = False
    for line in gateway_log_tail():
        if tag not in line or "tools.mcp_tool" not in line:
            continue
        ts = _log_ts(line)
        if ts is None or (since is not None and ts < since):
            continue
        if "parking until credentials change" in line or "failed initial authentication" in line:
            verdict = True
        elif "parked → connected" in line or "state: connecting → connected" in line:
            verdict = False
    return verdict


def spotify_logged_in():
    try:
        with open(os.path.join(H.hermes_home(), "auth.json"), encoding="utf-8") as f:
            auth = json.load(f)
    except (OSError, ValueError):
        return False
    prov = auth.get("providers") if isinstance(auth, dict) else None
    sp = prov.get("spotify") if isinstance(prov, dict) else None
    return bool(isinstance(sp, dict) and (sp.get("access_token") or sp.get("refresh_token")))


# ── Live checks ───────────────────────────────────────────────────────────


def hermes_env():
    """Environment for a hermes subprocess: never a browser, never a prompt."""
    env = dict(os.environ)
    env["HERMES_HOME"] = H.hermes_home()
    env["SSH_TTY"] = env.get("SSH_TTY") or "moe"     # _can_open_browser() → False
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.pop("DISPLAY", None)
    return env


def mcp_test(name):
    """Run `hermes mcp test <name>`. Returns (state, detail). Hermes exits 0
    whatever happened, so the answer is in the text."""
    hb = H.hermes_bin()
    if not hb:
        return "unavailable", "Memoe is not fully installed — run scripts/install.sh"
    rc, out, err = H.run([hb, "mcp", "test", name], MCP_TEST_TIMEOUT, env=hermes_env())
    text = out + "\n" + err
    low = text.lower()
    if rc == -1:
        return "unavailable", H.one_line(err, 80)
    if "✓ connected" in low or "tools discovered" in low:
        n = ""
        for line in text.splitlines():
            if "tools discovered" in line.lower():
                n = line.split(":", 1)[-1].strip()
        return "ok", ("%s tools" % n if n else "connected")
    if "authorization required" in low or "hermes mcp login" in low or "401" in low or "unauthorized" in low \
            or "oauthnoninteractive" in low or "non-interactive" in low:
        return "needs-setup", "sign-in needed — %s %s" % (CONNECT, name)
    bad = next((l for l in text.splitlines() if l.strip().startswith(("✗", "Error", "error"))), "")
    return "unavailable", H.one_line(bad or err or out, 90) or "could not connect"


def gateway_platforms():
    """{name: state} from the gateway's /health/detailed, or None when the
    gateway is not answering. Bearer = API_SERVER_KEY from .env."""
    cfg = config()
    api = platform_section(cfg, "api_server")
    port = api.get("port") or os.environ.get("API_SERVER_PORT") or 8642
    host = api.get("host") or "127.0.0.1"
    # Same precedence as the gateway itself (api_server.py: config.yaml's
    # platforms.api_server.key, else API_SERVER_KEY) so we present the key
    # it will actually check; configure-hermes.py keeps the two equal.
    key = str(api.get("key") or "") or env_value("API_SERVER_KEY")
    req = urllib.request.Request("http://%s:%s/health/detailed" % (host, port),
                                 headers={"Authorization": "Bearer %s" % key})
    try:
        with urllib.request.urlopen(req, timeout=GATEWAY_TIMEOUT) as r:
            data = json.load(r)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
        return None
    plats = data.get("platforms") if isinstance(data, dict) else None
    out = {}
    if isinstance(plats, dict):
        for k, v in plats.items():
            out[str(k)] = str((v or {}).get("state", "")) if isinstance(v, dict) else str(v)
    return out


# ── The connections ───────────────────────────────────────────────────────


def gateway_toolsets():
    """[(name, enabled, configured)] from the gateway's /v1/toolsets, or None
    when the gateway is not answering.

    configure-hermes.py writes `platform_toolsets.api_server` explicitly, and
    an explicit list is the only thing Hermes honours — so the question this
    answers is not "what did we write" but "what did the running gateway
    actually load". A toolset can be listed and still arrive disabled (a
    plugin that failed to import) or unconfigured (a tool whose credential is
    missing), and neither shows up in config.yaml.
    """
    cfg = config()
    api = platform_section(cfg, "api_server")
    port = api.get("port") or os.environ.get("API_SERVER_PORT") or 8642
    host = api.get("host") or "127.0.0.1"
    key = str(api.get("key") or "") or env_value("API_SERVER_KEY")
    req = urllib.request.Request("http://%s:%s/v1/toolsets" % (host, port),
                                 headers={"Authorization": "Bearer %s" % key})
    try:
        with urllib.request.urlopen(req, timeout=GATEWAY_TIMEOUT) as r:
            data = json.load(r)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
        return None
    # Hermes has shipped this as both a bare list and {"toolsets": [...]}.
    items = data.get("toolsets", data) if isinstance(data, dict) else data
    if not isinstance(items, list):
        return None
    out = []
    for it in items:
        if isinstance(it, str):
            out.append((it, True, True))
        elif isinstance(it, dict) and it.get("name"):
            out.append((str(it["name"]),
                        bool(it.get("enabled", True)),
                        bool(it.get("configured", True))))
    return out


def mcp_connections(cfg, keys):
    servers = cfg.get("mcp_servers") if isinstance(cfg.get("mcp_servers"), dict) else {}
    out = []
    # YAML turns a server called `on`, `off`, `yes` or `no` into a bool
    # (Hermes's own loader would too); skip anything that is not a string.
    for raw, entry in sorted((k, v) for k, v in servers.items() if isinstance(k, str)):
        name = H.safe_name(raw)
        if not name or not isinstance(entry, dict):
            continue
        enabled = entry.get("enabled", True)
        enabled = enabled if isinstance(enabled, bool) else str(enabled).lower() in ("true", "1", "yes")
        auth = "oauth" if entry.get("auth") == "oauth" else ("api-key" if entry.get("headers") else "none")
        transport = "http" if entry.get("url") else ("stdio" if entry.get("command") else "?")
        c = {"kind": "mcp", "name": name, "label": name, "auth": auth, "transport": transport,
             "enabled": enabled}
        if not enabled:
            c.update(state="needs-setup", detail="switched off — turn it back on in config.yaml (mcp_servers.%s.enabled)" % name)
        elif auth == "oauth":
            present, exp, refresh = mcp_token(name)
            if not present:
                c.update(state="needs-setup", detail="sign-in needed — %s %s" % (CONNECT, name))
            elif exp is not None and exp < time.time() and not refresh:
                c.update(state="needs-setup", detail="the sign-in expired — %s %s" % (CONNECT, name))
            elif gateway_parked(name, mcp_token_mtime(name)):
                c.update(state="needs-setup", detail="the sign-in stopped working — %s %s" % (CONNECT, name))
            else:
                c.update(state="ok", detail="signed in" + (" (renews itself)" if refresh else ""))
        elif auth == "api-key":
            # headers hold "${MCP_X_API_KEY}" placeholders; the key is in .env
            hdrs = entry.get("headers") if isinstance(entry.get("headers"), dict) else {}
            wanted = re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", " ".join(map(str, hdrs.values())))
            missing = [k for k in wanted if k not in keys]
            if missing:
                c.update(state="needs-setup", detail="needs a key (%s) — %s %s" % (", ".join(missing), CONNECT, name))
            else:
                c.update(state="ok", detail="key saved")
        else:
            c.update(state="ok", detail="ready")
        out.append(c)
    return out


def skill_connections(keys):
    out = []
    for e in CAT.skill_entries():
        envs = [c for c in e["credentials"] if "." not in c]
        files = [c for c in e["credentials"] if "." in c]
        have_env = [k for k in envs if k in keys]
        have_files = [f for f in files if os.path.isfile(os.path.join(H.hermes_home(), f))]
        if not have_env and not have_files:
            continue          # not attempted → not a connection (the catalog lists it)
        c = dict(e)
        missing = [k for k in envs if k not in keys] + [f for f in files if f not in have_files]
        if missing:
            c.update(state="needs-setup", detail="needs a key (%s) — %s %s" % (", ".join(missing), CONNECT, e["name"]))
        else:
            c.update(state="ok", detail="key saved")
        out.append(c)
    return out


def relay_silences_direct_platforms():
    """True when the gateway will refuse to run ANY directly-connected
    platform, whatever config.yaml says.

    This is the fork's rule, not ours (``gateway/config.py``): a gateway that
    dials a relay switches every direct platform off, because on a hosted
    Hermes the relay is the messaging path and running both double-delivers.
    It logs one WARNING per platform per start and carries on.

    Reading config and stopping there is what let that hide. Telegram had a
    valid token, `enabled: true`, and an approved user, so every check this
    file makes said "ok" — while the gateway had logged
    "disabling directly-connected platform 'telegram'" 104 times and the bot
    accumulated updates nobody consumed. A connection is not what the config
    asks for; it is what the gateway is running.

    So this reproduces the fork's own predicate rather than inspecting the
    gateway, which would mean a socket call on a screen that must open
    instantly and answer offline. It is a copy of somebody else's rule and
    therefore the kind of thing that goes stale — `test-platform-relay-truth`
    pins it against the fork's source so a change there fails here.
    """
    if "GATEWAY_RELAY_URL" not in env_keys():
        return False        # no relay: the gateway runs its platforms as asked
    allow = (env_value("GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS") or "").strip().lower()
    return allow not in ("1", "true", "yes", "on")


def cloud_holder_row(channel, label=None):
    """The state/detail for a channel Moe's cloud holds; ``None`` when it does
    not hold it.

    ``label`` is the name a person calls this channel ("WhatsApp"), which is
    what the sentences below use. The slug is the file name, not a word anybody
    says, and it used to land on screen as "Moe's cloud receives whatsapp now".

    **Why this comes before every other branch.** A channel the cloud holds is
    switched off on this Mac by name (`configure-hermes.py::apply_channel_holder`)
    — deliberately, because Telegram permits a webhook OR ``getUpdates`` and
    never both, and a Mac that kept polling one the edge had taken made
    Telegram refuse it and the adapter delete the edge's webhook to recover
    (2026-09-14). Read without this, that platform lands in the
    "switched off — turn it back on in config.yaml" branch below, which would
    tell somebody to undo the thing keeping their bot working.

    **And before the no-credentials gate, which is what actually bit.** Being
    held by the cloud is not one of several opinions about a channel — it is
    the reason there is nothing on this Mac to find. Handing a channel over
    moves its token off this Mac, so `have` is empty and
    `platforms.<name>.enabled` is false, and `platform_connections` used to
    `continue` past such a row before ever calling this function. The row then
    did not exist at all, the app built one from the catalog with no state, and
    a WhatsApp and a Slack that the owner's cloud computer was answering both
    read "not connected" with a Connect button (2026-09-15). Worse, the Slack
    row's own `say` — a sentence `channel-holder.py` had written for him,
    asking him to reconnect it — reached no surface at all.

    Three opinions exist about a channel and this screen must show the one that
    decides. The marker is what this Mac believes; `channel-holder.json` is
    what the **provider** last said, written by `connectors/channel-holder.py`
    — never asked for here, because this screen has to open instantly and
    answer offline, and a provider call is neither.
    """
    shown = label or channel
    if not os.path.exists(os.path.join(moe_home(), "cloud",
                                       "channel-%s.json" % channel)):
        return None
    row, held = {}, {}
    try:
        with open(os.path.join(moe_home(), "cloud", "channel-holder.json"),
                  encoding="utf-8") as fh:
            held = json.load(fh) or {}
        row = (held.get("channels") or {}).get(channel) or {}
    except (OSError, ValueError):
        row, held = {}, {}
    said = row.get("say")
    # **Somebody standing at the door, on this channel.**
    #
    # A knock stops Moe replying and nothing said so anywhere: the owner met
    # exactly that on 2026-09-14 and concluded their Moe was broken. It is not
    # a fault of the channel's — a perfectly held channel can have somebody
    # waiting — so it is its own line, and it is shown whether or not the
    # channel is otherwise well. `channel-holder.py` writes it; that file is
    # the one thing on this screen that has actually asked the cloud.
    waiting = [w for w in (held.get("waiting") or [])
               if isinstance(w, dict) and w.get("channel") == channel]
    if waiting and not said:
        who = (str(waiting[0].get("sender") or "").replace("\n", " ")[:60]
               or str(waiting[0].get("chat_id") or ""))
        detail = (("%s messaged Moe here and is waiting to be let in. Moe does "
                   "not answer anybody who has not been let in, so nothing has "
                   "been sent to them." % H.one_line(who, 80))
                  if len(waiting) == 1 else
                  "%d chats have messaged Moe here and are waiting to be let in. "
                  "Moe does not answer anybody who has not been let in, so "
                  "nothing has been sent to them." % len(waiting))
        return {"state": "needs-setup",
                "detail": detail + " Approve them above to let them in."}
    if said:
        # channel-holder.py wrote this for a person and it names the channel
        # and what has gone wrong. It never carries a token or a webhook path.
        return {"state": "needs-setup",
                "detail": "%s Moe is putting it back; if it keeps happening, "
                          "connect %s again in Settings › Away."
                          % (H.one_line(str(said), 220), shown)}
    return {"state": "ok",
            "detail": "Connected — your cloud computer answers %s, so it keeps "
                      "working while this Mac is closed. Anyone who messages "
                      "there has to be approved in Connections first" % shown}


def platform_connections(cfg, keys):
    out = []
    silenced = relay_silences_direct_platforms()
    for e in CAT.platform_entries():
        sec = platform_section(cfg, e["name"])
        explicit = sec.get("enabled") if isinstance(sec.get("enabled"), bool) else None
        have = [k for k in e["credentials"] if k in keys]
        # Moe's own Slack app (slice G1): added in one click, so there are no
        # keys on this Mac at all — what says it is connected is the marker
        # `channels.py slack-status` leaves. It has to be decided HERE, before
        # the no-keys gate below: behind it, the row was skipped (no keys, and
        # `platforms.slack.enabled` false or absent) and a Slack added in one
        # click read "not connected" for ever. A Mac with keys of its own is
        # a Slack app of its own, and the paths below still answer for it.
        one_click = e["name"] == "slack" and not have and _slack_app_linked()
        # And a Slack that cannot be added in one click yet: the catalog marks
        # Slack one-click unconditionally, so without this the row offered
        # Add to Slack on a cloud that refuses every install (third review of
        # slice G1). "unavailable" is the row's "Not available yet".
        unavailable = (e["name"] == "slack" and not have and not one_click
                       and _slack_app_unavailable())
        # And a Slack Moe was revoked from because Slack refused its key
        # (fourth review of slice G1): nothing is linked any more, and the row
        # has to say why rather than vanish.
        removed = ([t for t in _slack_app_trouble() if t.get("removed")]
                   if e["name"] == "slack" and not have and not one_click else [])
        # **Asked BEFORE the gate below, and this is the whole point.** Handing
        # a channel to the cloud takes its credential off this Mac and switches
        # it off here by name, so a held channel has no keys and no
        # `enabled: true` — exactly the shape the gate drops. Dropped, it is not
        # in the answer at all, and the app draws it from the catalog with no
        # state: "not connected", with a Connect button, over a channel the
        # person's cloud computer is answering. See `cloud_holder_row`.
        held = cloud_holder_row(e["name"], e.get("label"))
        if not have and explicit is not True and not one_click and not unavailable \
                and not removed and held is None:
            continue
        c = dict(e)
        missing = [k for k in e["credentials"] if k not in keys]
        if one_click or unavailable or removed:
            held = None
        if removed and not unavailable:
            c.update(state="needs-setup",
                     detail="Moe was removed from your Slack workspace %s — Slack stopped "
                            "accepting its key (%s). Add Moe to Slack again to reconnect it"
                            % (H.one_line(str(removed[0].get("workspace") or "(unnamed)"), 80),
                               H.one_line(str(removed[0].get("removed")), 80)))
        elif unavailable:
            c.update(state="unavailable",
                     detail="not available yet — Moe's cloud isn't set up for Add to Slack; "
                            "a Slack app of your own still works")
        elif one_click:
            if _slack_app_receiving():
                c.update(state="ok", detail="Moe is in your Slack — write to it under Apps; "
                                            "anyone else who messages there has to be approved "
                                            "in Connections first")
                gone = [t for t in _slack_app_trouble() if t.get("removed")]
                failed = [t for t in _slack_app_trouble() if t.get("last_failure")]
                if gone:
                    c["detail"] += (". Moe was removed from %s — Slack stopped accepting its "
                                    "key (%s); add Moe to Slack again there"
                                    % (H.one_line(str(gone[0].get("workspace") or "(unnamed)"), 80),
                                       H.one_line(str(gone[0].get("removed")), 80)))
                elif failed:
                    c["detail"] += (". The last reply Moe couldn't send in %s: %s"
                                    % (H.one_line(str(failed[0].get("workspace") or "(unnamed)"), 80),
                                       H.one_line(str(failed[0].get("last_failure")), 80)))
            else:
                # Added, and the cloud's connection to Slack is not up
                # (DECISIONS §5c.7: handed over is not carrying). Nothing for
                # the person to redo — the cloud keeps reconnecting.
                c.update(state="needs-setup",
                         detail="Moe is in your Slack, but Moe's cloud isn't connected to "
                                "Slack right now — it keeps trying")
        elif held is not None:
            # First, on purpose: see `cloud_holder_row`. A channel the cloud
            # holds is meant to be off here, and every branch below would read
            # that as a fault.
            c.update(**held)
            # And the live pass must leave it alone. `make_live` asks THIS
            # MAC's gateway which platforms it is running, and a channel the
            # cloud holds is deliberately not one of them — so Check again
            # turned this row's "Connected" into "set up, but not running yet
            # — quit Moe and open it again", advice that could never have
            # helped, over a channel that was working. The offline read and
            # the live read disagreeing about one row is the shape of every
            # bug this file has had.
            c["held_by_cloud"] = True
        elif explicit is False:
            c.update(state="needs-setup", detail="switched off — turn it back on in config.yaml (platforms.%s.enabled)" % e["name"])
        elif silenced:
            # Before the credential checks on purpose: a key that is present
            # and correct changes nothing while the gateway will not start the
            # platform, and saying "key saved" here is the lie this branch
            # exists to stop.
            c.update(state="needs-setup",
                     detail="Moe is not listening here — messages for this account "
                            "are going to your other devices instead")
        elif missing:
            c.update(state="needs-setup", detail="needs a key (%s) — %s %s" % (", ".join(missing), CONNECT, e["name"]))
        elif e["name"] == "whatsapp" and not os.path.exists(
                os.path.join(H.hermes_home(), "whatsapp", "session", "creds.json")):
            # WhatsApp is the one platform whose credential is not a key but a
            # linked-device session on disk, and WHATSAPP_ENABLED=true says
            # nothing about whether a phone ever scanned. connect.sh's old
            # WhatsApp branch wrote exactly that flag and returned success, so
            # the row went green over a platform with no session at all — and
            # the live check then said "set up, but not running yet — quit Moe
            # and open it again", advice that could never have helped. The
            # owner's Mac was in that state on 2026-09-09. Ask the artefact:
            # is there a session?
            c.update(state="needs-setup",
                     detail="not linked yet — scan the code (%s whatsapp)" % CONNECT)
        elif e["name"] == "signal" and not (
                os.path.exists(os.path.join(moe_home(), "signal", "account"))
                and os.path.isdir(os.path.join(moe_home(), "signal", "data"))):
            # Signal, like WhatsApp, is a linked device and not a key: the
            # two .env values say where a daemon would be, not that a phone
            # ever scanned. connect-signal.sh writes signal/account only after
            # signal-cli reports the link, and --forget removes it. The keys
            # live in signal/data: without them signal-daemon.sh never starts,
            # so an account file alone is not linked (connect-signal.sh
            # --status agrees), and "download again" would be the wrong advice.
            c.update(state="needs-setup",
                     detail="not linked yet — scan the code (%s signal)" % CONNECT)
        elif e["name"] == "signal" and not signal_status()[0]:
            # Linked, but the daemon cannot run (see `signal_status`).
            # Connecting again fetches Signal support and keeps the link:
            # connect-signal.sh never asks for a second scan when
            # signal/account is already there.
            c.update(state="needs-setup",
                     detail="linked, but Signal support has to be downloaded again before Moe can answer there "
                            "— no new scan (%s signal)" % CONNECT)
        elif e["name"] == "line":
            # LINE only ever delivers to a public HTTPS address, which this
            # Mac does not have: the engine's listener on port 8646 is one
            # nothing will call. What LINE is pointed at is Moe's cloud
            # (connect.sh connect_line_cloud, channels.py register), and the
            # row must not read like the other four. "key saved" is true;
            # "Moe answers here" would be true only of the cloud half.
            # And only once the cloud actually carries it: channels.py
            # register leaves $MOE_HOME/cloud/channel-line.json after the edge
            # accepts. Keys alone used to read "ok" — green over a bot nothing
            # could reach (the slice C review, 2026-09-11).
            if os.path.exists(os.path.join(moe_home(), "cloud", "channel-line.json")):
                c.update(state="ok", detail="key saved; LINE reaches Moe through Moe's cloud — "
                                            "anyone who messages there has to be approved in Connections first")
            else:
                c.update(state="needs-setup",
                         detail="key saved, but nothing arrives yet — LINE reaches Moe only through "
                                "Moe's cloud; sign in to Memoe, then connect LINE again")
        elif e["allowed_users"] and e["allowed_users"] not in keys \
                and e["allowed_users"].replace("_ALLOWED_USERS", "_ALLOW_ALL_USERS") not in keys \
                and "GATEWAY_ALLOW_ALL_USERS" not in keys:
            # No allowlist is not a broken connection: Hermes answers a
            # stranger with a pairing code, and the app's Approve button
            # (pending_pairings in --json, pairing.sh) puts them on the list.
            c.update(state="ok", detail="key saved; anyone who messages Moe here has to be approved in Connections first")
        else:
            c.update(state="ok", detail="key saved")
        out.append(c)
    return out


def auth_connections():
    if not spotify_logged_in():
        return []
    return [{"kind": "auth", "name": "spotify", "label": "Spotify", "auth": "oauth",
             "state": "ok", "detail": "signed in"}]


CONFIG_UNREADABLE = {
    "kind": "hermes", "name": "config", "label": "config.yaml", "auth": "none",
    "state": "unavailable",
    "detail": "Moe could not read its own list of services, so it cannot say what is connected. "
              "Quit Memoe and open it again; if it keeps happening, reinstall Memoe.",
}


#: How long `manifest` trusts the last list Composio gave (seconds). A sync
#: tick asks `manifest` about three times for each of ~27 sources, and until
#: 2026-10-07 every one of those asked Composio again over the network
#: (`composio.py list --json`, ~1.8 s measured on the owner's Mac): eighty
#: round trips a tick, enough of them past lib/connectors.sh's 10 s alarm that
#: a source's manifest came back empty and sync.sh / learn.sh skipped it
#: without a word ("Alarm clock: 14", 488 of 533 lines of com.moe.jobs.err).
#: Every other command still asks Composio afresh, and each fresh answer is
#: written here — so `names`, which sync runs first, primes it for the tick.
COMPOSIO_CACHE_SECONDS = int(os.environ.get("MOE_COMPOSIO_CACHE_SECONDS", "300"))
_COMPOSIO_MEMO = {}


def _composio_cache_path():
    return os.path.join(moe_home(), "cache", "composio-connections.json")


def _composio_cached(max_age):
    """The rows Composio gave last, when they are younger than max_age."""
    if max_age <= 0:
        return None
    path = _composio_cache_path()
    try:
        if time.time() - os.path.getmtime(path) > max_age:
            return None
        with open(path, encoding="utf-8") as f:
            rows = json.load(f).get("connections")
    except (OSError, ValueError, AttributeError):
        return None
    return rows if isinstance(rows, list) else None


def _composio_remember(rows):
    path = _composio_cache_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"connections": rows}, f)
        os.replace(tmp, path)
    except OSError:
        pass


def _composio_rows(script, max_age=0, timeout=25):
    """composio.py's `connections`, asked once per process, and — when
    max_age allows — read from the last answer instead of the network.
    Raises when Composio could not be asked."""
    if "rows" in _COMPOSIO_MEMO:
        return _COMPOSIO_MEMO["rows"]
    rows = _composio_cached(max_age)
    if rows is None:
        r = subprocess.run([sys.executable, script, "list", "--json"],
                           capture_output=True, text=True, timeout=timeout)
        rows = (json.loads(r.stdout or "{}").get("connections") or [])
        _composio_remember(rows)
    _COMPOSIO_MEMO["rows"] = rows
    return rows


def composio_connections(cfg, max_age=0, timeout=25):
    """The services behind the Composio MCP server, one row each.

    Composio is a single `mcp_servers` entry, so without this it shows up as
    ONE row called "composio" — technically true and useless to a person, who
    connects Gmail, not a broker. The services come from Composio itself
    (connected accounts plus whatever the session is scoped to); nothing is
    listed here, because a hard-coded set is how Moe ends up showing a
    fraction of what it can reach.

    Kept cheap and offline-safe: if there is no composio server configured,
    this returns nothing without touching the network. When there is, one
    subprocess answers for every service at once — a call per row would make
    opening Connections cost five round trips.
    """
    if "composio" not in (cfg.get("mcp_servers") or {}):
        return []
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "composio.py")
    if not os.path.exists(script):
        return []
    try:
        rows = _composio_rows(script, max_age, timeout)
    except Exception:
        # A broker that cannot be reached is not the same as no broker. Say
        # so in one row rather than silently dropping every service, which
        # would read as "you never connected these".
        return [{
            "kind": "composio", "name": "composio",
            "state": "unavailable",
            "detail": "could not reach Composio just now",
            "label": "Composio", "auth": "broker",
        }]
    out = []
    for row in rows:
        connected = bool(row.get("connected"))
        started = (row.get("state") or "") == "INITIALIZING"
        # "needs-setup" is the app's amber: a thing you set up that has since
        # stopped working, listed above everything else because it is a
        # regression you did not ask for. Never-connected is NOT that, and
        # saying so cost this row twice over.
        #
        # Every unconnected toolkit used to be "needs-setup", so the six
        # Google services in the session that nobody had signed into led the
        # screen under "6 need you" — in amber, above the things that
        # genuinely were connected — while the detail line right beneath each
        # one read "not connected — sign in once and Moe can use it". The
        # state and its own sentence contradicted each other.
        #
        # It also put a Disconnect on them. ConnectionsView.canDisconnect
        # excludes .notConnected and nothing else, so a wrong state here is
        # the whole reason the button appeared — on a service with no account
        # at Composio to forget, which is why pressing it did nothing anyone
        # could see. One line, both symptoms.
        #
        # INITIALIZING is the exception and the reason this is three cases and
        # not two: a sign-in that was begun and never finished IS unfinished
        # business of yours, and the person is the only one who can finish it.
        if connected:
            state, detail = "ok", "connected"
        elif started:
            state, detail = "needs-setup", "sign-in started but not finished"
        else:
            state, detail = "not-connected", "not connected — sign in once and Moe can use it"
        tools = row.get("tools")
        if connected and tools:
            detail = "signed in — %s things Moe can do here" % tools
        # Moe's cleanup at the broker is still pending for it (composio.py
        # rows(), `cleanup_pending`). The app keeps Disconnect on such a row
        # whatever its state, because Disconnect is how that cleanup is
        # retried — and a not-connected row says why the button is there.
        pending = bool(row.get("cleanup_pending"))
        if pending and not connected and not started:
            detail = "not connected — something Moe set up for it is still at the broker; Disconnect removes it"
        out.append({
            "cleanup_pending": pending,
            "kind": "composio", "name": row.get("slug") or "",
            "state": state, "detail": detail,
            "label": row.get("label") or row.get("slug") or "",
            "auth": "broker", "logo": row.get("logo") or "",
            # Every sign-in behind this service, so the app can list them,
            # name them, and disconnect one without touching the others.
            # Without this the row carries a single yes/no and a person with
            # a personal and a work account cannot tell them apart.
            "accounts": row.get("accounts") or [],
        })
    return out


def all_connections(kinds=None, composio_max_age=0, composio_timeout=25):
    """Every connection, or — `kinds`, a set — only those kinds, which is how
    `find` answers about one connection without building the rest: the
    services behind Composio are the only part that needs the network, and
    the skills are three hundred YAML files."""
    def wanted(kind):
        return kinds is None or kind in kinds
    cfg, keys = config(), env_keys()
    out = []
    if config_unreadable() and wanted("hermes"):
        # One honest line, listed first, so doctor.sh shows it under
        # "Through Hermes" instead of "nothing connected yet".
        out.append(dict(CONFIG_UNREADABLE))
    composio = (composio_connections(cfg, composio_max_age, composio_timeout)
                if wanted("composio") else [])
    mcp = mcp_connections(cfg, keys) if wanted("mcp") else []
    # When the broker has been split into a row per service, drop the broker's
    # own row. Leaving it makes "composio" sit in the list beside Gmail and
    # Google Drive as though it were another service to connect, which is the
    # confusion this split exists to remove. The row stays when the split
    # produced nothing — then it is the only thing that explains what is
    # configured.
    if any(c["kind"] == "composio" and c["name"] != "composio" for c in composio):
        mcp = [c for c in mcp if c["name"] != "composio"]
    return (out + mcp
            + (skill_connections(keys) if wanted("skill") else [])
            + (platform_connections(cfg, keys) + moe_email_connections() if wanted("platform") else [])
            + (auth_connections() if wanted("auth") else [])
            + [c for c in composio if wanted(c["kind"])])


def make_live(conns, oauth_live=True):
    """Replace file-based verdicts with real ones where a check is cheap.
    Only connections that look connected on disk are tested — an OAuth MCP
    server without a token would start a sign-in flow, not a test.

    `oauth_live=False` (what `list --live` passes) leaves a signed-in OAuth
    server on its file verdict: see LIVE_OAUTH above for why a test of our
    own can cost the person their sign-in."""
    plats = None
    deadline = time.time() + LIVE_BUDGET
    for c in conns:
        if c["state"] != "ok":
            continue
        if time.time() > deadline:
            c["state"], c["detail"] = "unavailable", "not checked this time — the check was taking too long"
            continue
        if c["kind"] == "mcp":
            if c.get("auth") == "oauth" and not oauth_live:
                continue
            c["state"], c["detail"] = mcp_test(c["name"])
        elif c["kind"] == "platform" and c["name"] == "moemail":
            # Moe's email is carried by the cloud, not by this Mac's gateway,
            # so the gateway's platform list says nothing about it.
            continue
        elif c["kind"] == "platform" and c.get("held_by_cloud"):
            # Carried by Moe's cloud, not by this Mac's gateway — the same
            # reason `moemail` is skipped above. Asking the local gateway
            # whether it is running this platform answers a question nobody
            # asked, and answers it "no" every time.
            continue
        elif c["kind"] == "platform":
            if plats is None:
                plats = gateway_platforms() or {}
                if not plats:
                    plats = {"__down__": ""}
            if "__down__" in plats:
                c["state"], c["detail"] = "unavailable", "set up, but not running yet — Moe starts it"
            elif c["name"] in plats:
                st = plats[c["name"]]
                if st in ("connected", "running", "ready", "ok"):
                    c["detail"] = "running (%s)" % st
                else:
                    c["state"], c["detail"] = "unavailable", "not working right now: %s" % H.one_line(st, 40)
            else:
                c["state"], c["detail"] = "unavailable", "set up, but not running yet — quit Memoe and open it again"
    return conns


# ── Commands ──────────────────────────────────────────────────────────────

EXIT = {"ok": 0, "needs-setup": 1, "unavailable": 3}


def find(key, composio_max_age=0):
    """One connection by "<kind>/<name>", building only that kind. Composio
    is asked only about its own rows (and the broker's mcp row, which the
    split decides), so an MCP server, a platform or a skill is read from
    files and answers offline."""
    kind, _, name = key.partition("/")
    kinds = {kind, "composio"} if (kind == "mcp" and name == "composio") else {kind}
    for c in all_connections(kinds, composio_max_age):
        if c["kind"] == kind and c["name"] == name:
            return c
    return None


def cmd_status(key):
    c = find(key)
    if c is None:
        kind, _, name = key.partition("/")
        if kind in ("mcp", "platform") and config_unreadable():
            print("unavailable: %s" % CONFIG_UNREADABLE["detail"])
            return 3
        print("needs-setup: not connected — %s %s" % (CONNECT, name or key))
        return 1
    make_live([c])
    note_watch_skips([c])
    print("%s: %s" % (c["state"], c["detail"]))
    return EXIT.get(c["state"], 3)


def GATHERABLE(c):
    """Can the learn pass read this connection back?

    An MCP server of its own, yes. A Composio toolkit, yes — reached through
    the one `composio` MCP server, its read tools discovered from Composio's
    catalog (lib/mcp_autoread). Two exclusions, each because the alternative
    is a well-formed offer that resolves to nothing:

      · the "composio" row itself is the broker, not a service;
      · a Composio row with no connected account has no data to read, and an
        unconnected row's crawl would come back empty.

    A platform (Telegram, WhatsApp), a skill or an auth row is status-only."""
    if c["kind"] == "mcp":
        return True
    return (c["kind"] == "composio" and c["name"] != "composio"
            and c.get("state") == "ok")


def cmd_manifest(key):
    # Answered from files, and for a Composio service from the last list
    # (COMPOSIO_CACHE_SECONDS): lib/connectors.sh asks this several times
    # per source per tick, under a 10 s limit.
    c = find(key, COMPOSIO_CACHE_SECONDS)
    if c is None:
        return 1
    gatherable = GATHERABLE(c)
    print("name=hermes:%s" % c["name"])
    print("label=%s" % H.one_line(c.get("label") or c["name"], 40))
    # Every MCP connection and every connected Composio service is gatherable
    # (auto-read discovers its safe reads); a platform, skill or auth row is
    # status-only. Nothing about WHICH connection is gatherable lives in code.
    print("verbs=status crawl" if gatherable else "verbs=status")
    print("cadence=0m")                    # never pulled; see sync.sh
    print("deep_crawl=yes" if gatherable else "deep_crawl=no")
    print("auth=%s" % ("oauth" if c.get("auth") in ("oauth", "credential-file") else "app-password"))
    print("runs_in=both")                  # Hermes runs the same anywhere
    print("cost=cheap")
    print("context_file=hermes-%s" % c["name"])
    print("provider=hermes")
    print("kind=%s" % c["kind"])
    return 0


def cmd_crawl(key, rest):
    """Auto-read one connection and print the gathered text. learn.sh calls
    this (through lib/connectors.sh) for a hermes: source whose manifest
    advertises `crawl`. lib/mcp_autoread discovers the connection's tools, keeps
    only safe metadata reads, lets a no-tools turn choose the calls, and
    executes them deterministically — no model ever holds a live tool. Empty
    output (nothing readable) is silently nothing (exit 0), never an error. The
    read imports Hermes, so re-exec under Hermes's venv first.

    Two spellings: `mcp/<name>`, a server of its own, and `composio/<slug>`,
    one of the brokered services — whose reads are made against the single
    `composio` server with the toolkit's own tool names."""
    kind, _, name = key.partition("/")
    if kind not in ("mcp", "composio") or not re.match(r"^[a-z][a-z0-9_-]{0,31}$", name or ""):
        print("crawl: expected an mcp/<name> or composio/<slug> connection", file=sys.stderr)
        return 2
    venv = os.path.join(H.hermes_home(), "hermes-agent", ".venv", "bin", "python")
    if os.path.exists(venv) and os.path.realpath(sys.executable) != os.path.realpath(venv):
        os.execv(venv, [venv, os.path.abspath(__file__), "crawl", key] + list(rest))
    lib = os.path.join(moe_home(), "lib")
    if lib not in sys.path:
        sys.path.insert(0, lib)
    import mcp_autoread  # noqa: WPS433
    # The window, plumbed through: sync.sh says --since 1, learn.sh the
    # profile's seed_days or the days since its stamp. What it means for the
    # read is the read-set's to say (a "{since_days}"/"{since_date}"
    # placeholder in a hand recipe's args; the auto plan carries none, so
    # it is the same read whatever the number). Dropping it here would make
    # every caller's window a fiction.
    try:
        since = crawl_since(rest)
    except ValueError as e:
        print("crawl: %s" % e, file=sys.stderr)
        return 2
    try:
        sys.stdout.write(mcp_autoread.crawl("%s/%s" % (kind, name), since_days=since,
                                            log=lambda m: print(m, file=sys.stderr)))
    except Exception as e:
        print("gather %s: %s" % (name, e), file=sys.stderr)
        return 1
    return 0


def crawl_since(rest):
    """`--since N` / `--since=N` out of crawl's trailing arguments → N or
    None; a value that is not a positive number of days is an error, not a
    silent full read."""
    since = None
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--since":
            if i + 1 >= len(rest):
                raise ValueError("--since needs a number of days")
            val, i = rest[i + 1], i + 2
        elif a.startswith("--since="):
            val, i = a[len("--since="):], i + 1
        else:
            i += 1
            continue
        if not val.isdigit() or int(val) < 1:
            raise ValueError("--since wants a positive number of days, not %r" % val)
        since = int(val)
    return since


# ── On this Mac, for the brief ────────────────────────────────────────────
#
# The native connectors (calendar, gmail, imessage …) are not Hermes
# connections and are not in `all_connections()`: the pane reads their
# `status` itself (MacSources.checkAll) and sync.sh pulls them. But the model
# is told about connections through ONE file, `context/_connections.md`, and
# until 2026-09-11 that file named the brokered services and nothing else —
# so a person whose Calendar, Notes and mail were all being read every ten
# minutes had a brain that could not say so, and the MCP servers it did name
# sat under a heading that called them "On this Mac".

STATUS_PROBE_TIMEOUT = 12


def _manifest_fields(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def mac_sources():
    """[(name, label, verbs)] for every native connector beside this script
    that is a SOURCE — its manifest lists `pull`. Read off disk, so a
    connector added tomorrow is on the list the day it ships."""
    out = []
    try:
        names = sorted(fn[:-len(".manifest")] for fn in os.listdir(HERE) if fn.endswith(".manifest"))
    except OSError:
        return out
    for name in names:
        if not re.match(r"^[A-Za-z0-9_-]+$", name):
            continue
        f = _manifest_fields(os.path.join(HERE, "%s.manifest" % name))
        verbs = [v for v in f.get("verbs", "").split() if v]
        if "pull" not in verbs:
            continue
        out.append((name, f.get("label") or name, verbs))
    return out


def mac_status_cache():
    """{name: connected} from $MOE_HOME/status.json — the verdicts the app's
    full consent list (MOE_FROM_APP) and the ten-minute sync leave behind.
    Missing or unreadable is an empty dict, never an error."""
    try:
        with open(os.path.join(moe_home(), "status.json"), encoding="utf-8") as fh:
            cache = json.load(fh)
    except (OSError, ValueError):
        return {}
    out = {}
    for name, entry in (cache.items() if isinstance(cache, dict) else []):
        if isinstance(entry, dict) and "connected" in entry:
            out[str(name)] = bool(entry.get("connected"))
    return out


def _probe_ok(name):
    for ext in (".sh", ".py"):
        script = os.path.join(HERE, name + ext)
        if os.path.isfile(script) and os.access(script, os.X_OK):
            break
    else:
        return False
    rc, out, _ = H.run([script, "status"], STATUS_PROBE_TIMEOUT)
    return rc != -1 and (out or "").split("\n", 1)[0].startswith("ok:")


def mac_connected(sources):
    """The names in `sources` that are connected right now.

    Two answers, and a source is named when EITHER says yes:

    - a live `status` probe, twelve seconds each and all at once — so a
      mailbox added a minute ago is on the list before this process exits,
      which is the whole reason `refresh` exists;
    - the cached verdict in status.json, written from inside the app and by
      the sync — because this script also runs from a terminal and from
      launchd, where the probe has none of the app's permissions and would
      answer "no" about a Calendar the app reads every ten minutes. The
      file the model reads must not flip with the process that wrote it: a
      changed prompt respawns the brain's child.

    So the file can lag a disconnect by one sync (the cache still says yes)
    and never lags a connect. That is the right way round.
    """
    if not sources:
        return set()
    cache = mac_status_cache()
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=16) as pool:
        futs = {name: pool.submit(_probe_ok, name) for name, _, _ in sources}
        live = set()
        for name, fut in futs.items():
            try:
                if fut.result():
                    live.add(name)
            except Exception:
                pass
    return live | {name for name, _, _ in sources if cache.get(name)}


def _tool(name, verb):
    """`gmail_send`: the moe-connectors plugin's name for a connector's verb
    (its tool_name — a dash is not legal in a tool name everywhere)."""
    return "%s_%s" % (name.replace("-", "_"), verb)


def github_cli_signed_in():
    """GitHub, through the `gh` command tools/git.sh shells out to. Signed
    in is `gh auth token` answering (offline, and its output is discarded
    unread); the script has to be beside this home too."""
    if not os.access(os.path.join(moe_home(), "tools", "git.sh"), os.X_OK):
        return False
    for gh in ("/opt/homebrew/bin/gh", "/usr/local/bin/gh", "gh"):
        try:
            r = subprocess.run([gh, "auth", "token"], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            continue
        return r.returncode == 0 and bool(r.stdout.strip())
    return False


def cmd_brief():
    """What is connected, as a few lines for the model's prompt.

    This exists because the model was told none of it. Moe's connectors are
    not tools it can see — sync.sh runs them and writes the brief — and the
    brokered services ARE tools, but their names (COMPOSIO_SEARCH_TOOLS and
    friends) say nothing about Gmail. Asked "how's my inbox" with the local
    mailbox gone, the model reached for the one messages-shaped tool it could
    see, found nothing, and reported that nothing was connected. It was
    answering honestly about a surface that did not describe itself.

    memory/tools/<server>.md is the documented place for this and it cannot
    work here: Hermes starts the claude-code child with Read disallowed, so
    the model cannot open a file to find out. It has to be in the prompt.

    Kept SHORT on purpose. This lands in the ephemeral part of the prompt,
    and anything volatile there costs a warm-child respawn — so it names what
    is connected and how to reach it, and leaves the data to the brief.
    """
    text = brief_text()
    if text:
        sys.stdout.write(text)
    return 0


def brief_text(conns=None):
    """`cmd_brief`'s words as a string, so `refresh` can write the same bytes.

    Split out from cmd_brief so the file on disk and the thing a person sees
    on stdout can never drift: one producer, two destinations. `conns` is
    `all_connections()` when the caller has it already (`cmd_refresh` writes
    the prose and the JSON from ONE read of the broker, not two).
    """
    lines = []
    say = lines.append

    conns = all_connections() if conns is None else conns
    live = [c for c in conns if c["state"] == "ok"]
    brokered = [c for c in live if c["kind"] == "composio"]
    servers = [c for c in live if c["kind"] == "mcp"]
    keyed = [c for c in live if c["kind"] in ("skill", "auth")]
    reach = [c for c in live if c["kind"] == "platform"]
    sources = mac_sources()
    on_mac = mac_connected(sources)
    mac = [(name, label, verbs) for name, label, verbs in sources if name in on_mac]
    github = github_cli_signed_in()
    # Composio configured means any of its services can be connected at any
    # moment, from the app, without this file knowing yet. That is worth a
    # paragraph even when nothing else is connected — it is exactly the state
    # a new person is in the minute after their first sign-in.
    broker = "composio" in ((config() or {}).get("mcp_servers") or {})
    if not (brokered or servers or keyed or mac or github or broker):
        return ""

    say("Connected right now. Do not tell the person something is not")
    say("connected without checking this list first.")
    say("")
    if brokered:
        say("Through Composio. The everyday reads are already in your tool")
        say("list — GMAIL_FETCH_EMAILS, GOOGLEDRIVE_FIND_FILE,")
        say("GOOGLECALENDAR_EVENTS_LIST_ALL_CALENDARS and a few more — so use")
        say("them directly. For anything else, COMPOSIO_SEARCH_TOOLS finds the")
        say("tool and COMPOSIO_MULTI_EXECUTE_TOOL runs it. A tool you cannot")
        say("see is not a service that is unavailable:")
        for c in sorted(brokered, key=lambda c: c["label"].lower()):
            # EVERY live account, not the first one. This used to `break` on
            # the first named ACTIVE account, so someone who connected a
            # personal and a work Gmail was told about one of them — and the
            # model, asked about the other, had nothing in front of it saying
            # that mailbox existed. Two accounts is the ordinary case for
            # mail, not an edge case: the owner connected two on the day this
            # was found. An expired account is deliberately not named — it is
            # not something Moe can read today.
            who = [a["who"] for a in (c.get("accounts") or [])
                   if (a.get("status") or "") == "ACTIVE" and a.get("who")]
            say("  - %s%s" % (c["label"],
                              (" (%s)" % ", ".join(who)) if who else ""))
        # Stable, so it never changes the file's bytes on its own (a changed
        # prompt respawns the brain's child). The list above is built from
        # Composio's own account list now, not one page of the session's
        # toolkits — but a broker's list is a broker's list, and the price
        # of missing one is the model denying a thing the person just
        # connected. Search first; deny never.
        say("  Anything else the person connected through Composio is")
        say("  reachable the same way even if it is not named here: run")
        say("  COMPOSIO_SEARCH_TOOLS for it before ever saying it is not")
        say("  connected.")
        say("")
    if broker:
        # 2026-09-16: Gmail was connected through Composio and in this list,
        # and Moe still told the owner twice it was not — because
        # `gmail_status`, which checks only the Mac's app-password route, said
        # needs-setup. The tool now asks Composio itself; this says the same
        # thing for every service no Mac tool shadows. Stable text: it must
        # not change the file's bytes on its own.
        say("Connections change while you run. This list can be a few minutes")
        say("behind, and a Mac tool's own status (gmail_status, calendar_status,")
        say("drive_status) speaks only for the Mac's route, not for Composio.")
        say("When the person says they connected something, or asks whether")
        say("a service is connected, check Composio live with")
        say("COMPOSIO_SEARCH_TOOLS for that service and trust what it says.")
        say("Never ask the person to confirm a connection you can check.")
        say("")
    # Every line below is built from names — manifests, config keys — and
    # never from what a probe SAID (a count, an address, a detail), so the
    # bytes change only when the connected set does. A changed prompt
    # respawns the brain's child; "3 calendars" becoming "4 calendars" must
    # not cost that.
    if mac:
        say("On this Mac. Each is a set of tools named <source>_<verb>; what")
        say("`pull` reads is already in the brief that comes with each message,")
        say("the other verbs act:")
        for name, label, verbs in mac:
            # `items` feeds Moe's background engine and is never a tool
            # (moe-connectors ENGINE_VERBS): naming it here would send the
            # brain after a tool that does not exist.
            tools = [_tool(name, v) for v in verbs if v not in ("status", "items")]
            say("  - %s: %s" % (label, ", ".join(tools)))
        say("")
    if servers or github:
        say("Other services, each a server whose tools start with mcp__<name>__:")
        for c in sorted(servers, key=lambda c: c["name"]):
            say("  - %s (mcp__%s__…)" % (c.get("label") or c["name"], c["name"]))
        if github:
            say("  - GitHub, through the gh command: ~/.moe/tools/git.sh repos, recent,")
            say("    commits, prs, issues, activity, search, show (and local, status, log,")
            say("    diff for the repos on this Mac)")
        say("")
    if keyed:
        say("Also signed in, as their own tools: " + ", ".join(sorted(
            {c.get("label") or c["name"] for c in keyed})))
        say("")
    if reach:
        say("Where the person can reach Moe from: " + ", ".join(sorted(
            {c.get("label") or c["name"] for c in reach})))
        # The other direction, said beside it: a channel they talk to Moe on
        # is not a tool Moe sends to them with. On 2026-09-25 "message me on
        # Telegram" became a job that messaged a contact, because nothing
        # here named the one tool that can only reach them.
        say("To message them — on one of these or anywhere — use reach_owner; it "
            "knows where they are. Never a contact-send tool.")
        say("")
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines) + "\n"


CONNECTIONS_JSON = "_connections.json"


def connections_json_text(conns=None):
    """The same facts as `brief_text()`, as canonical JSON, for the machine.

    `brief_text()` is prose written for THIS Mac's prompt — "On this Mac.
    Each is a set of tools named <source>_<verb>; what `pull` reads is
    already in the brief" — and every one of those sentences is false on the
    person's cloud computer, where the Mac's connectors are queued hands and
    the brief is a document from elsewhere. So the machine gets the facts and
    writes its own sentences (`moeledger/connected.py`), and this is the
    facts: names and labels, which accounts (the model has to know which of
    two Gmails it is reading), and never a count, a token or an address of
    a server.

    Canonical (sorted keys, no spaces) so the bytes change only when the
    connected set does: the file travels as the `context/connections`
    document, whose writer hashes it, and a byte that moved for nothing is a
    record on the ledger for nothing.
    """
    conns = all_connections() if conns is None else conns
    live = [c for c in conns if c["state"] == "ok"]
    sources = mac_sources()
    on_mac = mac_connected(sources)

    def accounts(c):
        return sorted({a["who"] for a in (c.get("accounts") or [])
                       if (a.get("status") or "") == "ACTIVE" and a.get("who")})

    doc = {
        "v": 1,
        "broker": "composio" in ((config() or {}).get("mcp_servers") or {}),
        "composio": sorted(({"slug": c["name"], "label": c.get("label") or c["name"],
                             "who": accounts(c)}
                            for c in live if c["kind"] == "composio" and c["name"] != "composio"),
                           key=lambda r: r["label"].lower()),
        "mcp": sorted(({"name": c["name"], "label": c.get("label") or c["name"]}
                       for c in live if c["kind"] == "mcp" and c["name"] != "composio"),
                      key=lambda r: r["name"]),
        "mac": [{"name": name, "label": label} for name, label, _verbs in sources
                if name in on_mac],
        "github": github_cli_signed_in(),
        "reach": sorted({c.get("label") or c["name"] for c in live if c["kind"] == "platform"}),
    }
    return json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"


def cmd_refresh():
    """Write `brief_text()` to $MOE_HOME/context/_connections.md, now — and
    `connections_json_text()` to `_connections.json` beside it, for the
    person's cloud computer (the `context/connections` document).

    **The whole point is the "now".** This file is what the model is told
    about which services exist, and until 2026-09-07 the only thing that ever
    wrote it was `sync.sh`, on its ten-minute tick. So the ten minutes after
    someone connected a mailbox were exactly the ten minutes in which Moe
    would tell them, confidently and in the connector's own words, that "no
    mailbox is added yet" and offer to walk them through connecting the thing
    they had just connected. That is the report this verb exists for, and the
    measured gap in it was 88 seconds: connected at 21:34, asked at 21:36,
    file rewritten at 21:47.

    Written through a temporary file in the same directory and renamed, so a
    turn that reads it mid-write never sees half a list.

    Nothing live is not an error and is not "leave the old file alone": a
    person who disconnected everything must not keep a file claiming they are
    connected. Empty is what `sync.sh` writes in that case too.
    """
    ctx = os.path.join(moe_home(), "context")
    try:
        os.makedirs(ctx, exist_ok=True)
        conns = all_connections()
        for leaf, text in (("_connections.md", brief_text(conns)),
                           (CONNECTIONS_JSON, connections_json_text(conns))):
            tmp = os.path.join(ctx, ".%s.%d" % (leaf, os.getpid()))
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(text)
            os.replace(tmp, os.path.join(ctx, leaf))
    except Exception as exc:
        # A refresh that cannot run must not take a connect down with it: the
        # person's account IS connected either way, and the ten-minute sync
        # is still behind this.
        print("could not refresh _connections.md: %s" % type(exc).__name__,
              file=sys.stderr)
        return 1
    return 0


def main(argv):
    cmd = argv[0] if argv else "list"
    if cmd == "status":
        return cmd_status(argv[1] if len(argv) > 1 else "")
    if cmd == "manifest":
        return cmd_manifest(argv[1] if len(argv) > 1 else "")
    if cmd == "pull":
        return 1
    if cmd == "crawl":
        return cmd_crawl(argv[1] if len(argv) > 1 else "", argv[2:])
    if cmd == "toolsets":
        ts = gateway_toolsets()
        if ts is None:
            print("unavailable: gateway not answering", file=sys.stderr)
            return 1
        for name, enabled, configured in ts:
            state = "ok" if enabled and configured else (
                "needs-setup" if enabled else "off")
            print("%s\t%s" % (state, name))
        return 0
    if cmd == "brief":
        return cmd_brief()
    if cmd == "refresh":
        return cmd_refresh()
    if cmd == "names":
        # Under lib/connectors.sh's 10 s limit: Composio's last list when it
        # is fresh, and a shorter wait for a new one, so a slow broker costs
        # its own rows ("could not reach Composio") and never every row.
        for c in all_connections(composio_max_age=COMPOSIO_CACHE_SECONDS, composio_timeout=8):
            print("%s/%s" % (c["kind"], c["name"]))
        return 0
    if cmd == "gatherable":
        # Only the connections the learn pass can actually read back, so the
        # rule lives in ONE place (GATHERABLE) instead of being restated by
        # every caller that wants to offer a source. consent.sh asks this
        # before it will record an answer about a name.
        for c in all_connections():
            if GATHERABLE(c):
                print("%s/%s" % (c["kind"], c["name"]))
        return 0
    if cmd in ("list", "--live", "--json"):
        if "--live" in argv:
            # Before the rows are read, so one refresh flips a row the cloud
            # has since made available.
            recheck_slack_availability()
        conns = all_connections()
        if "--live" in argv:
            make_live(conns, oauth_live=LIVE_OAUTH)
        note_watch_skips(conns)
        if "--json" in argv:
            json.dump({"connections": conns,
                       "pending_pairings": H.pending_pairings() + slack_install_pairings()
                                           + cloud_channel_knocks()},
                      sys.stdout, indent=1)
            print()
        else:
            for c in conns:
                print("%s/%s\t%s: %s" % (c["kind"], c["name"], c["state"], c["detail"]))
        return 0
    print(__doc__.strip().split("\n\n")[3], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
