"""Slim a Hermes pm tool store for shipping inside Memoe's seed.

    slim-hermes-tools.py <store>            # do it
    slim-hermes-tools.py <store> --check    # say what would go; change nothing

Called by stage-hermes-seed.sh after pm.prepare_tools. Two things leave:

1. Chromium (Chrome for Testing, ~330 MB). pm pulls it in as agent-browser's
   dependency; Memoe's installer puts the same pinned, sha256-checked build
   into the store on first launch instead (fetch-hermes-browser.sh), so the
   download stays its old size. The store is left with `.browser-pending`,
   which the fork's browser tools read as "still downloading" until then.
2. Build-time-only files no seeded Hermes reads at run time: C headers
   (node's include/ is 64 MB of OpenSSL headers for every platform), man pages
   and doc directories, static archives, Python's Tk/IDLE/turtle.
   Lazy installs are off, so nothing compiles against them on a user's Mac.

ensurepip STAYS. Without it `python -m venv` fails on every Mac, and Memoe's
Telegram sign-in (connect-telegram.sh) made its venv that way: from 0.3.22 to
2026-11-13 every seeded Mac showed "…'-m', 'ensurepip', '--upgrade',
'--default-pip']' returned non-zero exit status 1". It is ~2 MB; anything a
person or a skill runs `-m venv` with needs it.

pm records a digest of every entry it publishes and re-hashes it on an
explicit install. A slimmed entry would read as damaged and be "repaired" back
to full size, so each touched entry's digest is recomputed with pm's own
Facts.refresh_digests, pm's own step for exactly this. The store then says, truthfully, what it holds.
"""
import fnmatch
import json
import shutil
import sys
from pathlib import Path

MARKER = ".browser-pending"          # tools.browser_tool_install.BROWSER_PENDING_MARKER in the fork
DROP_PACKAGES = ("chromium",)
# Paths relative to an entry. Globs match at that depth only.
DROP_IN_ENTRY = (
    "include",                       # node-*/include (64 MB), python-*/include (2.6 MB)
    "share/man", "share/doc", "doc", # man pages and docs (ripgrep's doc/ is 260 KB)
    "CHANGELOG.md",
    "lib/tcl*", "lib/tk*", "lib/itcl*", "lib/thread*", "lib/libtcl*",
    "lib/python3.*/tkinter", "lib/python3.*/idlelib", "lib/python3.*/turtledemo",
    "lib/python3.*/lib-dynload/_tkinter*",
)
DROP_ANYWHERE = ("*.a",)             # static archives: link-time only
# Never dropped, whatever a pattern above grows into: `python -m venv` dies
# without it (see the docstring). main() refuses a hit under one of these.
KEEP = ("lib/python3.*/ensurepip",)


def _size(p: Path) -> int:
    if p.is_symlink() or p.is_file():
        return p.lstat().st_size
    return sum(f.lstat().st_size for f in p.rglob("*") if f.is_file() and not f.is_symlink())


def _matches(entry: Path) -> list[Path]:
    hits = []
    for pattern in DROP_IN_ENTRY:
        hits.extend(sorted(entry.glob(pattern)))
    for pattern in DROP_ANYWHERE:
        hits.extend(p for p in sorted(entry.rglob("*"))
                    if p.is_file() and fnmatch.fnmatch(p.name, pattern))
    seen, out = set(), []
    for h in hits:                    # a parent already listed covers its children
        if h in seen or any(parent in seen for parent in h.parents):
            continue
        seen.add(h)
        out.append(h)
    return out




def main(argv: list[str]) -> int:
    store = Path(argv[1])
    check = "--check" in argv[2:]
    facts_path = store / "facts.json"
    facts = json.loads(facts_path.read_text())
    packages = facts.get("packages", {})
    freed = 0
    for name in DROP_PACKAGES:
        fact = packages.get(name)
        if not fact:
            continue
        entry = store / fact["entry"]
        size = _size(entry) if entry.exists() else 0
        freed += size
        print(f"  - {fact['entry']} ({size // 2**20} MB): Memoe's installer fetches it on first launch")
        if not check:
            shutil.rmtree(entry, ignore_errors=True)
            del packages[name]
    for name, fact in sorted(packages.items()):
        entry = store / fact["entry"]
        if not entry.is_dir():
            continue
        hits = _matches(entry)
        kept = [h for h in hits for k in KEEP for g in entry.glob(k) if h == g or g in h.parents or h in g.parents]
        if kept:
            print(f"  ✗ refusing to drop {', '.join(str(h.relative_to(entry)) for h in kept)}: "
                  f"`python -m venv` needs it")
            return 1
        if not hits:
            continue
        size = sum(_size(h) for h in hits)
        freed += size
        print(f"  - {fact['entry']}: {', '.join(str(h.relative_to(entry)) for h in hits)} ({size // 1024} KB)")
        if check:
            continue
        for h in hits:
            if h.is_dir() and not h.is_symlink():
                shutil.rmtree(h)
            else:
                h.unlink()
    if not check:
        facts_path.write_text(json.dumps(facts, indent=2, sort_keys=True) + "\n")
        try:
            from pm.lock import Facts
        except ImportError:           # a test fixture's store, with no pm beside it
            pass
        else:                         # pm's own "publish digests after packaging changed bytes"
            Facts(facts_path).refresh_digests(store)
        (store / MARKER).write_text("Memoe's installer puts the pinned Chromium here on first launch "
                                    "(scripts/fetch-hermes-browser.sh) and removes this file.\n")
    print(f"  {'would free' if check else 'freed'} {freed // 2**20} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
