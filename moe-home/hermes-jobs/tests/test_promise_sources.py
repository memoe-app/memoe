"""The sources promises come from beyond chats and mail: Apple Notes and
recorded calls (connectors/notes-items.py), and Moe's own records — its
meetings and the person's chats with it (lib/moe_items.py).

Run: python3 moe-home/hermes-jobs/tests/test_promise_sources.py
"""

import importlib.util
import json
import os
import shutil
import sqlite3
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MOE_SRC = os.path.normpath(os.path.join(HERE, "..", ".."))
NOW = 1790700000.0


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class NotesTest(unittest.TestCase):
    def setUp(self):
        self.n = load(os.path.join(MOE_SRC, "connectors", "notes-items.py"), "notes_items")
        self.rows = [
            ("n1", NOW - 3000, "Notes", "Todo", "call Dan about the invoice by Thursday"),
            ("n2", NOW - 2000, "Call Recordings", "Call with Dana", "Dana: I'll send it Monday"),
            ("n3", NOW - 1000, "Recently Deleted", "old", "gone"),
            ("n4", NOW - 900000, "Notes", "ancient", "before the cursor"),
            ("n5", NOW - 500, "Notes", "empty", "   "),
        ]
        os.environ.pop("MOE_ITEMS_BACKFILL_HOURS", None)

    def reader(self, back):
        self.asked_back = back
        return self.rows

    def test_first_look_is_only_a_cursor(self):
        items, cursor = self.n.items("notes", "", now=NOW, reader=self.reader, running=lambda: True)
        self.assertEqual((items, cursor), ([], str(int(NOW))))

    def test_notes_and_calls_are_two_sources(self):
        since = str(int(NOW - 4000))
        notes, c1 = self.n.items("notes", since, now=NOW, reader=self.reader, running=lambda: True)
        calls, c2 = self.n.items("calls", since, now=NOW, reader=self.reader, running=lambda: True)
        self.assertEqual([i["thread"] for i in notes], ["n1"])
        self.assertEqual([i["thread"] for i in calls], ["n2"])
        self.assertEqual((notes[0]["kind"], calls[0]["kind"]), ("note", "call"))
        self.assertTrue(notes[0]["from"]["me"] and notes[0]["to_me"])
        self.assertEqual(notes[0]["id"], "n1@%d" % int(NOW - 3000), "an edit is a new item")
        self.assertEqual(c1, str(int(NOW - 500)), "past the empty note too: read, nothing in it")
        self.assertGreaterEqual(self.asked_back, 4000)

    def test_notes_are_read_a_limited_number_at_a_time(self):
        self.rows = [("n%d" % i, NOW - 3000 + i, "Notes", "t", "call Dan by Friday") for i in range(self.n.LIMIT + 7)]
        items, cursor = self.n.items("notes", str(int(NOW - 4000)), now=NOW, reader=self.reader, running=lambda: True)
        self.assertEqual(len(items), self.n.LIMIT)
        self.assertEqual(cursor, str(int(NOW - 3000 + self.n.LIMIT - 1)))

    def test_while_notes_is_shut_nothing_moves(self):
        since = str(int(NOW - 4000))
        self.assertEqual(self.n.items("notes", since, now=NOW, reader=self.reader, running=lambda: False),
                         ([], since))

    def test_the_applescript_is_read_only(self):
        for word in ("make new", "delete", "set body", "set name", "move "):
            self.assertNotIn(word, self.n.SCRIPT)


class MeetingsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-src-")
        os.environ["MOE_HOME"] = self.tmp
        os.environ.pop("MOE_ITEMS_BACKFILL_HOURS", None)
        self.m = load(os.path.join(MOE_SRC, "lib", "moe_items.py"), "moe_items")

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def meeting(self, folder, rec, mtime):
        d = os.path.join(self.tmp, "meetings", folder)
        os.makedirs(d)
        p = os.path.join(d, "meeting.json")
        with open(p, "w") as f:
            json.dump(rec, f)
        os.utime(p, (mtime, mtime))

    def test_a_summarised_meeting_is_one_item_with_its_action_items(self):
        notes = {"title": "Pricing", "summary": "We agreed the new tiers.",
                 "decisions": ["Launch Oct 1"], "todos": ["Update site"], "open_questions": [],
                 "action_items": [{"who": "Dana", "what": "send the draft contract", "when": "Friday"},
                                  {"who": "", "what": "book the venue", "when": ""}]}
        self.meeting("2026-09-28-1038", {"summarised": True, "notes": notes}, NOW - 100)
        self.meeting("2026-09-28-1200", {"summarised": False, "notes": notes}, NOW - 50)
        self.meeting("2026-09-28-1300", {"summarised": True, "incomplete": True, "notes": notes}, NOW - 40)
        items, cursor = self.m.meetings(str(NOW - 1000), now=NOW)
        self.assertEqual(len(items), 1)
        it = items[0]
        self.assertEqual((it["kind"], it["thread"], it["thread_name"]),
                         ("meeting", "meeting:2026-09-28-1038", "Meeting: Pricing"))
        self.assertIn("Action item: Dana will send the draft contract (by Friday)", it["text"])
        self.assertIn("Action item: book the venue", it["text"])
        self.assertEqual(float(cursor), NOW - 100)
        self.assertEqual(self.m.meetings(cursor, now=NOW)[0], [], "read once")
        self.assertEqual(it["id"], "2026-09-28-1038", "one item per meeting, however often it is rewritten")

    def test_a_rewritten_old_meeting_is_dated_when_it_happened(self):
        notes = {"title": "Old", "summary": "x", "action_items": []}
        self.meeting("2026-08-01-0900", {"summarised": True, "startedAt": "2026-08-01T06:00:00Z",
                                         "notes": notes}, NOW - 10)
        items, _ = self.m.meetings(str(NOW - 1000), now=NOW)
        self.assertEqual(items[0]["at"], 1785564000.0)

    def test_meetings_are_read_a_limited_number_at_a_time(self):
        notes = {"title": "M", "summary": "x", "action_items": []}
        for i in range(self.m.LIMIT + 5):
            self.meeting("m%03d" % i, {"summarised": True, "notes": notes}, NOW - 1000 + i)
        items, cursor = self.m.meetings(str(NOW - 2000), now=NOW)
        self.assertEqual(len(items), self.m.LIMIT)
        self.assertEqual(float(cursor), NOW - 1000 + self.m.LIMIT - 1)
        self.assertEqual(self.m.meetings("", now=NOW), ([], str(int(NOW))))


class ChatsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-chats-")
        os.environ.pop("MOE_ITEMS_BACKFILL_HOURS", None)
        self.m = load(os.path.join(MOE_SRC, "lib", "moe_items.py"), "moe_items_chats")
        self.db = os.path.join(self.tmp, "state.db")
        con = sqlite3.connect(self.db)
        con.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL)")
        con.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT,"
                    " content TEXT, timestamp REAL)")
        con.executemany("INSERT INTO sessions VALUES (?, ?)", [("s1", "api_server"), ("c1", "cron")])
        rows = [("s1", "user", "I told Dan I'd send him the deck by Friday", NOW - 50),
                ("s1", "assistant", "I'll remind you", NOW - 49),
                ("s1", "user", "what's the weather", NOW - 40),
                ("c1", "user", "I'll send the digest", NOW - 30),
                ("s1", "user", "Meeting on Tuesday\n<transcript>I'll send it", NOW - 20),
                ("s1", "user", "# What is going on right now\n\nbrief I'll send x\n---\n\nsure\n# Before you answer\nrules",
                 NOW - 10),
                ("s1", "user", "Send the reply between the ======== lines below for me: Hi Dan, I'll transfer it by Thursday", NOW - 7),
                ("s1", "user", "Sarah promised to pay me back by Monday", NOW - 5)]
        con.executemany("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)", rows)
        con.commit()
        con.close()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_only_the_persons_words_about_a_commitment(self):
        items, cursor = self.m.chats("0", now=NOW, db=self.db, persons_text=lambda t: t.strip())
        self.assertEqual([i["text"] for i in items], ["I told Dan I'd send him the deck by Friday",
                                                      "Sarah promised to pay me back by Monday"])
        self.assertEqual(cursor, "8")
        self.assertTrue(all(i["kind"] == "moe-chat" and i["from"]["me"] for i in items))
        self.assertEqual(self.m.chats("", now=NOW, db=self.db, persons_text=lambda t: t)[1], "8")
        self.assertEqual(self.m.chats("junk", now=NOW, db=self.db, persons_text=lambda t: t), ([], "8"))

    def test_an_unfamiliar_layout_fails_closed(self):
        con = sqlite3.connect(self.db)
        con.execute("ALTER TABLE messages RENAME COLUMN role TO speaker")
        con.commit()
        con.close()
        with self.assertRaises(RuntimeError):
            self.m.chats("0", now=NOW, db=self.db, persons_text=lambda t: t)

    def test_the_real_sweep_reader_loads(self):
        # THIS checkout's sweep.py. `_persons_text` looks beside Hermes first
        # ($HERMES_HOME/plugins/moe-screen) and in the repo second, and with
        # HERMES_HOME unset that is the plugin installed on the developer's
        # Mac — here one from 2026-09-23 with no `persons_text` at all. It
        # used to pass only when an earlier test in the run had failed and
        # left HERMES_HOME pointing at a temp directory behind it.
        previous = os.environ.get("HERMES_HOME")
        os.environ["HERMES_HOME"] = self.tmp
        self.addCleanup(lambda: os.environ.pop("HERMES_HOME", None) if previous is None
                        else os.environ.__setitem__("HERMES_HOME", previous))
        fn = self.m._persons_text()
        self.assertEqual(fn("Now: Tuesday\n\nI'll send it"), "I'll send it")


class EngineTest(unittest.TestCase):
    def test_moe_records_need_no_grant_and_are_never_forgotten(self):
        tmp = tempfile.mkdtemp(prefix="moe-src-engine-")
        os.environ["MOE_HOME"] = tmp
        try:
            s = load(os.path.join(MOE_SRC, "lib", "situations.py"), "situations_sources")
            self.assertTrue(s.consented("moe/meetings") and s.granted("moe/chats"))
            self.assertFalse(s.consented("moe/anything-else"))
            self.assertFalse(s.consented("native/notes"), "a connection still needs its grant")
        finally:
            os.environ.pop("MOE_HOME", None)
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
