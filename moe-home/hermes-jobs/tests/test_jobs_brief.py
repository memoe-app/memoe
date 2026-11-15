"""lib/jobs_brief.py: the person's jobs in the brief, with how each is doing,
in words that stay the same while nothing changes.

Run: python3 moe-home/hermes-jobs/tests/test_jobs_brief.py
"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("jobs_brief", os.path.join(HERE, "..", "..", "lib", "jobs_brief.py"))
jb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jb)


class JobsBriefTest(unittest.TestCase):
    def test_the_real_shapes(self):
        jobs = [
            {"name": "X daily growth — follow &amp; comment", "prompt": "Grow.", "enabled": True,
             "schedule": {"kind": "cron", "expr": "0 9 * * *", "display": "every day at 9am"},
             "last_status": "error", "failure_streak": 5, "last_run_at": "2026-09-30T09:16:55-04:00",
             "last_error": "TimeoutError: Cron job 'X' idle for 905s (limit 600s)"},
            {"name": "Marketing: watchdog", "no_agent": True, "script": "marketing-watchdog.sh",
             "schedule": {"kind": "cron", "expr": "30 13 * * *", "display": "30 13 * * *"}},
            {"name": "Memoe marketing push", "prompt": "Push.", "enabled": False,
             "schedule": {"kind": "once", "display": "once in 1m"}},
            {"name": "moe-proactive", "prompt": "internal"},
        ]
        for j in jobs:
            j.setdefault("id", "ab12cd34ef56")
        got = jb.lines(jobs, cloud=True)
        self.assertEqual(got, [
            "- X daily growth — follow & comment — every day at 9am, on your Mac, and in the cloud while it "
            "is off — not working — it stalled before finishing, several runs in a row",
            "- Marketing: watchdog — 30 13 * * *, on your Mac — not run yet",
            "- Memoe marketing push — once in 1m, on your Mac, and in the cloud while it is off — paused",
        ])

    def test_a_working_job_reads_the_same_run_after_run(self):
        job = {"name": "Brief", "prompt": "x", "schedule": {"display": "every day at 8:30am"},
               "last_status": "ok", "last_run_at": "2026-09-30T08:31:00-04:00"}
        later = dict(job, last_run_at="2026-10-01T08:31:00-04:00")
        self.assertEqual(jb.lines([job]), jb.lines([later]))

    def test_one_more_failure_does_not_change_the_line(self):
        a = {"name": "Monitor", "prompt": "x", "id": "ab12cd34ef56", "schedule": {"display": "every 2 hours"},
             "last_status": "error", "failure_streak": 3, "last_error": "idle for 905s",
             "last_run_at": "2026-09-30T09:00:00-04:00"}
        self.assertEqual(jb.lines([a], cloud=True), jb.lines([dict(a, failure_streak=4)], cloud=True))

    def test_a_browser_job_runs_in_the_cloud_too_unless_it_needs_the_macs_own(self):
        # Away has its own browser since 2026-11-13 (docs/AWAY-BROWSER.md).
        job = {"name": "Prices", "prompt": "Use browser_exec to read the pricing page.",
               "id": "ab12cd34ef56", "schedule": {"display": "daily"}}
        self.assertEqual(jb.lines([job], cloud=True),
                         ["- Prices — daily, on your Mac, and in the cloud while it is off — not run yet"])
        own = dict(job, prompt="browser_exec local=true: read my inbox.")
        self.assertEqual(jb.lines([own], cloud=True), ["- Prices — daily, on your Mac — not run yet"])

    def test_no_cloud_computer_no_cloud_promise(self):
        job = {"name": "Brief", "prompt": "x", "id": "ab12cd34ef56", "schedule": {"display": "daily"}}
        self.assertEqual(jb.lines([job], cloud=False), ["- Brief — daily, on your Mac — not run yet"])


if __name__ == "__main__":
    unittest.main()
