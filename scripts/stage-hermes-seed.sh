#!/bin/bash
# Stages the Hermes seed that ships inside Memoe.app, so a new Mac needs no
# network to think.
#
# Today onboarding clones a repo and pipes an installer from the internet into
# a shell, at the one moment a new user is least able to judge either. This
# builds the same result ahead of time, from a pinned commit of the fork, so it
# can be signed by Apple before it ever reaches a stranger.
#
# ── What a seed is, since Hermes moved to Python 3.14 and `pm` ──────────────
#
#   hermes-agent/          the fork at one commit (tracked files only), with
#     .venv/               its sealed dependency environment
#     install-stamp.json   "updateMechanism: external" — Memoe updates this
#                          tree; Hermes never syncs or re-execs it at launch
#     .moe-seed-commit     which commit (refresh-hermes-seed.sh reads it)
#     .moe-seed-pruned     what staging removed (ditto)
#   tools/                 Hermes's own `pm` tool store: the Python the venv
#                          runs on, Node + npm (MCP servers, the WhatsApp
#                          bridge), uv, and whatever SEED_TOOLS adds. Hermes
#                          finds every one of them here by itself
#                          ($HERMES_HOME/tools/facts.json) and nowhere else —
#                          upstream 5e4a2a3d24 stopped reading $HERMES_HOME/node
#                          and the PATH.
#
# Both are built the way upstream builds its own sealed desktop payload
# (scripts/bundles/native.py): `pm.prepare_tools` for the store and
# `pm.build_env --sealed` for the venv, on the store's own interpreter. A
# sealed build drops the two .pth files that name the build machine; the tree
# is wired to its venv by a RELATIVE hermes-agent.pth instead, so it needs no
# rewriting at all.
#
# ── The rule this file exists to enforce ────────────────────────────────────
#
# Nothing in this seed comes from anybody's working Hermes. It used to: the
# seed was a copy of ~/.hermes's hermes-agent, python and node, by allowlist,
# out of the one directory on this Mac that holds auth.json, .env,
# mcp-tokens/, memories/ and sessions/. Now the code is `git archive` of a
# commit and everything else is built fresh into $OUT, so there is no route
# for a personal file to arrive. The leak gate at the end stays, and still
# fails on a planted leak (scripts/test-hermes-seed.sh), because a gate that
# has never been seen to fail is decoration.
#
# ── Absolute paths ──────────────────────────────────────────────────────────
#
# A venv is full of them: the shebang of every script in .venv/bin, `home =`
# in pyvenv.cfg, and the editable install's direct_url.json. They are
# rewritten to the literal @HERMES_ROOT@ here and substituted back on the
# user's Mac (HermesSeed.swift). That is what makes the seed the same bytes
# for everybody — which the gate at the end then proves, and which is also
# what lets a Sparkle delta skip all of it.
#
#   ./scripts/stage-hermes-seed.sh                       # from ~/.hermes/hermes-agent
#   HERMES_SOURCE=~/hermes-agent-fork ./scripts/stage-hermes-seed.sh
#   HERMES_ROOT=/somewhere ./scripts/stage-hermes-seed.sh  # = /somewhere/hermes-agent
#
# Needs the network (PyPI, and the pinned tool downloads in the fork's
# pm/lock.json, each sha256-checked by pm) and uv on PATH or in ~/.local/bin.
# Touches nothing outside $OUT and a temporary directory: pm's own state and
# HOME are pointed into that directory for the whole build.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
SRC="${HERMES_SOURCE:-$HERMES_ROOT/hermes-agent}"
OUT="${MOE_SEED_OUT:-$ROOT/hermes-seed}"
PLACEHOLDER='@HERMES_ROOT@'
# The interpreter Hermes runs on. Upstream's lock covers 3.14 only
# ([tool.uv] environments); the store's pinned Python is what this names.
PYTHON_VERSION="3.14"
# Extras baked into the venv. With lazy installs off (configure-hermes.py
# apply_dependency_seal) this is the WHOLE feature set: an extra not listed
# here is refused at first use, never fetched. [all] is upstream's own "cannot
# be prepared on demand" set; the rest is what Moe's seed has always carried.
SEED_EXTRAS="${SEED_EXTRAS:-all messaging anthropic edge-tts voice}"
# pm tool packages (the fork's pm/lock.json). python is the venv's interpreter;
# node + npm run MCP servers and the WhatsApp bridge; uv is what pm itself
# needs for any explicit operation; ffmpeg, ripgrep and (since the 0.3.26
# pin) pnpm are the others pm calls REQUIRED — without them every launch
# warns "install out of sync" and a tool that wants one is refused (lazy installs are off). `chromium` (Chrome
# for Testing) is the browser lane. Up to the 0.3.25 pin this list named
# `agent-browser`, which pulled chromium in as its dependency; upstream's
# browser rewire (#143146, in since the 0.3.26 pin) removed agent-browser from
# pm/lock.json, browser_exec drives Chromium over CDP itself, and pm no
# longer knows the name. Slimming (below) still leaves Chromium out of the
# download; it is fetched on first launch, as before.
SEED_TOOLS="${SEED_TOOLS:-python node npm pnpm uv ffmpeg ripgrep chromium}"

die() { echo "✗ $1" >&2; exit 1; }

# ---- 0. which commit this is — BEFORE anything is destroyed -----------------
#
# **Order is the whole point of this block.** This refusal used to live after
# `rm -rf "$OUT"`, and its message said "Nothing was staged" about a directory
# it had just emptied. Every question that can refuse is asked while $OUT is
# still untouched.
[ -e "$SRC" ] || die "no Hermes checkout at $SRC — set HERMES_SOURCE to a clone of the fork"
if SEED_COMMIT="$(git -C "$SRC" rev-parse --verify -q HEAD 2>/dev/null)" \
   && [ "${#SEED_COMMIT}" = 40 ] && [ -d "$SRC/.git" -o -f "$SRC/.git" ]; then
  :
else
  # A source with no `.git` is a seed, and a seed cannot answer the two things
  # staging has to record about it: which commit it is (the output would
  # inherit a stamp nothing here derived), and what was pruned from it (a
  # pruned tree yields an EMPTY record while tests/ and docs/ are still absent,
  # which makes them look like something the user deleted). Since 0.3.13
  # `~/.hermes/hermes-agent` IS a seed on any Mac that has run Moe, so this is
  # the ordinary way to reach here, not an exotic one.
  die "$SRC is not a git checkout — it is a seed, or a copy of one.
  A seed cannot be staged into a seed: the stamp would be inherited rather than
  derived, and the prune record would come out empty while the pruned directories
  are still missing, which makes every one of them look like something the user
  deleted. **Nothing was touched** — $OUT is exactly as it was.
  Point HERMES_SOURCE at a clone of the fork at the commit you want shipped:
      HERMES_SOURCE=~/hermes-agent-fork ./scripts/stage-hermes-seed.sh
  Note that scripts/install-hermes.sh does NOT build one: on a Mac that already
  has a seed it refreshes in place (or lays the bundled seed) and never creates a .git."
fi
for f in pyproject.toml uv.lock pm/lock.json pm/build_env.py scripts/write_install_stamp.py; do
  git -C "$SRC" cat-file -e "HEAD:$f" 2>/dev/null || die "$SRC at ${SEED_COMMIT:0:10} has no $f — that is not a Hermes this seed knows how to build
  (the pm package manager arrived with upstream 27df3b8847). Nothing was touched."
done

UV="${MOE_UV:-}"
if [ -z "$UV" ]; then
  if [ -x "$HOME/.local/bin/uv" ]; then UV="$HOME/.local/bin/uv"; else UV="$(command -v uv || true)"; fi
fi
[ -n "$UV" ] && [ -x "$UV" ] || die "no uv (looked in ~/.local/bin and PATH) — it fetches the Python that runs pm during the build. Nothing was touched."

echo "› seeding Hermes ${SEED_COMMIT:0:10} from $SRC"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/moe-seed-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$OUT"
mkdir -p "$OUT/hermes-agent"

# ---- 1. the code: tracked files at the commit, nothing else -----------------
# `git archive`, not a copy of the working tree: an untracked file, a local
# edit, a stray .env or a test's leftovers in the source checkout cannot reach
# the seed, because they are not in the commit.
git -C "$SRC" archive --format=tar "$SEED_COMMIT" | tar -x -C "$OUT/hermes-agent" \
  || die "git archive of ${SEED_COMMIT:0:10} failed"
printf '%s\n' "$SEED_COMMIT" > "$OUT/hermes-agent/.moe-seed-commit"
echo "  commit ${SEED_COMMIT:0:7} recorded in hermes-agent/.moe-seed-commit"
# What hermes-agent carried before anything was pruned (see §2z).
SEED_TOP_BEFORE="$(ls -A "$OUT/hermes-agent" 2>/dev/null | grep -vx '.moe-seed-commit' | sort)"

# ---- 1b. the tool store and the sealed venv ---------------------------------
# pm's state, caches and HOME all live in $WORK for the build, so nothing is
# written to the builder's ~/.hermes. HERMES_RUNTIME_DIR is pm's "this is the
# store" switch; pointing it at $OUT/tools is how upstream's payload builder
# stages a store it ships (scripts/bundles/native.py stage_native).
BUILD_ENV=(env -u PYTHONPATH -u VIRTUAL_ENV -u UV_PYTHON
           HOME="$WORK/home" HERMES_HOME="$WORK/home/.hermes"
           HERMES_RUNTIME_DIR="$OUT/tools"
           XDG_CACHE_HOME="$WORK/cache" XDG_CONFIG_HOME="$WORK/config"
           UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
           UV_PYTHON_INSTALL_DIR="$WORK/uv-python"
           PYTHONDONTWRITEBYTECODE=1)
mkdir -p "$WORK/home/.hermes" "$WORK/cache" "$WORK/config"

build_seed() {
  # A test can stand in for the network half (pm + PyPI) with a script that
  # lays down the same shape: $1 = the checkout, $2 = the store, $3 = the venv.
  if [ -n "${MOE_SEED_BUILDER:-}" ]; then
    "$MOE_SEED_BUILDER" "$OUT/hermes-agent" "$OUT/tools" "$OUT/hermes-agent/.venv"
    return
  fi
  # pm needs a Python to run on before the store has one; any 3.14 does.
  local boot
  boot="$("${BUILD_ENV[@]}" "$UV" python find --managed-python "$PYTHON_VERSION" 2>/dev/null || true)"
  if [ -z "$boot" ]; then
    "${BUILD_ENV[@]}" "$UV" python install "$PYTHON_VERSION" >"$WORK/uv-python.log" 2>&1 \
      || { cat "$WORK/uv-python.log" >&2; die "could not fetch a Python $PYTHON_VERSION to run pm"; }
    boot="$("${BUILD_ENV[@]}" "$UV" python find --managed-python "$PYTHON_VERSION")"
  fi
  echo "  tools: $SEED_TOOLS (pm, pinned and sha256-checked by the fork's pm/lock.json)"
  local tools_py
  tools_py="import sys; from pathlib import Path; from pm import prepare_tools, current_target; prepare_tools(sys.argv[1:], out=Path('$OUT/tools'), target=current_target())"
  # shellcheck disable=SC2086
  (cd "$OUT/hermes-agent" && "${BUILD_ENV[@]}" PYTHONPATH="$OUT/hermes-agent" "$boot" -c "$tools_py" $SEED_TOOLS) \
    || die "pm could not stage the tool store"
  local store_py
  store_py="$(ls -d "$OUT"/tools/python-"$PYTHON_VERSION".*/bin/python"$PYTHON_VERSION" 2>/dev/null | head -1)"
  [ -x "$store_py" ] || die "the tool store has no python$PYTHON_VERSION — SEED_TOOLS must include python"
  local extra_args=() e
  for e in $SEED_EXTRAS; do extra_args+=(--extra "$e"); done
  echo "  venv: pm.build_env --sealed, extras: $SEED_EXTRAS"
  (cd "$OUT/hermes-agent" && "${BUILD_ENV[@]}" PYTHONPATH="$OUT/hermes-agent" "$boot" -m pm.build_env \
      --source "$OUT/hermes-agent" --python "$store_py" --out "$OUT/hermes-agent/.venv" \
      --sealed "${extra_args[@]}") >"$WORK/build-env.log" 2>&1 \
    || { tail -40 "$WORK/build-env.log" >&2; die "pm.build_env could not build the sealed venv"; }
}
build_seed

# ---- 1b2. the store, slimmed for the download ---------------------------------
# Chromium (330 MB) leaves — Memoe's installer fetches the same pinned build on
# first launch (scripts/fetch-hermes-browser.sh) — and so do headers, man
# pages and static archives nothing reads at run time. pm's digests for the
# touched entries are recomputed, so the store does not read as damaged.
# scripts/slim-hermes-tools.py says what and why; it leaves tools/.browser-pending.
echo "  slimming the tool store:"
store_py="$(ls -d "$OUT"/tools/python-"$PYTHON_VERSION".*/bin/python"$PYTHON_VERSION" 2>/dev/null | head -1)"
(cd / && "${BUILD_ENV[@]}" PYTHONPATH="$OUT/hermes-agent" "${store_py:-python3}" \
    "$ROOT/scripts/slim-hermes-tools.py" "$OUT/tools") || die "could not slim the tool store"
[ -z "$(ls -d "$OUT"/tools/chromium-* 2>/dev/null)" ] || die "Chromium is still in the seed's tool store"
[ -f "$OUT/tools/.browser-pending" ] || die "the slimmed store has no .browser-pending marker"

VENV="$OUT/hermes-agent/.venv"
[ -x "$VENV/bin/hermes" ] || die "the venv has no bin/hermes — the project itself was not installed"
SITEP="$(ls -d "$VENV"/lib/python3.*/site-packages 2>/dev/null | head -1)"
[ -d "$SITEP" ] || die "the venv has no site-packages"
PYV="$(basename "$(dirname "$SITEP")")"           # e.g. python3.14
[ "$PYV" = "python$PYTHON_VERSION" ] || die "the venv is $PYV, not python$PYTHON_VERSION"

# The store's interpreter: what pyvenv.cfg's `home` names. Read, never assumed,
# because everything below depends on it being INSIDE $OUT: the seed carries
# tools/, and a venv whose home points anywhere else works on the build Mac
# and on no other.
VENV_HOME="$(sed -n 's/^home *= *//p' "$VENV/pyvenv.cfg" | head -1)"
case "$VENV_HOME" in
  "$OUT"/tools/*) ;;
  *) die "the venv's interpreter is at '$VENV_HOME', outside $OUT/tools — a seed made from it would not run anywhere else" ;;
esac
PYROOT="$(dirname "$VENV_HOME")"
[ -f "$PYROOT/bin/$PYV" ] || die "$PYROOT/bin/$PYV is missing — the seed has no interpreter to link to"

# ---- 1c. Memoe, not Hermes, updates this tree --------------------------------
# install-stamp.json is upstream's declaration of who replaces a tree.
# `external` means a steward does (Docker, Nix — here, Memoe's own update):
# no dependency sync or re-exec at launch, no `hermes update`, no launchers
# written into ~/.local/bin. Without it a seeded tree is "unknown" and
# install-hermes.sh would have to guess.
# The writer fills branch, dirty and the commit date from `git` of the tree it
# sits in — and the snapshot has no .git, so git would walk UP and describe
# whatever repository $OUT happens to be inside (this repo: "dirty", Moe's
# branch). GIT_CEILING_DIRECTORIES stops that walk; the date comes from the
# source commit itself.
env GIT_CEILING_DIRECTORIES="$OUT" "$VENV/bin/python" "$OUT/hermes-agent/scripts/write_install_stamp.py" \
  --output "$OUT/hermes-agent/install-stamp.json" --commit "$SEED_COMMIT" \
  --commit-date "$(git -C "$SRC" log -1 --format=%ct "$SEED_COMMIT")" \
  --source memoe --update-mechanism external >/dev/null \
  || die "could not write hermes-agent/install-stamp.json"
command grep -q '"dirty": false' "$OUT/hermes-agent/install-stamp.json" \
  || die "install-stamp.json calls the seed dirty — it described some other repository"
grep -q '"updateMechanism": "external"' "$OUT/hermes-agent/install-stamp.json" \
  || die "install-stamp.json does not say updateMechanism external"

# ---- 1d. the tree is wired to its venv by a RELATIVE .pth -------------------
# A sealed build deletes uv's __editable__ pointer (it names this machine), the
# same as upstream's payload; this is the line upstream writes in its place
# (scripts/bundles/native.py `hermes-agent.pth`). Relative, so the seed moves.
python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
  "$OUT/hermes-agent" "$SITEP" > "$SITEP/hermes-agent.pth"

# ---- 2. prune what is large, personal, or rebuilt on demand ------------------
prune() {
  find "$OUT" -name "$1" -print0 2>/dev/null | xargs -0 rm -rf 2>/dev/null || true
}
prune '__pycache__'
prune '.pytest_cache'
prune '.pytest-cache'
prune '.git'
prune '.github'
prune '.claude'
prune '.DS_Store'
prune '*.pyc'
prune '.env'
prune '.env.lock'
prune '.env.example'
prune '.envrc'

# Whole directories an installed runtime never reads. Each is also a source of
# false positives for the gate below — Hermes's own test fixtures are full of
# dummy `xoxb-` and `sk-` tokens — and the right answer to that is to stop
# shipping them, not to soften the gate. apps/ is the Electron desktop app and
# its installers, which Memoe is instead of.
for dead in \
  hermes-agent/tests \
  hermes-agent/tests-js \
  hermes-agent/website \
  hermes-agent/docs \
  hermes-agent/examples \
  hermes-agent/benchmarks \
  hermes-agent/evals \
  hermes-agent/apps
do
  rm -rf "${OUT:?}/$dead"
done

# Tests inside site-packages are dead weight in a shipped runtime. Scoped to
# directories literally named "tests" or "test" under site-packages, so a
# package called "pytest" or a module named "testing" is untouched.
find "$OUT" -type d \( -name tests -o -name test \) -path '*/site-packages/*' -print0 2>/dev/null \
  | xargs -0 rm -rf 2>/dev/null || true

# googleapiclient ships a cached copy of Google's API discovery document for
# every Google API that exists — 94 MB, of which Moe uses six. When a document
# is absent the client fetches it over the network instead, and every one of
# these APIs is a network call anyway.
DISCO="$SITEP/googleapiclient/discovery_cache/documents"
if [ -d "$DISCO" ]; then
  find "$DISCO" -type f -name '*.json' \
    ! -name 'gmail.*' ! -name 'calendar.*' ! -name 'drive.*' \
    ! -name 'docs.*'  ! -name 'sheets.*'   ! -name 'people.*' \
    -delete 2>/dev/null || true
fi

# ── The local-Whisper speech stack: Moe cannot reach it ─────────────────────
# `faster-whisper` transcribes audio in Python, and it drags `onnxruntime`,
# PyAV and `ctranslate2` behind it. Moe never calls any of it: transcription
# is Swift, on the Neural Engine. With lazy installs off, a Hermes feature that
# asks for it is refused rather than fetched — which is the point.
for gone in onnxruntime av ctranslate2 faster_whisper hf_xet; do
  rm -rf "${SITEP:?}/$gone"
  find "$SITEP" -maxdepth 1 -type d \
    \( -name "${gone}-*.dist-info" -o -name "$(printf '%s' "$gone" | tr '_' '-')-*.dist-info" \) \
    -exec rm -rf {} + 2>/dev/null || true
done

# ── One interpreter, and the venv must LINK to it ──────────────────────────
#
# A python-build-standalone binary copied out of its prefix cannot find its
# own standard library. It falls back to the prefix compiled into it,
# `/install`, and dies before it runs a line of Python:
#
#     ModuleNotFoundError: No module named 'encodings'
#
# That shipped in 0.3.13: every download was a Moe that could not think.
# `scripts/check-hermes-seed-runs.sh` refuses it, by running the interpreter.
# So the venv reaches the store's one real binary by a RELATIVE symlink —
# relative because the seed is copied to ~/.hermes at first launch and an
# absolute link would point back into the app bundle, and because
# HermesSeed.substitute rewrites file contents, never link targets.
VBIN="$VENV/bin"
PYREL="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
         "$PYROOT/bin/$PYV" "$VBIN")"
rm -f "$VBIN/$PYV"
ln -s "$PYREL" "$VBIN/$PYV"
[ -x "$VBIN/$PYV" ] || die "the venv's interpreter link ($PYREL) does not resolve from $VBIN"
for c in python python3; do
  rm -f "$VBIN/$c"
  ln -s "$PYV" "$VBIN/$c"
done
# The tool store is pm's, and pm records what it installed by digest: nothing
# inside tools/ is pruned or relinked here, so `hermes pm doctor` on a user's
# Mac reads the same entries pm staged.

# ---- 2z. write down what the pruning removed ---------------------------------
# Derived by comparing before with after, never a second copy of the prune list
# above. Top level of hermes-agent only: that is the granularity
# refresh-hermes-seed.sh's pruned_top asks about.
{
  comm -23 <(printf '%s\n' "$SEED_TOP_BEFORE") \
           <(ls -A "$OUT/hermes-agent" 2>/dev/null | sort)
} > "$OUT/hermes-agent/.moe-seed-pruned"
echo "  $(grep -c . "$OUT/hermes-agent/.moe-seed-pruned" 2>/dev/null || echo 0) top-level entr(ies) recorded in hermes-agent/.moe-seed-pruned"

# ---- 3. make it path-independent ---------------------------------------------
echo "› rewriting absolute paths to $PLACEHOLDER"
# One Python pass over the tree. Text-ness is decided by trying to decode,
# which is the real question; a file that is not valid UTF-8 and still names
# the build path is fatal, because a substitution would change its length.
python3 - "$OUT" "$PLACEHOLDER" <<'PYEOF'
import os, sys

out, ph = sys.argv[1:3]
# Everything was built in place, so $OUT is the one path to replace: the
# shebangs name $OUT/hermes-agent/.venv/bin/python, pyvenv.cfg names
# $OUT/tools/python-…/bin, direct_url.json names $OUT/hermes-agent.
real = os.path.realpath(out)
subs = sorted({out, real}, key=len, reverse=True)
rewritten = 0
binary = []
for root, dirs, files in os.walk(out):
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path):
            continue
        try:
            if os.path.getsize(path) > 8_000_000:
                continue
            with open(path, "rb") as f:
                raw = f.read()
        except OSError:
            continue
        if not any(k.encode() in raw for k in subs):
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            binary.append(path)
            continue
        for old in subs:
            text = text.replace(old, ph)
        mode = os.stat(path).st_mode
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(path, mode)
        rewritten += 1

print("  rewrote %d file(s)" % rewritten)
if binary:
    for p in binary[:5]:
        print("  ! binary embeds the build path: %s" % p, file=sys.stderr)
    print("✗ %d binary file(s) contain this machine's path and cannot be rewritten"
          % len(binary), file=sys.stderr)
    sys.exit(1)
PYEOF

# ---- 4. the gate -------------------------------------------------------------
# Two scans, because they answer two different questions.
#
# The first is about *this builder* and is fatal anywhere in the tree: a home
# directory, the build directory, a company name, an email. One hit means the
# rewrite above did not finish. Binaries included (`--binary-files=text`):
# plain `-I` skips them, which is the one class the rewrite cannot repair.
#
# The second looks for real credentials and is scoped to code we control.
echo "› checking the seed carries nothing personal"
leak=0
for needle in "$OUT" "$WORK" "$HOME"; do
  found=$(grep -rl --binary-files=text -F "$needle" "$OUT" 2>/dev/null | head -5 || true)
  if [ -n "$found" ]; then
    echo "✗ '$needle' is still in the seed:" >&2
    printf '%s\n' "$found" | sed 's/^/    /' >&2
    leak=1
  fi
done
for marker in ${MOE_SEED_PII_MARKERS:-}; do
  if [ -n "$(grep -rIlF "$marker" "$OUT" 2>/dev/null | head -3)" ]; then
    echo "✗ '$marker' is in the seed:" >&2
    grep -rIlF "$marker" "$OUT" 2>/dev/null | head -3 | sed 's/^/    /' >&2
    leak=1
  fi
done

# A key rather than the *mention* of one: a PEM block is a delimiter followed
# by a body of base64; a token is long, mixed, and not a row of placeholder
# characters. Vendored trees (site-packages, node_modules, the tool store)
# are third-party source published in this same form by their own authors.
python3 - "$OUT" <<'PYEOF' || leak=1
import os, re, sys

out = sys.argv[1]
VENDORED = re.compile(r"/(site-packages|node_modules|\.venv|tools)/")
PEM = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----[^\n]*\n[A-Za-z0-9+/=\s]{0,80}?[A-Za-z0-9+/=]{40}")
TOKEN = re.compile(r"\b(sk-(?:ant-)?[A-Za-z0-9_-]{24,}|ghp_[A-Za-z0-9]{30,}|xox[baprs]-[0-9]{6,}-[A-Za-z0-9-]{6,})\b")
PLACEHOLDER = re.compile(r"(.)\1{7,}|example|placeholder|your[-_]?(key|token)|xxxx", re.I)

hits = []
for root, dirs, files in os.walk(out):
    for name in files:
        path = os.path.join(root, name)
        if VENDORED.search(path) or os.path.islink(path):
            continue
        try:
            if os.path.getsize(path) > 4_000_000:
                continue
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except (OSError, UnicodeDecodeError):
            continue
        if PEM.search(text):
            hits.append(("a private key", path))
            continue
        for m in TOKEN.finditer(text):
            if not PLACEHOLDER.search(m.group(0)):
                hits.append(("an API token", path))
                break

for what, path in hits[:10]:
    print("✗ %s is in the seed: %s" % (what, path), file=sys.stderr)
sys.exit(1 if hits else 0)
PYEOF
[ "$leak" = 0 ] || die "the seed is not shippable"

# ---- 5. report ---------------------------------------------------------------
SIZE=$(du -sm "$OUT" | cut -f1)
BINS=$(find "$OUT" \( -name '*.so' -o -name '*.dylib' \) 2>/dev/null | wc -l | tr -d ' ')
echo
echo "✓ seed staged at $OUT (Hermes ${SEED_COMMIT:0:10}, Python $PYTHON_VERSION)"
echo "  size:            ${SIZE} MB  ($(du -sm "$OUT/hermes-agent" | cut -f1) MB code + venv, $(du -sm "$OUT/tools" | cut -f1) MB tools)"
echo "  Mach-O to sign:  ${BINS}+ (release.sh signs every Mach-O under the seed)"
echo "  build.sh copies it into Contents/Resources/hermes-seed"
