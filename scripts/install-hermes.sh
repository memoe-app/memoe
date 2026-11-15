#!/bin/bash
# Installs Hermes — Moe's core — with no questions asked. Idempotent: run it
# again and every step says "already" and changes nothing.
#
#   1. uv        pinned release, installer sha256-checked, into ~/.local/bin
#   2. Python    3.14, uv-managed (no Homebrew, no Xcode)
#   3. checkout  Izzy-Gottz/hermes-agent @ claude-code-runtime → ~/.hermes/hermes-agent
#                (existing checkout: fetch + fast-forward only; a dirty tree stops us)
#   4. venv      uv sync --locked in that checkout; `hermes` wrapper → ~/.local/bin
#   5. smoke     hermes --version, hermes doctor; then configure-hermes.py --check
#   6. cua-driver  the computer_use backend, so Moe can see and act on the
#                screen and be told whether it worked (the fallback cannot)
#   7. tools     Hermes's pm tool store ($HERMES_HOME/tools): node, npm, uv,
#                ffmpeg, ripgrep, the browser — Hermes looks nowhere else
#
# A seeded Mac (no .git) is refreshed to the pin, or — when the pin changes
# what the venv contains — given the seed this Memoe carries
# (scripts/reseed-hermes.sh, MOE_HERMES_SEED_BUNDLE).
#
# Every step prints ✓ or ✗ with a one-line reason; the full output of every
# command is in ~/.moe/logs/install-hermes.log. Exit 0 = Hermes is installed
# (the --check at the end may still list what configure-hermes.py has yet to
# do; that is the next step, not a failure of this one).
#
# Network trouble: a local TLS-inspecting proxy (Canopy and friends on
# 127.0.0.1) breaks uv's own certificate store and git's proxy discovery.
# Each network step is tried plainly first, then once more with
# NO_PROXY='*' UV_NATIVE_TLS=1 UV_SYSTEM_CERTS=1 (bypass the proxy, use the macOS keychain
# roots), and the ✗/✓ line says which one worked.
#
# Overrides (all optional; the tests use them to keep the real ~ untouched):
#   MOE_HOME       ~/.moe          log location, configure-hermes.py copy
#   HERMES_HOME    ~/.hermes       where hermes-agent/ goes; exported to hermes
#   MOE_BIN_DIR    ~/.local/bin    uv, uvx and the hermes wrapper
#   HERMES_FORK    https://github.com/Izzy-Gottz/hermes-agent
#   HERMES_BRANCH  claude-code-runtime
#   HERMES_COMMIT  the exact sha to install ("" follows the branch tip)
#   HERMES_EXTRAS  "all messaging anthropic edge-tts voice"  uv extras to sync
#                  (the seed's set: stage-hermes-seed.sh SEED_EXTRAS)
#   UV_PYTHON_INSTALL_DIR / UV_CACHE_DIR  passed through to uv (for tests)
set -euo pipefail

MOE_HOME="${MOE_HOME:-$HOME/.moe}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
MOE_BIN_DIR="${MOE_BIN_DIR:-$HOME/.local/bin}"
HERMES_FORK="${HERMES_FORK:-https://github.com/Izzy-Gottz/hermes-agent}"
HERMES_BRANCH="${HERMES_BRANCH:-claude-code-runtime}"
# The exact commit this build of Moe installs. Until 2026-08-31 this script
# took whatever the branch tip happened to be, which meant two people who
# installed on different days got different brains, and a bug report named a
# version that no longer existed. DISTRIBUTION.md §4 called that out as "right
# while the fork is ours and moves daily, wrong for a shipped product".
#
# Bump it deliberately: run the fork's tests, then paste the sha here. Set
# HERMES_COMMIT="" to follow the branch tip again — that is a development
# convenience and the script says so out loud when it happens.
#
# ── Before you bump it, check whether the range moves uv.lock ────────────────
#
# A fresh install gets whatever this names. An EXISTING install is a seed —
# `~/.hermes/hermes-agent` has no `.git` since 0.3.13 — and it is moved forward
# by scripts/refresh-hermes-seed.sh, which refreshes tracked source and never
# rebuilds a venv. So a bump whose range touches `uv.lock`, `pyproject.toml` or
# `.python-version` REACHES NOBODY WHO ALREADY HAS MOE: the refresh refuses it,
# by design, because rebuilding the venv there would replace the interpreter.
#
# That refusal is loud on the user's Mac and silent to you, which is the wrong
# way round — CLAUDE.md moved install-override notices off the owner's island
# for exactly this reason. So ask before you paste:
#
#   git -C <fork> diff --name-only <old-pin> <new-pin> -- uv.lock pyproject.toml .python-version
#
# Anything printed means existing Macs need a re-seed and a release, not just a
# pin bump. Nothing printed means the bump reaches everyone.
# 2026-11-12, for 0.3.25: the pin is the fork's merge of upstream up to
# 1b0f071dbbf (staged catch-up steps 1-3) and it is published on the fork as
# the branch `memoe/0.3.25`, NOT yet on `claude-code-runtime`. The old pin is
# an ancestor of it, so moving `claude-code-runtime` there is a plain
# fast-forward — and until someone does, the one path below that insists the
# pin is in $remote/$HERMES_BRANCH (an existing .git checkout, which no Mac
# running a shipped Memoe has had since 0.3.13) refuses. Seeds, fresh clones,
# deploy.sh and refresh-hermes-seed.sh fetch the sha itself and do not care.
# This range moves uv.lock, pyproject.toml and pm/lock.json: it reaches
# existing Macs only through the re-seed a release carries.
# fa8a2f898d (on top of 4b10e410aa): an api_server turn run by the session
# authority keeps X-Hermes-Turn-Origin, -Person-Words and -Voice-Turn. Without
# it every Memoe turn on the merged gateway was nobody's: no spoken quick open,
# no claimstore learning, no person words for recipient grounding.
# b62f5983d6 (on top of fa8a2f898d): the Chrome Web Store build of the
# extension (nmdhnfjfpipnjbfbiligpbdnpfdkojjn) is trusted beside the unpacked
# dev id, by the host manifest and the relay; lane_status says why the lane is
# unusable; extension 0.2.2 shows a red "!" when it cannot reach the host.
# 782ecedbc8 (on top of b62f5983d6): the cloud computer's kept browser
# (docs/AWAY-BROWSER.md) is the OOM killer's first choice, launches small, caps
# its tabs and holds a memory floor, and never clicks, holds or solves a
# CAPTCHA (browser.captcha.hands_off). On every lane, a Mac's too: the attach
# no longer asks agent-browser for its cdp-url, which launched a second,
# throwaway Chrome beside the driven one for the life of the daemon.
# ee552f2952 (merge on top of 782ecedbc8): a `pre_cron_run` plugin hook, asked
# first in every cron fire, so moe-screen can claim each run on the edge before
# the Mac fires it (owner decision D4, 2026-11-13). Code only: no lock moves.
# 1d8ecafda5 (on top of ee552f2952): X-Hermes-No-Memory, bound like the turn
# origin, for Memoe's "Don't remember this chat": the built-in memory tool refuses
# every write in that turn and no background memory review is spawned; plugins
# read gateway.session_context.get_turn_no_memory(). Code only: no lock moves.
# 117f524bdd (on top of 1d8ecafda5): the engine's own notices in plain words
# (no "Hermes", no commands), the startup "I'm back" ping behind the same
# diagnostics gate as the shutdown notice, and "low disk" relative to the
# volume — a 2 GB Away disk with 1.7 GB free was "low". Code only: no lock moves.
# c03680cd35 (on top of 117f524bdd): a relayed channel with no adapter here
# (Memoe's `moemail`) keeps its own name instead of becoming "relay", so its
# turns are the person talking. Code only: no lock moves.
# 2026-11-13, for 0.3.26: Hermes v0.23.1. The pin is the fork's merge of the
# 0.3.25 line (up to c03680cd35) with upstream's browser rewire (#143146,
# staged catch-up step 4) and the stable tag v0.23.1 (3b42157858, step 5),
# published as the branch `memoe/0.3.26`, NOT yet on `claude-code-runtime`
# (that branch's tip is an ancestor, so moving it there is a fast-forward;
# the .git-checkout path below fetches a pin from any fork branch).
# Upstream retired agent-browser: browser_exec drives pm's Chromium over CDP,
# so SEED_TOOLS / PM_TOOLS carry `chromium` (and `pnpm`, now required).
# This range moves uv.lock, pyproject.toml and pm/lock.json: it reaches
# existing Macs only through the re-seed a release carries.
# 8b18fb186a (on top of 5ee5f7634b): the 16 translations of the cron-interrupted
# notice follow the plain English one, which dropped {action} in 117f524bdd.
# Locales only: no lock moves.
# 169f94d2d2 (on top of 8b18fb186a): the engine image's runtime stage stages
# pnpm too, which pm.activate() calls required — the Away image answered every
# launch and `hermes doctor` with "install out of sync (pnpm: …)" without it.
# Dockerfile only: no lock moves, and nothing a Mac's seed carries changes.
# eaba0dfe9c (on top of 169f94d2d2): a relayed message from Memoe's catch-all
# connector (one generic `relay` hello, raw secret, no GATEWAY_RELAY_ID) is
# admitted again. v0.23.1 refused every one permission_denied, so the Mac
# dropped Telegram DMs with no reply. Code only: no lock moves.
HERMES_COMMIT="${HERMES_COMMIT-eaba0dfe9c72c57d3dcaba5c371445cf269d11d8}"
# The same set the seed is built with (stage-hermes-seed.sh SEED_EXTRAS). Since
# the 3.14 line Hermes no longer installs an extra on first use here — lazy
# installs are off — so what is not synced now is a feature that is refused.
# And upstream dropped PyYAML from its core: Moe's configure-hermes.py and
# plugins import `yaml`, which arrives only through these extras (uvicorn's
# standard set in [all], huggingface_hub in [voice]).
HERMES_EXTRAS="${HERMES_EXTRAS:-all messaging anthropic edge-tts voice}"
PYTHON_VERSION="3.14"
AGENT_DIR="$HERMES_HOME/hermes-agent"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# uv release pin. The installer script is downloaded from the release itself
# (not astral.sh, which always serves the newest) and checked against this
# sha256 before it runs. The installer in turn carries the sha256 of every
# platform tarball and verifies it — but only if a `sha256sum` command exists,
# which macOS lacks, so a shim is put on its PATH (see install_uv). Bump both
# lines together: shasum -a 256 uv-installer.sh from the release page.
UV_VERSION="0.12.7"
UV_INSTALLER_SHA256="92e8554321e2bde08c9b1445dae47a65360f885274f31df51cdc2f9faa84e001"
UV_INSTALLER_URL="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-installer.sh"

# A short sha, a tag or a branch name would all "work" and none of them pins
# anything, so only a full sha is accepted. "" means follow the tip.
if [ -n "$HERMES_COMMIT" ]; then
  case "$HERMES_COMMIT" in *[!0-9a-f]*)
    echo "✗ HERMES_COMMIT must be a 40-character sha, got: $HERMES_COMMIT" >&2; exit 1 ;;
  esac
  if [ "${#HERMES_COMMIT}" -ne 40 ]; then
    echo "✗ HERMES_COMMIT must be a full 40-character sha, got ${#HERMES_COMMIT} characters" >&2; exit 1
  fi
  # Forty hex characters is a SHAPE. It says nothing about whether the fork
  # has that commit, and on 2026-09-03 it did not: a pin was moved to a
  # commit that existed only on one Mac, and every cloud image build died
  # with "upload-pack: not our ref" — two runs, including another session's,
  # before anyone noticed. A well-formed identifier that resolves to nothing
  # is more dangerous than an absent one, because absence is honest.
  #
  # Network-dependent, so it warns rather than refuses when it cannot ask:
  # a laptop on a plane must still be able to install. What it will not do
  # is stay quiet when it CAN ask and the answer is no.
  if command -v git >/dev/null 2>&1; then
    if remote_refs="$(git ls-remote "$HERMES_FORK" 2>/dev/null)"; then
      # A `case` and not `printf … | grep -q`. Under `set -o pipefail`,
      # grep -q exits the moment it matches, printf takes SIGPIPE, and the
      # PIPELINE reports failure — so a found sha read as not-found and this
      # check refused every correct pin. Same shape as the `./build.sh | grep`
      # line that let a broken bundle install this morning: the status of a
      # pipeline is not the status of the command you care about.
      #
      # `ls-remote` lists REF TIPS, and a pin is usually not one. This check
      # used to be that substring test alone, and it refused every correct pin
      # that was not currently the head of a branch — which is the normal
      # state of a pin, because the fork moves on after you take one. Measured
      # 2026-09-04: `fe4042986170…` was refused as "not on the fork" while
      # `git fetch --depth=1 <url> <sha>` fetched it in under a second. So the
      # refusal said "push the commit" about a commit that was already pushed:
      # an error naming the wrong cause, which is the same family as the bug
      # this pin bump was fixing in `auxiliary_client.py`, and worse than
      # silence because it sends the reader somewhere there is nothing to find.
      #
      # The tip test stays as the fast path. When it misses, ask the question
      # that actually matters by DOING the thing the install will do — a
      # shallow fetch of that exact sha into a throwaway directory. A
      # falsifier for "can this be fetched" has to be a fetch.
      case "$remote_refs" in
        *"$HERMES_COMMIT"*) : ;;
        *)
        pin_probe="$(mktemp -d)"
        if git -C "$pin_probe" init -q . 2>/dev/null &&
           git -C "$pin_probe" fetch -q --no-tags --depth=1 "$HERMES_FORK" "$HERMES_COMMIT" 2>/dev/null; then
          rm -rf "$pin_probe"
        else
          rm -rf "$pin_probe"
          echo "✗ HERMES_COMMIT $HERMES_COMMIT is not on $HERMES_FORK." >&2
          echo "  It is a real-looking sha that nothing can fetch, so every build" >&2
          echo "  from a fresh clone will fail. Push the commit, or move the pin" >&2
          echo "  back to one that is there." >&2
          echo "  (checked by fetching that sha, not by looking for it among" >&2
          echo "   the branch tips — a pin is usually not a tip.)" >&2
          exit 1
        fi ;;
      esac
    else
      echo "  (could not reach $HERMES_FORK to check the pin — carrying on)" >&2
    fi
  fi
fi

export HERMES_HOME
export UV_NO_CONFIG=1                # a stray ~/.config/uv/uv.toml can't redirect us
# The interpreter lives INSIDE the Hermes home. stage-hermes-seed.sh refuses a
# venv whose `home =` points anywhere else (a seed of it would run on no other
# Mac), and on a seeded Mac $HERMES_HOME/python is already where the seed put
# it — so `uv python find --managed-python` finds that copy and a re-sync keeps
# the venv stageable. Measured 2026-09-11: an app-driven re-sync with uv's
# default dir re-pointed the venv at ~/.local/share/uv/python and the next
# stage-hermes-seed.sh refused. Tests pass their own directory through.
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$HERMES_HOME/python}"
# And keep uv's `python3.x` link out of the person's ~/.local/bin, where
# `uv python install` puts one by default: that is a directory on their own
# PATH, and Hermes's interpreter has no business answering `python3.14` in
# their terminal. Found 2026-11-13 through this script's test, which leaked
# the same link into the developer's ~/.local/bin.
export UV_PYTHON_BIN_DIR="${UV_PYTHON_BIN_DIR:-$UV_PYTHON_INSTALL_DIR/bin}"
unset UV_PYTHON 2>/dev/null || true  # an inherited pin must not override PYTHON_VERSION

mkdir -p "$MOE_HOME/logs" "$MOE_BIN_DIR" "$HERMES_HOME"

# One installer at a time. Moe offers "Set it up" in two places — onboarding
# and Settings › Brain — and both windows can be open, so two runs can start
# against the same checkout. Two concurrent `git checkout -B` or `uv sync`
# runs corrupt it, and the recovery this script offers for a corrupt checkout
# is "move it aside and re-run", which nobody who downloaded an app is going
# to do. mkdir is the lock: it is atomic on every filesystem that matters.
LOCK="$HERMES_HOME/.install.lock"
LOCK_HELD=0
# The trap goes up *before* the lock is taken. It used to be installed sixty
# lines later, so anything that ended the shell in between — a full disk on
# the first write to the log, a signal when the app's "Set it up" process is
# killed — left the directory behind and every run for the next hour said
# "Moe is already setting this up".
lock_cleanup() { [ "$LOCK_HELD" = 1 ] && rmdir "$LOCK" 2>/dev/null; return 0; }
trap lock_cleanup EXIT
if mkdir "$LOCK" 2>/dev/null; then
  LOCK_HELD=1
else
  # A lock older than an hour belonged to a run that died; this install takes
  # about a minute and a half.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    # Rename-then-claim rather than rmdir-then-mkdir: two runs that both see
    # the same stale lock can otherwise interleave so that the second removes
    # the *fresh* lock the first just took, and both proceed.
    stale="$LOCK.stale.$$"
    if mv "$LOCK" "$stale" 2>/dev/null; then
      rmdir "$stale" 2>/dev/null || rm -rf "$stale" 2>/dev/null || true
    fi
    mkdir "$LOCK" 2>/dev/null || { echo "✗ another install is running (${LOCK})"; exit 1; }
    LOCK_HELD=1
  else
    echo "✗ Moe is already setting this up. Give it a minute — running it twice at once would break the install."
    exit 1
  fi
fi
LOG="$MOE_HOME/logs/install-hermes.log"
{ echo; echo "=== install-hermes $(date '+%Y-%m-%d %H:%M:%S') HERMES_HOME=$HERMES_HOME ==="; } >>"$LOG"

ok()   { printf '✓ %s\n' "$*"; echo "[$(date '+%H:%M:%S')] OK  $*" >>"$LOG"; }
fail() { printf '✗ %s\n' "$*"; echo "ERR $*" >>"$LOG"; echo "  (details: $LOG)"; exit 1; }
say()  { printf '› %s\n' "$*"; echo "--  $*" >>"$LOG"; }

# run CMD…  → stdout/stderr to the log, exit status returned.
run() { echo "[$(date '+%H:%M:%S')] \$ $*" >>"$LOG"; "$@" >>"$LOG" 2>&1; }

# Network commands: plain first, then the proxy-bypass variant. Sets
# NET_NOTE to say which worked, so the ✓ line can carry it.
NET_FALLBACK="${MOE_NET_FALLBACK:-0}"   # 1 = go straight to the bypass
NET_NOTE=""
net_run() {
  # The plain attempt gets a short leash: through a blocking proxy uv's
  # default (30 s × 3 retries) is 90 s of nothing before the retry can help.
  if [ "$NET_FALLBACK" = 0 ] && run env UV_HTTP_TIMEOUT=20 UV_HTTP_RETRIES=0 \
       GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20 "$@"; then NET_NOTE=""; return 0; fi
  local hint=""
  if [ "$NET_FALLBACK" = 0 ]; then
    if tail -n 40 "$LOG" | grep -qiE 'certificate|tls|ssl|proxy|handshake|connection (refused|reset)|could not connect|network'; then
      hint="TLS/proxy error"
    else
      hint="first attempt failed"
    fi
    echo "-- $hint; retrying with NO_PROXY='*' UV_NATIVE_TLS=1" >>"$LOG"
  fi
  if run env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy \
         NO_PROXY='*' no_proxy='*' UV_NATIVE_TLS=1 UV_SYSTEM_CERTS=1 "$@"; then
    NET_FALLBACK=1
    NET_NOTE=" (via proxy bypass: NO_PROXY='*' UV_NATIVE_TLS=1${hint:+ after $hint})"
    return 0
  fi
  NET_NOTE=" (${hint:-failed}; also failed with NO_PROXY='*' UV_NATIVE_TLS=1)"
  return 1
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
TMP_DIRS=()
# The lock goes here rather than in a trap of its own: this `trap cleanup EXIT`
# replaces any earlier one, so a second trap would simply never run — which is
# exactly what happened, and the second run then refused to start.
cleanup() {
  [ ${#TMP_DIRS[@]} -gt 0 ] && rm -rf "${TMP_DIRS[@]}"
  lock_cleanup
  return 0
}
trap cleanup EXIT

echo "Hermes install"
echo "──────────────"

# ---- 1. uv -----------------------------------------------------------------
UV=""
find_uv() {
  if [ -x "$MOE_BIN_DIR/uv" ]; then UV="$MOE_BIN_DIR/uv"
  elif command -v uv >/dev/null 2>&1; then UV="$(command -v uv)"
  else return 1; fi
}
install_uv() {
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/moe-uv.XXXXXX")"
  TMP_DIRS+=("$tmp")
  if ! net_run curl -fsSL --retry 1 --connect-timeout 20 --max-time 120 -o "$tmp/uv-installer.sh" "$UV_INSTALLER_URL"; then
    fail "uv: could not download $UV_INSTALLER_URL$NET_NOTE"
  fi
  local got; got="$(sha256_of "$tmp/uv-installer.sh")"
  if [ "$got" != "$UV_INSTALLER_SHA256" ]; then
    fail "uv: installer sha256 $got != pinned $UV_INSTALLER_SHA256 (uv $UV_VERSION) — not running it"
  fi
  # macOS has no sha256sum, and without it the installer skips its own
  # tarball check. Give it one so the embedded hash is actually verified.
  mkdir -p "$tmp/bin"
  printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' >"$tmp/bin/sha256sum"
  chmod +x "$tmp/bin/sha256sum"
  if ! PATH="$tmp/bin:$PATH" net_run env UV_INSTALL_DIR="$MOE_BIN_DIR" UV_NO_MODIFY_PATH=1 \
       sh "$tmp/uv-installer.sh"; then
    fail "uv: installer failed$NET_NOTE"
  fi
  [ -x "$MOE_BIN_DIR/uv" ] || fail "uv: installer finished but $MOE_BIN_DIR/uv is missing"
}
if find_uv; then
  ok "uv already installed: $("$UV" --version 2>/dev/null | head -1) at $UV"
else
  install_uv
  UV="$MOE_BIN_DIR/uv"
  ok "uv $UV_VERSION installed to $MOE_BIN_DIR (installer sha256 verified, tarball sha256 verified by installer)$NET_NOTE"
fi

# ---- 2. Python 3.14 ----------------------------------------------------------
# Only a checkout needs it: `uv sync` builds the venv on it. A seed (no .git)
# carries its interpreter in its own tool store, and a seed moving to another
# Python is laid from the bundle, not rebuilt — so on a seed this would only
# download an interpreter nothing uses (and, offline, fail the whole upgrade
# before it reached the step that needs no network).
if [ -e "$AGENT_DIR" ] && [ ! -e "$AGENT_DIR/.git" ]; then
  ok "Python: not needed here — $AGENT_DIR is a seed, which carries its own"
elif PY="$("$UV" python find --managed-python "$PYTHON_VERSION" 2>>"$LOG")" && [ -x "$PY" ]; then
  ok "Python already installed: $("$PY" --version 2>&1) (uv-managed) at $PY"
else
  if ! net_run "$UV" python install "$PYTHON_VERSION"; then
    fail "Python $PYTHON_VERSION: uv python install failed$NET_NOTE"
  fi
  PY="$("$UV" python find --managed-python "$PYTHON_VERSION" 2>>"$LOG")" \
    || fail "Python $PYTHON_VERSION: installed but uv python find cannot see it"
  ok "Python installed: $("$PY" --version 2>&1) (uv-managed, no Homebrew/Xcode)$NET_NOTE"
fi

# ---- 3. The fork checkout ----------------------------------------------------
# Following the tip is a development mode, so it is said out loud: a build that
# ships this way cannot be reproduced tomorrow.
[ -n "$HERMES_COMMIT" ] || echo "› HERMES_COMMIT is empty: following the tip of $HERMES_BRANCH (not reproducible)"
git_q() { git -C "$AGENT_DIR" "$@"; }
# What the tree is at when step 4 asks. A checkout answers with git; a seed
# answers with its stamp, and there is no third kind.
HEAD_SHA=""
IS_SEED=0
if [ -d "$AGENT_DIR/.git" ]; then
  if ! git_q rev-parse --verify -q HEAD >/dev/null 2>&1; then
    fail "hermes-agent: $AGENT_DIR has a .git but no commits (an interrupted clone?) — rm -rf it and re-run"
  fi
  branch="$(git_q rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  if [ "$branch" != "$HERMES_BRANCH" ]; then
    fail "hermes-agent: $AGENT_DIR is on branch '$branch', not '$HERMES_BRANCH' — switch it yourself; this script only fast-forwards that branch"
  fi
  if [ -n "$(git_q status --porcelain --untracked-files=normal 2>>"$LOG")" ]; then
    fail "hermes-agent: $AGENT_DIR has local changes (git status is not clean) — commit, stash or discard them, then re-run; nothing was reset"
  fi
  # Which remote is the fork? The hand-made install calls it `fork`, a clone
  # by this script calls it `origin`. Add one if neither matches.
  remote="$(git_q remote -v | awk -v u="$HERMES_FORK" '$2==u || $2==u".git" {print $1; exit}')"
  if [ -z "$remote" ]; then
    remote="moe-fork"
    run git_q remote add "$remote" "$HERMES_FORK" || fail "hermes-agent: could not add remote $HERMES_FORK"
  fi
  before="$(git_q rev-parse HEAD)"
  MOVED_BACK=0
  # Already exactly where the pin says? Then the fetch is not worth a network
  # round trip, and an offline machine re-runs the installer without failing.
  if [ -n "$HERMES_COMMIT" ] && [ "$before" = "$HERMES_COMMIT" ]; then
    ok "hermes-agent already at the pinned ${HERMES_COMMIT:0:7}"
  else
    if ! net_run git -C "$AGENT_DIR" fetch --quiet "$remote" "$HERMES_BRANCH"; then
      fail "hermes-agent: git fetch $remote $HERMES_BRANCH failed$NET_NOTE"
    fi
    # The pin need not be on $HERMES_BRANCH: since 0.3.25 a release's pin is
    # published on the fork as `memoe/<version>` first, and the default branch
    # catches up later. So when the fetch above did not bring the pinned
    # commit, ask the fork for the commit itself, and refresh the other
    # branches so "already on the remote" below can see where it lives.
    if [ -n "$HERMES_COMMIT" ] && ! git_q cat-file -e "$HERMES_COMMIT^{commit}" 2>/dev/null; then
      net_run git -C "$AGENT_DIR" fetch --quiet "$remote" 2>>"$LOG" || true
      git_q cat-file -e "$HERMES_COMMIT^{commit}" 2>/dev/null \
        || net_run git -C "$AGENT_DIR" fetch --quiet "$remote" "$HERMES_COMMIT" 2>>"$LOG" || true
    fi
    # Where the checkout should end up, decided explicitly rather than by
    # asking merge to work it out.
    #
    # `git merge --ff-only <ancestor>` *succeeds* — "Already up to date" — so
    # a checkout that had run ahead of the pin sailed through the merge and
    # stayed exactly where it was, with the script reporting success. The four
    # cases are named here instead:
    #
    #   at the pin      nothing to do
    #   behind it       fast-forward, the ordinary update
    #   ahead of it     move the branch pointer back; the tree was checked
    #                   clean above, so nothing of anyone's is discarded, and
    #                   `hermes update` or a downgraded Moe lands here
    #   diverged        stop, and reset nothing
    target="${HERMES_COMMIT:-$remote/$HERMES_BRANCH}"
    if ! git_q cat-file -e "$target^{commit}" 2>>"$LOG"; then
      fail "hermes-agent: $target is not on $remote — is the pin pushed? (HERMES_COMMIT in $(basename "$0"))"
    fi
    target_sha="$(git_q rev-parse "$target^{commit}")"
    if [ "$before" = "$target_sha" ]; then
      :
    elif git_q merge-base --is-ancestor HEAD "$target_sha" 2>/dev/null; then
      if ! run git_q merge --ff-only "$target_sha"; then
        fail "hermes-agent: could not fast-forward to ${target_sha:0:7}"
      fi
    elif git_q merge-base --is-ancestor "$target_sha" HEAD 2>/dev/null; then
      # Ahead of the pin. Moving the branch pointer back is only safe when
      # every commit it would leave behind is already on the remote — then
      # nothing is lost, it is just not what this build installs.
      #
      # This matters more than it sounds. The checkout on the machine where
      # this was written was two commits ahead of the pin and **neither was
      # pushed**: an unconditional move back would have orphaned somebody's
      # unpushed work to the reflog, silently, during what looks like an
      # install. A clean tree is not the same as a saved one.
      #
      # "On the remote" means on ANY of its branches, not only $HERMES_BRANCH:
      # a pin published as `memoe/<version>` is as safe to leave as one on the
      # default branch, and asking only the default branch refused every
      # downgrade from such a pin with "N commits ahead … not on the remote".
      if [ -n "$(git_q branch -r --contains HEAD --list "$remote/*" 2>/dev/null)" ]; then
        if run git_q checkout -B "$HERMES_BRANCH" "$target_sha" --; then
          MOVED_BACK=1
          ok "hermes-agent moved back to the pinned ${target_sha:0:7} (it was ahead)"
        else
          fail "hermes-agent: could not move back to the pinned ${target_sha:0:7}"
        fi
      else
        unpushed="$(git_q rev-list --count HEAD --not --remotes="$remote" 2>/dev/null || echo '?')"
        fail "hermes-agent: $AGENT_DIR is $unpushed commit(s) ahead of the pin and they are not on $remote.
  Nothing was moved — push them, or point HERMES_COMMIT at what you actually want installed."
      fi
    else
      fail "hermes-agent: '$HERMES_BRANCH' has diverged from ${target_sha:0:7} — nothing was reset (see git log in $AGENT_DIR)"
    fi
    after="$(git_q rev-parse --short HEAD)"
    if [ "${before:0:7}" = "${after:0:7}" ]; then
      ok "hermes-agent already at $after$NET_NOTE"
    elif [ "$MOVED_BACK" = 1 ]; then
      : # the ahead-of-pin branch has already said what it did
    else
      ok "hermes-agent fast-forwarded ${before:0:7} → $after$NET_NOTE"
    fi
  fi
elif [ -e "$AGENT_DIR" ]; then
  # A seeded Hermes: laid down out of Memoe.app by HermesSeed.swift, stamped with
  # .moe-seed-commit, no .git. Since 0.3.13 this is the NORMAL shape on a
  # downloaded Mac — the common case, not a broken one.
  #
  # This line used to be:
  #
  #   fail "… exists but is not a git checkout — move it aside and re-run"
  #
  # which read "no .git" as "damaged". Followed, that advice destroys a working
  # Hermes, including a 246 MB venv that no commit covers and nothing can
  # rebuild. And it closed the last door in the loop: HermesSeed.swift leaves an
  # existing hermes-agent alone and names THIS script as "what runs instead",
  # and this script refused it. A pin bump reached nobody who already had Moe.
  #
  # scripts/refresh-hermes-seed.sh is what runs instead now. It refreshes the
  # tracked source the commit covers, refuses rather than replacing anything,
  # and leaves .venv alone. Its refusals are the reason this is a `fail` with
  # whatever it said, not a fallback to the old advice.
  say "hermes-agent is a seed (no .git) — refreshing it to the pin rather than moving it aside"
  # Named, not assumed. On an installed Mac this script runs from
  # ~/.moe/scripts, so $REPO is ~/.moe and the refresh has to have been copied
  # there by install.sh's payload list. A missing file would otherwise surface
  # as bash's "No such file or directory" and exit 127 — a well-formed path
  # that resolves to nothing, which is the failure this repo keeps meeting.
  REFRESH="$REPO/scripts/refresh-hermes-seed.sh"
  [ -x "$REFRESH" ] || fail "hermes-agent: $AGENT_DIR is a seed, and $REFRESH — the only thing that
  can move one — is not here. Nothing was changed. This copy of Memoe is missing a file
  it ships: scripts/install.sh's payload list should carry refresh-hermes-seed.sh."
  # `--to "$HERMES_COMMIT"`, not just `--installer "$0"`. HERMES_COMMIT is the
  # documented way to aim this script somewhere other than its built-in pin —
  # every other path here honours it — and passing only the installer would
  # have made the refresh re-read the file's own default and silently install
  # the pin while the caller believed they had chosen. Found by the seam test:
  # the two ends were green and the join was not.
  if [ -z "$HERMES_COMMIT" ]; then
    fail "hermes-agent: $AGENT_DIR is a seed and HERMES_COMMIT is empty (follow-the-tip mode).
  A seed is moved between two named commits, so there is nothing to move it to. Nothing was
  changed. Set HERMES_COMMIT to the sha you want installed."
  fi
  # The seed this copy of Memoe carries, when the app said where it is
  # (HermesUpgrade.runInstaller sets MOE_HERMES_SEED_BUNDLE to
  # Contents/Resources/hermes-seed). It is the only way across a pin that
  # changes what the venv contains: refresh-hermes-seed.sh refuses that move
  # (exit 3) because it never rebuilds a venv on the person's Mac, and
  # reseed-hermes.sh lays the venv the release built and signed instead.
  RESEED="$REPO/scripts/reseed-hermes.sh"
  BUNDLE_SEED="${MOE_HERMES_SEED_BUNDLE:-}"
  bundle_at_pin=0
  if [ -n "$BUNDLE_SEED" ] && [ -x "$RESEED" ] && \
     [ "$(tr -d '[:space:]' < "$BUNDLE_SEED/hermes-agent/.moe-seed-commit" 2>/dev/null)" = "$HERMES_COMMIT" ]; then
    bundle_at_pin=1
  fi
  # A seed on another Python (lib/python3.11 under a 3.14 bundle) or without
  # the tool store cannot be refreshed into this one at all, so do not ask the
  # network first: lay the bundle, which needs none.
  installed_py="$(basename "$(ls -d "$AGENT_DIR"/.venv/lib/python3.* 2>/dev/null | head -1)" 2>/dev/null)"
  bundle_py="$(basename "$(ls -d "$BUNDLE_SEED"/hermes-agent/.venv/lib/python3.* 2>/dev/null | head -1)" 2>/dev/null)"
  refresh_rc=0
  if [ "$bundle_at_pin" = 1 ] && { [ "$installed_py" != "$bundle_py" ] || [ ! -d "$HERMES_HOME/tools" ]; }; then
    refresh_rc=3
    say "the installed seed is ${installed_py:-unknown}, this Memoe carries ${bundle_py:-unknown} — laying the bundled seed"
  else
    "$REFRESH" "$AGENT_DIR" --to "$HERMES_COMMIT" --installer "$0" || refresh_rc=$?
  fi
  if [ "$refresh_rc" = 3 ] && [ "$bundle_at_pin" = 1 ]; then
    if ! "$RESEED" "$BUNDLE_SEED" --home "$HERMES_HOME" --to "$HERMES_COMMIT"; then
      fail "hermes-agent: the seed this Memoe carries could not be laid over $AGENT_DIR (the reason is above).
  The Hermes you had is back in place and still works. Do NOT move it aside."
    fi
  elif [ "$refresh_rc" != 0 ]; then
    fail "hermes-agent: $AGENT_DIR is a seed that could not be refreshed (the reason is above).
  Nothing was changed and the Hermes you have still works. Do NOT move it aside:
  that deletes a venv no commit can rebuild."
  fi
  IS_SEED=1
  HEAD_SHA="$(tr -d '[:space:]' < "$AGENT_DIR/.moe-seed-commit" 2>/dev/null || true)"
  [ ${#HEAD_SHA} -eq 40 ] || fail "hermes-agent: the refresh finished but $AGENT_DIR/.moe-seed-commit does not name a commit"
  ok "hermes-agent (seed) is at ${HEAD_SHA:0:7}"
else
  if ! net_run git clone --quiet --branch "$HERMES_BRANCH" "$HERMES_FORK" "$AGENT_DIR"; then
    rm -rf "$AGENT_DIR"
    fail "hermes-agent: git clone $HERMES_FORK ($HERMES_BRANCH) failed$NET_NOTE"
  fi
  # Move the branch to the pin. On a clone seconds old there is nothing to
  # lose, so this is `checkout -B` rather than the fast-forward above; the
  # branch is kept (not detached) because `hermes update` expects one.
  if [ -n "$HERMES_COMMIT" ]; then
    if ! git_q cat-file -e "$HERMES_COMMIT^{commit}" 2>>"$LOG"; then
      rm -rf "$AGENT_DIR"
      fail "hermes-agent: the pinned commit ${HERMES_COMMIT:0:7} is not on $HERMES_BRANCH — push it, or fix HERMES_COMMIT"
    fi
    if ! run git_q checkout -B "$HERMES_BRANCH" "$HERMES_COMMIT" --; then
      rm -rf "$AGENT_DIR"
      fail "hermes-agent: could not check out the pinned ${HERMES_COMMIT:0:7}"
    fi
  fi
  ok "hermes-agent cloned: $HERMES_FORK @ $HERMES_BRANCH ($(git_q rev-parse --short HEAD))$NET_NOTE"
fi
if [ "$IS_SEED" = 0 ]; then
  HEAD_SHA="$(git_q rev-parse HEAD)"
fi

# ---- 4. venv + wrapper -------------------------------------------------------
# `uv sync --locked` installs exactly what uv.lock says (hash-checked) and
# refuses if the lock is stale, so a run never quietly re-resolves. The lock
# records this checkout's [tool.uv] settings (exclude-newer), so UV_NO_CONFIG
# — which hides pyproject.toml — must be off for this one command; the user's
# own uv config is kept out by pointing XDG_CONFIG_HOME at an empty dir
# (same trick as Hermes's setup-hermes.sh).
extra_args=()
for e in $HERMES_EXTRAS; do extra_args+=(--extra "$e"); done
sync_stamp="$AGENT_DIR/.venv/.moe-sync"
want="$HEAD_SHA $HERMES_EXTRAS $("$UV" --version | head -1)"
if [ "$IS_SEED" = 1 ]; then
  # A seed's venv is not this script's to rebuild, and `uv sync` here is not a
  # smaller version of that — it is that. Measured on this Mac 2026-09-08: the
  # seeded venv's own stamp reads
  #
  #   bc7d807e… mcp anthropic messaging edge-tts voice google youtube acp uv 0.12.7
  #
  # while this script's default HERMES_EXTRAS is "mcp anthropic messaging
  # edge-tts". So `want` never matches and the sync would ALWAYS run — and it
  # would run `--managed-python`, not find the seed's own interpreter at
  # $HERMES_HOME/python/…, and replace .venv wholesale. That takes with it the
  # hand repair to .venv/bin/python3.11 that 0.3.13 made necessary and that no
  # commit covers.
  #
  # refresh-hermes-seed.sh has already refused any commit that moves uv.lock,
  # pyproject.toml or .python-version, so a refreshed seed's venv is correct for
  # the commit it now carries. What is left is to check that it still starts.
  if [ -x "$AGENT_DIR/.venv/bin/hermes" ]; then
    ok "venv left as it is (a seed's venv; the refresh refuses any commit that would change it)"
  else
    fail "venv: $AGENT_DIR/.venv/bin/hermes is not runnable, and this is a seed — there is no
  lockfile-and-interpreter pair here to rebuild it from without replacing the venv.
  Nothing was changed. Reinstall Moe to lay a fresh seed on a machine that has none."
  fi
elif [ -x "$AGENT_DIR/.venv/bin/hermes" ] && [ "$(cat "$sync_stamp" 2>/dev/null)" = "$want" ]; then
  ok "venv already in sync (uv.lock @ ${HEAD_SHA:0:7}, extras: $HERMES_EXTRAS)"
else
  say "syncing the venv (first time: a few minutes, ~300 MB)…"
  rm -f "$sync_stamp"   # a sync that dies half-way must not look "already in sync" next time
  cfg_tmp="$(mktemp -d "${TMPDIR:-/tmp}/moe-uvcfg.XXXXXX")"; TMP_DIRS+=("$cfg_tmp")
  if ! (cd "$AGENT_DIR" && net_run env -u UV_NO_CONFIG XDG_CONFIG_HOME="$cfg_tmp" XDG_CONFIG_DIRS="$cfg_tmp" \
          "$UV" sync --locked --managed-python --python "$PYTHON_VERSION" "${extra_args[@]}"); then
    fail "venv: uv sync --locked failed in $AGENT_DIR$NET_NOTE"
  fi
  [ -x "$AGENT_DIR/.venv/bin/hermes" ] || fail "venv: uv sync finished but .venv/bin/hermes is missing"
  echo "$want" >"$sync_stamp"
  ok "venv synced: $(ls "$AGENT_DIR/.venv/lib/python$PYTHON_VERSION/site-packages" | grep -c dist-info) packages, extras: $HERMES_EXTRAS$NET_NOTE"
fi

# ---- 4b. Who updates this tree: Memoe, never Hermes itself -------------------
# Since upstream's Python 3.14 + `pm` line, a Hermes checkout with no
# install-stamp.json at ~/.hermes/hermes-agent is "adopted" on its first launch
# (hermes_cli/post_update.py step_adopt_blessed_checkout) as
# `updateMechanism: self` — and a self-updating checkout re-syncs its
# dependencies at launch and execs into a new environment under
# $HERMES_HOME/installs/, outside anything this script built
# (hermes_cli/venv_sync.py prepare_launch). `external` is upstream's own word
# for "a steward replaces this tree" (Docker, Nix): no launch-time sync, no
# `hermes update`, and no launchers written into ~/.local/bin, which is ours.
# The stamp is gitignored upstream, so the checkout stays clean. A seed carries
# one from stage-hermes-seed.sh; it is rewritten here so its commit follows a
# refresh.
STAMP="$AGENT_DIR/install-stamp.json"
if [ -f "$AGENT_DIR/scripts/write_install_stamp.py" ]; then
  if grep -q '"updateMechanism": "external"' "$STAMP" 2>/dev/null && grep -q "\"commit\": \"$HEAD_SHA\"" "$STAMP" 2>/dev/null; then
    ok "install stamp already says Memoe updates this Hermes (${HEAD_SHA:0:7})"
  elif run "$AGENT_DIR/.venv/bin/python" "$AGENT_DIR/scripts/write_install_stamp.py" \
         --output "$STAMP" --commit "$HEAD_SHA" --source memoe --update-mechanism external; then
    ok "install stamp written: Memoe updates this Hermes, it never updates itself (${HEAD_SHA:0:7})"
  else
    fail "install stamp: could not write $STAMP — without it Hermes adopts this tree as self-updating"
  fi
fi

# The wrapper is a console script for the venv, where PATH and Moe's
# Paths.hermesBinary() look. It used to be a byte copy of .venv/bin/hermes,
# which only worked while that script named its interpreter by absolute path.
# A seed's venv is now built relocatable (pm.build_env, as upstream builds its
# own payloads), and its scripts find Python next to where they REALLY are:
#
#     '''exec' "$(dirname -- "$(realpath -- "$0")")"/'python3' "$0" "$@"
#
# A copy of that in ~/.local/bin looks for ~/.local/bin/python3 — absent, or
# somebody else's. So the wrapper is WRITTEN, in the classic shape uv itself
# writes for a non-relocatable venv: a shebang naming the venv's python. That
# shape is what three readers already rely on — Paths.isLaunchable requires
# the named interpreter to exist (a deleted ~/.hermes then reads "not
# installed", the 2026-09-10 fix), MacErase recognises it as Moe's by that
# interpreter, and `hermes doctor` accepts a regular file where it would call
# a link to the venv "broken". A path with a space cannot be a shebang; then
# the `'''exec' '<python>'` form uv uses for long paths, which isLaunchable
# also reads.
WRAPPER="$MOE_BIN_DIR/hermes"
VPY="$AGENT_DIR/.venv/bin/python"
case "$VPY" in
  *" "*) WANT="$(printf '#!/bin/sh\n'"'''"'exec'"'"' '"'"'%s'"'"' "$0" "$@"\n'"'"' '"'''"'\n' "$VPY")" ;;
  *)     WANT="#!$VPY" ;;
esac
WANT="$WANT
# Memoe's hermes command (scripts/install-hermes.sh). Rewritten on every install.
import sys
from hermes_cli.main import main
if __name__ == \"__main__\":
    sys.exit(main())"
if [ -f "$WRAPPER" ] && [ ! -L "$WRAPPER" ] && [ "$(cat "$WRAPPER")" = "$WANT" ]; then
  ok "hermes wrapper already at $WRAPPER"
else
  if [ -L "$WRAPPER" ]; then
    case "$(readlink "$WRAPPER")" in
      */hermes-agent/.venv/bin/hermes) ;;
      *) fail "wrapper: $WRAPPER links to $(readlink "$WRAPPER"), not a Hermes venv — remove it yourself if it is stale" ;;
    esac
  elif [ -e "$WRAPPER" ] && ! grep -q "hermes-agent/.venv/bin/python" "$WRAPPER"; then
    fail "wrapper: $WRAPPER exists and is not a Hermes venv script — remove it yourself if it is stale"
  fi
  had=0
  if [ -e "$WRAPPER" ] || [ -L "$WRAPPER" ]; then had=1; fi
  # Beside, then rename: never a moment with no `hermes` on the path.
  if ! { printf '%s\n' "$WANT" > "$WRAPPER.moe-new.$$" && chmod 755 "$WRAPPER.moe-new.$$" \
         && mv -f "$WRAPPER.moe-new.$$" "$WRAPPER"; }; then
    rm -f "$WRAPPER.moe-new.$$"
    fail "wrapper: could not write $WRAPPER"
  fi
  if [ "$had" = 1 ]; then
    ok "hermes wrapper rewritten at $WRAPPER (it was another venv's, or a copy)"
  else
    ok "hermes wrapper installed at $WRAPPER"
  fi
fi
case ":$PATH:" in
  *":$MOE_BIN_DIR:"*) ;;
  *) say "note: $MOE_BIN_DIR is not on your PATH (Moe finds hermes anyway; add it for your shell)";;
esac

# ---- 5. Smoke ----------------------------------------------------------------
if ver="$("$WRAPPER" --version 2>>"$LOG" | head -1)" && [ -n "$ver" ]; then
  ok "hermes --version: $ver"
else
  fail "hermes --version failed (wrapper $WRAPPER)"
fi
# Doctor is a smoke test: it imports most of Hermes and walks every section.
# Since eb8e427 it also exits 1 for any finding at all — "run 'hermes setup'
# to configure API keys", an npm advisory in the WhatsApp bridge — and on a
# Moe there are always some, because Moe configures Hermes its own way. Read
# as fatal, that made every seed refresh "fail" AFTER the new tree was in
# place (2026-10-09), so nothing restarted the gateway and every turn broke.
# So: a doctor that printed its summary ran, and its findings are advice for
# the log; a doctor that crashed, or exited anything else, is still fatal.
echo "[$(date '+%H:%M:%S')] \$ $WRAPPER doctor" >>"$LOG"
set +e
doctor_out="$("$WRAPPER" doctor 2>&1)"
doctor_rc=$?
set -e
printf '%s\n' "$doctor_out" >>"$LOG"
doctor_found="$(printf '%s\n' "$doctor_out" | sed -n 's/.*Found \([0-9][0-9]*\) issue(s) to address.*/\1/p' | tail -1)"
if [ "$doctor_rc" = 0 ]; then
  ok "hermes doctor passed"
elif [ "$doctor_rc" = 1 ] && [ -n "$doctor_found" ] && ! printf '%s\n' "$doctor_out" | grep -q '^Traceback'; then
  ok "hermes doctor passed — $doctor_found finding(s) to look at, listed in $LOG"
else
  fail "hermes doctor failed (exit $doctor_rc)"
fi

# The read-only config check. It exits 1 with a list on a fresh install —
# that list IS the next step, so it is printed, not treated as our failure.
CHECK=""
for c in "$MOE_HOME/hermes/configure-hermes.py" "$REPO/moe-home/hermes/configure-hermes.py"; do
  [ -f "$c" ] && { CHECK="$c"; break; }
done
echo
if [ -n "$CHECK" ]; then
  say "configure-hermes.py --check:"
  set +e
  out="$("$AGENT_DIR/.venv/bin/python" "$CHECK" --check --hermes-home "$HERMES_HOME" --moe-home "$MOE_HOME" --hermes-agent "$AGENT_DIR" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" | sed 's/^/  /' | tee -a "$LOG"
  if [ $rc = 0 ]; then ok "Hermes is installed and configured as Moe's core"; else ok "Hermes is installed; configuration is the next step (above)"; fi
else
  ok "Hermes is installed (configure-hermes.py not found; run scripts/install.sh to lay out ~/.moe)"
fi

# ---- 6. cua-driver -----------------------------------------------------------
# The backend `computer_use` wants. Without it Hermes falls back to posting
# CoreGraphics events at whatever happens to be frontmost, and — the part that
# actually costs you — it cannot tell a keystroke that landed from one that
# vanished, so the agent retries blind. Here rather than in the app's launch
# path because this is a download, and the app bounds that path at 60s.
#
# Not fatal: a machine that cannot reach the download still runs, on the
# fallback, and every later `configure-hermes.py` tries again.
echo
if run "$WRAPPER" computer-use install; then
  ok "cua-driver installed (background computer use)"
  # Installed is not permitted. The grants attach to cua-driver's own identity
  # (com.trycua.driver) — not to Memoe.app and not to this terminal — and only a
  # person can give them, so it is the next step, not something to attempt.
  if run "$WRAPPER" computer-use permissions status; then
    say "grant it Accessibility + Screen Recording: hermes computer-use permissions grant"
  fi
else
  say "cua-driver did not install; Moe still runs, but it cannot confirm that a"
  say "  click or keystroke landed. Retry later: hermes computer-use install"
fi

# ---- 7. Hermes's own tool store ----------------------------------------------
# Since upstream 5e4a2a3d24 Hermes finds Node, npm, uv, ffmpeg, ripgrep and its
# browser (agent-browser + the Chrome for Testing it drives) ONLY in its `pm`
# tool store, $HERMES_HOME/tools — never $HERMES_HOME/node, never the PATH. And
# with lazy installs off (configure-hermes.py apply_dependency_seal) it will
# not fetch one on first use. So the store is filled here, where a download is
# expected, by the same `pm.prepare_tools` stage-hermes-seed.sh uses — pinned
# and sha256-checked against the fork's pm/lock.json. A seed already carries
# it; this then only confirms it.
#
# What this replaces: `npm install -g agent-browser` into $HERMES_HOME/node/bin,
# `agent-browser install` (Chromium into ~/.agent-browser) and
# `uv tool install browser-use`. Hermes now runs browser-use from its own venv
# (browser-harness is a core dependency) and agent-browser from the store.
#
# cua-driver is deliberately NOT in this list: a store copy outranks the
# /Applications/CuaDriver.app a Mac already granted Accessibility and Screen
# Recording to, and would ask for both again. Step 6 owns it.
#
# Not fatal: Hermes runs without any of these, and says which tool is missing.
echo
# `chromium`, not `agent-browser`, since the 0.3.26 pin: upstream's browser
# rewire (#143146) removed agent-browser from pm/lock.json (pm/defaults.py
# RETIRED_DEFAULTS maps the old name to chromium), and prepare_tools refuses a
# name the lock does not carry. `pnpm` joined pm's required set at the same
# pin; without it every launch warns "install out of sync (pnpm: ...)".
PM_TOOLS="${MOE_PM_TOOLS:-node npm pnpm uv ffmpeg ripgrep chromium}"
pm_missing="$(cd / && env HERMES_HOME="$HERMES_HOME" PYTHONPATH="$AGENT_DIR" \
  "$AGENT_DIR/.venv/bin/python" -c '
import sys
try:
    import pm
except Exception:
    print("pm-unavailable"); sys.exit(0)
def present(name):
    # uv is pm-internal: installed_package refuses it by design; uv_launcher reads it.
    return (pm.uv_launcher("uv") if name == "uv" else pm.installed_package(name)) is not None
print(" ".join(n for n in sys.argv[1:] if not present(n)))' $PM_TOOLS 2>>"$LOG" || echo "?")"
if [ "$pm_missing" = "pm-unavailable" ]; then
  say "this Hermes has no pm tool store (a pre-3.14 commit); nothing to fill"
elif [ -z "$pm_missing" ]; then
  ok "Hermes's tool store already has: $PM_TOOLS"
elif net_run env HERMES_HOME="$HERMES_HOME" HERMES_RUNTIME_DIR="$HERMES_HOME/tools" PYTHONPATH="$AGENT_DIR" \
       "$AGENT_DIR/.venv/bin/python" -c '
import sys
from pathlib import Path
from pm import current_target
from pm.build_operations import prepare_tools  # in-process: no pm worker env built from PyPI
prepare_tools(sys.argv[2:], out=Path(sys.argv[1]), target=current_target())' "$HERMES_HOME/tools" $pm_missing; then
  ok "Hermes's tool store filled: $pm_missing (pinned by the fork's pm/lock.json)$NET_NOTE"
else
  say "Hermes's tool store is missing: $pm_missing — Hermes runs, but anything that needs"
  say "  one of them says so instead of fetching it. Retry: re-run this installer."
fi
# The browser: never in the seed (slim-hermes-tools.py), so it arrives here —
# Chrome for Testing at the build pm/lock.json pins, sha256-checked by pm, or
# cloned from an identical build agent-browser already downloaded. A seed's
# store says `.browser-pending` until it is in; the browser tools tell the
# person "still downloading its browser" meanwhile. Not fatal: the next launch
# (HermesUpgrade.fetchBrowserIfPending) tries again.
if [ "$pm_missing" != "pm-unavailable" ] && [ -d "$HERMES_HOME/tools" ]; then
  FETCH_BROWSER="${MOE_FETCH_BROWSER:-$REPO/scripts/fetch-hermes-browser.sh}"
  if [ ! -x "$FETCH_BROWSER" ]; then
    say "no $FETCH_BROWSER beside this installer; the browser stays pending"
  elif browser_out="$("$FETCH_BROWSER" --home "$HERMES_HOME" 2>&1)"; then
    printf '%s\n' "$browser_out" >>"$LOG"
    ok "$(printf '%s\n' "$browser_out" | grep '^✓' | tail -1 | sed 's/^✓ //')"
  else
    printf '%s\n' "$browser_out" >>"$LOG"
    say "the browser is not in place yet: $(printf '%s\n' "$browser_out" | tail -1)"
    say "  Hermes runs; browser tools say it is still downloading. The next launch retries."
  fi
fi

cat <<EOF

  Next:
    $MOE_HOME/scripts/hermes-signin.sh      sign Hermes's Claude Code in, once (asks you; opens a browser)
    $MOE_HOME/hermes/configure-hermes.py    make Hermes Moe's core (config, Telegram, memory)
    hermes computer-use permissions grant   let Moe see and act on your screen (opens a macOS dialog)
EOF
