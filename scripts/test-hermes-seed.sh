#!/bin/bash
# Proves the Hermes seed is safe to ship and works when it lands.
#
# The seed is the largest thing Moe puts in front of a stranger that Moe did
# not write: ~1 GB of third-party runtime, built on the developer's Mac — the
# Mac whose ~/.hermes holds auth.json, mcp-tokens/, memories/ and sessions/.
# Two things therefore have to be true, and neither is provable by reading
# the script:
#
#   1. nothing personal reaches the seed, and the gate that says so would
#      actually fail if something did;
#   2. the seed runs after it is copied somewhere else, because every absolute
#      path in a venv points at the machine that built it.
#
# Tests 2 and 3 are the ones that matter: a privacy gate that has never been
# seen to fail is decoration, so both are checked by planting a leak and
# demanding a non-zero exit.
set -u
unset CDPATH   # an exported CDPATH makes `cd` print, and $(cd … && pwd) then reads two lines
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SCRATCH="${MOE_TEST_SCRATCH:-$(mktemp -d)}"
trap 'rm -rf "$SCRATCH"' EXIT

pass=0; fail=0; skipped=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { fail=$((fail+1)); echo "  ✗ $1"; }
skip() { skipped=$((skipped+1)); echo "  – skipped: $1"; }

# ── The fixture ──────────────────────────────────────────────────────────────
#
# stage-hermes-seed.sh builds a seed from a COMMIT of the fork: the code by
# `git archive`, the store and the venv by pm (network). The network half is
# replaced here by MOE_SEED_BUILDER, a script that lays down the same shape pm
# does — measured from a real 3.14 seed staged 2026-10-07 from upstream
# 354724fb08, not invented: the store entry is `python-<ver>+<date>-<target>`,
# the venv's pyvenv.cfg `home` names its bin, the console scripts are uv's
# relocatable trampolines, and the editable install's direct_url.json and
# finder name the build directory. Everything after the builder — pruning,
# linking, the stamp, the placeholder rewrite and the leak gate — is the real
# script running on it.
#
# The "interpreter" in the store is a shell script that execs this Mac's
# python3, so the stage's own `python write_install_stamp.py` step really runs.
PYRT="python-3.14.7+20260901-darwin-arm64"

make_src() {  # make_src <dir>: a git checkout shaped like the fork, plus junk around it
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d/agent" "$d/pm" "$d/scripts" "$d/tests" "$d/docs" "$d/website" "$d/__pycache__"
  printf '[project]\nname = "hermes-agent"\nversion = "0.0.0"\n' > "$d/pyproject.toml"
  printf 'version = 1\n' > "$d/uv.lock"
  printf '{"schema": 1, "packages": {}}\n' > "$d/pm/lock.json"
  printf '# pm.build_env stand-in\n' > "$d/pm/build_env.py"
  # The stamp writer the stage calls: takes upstream's flags, writes the JSON.
  cat > "$d/scripts/write_install_stamp.py" <<'PY'
import argparse, json
ap = argparse.ArgumentParser()
ap.add_argument("--output"); ap.add_argument("--commit"); ap.add_argument("--source")
ap.add_argument("--update-mechanism"); ap.add_argument("--commit-date")
a = ap.parse_args()
# Like upstream's writer: "dirty" comes from git of whatever repository the
# script finds itself in — so the stage has to stop that walk.
import subprocess
dirty = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True,
                       cwd=__import__("os").path.dirname(__file__))
json.dump({"schemaVersion": 2, "commit": a.commit, "source": a.source,
           "dirty": bool(dirty.returncode == 0 and dirty.stdout.strip()),
           "updateMechanism": a.update_mechanism}, open(a.output, "w"), indent=2)
PY
  # A parser constant, not a key: the gate must not fire on this.
  printf 'PEM_MARKER = "-----BEGIN OPENSSH PRIVATE KEY-----"\n' > "$d/agent/redact.py"
  printf 'a test\n' > "$d/tests/test_x.py"
  printf 'docs\n' > "$d/docs/index.md"
  printf 'site\n' > "$d/website/index.md"
  printf 'TRACKED=1\n' > "$d/.env.example"
  ( cd "$d" && git init -q . && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A \
      && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm seed ) >/dev/null 2>&1
  # Untracked, in the checkout the seed is built from: the commit does not
  # carry them, so the seed must not either. A copy of the working tree would.
  printf 'SECRET=1\n' > "$d/.env"
  printf '{"token":"real-looking-secret"}\n' > "$d/auth.json"
  printf 'cached\n' > "$d/__pycache__/x.pyc"
  printf 'my local edit\n' > "$d/agent/untracked_scratch.py"
}

commit_src() {  # commit_src <dir>: commit whatever was planted, so the archive carries it
  ( cd "$1" && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A agent \
      && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm plant ) >/dev/null 2>&1
}

BUILDER="$SCRATCH/fake-pm-builder.sh"
cat > "$BUILDER" <<'SH'
#!/bin/bash
# fake-pm-builder <checkout> <store> <venv> — the shape pm.prepare_tools and
# pm.build_env --sealed leave, with the knobs the tests turn.
set -e
code="$1" store="$2" venv="$3"
PYRT="python-3.14.7+20260901-darwin-arm64"
mkdir -p "$store/$PYRT/bin" "$store/$PYRT/lib/python3.14/json" "$store/node-26.7.0-darwin-arm64/bin"
printf '#!/bin/sh\nexec /usr/bin/python3 "$@"\n' > "$store/$PYRT/bin/python3.14"
chmod +x "$store/$PYRT/bin/python3.14"
ln -s python3.14 "$store/$PYRT/bin/python3"
printf 'node\n' > "$store/node-26.7.0-darwin-arm64/bin/node"; chmod +x "$store/node-26.7.0-darwin-arm64/bin/node"
printf '{"schema":1,"packages":{"node":{"entry":"node-26.7.0-darwin-arm64","env":{"PATH":["{{store}}/node-26.7.0-darwin-arm64/bin"]}}}}\n' > "$store/facts.json"
SP="$venv/lib/python3.14/site-packages"
mkdir -p "$venv/bin" "$SP/somepkg/tests" "$SP/hermes_agent-0.0.0.dist-info"
home="${FAKE_VENV_HOME:-$store/$PYRT/bin}"
printf 'home = %s\nimplementation = CPython\nversion_info = 3.14.7\nrelocatable = true\n' "$home" > "$venv/pyvenv.cfg"
# What uv's venv creation leaves: absolute links to the base interpreter.
ln -s "$store/$PYRT/bin/python3.14" "$venv/bin/python"
ln -s python "$venv/bin/python3"
ln -s python "$venv/bin/python3.14"
printf "#!/bin/sh\n'''exec' \"\$(dirname -- \"\$(realpath -- \"\$0\")\")\"/'python3' \"\$0\" \"\$@\"\n' '''\nprint('hermes')\n" > "$venv/bin/hermes"
chmod +x "$venv/bin/hermes"
printf '{"url":"file://%s","dir_info":{"editable":true}}' "$code" > "$SP/hermes_agent-0.0.0.dist-info/direct_url.json"
printf 'MAPPING = {"agent": "%s/agent"}\n' "$code" > "$SP/__editable___hermes_agent_0_0_0_finder.py"
printf 'in site-packages\n' > "$SP/somepkg/tests/t.py"
for gone in onnxruntime av ctranslate2 faster_whisper hf_xet; do
  mkdir -p "$SP/$gone" "$SP/${gone}-1.0.0.dist-info"
  printf 'weights\n' > "$SP/$gone/__init__.py"
done
for stay in pip numpy anthropic mcp; do
  mkdir -p "$SP/$stay"; printf 'core\n' > "$SP/$stay/__init__.py"
done
SH
chmod +x "$BUILDER"

SEED="$SCRATCH/seed"
stage() {  # stage <src>; leaves output in $SCRATCH/out.log
  HERMES_SOURCE="$1" MOE_SEED_OUT="$SEED" MOE_SEED_BUILDER="$BUILDER" \
    MOE_UV=/usr/bin/true ./scripts/stage-hermes-seed.sh >"$SCRATCH/out.log" 2>&1
}
SRC="$SCRATCH/src"
SITEO="$SEED/hermes-agent/.venv/lib/python3.14/site-packages"

echo "1. the seed is the commit: nothing from the checkout's working tree reaches it"
make_src "$SRC"
if stage "$SRC"; then
  leaked=""
  for f in .env auth.json agent/untracked_scratch.py; do
    [ -e "$SEED/hermes-agent/$f" ] && leaked="$leaked $f"
  done
  [ -z "$leaked" ] && ok "untracked files in the source checkout (.env, auth.json, a scratch edit) are absent" \
                   || bad "the seed contains untracked files:$leaked"
  [ -d "$SEED/hermes-agent" ] && [ -d "$SEED/tools" ] && [ ! -e "$SEED/python" ] && [ ! -e "$SEED/node" ] \
    && ok "hermes-agent/ and tools/ are present; the old python/ and node/ are not" \
    || bad "the seed's top level is not hermes-agent/ + tools/: $(ls "$SEED" | tr '\n' ' ')"
  [ ! -e "$SEED/hermes-agent/.env.example" ] && [ ! -d "$SEED/hermes-agent/.git" ] \
    && [ ! -d "$SEED/hermes-agent/__pycache__" ] && [ ! -d "$SEED/hermes-agent/tests" ] \
    && [ ! -d "$SEED/hermes-agent/docs" ] && [ ! -d "$SEED/hermes-agent/website" ] \
    && ok ".env*, .git, __pycache__, tests, docs and website are pruned" \
    || bad "a prune did not happen"
  want_commit=$(git -C "$SRC" rev-parse HEAD 2>/dev/null)
  got_commit=$(cat "$SEED/hermes-agent/.moe-seed-commit" 2>/dev/null)
  [ -n "$want_commit" ] && [ "$got_commit" = "$want_commit" ] \
    && ok "hermes-agent/.moe-seed-commit records the source commit (${want_commit:0:7})" \
    || bad ".moe-seed-commit is '$got_commit', wanted '$want_commit'"
  for d in tests docs website; do
    command grep -qx "$d" "$SEED/hermes-agent/.moe-seed-pruned" 2>/dev/null || { bad ".moe-seed-pruned does not record $d"; continue; }
  done
  command grep -qx tests "$SEED/hermes-agent/.moe-seed-pruned" && ok ".moe-seed-pruned records what staging removed"
  [ ! -d "$SITEO/somepkg/tests" ] && ok "tests inside site-packages are pruned" || bad "site-packages tests survived"
  # Memoe updates this tree; Hermes never syncs or re-execs it at launch.
  command grep -q '"updateMechanism": "external"' "$SEED/hermes-agent/install-stamp.json" 2>/dev/null \
    && command grep -q "\"commit\": \"$want_commit\"" "$SEED/hermes-agent/install-stamp.json" \
    && ok "install-stamp.json says updateMechanism external, at the commit" \
    || bad "install-stamp.json is missing or does not say external at the commit"
  [ "$(cat "$SITEO/hermes-agent.pth" 2>/dev/null)" = "../../../.." ] \
    && ok "the venv reaches the code by a relative hermes-agent.pth" \
    || bad "hermes-agent.pth is '$(cat "$SITEO/hermes-agent.pth" 2>/dev/null)', not ../../../.."
else
  bad "staging a clean source failed"
  sed 's/^/      /' "$SCRATCH/out.log" | tail -8
fi

echo "2. no absolute path from this machine survives"
if [ -d "$SEED/hermes-agent" ]; then
  if [ -z "$(command grep -rlF "$SEED" "$SEED" 2>/dev/null | head -1)" ]; then
    ok "the build directory appears nowhere in the seed"
  else
    bad "the build directory is still in the seed"
    command grep -rlF "$SEED" "$SEED" 2>/dev/null | head -3 | sed 's/^/      /'
  fi
  command grep -q '@HERMES_ROOT@/tools/' "$SEED/hermes-agent/.venv/pyvenv.cfg" 2>/dev/null \
    && ok "pyvenv.cfg's home is the placeholder's tools/" || bad "pyvenv.cfg was not rewritten"
  command grep -q '@HERMES_ROOT@' "$SITEO/hermes_agent-0.0.0.dist-info/direct_url.json" 2>/dev/null \
    && ok "the editable install's direct_url.json was rewritten" \
    || bad "direct_url.json still names the build machine"
  # A relocatable trampoline has no path in it to rewrite, and must keep none.
  command grep -q "realpath" "$SEED/hermes-agent/.venv/bin/hermes" \
    && ! command grep -q '@HERMES_ROOT@' "$SEED/hermes-agent/.venv/bin/hermes" \
    && ok "the console script stays relocatable (no path, no placeholder)" \
    || bad "the console script was rewritten or is not relocatable"
fi

echo "3. the gate fails when something personal is planted"
# Without this, a passing run proves only that the gate is quiet. Planted in
# the COMMIT, because nothing else can reach the seed now.
make_src "$SRC"
printf 'client_secret from %s\n' "$HOME" > "$SRC/agent/leak.py"; commit_src "$SRC"
if stage "$SRC"; then
  bad "the gate passed a seed containing the builder's home directory"
else
  command grep -q "is still in the seed" "$SCRATCH/out.log" \
    && ok "a planted home-directory path is caught, and named" \
    || { bad "staging failed but not because of the leak"; sed 's/^/      /' "$SCRATCH/out.log" | tail -5; }
fi
make_src "$SRC"
printf 'KEY = "sk-ant-api03-R7kQ2mZvB9nX4wLpT6yH8cJdF3gA5sE1uN0iO7rK2bM9tV4x"\n' > "$SRC/agent/leak.py"; commit_src "$SRC"
if stage "$SRC"; then
  bad "the gate passed a seed containing an API token"
else
  command grep -q "API token" "$SCRATCH/out.log" && ok "a planted API token is caught" \
    || { bad "staging failed but not because of the token"; sed 's/^/      /' "$SCRATCH/out.log" | tail -5; }
fi
make_src "$SRC"
{ echo "-----BEGIN RSA PRIVATE KEY-----"
  printf 'MIIEowIBAAKCAQEAx7Vn9mQpLd0TgYs2FbKcJqW4rNvPzHtEuXaBcDeFgHiJkLmN\n'
  echo "-----END RSA PRIVATE KEY-----"; } > "$SRC/agent/id_rsa"; commit_src "$SRC"
if stage "$SRC"; then
  bad "the gate passed a seed containing a private key"
else
  command grep -q "private key" "$SCRATCH/out.log" && ok "a planted private key is caught" \
    || { bad "staging failed but not because of the key"; sed 's/^/      /' "$SCRATCH/out.log" | tail -5; }
fi

echo "4. the gate does not fire on code that merely mentions a key"
make_src "$SRC"
if stage "$SRC"; then
  ok "a PEM delimiter with no key body is not treated as a key"
else
  bad "the gate fired on redact.py — it cannot tell a parser from a secret"
  sed 's/^/      /' "$SCRATCH/out.log" | tail -5
fi

echo "5. what cannot become a seed is refused before anything is touched"
make_src "$SRC"
if FAKE_VENV_HOME=/opt/homebrew/opt/python@3.14/bin stage "$SRC"; then
  bad "staged a venv whose interpreter is not in the seed — it would not run elsewhere"
else
  command grep -q "outside" "$SCRATCH/out.log" \
    && ok "a venv on an interpreter outside tools/ is refused, with the reason" \
    || bad "refused, but not for the interpreter"
fi
# A seed (no .git) as the source: refused, and the previous output untouched.
make_src "$SRC"; stage "$SRC" >/dev/null 2>&1
printf 'previous\n' > "$SEED/MARKER"
NOGIT="$SCRATCH/nogit"; rm -rf "$NOGIT"; cp -R "$SRC" "$NOGIT"; rm -rf "$NOGIT/.git"
if stage "$NOGIT"; then
  bad "staged from a tree with no .git — a seed was staged into a seed"
else
  command grep -q "not a git checkout" "$SCRATCH/out.log" && [ -f "$SEED/MARKER" ] \
    && ok "a source with no .git is refused, and the previous seed is untouched" \
    || bad "refused, but the reason or the untouched output is wrong"
fi

echo "6. the size rules take what nothing reaches, and the interpreter is LINKED"
make_src "$SRC"
if stage "$SRC"; then
  left=""
  for gone in onnxruntime av ctranslate2 faster_whisper hf_xet; do
    [ -e "$SITEO/$gone" ] && left="$left $gone"
    ls -d "$SITEO/${gone}-"*.dist-info >/dev/null 2>&1 && left="$left ${gone}.dist-info"
  done
  [ -z "$left" ] && ok "the local-Whisper stack is gone, dist-info and all" || bad "still shipped:$left"
  keptall=1
  for stay in pip numpy anthropic mcp; do
    [ -d "$SITEO/$stay" ] || { bad "the size rules removed $stay, which Hermes needs"; keptall=0; }
  done
  [ "$keptall" = 1 ] && ok "pip, numpy, anthropic and mcp are untouched"
  # 0.3.13 shipped a COPIED interpreter, which cannot find its stdlib. Every
  # venv interpreter is a link, every link relative, python3.14 into tools/.
  vreals=0; vabs=0
  for c in python python3 python3.14; do
    b="$SEED/hermes-agent/.venv/bin/$c"
    [ -e "$b" ] || [ -L "$b" ] || continue
    if [ -L "$b" ]; then case "$(readlink "$b")" in /*) vabs=$((vabs+1)) ;; esac
    else vreals=$((vreals+1)); fi
  done
  [ "$vreals" = 0 ] && ok "the venv carries no copied interpreter — only links" \
    || bad "the venv has $vreals copied interpreter(s): that seed cannot start (the 0.3.13 bug)"
  [ "$vabs" = 0 ] && ok "and none of them is absolute (uv made them absolute; the stage relinks)" \
    || bad "the venv has $vabs absolute interpreter link(s)"
  [ "$(readlink "$SEED/hermes-agent/.venv/bin/python3.14")" = "../../../tools/$PYRT/bin/python3.14" ] \
    && ok "the venv's python3.14 points up into the seed's own tools/$PYRT" \
    || bad "the venv's python3.14 is '$(readlink "$SEED/hermes-agent/.venv/bin/python3.14")'"
  [ -x "$SEED/hermes-agent/.venv/bin/python3.14" ] && ok "and it resolves" || bad "the link does not resolve"
  # The store is pm's: entries are recorded by digest, so nothing in it is pruned.
  [ -d "$SEED/tools/$PYRT/lib/python3.14/json" ] && [ -f "$SEED/tools/facts.json" ] \
    && ok "tools/ is left exactly as pm staged it" || bad "something in tools/ was pruned"
else
  bad "staging failed with the size rules in place"
  sed 's/^/      /' "$SCRATCH/out.log" | tail -5
fi

echo "7. Moe itself lays the seed down, and it runs from there"
# Through `Moe --install-hermes-seed`, i.e. the same HermesSeed.swift the app
# runs on first launch — not a Python re-implementation of it.
#
# The first version of this test did reimplement the substitution, with
# different rules (any file under 8 MB that decodes, versus Swift's bin/-or-
# nine-extensions under 4 MB). That proved the *seed* was relocatable and said
# nothing about whether Moe relocates it correctly, which is the half that can
# actually break a user's Mac.
SEED="$ROOT/hermes-seed"   # the REAL staged seed, read-only from here on
MOE_BIN="${MOE_BIN:-$ROOT/.build/debug/Moe}"
if [ ! -x "$MOE_BIN" ]; then
  skip "no built Moe at $MOE_BIN (swift build), so the install path was NOT checked"
elif [ ! -x "$SEED/hermes-agent/.venv/bin/hermes" ]; then
  skip "no seed staged, so \"runs elsewhere\" was NOT checked (./scripts/stage-hermes-seed.sh)"
else
  DEST="$SCRATCH/live"
  out=$(MOE_HERMES_SEED="$SEED" "$MOE_BIN" --install-hermes-seed "$DEST" 2>&1)
  case "$out" in
    *installed*) ok "Moe reports it installed the seed: $out" ;;
    *)           bad "Moe did not install the seed: $out" ;;
  esac

  # The placeholder must be gone everywhere, not merely from the files the
  # substitution happens to visit. This is the check that would have caught a
  # path landing in a file shape Swift's rules do not reach.
  left=$(grep -rl --binary-files=text -F '@HERMES_ROOT@' "$DEST" 2>/dev/null | head -3 || true)
  if [ -z "$left" ]; then
    ok "no @HERMES_ROOT@ survives anywhere under the destination"
  else
    bad "the placeholder is still in the installed tree:"
    printf '%s\n' "$left" | sed 's/^/      /'
  fi

  # Both parts, since the seed is useless without either of them.
  missing=""
  for part in hermes-agent tools; do
    [ -d "$DEST/$part" ] || missing="$missing $part"
  done
  [ -z "$missing" ] && ok "hermes-agent and tools landed" \
                    || bad "the install is missing:$missing"

  # The point of the whole exercise. DEST is the HERMES_HOME, as ~/.hermes is
  # on a Mac — and never the real one: a bare `hermes --version` writes logs,
  # skills and sessions into whatever home it resolves.
  hrun() { env HOME="$SCRATCH/home" HERMES_HOME="$DEST" HERMES_DISABLE_LAZY_INSTALLS=1 "$@"; }
  mkdir -p "$SCRATCH/home"
  ver=$(hrun "$DEST/hermes-agent/.venv/bin/hermes" --version 2>&1 | head -1)
  case "$ver" in
    *"Hermes Agent"*) ok "the installed hermes runs: $ver" ;;
    *)                bad "the installed hermes does not run: $ver" ;;
  esac

  # Idempotence: a second run must not re-copy, and must not damage what is
  # there. `hermes-agent` already existing is the guard that protects a
  # half-finished install a user is about to repair.
  out2=$(MOE_HERMES_SEED="$SEED" "$MOE_BIN" --install-hermes-seed "$DEST" 2>&1)
  case "$out2" in
    *"already exists"*|*"already installed"*) ok "a second run leaves it alone: $out2" ;;
    *) bad "a second run did something: $out2" ;;
  esac
  ver2=$(hrun "$DEST/hermes-agent/.venv/bin/hermes" --version 2>&1 | head -1)
  case "$ver2" in
    *"Hermes Agent"*) ok "and it still runs afterwards" ;;
    *)                bad "the second run broke it: $ver2" ;;
  esac

  # An existing hermes-agent is never deleted, even a broken one — that is a
  # user's half-finished install or a developer's checkout.
  DEST2="$SCRATCH/existing"
  mkdir -p "$DEST2/hermes-agent"
  printf 'my unpushed work\n' > "$DEST2/hermes-agent/PRECIOUS"
  MOE_HERMES_SEED="$SEED" "$MOE_BIN" --install-hermes-seed "$DEST2" >/dev/null 2>&1
  [ -f "$DEST2/hermes-agent/PRECIOUS" ] \
    && ok "an existing hermes-agent is left untouched" \
    || bad "the seed install destroyed an existing hermes-agent"

  # ---- cloned into place, not copied twice --------------------------------
  # Moe used to fm.copyItem the seed, so a Mac carried the whole of Hermes
  # twice: 817 MB inside the app and 817 MB again in the home. It clones now.
  #
  # The risk a clone brings is the opposite of the one a copy brings. A hard
  # link would look like the same saving and would make an edit to ~/.hermes
  # reach back into the SIGNED APP BUNDLE — so what is asserted is not "it
  # was cloned" but the two things that make cloning correct: the trees are
  # independent, and they are not one file. Both run here, inside test 6,
  # because test 7 restages $SEED and after that this would be comparing the
  # installed tree against a different seed entirely.
  # Independence and inode-inequality are necessary but NOT sufficient: a
  # plain fm.copyItem passes both, so on their own they cannot tell a clone
  # from the copy this replaced. Free space is what tells them apart. A real
  # seed is ~817 MB; copying it costs that much disk and cloning costs
  # essentially none, so the third install below is measured rather than
  # asserted. Skipped on a fixture seed, where the difference is noise.
  seedkb=$(du -sk "$SEED" | cut -f1)
  if [ "$seedkb" -gt 204800 ]; then
    DEST3="$SCRATCH/space"
    free_before=$(df -k "$SCRATCH" | awk 'NR==2 {print $4}')
    MOE_HERMES_SEED="$SEED" "$MOE_BIN" --install-hermes-seed "$DEST3" >/dev/null 2>&1
    free_after=$(df -k "$SCRATCH" | awk 'NR==2 {print $4}')
    used=$((free_before - free_after))
    # Half the seed is a generous line: a copy costs all of it, a clone costs
    # the rewritten text files and whatever else the volume did meanwhile.
    if [ "$used" -lt $((seedkb / 2)) ]; then
      ok "installing $((seedkb/1024)) MB cost $((used/1024)) MB of disk — cloned, not copied"
    else
      bad "installing $((seedkb/1024)) MB cost $((used/1024)) MB — the seed was copied twice"
    fi
    rm -rf "$DEST3"
  else
    skip "fixture seed is too small to measure the clone against"
  fi

  ref="hermes-agent/.venv/bin/hermes"
  if [ -f "$SEED/$ref" ] && [ -f "$DEST/$ref" ]; then
    before="$(cat "$SEED/$ref")"
    printf '\n# written into the installed tree\n' >> "$DEST/$ref"
    [ "$(cat "$SEED/$ref")" = "$before" ] \
      && ok "writing to the installed tree leaves the app's copy alone" \
      || bad "the trees share storage — an edit reached back into the bundle"
    [ "$(stat -f %i "$SEED/$ref")" != "$(stat -f %i "$DEST/$ref")" ] \
      && ok "and they are separate files, not one hard link" \
      || bad "the seed was hard-linked into place"
  else
    skip "no comparable file in both trees to check independence against"
  fi
fi

echo "8. the build refuses a seed that is not the pinned Hermes"
# The seed in 0.3.12 was staged before the pin moved and carried no stamp at
# all, and the build said nothing. So: a stamp that differs is refused, NO
# stamp is refused (unknown is not current), the pin is refused, and only the
# matching stamp passes — each by running the check build.sh runs, on a
# fixture, and demanding the exit code.
CHECK="$ROOT/scripts/check-hermes-seed-commit.sh"
G8="$SCRATCH/gate"
PIN="0123456789abcdef0123456789abcdef01234567"
OTHER="fedcba9876543210fedcba9876543210fedcba98"
mkdir -p "$G8/seed/hermes-agent" "$G8/seed/tools"
printf 'HERMES_COMMIT="${HERMES_COMMIT-%s}"\n' "$PIN" > "$G8/install-hermes.sh"
if "$CHECK" "$G8/seed" "$G8/install-hermes.sh" >/dev/null 2>&1; then
  bad "a seed with no .moe-seed-commit passed — unknown was read as current, which is exactly the 0.3.12 seed"
else
  ok "a seed with no stamp is refused"
fi
printf '%s\n' "$OTHER" > "$G8/seed/hermes-agent/.moe-seed-commit"
if "$CHECK" "$G8/seed" "$G8/install-hermes.sh" >"$G8/stale.out" 2>&1; then
  bad "a seed at another commit than the pin passed"
else
  grep -q "${OTHER:0:10}" "$G8/stale.out" && grep -q "${PIN:0:10}" "$G8/stale.out" \
    && ok "a stale seed is refused, and the message names both commits" \
    || bad "a stale seed is refused but the message does not say which two commits disagree"
fi
printf '%s\n' "$PIN" > "$G8/seed/hermes-agent/.moe-seed-commit"
"$CHECK" "$G8/seed" "$G8/install-hermes.sh" >/dev/null 2>&1 \
  && ok "the seed at the pinned commit passes" \
  || bad "the seed at the pinned commit was refused"
printf 'short\n' > "$G8/seed/hermes-agent/.moe-seed-commit"
"$CHECK" "$G8/seed" "$G8/install-hermes.sh" >/dev/null 2>&1 \
  && bad "a stamp that is not a sha passed" || ok "a stamp that is not a sha is refused"
printf 'HERMES_COMMIT=something-else\n' > "$G8/no-pin.sh"
printf '%s\n' "$PIN" > "$G8/seed/hermes-agent/.moe-seed-commit"
"$CHECK" "$G8/seed" "$G8/no-pin.sh" >/dev/null 2>&1 \
  && bad "an installer with no readable pin line passed" || ok "an installer with no readable pin line is refused"
# The check has teeth: with its comparison deleted, the stale seed passes.
# If this ever stops being true the fixture is no longer reaching the
# comparison, and the four checks above are testing something else.
sed '/if \[ "\$stamp" != "\$pin" \]; then/,/^fi$/d' "$CHECK" > "$G8/mutant.sh"; chmod +x "$G8/mutant.sh"
printf '%s\n' "$OTHER" > "$G8/seed/hermes-agent/.moe-seed-commit"
if "$G8/mutant.sh" "$G8/seed" "$G8/install-hermes.sh" >/dev/null 2>&1; then
  ok "with the comparison removed the stale seed passes — so the refusal above is the comparison, not an accident"
else
  bad "the mutant still refused the stale seed: the fixture is not reaching the comparison"
fi
grep -q 'check-hermes-seed-commit.sh hermes-seed ./scripts/install-hermes.sh || exit 1' "$ROOT/build.sh" \
  && ok "build.sh runs the check before it bundles a seed" \
  || bad "build.sh does not run scripts/check-hermes-seed-commit.sh — the gate is not in the build"

# ── 9. A seed whose Python cannot start ────────────────────────────────────
#
# 0.3.13 shipped one. `cp -RL` in stage-hermes-seed.sh dereferenced the venv's
# interpreter symlink into a 17.3 MB copy, and a python-build-standalone binary
# copied out of its prefix cannot find its own standard library: it falls back
# to the prefix compiled into it, `/install`, and dies on `import encodings`.
# Moe installed, laid the seed down, spawned the brain, and the brain could not
# start — the island said "the part of Moe that thinks kept stopping" and
# Connections fell back to the ten Mac connectors it can find without one.
#
# Every gate that seed passed asked about its shape: stamp, links, size,
# placeholder, the three parts by name. A working seed and a dead one are
# identical under all of them. So check-hermes-seed-runs.sh starts it instead.
echo
echo "9. the seed's Python has to start"
RUNS="$ROOT/scripts/check-hermes-seed-runs.sh"
G9="$SCRATCH/g9"; rm -rf "$G9"; mkdir -p "$G9"

# A seed shaped like the real one, with a stand-in interpreter whose behaviour
# the test controls. `$1` is what it prints, `$2` its exit code.
fake_seed() {  # fake_seed <dir> <prints> <exit>
  local d="$1" out="$2" rc="$3"
  rm -rf "$d"; mkdir -p "$d/hermes-agent/.venv/bin"
  printf 'home = @HERMES_ROOT@/rt/bin\n' > "$d/hermes-agent/.venv/pyvenv.cfg"
  {
    printf '#!/bin/sh\n'
    printf 'd=$(cd "$(dirname "$0")/../../.." && pwd -P)\n'
    printf 'printf "%%s\\\\n" "%s"\n' "$out"
    printf 'exit %s\n' "$rc"
  } > "$d/hermes-agent/.venv/bin/python"
  chmod +x "$d/hermes-agent/.venv/bin/python"
}

fake_seed "$G9/good" '$d/rt' 0
"$RUNS" "$G9/good" >/dev/null 2>&1 \
  && ok "a seed whose python starts from inside itself passes" \
  || bad "the check refused a seed whose python starts from inside itself"

fake_seed "$G9/dead" 'ModuleNotFoundError: No module named '"'"'encodings'"'"'' 1
"$RUNS" "$G9/dead" >/dev/null 2>&1 \
  && bad "a seed whose python exits non-zero passed — this is 0.3.13 shipping again" \
  || ok "a seed whose python cannot start is refused"

# Exit 0 is not enough. A seed that starts by finding some *other* interpreter
# works on the builder's Mac and on no user's, because a user's Mac has none.
fake_seed "$G9/elsewhere" '/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14' 0
"$RUNS" "$G9/elsewhere" >/dev/null 2>&1 \
  && bad "a seed that started from another Mac-wide interpreter passed" \
  || ok "a seed that starts from outside itself is refused"

mkdir -p "$G9/novenv/hermes-agent"
"$RUNS" "$G9/novenv" >/dev/null 2>&1 \
  && bad "a directory with no .venv passed as a seed" \
  || ok "a tree with no hermes-agent/.venv is refused"

# The physics, against a real interpreter rather than a stand-in: the same
# bytes in the same tree pass as a symlink and fail as a copy. This is the
# whole bug, and nothing above would notice if the reason were something else.
RT=""
# A real python-build-standalone 3.14: the staged seed's own store first, then
# a uv-managed one. Read-only: it is cloned, never written.
for c in "$ROOT/hermes-seed/tools"/python-3.14*/ "$HOME/.local/share/uv/python"/cpython-3.14*/; do
  # Physically: uv keeps `cpython-3.14-…` as a symlink to the patch-level
  # directory, and `cp -R` of a link copies the link, so the "seed" below
  # started the uv interpreter by its absolute path and was refused as
  # running from outside itself — the check right, the fixture wrong.
  [ -x "$c/bin/python3.14" ] && { RT="$(cd "$c" && pwd -P)"; break; }
done
if [ -z "$RT" ]; then
  skipped=$((skipped+1))
  echo "  – no standalone 3.14 runtime on this Mac to build a real seed from (skipped)"
else
  build_real() {  # build_real <dir> copy|link
    local d="$1" how="$2"
    rm -rf "$d"; mkdir -p "$d/tools" "$d/hermes-agent/.venv/bin"
    cp -Rc "$RT" "$d/tools/rt" 2>/dev/null || cp -R "$RT" "$d/tools/rt"
    printf 'home = @HERMES_ROOT@/tools/rt/bin\nversion_info = 3.14\ninclude-system-site-packages = false\n' \
      > "$d/hermes-agent/.venv/pyvenv.cfg"
    mkdir -p "$d/hermes-agent/.venv/lib/python3.14/site-packages/yaml"
    # Moe's own code imports yaml from this venv (the check asks for it).
    printf '# stand-in\n' > "$d/hermes-agent/.venv/lib/python3.14/site-packages/yaml/__init__.py"
    if [ "$how" = link ]; then
      ln -s ../../../tools/rt/bin/python3.14 "$d/hermes-agent/.venv/bin/python3.14"
    else
      cp "$RT/bin/python3.14" "$d/hermes-agent/.venv/bin/python3.14"
    fi
    ln -s python3.14 "$d/hermes-agent/.venv/bin/python"
  }
  # tools/ without Hermes in it would trip the Hermes half of the check, which
  # is not what these two are about: the interpreter half is.
  build_real "$G9/real-link" link; mv "$G9/real-link/tools" "$G9/real-link/rt-tools"
  sed -i '' 's|@HERMES_ROOT@/tools/rt|@HERMES_ROOT@/rt-tools/rt|' "$G9/real-link/hermes-agent/.venv/pyvenv.cfg"
  rm "$G9/real-link/hermes-agent/.venv/bin/python3.14"
  ln -s ../../../rt-tools/rt/bin/python3.14 "$G9/real-link/hermes-agent/.venv/bin/python3.14"
  "$RUNS" "$G9/real-link" >/dev/null 2>&1 \
    && ok "a real seed whose interpreter is a relative symlink starts" \
    || bad "a real seed with a symlinked interpreter was refused — the check is wrong"
  # Without yaml the same seed is refused: configure-hermes.py and the plugins
  # import it, and upstream's 3.14 core no longer brings it.
  rm -rf "$G9/real-link/hermes-agent/.venv/lib/python3.14/site-packages/yaml"
  "$RUNS" "$G9/real-link" >/dev/null 2>&1 \
    && bad "a seed whose venv cannot import yaml passed — Moe could not configure its brain" \
    || ok "a seed whose venv cannot import yaml is refused"
  build_real "$G9/real-copy" copy; mv "$G9/real-copy/tools" "$G9/real-copy/rt-tools"
  sed -i '' 's|@HERMES_ROOT@/tools/rt|@HERMES_ROOT@/rt-tools/rt|' "$G9/real-copy/hermes-agent/.venv/pyvenv.cfg"
  if "$RUNS" "$G9/real-copy" >/dev/null 2>&1; then
    bad "a real seed with a COPIED interpreter passed — this is exactly what 0.3.13 shipped"
  else
    ok "a real seed with a copied interpreter is refused (the 0.3.13 bug, reproduced)"
  fi
  rm -rf "$G9/real-link" "$G9/real-copy"
fi

# And stage-hermes-seed.sh must produce the link, not the copy, or the gate
# above just moves the failure from the user to the builder every time.
grep -q 'ln -s "$PYREL" "$VBIN/$PYV"' "$ROOT/scripts/stage-hermes-seed.sh" \
  && ok "stage-hermes-seed.sh links the venv's interpreter into the runtime" \
  || bad "stage-hermes-seed.sh no longer links the venv's interpreter — it will ship a copy again"

grep -q 'check-hermes-seed-runs.sh hermes-seed || exit 1' "$ROOT/build.sh" \
  && ok "build.sh runs the seed before it bundles it" \
  || bad "build.sh does not run scripts/check-hermes-seed-runs.sh — the gate is not in the build"

grep -q 'check-hermes-seed-runs.sh" "$SEEDDIR"' "$ROOT/scripts/publish-release.sh" \
  && ok "publish-release.sh runs the seed inside the mounted image" \
  || bad "publish-release.sh does not run the seed — a dead brain could still be published"

echo
echo "10. Hermes from the seed finds its own Node, and building nothing is part of passing"
# The half of check-hermes-seed-runs.sh that the 3.14 seed added: Hermes reads
# Node only from its pm store, and lazy installs are off, so a store without
# Node is an app whose MCP servers and WhatsApp bridge cannot start. Against
# the REAL staged seed (a clone; the original is only read), because nothing
# smaller is a Hermes.
if [ -d "$ROOT/hermes-seed/tools" ] && [ -x "$ROOT/hermes-seed/hermes-agent/.venv/bin/hermes" ]; then
  G10="$SCRATCH/g10"; rm -rf "$G10"
  cp -Rc "$ROOT/hermes-seed" "$G10" 2>/dev/null || cp -R "$ROOT/hermes-seed" "$G10"
  "$RUNS" "$G10" >"$SCRATCH/g10.out" 2>&1 \
    && ok "the staged seed passes: $(tail -1 "$SCRATCH/g10.out")" \
    || { bad "the staged seed fails its own gate"; tail -3 "$SCRATCH/g10.out" | sed 's/^/      /'; }
  rm -rf "$G10"/tools/node-*
  if "$RUNS" "$G10" >"$SCRATCH/g10.out" 2>&1; then
    bad "a seed whose store has no Node passed — Hermes would ask pm to download one at first use"
  else
    command grep -q "did not find Node" "$SCRATCH/g10.out" \
      && ok "a seed whose store has no Node is refused, by name" \
      || { bad "refused, but not for Node"; tail -3 "$SCRATCH/g10.out" | sed 's/^/      /'; }
  fi
  rm -rf "$G10"
else
  skipped=$((skipped+1))
  echo "  – no 3.14 seed staged at $ROOT/hermes-seed (skipped; ./scripts/stage-hermes-seed.sh)"
fi

echo
if [ "$skipped" -gt 0 ]; then
  echo "$pass passed, $fail failed, $skipped skipped"
else
  echo "$pass passed, $fail failed"
fi
[ "$fail" -eq 0 ]
