#!/usr/bin/env python3
"""Who a message is going to, and who asked for them.

One question every send path asks before a message leaves, answered in one
place: the send hook (hermes/hooks/confirm-send.sh), and each of Moe's own
connectors (whatsapp.sh, telegram.py, gmail.py) after it has resolved a name
to an address.

The incident this exists for, 2026-09-25: a scheduled job told "send ONE
WhatsApp message to Jordan" (the owner) called
whatsapp_send(to="Walter Brennan") — the owner's grandfather, the only
WhatsApp contact named in memory. No lookup. The resolver did exactly what it
was asked; nothing anywhere could tell that nobody had asked for him.

Nothing here knows about grandfathers, WhatsApp or any one tool.

1. **Is this the owner?** The owner is DATA: `$MOE_HOME/owner.json` (written by
   configure-hermes.py on every sync) plus the same sources read live — the
   Telegram id Hermes answers to, the WhatsApp number (and @lid) this Mac is
   linked as, the Google address it signed in with, the mailboxes it reads,
   the Mac account's name, and whatever the person pinned (nicknames too).
   A contact tool whose only recipient is the owner is refused unless the
   request asked to reach the owner; `reach_owner` is the right door.

2. **Did the OWNER name this person?** Hermes writes, per conversation, what
   was said and who said it, and what tools returned
   (`$HERMES_HOME/grounding/<sha256(key)[:32]>.json`; hermes-agent
   `agent/recipient_grounding.py` states the format). A recipient is:

   - `named`   — the owner's own words say it, in full;
   - `partial` — the owner said only part of it ("Walter") and Moe picked the
                 rest ("Walter Brennan"): allowed, the card says so in amber;
   - `found`   — a real LOOKUP returned it (contacts, chats, mail search — an
                 allowlist; never a web page, a shell, a file read or memory):
                 allowed, amber, with the source;
   - `shown`   — an ADDRESS Moe read off a page or the screen in this
                 conversation (a browser, web or screen tool's result — never
                 one the call itself was handed), then named in its own message
                 immediately before the owner's latest one, which says yes
                 ("good", "send it"). Never silent: always the card, in amber,
                 saying where it was found and what the owner said; no session
                 grant covers it. Moe's own words never ground anyone — an
                 address it invented is in no page, and one on a page it never
                 showed was never agreed to;
   - otherwise refused: look the person up or ask.

   Words count only when the OWNER said them: the Mac's own person-started
   turns, or a chat message whose sender id is the owner's. A job's prompt, a
   delegated goal, a summary, another person's message are context: they can
   refuse a recipient or flag a mismatch, never ground one.

   Hermes writes `grounding/.enabled` beside its ledgers. With the marker there,
   a missing, unreadable or old-format ledger is a refusal. With no marker (a
   Hermes from before this) nothing is refused for grounding and nothing is
   said about it on the card.

Stdlib only, Python 3.9 (macOS's /usr/bin/python3). Importable, and a CLI:

    recipients.py gate --to RAW [--to RAW…] [--resolved ADDR…] [--channel C]
        prints three lines — ok|refuse, the refusal (or empty), provenance JSON
        exit 0 ok, 3 refused
    recipients.py owner          the owner identity, as JSON
    recipients.py write-owner    write $MOE_HOME/owner.json from the sources
    recipients.py is-owner ADDR  exit 0 when ADDR is the owner
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import sys
import tempfile
import unicodedata

OWNER_FILE = "owner.json"
GROUNDING_KEY_ENV = "HERMES_GROUNDING_KEY"
LEDGER_DIR = "grounding"
ENABLED_MARKER = ".enabled"
LEDGER_VERSION = 2
REACH_OWNER_TOOL = "reach_owner"

# The words a model uses for the owner when it has no address for them.
SELF_WORDS = frozenset({"me", "myself", "self", "owner", "the owner", "user", "the user",
                        "yourself", "my phone", "my own"})
PLATFORM_PREFIX = re.compile(
    r"^(?:telegram|whatsapp|wa|imessage|sms|signal|slack|discord|email|mailto|tel|matrix)\s*:\s*",
    re.I)
EMAIL = re.compile(r"[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
JID = re.compile(r"^([0-9A-Za-z._:-]+)@(s\.whatsapp\.net|c\.us|lid|g\.us|broadcast)$", re.I)
PHONEISH = re.compile(r"^\+?[\d\s().-]+$")
DIGIT_RUN = re.compile(r"\+?\d[\d\s().-]{4,}\d")
BRACKETED = re.compile(r"^(.*?)\s*[(<\[]\s*([^()<>\[\]]+?)\s*[)>\]]\s*$")

# Words that are never a name on their own — function words, and ordinary
# words that are also names ("Will", "Mark", "Bot"). A recipient whose only
# overlap with the person's words is one of these was not named by them.
COMMON = frozenset("""
a an the and or but if of to in on at by for with from as is are was were be been being am
i me my mine we us our you your he him his she her it its they them their this that these those
do does did done have has had will would shall should can could may might must not no yes ok
just only also too very so then than now here there when where what which who whom whose why how
all any some each every both either neither none one two three first last next new old
up down out over under again off about into onto after before while until since
please thanks hi hello hey dear team family group chat bot bots admin support info sales
home work office mom dad boss everyone anyone someone people person friend friends
mark bill will may june april august grace hope joy faith frank don ray max sky rich art
dawn eve ivy lily iris rose summer winter autumn spring jack jean pat sue ben al ed
news update note notes list lists message messages text email mail call reply send
rest slack meeting report today tomorrow morning evening night week month year
""".split())
NAME_STOP = frozenset({"mr", "mrs", "ms", "dr", "de", "van", "von", "al", "bin", "ben", "da", "la", "le"})


# ── small helpers ────────────────────────────────────────────────────────────

def moe_home(env=None):
    env = os.environ if env is None else env
    return env.get("MOE_HOME") or os.path.expanduser("~/.moe")


def hermes_home(env=None):
    env = os.environ if env is None else env
    return env.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def fold(text):
    text = unicodedata.normalize("NFKD", str(text or ""))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", text.casefold()).strip()


def digits(text):
    return re.sub(r"\D", "", str(text or ""))


def e164(text):
    """A phone number as its digits, the international prefix `00` dropped."""
    d = digits(text)
    return d[2:] if d.startswith("00") else d


def same_number(a, b):
    """Two spellings of one number, in full: equal, or one is the other with a
    country code of 1–3 digits in front and at least ten digits after it.
    Never a shared tail: +44 20 555 1234 5678 is not +1 205 551 2345 678."""
    if not a or not b:
        return False
    if a == b:
        return True
    short, long_ = sorted((a, b), key=len)
    return len(short) >= 10 and 1 <= len(long_) - len(short) <= 3 and long_.endswith(short)


def email_key(address):
    """An address as the mailbox it reaches: casefolded, `+tag` dropped."""
    local, _, domain = str(address or "").strip().casefold().partition("@")
    return local.split("+", 1)[0] + "@" + domain if domain else local


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _env_file(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return out
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        out[key] = value
    return out


def _listed(value):
    return [p.strip() for p in re.split(r"[,;]", value or "") if p.strip()]


def split_recipients(value):
    """Every address a recipient value holds, one string each."""
    out = []
    if value is None or isinstance(value, bool):
        return out
    if isinstance(value, (list, tuple)):
        for v in value:
            out.extend(split_recipients(v))
        return out
    if isinstance(value, dict):
        for v in value.values():
            out.extend(split_recipients(v))
        return out
    # Commas and semicolons separate addresses, except inside quotes or angle
    # brackets: `"Lovelace, Ada" <ada@example.com>` is one address.
    part, depth, quoted = "", 0, False
    for ch in str(value):
        if ch == '"':
            quoted = not quoted
        elif ch == "<" and not quoted:
            depth += 1
        elif ch == ">" and not quoted and depth:
            depth -= 1
        if ch in ",;\n" and not quoted and not depth:
            if part.strip():
                out.append(part.strip())
            part = ""
            continue
        part += ch
    if part.strip():
        out.append(part.strip())
    return out


# ── what an address is made of ───────────────────────────────────────────────

def facets(raw):
    """{"raw", "name", "emails", "phones", "ids"} for one recipient string."""
    text = str(raw or "").strip()
    out = {"raw": text, "name": "", "emails": [], "phones": [], "ids": []}
    rest = PLATFORM_PREFIX.sub("", text, count=1).strip()
    m = BRACKETED.match(rest)
    parts = [m.group(1), m.group(2)] if m and m.group(1) else [rest]
    for part in parts:
        part = part.strip().strip("\"'")
        if not part:
            continue
        jm = JID.match(part)
        if jm:
            user, server = jm.group(1).split(":")[0], jm.group(2).lower()
            if server in ("s.whatsapp.net", "c.us") and 6 <= len(digits(user)) <= 15:
                out["phones"].append(e164(user))
            out["ids"].append(user)
            continue
        emails = EMAIL.findall(part)
        if emails:
            out["emails"].extend(e.lower() for e in emails)
            leftover = EMAIL.sub(" ", part).strip(" <>\"'")
            if leftover and not out["name"]:
                out["name"] = leftover
            continue
        bare = part.lstrip("@")
        if part.startswith("@") and re.fullmatch(r"[A-Za-z0-9_.]{3,64}", bare):
            out["ids"].append(bare)          # a handle is an address, not a name
            continue
        if PHONEISH.match(part):
            d = e164(part)
            if 6 <= len(d) <= 15:
                out["phones"].append(d)
            if re.fullmatch(r"-?\d+", part.strip()):
                out["ids"].append(part.strip())
            continue
        if re.fullmatch(r"-?[A-Za-z0-9_]{1,64}", bare) and any(c.isdigit() for c in bare):
            out["ids"].append(bare)
            continue
        if not out["name"]:
            out["name"] = part
    return out


def name_tokens(name):
    return [t for t in re.findall(r"[\w'’-]+", fold(name)) if len(t) >= 2 and t not in NAME_STOP]


def significant(token):
    return len(token) >= 3 and token not in COMMON


# ── the owner ────────────────────────────────────────────────────────────────

def _empty_owner():
    return {"names": [], "telegram": [], "phones": [], "emails": [], "ids": []}


def _add(owner, field, value):
    value = str(value or "").strip()
    if value and value not in owner[field]:
        owner[field].append(value)


def collect(moe=None, hermes=None, env=None):
    """The owner's identities, from every source this Mac already has. Read-only."""
    env = os.environ if env is None else env
    moe = moe or moe_home(env)
    hermes = hermes or hermes_home(env)
    owner = _empty_owner()
    henv = _env_file(os.path.join(hermes, ".env"))
    # The process's own environment too: on the away machine the gateway's
    # settings arrive as environment (fly secrets), not in a .env file.
    for key in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS", "TELEGRAM_HOME_CHANNEL",
                "GATEWAY_RELAY_URL", "WHATSAPP_HOME_CHANNEL", "WHATSAPP_CLOUD_HOME_CHANNEL"):
        if not henv.get(key) and env.get(key):
            henv[key] = env[key]
    relay = _load_json(os.path.join(moe, "cloud", "channel-holder.json"))
    edge_holds_telegram = isinstance(relay, dict) and isinstance(relay.get("channels"), dict) and \
        isinstance(relay["channels"].get("telegram"), dict) and \
        str(relay["channels"]["telegram"].get("holder") or "").lower() in ("edge", "cloud", "relay")

    # Telegram: the owner's id, whoever holds the bot — this Mac (a token), or
    # the edge in relay mode (no token here; the owner's id is still the first
    # one Hermes answers to).
    if henv.get("TELEGRAM_BOT_TOKEN") or henv.get("GATEWAY_RELAY_URL") or edge_holds_telegram:
        # Only the FIRST allowed user, as Swift's TelegramSelf does. A home
        # channel is where Hermes delivers, which may be anybody's chat — it
        # is never evidence of who the owner is.
        allowed = _listed(henv.get("TELEGRAM_ALLOWED_USERS"))
        if allowed and not allowed[0].startswith("-"):
            _add(owner, "telegram", allowed[0].lstrip("@"))

    for session in (os.path.join(hermes, "whatsapp", "session"),
                    os.path.join(hermes, "platforms", "whatsapp", "session")):
        creds = _load_json(os.path.join(session, "creds.json"))
        me = creds.get("me") if isinstance(creds, dict) else None
        if isinstance(me, dict):
            for key in ("id", "lid"):
                # "15551234567:12@s.whatsapp.net": the device suffix goes.
                user, _, server = str(me.get(key) or "").partition("@")
                f = facets(user.split(":")[0] + ("@" + server if server else ""))
                for p in f["phones"]:
                    _add(owner, "phones", p)
                for i in f["ids"]:
                    _add(owner, "ids", i)
            if me.get("name"):
                _add(owner, "names", me.get("name"))
    # Not WHATSAPP_HOME_CHANNEL: a home chat can be a contact's, and the
    # owner's own number is the linked device's `me` above.

    # The Google account the person signed in to Memoe with (the app writes
    # it as `account`), on the Mac and wherever the away machine keeps its
    # credential — `$HERMES_HOME/moe/credential.json` (moe-ledger's vault;
    # report-usage.py reads the same file).
    for cred_path in (os.path.join(moe, "cloud", "credential.json"),
                      os.path.join(hermes, "moe", "credential.json")):
        cred = _load_json(cred_path)
        for key in ("account", "email", "owner_email"):
            if isinstance(cred, dict) and isinstance(cred.get(key), str):
                for e in EMAIL.findall(cred[key]):
                    _add(owner, "emails", e.lower())
    accounts = _load_json(os.path.join(moe, "connectors", "gmail-accounts.json"))
    for a in accounts if isinstance(accounts, list) else []:
        if isinstance(a, dict) and isinstance(a.get("email"), str):
            for e in EMAIL.findall(a["email"]):
                _add(owner, "emails", e.lower())

    # The Mac account's own name. Not in a test run: it would be whoever runs the suite.
    if env.get("MOE_HOOK_TEST") != "1":
        try:
            import pwd
            full = pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].strip()
            if full and any(c.isalpha() for c in full):
                _add(owner, "names", full)
        except Exception:
            pass
    return owner


def load_owner(moe=None, hermes=None, env=None):
    """owner.json, merged with the live sources."""
    env = os.environ if env is None else env
    moe = moe or moe_home(env)
    owner = _empty_owner()
    for source in (_load_json(os.path.join(moe, OWNER_FILE)), collect(moe, hermes, env)):
        if not isinstance(source, dict):
            continue
        pinned = source.get("pinned") if isinstance(source.get("pinned"), dict) else {}
        for block in (source, pinned):
            for field in owner:
                vals = block.get(field)
                for v in vals if isinstance(vals, list) else []:
                    if isinstance(v, (str, int)) and not isinstance(v, bool):
                        _add(owner, field, str(v))
            # Nicknames are names; iMessage handles are phones or emails.
            for v in block.get("nicknames") if isinstance(block.get("nicknames"), list) else []:
                if isinstance(v, str):
                    _add(owner, "names", v)
            for v in block.get("imessage") if isinstance(block.get("imessage"), list) else []:
                f = facets(str(v))
                for p in f["phones"]:
                    _add(owner, "phones", p)
                for e in f["emails"]:
                    _add(owner, "emails", e)
    return owner


# The owner's own mail accounts that only Composio knows about: a Mac with no
# app-password mailbox reads Gmail through Composio, and the address is on the
# connected account (composio.py `list --json`, accounts[].who).
OWNER_MAIL_SLUGS = ("gmail", "outlook")


def composio_emails(moe, env=None, timeout=25):
    """[emails] of this person's connected Composio mail accounts, or None when
    Composio could not be asked (not set up, offline, a failure). composio.py
    rows()'s accounts[].who is the address on the connected account."""
    env = os.environ if env is None else env
    script = os.path.join(moe, "connectors", "composio.py")
    if not os.path.isfile(script):
        return None
    import subprocess
    # composio.py's own rows(), not its `list` command: `list` also retries
    # Moe's pending cleanups at Composio afterwards, which is not this
    # caller's to start.
    read = ("import importlib.util, json, sys\n"
            "spec = importlib.util.spec_from_file_location('moe_composio', sys.argv[1])\n"
            "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
            "print(json.dumps({'connections': m.rows()}))\n")
    try:
        r = subprocess.run([sys.executable, "-c", read, script], capture_output=True,
                           text=True, timeout=timeout, env=dict(env))
        body = json.loads(r.stdout.strip().splitlines()[-1]) if r.returncode == 0 and r.stdout.strip() else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    rows = body.get("connections") if isinstance(body, dict) else None
    if not isinstance(rows, list):
        return None
    out = []
    for row in rows:
        if not isinstance(row, dict) or str(row.get("slug") or "").lower() not in OWNER_MAIL_SLUGS:
            continue
        for a in row.get("accounts") if isinstance(row.get("accounts"), list) else []:
            for e in EMAIL.findall(str((a or {}).get("who") or "")) if isinstance(a, dict) else []:
                if e.lower() not in out:
                    out.append(e.lower())
    return out


COMPOSIO_TTL = 6 * 3600


def _refresh_composio_detached(moe, hermes, env):
    """Ask Composio for the owner's mail addresses in a process of its own,
    which rewrites owner.json when it has an answer. Nothing waits for it:
    a launch that waited on the network would be a slow launch every time
    Composio is slow."""
    import subprocess
    try:
        subprocess.Popen([sys.executable, os.path.realpath(__file__), "refresh-composio"],
                         env=dict(env, MOE_HOME=moe, HERMES_HOME=hermes or hermes_home(env)),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        return True
    except OSError:
        return False


def refresh_composio(moe=None, hermes=None, env=None, composio=composio_emails):
    """The detached half: ask Composio (up to its own timeout), then fold the
    answer into owner.json. An unanswered ask keeps what was there."""
    env = os.environ if env is None else env
    moe = moe or moe_home(env)
    found = composio(moe, env) if composio else None
    if found is None:
        return None
    old = _load_json(os.path.join(moe, OWNER_FILE))
    grounding = old.get("grounding") if isinstance(old, dict) and isinstance(old.get("grounding"), bool) else None
    return write_owner(moe, hermes, env, grounding=grounding, composio=None, composio_found=found)


def write_owner(moe=None, hermes=None, env=None, grounding=None, composio=None,
                composio_found=None, now=None):
    """Write $MOE_HOME/owner.json from the sources; keeps a `pinned` block.

    `grounding`: whether the installed Hermes keeps recipient ledgers (its code
    has agent/recipient_grounding.py). Pinned here, in a file no tool call may
    write, so the send gate refuses a send with no ledger even if the ledger
    directory and its marker are gone. None: decide from HERMES_HOME's code."""
    env = os.environ if env is None else env
    moe = moe or moe_home(env)
    path = os.path.join(moe, OWNER_FILE)
    old = _load_json(path)
    record = {"version": 1,
              "README": "Who owns this Moe, as addresses. Written on every sync from the "
                        "accounts this Mac has linked; add your own (and \"nicknames\") under "
                        "\"pinned\". A contact tool never messages these unasked.",
              "written": datetime.datetime.now().isoformat(timespec="seconds"),
              **collect(moe, hermes, env)}
    if grounding is None:
        grounding = os.path.isfile(os.path.join(hermes or hermes_home(env), "hermes-agent",
                                                "agent", "recipient_grounding.py"))
    record["grounding"] = bool(grounding)
    # The owner's Composio mail addresses. Composio answers over the network,
    # so this NEVER waits on it: it uses what was cached last time, and when
    # that is older than COMPOSIO_TTL it starts a detached refresh (or, in a
    # test, calls `composio` — which must be fast). An owner does not stop
    # being the owner offline.
    import time as _time
    now = _time.time() if now is None else now
    cached = [e for e in (old.get("composio_emails") or []) if isinstance(e, str)] \
        if isinstance(old, dict) and isinstance(old.get("composio_emails"), list) else []
    checked = old.get("composio_checked") if isinstance(old, dict) else None
    checked = checked if isinstance(checked, (int, float)) else 0
    if composio_found is not None:
        cached, checked = list(composio_found), now
    elif now - checked > COMPOSIO_TTL:
        if composio is not None:
            got = composio(moe, env)
            if got is not None:
                cached, checked = list(got), now
        elif env.get("MOE_HOOK_TEST") != "1" or env.get("MOE_TEST_COMPOSIO_DETACHED") == "1":
            _refresh_composio_detached(moe, hermes, env)
    record["composio_emails"] = cached
    record["composio_checked"] = checked
    for e in cached:
        _add(record, "emails", e)
    if isinstance(old, dict) and isinstance(old.get("pinned"), dict):
        record["pinned"] = old["pinned"]
    os.makedirs(moe, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=moe, prefix=".owner.")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(record, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return record


def address_is_owner(raw, owner):
    """Why the ADDRESS `raw` (a number, an id, an email) is the owner's, or ""."""
    text = str(raw or "").strip()
    fc = facets(text)
    stripped = PLATFORM_PREFIX.sub("", text, count=1).strip().lstrip("@")
    for tid in owner.get("telegram", []):
        if stripped == tid:
            return "it is the owner's Telegram id"
    for p in fc["phones"] + [e164(i) for i in fc["ids"] if i.isdigit()]:
        if any(same_number(p, e164(o)) for o in owner.get("phones", [])):
            return "it is the owner's own number"
    for i in fc["ids"]:
        if i in owner.get("ids", []):
            return "it is the owner's own account"
    owner_mail = {email_key(e) for e in owner.get("emails", [])}
    for e in fc["emails"]:
        if email_key(e) in owner_mail:
            return "it is the owner's own address"
    return ""


def owner_match(raw, owner):
    """Why `raw` is the owner, or "" when it is not."""
    text = str(raw or "").strip()
    f = fold(text)
    if not f:
        return ""
    if f in SELF_WORDS:
        return "it is addressed to \"%s\"" % text
    why = address_is_owner(text, owner)
    if why:
        return why
    name = facets(text)["name"]
    if name and any(fold(name) == fold(o) for o in owner.get("names", [])):
        return "it is the owner's own name"
    return ""


def names_the_owner(addressee, owner):
    """A name the REQUEST used — "Jordan", "me" — that means the owner. A first
    name or a nickname alone counts here: this is who was asked for."""
    a = fold(addressee)
    if a in SELF_WORDS:
        return True
    for o in owner.get("names", []):
        toks = name_tokens(o)
        if a == fold(o) or (toks and a == toks[0]):
            return True
    return False


def sender_is_owner(sender, owner):
    """Whether a words entry was written by the owner: the Mac's own surfaces,
    or a chat message whose sender id is one of the owner's addresses."""
    if not isinstance(sender, dict):
        return False
    kind = sender.get("kind")
    if kind == "local":
        return True
    if kind != "chat":
        return False
    platform = str(sender.get("platform") or "").lower()
    for uid in (sender.get("user_id"), sender.get("user_id_alt")):
        uid = str(uid or "").strip()
        if not uid:
            continue
        if platform == "telegram":
            if uid.lstrip("@") in owner.get("telegram", []):
                return True
            continue
        if address_is_owner(uid, owner):
            return True
    return False


# ── the ledger ───────────────────────────────────────────────────────────────

def grounding_key(session_id="", env=None):
    """HERMES_GROUNDING_KEY (the claude_code / codex MCP servers), else the
    call's own session id (the hook's payload — the call context, never a
    process environment another session may have written)."""
    env = os.environ if env is None else env
    return str(env.get(GROUNDING_KEY_ENV) or "").strip() or str(session_id or "").strip()


def ledger_path(key, hermes=None):
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]
    return os.path.join(hermes or hermes_home(), LEDGER_DIR, digest + ".json")


def grounding_enabled(hermes=None, moe=None):
    """Whether this Hermes keeps ledgers — decided from things the model cannot
    quietly remove: the owner record's pin (written by configure-hermes.py from
    the installed Hermes, gate-protected), the installed Hermes code itself,
    and the marker Hermes leaves beside its ledgers. Any one is enough; a
    deleted marker turns nothing off."""
    hermes = hermes or hermes_home()
    rec = _load_json(os.path.join(moe or moe_home(), OWNER_FILE))
    if isinstance(rec, dict) and (rec.get("grounding") is True or
                                  (isinstance(rec.get("pinned"), dict) and rec["pinned"].get("grounding") is True)):
        return True
    if os.path.isfile(os.path.join(hermes, "hermes-agent", "agent", "recipient_grounding.py")):
        return True
    return os.path.exists(os.path.join(hermes, LEDGER_DIR, ENABLED_MARKER))


def read_ledger(key, hermes=None, moe=None):
    """("off", None) — this Hermes keeps no ledgers; ("broken", why) — it does,
    and this conversation's is missing or unreadable; ("ok", ledger)."""
    hermes = hermes or hermes_home()
    if not grounding_enabled(hermes, moe):
        return "off", None
    if not key:
        return "broken", "this call carries no conversation key"
    data = _load_json(ledger_path(key, hermes))
    if data is None:
        return "broken", "there is no record of this conversation"
    if not isinstance(data, dict) or data.get("version") != LEDGER_VERSION:
        return "broken", "the record of this conversation is in a format this Moe cannot read"
    words = [w for w in data.get("words") or []
             if isinstance(w, dict) and isinstance(w.get("text"), str)]
    results = [r for r in data.get("results") or []
               if isinstance(r, dict) and isinstance(r.get("text"), str)]
    current = data.get("current") if isinstance(data.get("current"), dict) else None
    # What Moe said at the end of each turn (a Hermes from before 2026-10-07 keeps none).
    replies = [r for r in data.get("replies") or []
               if isinstance(r, dict) and isinstance(r.get("text"), str)]
    return "ok", {"words": words, "results": results, "current": current, "replies": replies,
                  # {"prompt": the job's own stored prompt}, or nothing.
                  "legacy_job": ({"prompt": str(data["legacy_job"].get("prompt") or "")}
                                 if isinstance(data.get("legacy_job"), dict) else None)}


# ── where a name or an address appears ───────────────────────────────────────

def _quote(text, start, end, width=160):
    lo = max(text.rfind(c, 0, start) for c in ".!?\n") + 1
    hi_c = [i for i in (text.find(c, end) for c in ".!?\n") if i >= 0]
    hi = min(hi_c) + 1 if hi_c else len(text)
    snippet = re.sub(r"\s+", " ", text[lo:hi]).strip()
    if len(snippet) > width:
        mid = (start + end) // 2 - lo
        a = max(0, mid - width // 2)
        snippet = ("…" if a else "") + snippet[a:a + width].strip() + "…"
    return snippet


def _fold_map(text):
    """`text` folded (accents off, case folded) with, for every folded
    character, the index of the original character it came from — so a match
    found in folded text is quoted from the original, in the person's casing."""
    out, idx = [], []
    for i, ch in enumerate(text or ""):
        for c in unicodedata.normalize("NFKD", ch):
            if unicodedata.combining(c):
                continue
            for f in c.casefold():
                out.append(f)
                idx.append(i)
    return "".join(out), idx


# A Hebrew word can carry a one-letter prefix — "למשה" is "to Walter".
HEBREW_PREFIX = "[לבמהושכ]"
NEGATION = re.compile(
    r"(?i)(?:\b(?:don'?t|do not|never|not|no|stop|without|except|instead of|rather than)\b"
    r"|(?<![\w])(?:אל|לא)(?![\w]))[^.!?\n]{0,30}$")


def _find_folded(phrase, text):
    """(start, end) in the ORIGINAL text of `phrase` as whole words, accents and
    case folded on both sides, a Hebrew one-letter prefix allowed; or None."""
    folded_text, idx = _fold_map(text)
    parts = [re.escape(p) for p in fold(phrase).split()]
    if not parts or not folded_text:
        return None
    m = re.search(r"(?<![\w])(?:" + HEBREW_PREFIX + r")?" + r"\s+".join(parts) + r"(?![\w])",
                  folded_text)
    if not m:
        return None
    return idx[m.start()], idx[m.end() - 1] + 1


def negated(text, start):
    """A mention the sentence itself says no to: "don't message Dan"."""
    return bool(NEGATION.search(text[max(0, start - 60):start]))


def find_address(fc, text):
    """(start, end) of this recipient's address in `text`, or None."""
    low = (text or "").casefold()
    for e in fc["emails"]:
        i = low.find(e.casefold())
        if i >= 0:
            return i, i + len(e)
    if fc["phones"]:
        for m in DIGIT_RUN.finditer(text or ""):
            if any(same_number(p, e164(m.group(0))) for p in fc["phones"]):
                return m.start(), m.end()
    for ident in fc["ids"]:
        m = re.search(r"(?<![\w-])@?" + re.escape(ident) + r"(?![\w])", text or "")
        if m:
            return m.start(), m.end()
    return None


def find_name(fc, text):
    """("full"|"partial", start, end) of the recipient's name in `text`, or None.

    Full: the whole name, as a phrase. Partial: only its FIRST name, and only
    when that is a real name rather than a word ("Walter", never "Will"). A
    one-word name that is also a common word ("Family") must appear exactly as
    written. Accents and case are folded on both sides; the quote keeps the
    person's own. A mention the sentence says no to is never full."""
    name = (fc["name"] or "").strip()
    toks = name_tokens(name)
    if not toks:
        return None
    if len(toks) == 1 and not significant(toks[0]):
        m = re.search(r"(?<![\w])" + re.escape(name) + r"(?![\w])", text or "")
        hit = ("full", m.start(), m.end()) if m else None
    else:
        span = _find_folded(name, text)
        hit = ("full",) + span if span else None
        if not hit and len(toks) > 1 and significant(toks[0]):
            span = _find_folded(toks[0], text)
            hit = ("partial",) + span if span else None
    if hit and hit[0] == "full" and negated(text, hit[1]):
        hit = ("partial", hit[1], hit[2])
    return hit


# ── lookups: the only tool results that may ground a recipient ───────────────

# Moe's own connector verbs that return people — by name, from Moe's own
# servers only. Each one grounds only the FIELDS of its output that name who a
# message or chat is from or to (`lookup_text`), never a message body: whoever
# wrote a body chose its words, and a body naming someone is not a lookup
# returning them. The calendar connectors print no attendees, so they are not
# lookups at all.
MOE_LOOKUPS = frozenset("""
whatsapp_find whatsapp_chats whatsapp_pull whatsapp_items whatsapp_crawl
telegram_pull telegram_crawl imessage_pull imessage_crawl calls_pull calls_crawl
gmail_pull gmail_crawl contacts_find
""".split())
# The broker's mail and calendar results: header fields of the JSON only.
HEADER_ONLY = re.compile(r"^(?:GMAIL_(?!SEARCH_PEOPLE|GET_CONTACTS|GET_PEOPLE)|OUTLOOK_(?!\w*CONTACT)|GOOGLECALENDAR_)")
# The broker's lookups, by toolkit and verb.
LOOKUP_SLUG = re.compile(
    r"^(?:GMAIL_(?:FETCH|LIST|SEARCH|GET)_\w+|GOOGLECONTACTS_\w+|GOOGLE_PEOPLE_\w+"
    r"|OUTLOOK_(?:LIST|SEARCH|GET)_\w+|GOOGLECALENDAR_(?:FIND|LIST|GET)_\w+"
    r"|SLACK_(?:FIND|LIST|SEARCH)_\w*(?:USER|MEMBER|CONVERSATION)\w*)$")
OWN_SERVERS = frozenset({"moe", "hermes-tools", "hermes_tools"})
BROKER_SERVERS = frozenset({"composio"})
SOURCE_LABEL = (
    (re.compile(r"^whatsapp_", re.I), "your WhatsApp chats"),
    (re.compile(r"^telegram_", re.I), "your Telegram"),
    (re.compile(r"^imessage_", re.I), "your Messages"),
    (re.compile(r"^(contacts_|GOOGLECONTACTS_|GOOGLE_PEOPLE_)", re.I), "your contacts"),
    (re.compile(r"^calls_", re.I), "your calls"),
    (re.compile(r"^GMAIL_(SEARCH_PEOPLE|GET_CONTACTS|GET_PEOPLE)", re.I), "your contacts"),
    (re.compile(r"^(gmail_|GMAIL_|OUTLOOK_)", re.I), "your mail"),
    (re.compile(r"^(calendar_|GOOGLECALENDAR_)", re.I), "your calendar"),
    (re.compile(r"^SLACK_", re.I), "Slack"),
)
QUERY_KEYS = ("query", "q", "name", "search", "term", "contact", "person", "keyword",
              "keywords", "filter", "who", "text_query", "search_query")
# Who a message is from and to. Not Reply-To: that is one more line a sender
# writes, and the person asked about the sender, not wherever it points.
HEADER_KEYS = frozenset({"from", "to", "cc", "bcc", "sender", "recipient",
                         "recipients", "attendee", "attendees", "organizer", "participants",
                         "torecipients", "ccrecipients", "bccrecipients", "fromaddress",
                         "toaddress", "emailaddress", "creator"})
# Gmail's own `payload.headers`: [{"name": "From", "value": "…"}, …].
HEADER_NAMES = frozenset({"from", "to", "cc", "bcc", "sender"})


def _segments(tool):
    """(servers, bare) for a tool id — `mcp__composio__GMAIL_SEARCH` →
    (["composio"], "GMAIL_SEARCH")."""
    t, servers = str(tool or ""), []
    while True:
        m = re.match(r"^mcp__(.+?)__(.+)$", t)
        if not m:
            return servers, t
        servers.append(m.group(1))
        t = m.group(2)


def _args(row):
    try:
        a = json.loads(row.get("args") or "{}")
    except (TypeError, ValueError):
        return {}
    return a if isinstance(a, dict) else {}


def lookup_names(row):
    """The lookup(s) a result came from, or [] when it is not one we trust."""
    servers, bare = _segments(row.get("tool"))
    if bare in MOE_LOOKUPS and all(s in OWN_SERVERS for s in servers):
        return [bare]
    brokered = all(s in OWN_SERVERS | BROKER_SERVERS for s in servers)
    if not brokered:
        return []
    if LOOKUP_SLUG.match(bare):
        return [bare]
    slugs = []
    tools = _args(row).get("tools")
    for item in tools if isinstance(tools, list) else []:
        if isinstance(item, dict):
            slug = str(item.get("tool_slug") or item.get("slug") or "")
            if slug:
                slugs.append(slug)
    # A broker's multiplexer is a lookup only when everything in it is one.
    return slugs if slugs and all(LOOKUP_SLUG.match(s) for s in slugs) else []


def source_label(names):
    for name in names:
        for rx, label in SOURCE_LABEL:
            if rx.search(name):
                return label
    return "a lookup (%s)" % (names[0] if names else "?")


def _norm_key(key):
    return re.sub(r"[^a-z0-9]", "", str(key).lower())


def _leaves(value, out, depth=0):
    if depth > 6:
        return
    if isinstance(value, dict):
        for v in value.values():
            _leaves(v, out, depth + 1)
    elif isinstance(value, list):
        for v in value[:200]:
            _leaves(v, out, depth + 1)
    elif isinstance(value, (str, int)) and not isinstance(value, bool):
        out.append(str(value))


def _headers(value, out, depth=0):
    if depth > 8:
        return
    if isinstance(value, dict):
        name = value.get("name")
        if isinstance(name, str) and name.strip().lower() in HEADER_NAMES and \
                isinstance(value.get("value"), str) and set(value) <= {"name", "value"}:
            out.append(value["value"])
            return
        for k, v in value.items():
            if _norm_key(k) in HEADER_KEYS:
                leaves = []
                _leaves(v, leaves)
                out.append(" ".join(leaves))
            elif isinstance(v, str) and v.lstrip()[:1] in ("{", "["):
                # A broker often wraps its tool's JSON as a string in `data`.
                try:
                    _headers(json.loads(v), out, depth + 1)
                except ValueError:
                    pass
            else:
                _headers(v, out, depth + 1)
    elif isinstance(value, list):
        for v in value[:500]:
            _headers(v, out, depth + 1)


def header_text(text):
    """Only the From/To/Cc/attendee FIELDS of a broker's mail or calendar JSON,
    one per line. Text that is not JSON yields nothing: a line reading
    "From: …" inside a body is still the body."""
    out = []
    try:
        _headers(json.loads(text), out)
    except (TypeError, ValueError):
        pass
    return "\n".join(o.strip() for o in out if o.strip())


def _lines(text):
    # "\n" only: str.splitlines also breaks on \r, \x0b, \u2028… inside a body.
    return (text or "").split("\n")


def _gmail_pull(text):
    # gmail.py fetch(): "- when | UNREAD|read | From | Subject". A Date that
    # carries " | " shifts the flag out of place and the line is dropped.
    for ln in _lines(text):
        if ln.startswith("- "):
            parts = ln[2:].split(" | ")
            if len(parts) >= 3 and parts[1] in ("UNREAD", "read"):
                yield parts[2]


GMAIL_BLOCK = re.compile(r"^### .* \| from (.*) \| to (.*)$")


def _gmail_crawl(text):
    # gmail.py crawl_folder(): "### date | subject | from X | to Y", then the
    # body — which body_text() flattens to ONE line, so no line of a body can
    # pass for a heading.
    for ln in _lines(text):
        m = GMAIL_BLOCK.match(ln)
        if m:
            yield m.group(1)
            yield m.group(2)


def _whatsapp_rows(text):
    # whatsapp.sh pull/crawl: "time|chat|sender|content" — the content is the
    # last field, so a "|" in a chat name only pushes the sender out of reach.
    for ln in _lines(text):
        parts = ln.split("|", 3)
        if len(parts) == 4:
            yield parts[1]
            yield parts[2]


def _whatsapp_chats(text):
    # "name|jid|time" (chats), "name|jid" (find): no bodies at all.
    for ln in _lines(text):
        yield ln


def _whatsapp_items(text):
    for ln in _lines(text):
        try:
            item = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(item, dict):
            continue
        who = item.get("from") if isinstance(item.get("from"), dict) else {}
        for v in (item.get("thread_name"), item.get("thread"), who.get("name"), who.get("id")):
            if isinstance(v, str) and v:
                yield v


def _telegram(text):
    # telegram.py pull: "**chat**" then "- stamp | who: text";
    #             crawl: "## chat: name" then "stamp | who: text".
    for ln in _lines(text):
        if ln.startswith("**") and ln.endswith("**") and len(ln) > 4:
            yield ln[2:-2]
        elif ln.startswith("## chat: "):
            yield ln[len("## chat: "):]
        else:
            body = ln[2:] if ln.startswith("- ") else ln
            stamp, sep, rest = body.partition(" | ")
            if sep and ": " in rest:
                yield rest.split(": ", 1)[0]


def _imessage_pull(text):
    # imessage.sh pull: "when | me -> handle" or "handle -> me" | text.
    for ln in _lines(text):
        parts = ln.split(" | ", 2)
        if len(parts) == 3:
            yield parts[1]


def _imessage_crawl(text):
    # imessage.sh crawl: "when | chat | sender | text" — the text is last, so
    # a " | " in a chat name only pushes the sender out of reach.
    for ln in _lines(text):
        parts = ln.split(" | ", 3)
        if len(parts) == 4:
            yield parts[1]
            yield parts[2]


def _calls(text):
    # calls.sh: "when | incoming|outgoing | answered|missed | address | 42s".
    for ln in _lines(text):
        parts = ln.split(" | ")
        if len(parts) == 5 and parts[1] in ("incoming", "outgoing"):
            yield parts[3]


def _whole(text):
    # Contacts: every field is a person or an address; there is no body.
    yield from _lines(text)


LOOKUP_FIELDS = {
    "gmail_pull": _gmail_pull, "gmail_crawl": _gmail_crawl,
    "whatsapp_pull": _whatsapp_rows, "whatsapp_crawl": _whatsapp_rows,
    "whatsapp_chats": _whatsapp_chats, "whatsapp_find": _whatsapp_chats,
    "whatsapp_items": _whatsapp_items,
    "telegram_pull": _telegram, "telegram_crawl": _telegram,
    "imessage_pull": _imessage_pull, "imessage_crawl": _imessage_crawl,
    "calls_pull": _calls, "calls_crawl": _calls, "contacts_find": _whole,
}


def lookup_text(names, text):
    """The part of a trusted lookup's result that may ground a recipient: the
    fields naming who a message or chat is from or to, one per line — never a
    message body. A lookup this does not know how to read yields nothing."""
    if all(n in LOOKUP_FIELDS for n in names) and names:
        out = []
        for n in names:
            out.extend(f.strip() for f in LOOKUP_FIELDS[n](text) if f and f.strip())
        return "\n".join(out)
    if any(n in MOE_LOOKUPS for n in names):
        return ""
    if any(HEADER_ONLY.match(n) for n in names):
        return header_text(text)
    return text or ""


def _queries(value, out, depth=0):
    if depth > 4:
        return
    if isinstance(value, dict):
        for k, v in value.items():
            if str(k).lower() in QUERY_KEYS and isinstance(v, str) and v.strip():
                out.append(v.strip())
            else:
                _queries(v, out, depth + 1)
    elif isinstance(value, list):
        for v in value:
            _queries(v, out, depth + 1)


def lookup_query(row):
    out = []
    _queries(_args(row), out)
    return out[0] if out else ""


# ── grounding ────────────────────────────────────────────────────────────────

def owner_words(ledger, owner):
    return [w["text"] for w in ledger.get("words") or []
            if w.get("origin") == "person" and sender_is_owner(w.get("sender"), owner)]


def context_texts(ledger):
    """This turn's instructions, whoever wrote them: the current message and any
    model-written job or goal text. They can refuse; they never ground."""
    out = []
    cur = ledger.get("current")
    if isinstance(cur, dict) and isinstance(cur.get("text"), str):
        out.append(cur["text"])
    for w in ledger.get("words") or []:
        if w.get("origin") == "model" and w["text"] not in out:
            out.append(w["text"])
    return out


def _entry_around(text, start, end, reach=120):
    edge = re.compile(r"\n|;|\}|\{|\]|\[|\|")
    lo = max(0, start - reach)
    before = [m.end() for m in edge.finditer(text, lo, start)]
    after = edge.search(text, end, min(len(text), end + reach))
    return text[(before[-1] if before else lo):(after.start() if after else min(len(text), end + reach))]


def _asked_for(query, said):
    joined = "\n".join(said)
    toks = [t for t in name_tokens(query) if significant(t)] or name_tokens(query)
    return any(_find_folded(t, joined) for t in toks) or bool(find_address(facets(query), joined))


def _lookup_rows(ledger):
    """(names, searchable text, row) for every result that is a trusted lookup."""
    for row in reversed(ledger.get("results") or []):
        names = lookup_names(row)
        if not names:
            continue
        text = lookup_text(names, row.get("text") or "")
        if text:
            yield names, text, row


def _found(names, text, hit, row, said, partial=None):
    query = lookup_query(row)
    out = {"state": "found", "source": source_label(names),
           "context": _entry_around(text, hit[0], hit[1])}
    if not query or not _asked_for(query, said):
        # A chat list pulled up, or a search the owner never named: Moe chose.
        out.update(query=query, query_unasked=True)
    if partial:
        out["said"] = partial["said"]
    return out


# ── shown: an address Moe found, showed the owner, and the owner said yes ──
#
# Ticket #22, 2026-10-07: the owner asked Moe to email a company whose address
# was on the page on their screen. Moe named it in its message, the owner said
# "good", and the gate refused — the address was in no words the owner typed
# and no contact lookup. It was in a screen capture, and in Moe's own message.
# Neither grounds an address alone: a page is anybody's words, and Moe's
# message is Moe's. Together with the owner's yes straight after, they are
# the owner choosing something they were shown — so it goes to the card,
# always, with where it came from and what they said.

#: Tools whose results are what a page or the screen showed — by name, from
#: Hermes's own tools only (no MCP server's). Not a shell, a file, code, or a
#: browser_cdp call: there the model writes what is printed. browser_exec is the
#: one browser tool since the 0.3.26 pin (upstream retired browser_navigate,
#: browser_snapshot, browser_vision and the rest of the legacy set).
SHOWN_TOOLS = frozenset("""
browser_exec web_extract web_search web_crawl computer_use
""".split())
SCREEN_TOOLS = frozenset({"computer_use"})
URL = re.compile(r"https?://([^/\s\"'<>]+)", re.I)

#: The owner saying yes, in a few words. The first word must be one of these;
#: none of NOT_YES may appear anywhere; nothing that could be another address.
YES_LEAD = frozenset("""
yes yeah yea yep yup ya sure ok okay k kk good great perfect fine correct right go send sent
approved approve confirm confirmed absolutely definitely lgtm please do sounds looks
כן בסדר יאללה סבבה מעולה טוב
""".split())
NOT_YES = frozenset("""
no not nope nah don't dont wait stop hold cancel change instead but actually wrong never
later different other else hmm if unless without except
לא אל רגע
""".split())
YES_MARKS = ("\U0001F44D", "\u2705", "\u2714")   # 👍 ✅ ✔


def affirmative(text):
    """Whether the owner's whole reply is a plain yes: "good", "yes send it",
    "looks good 👍". A question, a "but", another address, or more than eight
    words is not."""
    t = str(text or "").strip()
    if not t or "?" in t or "@" in t or re.search(r"\d{3}", t):
        return False
    marked = any(m in t for m in YES_MARKS)
    words = re.findall(r"[\w']+", t.casefold())
    if not words:
        return marked
    if len(words) > 8 or any(w in NOT_YES for w in words):
        return False
    return words[0] in YES_LEAD


def _shown_source(bare, row, text, hit):
    if bare in SCREEN_TOOLS:
        return "your screen"
    a = _args(row)
    for v in [a.get("url"), a.get("urls")] + [text[:300], text]:
        for u in (v if isinstance(v, list) else [v]):
            m = URL.search(str(u or ""))
            if m:
                host = m.group(1).lower().split("@")[-1].split(":")[0]
                return host[4:] if host.startswith("www.") else host
    return "a web page"


def shown(fc, ledger, owner):
    """{"state": "shown", …} when this address was found on a page or the
    screen, then named in Moe's message just before the owner's latest one,
    and that one says yes — else None."""
    cur = ledger.get("current")
    if not (isinstance(cur, dict) and cur.get("origin") == "person"
            and sender_is_owner(cur.get("sender"), owner) and affirmative(cur.get("text"))):
        return None
    at = cur.get("at")
    if not isinstance(at, (int, float)) or isinstance(at, bool):
        return None
    before = [r for r in ledger.get("replies") or [] if isinstance(r, dict)
              and isinstance(r.get("at"), (int, float)) and r["at"] < at and isinstance(r.get("text"), str)]
    if not before:
        return None
    reply = max(before, key=lambda r: r["at"])
    if not find_address(fc, reply["text"]):
        return None
    for row in reversed(ledger.get("results") or []):
        if not isinstance(row, dict):
            continue
        servers, bare = _segments(row.get("tool"))
        if bare not in SHOWN_TOOLS or not all(s in OWN_SERVERS for s in servers):
            continue
        found_at = row.get("at")
        if isinstance(found_at, (int, float)) and found_at > reply["at"]:
            continue          # read after Moe's message: not what it showed
        text = row.get("text") or ""
        hit = find_address(fc, text)
        if not hit or find_address(fc, row.get("args") or ""):
            continue          # not there, or the call was handed it (an echo)
        return {"state": "shown", "source": _shown_source(bare, row, text, hit),
                "said": _quote(cur["text"], 0, len(cur["text"])),
                "context": _entry_around(text, hit[0], hit[1])}
    return None


def ground(raw, ledger, owner):
    """{"state": named|partial|found|shown|ungrounded, …} for one recipient.

    A recipient that carries an ADDRESS (an email, a number, a chat id) is
    grounded by that address: the owner gave it, or a lookup returned it — and
    returned it FOR THIS PERSON, when the recipient names one. A name the owner
    said only adds confidence; "Walter Brennan <evil@x.com>" is not named
    because Walter Brennan is."""
    fc = facets(raw)
    said = owner_words(ledger, owner)
    has_address = bool(fc["emails"] or fc["phones"] or fc["ids"])
    if has_address:
        for text in reversed(said):
            hit = find_address(fc, text)
            if hit:
                if negated(text, hit[0]):
                    return {"state": "partial", "quote": _quote(text, hit[0], hit[1]),
                            "said": text[hit[0]:hit[1]]}
                return {"state": "named", "quote": _quote(text, hit[0], hit[1])}
        for names, text, row in _lookup_rows(ledger):
            hit = find_address(fc, text)
            if not hit:
                continue
            entry = _entry_around(text, hit[0], hit[1])
            if fc["name"] and not find_name(fc, entry):
                continue          # this address, but returned for somebody else
            return _found(names, text, hit, row, said)
        g = shown(fc, ledger, owner)
        if g:
            return g
        return {"state": "ungrounded", "address": True}
    partial = None
    for text in reversed(said):
        nh = find_name(fc, text)
        if nh and nh[0] == "full":
            return {"state": "named", "quote": _quote(text, nh[1], nh[2])}
        if nh and partial is None:
            partial = {"state": "partial", "quote": _quote(text, nh[1], nh[2]),
                       "said": text[nh[1]:nh[2]]}
    for names, text, row in _lookup_rows(ledger):
        nh = find_name(fc, text)
        if nh and nh[0] == "full":
            return _found(names, text, (nh[1], nh[2]), row, said, partial)
    if partial:
        return partial
    return {"state": "ungrounded"}


_NAME = r"[A-Z][\w'’-]+(?:\s+[A-Z][\w'’-]+)?"
_SEND_WORDS = r"(?i:send|message|text|email|e-mail|write|whatsapp|telegram|dm|ping|notify|reply|forward)"
ADDRESSEE = (
    re.compile(r"\b" + _SEND_WORDS + r"\b[^.\n]{0,80}?\b(?i:to)\s+(me|myself|" + _NAME + r")"),
    re.compile(r"\b(?i:message|text|email|e-mail|tell|ping|dm|notify|whatsapp|telegram|call)\s+(me|myself|"
               + _NAME + r")\b"),
    re.compile(r"\b(?i:send)\s+(me)\b"),
)


def addressees(text):
    """Who the text asks to be messaged, in its own words, first seen first."""
    out = []
    for rx in ADDRESSEE:
        for m in rx.finditer(text or ""):
            name = m.group(1).strip()
            first = fold(name.split()[0]) if name.split() else ""
            if not name or (first in COMMON and first not in ("me", "myself")):
                continue
            if name not in out:
                out.append(name)
    return out


def _same_person(addressee, raw, context=""):
    a = set(name_tokens(addressee))
    if not a:
        return False
    fc = facets(raw)
    r = set(name_tokens(fc["name"])) if fc["name"] else set()
    for e in fc["emails"]:
        r |= set(name_tokens(re.sub(r"[._+\d-]+", " ", e.split("@")[0])))
    if r & a:
        return True
    folded = fold(context)
    return any(re.search(r"(?<![\w])" + re.escape(t) + r"(?![\w])", folded) for t in a)


# ── the verdict ──────────────────────────────────────────────────────────────

def reach_owner_registered(hermes=None, env=None):
    """Whether this Hermes has a `reach_owner` tool to point the model at.

    The moe-screen plugin registers it (slice A, reach.py). A refusal that
    names a tool the model does not have sends it looking for one — or
    improvising one — so the wording follows what is installed. A forged file
    here changes only which sentence a refusal says: never whether it refuses."""
    env = os.environ if env is None else env
    hermes = hermes or hermes_home(env)
    for plugin in (os.path.join(hermes, "plugins", "moe-screen"),):
        try:
            with open(os.path.join(plugin, "reach.py"), encoding="utf-8") as fh:
                if re.search(r"""^TOOL_NAME\s*=\s*["']%s["']""" % REACH_OWNER_TOOL, fh.read(), re.M):
                    return True
        except OSError:
            pass
    return False


def owner_door(reach):
    if reach:
        return "use %s" % REACH_OWNER_TOOL
    return "put it in your reply — the person will see it"


def refusal_owner(raw, why, reach=False):
    return ("Not sent: this message would go to the owner — %s (\"%s\") — and nobody asked to reach "
            "them. A contact tool never messages the owner unasked; to reach the owner, %s."
            % (why, raw, owner_door(reach)))


def refusal_request_is_owner(raw, asked, reach=False):
    return ("Not sent: the request asks you to reach \"%s\", who is the owner — and this was going "
            "to \"%s\" through a contact tool. Never send the owner's message to one of their "
            "contacts: to reach the owner, %s (in a scheduled job, put it in your final "
            "response). If they meant someone else who shares that name, ask them which."
            % (asked, raw, owner_door(reach)))


def refusal_ungrounded(raw):
    return ("Not sent: the owner never named \"%s\" in this conversation, and no contact, chat or "
            "mail lookup returned them — the name came from memory, a job's own text, somebody "
            "else's message or a guess. Look the person up or ask; never pick a recipient from "
            "memory." % raw)


def refusal_address(raw):
    return ("Not sent: \"%s\" carries an address the owner never gave and no contact, chat or "
            "mail lookup returned for that person — a name the owner said does not vouch for an "
            "address beside it. Look the person up or ask." % raw)


def refusal_broken(why):
    return ("Not sent: Moe could not check who asked for this recipient — %s. Nothing was sent; "
            "ask the person to confirm who to send it to." % why)


# People a job's prompt names by relation, not by name: "text my wife",
# "send mom the list". Only for the Jobs card's "keep?" — never grounding.
RELATIONS = frozenset("""
wife husband partner spouse mom mum mother mommy mama dad father daddy papa parents son daughter
kids children brother sister grandma grandpa grandmother grandfather granny bubby zeidy savta saba
aunt uncle cousin nephew niece boss manager assistant secretary accountant lawyer doctor dentist
landlord tenant girlfriend boyfriend fiance fiancee friend neighbor neighbour babysitter nanny
team family
""".split())
NOT_A_PERSON = frozenset("""
summary report digest update updates list notes reminder reminders everything something it
them him her us yourself myself me everyone anyone someone people all out back over
""".split())
_RELATION_ASK = re.compile(
    r"\b(?i:send|text|message|email|e-mail|tell|ping|remind|call|dm|whatsapp|notify|write)\s+"
    r"(?:(?i:to)\s+)?((?i:my|our)\s+)?([A-Za-z][\w'’-]+)")
# Bare first names, lower-cased as people type them: only after verbs whose
# object is a person ("remind dan", "text avi"), never after "send".
_PERSON_VERB = frozenset({"text", "message", "tell", "ping", "remind", "call", "dm", "whatsapp", "notify"})


def _asks_by_relation(text):
    out = []
    for m in _RELATION_ASK.finditer(text or ""):
        verb = m.group(0).split()[0].lower()
        word = m.group(2)
        low = fold(word)
        if low in RELATIONS:
            ask = ("my " if m.group(1) else "") + word
        elif low in NOT_A_PERSON or (low in COMMON and low not in RELATIONS) or len(low) < 2:
            continue
        elif m.group(1) is None and verb in _PERSON_VERB and word == word.lower():
            ask = word
        else:
            continue
        if ask not in out:
            out.append(ask)
    return out


def job_asks_for(prompt):
    """Whom a job's own prompt asks it to message, in its words: the names the
    Jobs card asks "keep?" about — capitalised names, people named by relation
    ("my wife", "mom") or a bare first name after a person verb ("remind
    dan") — and any address the prompt spells out."""
    text = str(prompt or "")
    asked = addressees(text)[:3]
    for a in _asks_by_relation(text):
        if len(asked) < 3 and not any(fold(a) in fold(x) or fold(x) in fold(a) for x in asked):
            asked.append(a)
    for e in EMAIL.findall(text):
        if e not in asked:
            asked.append(e)
    for p in DIGIT_RUN.findall(text):
        if len(digits(p)) >= 7 and p not in asked:
            asked.append(p.strip())
    return asked


def legacy_soft_for(raw, legacy):
    """Whether a legacy job's send to `raw` is shown in amber rather than
    refused: only when `raw` is one of the people the job's prompt asks for.
    `legacy` is the ledger's marker, {"prompt": …}; anything else is soft
    about nobody."""
    if not isinstance(legacy, dict):
        return False
    fc = facets(raw)
    mine = set(name_tokens(fc["name"])) if fc["name"] else set()
    for ask in job_asks_for(legacy.get("prompt")):
        af = facets(ask)
        if af["emails"] or af["phones"]:
            if any(email_key(e) == email_key(x) for e in af["emails"] for x in fc["emails"]) or \
                    any(same_number(p, q) for p in af["phones"] for q in fc["phones"]):
                return True
            continue
        # A name: only the recipient's own display name counts — not the
        # local part of an address beside it, which anybody can choose.
        toks = {t for t in name_tokens(ask) if significant(t)}
        if toks and toks <= mine:
            return True
    return False


def judge(recipients, state, ledger, owner, resolved=(), reach=False):
    """{"verdict": ok|refuse, "message", "provenance"} for one send.

    `state`/`ledger` are read_ledger's answer. `recipients` are the addresses as
    the model wrote them; `resolved` what a connector turned them into (checked
    for the owner only — a jid never appears in anybody's words)."""
    people = [r for r in recipients if str(r or "").strip()]
    resolved = [r for r in resolved if str(r or "").strip()]
    if not people and not resolved:
        return {"verdict": "ok", "message": "", "provenance": None}
    if state == "off":
        # A Hermes that keeps no record: nothing to check, and nothing to say
        # on the card — an amber line on every send teaches people to ignore amber.
        return {"verdict": "ok", "message": "", "provenance": None}
    if state == "broken":
        return {"verdict": "refuse", "message": refusal_broken(ledger), "provenance": None}
    owner_why = [owner_match(r, owner) for r in people]
    resolved_why = [owner_match(r, owner) for r in resolved]
    to_owner = (people and all(owner_why)) or (resolved and all(resolved_why))
    asked = []
    for text in context_texts(ledger) + owner_words(ledger, owner)[-1:]:
        for a in addressees(text):
            if a not in asked:
                asked.append(a)
    asked_owner = [a for a in asked if names_the_owner(a, owner)]
    if to_owner:
        who, why = ((people[0], owner_why[0]) if people and all(owner_why)
                    else (resolved[0], resolved_why[0]))
        if not asked_owner:
            return {"verdict": "refuse", "message": refusal_owner(who, why, reach), "provenance": None}
        return {"verdict": "ok", "message": "",
                "provenance": {"v": 1, "state": "owner", "recipient": who, "requested": asked_owner[0]}}
    others = [r for r, why in zip(people, owner_why) if not why]
    verdicts = []
    for r in others:
        g = ground(r, ledger, owner)
        named_only_as_owner = g["state"] in ("named", "partial") and \
            any(_same_person(a, r) for a in asked_owner) and \
            not any(_same_person(a, r) for a in asked if a not in asked_owner)
        if named_only_as_owner or (g["state"] != "named" and asked_owner and len(asked_owner) == len(asked)):
            return {"verdict": "refuse", "message": refusal_request_is_owner(r, asked_owner[0], reach),
                    "provenance": None}
        if g["state"] == "ungrounded" and legacy_soft_for(r, ledger.get("legacy_job")):
            # A job made before jobs recorded who asked for them, sending to
            # somebody its own stored prompt asks for: shown, in amber, rather
            # than refused — until the person answers "keep?" on the Jobs card,
            # which records their words and ends this. Anybody else it sends
            # to (an injected thief@…) is refused like any other job's.
            g = {"state": "legacy"}
        if g["state"] == "ungrounded":
            return {"verdict": "refuse", "provenance": None,
                    "message": refusal_address(r) if g.get("address") else refusal_ungrounded(r)}
        verdicts.append((r, g))
    if not verdicts:
        return {"verdict": "ok", "message": "", "provenance": None}
    primary, g = verdicts[0]
    prov = {"v": 1, "state": g["state"], "recipient": primary}
    for k in ("quote", "said", "source", "query", "query_unasked"):
        if g.get(k):
            prov[k] = g[k]
    named_asks = [a for a in asked if not names_the_owner(a, owner)]
    if named_asks and not any(_same_person(a, primary, g.get("context", "")) for a in named_asks):
        prov["requested"] = named_asks[0]
        prov["mismatch"] = True
    return {"verdict": "ok", "message": "", "provenance": prov}


def gate(recipients, resolved=(), session_id="", env=None):
    """The verdict for one send, for the HOOK (which sees the call's session)."""
    env = os.environ if env is None else env
    owner = load_owner(env=env)
    state, ledger = read_ledger(grounding_key(session_id, env), hermes_home(env), moe_home(env))
    return judge(recipients, state, ledger, owner, resolved,
                 reach=reach_owner_registered(hermes_home(env), env))


# ── tickets: a verdict held in memory, redeemed once by the connector ──────
#
# The model has a shell under the same user, so a file it can write proves
# nothing, and neither does anything in a connector's environment. The process
# that runs Moe's connector tools (the moe-connectors plugin, inside Hermes)
# judges each send itself, just before it starts the connector, and MINTS a
# ticket in its own memory: a random nonce holding exactly the recipients, the
# words, the provenance for the card, and an expiry. The connector is handed
# the nonce and the address of a socket into that process, and REDEEMS it
# there — once; the answer is the only provenance its dialog ever shows. A
# connector started any other way has no nonce and refuses.
#
# Threat model, stated: this stops a confused or injected model taking a cheap
# path. A determined process of the same uid can read another process's
# environment while it runs; that is out of scope.

TICKET_TTL = 10 * 60
TICKET_ENV = "MOE_SEND_TICKET"
TICKET_SOCKET_ENV = "MOE_SEND_TICKET_SOCKET"


def _norm_recipients(recipients):
    """Who a send reaches, spelled one way whoever spells it: its addresses
    when it has any, else its folded name."""
    keys = set()
    for raw in recipients:
        for part in split_recipients(raw):
            fc = facets(part)
            found = [e.casefold() for e in fc["emails"]] + fc["phones"] + fc["ids"]
            keys.update(found or [fold(fc["name"] or part)])
    return sorted(keys)


def ticket_digest(recipients, body):
    blob = json.dumps([_norm_recipients(recipients), str(body or "").strip()], ensure_ascii=True)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


class TicketStore:
    """Tickets in memory: minted by the judge, redeemed once, gone at expiry."""

    def __init__(self, ttl=TICKET_TTL, clock=None):
        import threading
        import time as _time
        self.ttl = ttl
        self.clock = clock or _time.time
        self._tickets = {}
        self._lock = threading.Lock()

    def mint(self, recipients, body, provenance):
        import secrets
        nonce = secrets.token_urlsafe(24)
        with self._lock:
            now = self.clock()
            for n in [n for n, t in self._tickets.items() if t["expires"] <= now]:
                del self._tickets[n]
            self._tickets[nonce] = {"digest": ticket_digest(recipients, body),
                                    "provenance": provenance, "expires": now + self.ttl}
        return nonce

    def redeem(self, nonce, recipients, body):
        """{"ok": True, "provenance"} once, for exactly this send; else a reason."""
        with self._lock:
            ticket = self._tickets.pop(str(nonce or ""), None)
        if ticket is None:
            return {"ok": False, "error": "no such ticket (never minted, or already used)"}
        if self.clock() >= ticket["expires"]:
            return {"ok": False, "error": "the ticket has expired"}
        if ticket["digest"] != ticket_digest(recipients, body):
            return {"ok": False, "error": "the ticket is for a different message"}
        return {"ok": True, "provenance": ticket["provenance"]}


class TicketServer:
    """A TicketStore behind a Unix socket in a private directory, served from
    a thread of the process that minted the tickets."""

    def __init__(self, store=None):
        import socket
        import threading
        self.store = store or TicketStore()
        # A short directory: a Unix socket path has a ~104-byte limit, and a
        # per-user $TMPDIR under /var/folders is most of that already.
        short = "/tmp" if os.path.isdir("/tmp") and os.access("/tmp", os.W_OK) else None
        self.dir = tempfile.mkdtemp(prefix="moe-t-", dir=short)
        os.chmod(self.dir, 0o700)
        self.path = os.path.join(self.dir, "s")
        # Whose server this is, for prune_ticket_dirs: a directory whose
        # process is gone is dead whatever its socket says.
        with open(os.path.join(self.dir, "pid"), "w") as fh:
            fh.write(str(os.getpid()))
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(self.path)
        os.chmod(self.path, 0o600)
        self._sock.listen(16)
        import atexit
        atexit.register(self.close)
        t = threading.Thread(target=self._serve, name="moe-send-tickets", daemon=True)
        t.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            try:
                conn.settimeout(10)
                data = b""
                while not data.endswith(b"\n") and len(data) < 1 << 20:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                try:
                    req = json.loads(data.decode("utf-8"))
                    reply = self.store.redeem(req.get("nonce"), req.get("recipients") or [],
                                              req.get("body") or "")
                except (ValueError, AttributeError):
                    reply = {"ok": False, "error": "unreadable request"}
                conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))
            except OSError:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

    def env(self, nonce):
        return {TICKET_ENV: nonce, TICKET_SOCKET_ENV: self.path}

    def close(self):
        try:
            self._sock.close()
        except OSError:
            pass
        for p in (self.path, os.path.join(self.dir, "pid"), self.dir):
            try:
                (os.rmdir if p == self.dir else os.unlink)(p)
            except OSError:
                pass


def prune_ticket_dirs(root="/tmp", min_age=60):
    """Remove ticket directories whose server is gone — a process that died
    without its atexit (a SIGKILL, a crash) leaves /tmp/moe-t-*/ behind. Only
    this user's own real directories; one whose socket still answers is
    somebody's live server and is left alone. Returns how many went."""
    import glob
    import socket
    import stat
    import time as _time
    gone = 0
    for d in glob.glob(os.path.join(root, "moe-t-*")):
        try:
            st = os.lstat(d)
        except OSError:
            continue
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
            continue
        sock, pidfile = os.path.join(d, "s"), os.path.join(d, "pid")
        pid = ""
        try:
            with open(pidfile, encoding="utf-8") as fh:
                pid = fh.read().strip()
        except OSError:
            pass
        if pid.isdigit():
            try:
                os.kill(int(pid), 0)
                continue                  # its process is alive
            except ProcessLookupError:
                pass                      # dead
            except OSError:
                continue                  # somebody else's, or unknowable
        elif os.path.lexists(sock):
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            c.settimeout(1)
            try:
                c.connect(sock)
                continue                  # a live server: not ours to judge
            except (ConnectionRefusedError, FileNotFoundError):
                pass
            except OSError:
                continue
            finally:
                c.close()
        elif _time.time() - st.st_mtime < min_age:
            continue                      # a server between mkdtemp and bind
        try:
            for f in (sock, pidfile):
                if os.path.lexists(f):
                    os.unlink(f)
            os.rmdir(d)
            gone += 1
        except OSError:
            pass
    return gone


def redeem_ticket(socket_path, nonce, recipients, body, timeout=10):
    import socket
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(socket_path)
        s.sendall((json.dumps({"nonce": nonce, "recipients": list(recipients),
                               "body": body}) + "\n").encode("utf-8"))
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        s.close()
        reply = json.loads(data.decode("utf-8"))
        return reply if isinstance(reply, dict) else {"ok": False, "error": "unreadable answer"}
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": "could not reach the send gate (%s)" % type(exc).__name__}


NO_TICKET = ("not sent — Moe's send gate has not checked who this goes to. Send it through Moe's "
             "own send tool (whatsapp_send, gmail_send, telegram_send) in a conversation, never by "
             "running the connector yourself.")


def connector_check(recipients, body, resolved=(), env=None):
    """What a connector asks before its dialog: its ticket, redeemed in the
    process that minted it, and — the one thing only the connector can see —
    whether the address it resolved to is the owner's."""
    env = os.environ if env is None else env
    nonce, sock = str(env.get(TICKET_ENV) or ""), str(env.get(TICKET_SOCKET_ENV) or "")
    if not nonce or not sock:
        return {"verdict": "refuse", "provenance": None, "message": NO_TICKET}
    answer = redeem_ticket(sock, nonce, recipients, body)
    if not answer.get("ok"):
        return {"verdict": "refuse", "provenance": None,
                "message": "not sent — %s; send it through Moe's own send tool in a conversation."
                           % (answer.get("error") or "no ticket")}
    prov = answer.get("provenance") if isinstance(answer.get("provenance"), dict) else None
    owner = load_owner(env=env)
    resolved = [r for r in resolved if str(r or "").strip()]
    why = [owner_match(r, owner) for r in resolved]
    if resolved and all(why) and not (prov and prov.get("state") == "owner"):
        return {"verdict": "refuse", "provenance": None, "message": refusal_owner(resolved[0], why[0], reach_owner_registered(env=env))}
    return {"verdict": "ok", "message": "", "provenance": prov}


# ── the app, and only the app ────────────────────────────────────────────────
#
# Two things only the person may do, through the Memoe app: send an offer's
# draft they chose ("Use draft"), and say who a job may message ("keep?" on
# the Jobs card). The app starts the script itself; the script checks that its
# parent process IS the signed Memoe app. A model's shell is never the app's
# child. Residual risk, stated: a same-uid process could re-sign a binary with
# the app's identifier; that is a determined attack, out of scope.

APP_IDENTIFIERS = ("com.memoe.app", "com.memoe.app.dev", "com.moe.assistant", "com.moe.assistant.dev")


def _pid_path(pid):
    import ctypes
    import ctypes.util
    try:
        lib = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
    except OSError:
        return ""
    buf = ctypes.create_string_buffer(4096)
    n = lib.proc_pidpath(int(pid), buf, ctypes.c_uint32(4096))
    return buf.value.decode("utf-8", "replace") if n > 0 else ""


def _test_seam(env):
    """The two-key seam the suites use: MOE_HOOK_TEST=1 AND this file itself
    running from a temporary directory, which the installed copy never is."""
    here = os.path.realpath(__file__)
    return env.get("MOE_HOOK_TEST") == "1" and here.startswith(("/tmp/", "/private/tmp/",
                                                                   "/var/folders/", "/private/var/folders/"))


NOT_THE_APP = "that request did not come from the Memoe app, and only the app can send an offer's draft"
UNVERIFIED = "Moe could not verify the Memoe app's signature, so it sent nothing"


def why_not_the_app(pid, env=None):
    """"" when process `pid` is the Memoe app — its executable passes
    `codesign --verify --strict` and its signing identifier is the app's —
    else the reason, in words a person can read."""
    env = os.environ if env is None else env
    path = _pid_path(pid)
    if not path:
        return NOT_THE_APP
    if _test_seam(env) and env.get("MOE_TEST_APP_EXE") and \
            os.path.realpath(path) == os.path.realpath(env["MOE_TEST_APP_EXE"]):
        return ""
    import subprocess
    try:
        verified = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", path],
                                  capture_output=True, timeout=20).returncode == 0
        info = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=1", path],
                              capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return UNVERIFIED
    ident = ""
    for line in (info.stderr or "").splitlines():
        if line.startswith("Identifier="):
            ident = line.split("=", 1)[1].strip()
    if ident not in APP_IDENTIFIERS:
        return NOT_THE_APP
    return "" if verified else UNVERIFIED


def parent_is_the_app(pid, env=None):
    """True when process `pid` is the Memoe app (why_not_the_app says why not)."""
    return why_not_the_app(pid, env) == ""


OFFER_TTL = 10 * 60


def check_offer(text, parent_pid, env=None, now=None):
    """(to, body) for an offer the app handed over on stdin, or (None, why).
    Only from the app, only fresh: the app writes {"to", "body", "at"} — or,
    for WhatsApp, {"jid", …} — from its own memory at the moment the person
    pressed Use draft. `to` is the conversation's own id in that connector
    (a chat id, a thread id), never a name to look up."""
    import time as _time
    env = os.environ if env is None else env
    why = why_not_the_app(parent_pid, env)
    if why:
        return None, why
    try:
        rec = json.loads(text)
    except (TypeError, ValueError):
        return None, "the offer could not be read"
    if not isinstance(rec, dict):
        return None, "the offer could not be read"
    jid, body = str(rec.get("to") or rec.get("jid") or ""), str(rec.get("body") or "")
    try:
        age = (now if now is not None else _time.time()) - float(rec.get("at"))
    except (TypeError, ValueError):
        return None, "the offer carries no time"
    if not jid or not body or "\n" in jid or "\0" in jid + body:
        return None, "the offer is incomplete"
    if age < -60 or age > OFFER_TTL:
        return None, "that offer is more than ten minutes old — open it again to send it"
    return (jid, body), ""


def _cli(argv):
    if not argv:
        print(__doc__.strip().splitlines()[0])
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "owner":
        print(json.dumps(load_owner(), indent=1, ensure_ascii=False))
        return 0
    if cmd == "refresh-composio":
        refresh_composio()
        return 0
    if cmd == "write-owner":
        # --grounding-code <path>: the installed Hermes's recipient_grounding.py,
        # wherever that Hermes lives (the away machine's is not under HERMES_HOME).
        code = rest[rest.index("--grounding-code") + 1] if "--grounding-code" in rest[:-1] else None
        write_owner(grounding=os.path.isfile(code) if code else None)
        return 0
    if cmd == "is-owner":
        return 0 if rest and owner_match(rest[0], load_owner()) else 1
    if cmd == "take":
        # A connector's check: recipients as --to, the message on stdin.
        to, resolved = [], []
        i = 0
        while i < len(rest):
            flag, val = rest[i], (rest[i + 1] if i + 1 < len(rest) else "")
            if flag == "--to":
                to.extend(split_recipients(val))
            elif flag == "--resolved":
                resolved.extend(split_recipients(val))
            elif flag != "--channel":
                print("refuse\nthe recipient check was called wrongly (%s)\n" % flag)
                return 3
            i += 2
        v = connector_check(to, sys.stdin.read(), resolved)
        prov = json.dumps(v["provenance"], ensure_ascii=True) if v["provenance"] else ""
        sys.stdout.write("%s\n%s\n%s\n" % (v["verdict"], v["message"].replace("\n", " "), prov))
        return 3 if v["verdict"] == "refuse" else 0
    if cmd == "offer":
        # whatsapp.sh send-offer: the offer on stdin, and the connector's own
        # parent pid (the app, if it is the app) as --ppid.
        ppid = rest[rest.index("--ppid") + 1] if "--ppid" in rest[:-1] else "0"
        got, why = check_offer(sys.stdin.read(), int(ppid) if ppid.isdigit() else 0)
        if not got:
            sys.stdout.write("refuse\nnot sent — %s\n" % why)
            return 3
        sys.stdout.write("ok\n%s\n%s" % got)
        return 0
    if cmd == "gate":
        to, resolved, session = [], [], ""
        i = 0
        while i < len(rest):
            flag = rest[i]
            val = rest[i + 1] if i + 1 < len(rest) else ""
            if flag == "--to":
                to.extend(split_recipients(val))
            elif flag == "--resolved":
                resolved.extend(split_recipients(val))
            elif flag == "--session-id":
                session = val
            elif flag != "--channel":
                print("refuse\nthe recipient check was called wrongly (%s)\n" % flag)
                return 3
            i += 2
        v = gate(to, resolved, session)
        prov = json.dumps(v["provenance"], ensure_ascii=True) if v["provenance"] else ""
        sys.stdout.write("%s\n%s\n%s\n" % (v["verdict"], v["message"].replace("\n", " "), prov))
        return 3 if v["verdict"] == "refuse" else 0
    print("unknown command: %s" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
