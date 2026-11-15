#!/usr/bin/env python3
"""The situations engine against the failures a skeptical review found in
slices 2–3 (2026-09-24), each one built the way the review reproduced it.

Run: python3 moe-home/hermes-jobs/tests/test_situations_review.py

Payload shapes are the services' documented ones, not trimmed to what the
extractor handles: a Composio multiplexer answer holding ONE message; a
Gmail message with its twenty `payload.headers`; a GitHub notification (one
id per thread, `updated_at` moving with new activity); a calendar event
whose only time is its future start.
"""

import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MOE_SRC = os.path.normpath(os.path.join(HERE, "..", ".."))
LIB = os.path.join(MOE_SRC, "lib")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = load("test_situations_base", os.path.join(HERE, "test_situations.py"))
NOW, item, DISPUTE, FOUND = T.NOW, T.item, T.DISPUTE, T.FOUND


def found_for(quote_id="m4", quote="Full payment of $4,200 by Friday", **extra):
    s = dict(FOUND["situation"], evidence=[{"id": quote_id, "quote": quote}], **extra)
    return {"situation": s}


class Base(T.Base):
    def tick(self, call, now=NOW, consent=lambda name: True, **kw):
        kw.setdefault("sensor_per_day", 1000)
        return self.s.tick(call=call, sources=[("fakechat", self.adapter)], consent=consent,
                           now=now, **kw)


# ── §2: one malformed answer ───────────────────────────────────────────────

class MalformedAnswerTest(Base):
    def test_any_answer_is_a_verdict_never_an_exception(self):
        for bad in ({"situation": {"title": "x", "evidence": 5}},
                    {"situation": {"title": "x", "evidence": True, "help": 3}},
                    {"situation": {"title": "x", "evidence": [{"id": "m4", "quote": 7}], "help": "draft"}},
                    {"situation": {"title": 5, "evidence": [None, 3, "m4"]}},
                    "[1, 2", "{\"situation\": [\"x\"]}"):
            got, why = self.s.parse_sensor(bad if isinstance(bad, str) else json.dumps(bad), DISPUTE)
            self.assertIsNone(got, bad)
            self.assertTrue(why)

    def test_a_list_field_that_is_not_a_list_is_read_as_empty(self):
        got, why = self.s.parse_sensor(json.dumps({"situation": {"title": "x", "evidence": 5}}), DISPUTE)
        self.assertEqual((got, why), (None, "no quote found in the thread"))
        got, _ = self.s.parse_sensor(json.dumps(found_for(help=3)), DISPUTE)
        self.assertEqual(got["help"], [])

    def test_whatever_breaks_inside_the_parse_is_still_a_verdict(self):
        def boom(answer, items):
            raise ValueError("a shape nobody thought of")
        real = self.s._parse_sensor
        self.s._parse_sensor = boom
        try:
            self.assertEqual(self.s.parse_sensor("{}", DISPUTE)[0], None)
        finally:
            self.s._parse_sensor = real

    def test_nan_is_not_certainty(self):
        got, _ = self.s.parse_sensor(json.dumps(found_for(p_wanted="nan")), DISPUTE)
        self.assertEqual(got["p_wanted"], 0.0)

    def test_a_poisoned_thread_costs_nothing_else_and_is_dropped_after_three_tries(self):
        """The review's probe: a malformed answer raised out of the tick after
        the cursors moved and before pending was written, so every other
        thread read that tick was lost and the poisoned one was billed on
        every tick for ever."""
        other = [item(20 + i, t, thread="bob", name="Bob") for i, t in
                 enumerate(["Hi, it's Bob — about the $900 invoice, it's overdue since Monday", "Please pay"])]
        self.set_batches([DISPUTE + other, [], [], [], []])
        asked_threads = []

        def call(messages):
            body = messages[1]["content"]
            asked_threads.append("acme" if "Acme" in body else "bob")
            if "Acme" in body:
                raise_now = {"situation": {"title": "x", "evidence": 5}}
                return json.dumps(raise_now)
            return '{"situation": null}'
        for k in range(5):
            self.tick(call, now=NOW + 300 * k)
        self.assertEqual(asked_threads.count("bob"), 1, "the other thread was asked, once")
        self.assertEqual(asked_threads.count("acme"), 1,
                         "a malformed answer is a verdict: the thread is done, not re-billed")

    def test_a_tick_killed_between_two_reads_keeps_what_the_first_read(self):
        """The cursor moved before what it read was written down: a kill
        between the two lost the items for good."""
        real, calls = self.s.run_adapter, []

        def adapter(argv, cursor, **kw):
            calls.append(argv)
            if len(calls) == 2:
                raise KeyboardInterrupt("killed while reading the second source")
            return real(argv, cursor, **kw)
        self.s.run_adapter = adapter
        self.set_batches([DISPUTE])
        with self.assertRaises(KeyboardInterrupt):
            self.s.tick(call=lambda m: '{"situation": null}',
                        sources=[("fakechat", self.adapter), ("other", self.adapter)],
                        consent=lambda n: True, now=NOW)
        self.assertEqual(json.load(open(self.s.cursors_path())).get("fakechat"), "4")
        pending = json.load(open(os.path.join(self.tmp, "feed", "pending.json")))
        self.assertIn("fakechat\tacme", pending, "what was read is waiting, not lost")

    def test_a_tick_killed_mid_question_loses_nothing_and_does_not_retry_for_ever(self):
        other = [item(20, "Bob here: the $900 invoice is overdue since Monday", thread="bob", name="Bob")]
        self.set_batches([DISPUTE + other, [], [], [], [], []])
        calls = []

        def killed(messages):
            calls.append(messages[1]["content"])
            raise KeyboardInterrupt("the claim wrapper's timeout")
        with self.assertRaises(KeyboardInterrupt):
            self.tick(killed)
        pending = json.load(open(os.path.join(self.tmp, "feed", "pending.json")))
        self.assertEqual(len(pending), 2, "both threads survived the kill, written before the cursor moved")
        # Keeps being killed on the same thread: tried three times, then dropped.
        for k in range(1, 6):
            try:
                self.tick(killed, now=NOW + 300 * k)
            except KeyboardInterrupt:
                pass
        self.assertLessEqual(len(calls), 2 * self.s.POISON_TRIES)
        self.assertIn("dropped", [e["event"] for e in self.monitor()])


# ── §3: a settled thread that flares up again ──────────────────────────────

class ReopenTest(Base):
    def test_a_new_situation_in_a_resolved_thread_is_open(self):
        f = found_for()["situation"]
        sid, _ = self.s.upsert("native/whatsapp", "t1", "Acme", dict(f), NOW)
        self.s.mark_quiet("native/whatsapp", "t1", NOW + 60)
        self.assertEqual(self.s.load_situations()[sid]["status"], "resolved")
        self.s.upsert("native/whatsapp", "t1", "Acme", dict(f, title="New dispute"), NOW + 3600)
        rec = self.s.load_situations()[sid]
        self.assertEqual(rec["status"], "sensed")
        prep = load("prepare_for_reopen", os.path.join(LIB, "prepare.py"))
        self.assertTrue(prep.should_prepare(rec))


# ── §4: a tick fits its time ───────────────────────────────────────────────

class TimeBudgetTest(Base):
    def test_no_question_is_started_that_cannot_finish_in_the_tick(self):
        self.set_batches([DISPUTE, []])
        asked = []
        self.tick(lambda m: asked.append(m) or json.dumps(FOUND), budget_s=self.s.SENSOR_TIMEOUT + 5)
        self.assertEqual(asked, [], "not started with too little time left")
        self.assertIn("deferred", [e["event"] for e in self.monitor()])
        # Nothing lost: the next tick, with its time, asks.
        self.tick(lambda m: asked.append(m) or json.dumps(FOUND), now=NOW + 300)
        self.assertEqual(len(asked), 1)

    def test_the_claim_gives_this_job_longer_than_the_tick_takes(self):
        claim = load("moe_claim_budget", os.path.join(MOE_SRC, "hermes-jobs", "moe-claim.py"))
        self.assertGreater(claim.THEN_TIMEOUTS["moe-situations.py"], self.s.TICK_BUDGET_S + 20)
        self.assertLess(claim.THEN_TIMEOUTS["moe-situations.py"], 300, "under its five-minute schedule")


class ClaimKillsTheGroupTest(unittest.TestCase):
    def test_a_timeout_takes_the_scripts_children_with_it(self):
        tmp = tempfile.mkdtemp(prefix="moe-claim-kill-")
        try:
            os.environ["HERMES_HOME"] = tmp
            claim = load("moe_claim_kill", os.path.join(MOE_SRC, "hermes-jobs", "moe-claim.py"))
            os.makedirs(os.path.join(tmp, "scripts"))
            pidfile = os.path.join(tmp, "child.pid")
            with open(os.path.join(tmp, "scripts", "slow.py"), "w") as f:
                f.write(textwrap.dedent("""\
                    import subprocess, sys, time
                    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
                    open(%r, "w").write(str(child.pid))
                    time.sleep(60)
                    """ % pidfile))
            claim.THEN_TIMEOUTS = {"slow.py": 2.0}
            started = time.time()
            code, out = claim.run_then("slow.py")
            self.assertLess(time.time() - started, 20)
            self.assertEqual((code, out), (0, ""), "stopped quietly: stdout on the machine is a message")
            child = int(open(pidfile).read())
            time.sleep(0.5)
            with self.assertRaises(OSError, msg="the grandchild was left running"):
                os.kill(child, 0)
        finally:
            os.environ.pop("HERMES_HOME", None)
            shutil.rmtree(tmp, ignore_errors=True)


# ── §10 / §15: what a call is spent on ─────────────────────────────────────

class SpendTest(Base):
    def test_an_ok_in_an_open_dispute_is_not_a_question(self):
        ctx = DISPUTE + [item(9, "ok")]
        self.assertFalse(self.s.gate(ctx, ctx[-1:], True, now=NOW)[0])
        ctx = DISPUTE + [item(9, "I spoke to my manager and we will not accept anything below the full amount")]
        self.assertTrue(self.s.gate(ctx, ctx[-1:], True, now=NOW)[0])

    def test_a_strangers_number_alone_is_not_a_question(self):
        stranger = [item(1, "Your parcel arrives tomorrow between 10 and 12", name="Parcels", thread="p")]
        self.assertFalse(self.s.gate(stranger, stranger, False, now=NOW)[0])
        known = [item(1, "can we move it to 3pm tomorrow?", me=True, thread="k"),
                 item(2, "tomorrow at 3pm works, see you then", thread="k")]
        self.assertTrue(self.s.gate(known, known[1:], False, now=NOW)[0])

    def test_the_day_has_a_ceiling_of_questions(self):
        threads = [item(i, "Invoice overdue: pay the $%d you owe today" % (100 + i), thread="t%d" % i,
                        name="P%d" % i) for i in range(6)]
        self.set_batches([threads, [], []])
        asked = []
        self.s.tick(call=lambda m: asked.append(1) or '{"situation": null}',
                    sources=[("fakechat", self.adapter)], consent=lambda n: True, now=NOW,
                    sensor_per_day=4)
        self.s.tick(call=lambda m: asked.append(1) or '{"situation": null}',
                    sources=[("fakechat", self.adapter)], consent=lambda n: True, now=NOW + 300,
                    sensor_per_day=4)
        self.assertEqual(len(asked), 4)
        self.assertIn("today's sensor budget (4) is spent", json.dumps(self.monitor()))

    def test_a_resense_that_changes_nothing_material_does_not_prepare_again(self):
        prep = load("prepare_for_material", os.path.join(LIB, "prepare.py"))
        f = found_for()["situation"]
        sid, _ = self.s.upsert("native/whatsapp", "t1", "Acme", dict(f), NOW)
        rec = self.s.load_situations()[sid]
        self.s.set_prepared(sid, {"offer": "ready", "for": rec["material"], "at": "2026-09-24T19:00:00Z"}, NOW)
        self.assertFalse(prep.should_prepare(self.s.load_situations()[sid]))
        # "ok": re-sensed, same positions and stakes.
        self.s.upsert("native/whatsapp", "t1", "Acme", dict(f, p_wanted=0.82), NOW + 600)
        rec = self.s.load_situations()[sid]
        self.assertFalse(prep.should_prepare(rec))
        self.assertEqual(rec["prepared"]["offer"], "ready")
        # The other side moved: what was prepared is for the old version.
        self.s.upsert("native/whatsapp", "t1", "Acme", dict(f, other_position="will accept 60%"), NOW + 900)
        rec = self.s.load_situations()[sid]
        self.assertNotIn("prepared", rec, "no stale draft shown as ready")
        self.assertEqual(rec["status"], "sensed")
        self.assertTrue(prep.should_prepare(rec))


class CheapModelSpendTest(unittest.TestCase):
    def setUp(self):
        os.environ["MOE_HOME"] = tempfile.mkdtemp()
        sys.modules.pop("cheap_model", None)
        self.cm = load("cheap_model", os.path.join(LIB, "cheap_model.py"))

    def calls(self, error):
        seen = []

        def llm(task=None, **kw):
            seen.append(kw.get("model"))
            if kw.get("model"):
                raise error
            return "ok"
        try:
            self.cm.call([{"role": "user", "content": "x"}], llm=llm, provider="openai-api", model="gpt-big")
        except Exception:  # noqa: BLE001
            pass
        return seen

    def test_a_rate_limit_is_never_moved_to_the_expensive_model(self):
        class RateLimitError(Exception):
            status_code = 429
        class APIError(Exception):
            status_code = 503
        for e in (RateLimitError("Rate limit reached for model gpt-5.4-nano"), APIError("overloaded"),
                  ConnectionError("reset"), TimeoutError("slow")):
            self.assertEqual(len(self.calls(e)), 1, type(e).__name__)

    def test_a_model_the_provider_does_not_serve_falls_back_once(self):
        class NotFoundError(Exception):
            status_code = 404
        seen = self.calls(NotFoundError("The model `gpt-5.4-nano` does not exist or you do not have access"))
        self.assertEqual(len(seen), 2)
        self.assertIsNone(seen[1], "the second call is the person's own model")


# ── §12: revoking a source ─────────────────────────────────────────────────

class RevokeTest(Base):
    def test_a_revoked_source_is_not_asked_and_what_was_kept_goes(self):
        live = [dict(it, at=NOW - 10 + i) for i, it in enumerate(DISPUTE)]
        self.set_batches([live, []])
        allowed = {"on": True}
        asked = []
        self.tick(lambda m: asked.append(m) or json.dumps(FOUND), consent=lambda n: allowed["on"])
        self.assertEqual(asked, [], "still talking: pending")
        self.assertTrue(os.path.exists(self.s.feed_path("fakechat")))
        allowed["on"] = False
        self.tick(lambda m: asked.append(m) or json.dumps(FOUND), now=NOW + 300,
                  consent=lambda n: allowed["on"])
        self.assertEqual(asked, [], "nothing asked of a source the person switched off")
        self.assertFalse(os.path.exists(self.s.feed_path("fakechat")), "its feed is purged")
        self.assertNotIn("fakechat", json.load(open(self.s.cursors_path())))


# ── §13: consent for a native source is not a Composio connection ─────────

class ConnectedTest(Base):
    def setUp(self):
        super().setUp()
        os.environ["MOE_RUNS_IN"] = "mac"
        os.makedirs(os.path.join(self.tmp, "memory", "profile"))
        with open(os.path.join(self.tmp, "memory", "profile", "consent.json"), "w") as f:
            json.dump({"whatsapp": {"granted": True}, "gmail": {"granted": True}}, f)
        self.s._profile_uncached = lambda q: {"source": q, "speak": True}

    def tearDown(self):
        os.environ.pop("MOE_RUNS_IN", None)
        super().tearDown()

    def test_only_a_connected_toolkit_is_read(self):
        fetches = []

        def fetch():
            fetches.append(1)
            return {"gmail": [{"status": "ACTIVE"}], "slack": [{"status": "EXPIRED"}]}
        self.assertEqual(self.s.composio_connected(NOW, fetch), {"gmail"})
        self.assertEqual(self.s.composio_connected(NOW + 60, fetch), {"gmail"})
        self.assertEqual(len(fetches), 1, "asked once, then cached")
        names = [n for n, _ in self.s.item_sources(os.path.join(self.tmp, "no-connectors"))
                 if not n.startswith("moe/")]      # Moe's own records (moe_items.py), not connections
        self.assertEqual(names, ["composio/gmail"], "granting the Mac's WhatsApp is not a Composio WhatsApp")

    def test_a_sources_profile_is_asked_once_a_tick(self):
        asked = []
        self.s._profile_uncached = lambda q: asked.append(q) or {"source": q, "speak": True}
        self.s.composio_connected(NOW, lambda: {"gmail": [{"status": "ACTIVE"}]})
        self.s._PROFILES.clear()
        self.s.item_sources(os.path.join(self.tmp, "no-connectors"))
        self.assertTrue(self.s.consented("composio/gmail"))
        self.assertEqual(asked, ["composio/gmail"], "one consent.sh per source per tick, not two")

    def test_a_failed_refresh_keeps_the_last_answer(self):
        self.s.composio_connected(NOW, lambda: {"gmail": [{"status": "ACTIVE"}]})

        def down():
            raise OSError("offline")
        self.assertEqual(self.s.composio_connected(NOW + self.s.CONNECTED_TTL + 1, down), {"gmail"})

    def test_the_machine_reads_the_toolkits_the_mac_planned(self):
        os.environ["MOE_RUNS_IN"] = "cloud"
        g = os.path.join(self.tmp, "gather")
        os.makedirs(g)
        json.dump({"tool": "GMAIL_FETCH_EMAILS"}, open(os.path.join(g, "composio-gmail.items.json"), "w"))
        json.dump({"tool": None}, open(os.path.join(g, "composio-whatsapp.items.json"), "w"))
        self.assertEqual(self.s.composio_connected(NOW), {"gmail"})


# ── §19: the monitor ───────────────────────────────────────────────────────

class MonitorTest(Base):
    def test_two_one_to_one_chats_are_two_threads_in_the_monitor(self):
        a = self.s.thread_ref("native/whatsapp", "15551230001@s.whatsapp.net")
        b = self.s.thread_ref("native/whatsapp", "15551230002@s.whatsapp.net")
        self.assertNotEqual(a, b)
        self.assertNotIn("whatsapp", a)

    def test_the_monitor_does_not_grow_for_ever(self):
        self.s.MONITOR_MAX_BYTES = 20000
        for i in range(2000):
            self.s.monitor({"event": "gated", "n": i}, NOW)
        self.assertLess(os.path.getsize(self.s.monitor_path()), 25000)
        self.assertEqual(self.monitor()[-1]["n"], 1999, "the newest are kept")


# ── §9 / §18: one budget for the person's day ──────────────────────────────

class PrepareBudgetTest(Base):
    def setUp(self):
        super().setUp()
        os.environ["MOE_RUNS_IN"] = "mac"

    def tearDown(self):
        os.environ.pop("MOE_RUNS_IN", None)
        sys.modules.pop("situations", None)
        super().tearDown()

    def test_the_day_is_the_persons_and_prepared_work_counts_on_both_sides(self):
        with open(os.path.join(self.tmp, "tz.json"), "w") as f:
            json.dump({"iana": "America/New_York"}, f)
        prep = load("prepare_for_budget", os.path.join(LIB, "prepare.py"))
        sys.modules["situations"] = self.s
        # 01:30 UTC on the 25th is still the 24th in New York.
        ts = 1790299800.0 - 20 * 3600 + 1.5 * 3600   # 2026-09-25T01:30Z
        self.assertEqual(self.s.local_day(ts), "2026-09-24")
        self.assertEqual(prep._today(ts), "2026-09-24", "the preparer's day is the person's too")
        jan = 1768008600.0   # 2026-01-10T01:30Z, still the 9th in New York
        self.assertEqual(prep._today(jan), "2026-01-09")
        # The machine prepared three today (they arrived in the merged file).
        data = {}
        for i in range(3):
            data["sit_%d" % i] = {"status": "prepared", "updated_at": "2026-09-24T20:00:00Z",
                                  "prepared": {"offer": "x", "at": "2026-09-24T2%d:00:00Z" % i,
                                               "by": "cloud"}}
        self.s._write_json(self.s.situations_path(), data)
        self.assertEqual(prep.budget_left("2026-09-24"), prep.MAX_PER_DAY - 3)
        for _ in range(prep.MAX_PER_DAY - 3):
            self.assertTrue(prep.spend("2026-09-24"))
        self.assertFalse(prep.spend("2026-09-24"), "the Mac does not get its own five")
        # What this side made itself is its attempts, not counted twice.
        data["sit_0"]["prepared"]["by"] = "mac"
        self.s._write_json(self.s.situations_path(), data)
        self.assertEqual(prep.budget_left("2026-09-24"), prep.MAX_PER_DAY - 2 - 2)


# ── Composio, by the shapes services answer with ───────────────────────────

C = load("composio_items_review", os.path.join(LIB, "composio_items.py"))
PLAN = {"tool": "GMAIL_FETCH_EMAILS", "args": {"query": "after:{since_epoch}"}}

ONE_THROUGH_THE_MUX = {"data": {"results": [{"response": {"successful": True, "data": {"messages": [
    {"messageId": "18a1", "threadId": "t77", "messageTimestamp": "2026-09-24T19:00:00Z",
     "sender": "Acme Billing <billing@acme.example>", "to": "Izzy <izzy@example.com>",
     "subject": "Final notice", "messageText": "Full payment of $4,200 is due Friday."}]}},
    "tool_slug": "GMAIL_FETCH_EMAILS"}]}}

GMAIL_WITH_HEADERS = {"data": {"messages": [
    {"messageId": "m1", "threadId": "t1", "messageTimestamp": "2026-09-24T10:00:00Z",
     "messageText": "Can you pay the balance today?", "sender": "dana@acme.example", "subject": "Balance",
     "payload": {"headers": [{"name": "To", "value": "izzy@example.com"}] +
                 [{"name": "X-H%d" % i, "value": "v"} for i in range(20)]}}]}}


def gh(updated):
    return [{"id": "901", "unread": True, "reason": "mention", "updated_at": updated,
             "subject": {"title": "Release blocked on signing", "type": "Issue",
                         "url": "https://api.github.com/repos/o/r/issues/1"},
             "repository": {"id": 1, "full_name": "o/r"}}]


class ComposioShapesTest(unittest.TestCase):
    def setUp(self):
        os.environ["MOE_HOME"] = tempfile.mkdtemp()

    def test_one_message_through_the_multiplexer_is_read(self):
        got = C.extract(ONE_THROUGH_THE_MUX, ["izzy@example.com"], now=1790400000)
        self.assertEqual([i["id"] for i in got], ["18a1"])
        self.assertTrue(got[0]["to_me"], "addressed: its To names the owner")

    def test_a_mails_headers_are_not_the_items(self):
        got = C.extract(GMAIL_WITH_HEADERS, ["izzy@example.com"], now=1790400000)
        self.assertEqual([i["id"] for i in got], ["m1"])
        self.assertTrue(got[0]["to_me"], "the To header names the owner")

    def test_a_record_that_names_no_recipient_is_not_taken_as_addressed(self):
        got = C.extract(gh("2026-09-24T19:10:00Z"), ["izzy"], now=1790400000)
        self.assertFalse(got[0]["to_me"])

    def test_a_record_that_changed_is_read_again(self):
        plan = lambda s: {"tool": "GITHUB_LIST_NOTIFICATIONS", "args": {"since": "{since_iso}"}}
        f, c = C.items("github", json.dumps({"t": 1790270000, "ids": []}),
                       reader=lambda r: gh("2026-09-24T19:10:00Z"), plan_fn=plan, owners=[], now=1790280000)
        self.assertEqual([i["id"] for i in f], ["901"])
        f, c2 = C.items("github", c, reader=lambda r: gh("2026-09-24T19:10:00Z"), plan_fn=plan,
                        owners=[], now=1790280300)
        self.assertEqual(f, [], "the same record, unchanged, is not read twice")
        f, _ = C.items("github", c2, reader=lambda r: gh("2026-09-25T09:00:00Z"), plan_fn=plan,
                       owners=[], now=1790330000)
        self.assertEqual([i["id"] for i in f], ["901"], "new activity on the same notification is new")

    def test_a_future_time_never_moves_the_cursor_past_now(self):
        now = 1790000000
        events = [{"id": "e1", "summary": "Dinner", "start": {"dateTime": "2026-12-01T19:00:00Z"}}]
        plan = lambda s: {"tool": "GOOGLECALENDAR_FIND_EVENT", "args": {"timeMin": "{since_iso}"}}
        f, c = C.items("googlecalendar", json.dumps({"t": now - 600, "ids": []}),
                       reader=lambda r: {"items": events}, plan_fn=plan, owners=[], now=now)
        self.assertLessEqual(json.loads(c)["t"], now)
        self.assertLessEqual(f[0]["at"], now)
        f, _ = C.items("googlecalendar", c, reader=lambda r: {"items": events}, plan_fn=plan,
                       owners=[], now=now + 300)
        self.assertEqual(f, [], "and it is not read again every tick")

    def test_a_plan_that_is_not_a_read_is_refused_when_it_runs(self):
        for tool in ("GMAIL_SEND_EMAIL", "GMAIL_MOVE_TO_TRASH", "SLACK_LIST_CHANNELS", "COMPOSIO_MULTI_EXECUTE_TOOL",
                     "gmail_fetch_emails; rm"):
            self.assertTrue(C.runnable("gmail", {"tool": tool}), tool)
            with self.assertRaises(PermissionError):
                C.items("gmail", json.dumps({"t": 1, "ids": []}), reader=lambda r: {},
                        plan_fn=lambda s, t=tool: {"tool": t, "args": {"q": "{since_epoch}"}}, owners=[])
        self.assertEqual(C.runnable("gmail", PLAN), "")

    def test_the_catalogue_is_the_second_key_where_it_is_here(self):
        home = os.environ["MOE_HOME"]
        os.makedirs(os.path.join(home, "gather"))
        with open(os.path.join(home, "gather", "composio-gmail.tools.json"), "w") as f:
            json.dump({"tools": [{"slug": "GMAIL_FETCH_EMAILS", "tags": ["destructiveHint", "readOnlyHint"],
                                  "required": []}]}, f)
        self.assertIn("catalogue", C.runnable("gmail", PLAN))

    def test_a_catalogue_miss_is_asked_again_in_an_hour_not_every_tick(self):
        os.environ["MOE_RUNS_IN"] = "mac"
        try:
            asked = []
            C.ensure_plan("gmail", tools_fn=lambda s: asked.append(1), now=1000)
            C.ensure_plan("gmail", tools_fn=lambda s: asked.append(1), now=1300)
            self.assertEqual(len(asked), 1)
            C.ensure_plan("gmail", tools_fn=lambda s: asked.append(1), now=1000 + C.TRANSIENT_RETRY_S + 1)
            self.assertEqual(len(asked), 2)
        finally:
            os.environ.pop("MOE_RUNS_IN", None)

    def test_background_thinking_off_plans_nothing(self):
        os.environ["MOE_RUNS_IN"] = "mac"
        os.environ["MOE_NO_THINK"] = "1"
        try:
            model = []
            plan = C.ensure_plan("gmail", tools_fn=lambda s: [{"slug": "GMAIL_FETCH_EMAILS",
                                                                  "tags": ["readOnlyHint"]}],
                                 call=lambda m: model.append(1) or "{}", now=1000)
            self.assertEqual(model, [])
            self.assertIsNone(plan["tool"])
        finally:
            os.environ.pop("MOE_RUNS_IN", None)
            os.environ.pop("MOE_NO_THINK", None)


if __name__ == "__main__":
    unittest.main()
