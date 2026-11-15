"""What Moe's connectors really print, made by running them on synthetic data.

The send gate grounds a recipient from the fields of a lookup's output that
name who a message is from or to (tools/recipients.py `lookup_text`). A test
of that parser against text the test wrote itself agrees with itself and
proves nothing, so every fixture here is the connector's own formatter run
on made-up mail and messages:

  gmail_pull / gmail_crawl     gmail.py's cmd_pull / cmd_crawl over a fake IMAP server
  telegram_pull / _crawl       telegram.py's cmd_pull / cmd_crawl over a fake Telethon client
  whatsapp(verb, …)            whatsapp.sh itself, on a store with the bridge's schema
  imessage(verb, …)            imessage.sh itself, on a chat.db with Messages' tables
  calls(verb, …)               calls.sh itself, on a CallHistory store

Nothing here reaches a network, a keychain or the real stores.
"""

import contextlib
import email.utils
import importlib.util
import io
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import types
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
PAYLOAD = os.path.normpath(os.path.join(HERE, "..", ".."))
CONNECTORS = os.path.join(PAYLOAD, "connectors")


def _load(name):
    spec = importlib.util.spec_from_file_location("fixture_" + name, os.path.join(CONNECTORS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _capture(fn, *args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        fn(*args)
    return out.getvalue()


# ── Gmail ────────────────────────────────────────────────────────────────────

def _header_bytes(mail, crawl):
    lines = ["From: %s" % mail["from"], "Subject: %s" % mail.get("subject", "hello"),
             "Date: %s" % email.utils.format_datetime(datetime.now(timezone.utc) - timedelta(hours=1))]
    if crawl:
        lines.append("To: %s" % mail.get("to", "Owner <y@example.com>"))
        lines.append("Content-Type: text/plain; charset=utf-8")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("utf-8")


class _FakeImap:
    def __init__(self, mails, crawl):
        self.mails, self.crawl = mails, crawl

    def login(self, *a):
        return "OK", [b""]

    def select(self, folder, readonly=False):
        return "OK", [b"%d" % len(self.mails)]

    def search(self, *a):
        # Sent Mail is empty: every fixture message is in the inbox.
        return "OK", [b" ".join(b"%d" % (i + 1) for i in range(len(self.mails)))]

    def fetch(self, ids, what):
        out = []
        for i, mail in enumerate(self.mails):
            seq = i + 1
            hdr = _header_bytes(mail, self.crawl)
            if self.crawl:
                out.append((b"%d (BODY[HEADER.FIELDS (FROM TO SUBJECT DATE)] {%d}" % (seq, len(hdr)), hdr))
                body = mail.get("body", "").encode("utf-8")
                out.append((b" BODY[TEXT]<0> {%d}" % len(body), body))
                out.append(b")")
            else:
                out.append((b"%d (FLAGS () BODY[HEADER.FIELDS (FROM SUBJECT DATE)] {%d}" % (seq, len(hdr)), hdr))
                out.append(b")")
        return "OK", out

    def close(self):
        pass

    def logout(self):
        pass


class _SentMailIsEmpty(_FakeImap):
    def __init__(self, mails, crawl):
        super().__init__(mails, crawl)
        self.folder = "INBOX"

    def select(self, folder, readonly=False):
        self.folder = folder
        return super().select(folder, readonly)

    def search(self, *a):
        if self.folder != "INBOX":
            return "OK", [b""]
        return super().search(*a)


def _gmail(mails, crawl):
    gmail = _load("gmail")
    gmail.load_accounts = lambda: [{"label": "personal", "email": "y@example.com",
                                    "host": "imap.example.invalid"}]
    gmail.keychain_password = lambda _e: "app-password"
    fake = types.ModuleType("imaplib")
    fake.IMAP4_SSL = lambda *a, **k: _SentMailIsEmpty(mails, crawl)
    real = sys.modules.get("imaplib")
    sys.modules["imaplib"] = fake
    try:
        return _capture(gmail.cmd_crawl, []) if crawl else _capture(gmail.cmd_pull)
    finally:
        if real is not None:
            sys.modules["imaplib"] = real
        else:
            sys.modules.pop("imaplib", None)


def gmail_pull(mails):
    """mails: [{"from": "Dana Levi <dana@levi.com>", "subject": …}]"""
    return _gmail(mails, crawl=False)


def gmail_crawl(mails):
    """mails: [{"from": …, "to": …, "subject": …, "body": …}]"""
    return _gmail(mails, crawl=True)


# ── Telegram ─────────────────────────────────────────────────────────────────

class _Sender:
    def __init__(self, first_name):
        self.first_name = first_name


class _Msg:
    def __init__(self, sender_id, first_name, text, when):
        self.sender_id, self.sender, self.text, self.date = sender_id, _Sender(first_name), text, when


class _Dialog:
    def __init__(self, i, name, when):
        self.id, self.name, self.date = i, name, when


class _FakeTelegram:
    def __init__(self, chats):
        now = datetime.now(timezone.utc)
        self.dialogs, self.messages = [], {}
        for i, (name, msgs) in enumerate(chats):
            self.dialogs.append(_Dialog(i + 1, name, now))
            self.messages[i + 1] = [_Msg(1000 + j, who, text, now - timedelta(minutes=5 + j))
                                    for j, (who, text) in enumerate(msgs)]

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def get_me(self):
        return types.SimpleNamespace(id=1)

    def iter_dialogs(self, limit=None):
        return iter(self.dialogs[:limit] if limit else self.dialogs)

    def iter_messages(self, dialog_id, limit=None, offset_date=None, reverse=False):
        return iter(self.messages[dialog_id])


def _telegram(chats, crawl):
    tg = _load("telegram")
    tg.have_session = lambda: True
    tg.have_telethon = lambda: True
    tg.telegram_creds = lambda: ("1", "hash")
    tg.connected_client = lambda: _FakeTelegram(chats)
    sync = types.ModuleType("telethon.sync")
    sync.TelegramClient = object
    root = types.ModuleType("telethon")
    root.sync = sync
    saved = {k: sys.modules.get(k) for k in ("telethon", "telethon.sync")}
    sys.modules.update({"telethon": root, "telethon.sync": sync})
    os.environ.setdefault("TELEGRAM_API_ID", "1")
    os.environ.setdefault("TELEGRAM_API_HASH", "hash")
    try:
        return _capture(tg.cmd_crawl, []) if crawl else _capture(tg.cmd_pull)
    finally:
        for k, v in saved.items():
            if v is None:
                sys.modules.pop(k, None)
            else:
                sys.modules[k] = v


def telegram_pull(chats):
    """chats: [("Family", [("Avi", "text"), …]), …]"""
    return _telegram(chats, crawl=False)


def telegram_crawl(chats):
    return _telegram(chats, crawl=True)


# ── WhatsApp ─────────────────────────────────────────────────────────────────

WA_SCHEMA = """
CREATE TABLE chats (jid TEXT PRIMARY KEY, name TEXT, last_message_time TIMESTAMP);
CREATE TABLE messages (id TEXT, chat_jid TEXT, sender TEXT, content TEXT, timestamp TIMESTAMP,
  is_from_me BOOLEAN, media_type TEXT, filename TEXT, url TEXT, media_key BLOB, file_sha256 BLOB,
  file_enc_sha256 BLOB, file_length INTEGER, direct_path TEXT, mimetype TEXT,
  PRIMARY KEY (id, chat_jid));
"""


def _home_with_tools(tmp, contacts=None):
    home = os.path.join(tmp, "home")
    tools = os.path.join(home, ".moe", "tools")
    os.makedirs(tools)
    shutil.copy(os.path.join(PAYLOAD, "tools", "name-numbers.py"), tools)
    with open(os.path.join(home, ".moe", "contacts.json"), "w") as fh:
        import json
        json.dump(contacts or {}, fh)
    return home


def whatsapp(verb, chats, *args, contacts=None):
    """Run whatsapp.sh `verb` on a store holding `chats`:
    [{"jid": "…@g.us", "name": "Family", "messages": [(sender_jid, "text"), …]}]"""
    with tempfile.TemporaryDirectory() as tmp:
        db = os.path.join(tmp, "messages.db")
        con = sqlite3.connect(db)
        con.executescript(WA_SCHEMA)
        n = 0
        for c in chats:
            con.execute("insert into chats values (?, ?, datetime('now','-5 minutes'))",
                        (c["jid"], c.get("name", "")))
            for sender, text in c.get("messages", []):
                n += 1
                con.execute("insert into messages (id, chat_jid, sender, content, timestamp, is_from_me) "
                            "values (?, ?, ?, ?, datetime('now','-10 minutes'), 0)",
                            ("m%d" % n, c["jid"], sender, text))
        con.commit()
        con.close()
        home = _home_with_tools(tmp, contacts)
        env = {"PATH": "/usr/bin:/bin", "HOME": home, "MOE_WHATSAPP_DB": db,
               "MOE_ITEMS_BACKFILL_HOURS": "24",
               "HERMES_HOME": os.path.join(tmp, "hermes"), "MOE_HOME": os.path.join(home, ".moe")}
        r = subprocess.run(["bash", os.path.join(CONNECTORS, "whatsapp.sh"), verb, *args],
                           env=env, capture_output=True, text=True, timeout=30)
        return r.stdout


# ── iMessage ─────────────────────────────────────────────────────────────────

IM_SCHEMA = """
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, display_name TEXT);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, date INTEGER, is_from_me INTEGER,
  handle_id INTEGER, attributedBody BLOB);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
"""


def imessage(verb, chats, *args):
    """Run imessage.sh `verb` on a chat.db holding
    `chats`: [{"name": "Family" or "", "messages": [("+972…", "text"), …]}]"""
    with tempfile.TemporaryDirectory() as tmp:
        home = os.path.join(tmp, "home")
        msgs = os.path.join(home, "Library", "Messages")
        os.makedirs(msgs)
        con = sqlite3.connect(os.path.join(msgs, "chat.db"))
        con.executescript(IM_SCHEMA)
        # Apple's clock: nanoseconds since 2001-01-01.
        stamp = int((datetime.now(timezone.utc) - timedelta(minutes=10)).timestamp() - 978307200) * 10**9
        h = m = 0
        for ci, c in enumerate(chats, start=1):
            con.execute("insert into chat values (?, ?)", (ci, c.get("name", "")))
            for sender, text in c.get("messages", []):
                h += 1
                m += 1
                con.execute("insert into handle values (?, ?)", (h, sender))
                con.execute("insert into message values (?, ?, ?, 0, ?, NULL)", (m, text, stamp, h))
                con.execute("insert into chat_message_join values (?, ?)", (ci, m))
        con.commit()
        con.close()
        r = subprocess.run(["bash", os.path.join(CONNECTORS, "imessage.sh"), verb, *args],
                           env={"PATH": "/usr/bin:/bin", "HOME": home}, capture_output=True, text=True,
                           timeout=30)
        return r.stdout


# ── Calls ────────────────────────────────────────────────────────────────────

def calls(verb, rows, *args):
    """Run calls.sh `verb` on a CallHistory store holding
    `rows`: [("+972…", outgoing, answered, seconds), …]"""
    with tempfile.TemporaryDirectory() as tmp:
        home = os.path.join(tmp, "home")
        d = os.path.join(home, "Library", "Application Support", "CallHistoryDB")
        os.makedirs(d)
        con = sqlite3.connect(os.path.join(d, "CallHistory.storedata"))
        con.execute("CREATE TABLE ZCALLRECORD (Z_PK INTEGER PRIMARY KEY, ZDATE REAL, ZORIGINATED INTEGER, "
                    "ZANSWERED INTEGER, ZADDRESS TEXT, ZDURATION REAL)")
        stamp = (datetime.now(timezone.utc) - timedelta(minutes=10)).timestamp() - 978307200
        for addr, out, answered, secs in rows:
            con.execute("insert into ZCALLRECORD (ZDATE, ZORIGINATED, ZANSWERED, ZADDRESS, ZDURATION) "
                        "values (?, ?, ?, ?, ?)", (stamp, int(out), int(answered), addr, secs))
        con.commit()
        con.close()
        r = subprocess.run(["bash", os.path.join(CONNECTORS, "calls.sh"), verb, *args],
                           env={"PATH": "/usr/bin:/bin", "HOME": home}, capture_output=True, text=True,
                           timeout=30)
        return r.stdout
