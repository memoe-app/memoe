"""Promises (moe-home/lib/promises.py) inside the situations engine: found by
the one sensor call, quote-checked, watched to their moment, closed silently
when kept, raised as a situation when not — and merged between the Mac and
the machine like the situations are.

The merge between the Mac and the machine is tested with the ledger
(moe-ledger/tests/test_situations_documents.py).

Run: python3 moe-home/hermes-jobs/tests/test_promises.py
"""

import importlib.util
import json
import os
import shutil
import sys
import tempfile
import textwrap
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
MOE_SRC = os.path.normpath(os.path.join(HERE, "..", ".."))
LIB = os.path.join(MOE_SRC, "lib", "situations.py")

ZONE = ZoneInfo("Asia/Jerusalem")


def at(stamp):
    """A local time in the person's zone, as unix seconds."""
    return datetime.strptime(stamp, "%Y-%m-%d %H:%M").replace(tzinfo=ZONE).timestamp()


NOW = at("2026-09-29 10:00")


def load():
    spec = importlib.util.spec_from_file_location("situations_for_promises", LIB)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def item(i, text, *, me=False, thread="dan", at_=None, name="Dan Cohen", kind="msg", to_me=True):
    return {"id": "i%d" % i, "thread": thread, "thread_name": name, "at": at_ or NOW - 600 + i,
            "from": {"id": "me" if me else "dan", "name": "" if me else name, "me": me},
            "to_me": to_me, "group": False, "kind": kind, "text": text, "source": "fakechat"}


PROMISE_ANSWER = {"situation": None, "promises": [
    {"by": "me", "who": "Dan", "what": "send the pitch deck", "due": "2026-10-01",
     "help": ["draft"], "p_wanted": 0.8,
     "evidence": {"id": "m2", "quote": "I'll send you the deck by Thursday"}}]}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-promises-")
        os.environ["MOE_HOME"] = self.tmp
        with open(os.path.join(self.tmp, "tz.json"), "w") as f:
            json.dump({"iana": "Asia/Jerusalem"}, f)
        self.s = load()
        self.P = self.s.promises_mod()
        self.asked = []
        self.adapter = os.path.join(self.tmp, "fake-items.py")
        with open(self.adapter, "w") as f:
            f.write(textwrap.dedent("""\
                #!/usr/bin/env python3
                import json, os, sys
                state = os.path.join(os.path.dirname(__file__), "fake-state.json")
                st = json.load(open(state))
                since = sys.argv[sys.argv.index("--since") + 1]
                batch = st["batches"].pop(0) if st["batches"] else []
                json.dump(st, open(state, "w"))
                for it in batch:
                    print(json.dumps(it))
                print(json.dumps({"cursor": str(int(since or 0) + len(batch))}))
                """))
        os.chmod(self.adapter, 0o755)
        self.set_batches([])

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def set_batches(self, batches):
        with open(os.path.join(self.tmp, "fake-state.json"), "w") as f:
            json.dump({"batches": batches}, f)

    def answering(self, *payloads):
        queue = list(payloads)

        def call(messages):
            self.asked.append(messages)
            p = queue.pop(0) if len(queue) > 1 else queue[0]
            return p if isinstance(p, str) else json.dumps(p)
        return call

    def tick(self, call, now=NOW, **kw):
        return self.s.tick(call=call, sources=[("fakechat", self.adapter)],
                           consent=lambda name: True, now=now, **kw)

    def promises(self):
        return self.P.load()

    def monitor(self):
        try:
            with open(self.s.monitor_path()) as f:
                return [json.loads(line) for line in f]
        except OSError:
            return []


CHAT = [item(1, "Can you send me the deck before our meeting?"),
        item(2, "Sure, I'll send you the deck by Thursday", me=True)]


class ParseTest(Base):
    def test_a_promise_must_quote_the_right_side(self):
        got = self.P.parse(json.dumps(PROMISE_ANSWER), CHAT, [])
        self.assertEqual(len(got["new"]), 1)
        p = got["new"][0]
        self.assertEqual((p["by"], p["what"], p["due"], p["item"]), ("owner", "send the pitch deck",
                                                                     "2026-10-01", "i2"))
        # Pinned on the wrong side of the conversation: a misread, dropped.
        wrong = json.loads(json.dumps(PROMISE_ANSWER))
        wrong["promises"][0]["by"] = "them"
        self.assertEqual(self.P.parse(json.dumps(wrong), CHAT, [])["new"], [])
        # A quote that is not in the message: dropped.
        made_up = json.loads(json.dumps(PROMISE_ANSWER))
        made_up["promises"][0]["evidence"]["quote"] = "I will wire the money tonight"
        self.assertEqual(self.P.parse(json.dumps(made_up), CHAT, [])["new"], [])

    def test_a_note_or_a_meeting_is_the_owner_writing_about_both_sides(self):
        note = [item(1, "Dan will send the signed contract by Friday", me=True, kind="note")]
        ans = {"promises": [{"by": "them", "who": "Dan", "what": "send the signed contract",
                             "due": "2026-10-02", "evidence": {"id": "m1", "quote": "Dan will send the signed contract"}}]}
        self.assertEqual(len(self.P.parse(json.dumps(ans), note, [])["new"]), 1)

    def test_a_date_out_of_range_is_no_date(self):
        made = at("2026-09-29 09:00")
        self.assertEqual(self.P.parse_due("2026-10-01", made), "2026-10-01")
        self.assertEqual(self.P.parse_due("2026-10-01T15:30", made), "2026-10-01T15:30")
        self.assertEqual(self.P.parse_due("2025-01-01", made), "")
        self.assertEqual(self.P.parse_due("2031-01-01", made), "")
        self.assertEqual(self.P.parse_due("Thursday", made), "")
        self.assertEqual(self.P.parse_due("2026-02-30", made), "")

    def test_nonsense_is_nothing_and_never_raises(self):
        for junk in ("", "no", "{", '{"promises": 5}', '{"promises": [5, null, {"by": "me"}]}',
                     '{"kept": [{"promise": "p9"}]}', None):
            self.assertEqual(self.P.parse(junk, CHAT, []), {"new": [], "kept": [], "released": []})

    def test_only_what_came_after_can_keep_a_promise(self):
        open_ps = [{"id": "prm_x", "by": "owner", "what": "send the deck", "made_at": self.s._iso(NOW - 300)}]
        thread = [item(1, "Here is the deck, as promised", me=True, at_=NOW - 400),
                  item(2, "Here you go, the deck is attached", me=True, at_=NOW - 100)]
        early = {"kept": [{"promise": "p1", "id": "m1", "quote": "Here is the deck, as promised"}]}
        self.assertEqual(self.P.parse(json.dumps(early), thread, open_ps)["kept"], [])
        late = {"kept": [{"promise": "p1", "id": "m2", "quote": "the deck is attached"}]}
        self.assertEqual(self.P.parse(json.dumps(late), thread, open_ps)["kept"][0]["id"], "prm_x")


class GateTest(Base):
    def test_the_owners_own_commitment_is_read(self):
        mine = [item(1, "I'll send you the deck by Thursday", me=True)]
        self.assertEqual(self.s.gate(mine, mine, False, now=NOW), (True, ["the owner committed"]))
        chatter = [item(1, "haha nice", me=True)]
        self.assertFalse(self.s.gate(chatter, chatter, False, now=NOW)[0])
        hebrew = [item(1, "אשלח לך את המצגת עד יום חמישי", me=True)]
        self.assertTrue(self.s.gate(hebrew, hebrew, False, now=NOW)[0])

    def test_a_thread_with_an_open_promise_is_always_read(self):
        sent = [item(1, "sent!", me=True)]
        self.assertFalse(self.s.gate(sent, sent, False, now=NOW)[0])
        self.assertEqual(self.s.gate(sent, sent, False, now=NOW, watched=True), (True, ["promise open here"]))
        # Still talking still waits.
        live = [item(1, "sent!", me=True, at_=NOW - 10)]
        self.assertEqual(self.s.gate(live, live, False, now=NOW, watched=True), (False, ["still talking"]))


class TickTest(Base):
    def test_found_by_the_one_sensor_call_and_recorded_once(self):
        self.set_batches([[], CHAT, []])
        self.tick(self.answering({"situation": None}))            # first look: the cursor only
        self.tick(self.answering(PROMISE_ANSWER))
        self.assertEqual(len(self.asked), 1, "one call per thread, never a second for promises")
        self.assertIn("Separately, promises", self.asked[0][0]["content"])
        ps = self.promises()
        self.assertEqual(len(ps), 1)
        p = list(ps.values())[0]
        self.assertEqual((p["status"], p["by"], p["due"], p["source"], p["thread"]),
                         ("open", "owner", "2026-10-01", "fakechat", "dan"))
        # The same promise read again, worded a little differently: one record.
        again = json.loads(json.dumps(PROMISE_ANSWER))
        again["promises"][0]["what"] = "send the deck"
        self.set_batches([[item(3, "Great, thanks! Looking forward to it, see you Thursday")]])
        self.tick(self.answering(again), now=NOW + 200)
        self.assertEqual(len(self.promises()), 1)
        # …and the open promise was shown to the sensor by a short id.
        self.assertIn("[p1] me → them: send the pitch deck (due 2026-10-01)", self.asked[-1][1]["content"])

    def test_kept_in_the_thread_closes_it_silently(self):
        self.set_batches([[], CHAT, [item(5, "Here it is, deck attached", me=True, at_=NOW + 100)]])
        self.tick(self.answering({"situation": None}))
        self.tick(self.answering(PROMISE_ANSWER))
        kept = {"situation": None, "kept": [{"promise": "p1", "id": "m3", "quote": "deck attached"}]}
        self.tick(self.answering(kept), now=NOW + 400)
        p = list(self.promises().values())[0]
        self.assertEqual(p["status"], "kept")
        self.assertEqual(p["closed"]["evidence"]["id"], "i5")
        # Past its moment nothing is raised for it.
        self.tick(self.answering({"situation": None}), now=at("2026-10-01 10:00"))
        self.assertFalse([s for s in self.s.load_situations().values() if s.get("promise")])


class TimingTest(Base):
    def rec(self, due, made="2026-09-29 09:00", **kw):
        return dict({"by": "owner", "who": "Dan", "what": "send the deck", "due": due,
                     "made_at": self.s._iso(at(made)), "status": "open", "stage": ""}, **kw)

    def test_a_date_comes_up_that_morning_and_the_morning_after(self):
        p = self.rec("2026-10-01")
        self.assertEqual(self.P.stage_now(p, at("2026-10-01 08:59")), "")
        self.assertEqual(self.P.stage_now(p, at("2026-10-01 09:00")), "due")
        self.assertEqual(self.P.stage_now(p, at("2026-10-01 23:00")), "due")
        self.assertEqual(self.P.stage_now(p, at("2026-10-02 09:00")), "broken")

    def test_promised_for_today_waits_two_hours(self):
        p = self.rec("2026-09-29", made="2026-09-29 14:00")
        self.assertEqual(self.P.stage_now(p, at("2026-09-29 15:59")), "")
        self.assertEqual(self.P.stage_now(p, at("2026-09-29 16:00")), "due")

    def test_a_time_comes_up_two_hours_before_and_an_hour_after(self):
        p = self.rec("2026-10-01T15:00")
        self.assertEqual(self.P.stage_now(p, at("2026-10-01 12:59")), "")
        self.assertEqual(self.P.stage_now(p, at("2026-10-01 13:00")), "due")
        self.assertEqual(self.P.stage_now(p, at("2026-10-01 16:00")), "broken")

    def test_no_date_once_after_a_week(self):
        p = self.rec("")
        self.assertEqual(self.P.stage_now(p, at("2026-10-06 08:59")), "")
        self.assertEqual(self.P.stage_now(p, at("2026-10-06 09:00")), "quiet")


class WatchTest(Base):
    def put(self, **kw):
        rec = dict({"by": "owner", "who": "Dan", "what": "send the deck", "due": "2026-10-01",
                    "made_at": self.s._iso(NOW), "status": "open", "stage": "", "source": "fakechat",
                    "thread": "dan", "thread_name": "Dan Cohen", "help": ["draft"], "p_wanted": 0.5,
                    "evidence": [{"id": "i2", "quote": "I'll send you the deck"}],
                    "updated_at": self.s._iso(NOW)}, **kw)
        self.s._write_json(self.P.promises_path(), {"prm_a": rec})
        return rec

    def feed(self, items):
        self.s.append_feed("fakechat", items)

    def test_nothing_to_check_is_raised_without_a_call(self):
        self.put()
        self.P.bind(self.s)
        self.P.watch(self.answering({"kept": False}), now=at("2026-10-01 09:30"))
        self.assertEqual(self.asked, [])
        sits = [s for s in self.s.load_situations().values() if s.get("promise") == "prm_a"]
        self.assertEqual(len(sits), 1)
        s = sits[0]
        self.assertEqual((s["stage"], s["next_move"], s["kind"], s["thread"]), ("due", "owner", "promise mine", "dan"))
        self.assertGreaterEqual(s["p_wanted"], 0.75)
        self.assertEqual(self.promises()["prm_a"]["stage"], "due")
        # The same moment is not raised twice.
        self.P.watch(self.answering({"kept": False}), now=at("2026-10-01 10:30"))
        self.assertEqual(len([e for e in self.monitor() if e["event"] == "promise-raised"]), 1)

    def test_kept_elsewhere_closes_it_before_any_card(self):
        # Across sources the counterpart is their full name: a WhatsApp id is
        # not an address, and "Dan" alone is every Dan (re-review #7).
        self.put(who="Dan Cohen")
        # The deck went by mail, in another source, in a thread Dan wrote in
        # (a mail's own name is its subject, which never counts).
        ask = dict(item(8, "Could you mail me the deck?", thread="mail-1", name="Dan Cohen",
                        kind="mail", at_=NOW + 1800), source="fakemail")
        ask["thread_name"] = "Re: Thursday"
        ask["from"]["id"] = "dan@acme.io"
        mail = dict(item(9, "Hi Dan, attached is the deck.", me=True, thread="mail-1",
                         name="Re: Thursday", kind="mail", at_=NOW + 3600), source="fakemail")
        self.s.append_feed("fakemail", [ask, mail])
        self.P.watch(self.answering({"kept": True, "evidence": {"id": "m2", "quote": "attached is the deck"}}),
                     now=at("2026-10-01 09:30"))
        self.assertEqual(len(self.asked), 1)
        self.assertIn("attached is the deck", self.asked[0][1]["content"])
        self.assertEqual(self.promises()["prm_a"]["status"], "kept")
        self.assertFalse([s for s in self.s.load_situations().values() if s.get("promise")])

    def test_a_model_saying_kept_without_a_quote_changes_nothing(self):
        self.put()
        self.feed([item(9, "Thanks for yesterday", at_=NOW + 3600)])
        self.P.watch(self.answering({"kept": True, "evidence": None}), now=at("2026-10-01 09:30"))
        self.assertEqual(self.promises()["prm_a"]["status"], "open")
        self.assertTrue([s for s in self.s.load_situations().values() if s.get("promise")])

    def test_unrelated_conversations_are_not_checked(self):
        self.put()
        self.feed([item(9, "deck attached", thread="other", name="Sarah Levi", at_=NOW + 3600)])
        self.P.watch(self.answering({"kept": True}), now=at("2026-10-01 09:30"))
        self.assertEqual(self.asked, [])

    def test_broken_then_lapses_quietly(self):
        self.put()
        self.P.watch(self.answering({"kept": False}), now=at("2026-10-02 09:30"))
        sid = self.P.situation_for("prm_a")
        self.assertEqual(self.s.load_situations()[sid]["stage"], "broken")
        self.P.watch(self.answering({"kept": False}), now=at("2026-10-17 09:30"))
        self.assertEqual(self.promises()["prm_a"]["status"], "lapsed")
        self.assertEqual(self.s.load_situations()[sid]["status"], "resolved")

    def test_a_new_stage_is_a_new_version_to_prepare_and_offer(self):
        self.put()
        self.P.watch(self.answering({}), now=at("2026-10-01 09:30"))
        sid = self.P.situation_for("prm_a")
        due = self.s.load_situations()[sid]
        self.s.set_prepared(sid, {"offer": "x", "for": due["material"]}, at("2026-10-01 09:30"))
        self.s.set_offered(sid, due["material"], at("2026-10-01 09:31"))
        self.P.watch(self.answering({}), now=at("2026-10-02 09:30"))
        broken = self.s.load_situations()[sid]
        self.assertNotEqual(broken["material"], due["material"])
        self.assertNotIn("prepared", broken)
        self.assertEqual(broken["status"], "sensed")

    def test_dismissed_stays_dismissed(self):
        self.put()
        self.P.watch(self.answering({}), now=at("2026-10-01 09:30"))
        sid = self.P.situation_for("prm_a")
        data = self.s.load_situations()
        data[sid]["status"] = "dismissed"
        self.s._write_json(self.s.situations_path(), data)
        self.P.watch(self.answering({}), now=at("2026-10-02 09:30"))
        self.assertEqual(self.s.load_situations()[sid]["status"], "dismissed")


class OfferTest(Base):
    def test_nothing_to_prepare_is_offered_as_the_promise_itself(self):
        WatchTest.put(self, help=["remind"], who="Dan", what="send the deck")
        offered = []
        self.tick(self.answering({}), now=at("2026-10-01 09:30"),
                  offerer=lambda sit: offered.append(sit) or True)
        self.assertEqual(len(offered), 1)
        self.assertEqual(offered[0]["prepared"]["offer"], "Due Oct 1: you told Dan you'd send the deck.")
        texts = self.s.offer_texts(offered[0])
        self.assertIn("you told Dan", texts["line"])
        # The broken moment is offered again, once.
        self.tick(self.answering({}), now=at("2026-10-02 09:30"), offerer=lambda sit: offered.append(sit) or True)
        self.tick(self.answering({}), now=at("2026-10-02 10:30"), offerer=lambda sit: offered.append(sit) or True)
        self.assertEqual(len(offered), 2)
        self.assertIn("no sign it happened", offered[1]["prepared"]["offer"])

    def test_theirs_broken(self):
        WatchTest.put(self, by="other", help=[], what="send the signed contract")
        offered = []
        self.tick(self.answering({}), now=at("2026-10-02 09:30"),
                  offerer=lambda sit: offered.append(sit) or True)
        self.assertEqual(offered[0]["prepared"]["offer"],
                         "Dan said they'd send the signed contract by Oct 1, and nothing has come.")
        self.assertEqual(offered[0]["kind"], "promise theirs")


class ReviewFixesTest(Base):
    """Review 2026-09-29, one test per finding, each checked against the
    code that had the defect."""

    def put(self, **kw):
        return WatchTest.put(self, **kw)

    def test_1_a_closed_promise_is_never_raised_from_a_stale_copy(self):
        self.put()
        data = self.P.load()
        stale = dict(data["prm_a"])
        data["prm_a"].update({"status": "kept", "updated_at": self.s._iso(NOW + 10)})
        self.s._write_json(self.P.promises_path(), data)
        self.P.watch(self.answering({}), now=at("2026-10-01 09:30"))
        self.assertFalse([x for x in self.s.load_situations().values() if x.get("promise")])
        self.assertEqual(self.P.load()["prm_a"]["status"], "kept")
        self.assertFalse(self.P._set_stage("prm_a", "due", NOW, False))
        del stale

    def test_2_talk_is_not_a_commitment(self):
        for t in ("let me know when you land", "ok I'll see", "we'll see", "I'll take a look sometime"):
            mine = [item(1, t, me=True)]
            self.assertFalse(self.s.gate(mine, mine, False, now=NOW)[0], t)
        for t in ("I'll send you the deck", "I can pay you back tomorrow", "we'll transfer the money"):
            mine = [item(1, t, me=True), item(0, "hi", at_=NOW - 3000)]
            self.assertTrue(self.s.gate(mine, mine[:1], False, now=NOW)[0], t)

    def test_3_a_far_promise_outlives_the_open_cut(self):
        self.put(due="2027-02-20")
        data = self.P.load()
        later = at("2027-02-01 10:00")
        self.assertIn("prm_a", self.P.prune(data, later))
        self.assertNotIn("prm_a", self.P.prune(data, at("2027-07-01 10:00")))

    def test_4_two_promises_in_one_message_are_two(self):
        thread = [item(1, "I'll send the contract and the invoice by Friday", me=True)]
        ans = {"promises": [
            {"by": "me", "who": "Dan", "what": "send the contract", "due": "2026-10-02",
             "evidence": {"id": "m1", "quote": "I'll send the contract"}},
            {"by": "me", "who": "Dan", "what": "send the invoice", "due": "2026-10-02",
             "evidence": {"id": "m1", "quote": "the invoice by Friday"}}]}
        got = self.P.record("fakechat", "dan", "Dan", self.P.parse(json.dumps(ans), thread, []), NOW)
        self.assertEqual(got["new"], 2)
        self.assertTrue(self.P._similar("send the pitch deck", "send over the deck"))
        self.assertFalse(self.P._similar("pay the rent", "pay the plumber"))

    def test_5_today_is_the_persons_and_yesterday_is_a_misread(self):
        late = at("2026-09-30 01:30")          # 22:30 UTC the day before
        self.set_batches([[], [item(1, "I'll send you the deck today", me=True, at_=late - 200)]])
        self.tick(self.answering({"situation": None}), now=late - 300)
        self.tick(self.answering({"situation": None}), now=late)
        head = self.asked[-1][1]["content"]
        self.assertIn("Today is 2026-09-30", head)
        self.assertIn("2026-09-30 01:26", head)
        self.assertEqual(self.P.parse_due("2026-09-29", late), "")
        self.assertEqual(self.P.parse_due("2026-09-30", late), "2026-09-30")

    def test_6_the_promise_itself_never_proves_it_kept(self):
        thread = [item(1, "I'll send you the contract tomorrow", me=True, at_=NOW - 100)]
        open_ps = [{"id": "prm_x", "by": "owner", "what": "send the contract",
                    "made_at": self.s._iso(NOW - 100), "item": "i1"}]
        ans = {"kept": [{"promise": "p1", "id": "m1", "quote": "send you the contract tomorrow"}]}
        self.assertEqual(self.P.parse(json.dumps(ans), thread, open_ps)["kept"], [])

    def test_8_made_late_on_the_day_no_midnight_card(self):
        p = {"due": "2026-09-29", "made_at": self.s._iso(at("2026-09-29 22:30"))}
        self.assertEqual([m for m, _ in self.P.moments(p)], ["broken"])
        p = {"due": "2026-09-29", "made_at": self.s._iso(at("2026-09-29 12:00"))}
        self.assertEqual(self.P.moments(p)[0], ("due", at("2026-09-29 14:00")))
        p = {"due": "2026-09-29", "made_at": self.s._iso(at("2026-09-29 18:30"))}
        self.assertEqual([m for m, _ in self.P.moments(p)], ["broken"], "20:30 is past the evening")

    def test_9_a_subject_or_a_stranger_is_not_the_counterpart(self):
        self.put(who="Dan", who_ids=["dan"])
        other = dict(item(9, "deck attached", thread="m-2", name="Sarah", kind="mail", at_=NOW + 3600),
                     source="fakemail")
        other["thread_name"] = "Invoice for Dan"
        other["from"]["id"] = "sarah@x.io"
        self.s.append_feed("fakemail", [other])
        self.assertEqual(self.P.related_items(self.P.load()["prm_a"]), [])

    def test_10_a_watched_thread_ignores_machines_and_group_chatter(self):
        otp = [item(1, "Your verification code is 552211")]
        self.assertFalse(self.s.gate(otp, otp, False, now=NOW, watched=True)[0])
        chatter = [dict(item(1, "haha that was a great party last night", to_me=False), group=True)]
        self.assertFalse(self.s.gate(chatter, chatter, False, now=NOW, watched=True)[0])
        mine = [item(1, "sent!", me=True)]
        self.assertTrue(self.s.gate(mine, mine, False, now=NOW, watched=True)[0])

    def test_11_the_machine_never_raises(self):
        self.put()
        os.environ["MOE_RUNS_IN"] = "cloud"
        try:
            self.P.watch(self.answering({}), now=at("2026-10-01 09:30"))
        finally:
            os.environ.pop("MOE_RUNS_IN", None)
        self.assertFalse(self.s.load_situations())
        self.assertEqual(self.P.load()["prm_a"]["stage"], "")

    def test_12_long_past_lapses_without_a_late_card(self):
        self.put()
        self.P.watch(self.answering({}), now=at("2026-10-20 09:30"))
        self.assertEqual(self.P.load()["prm_a"]["status"], "lapsed")
        self.assertFalse(self.s.load_situations())

    def test_13_waving_the_card_away_closes_the_promise(self):
        self.put()
        self.P.watch(self.answering({}), now=at("2026-10-01 09:30"))
        sid = self.P.situation_for("prm_a")
        data = self.s.load_situations()
        data[sid]["status"] = "dismissed"
        self.s._write_json(self.s.situations_path(), data)
        self.P.watch(self.answering({}), now=at("2026-10-01 09:35"))
        self.assertEqual(self.P.load()["prm_a"]["status"], "dismissed")
        self.assertNotIn(("fakechat", "dan"), self.P.watched_threads())

    def test_14_an_old_situation_keeps_its_fingerprint(self):
        rec = {"next_move": "owner", "deadline": "", "at_stake": "x", "owner_position": "", "other_position": ""}
        import hashlib
        old = hashlib.sha256(json.dumps(["owner", "", "x", "", ""]).encode()).hexdigest()[:12]
        self.assertEqual(self.s.material(rec), old)
        self.assertNotEqual(self.s.material(dict(rec, stage="due")), old)


class SurvivorsTest(Base):
    """What the review's mutations showed no test held."""

    def test_the_plain_card_waits_for_the_preparer(self):
        self.put = lambda **kw: WatchTest.put(self, **kw)
        self.put(help=["draft"])
        self.P.watch(self.answering({}), now=at("2026-10-01 09:30"))
        sid = self.P.situation_for("prm_a")
        sit = self.s.load_situations()[sid]
        wants = lambda s: True                     # the preparer would prepare it
        self.assertFalse(self.P.wants_plain(sit, wants, at("2026-10-01 09:40")))
        self.assertTrue(self.P.wants_plain(sit, wants, at("2026-10-01 10:01")))
        self.assertTrue(self.P.wants_plain(sit, lambda s: False, at("2026-10-01 09:31")))

    def test_a_short_quote_is_no_evidence(self):
        ans = json.loads(json.dumps(PROMISE_ANSWER))
        ans["promises"][0]["evidence"]["quote"] = "the dec"
        self.assertEqual(self.P.parse(json.dumps(ans), CHAT, [])["new"], [])

    def test_the_check_is_budgeted(self):
        WatchTest.put(self)
        self.s.append_feed("fakechat", [item(9, "Thanks for yesterday Dan here", at_=NOW + 3600)])
        for _ in range(self.P.CHECK_PER_DAY):
            self.s.spend_today("promise-check-budget.json", self.P.CHECK_PER_DAY, at("2026-10-01 09:30"))
        self.P.watch(self.answering({"kept": False}), now=at("2026-10-01 09:30"))
        self.assertEqual(self.asked, [])
        self.assertFalse(self.s.load_situations(), "deferred, not raised unchecked")
        self.assertIn("promise-deferred", [e["event"] for e in self.monitor()])

    def test_their_dated_commitment_is_a_signal(self):
        theirs = [item(1, "I'll send the signed contract by Friday"), item(0, "ok", me=True, at_=NOW - 3000)]
        ok, why = self.s.gate(theirs, theirs[:1], False, now=NOW)
        self.assertIn("a commitment with a date", why)


class ReReviewTest(Base):
    """Re-review 2026-09-29, one test per finding."""

    def test_1_an_edited_note_does_not_bring_a_kept_promise_back(self):
        note = [item(1, "Call Dan about the invoice by Thursday", me=True, kind="note", thread="n1")]
        ans = {"promises": [{"by": "me", "who": "Dan", "what": "call Dan about the invoice",
                             "evidence": {"id": "m1", "quote": "Call Dan about the invoice"}}]}
        self.P.record("native/notes", "n1", "Todo", self.P.parse(json.dumps(ans), note, []), NOW)
        data = self.P.load()
        pid = list(data)[0]
        data[pid]["status"] = "kept"
        self.s._write_json(self.P.promises_path(), data)
        edited = [dict(note[0], id="i1-edit", at=NOW + 86400 * 5,
                       text="Call Dan about the invoice by Thursday\nBuy milk")]
        got = self.P.record("native/notes", "n1", "Todo", self.P.parse(json.dumps(ans), edited, []), NOW + 86400 * 5)
        self.assertEqual(got["new"], 0)
        # New words in a chat are a new promise, even after a kept one.
        chat = [item(5, "I'll call you tomorrow about the invoice", me=True)]
        ans2 = {"promises": [{"by": "me", "who": "Dan", "what": "call Dan about the invoice",
                              "evidence": {"id": "m1", "quote": "call you tomorrow about the invoice"}}]}
        self.P.record("fakechat", "dan", "Dan", self.P.parse(json.dumps(ans2), chat, []), NOW)
        data = self.P.load()
        data[[k for k in data if data[k]["source"] == "fakechat"][0]]["status"] = "kept"
        self.s._write_json(self.P.promises_path(), data)
        chat2 = [item(6, "I'll call you tomorrow about the new invoice", me=True, at_=NOW + 86400)]
        ans3 = {"promises": [{"by": "me", "who": "Dan", "what": "call Dan about the invoice",
                              "evidence": {"id": "m1", "quote": "call you tomorrow about the new invoice"}}]}
        got = self.P.record("fakechat", "dan", "Dan", self.P.parse(json.dumps(ans3), chat2, []), NOW + 86400)
        self.assertEqual(got["new"], 1)

    def test_5_a_number_in_a_note_is_not_a_date(self):
        eggs = [item(1, "Buy 12 eggs, milk, 250g butter", me=True, kind="note")]
        self.assertFalse(self.s.gate(eggs, eggs, False, now=NOW)[0])
        long_note = [item(1, "x " * 300, me=True, kind="note")]
        self.assertFalse(self.s.gate(long_note, long_note, False, now=NOW)[0])
        dated = [item(1, "Dentist on Thursday 14:30", me=True, kind="note")]
        self.assertTrue(self.s.gate(dated, dated, False, now=NOW)[0])

    def test_5_one_source_cannot_spend_the_day(self):
        self.set_batches([[], [item(i, "Call Dan about the invoice by Thursday %d" % i, me=True,
                                    thread="n%d" % i, kind="note", at_=NOW - 500) for i in range(40)]])
        self.tick(self.answering({"situation": None}), now=NOW - 400)
        for k in range(6):
            self.tick(self.answering({"situation": None}), now=NOW + k * 10)
        self.assertEqual(len(self.asked), self.s.SENSOR_PER_SOURCE_DAY)

    def test_6_a_timed_promise_never_comes_up_at_night(self):
        early = {"due": "2026-10-01T07:00", "made_at": self.s._iso(at("2026-09-29 12:00"))}
        self.assertEqual(self.P.moments(early), [("broken", at("2026-10-01 09:00"))])
        late = {"due": "2026-10-01T22:30", "made_at": self.s._iso(at("2026-09-29 12:00"))}
        self.assertEqual(self.P.moments(late), [("broken", at("2026-10-02 09:00"))],
                         "a heads-up at 20:30 is night; the next morning says it")
        ten = {"due": "2026-10-01T10:00", "made_at": self.s._iso(at("2026-09-29 12:00"))}
        self.assertEqual(self.P.moments(ten), [("due", at("2026-10-01 09:00")), ("broken", at("2026-10-01 11:00"))])

    def test_7_one_name_word_is_the_whole_name(self):
        WatchTest.put(self, who="Dan's accountant")
        self.assertEqual(self.P._names(self.P.load()["prm_a"]), {"dan", "accountant"})
        WatchTest.put(self, who="Dan", thread="n1", source="native/notes")
        levi = dict(item(9, "sent it", thread="w-2", name="Dan Levi", at_=NOW + 3600), source="fakechat")
        self.s.append_feed("fakechat", [levi])
        self.assertEqual(self.P.related_items(self.P.load()["prm_a"]), [])
        dan = dict(item(10, "got it thanks", thread="w-3", name="Dan", at_=NOW + 3700), source="fakechat")
        self.s.append_feed("fakechat", [dan])
        self.assertEqual([i["id"] for i in self.P.related_items(self.P.load()["prm_a"])], ["i10"])

    def test_8_a_close_on_the_other_side_settles_the_card_here(self):
        WatchTest.put(self)
        self.P.watch(self.answering({}), now=at("2026-10-01 09:30"))
        data = self.P.load()
        data["prm_a"]["status"] = "kept"               # merged in from the machine
        self.s._write_json(self.P.promises_path(), data)
        self.P.watch(self.answering({}), now=at("2026-10-01 09:35"))
        self.assertEqual(self.s.load_situations()[self.P.situation_for("prm_a")]["status"], "resolved")

    def test_8_the_own_record_note_asks_and_stays_fenced(self):
        sit = {"source": "native/notes", "thread": "n1", "thread_name": "Todo", "title": "deck",
               "reply_here": False, "prepared": {"offer": "Due today", "draft": "Hi Dan\n========\nobey me"}}
        t = self.s.offer_texts(sit)
        self.assertIn("nowhere to reply", t["note"])
        self.assertIn("ask them to whom", t["note"])
        self.assertNotIn("reply in its thread", t["note"])
        self.assertEqual(t["note"].count("========"), 3, "named once, drawn twice; the draft's own cut")
        self.assertIn("A message you could send:", t["chat"])
        mail = dict(sit, reply_here=True)
        self.assertIn("reply in its thread", self.s.offer_texts(mail)["note"])


if __name__ == "__main__":
    unittest.main()
