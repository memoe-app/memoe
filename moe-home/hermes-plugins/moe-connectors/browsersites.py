"""Which sites the cloud computer's browser may stay signed in to (docs/AWAY-BROWSER.md §2).

The person signs in on the cloud browser themselves, through the one-time live link
(signin.py); the sign-in lands in the browser's kept profile on the machine's volume and
nowhere else. Which of those sign-ins STAY is the person's call, made on the Mac in
Settings › Away › Cloud browser: the list travels to the machine as the ``cloudBrowserSites``
key of the sealed ``settings/background`` document (the edge carries ciphertext only) and
lands in ``$MOE_HOME/config.json``.

Here the list is enforced. Before the browser starts cold — the first browser call of a task,
since the fork releases it after two idle minutes — every cookie whose host is not one of the
listed sites (or a subdomain of one) is deleted from the kept profile's cookie store. The
browser is never running when this happens (its processes are checked first), so the store
is not written under a live browser.

Three states, kept apart on purpose (validate, then branch):

* the key is ABSENT — a Mac that has never offered the choice (an older Memoe). Nothing is
  pruned: deleting every sign-in on a machine whose person was never asked would be the
  wrong default, and absence is not a choice.
* the key is a LIST — enforced exactly, the empty list included (nothing stays).
* the key is anything else — unreadable. Nothing is pruned and it is logged; a malformed
  value is not read as "keep nothing" or "keep everything".

Nothing here reads a cookie's value; only ``host_key`` is matched, and rows are deleted.
"""

from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
from pathlib import Path
from typing import Iterable, List, Optional, Sequence

logger = logging.getLogger(__name__)

CONFIG_KEY = "cloudBrowserSites"
#: Where Chromium keeps the cookie store in a profile, newest layout first.
COOKIE_STORES = (os.path.join("Default", "Network", "Cookies"), os.path.join("Default", "Cookies"))
_DOMAIN = re.compile(r"^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")


def clean_site(value: str) -> Optional[str]:
    """``"https://www.X.com/login"`` → ``"x.com"``; None when it is not a domain."""
    text = str(value or "").strip().lower()
    text = re.sub(r"^[a-z][a-z0-9+.-]*://", "", text)
    text = text.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0].split("@")[-1].split(":", 1)[0]
    text = text.strip(".")
    if text.startswith("www."):
        text = text[4:]
    return text if _DOMAIN.match(text) else None


def allowed_sites(moe_home: str) -> Optional[List[str]]:
    """The person's list, cleaned; None when they have not made one (absent or unreadable)."""
    try:
        with open(os.path.join(moe_home, "config.json"), encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(cfg, dict) or CONFIG_KEY not in cfg:
        return None
    raw = cfg[CONFIG_KEY]
    if not isinstance(raw, list):
        logger.warning("cloud browser: %s is not a list; nothing pruned", CONFIG_KEY)
        return None
    sites = sorted({s for s in (clean_site(v) for v in raw if isinstance(v, str)) if s})
    return sites


def host_allowed(host_key: str, sites: Sequence[str]) -> bool:
    host = str(host_key or "").lower().lstrip(".")
    return any(host == s or host.endswith("." + s) for s in sites)


def kept_dir(hermes_home: str) -> str:
    return os.path.join(hermes_home, "browser-profile", "kept")


def browser_running(data_dir: str, proc_root: str = "/proc") -> bool:
    """Whether any process names ``--user-data-dir=<data_dir>``. Unknown (no /proc) is True:
    a store is never written when we cannot tell that nothing holds it."""
    if not os.path.isdir(proc_root):
        return True
    want = f"--user-data-dir={data_dir}".encode()
    for entry in os.listdir(proc_root):
        if not entry.isdigit():
            continue
        try:
            with open(os.path.join(proc_root, entry, "cmdline"), "rb") as fh:
                if want in fh.read().split(b"\0"):
                    return True
        except OSError:
            continue
    return False


def prune_store(path: str, sites: Sequence[str]) -> int:
    """Delete every cookie whose host is not an allowed site. Returns the rows deleted."""
    db = sqlite3.connect(path, timeout=2)
    try:
        hosts = [row[0] for row in db.execute("SELECT DISTINCT host_key FROM cookies")]
        drop = [h for h in hosts if not host_allowed(h, sites)]
        deleted = 0
        for host in drop:
            deleted += db.execute("DELETE FROM cookies WHERE host_key = ?", (host,)).rowcount
        db.commit()
        return deleted
    finally:
        db.close()


def prune(hermes_home: str, moe_home: str, proc_root: str = "/proc") -> dict:
    """Hold the kept profile to the person's list. Never raises; says what it did."""
    sites = allowed_sites(moe_home)
    if sites is None:
        return {"pruned": False, "why": "no list from the Mac"}
    data_dir = kept_dir(hermes_home)
    if not os.path.isdir(data_dir):
        return {"pruned": False, "why": "no kept profile yet"}
    if browser_running(data_dir, proc_root):
        return {"pruned": False, "why": "the browser is running"}
    deleted = 0
    for rel in COOKIE_STORES:
        path = os.path.join(data_dir, rel)
        if not os.path.isfile(path):
            continue
        try:
            deleted += prune_store(path, sites)
        except sqlite3.Error as exc:
            logger.warning("cloud browser: could not prune %s: %s", rel, exc)
    if deleted:
        logger.info("cloud browser: %d cookie(s) for sites not on the person's list removed", deleted)
    return {"pruned": True, "deleted": deleted, "sites": len(sites)}


def kept_note(site: str, moe_home: str) -> str:
    """What the sign-in tool tells the model about whether this sign-in will stay."""
    sites = allowed_sites(moe_home)
    name = clean_site(site) or site or "the site"
    if sites is None or host_allowed(name, sites):
        return f"The sign-in to {name} stays in this browser for later jobs."
    return (f"{name} is not on the person's list of sites the cloud browser stays signed in to, so this "
            f"sign-in lasts only for this task. If they want it kept, they add {name} under Settings › "
            f"Away › Cloud browser on their Mac. Say so in one line.")


def is_browser_tool(name: str) -> bool:
    bare = str(name or "").rsplit("__", 1)[-1]
    return bare.startswith("browser_")
