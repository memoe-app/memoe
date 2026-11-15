#!/usr/bin/env python3
"""The preparer (moe-home/lib/prepare.py): a noticed situation turned into
research, options and a draft, with nothing sent. Stubbed models and search.

Run: python3 moe-home/hermes-jobs/tests/test_prepare.py
"""

import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", "..", "lib"))


def load(name):
    if LIB not in sys.path:
        sys.path.insert(0, LIB)
    spec = importlib.util.spec_from_file_location(name, os.path.join(LIB, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


SIT = {"id": "sit_1", "title": "Acme short delivery", "kind": "payment dispute",
       "owner_position": "pay half: 250 of 700 arrived", "other_position": "wants $4,200 by Friday",
       "at_stake": "$4,200 and the supplier", "open_question": "how much to pay",
       "next_move": "owner", "deadline": "2026-09-26", "help": ["research", "draft", "compute"],
       "p_wanted": 0.8, "status": "sensed", "updated_at": "2026-09-24T19:00:00Z",
       "thread_name": "Acme Foods", "source": "native/whatsapp",
       "evidence": [{"id": "x", "quote": "Full payment of $4,200 by Friday"}]}

#: 2026-09-24T20:00:00Z — an hour after SIT's `updated_at`.
TICK_AT = 1790280000.0

FOUND = [{"title": "Rights when a supplier short-ships", "url": "https://law.example/short-ship",
          "snippet": "Pay for what was delivered, or accept with a credit note."}]


def plan_call(queries, draft=True):
    return lambda m: json.dumps({"queries": queries, "work_out": "pro-rata amount",
                                 "draft": {"needed": draft, "to": "Acme Foods", "goal": "propose pro-rata"}})


def compose_call(payload):
    return lambda m: json.dumps(payload)


GOOD = {"offer": "Acme wants the full $4,200 for a short delivery; I worked out pro-rata and drafted a reply.",
        "research": [{"point": "Buyers usually pay for what arrived", "source": "https://law.example/short-ship"},
                     {"point": "Invented", "source": "https://not-searched.example"}],
        "options": ["Pay pro-rata: $1,500 for 250 of 700", "Pay for delivered plus a credit note"],
        "draft": "Hi — 250 of the 700 arrived, so I'll pay $1,500 now. See https://evil.example"}


class PrepareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-prepare-")
        os.environ["MOE_HOME"] = self.tmp
        self.p = load("prepare")
        self.searched = []

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def search(self, q):
        self.searched.append(q)
        return FOUND

    def test_prepares_research_options_and_a_draft(self):
        made, why = self.p.prepare(SIT, plan_call=plan_call(["how buyers settle a short shipment"]),
                                   compose_call=compose_call(GOOD), search=self.search)
        self.assertEqual(why, "prepared")
        self.assertEqual([r["source"] for r in made["research"]], ["https://law.example/short-ship"],
                         "only sources the search returned")
        self.assertEqual(len(made["options"]), 2)
        self.assertNotIn("http", made["draft"], "no links in a draft")
        self.assertEqual(made["for"], SIT["updated_at"])

    def test_nothing_ready_to_use_carries_a_link_or_an_account_number(self):
        """Review §17: only http(s) links were taken out, and only of the draft."""
        sly = dict(GOOD, offer="Pay at www.pay-here.com today",
                   options=["Wire it to GB82 WEST 1234 5698 7654 32", "Use bit.ly/x9 to pay"],
                   research=[{"point": "See pay-here.com/terms", "source": "https://law.example/short-ship"}],
                   draft="Sure, I'll pay via www.pay-here.com or IBAN DE89370400440532013000.")
        made, _ = self.p.prepare(SIT, plan_call=plan_call(["how buyers settle a short shipment"]),
                                 compose_call=compose_call(sly), search=self.search)
        blob = json.dumps({k: made[k] for k in ("offer", "options", "research", "draft")})
        for bad in ("pay-here", "bit.ly", "GB82", "DE8937"):
            self.assertNotIn(bad, blob)
        self.assertEqual(made["research"][0]["source"], "https://law.example/short-ship")

    def test_a_search_engine_never_learns_who_or_what_was_said(self):
        """Review §11: a lowercase name, an accented one, one in another script
        and an email domain all passed the first version, which banned only
        Capitalised words."""
        sit = dict(SIT, thread_name="Dave Müller", evidence=SIT["evidence"] + [
            {"id": "y", "quote": "hey its dave, Müller GmbH, email me at dave@brightwater.io"}])
        self.p.prepare(sit, plan_call=plan_call([
            "Acme Foods dispute", "is $4,200 fair for 250 birds",
            "Full payment of $4,200 by Friday meaning", "partial delivery payment norms",
            "dave plumber refund rights", "müller gmbh late delivery", "משה כהן חוב",
            "brightwater.io late payment", "how buyers settle a short shipment",
            "late delivery compensation customs", "supplier sent less than ordered", "one too many"]),
            compose_call=compose_call(GOOD), search=self.search)
        self.assertEqual(self.searched, ["how buyers settle a short shipment",
                                         "late delivery compensation customs",
                                         "supplier sent less than ordered"])

    def test_no_draft_unless_the_plan_wanted_one_and_nothing_usable_is_nothing(self):
        made, _ = self.p.prepare(SIT, plan_call=plan_call(["partial delivery payment norms"], draft=False),
                                 compose_call=compose_call(GOOD), search=self.search)
        self.assertEqual(made["draft"], "")
        made, why = self.p.prepare(SIT, plan_call=plan_call([]), compose_call=compose_call({"offer": "x"}),
                                   search=self.search)
        self.assertEqual((made, why), (None, "nothing usable prepared"))
        made, why = self.p.prepare(SIT, plan_call=lambda m: "no", compose_call=compose_call(GOOD),
                                   search=self.search)
        self.assertEqual((made, why), (None, "unreadable plan"))

    def test_a_hebrew_conversation_is_researched_in_english_and_its_words_stay_home(self):
        """Owner, 2026-09-24: translate, then check. The planner is told to
        search in English about the kind of situation; a query in the
        conversation's own script is still refused."""
        self.assertIn("always in English", self.p.PLAN_SYSTEM)
        sit = dict(SIT, thread_name="\u05de\u05e8\u05d3\u05db\u05d9",
                   evidence=[{"id": "x", "quote": "\u05ea\u05e9\u05dc\u05dd \u05d0\u05ea \u05d4\u05db\u05dc"}])
        self.p.prepare(sit, plan_call=plan_call(["\u05e1\u05e4\u05e7 \u05d7\u05dc\u05e7\u05d9",
                                                 "supplier partial delivery payment norms"]),
                       compose_call=compose_call(GOOD), search=self.search)
        self.assertEqual(self.searched, ["supplier partial delivery payment norms"])

    def test_what_is_worth_preparing(self):
        self.assertTrue(self.p.should_prepare(SIT))
        for change in ({"next_move": "other"}, {"p_wanted": 0.3}, {"status": "resolved"},
                       {"help": ["remind"]}):
            self.assertFalse(self.p.should_prepare(dict(SIT, **change)), change)
        # Prepared for this version of what it works from: not again when
        # only the thread moved on ("ok"), again when that changed (review §10).
        same = dict(SIT, material="0a1b2c3d4e5f", updated_at="2026-09-25T08:00:00Z",
                    prepared={"for": "0a1b2c3d4e5f"})
        self.assertFalse(self.p.should_prepare(same))
        self.assertTrue(self.p.should_prepare(dict(same, material="ffff00001111")))
        done = dict(SIT, prepared={"for": SIT["updated_at"]})
        self.assertFalse(self.p.should_prepare(done), "not twice for one version")
        self.assertTrue(self.p.should_prepare(dict(done, updated_at="2026-09-25T08:00:00Z")),
                        "again when the situation moves")

    def test_the_day_has_a_budget(self):
        for _ in range(self.p.MAX_PER_DAY):
            self.p.spend("2026-09-24")
        self.assertEqual(self.p.budget_left("2026-09-24"), 0)
        self.assertEqual(self.p.budget_left("2026-09-25"), self.p.MAX_PER_DAY)


class TickPrepareTest(unittest.TestCase):
    """Through the engine's tick: a noticed situation gets prepared, once."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="moe-prepare-tick-")
        os.environ["MOE_HOME"] = self.tmp
        self.s = load("situations")
        load("prepare")
        os.makedirs(os.path.join(self.tmp, "proactive"))
        with open(self.s.situations_path(), "w") as f:
            json.dump({"sit_1": SIT}, f)

    def tearDown(self):
        os.environ.pop("MOE_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_prepared_once_and_updated_at_is_left_alone(self):
        calls = []

        def preparer(sit):
            calls.append(sit["id"])
            return ({"offer": "ready", "research": [], "options": ["a"], "draft": "", "for": sit["updated_at"]},
                    "prepared")
        # A pinned clock, an hour after SIT was last touched. With none, the
        # tick ran on the wall clock and SIT — dated 2026-09-24 — aged out of
        # the 45-day keep on 2026-11-08, so `prune` dropped the record this
        # is about and the test failed on a KeyError rather than on anything
        # it checks.
        self.s.tick(call=lambda m: "{}", sources=[], preparer=preparer, now=TICK_AT)
        self.s.tick(call=lambda m: "{}", sources=[], preparer=preparer, now=TICK_AT + 300)
        self.assertEqual(calls, ["sit_1"])
        rec = self.s.load_situations()["sit_1"]
        self.assertEqual(rec["status"], "prepared")
        self.assertEqual(rec["updated_at"], SIT["updated_at"])
        self.assertEqual(rec["prepared"]["offer"], "ready")

    def test_nothing_is_prepared_with_background_thinking_off(self):
        calls = []
        self.s.tick(call=lambda m: "{}", sources=[], think=False,
                    preparer=lambda sit: calls.append(1) or (None, "x"))
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
