#!/bin/bash
# Builds Memoe.app. No Xcode, no Homebrew, no npm — just the Command Line Tools.
set -euo pipefail
# A CDPATH exported by the person's shell (this Mac's ~/.zshrc has
# ".:$HOME/repos") makes bash's `cd dir` PRINT the directory, and every
# `( cd x && find . ) | while read f` below then reads that path as a file:
# catch-up failed on 2026-10-06 with `cp: moe-home//Users/…/moe-home`.
unset CDPATH

cd "$(dirname "$0")"
APP="dist/Memoe.app"
# The commit this build came from, stamped into the bundle below.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT+dirty"; fi
# Whether this build is the one being published. Every build between two
# releases carries the last release's CFBundleShortVersionString and
# CFBundleVersion — those are Sparkle's, and they move only when a release is
# cut — so a catch-up build of main and the published image both said
# "0.3.24 (31)" and a problem report could not tell them apart.
# publish-release.sh sets MOE_RELEASE_IS_PUBLISHED for the one build that goes
# to everybody; anything else says "unreleased build" beside its commit, in
# Settings › About and in `--build-info` (BuildInfo.swift). The two version
# keys are not touched.
MOE_RELEASE_BUILD=0
[ "${MOE_RELEASE_IS_PUBLISHED:-0}" = 1 ] && MOE_RELEASE_BUILD=1

# ── Which Moe is this: the one the person uses, or one we are working on ──
#
# On 2026-09-03 the same Mac's Moe was replaced three times in one day by
# three different mechanisms: an install from a branch behind main, an
# install that overrode the staleness guard, and — the one that actually
# confused the person for twenty minutes — a build launched straight out of
# a worktree's `dist/`, never installed at all. Every guard written that day
# watches the install path, and the last of those never went near it.
#
# The fix is not a better guard. On macOS an app's identity is its
# CFBundleIdentifier: Launch Services treats two bundles with the same one
# as the same app, sharing its preferences, its container, its privacy
# grants and its URL claims. Chrome Canary is com.google.Chrome.canary with
# its own data directory and its own icon; Firefox Nightly, VS Code
# Insiders and Tauri's debugApplicationIdSuffix are all the same shape. A
# development build that cannot occupy the release app's slot cannot take
# it, whoever runs what, and is obvious on screen when it is running.
#
# MOE_DEV=1 (or a `dev` argument) builds that: a different identity, a
# different name, a different home, no updater. Everything else about the
# build is identical, so what is tested is what ships.
# ── Which edition: official Memoe, or a community build of the open source ──
#
# The official identity — bundle id, URL scheme, Sparkle feed and key, the
# hosted edge, and the strictness a release needs — lives in ONE closed file,
# cloud/release.env, which the public export does not carry. Present (this
# private repo), it is sourced and every build is exactly what it was before
# the file existed. Absent (a fresh clone of the public repo), the build is a
# community build: its own bundle id, its own home, no updater, no cloud, and
# models downloaded on first use instead of refused. MOE_EDITION=community
# builds that here too, which is how scripts/test-editions.sh checks it.
#
# Presence rather than a flag a caller must remember: ship.sh, release.sh,
# install.sh and catch-up.sh all reach this line, and none of them can forget
# to say "official" — a stale copy passes through here anyway (CLAUDE.md,
# lesson six).
RELEASE_ENV="cloud/release.env"
if [ -z "${MOE_EDITION:-}" ]; then
  if [ -f "$RELEASE_ENV" ]; then MOE_EDITION=official; else MOE_EDITION=community; fi
fi
# Community values. release.env overrides every one of them.
#
# The community edition is named "Memoe OSS": the shape of Code - OSS (what
# Microsoft's vscode repo builds before its own branding goes on) and of
# Chromium beside Chrome. One word says what it is, and it never answers to
# the official name, id, scheme or home. TRADEMARK.md lets an unmodified build
# keep this name; a modified one takes its own. The id is under memoe.app,
# reversed, because that is a domain the project holds.
MOE_ID_BUNDLE="app.memoe.oss"
MOE_ID_URL_SCHEME="memoe-oss"
MOE_ID_APP_NAME="Memoe OSS"
MOE_ID_HOME="~/Library/Application Support/Memoe OSS"   # "" = the official default home
MOE_ID_DEV_HOME_NAME="Memoe OSS Dev"
MOE_ID_SPARKLE_FEED_URL=""
MOE_ID_SPARKLE_PUBLIC_KEY=""
MOE_ID_CLOUD_EDGE=""          # "" = no cloud: Away, sign-in and cloud voice stay hidden
MOE_ID_REQUIRE_MODELS=0       # 1 = refuse a build with no Models/ (a release must speak offline)
MOE_ID_PAYLOAD_DENY='BEGIN [A-Z ]*PRIVATE KEY'
case "$MOE_EDITION" in
  official)
    [ -f "$RELEASE_ENV" ] || { echo "✗ MOE_EDITION=official but $RELEASE_ENV is not in this checkout" >&2; exit 1; }
    # shellcheck source=/dev/null
    . "./$RELEASE_ENV" ;;
  community) ;;
  *) echo "✗ MOE_EDITION is '$MOE_EDITION' — official or community" >&2; exit 1 ;;
esac
export MOE_EDITION

MOE_DEV="${MOE_DEV:-0}"
case "${1:-}" in dev|--dev) MOE_DEV=1 ;; esac
if [ "$MOE_DEV" = 1 ]; then
  BUNDLE_ID="$MOE_ID_BUNDLE.dev"
  # Its own URL scheme too: a workbench build must never answer the link the
  # real Moe's checkout page opens (see CFBundleURLTypes below).
  URL_SCHEME="$MOE_ID_URL_SCHEME-dev"
  APP_NAME="$MOE_ID_APP_NAME Dev"
  APP="dist/Memoe Dev.app"
  # Its own home, so a development build can never write the notes,
  # memory, consent answers or connector tokens of the Moe in daily use.
  # `Paths` reads this at launch; nothing else needs to know.
  MOE_HOME_DEFAULT="$HOME/Library/Application Support/$MOE_ID_DEV_HOME_NAME"
  # And no updater: a dev build must never offer an update, nor accept
  # one. build.sh already refuses a half-configured Sparkle, so both go.
  MOE_SPARKLE_FEED_URL=""
  MOE_SPARKLE_PUBLIC_KEY=""
  export MOE_SPARKLE_FEED_URL MOE_SPARKLE_PUBLIC_KEY
else
  BUNDLE_ID="$MOE_ID_BUNDLE"
  URL_SCHEME="$MOE_ID_URL_SCHEME"
  APP_NAME="$MOE_ID_APP_NAME"
  MOE_HOME_DEFAULT="$MOE_ID_HOME"
fi
# The hosted edge this build talks to, stamped into Info.plist as MoeCloudEdge
# and read by Config.defaultCloudEdge. `${VAR-…}` so an explicit empty string
# turns the cloud off even in an official checkout.
MOE_CLOUD_EDGE="${MOE_CLOUD_EDGE-$MOE_ID_CLOUD_EDGE}"

# MOE_ON_DEMAND_COMPONENTS — the one switch for the slim download
# (docs/SLIM-DOWNLOAD.md). Stamped into Info.plist as MoeOnDemandComponents.
#
#   off      every model is in the app, and nothing else happens.
#   prepare  still every model in the app, and the app copies the on-demand
#            ones out of itself into the model cache at launch. Ship this ONE
#            RELEASE BEFORE `on`, so an install that updates to the slim build
#            already has them as real folders and re-downloads nothing.
#   on       the slim build: the folders named by ON_DEMAND_MODELS in
#            scripts/fetch-models.sh are left out of the app, which fetches
#            each the first time it is needed — pinned commit, sha256 per file.
#
# Anything else is refused: a typo here must not be read as either answer.
#
# **What a build gets when nobody says** comes from scripts/on-demand-plan.txt,
# by the version this file carries: a real Memoe — official edition, not Dev —
# takes the mode planned for its release, so 0.3.25 is `prepare` because the
# plan says so and not because whoever ran ship.sh remembered a variable.
# Here rather than in ship.sh, install.sh or catch-up.sh because every one of
# them ends up on this line, and a stale copy of any of them does too.
#
# Memoe Dev and a community build stay `off` unless asked: Dev shares the
# model caches with the real Memoe (Models.swift) and must not be the thing
# that rearranges them, and a community build carries no models to keep.
ON_DEMAND_VERSION="$(sed -n 's/.*CFBundleShortVersionString<\/key><string>\([^<]*\)<.*/\1/p' build.sh | head -1)"
ON_DEMAND_PLANNED=off
if [ "$MOE_EDITION" = official ] && [ "$MOE_DEV" != 1 ]; then
  if ! ON_DEMAND_PLANNED="$(./scripts/on-demand-plan.sh mode "$ON_DEMAND_VERSION")"; then
    echo "✗ cannot tell what version '$ON_DEMAND_VERSION' does about the on-demand models" >&2
    echo "  (scripts/on-demand-plan.txt). Not guessing: a wrong answer either ships a" >&2
    echo "  slim app nobody prepared for, or skips the release that prepares for it." >&2
    exit 1
  fi
fi
MOE_ON_DEMAND_COMPONENTS="${MOE_ON_DEMAND_COMPONENTS:-$ON_DEMAND_PLANNED}"
case "$MOE_ON_DEMAND_COMPONENTS" in
  off|prepare|on) ;;
  *) echo "✗ MOE_ON_DEMAND_COMPONENTS is '$MOE_ON_DEMAND_COMPONENTS' — off, prepare or on" >&2; exit 1 ;;
esac
# The build that goes to everybody is the planned one or it is not built.
# publish-release.sh asks the same question of the finished image; this is the
# same refusal forty minutes earlier, before the compiler and the notary.
if [ "$MOE_RELEASE_BUILD" = 1 ] && [ "$MOE_ON_DEMAND_COMPONENTS" != "$ON_DEMAND_PLANNED" ]; then
  echo "✗ this is the published build of $ON_DEMAND_VERSION, whose plan is '$ON_DEMAND_PLANNED'" >&2
  echo "  (scripts/on-demand-plan.txt), but MOE_ON_DEMAND_COMPONENTS is '$MOE_ON_DEMAND_COMPONENTS'." >&2
  echo "  Unset it, or change the plan in a commit — never for one build." >&2
  exit 1
fi
[ "$MOE_ON_DEMAND_COMPONENTS" = off ] || echo "  on demand: $MOE_ON_DEMAND_COMPONENTS (plan for $ON_DEMAND_VERSION: $ON_DEMAND_PLANNED)"

# MOE_BUILD_STAGE_ONLY=<dir>: assemble the bundle at <dir> — the real
# Info.plist, the real Resources — and stop before the compiler and before the
# keychain. scripts/test-release.sh uses it to check what a shipped app
# actually contains without a five-minute release build and without `security`
# ever being asked for an identity.
#
# It exists because the alternative is a test that keeps its own copy of the
# Info.plist keys, which would agree with itself forever and with build.sh
# never. The executable it leaves behind is a two-line stub, so this is a
# staging mode, not a build: it can produce nothing shippable.
STAGE_ONLY="${MOE_BUILD_STAGE_ONLY:-}"
[ -n "$STAGE_ONLY" ] && APP="$STAGE_ONLY"

if [ -n "$STAGE_ONLY" ]; then
  echo "› staging ${APP} (no compiler, no signature)…"
else
  echo "› compiling (release)…"
  # A neutral scratch path, not ./.build, and that is a privacy fix rather
  # than a preference. SwiftPM bakes the absolute path of its build directory
  # into the binary as `Bundle.module`'s fallback, so building under $HOME
  # publishes the author's username and directory layout to everyone who runs
  # `strings` on the app. Building under /tmp makes the embedded string
  # /tmp/moe-build/... and personal to nobody. MOE_SCRATCH overrides it.
  # Per-user, because /tmp is world-writable: a fixed /tmp/moe-build could be
  # pre-created by another local account, and whatever it contained would be
  # copied into the bundle and signed. The path still has to be impersonal —
  # it ends up inside the binary as Bundle.module's fallback — but impersonal
  # is not the same as fixed.
  SCRATCH_PATH="${MOE_SCRATCH:-/tmp/moe-build-$(id -u)}"
  # -L first: `-O` stats through a symlink, so a link planted in world-writable
  # /tmp pointing at something the builder owns would pass the ownership test
  # and then be built into.
  if [ -L "$SCRATCH_PATH" ]; then
    echo "✗ $SCRATCH_PATH is a symlink — refusing to build into it" >&2
    exit 1
  fi
  if [ -e "$SCRATCH_PATH" ] && [ ! -O "$SCRATCH_PATH" ]; then
    echo "✗ $SCRATCH_PATH exists and is not yours — refusing to build into it" >&2
    exit 1
  fi
  mkdir -p "$SCRATCH_PATH"
  chmod 700 "$SCRATCH_PATH"
  # **macOS reaps /tmp, and a reaped SwiftPM cache does not look reaped.**
  # /etc/periodic/daily/110.clean-tmps deletes FILES under /tmp that have not
  # been touched for three days and leaves the DIRECTORIES standing. So a
  # checkout that has sat unbuilt over a weekend comes back as a directory
  # full of sources with no Package.swift in it, and SwiftPM reports
  #
  #   error: the package manifest at '.../argmax-oss-swift/Package.swift'
  #   cannot be accessed (... doesn't exist in file system)
  #   error: XCFramework Info.plist not found at '.../NemoTextProcessing.xcframework'
  #
  # which reads as "this dependency is broken" and is really "this Mac tidied
  # up". It cost two failed catch-up runs on 2026-09-10 before anyone looked
  # in the directory. Moving the scratch off /tmp is NOT the fix: the comment
  # above is load-bearing -- SwiftPM bakes this absolute path into the binary
  # as Bundle.module's fallback, so a scratch under $HOME ships the builder's
  # username to everyone who runs `strings` on the app.
  #
  # So: check the cache is COHERENT before building, rather than matching the
  # error text afterwards. A checkout with no manifest and an .xcframework
  # with no Info.plist are both things that cannot legitimately occur, and
  # asking the artefact needs no list of error strings to keep current.
  reaped=""
  for d in "$SCRATCH_PATH"/checkouts/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}Package.swift" ] || reaped="${reaped}${d}Package.swift is gone\n"
  done
  while IFS= read -r fw; do
    [ -n "$fw" ] || continue
    [ -f "$fw/Info.plist" ] || reaped="${reaped}$fw/Info.plist is gone\n"
  done <<EOF
$(find "$SCRATCH_PATH/artifacts" -type d -name '*.xcframework' 2>/dev/null)
EOF
  if [ -n "$reaped" ]; then
    echo "› the build cache was tidied away by macOS, not broken by a dependency:" >&2
    printf "%b" "$reaped" | sed 's/^/    /' >&2
    echo "› clearing $SCRATCH_PATH and fetching again" >&2
    rm -rf "$SCRATCH_PATH"
    mkdir -p "$SCRATCH_PATH"
    chmod 700 "$SCRATCH_PATH"
  fi
  # Package.swift adds the closed targets only when cloud/targets.json is here, and
  # SwiftPM caches an evaluated manifest by its contents, not by what is on
  # disk -- so a checkout that built WITH cloud/ and then lost it would build
  # the stale target list. Re-evaluating costs about a second.
  MANIFEST_CACHE=()
  [ -f cloud/targets.json ] || MANIFEST_CACHE=(--manifest-cache none)
  swift build -c release --scratch-path "$SCRATCH_PATH" ${MANIFEST_CACHE[@]+"${MANIFEST_CACHE[@]}"}
fi

echo "› assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ -n "$STAGE_ONLY" ]; then
  printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/Moe"
  chmod +x "$APP/Contents/MacOS/Moe"
  printf '#!/bin/sh\nexit 2\n' > "$APP/Contents/MacOS/moe-confirm"
  chmod +x "$APP/Contents/MacOS/moe-confirm"
  ln -s moe-confirm "$APP/Contents/MacOS/moe-secret"
else
  cp "$SCRATCH_PATH/release/Moe" "$APP/Contents/MacOS/Moe"
  # The send-confirmation dialog (Sources/MoeConfirm). A second executable in
  # the same bundle, not a window in the app, because moe-home/tools/confirm.sh
  # is called from shells and hooks that run whether or not Moe is up — and a
  # gate that needs the app running is a gate with an off switch. It rides
  # inside Contents/MacOS so it is under the same signature as everything else:
  # this is the one binary on the Mac whose exit status means "the human said
  # send", and it should not be replaceable without breaking the seal.
  cp "$SCRATCH_PATH/release/MoeConfirm" "$APP/Contents/MacOS/moe-confirm"
  # The password window (Sources/MoeConfirm/SecretMain.swift) is the same
  # program reached by another name: Hermes runs HERMES_SECRET_PROMPT_CMD as
  # a bare path with no arguments, so the name is the switch. A relative link
  # inside Contents/MacOS, under the bundle's seal like the card itself —
  # the window that is handed a person's password must not be a file anything
  # else on the Mac can replace. HermesSupervisor points Hermes at it.
  ln -s moe-confirm "$APP/Contents/MacOS/moe-secret"

  # Strip the debug map before anything else touches these binaries.
  #
  # A SwiftPM release build still carries N_OSO debug-map entries — one per
  # object file — and each is an absolute path into the machine that built it.
  # On 0.2.0 that was 462 entries and 920 occurrences of the author's home
  # directory, so `strings Memoe.app/Contents/MacOS/Moe | grep /Users/` handed a
  # downloader the developer's username, their directory layout and the name
  # of every file in a private source tree. It is the largest thing in a
  # bundle that is meant to be identical for everyone.
  #
  # `strip -S` removes debug symbols and leaves the symbol table, which is the
  # level a release wants: crash reports still resolve public symbols, and
  # nothing that Swift's runtime reflects on lives in the debug map. It must
  # happen before install_name_tool and before codesign, both of which are
  # below — stripping after signing would invalidate the signature.

  # ---- SwiftPM resource bundles ----------------------------------------
  # FluidAudio ships its English G2P lexicon this
  # way (luxtts_en_us_lexicon.tsv.zz + luxtts_en_us_g2p_aux.json), reached
  # through `Bundle.module`. That accessor looks in Bundle.main's resources
  # first and falls back to the *build directory* — which exists on the
  # machine that compiled the app and on no other. So this was working here
  # and would have failed on a stranger's Mac, silently, in the part of Moe
  # that turns text into speech. Copy them in; there is no supported way to
  # ask SwiftPM to do it for a hand-assembled bundle.
  for b in "$SCRATCH_PATH"/release/*.bundle; do
    [ -e "$b" ] || continue
    rm -rf "$APP/Contents/Resources/$(basename "$b")"
    cp -R "$b" "$APP/Contents/Resources/$(basename "$b")"
    echo "  bundle:  $(basename "$b")"
  done

  strip -S "$APP/Contents/MacOS/Moe" "$APP/Contents/MacOS/moe-confirm"
  # This machine's home specifically, not /Users/ generally: the binary also
  # carries /Users/runner/.cargo/... paths from the GitHub Actions machine
  # that built an upstream Rust crate, and those are upstream artifacts rather
  # than anything about whoever built Moe.
  for bin in Moe moe-confirm; do
    # -F and unanchored. `grep -c "^$HOME"` interpolated a path into a regular
    # expression (a dot in a username is a wildcard) and only matched strings
    # that *begin* with it — while a debug-map entry is as likely to read
    # "-I/Users/…" as "/Users/…".
    left=$(strings -a "$APP/Contents/MacOS/$bin" 2>/dev/null | grep -cF "$HOME" || true)
    if [ "${left:-0}" != 0 ]; then
      echo "✗ $left paths inside the builder's home are still in Contents/MacOS/$bin" >&2
      # The same grep as the count. It was left anchored and regex while the
      # count became unanchored and fixed-string, so precisely the mid-line
      # matches the fix was written for printed no evidence at all — and
      # pipefail then killed the script before the exit below.
      strings -a "$APP/Contents/MacOS/$bin" 2>/dev/null | grep -F "$HOME" | head -3 >&2 || true
      exit 1
    fi
  done
fi
if [ -f Resources/Moe.icns ]; then
  cp Resources/Moe.icns "$APP/Contents/Resources/Moe.icns"
  # Moe Dev wears a different face, and this is not decoration.
  #
  # A person spent twenty minutes on 2026-09-03 looking at a months-old
  # build wondering what had happened to their Mac, because the only thing
  # distinguishing it from their own Moe was a version string inside the
  # bundle. A name in the menu bar is read; an icon in the Dock is *seen*,
  # without looking for it. Chrome Canary is gold and Firefox Nightly is
  # blue for exactly this reason.
  #
  # Built rather than committed as a second .icns: derived from the real
  # icon by hue rotation, so the dev icon can never drift from the app's
  # own artwork, and there is no second file to keep in step. If any step
  # is unavailable the plain icon is used — a build must not fail over its
  # icon, and an unmarked dev build is still safely a different app.
  if [ "$MOE_DEV" = 1 ] && command -v iconutil >/dev/null 2>&1 \
     && command -v swift >/dev/null 2>&1 && [ -f scripts/dev-icon.swift ]; then
    devtmp="$(mktemp -d)"
    if iconutil -c iconset -o "$devtmp/Moe.iconset" Resources/Moe.icns 2>/dev/null; then
      recoloured=0
      for png in "$devtmp/Moe.iconset"/*.png; do
        [ -f "$png" ] || continue
        if swift scripts/dev-icon.swift "$png" "$png.dev" 2>/dev/null && [ -s "$png.dev" ]; then
          mv "$png.dev" "$png"
          recoloured=1
        else
          rm -f "$png.dev"
        fi
      done
      # Only replace the icon if every size actually changed colour. A
      # half-recoloured iconset would show the real icon at some sizes and
      # the dev one at others, which is worse than either.
      if [ "$recoloured" = 1 ] && iconutil -c icns -o "$devtmp/Dev.icns" "$devtmp/Moe.iconset" 2>/dev/null; then
        cp "$devtmp/Dev.icns" "$APP/Contents/Resources/Moe.icns"
      fi
    fi
    rm -rf "$devtmp"
  fi
fi
# Each connected service's real mark, fetched once by
# scripts/fetch-service-icons.sh and committed. Bundled rather than fetched at
# runtime: asking each company for its favicon on the user's Mac would tell
# every one of them which tools that user has connected. Absent is survivable —
# ServiceIcon falls back to a monogram in the service's own colour.
# "Hey Moe": the frozen mel + speech-embedding front ends and the trained
# classifier (VOICE-PLAN.md §4.1). WakeHead.swift looks for them here.
if [ -d Resources/WakeWord ]; then
  cp -R Resources/WakeWord "$APP/Contents/Resources/WakeWord"
fi
if [ -d Resources/ServiceIcons ]; then
  cp -R Resources/ServiceIcons "$APP/Contents/Resources/ServiceIcons"
fi
# The Google Docs picker reads its sign-in client from the bundle. Gitignored
# and absent in a fresh checkout, so this is optional: without it that one
# connector reports "not configured" and nothing else is affected.
if [ -f Resources/google-client.json ]; then
  cp Resources/google-client.json "$APP/Contents/Resources/google-client.json"
  chmod 600 "$APP/Contents/Resources/google-client.json"
  # Said out loud, because this file is gitignored and everything else that is
  # gitignored is a secret we must never publish. This one is different and the
  # difference is worth stating: it is a Google **Desktop** OAuth client, and
  # Google documents that an installed app cannot keep its client secret
  # confidential — the flow is protected by PKCE, not by the secret. Shipping
  # it is what makes "Connect Google Docs" one click. Anyone who extracts it
  # can spend this project's OAuth quota, which is the accepted cost.
  echo "  google:  embedding the Desktop OAuth client — it ships to everyone who downloads this"
fi

# The licence texts ride inside the app, not only in the repo.
#
# Apache-2.0 §4(a) requires a copy of the License to travel with every
# distribution, and NOTICE's own opening says "Full licence texts are in
# THIRD_PARTY_LICENSES/" — which is false for anyone who only ever has the
# dmg. release.sh copies the whole .app into the image, so this is the step
# that actually puts them in a downloader's hands.
#
# Contents/Resources is the conventional place, and it is inside the seal:
# codesign (below) hashes everything under Contents, so these arrive
# tamper-evident rather than merely present. No `if [ -f ]` guard, unlike
# the icon above: a build with no licence texts is not one we may ship, so
# a missing file must stop the build, not shrug.
cp NOTICE "$APP/Contents/Resources/NOTICE"
cp -R THIRD_PARTY_LICENSES "$APP/Contents/Resources/THIRD_PARTY_LICENSES"

# ---- the ~/.moe payload ------------------------------------------------------
# Everything Moe needs on disk that is not the binary: the connectors and their
# manifests, the tools the model shells out to, lib/, prompts/, learn/, the
# Hermes glue with its plugins and jobs, sync/doctor/learn/nudge, the connect
# scripts the Connections pane launches by path, and the starter vocabulary.
#
# Until 2026-08-31 all of it reached a Mac only through scripts/install.sh,
# which copies it out of a **git checkout of a private repo**. Someone who
# downloaded the dmg got an app with an empty Connections pane and a Brain
# pane that could not choose a provider, and nothing said why: the fallback in
# ConnectionsModel.swift to ~/moe/... always hits on a developer's Mac and can
# never hit on anyone else's. docs/BUNDLE.md §1.
#
# The tree here mirrors ~/.moe one for one, so the installer that lays it down
# (FirstRun.installPayloadIfNeeded) is a plain recursive copy with no name list
# of its own to drift out of date. It is staged under Contents/Resources, i.e.
# inside the code signature, so what lands in ~/.moe is what we signed.
#
# It is a *seed*, not the live copy: the app copies it out on first run rather
# than running from inside the bundle. connectors/ holds credentials beside its
# own code (gmail-accounts.json, telegram.session, drive-docs-files.json),
# tools/ must stay a sibling of connectors/ because gmail.py locates
# confirm.sh by its own realpath, and nothing may be chmod'd or written inside
# a signed bundle. Copying out answers all three at once.
PAYLOAD="$APP/Contents/Resources/moe-home"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD"
# All of moe-home/ except the test suites and hermes-toolsets.md, which are
# repo documentation — install.sh has never copied either into ~/.moe.
( cd moe-home && find . -type d -name tests -prune -o -type f \
    ! -name hermes-toolsets.md -print ) \
  | while IFS= read -r f; do
      mkdir -p "$PAYLOAD/$(dirname "$f")"
      cp "moe-home/$f" "$PAYLOAD/$f"
    done
# The connect flows live in scripts/, not moe-home/, and land in ~/.moe/scripts.
# Named one by one, exactly as install.sh names them: a glob that silently
# matches nothing is the failure this must not have.
mkdir -p "$PAYLOAD/scripts"
# connect-whatsapp-bot.sh: connect-whatsapp.sh has been a one-line exec of it
# since 2026-09-09, and for two days the download shipped the wrapper without
# the script it hands off to — the WhatsApp row said "Getting a code for you…"
# over a file that was not there. test-fresh-install.sh now derives every such
# hand-off from the scripts themselves, so the next one is a red test, not a
# spinner.
for f in connect.sh connect-gmail.sh connect-telegram.sh connect-drive-docs.sh \
         connect-telegram-bot.sh connect-whatsapp.sh connect-whatsapp-bot.sh \
         connect-signal.sh fetch-signal-cli.sh signal-daemon.sh \
         connect-mcp.sh pairing.sh \
         hermes-signin.sh hermes-codex-signin.sh install-hermes.sh install-claude.sh \
         refresh-hermes-seed.sh reseed-hermes.sh fetch-hermes-browser.sh \
         uninstall-hermes.sh import-assistant-dump.sh; do
  # The one-click Telegram bot is made by our edge, so the open-source export
  # does not carry its script (.oss/manifest). A community build has no edge;
  # connect.sh says the script is missing if anyone asks it for the bot.
  if [ "$f" = connect-telegram-bot.sh ] && [ "$MOE_EDITION" = community ] && [ ! -f "scripts/$f" ]; then
    echo "  payload: no scripts/$f (community build: the one-click Telegram bot needs our edge)"
    continue
  fi
  if [ ! -f "scripts/$f" ]; then
    echo "✗ scripts/$f is missing — the app would ship a Connections pane that cannot connect" >&2
    exit 1
  fi
  cp "scripts/$f" "$PAYLOAD/scripts/$f"
done
echo "  payload: $(find "$PAYLOAD" -type f | wc -l | tr -d ' ') files, $(du -sh "$PAYLOAD" | cut -f1)"

# Nothing personal in the payload. This is not hypothetical and it is not a
# one-off: the payload ships to everyone, three separate leaks have been found
# in it (a real WhatsApp contact, a real group chat, a live phone number), and
# a fourth arrived afterwards — a real name in an example address inside the
# moe-connectors plugin, written by someone documenting a comma-splitting bug.
# A release-time check found that one; this finds the next one at the moment
# it is built, which is when whoever wrote it is still here to fix it.
#
# The publisher's own home path is checked too: an absolute path that leaks
# into a script would name them.
# A degenerate HOME would match everything: `grep -F ""` matches every file
# and `grep -F /` every file with a slash in it. Both are reachable — env -i,
# a launchd context, a stripped sudo — and the failure would read as though
# the whole payload were a leak.
case "$HOME" in
  ""|/) echo "✗ HOME is ${HOME:-empty}; refusing to guess what is personal" >&2; exit 1 ;;
esac
# Compiled Python goes first, because it is generated rather than written and
# it carries the absolute path of the source it was compiled from. Moe 0.3.5
# shipped two of them, and the path inside named the builder's username and
# the worktree they happened to be in:
#
#   /Users/<name>/moe/.claude/worktrees/crons-proactive/moe-home/hermes/…
#
# They are regenerated on the user's Mac the first time Python imports the
# module, so removing them costs nothing at all.
find "$PAYLOAD" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$PAYLOAD" -name '*.pyc' -delete 2>/dev/null || true

# --binary-files=text, not -I.
#
# `grep -I` skips binary files *by definition*, and a .pyc is binary — so the
# gate below read the payload, found nothing, and passed a bundle that had the
# builder's home directory in it. The same blind spot was found in the Hermes
# seed gate the day before; this is the other half of it. A check that cannot
# see the file class most likely to embed a build path is not a check.
if [ -n "$(grep -rl --binary-files=text -F "$HOME" "$PAYLOAD" 2>/dev/null)" ]; then
  echo "✗ the payload contains this machine's home directory:" >&2
  grep -rl --binary-files=text -F "$HOME" "$PAYLOAD" 2>/dev/null | sed 's/^/    /' >&2
  exit 1
fi
if [ -n "$(grep -rl --binary-files=text -E "$MOE_ID_PAYLOAD_DENY" "$PAYLOAD" 2>/dev/null)" ]; then
  echo "✗ an address or a private key is in the payload:" >&2
  grep -rl --binary-files=text -E "$MOE_ID_PAYLOAD_DENY" "$PAYLOAD" 2>/dev/null | sed 's/^/    /' >&2
  exit 1
fi

# ---- the speech and voice models ---------------------------------------------
# Without these, a stranger's first run downloads 806 MB from Hugging Face
# before Moe can answer once — behind a status line reading "loading speech
# recognition…" with no percentage — and on an offline Mac it never works at
# all. scripts/fetch-models.sh stages them into Models/ (gitignored: ~900 MB
# of Core ML weights do not belong in a git history), and this copies them in.
#
# Optional, like the icon and unlike the licences: a build without them is a
# perfectly good build that simply downloads on demand, which is what every
# development build should do rather than carry a gigabyte around. release.sh
# is where their absence is worth saying out loud.
# Skipped when staging: MOE_BUILD_STAGE_ONLY exists to produce an Info.plist
# and a Resources tree for the tests, and copying 889 MB for each of the five
# staging runs in a test pass is minutes of nothing.
if [ -d Models ] && [ -z "$STAGE_ONLY" ]; then
  # A symlink here is never right, and it is the shape of a specific
  # mistake: the app links FluidAudio's caches into its own bundle, so
  # re-staging from a cache without dereferencing produces links into an app
  # that is about to be deleted. Ship those and the bundle is a few kilobytes
  # of dangling pointers that report themselves as models.
  # `find … | grep -q .` is the wrong shape for a gate: grep exits on the
  # first line, the producer takes SIGPIPE, and pipefail turns that into a
  # non-zero pipeline that reads as "no match". Small trees finish first so it
  # passes today; a safety check should not depend on that.
  if [ -n "$(find Models -type l)" ]; then
    echo "✗ Models/ contains symlinks — re-run ./scripts/fetch-models.sh" >&2
    find Models -type l | head -3 >&2
    exit 1
  fi
  rm -rf "$APP/Contents/Resources/Models"
  cp -R Models "$APP/Contents/Resources/Models"
  mb=$(du -sm "$APP/Contents/Resources/Models" | cut -f1)
  if [ "${mb:-0}" -lt "${MOE_MIN_MODELS_MB:-500}" ]; then
    echo "✗ the bundled models are only ${mb} MB — expected ~900 MB" >&2
    exit 1
  fi

  # …and the same question asked the other way, because a minimum can only
  # ever catch half of it. scripts/check-bundled-models.sh says why, and is
  # a separate script so scripts/test-models.sh can watch it refuse.
  if ! ./scripts/check-bundled-models.sh "$APP/Contents/Resources/Models"; then
    echo "  (this is what shipped 937 MB of two deleted engines on 2026-09-06)" >&2
    exit 1
  fi

  # The voice the app speaks in by default must be inside the app. This
  # has now shipped wrong twice in opposite directions — a default naming
  # a model that was not bundled, then a bundle missing the model the
  # default named — and both times it was a line of output nobody read.
  # An error, on stderr, where a discarded stdout cannot hide it.
  # Read the default from the ONE constant that decides it, not from
  # Config.swift's declaration. Config now says
  # `var ttsEngine: String = TtsEngineKind.shipped.rawValue` — deliberately,
  # because a literal there is what let the default and the staged set
  # disagree in a shipped build, and TtsShippedDefaultTests enforces the
  # non-literal form. The old sed looked for the literal, found nothing, and
  # left `want` empty: `[ -n "$need" ]` was then false and this whole
  # refusal was skipped. A blind gate that reports success is worse than no
  # gate, and it is the third one in this repo to fail that way.
  want=$(sed -n 's/.*static let shipped: TtsEngineKind = \.\([a-z]*\).*/\1/p' \
           Sources/Moe/TtsBackends.swift | head -1)
  if [ -z "$want" ]; then
    echo "✗ cannot tell which voice this build defaults to." >&2
    echo "  TtsEngineKind.shipped was not readable in Sources/Moe/TtsBackends.swift." >&2
    echo "  Refusing rather than guessing — a guard that cannot see what it" >&2
    echo "  guards must not report success." >&2
    exit 1
  fi
  case "$want" in
    kokoro)     need=kokoro-82m-coreml ;;
    apple)      need="" ;;   # the system's own voices; nothing to bundle
    inworld)
      # The cloud voice. It bundles nothing — that is the point of it — and
      # for the same reason it must never be the default: it needs an
      # entitlement and a network, and a fresh Mac has to speak offline.
      # An explicit arm rather than the catch-all so the reason is on the
      # screen, not "no model mapping" for an engine that has no model.
      echo "✗ TtsEngineKind.shipped is 'inworld', the cloud voice. It needs no" >&2
      echo "  bundled model, which is exactly why it cannot be the default: a" >&2
      echo "  fresh Mac with no entitlement and no network would have no voice." >&2
      exit 1 ;;
    *)
      echo "✗ TtsEngineKind.shipped is '$want', which build.sh has no model" >&2
      echo "  mapping for. Add one here in the same commit that added it." >&2
      exit 1 ;;
  esac

  # The on-demand components. Nothing here runs in the default build.
  # scripts/slim-bundled-models.sh says what it checks and why, and is a
  # separate script so scripts/test-slim.sh can watch it refuse. It runs
  # after check-bundled-models.sh on purpose: that check wants every listed
  # model present, and this is the only thing allowed to take one away.
  if [ "$MOE_ON_DEMAND_COMPONENTS" != off ]; then
    if ! ./scripts/slim-bundled-models.sh "$MOE_ON_DEMAND_COMPONENTS" Models "$APP/Contents/Resources/Models"; then
      exit 1
    fi
  fi

  if [ -n "$need" ] && [ ! -d "$APP/Contents/Resources/Models/$need" ]; then
    echo "✗ the default voice is '$want' but $need is not in the bundle." >&2
    echo "  Run ./scripts/fetch-models.sh in this checkout, or change the default." >&2
    exit 1
  fi
  echo "  models:  $(du -sh "$APP/Contents/Resources/Models" | cut -f1) ($(ls "$APP/Contents/Resources/Models" | tr '\n' ' '))"
elif [ -z "$STAGE_ONLY" ] && [ "$MOE_ID_REQUIRE_MODELS" != 1 ]; then
  # A community build: no models is fine. The app downloads each one the
  # first time it is needed (Models.swift), and scripts/fetch-models.sh needs
  # a built app to fetch them at all — refusing here would deadlock a fresh
  # clone. The official edition still refuses, below.
  echo "  models:  none bundled — they download on first use (./scripts/fetch-models.sh to bundle them)"
elif [ -z "$STAGE_ONLY" ]; then
  # No models at all. The app can download them, but the voice it is
  # configured to speak in would be a 766 MB wait on the first sentence,
  # and this is the branch that shipped: build.sh said so on a stdout
  # install.sh was discarding.
  echo "✗ no Models/ in this checkout, so the app would ship with no voice." >&2
  echo "  Run ./scripts/fetch-models.sh here first." >&2
  exit 1
else
  echo "  models:  none bundled (staging only)"
fi

# ---- the Hermes seed ---------------------------------------------------------
# The part of Moe that thinks. Without it in the bundle, onboarding reaches the
# brain step and runs a `git clone` plus a `curl … | sh` on the user's Mac —
# which fails on a plane, behind a proxy, or on a bad GitHub day, and asks a
# stranger to trust two hosts at the moment they can least judge it. Seeded, it
# is inside the image Apple notarized.
#
# scripts/stage-hermes-seed.sh builds it from a commit of the fork — the code by
# `git archive`, the venv by `pm.build_env --sealed`, Hermes's own tool store
# (tools/: Python 3.14, Node, npm, uv, ffmpeg, ripgrep, the browser) by
# `pm.prepare_tools` — never from anybody's ~/.hermes, and rewrites every
# absolute path to @HERMES_ROOT@, which HermesSeed.swift substitutes back on
# first run.
#
# Optional, exactly like Models/: a build without it downloads Hermes on
# demand, which is what a development build should do rather than carry 400 MB
# around. Skipped when staging, for the same reason the models are.
if [ -d hermes-seed ] && [ -z "$STAGE_ONLY" ]; then
  # The rewrite is what makes the seed identical for everyone. If this
  # machine's home is still in there, the staging script did not finish, and
  # shipping it would publish the builder's directory layout to every user
  # and break every shebang on their Mac at the same time.
  # --binary-files=text, not -I. `grep -I` skips binary files, and a compiled
  # extension module with the build path baked into it is precisely the case
  # the staging script cannot repair and therefore the one this most needs to
  # see.
  #
  # Bytecode caches first, though: they are never part of a seed (staging
  # runs with PYTHONDONTWRITEBYTECODE=1), and since the 3.14 seed's Python
  # writes them into its own stdlib whenever anything starts it in place,
  # every one embeds the path it was started from. 0.3.22's first build
  # refused on 31 of them. A cache is regenerated on the user's Mac; deleting
  # it here loses nothing, and the check below still sees everything else.
  find hermes-seed -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  if [ -n "$(grep -rl --binary-files=text -F "$HOME" hermes-seed 2>/dev/null | head -1)" ]; then
    echo "✗ hermes-seed/ still contains the builder's home — re-run ./scripts/stage-hermes-seed.sh" >&2
    grep -rl --binary-files=text -F "$HOME" hermes-seed 2>/dev/null | head -3 | sed 's/^/    /' >&2
    exit 1
  fi
  # Same trap as Models/: a seed of dangling links reports itself as a runtime
  # right up until the first spawn on a machine that is not this one. The
  # interpreter links stage-hermes-seed.sh makes are RELATIVE and resolve
  # inside the seed (the venv's python3.14 into tools/python-…) —
  # that is the design, not the trap, and refusing every link refused every
  # seed the current script stages (found 2026-09-07). An absolute target,
  # or a dangling one, is still the trap.
  seed_bad_links() {
    find hermes-seed -type l | while IFS= read -r l; do
      t="$(readlink "$l")"
      if [ "${t#/}" != "$t" ]; then echo "$l -> $t (absolute)"; fi
      [ -e "$l" ] || echo "$l -> $t (dangling)"
    done
  }
  bad_links="$(seed_bad_links)"
  if [ -n "$bad_links" ]; then
    echo "✗ hermes-seed/ contains symlinks that would not survive the copy — re-run ./scripts/stage-hermes-seed.sh" >&2
    printf '%s\n' "$bad_links" | head -3 >&2
    exit 1
  fi
  rm -rf "$APP/Contents/Resources/hermes-seed"
  cp -R hermes-seed "$APP/Contents/Resources/hermes-seed"
  # The pieces by name, before the size. A floor alone let a seed of
  # `node` + `python` and no `hermes-agent` at all through — 200 MB of runtime
  # with nothing to run, which is an app whose brain cannot start and whose
  # build said nothing. Since the Python 3.14 seed the runtime is one piece,
  # tools/ (Hermes's pm store), and the old python/ + node/ are gone.
  for part in hermes-agent tools; do
    [ -d "$APP/Contents/Resources/hermes-seed/$part" ] || {
      echo "✗ the bundled Hermes seed has no $part — re-run ./scripts/stage-hermes-seed.sh" >&2
      exit 1
    }
  done
  # And it is THE Hermes this build pins, by stamp. The seed in 0.3.12 was
  # older than the pin and nothing here could tell (docs/BUNDLE.md §5c); a
  # seed with no stamp is refused too, because that is what that seed had.
  ./scripts/check-hermes-seed-commit.sh hermes-seed ./scripts/install-hermes.sh || exit 1
  # And it can start. Every check above and below this line asks about the
  # seed's *shape*; 0.3.13 shipped a seed with the right shape and a Python
  # that died on `import encodings`, so every download was a Moe whose brain
  # could not boot. Only running it can tell the two apart.
  ./scripts/check-hermes-seed-runs.sh hermes-seed || exit 1
  # Size and shape: ~687 MB, no Chrome for Testing (fetched on first launch),
  # no build-time headers. Floor and ceiling and why: check-hermes-seed-size.sh.
  ./scripts/check-hermes-seed-size.sh "$APP/Contents/Resources/hermes-seed" || exit 1
  echo "  hermes:  $(du -sh "$APP/Contents/Resources/hermes-seed" | cut -f1) seeded"
else
  echo "  hermes:  none bundled (./scripts/stage-hermes-seed.sh stages it)"
fi

# Sparkle rides in Contents/Frameworks.
#
# SwiftPM links the binary against @rpath/Sparkle.framework and gives it only
# an @loader_path rpath — which is Contents/MacOS inside a bundle, not
# Contents/Frameworks. Without the added rpath below dyld cannot find the
# framework and the app does not launch at all, so the two steps are one step.
# install_name_tool invalidates any existing signature, which is why this
# happens before the codesign at the bottom of this file.
#
# Staging mode skips it: the stub executable is a shell script, and
# install_name_tool has nothing to edit in a shell script.
if [ -z "$STAGE_ONLY" ]; then
  if [ -d "$SCRATCH_PATH/release/Sparkle.framework" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
    cp -R "$SCRATCH_PATH/release/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Moe"
  elif otool -L "$APP/Contents/MacOS/Moe" | grep -q '@rpath/Sparkle\.framework'; then
    # Linked against a framework that is not in the bundle: dyld kills the app
    # at launch, on the user's Mac, with no dialog worth reading. A build that
    # cannot start is not a build, so this is fatal rather than a warning.
    echo "✗ the binary links Sparkle but $SCRATCH_PATH/release/Sparkle.framework is missing" >&2
    exit 1
  fi
fi

# Sparkle's feed and its Ed25519 public key, from the environment:
#
#   MOE_SPARKLE_FEED_URL    https URL of the appcast   (docs/RELEASING.md §3)
#   MOE_SPARKLE_PUBLIC_KEY  `generate_keys -p` output  (docs/RELEASING.md §1.4)
#
# Empty means the keys are **omitted**, not written blank. Sparkle treats a
# present-but-unusable SUFeedURL as a misconfigured app and puts an alert in
# front of the user telling them to contact the developer — so a blank key
# would turn every checkout build into a support request. Absent is what
# Sources/Moe/Updates.swift checks for before it starts the updater or offers
# the menu item; with the keys absent the app behaves exactly as it did before
# Sparkle existed.
#
# One without the other is always a mistake — a feed with no key means Sparkle
# cannot verify anything it downloads — so it stops the build rather than
# shipping half a configuration. That is why turning the updater off means
# setting **both** to the empty string: emptying only one leaves the other on
# its default and the build stops, which is the guard working as intended.
#
# They default to the real feed and the real key, because a release built
# without them is a release that can never update itself, and nothing about
# the build would say so. The key here is the *public* half — it is meant to
# be published, and is worthless without the private half in the keychain.
# `${VAR-...}` rather than `${VAR:-...}` on purpose: an explicitly empty
# string has to survive the default, or a local build could not opt out at
# all. Both must be emptied together — see above.
MOE_SPARKLE_FEED_URL="${MOE_SPARKLE_FEED_URL-$MOE_ID_SPARKLE_FEED_URL}"
MOE_SPARKLE_PUBLIC_KEY="${MOE_SPARKLE_PUBLIC_KEY-$MOE_ID_SPARKLE_PUBLIC_KEY}"

SPARKLE_PLIST=""
if [ -n "${MOE_SPARKLE_FEED_URL:-}" ] && [ -n "${MOE_SPARKLE_PUBLIC_KEY:-}" ]; then
  xmlesc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  SPARKLE_PLIST="
  <key>SUFeedURL</key>
  <string>$(xmlesc "$MOE_SPARKLE_FEED_URL")</string>
  <key>SUPublicEDKey</key>
  <string>$(xmlesc "$MOE_SPARKLE_PUBLIC_KEY")</string>
  <!-- Updates install silently (docs/DEFAULTS.md row 46, the owner's
       decision). SUEnableAutomaticChecks means Sparkle never
       asks whether it may check; SUAutomaticallyUpdate means a new version is
       downloaded in the background and installed when Moe next quits, with no
       window. Nothing relaunches the app to hurry it. A day between checks.
       scripts/test-sparkle-silent.sh fails when either key leaves this block. -->
  <key>SUEnableAutomaticChecks</key>    <true/>
  <key>SUAutomaticallyUpdate</key>      <true/>
  <key>SUScheduledCheckInterval</key>   <integer>86400</integer>"
elif [ -n "${MOE_SPARKLE_FEED_URL:-}${MOE_SPARKLE_PUBLIC_KEY:-}" ]; then
  echo "✗ set both MOE_SPARKLE_FEED_URL and MOE_SPARKLE_PUBLIC_KEY, or neither" >&2
  exit 1
fi

# The licence public key, from the environment:
#
#   MOE_LICENCE_PUBLIC_KEY  base64 of the 32-byte Ed25519 public key
#                           (`scripts/make-licence.py --show-public-key`,
#                           docs/RELEASING.md §1.5)
#
# Absent by default, and absent means the key is **omitted**. A build with no
# public key has no licensing in it: Sources/Moe/Licence/LicenceStore.swift
# checks for it and the Settings pane says so, exactly as Updates.swift does
# for a build with no appcast. Nothing is gated either way, so a checkout
# build loses nothing at all by not having it.
#
# There is no matching private key anywhere in this repo and there must never
# be one — see docs/RELEASING.md §1.5. This value is public: it ships inside
# every copy of Moe, and publishing it weakens nothing.
LICENCE_PLIST=""
if [ -n "${MOE_LICENCE_PUBLIC_KEY:-}" ]; then
  xmlesc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  LICENCE_PLIST="
  <key>MoeLicencePublicKey</key>
  <string>$(xmlesc "$MOE_LICENCE_PUBLIC_KEY")</string>"
fi

# The Telegram application pair. Telegram issues these per *application*, not
# per user (my.telegram.org/apps), so the product is meant to carry its own —
# a person connecting their chats should never meet that page. Ship it by
# building with MOE_TELEGRAM_API_ID / MOE_TELEGRAM_API_HASH set. Without it
# the app asks for a pair in the Connections sheet, with the steps and the
# link, and stores what it is given: still no Terminal, just more typing.
#
# An api_id/api_hash is not a secret in the password sense — every Telegram
# desktop client ships one — but it identifies this application, so it is
# gitignored rather than committed.
#
# Two ways in, and the file is the one that works. Environment variables are
# invisible: they live in one person's shell, no checkout has them, and a new
# worktree building a release gets a perfectly good app with Telegram
# permanently dead. That is not hypothetical — Telegram was dead in *every*
# release up to 0.3.5, for exactly this reason, and the only thing that ever
# caught it was a gate added the night before.
#
# So it now works like Resources/google-client.json: a file in the checkout,
# gitignored, discovered without anyone remembering anything. The environment
# still wins when set, for CI and for overriding a stale file.
TELEGRAM_CLIENT="${MOE_TELEGRAM_CLIENT:-Resources/telegram-client.json}"
if [ -z "${MOE_TELEGRAM_API_ID:-}" ] && [ -f "$TELEGRAM_CLIENT" ]; then
  # Read with python3 rather than sed: this is JSON, and a hand-rolled parser
  # that half-works would bake a truncated id into the app and be discovered
  # by a user whose Telegram will not connect.
  MOE_TELEGRAM_API_ID="$(python3 -c "
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(d.get('api_id', '') or '')
" "$TELEGRAM_CLIENT" 2>/dev/null || true)"
  MOE_TELEGRAM_API_HASH="$(python3 -c "
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(d.get('api_hash', '') or '')
" "$TELEGRAM_CLIENT" 2>/dev/null || true)"
  if [ -n "${MOE_TELEGRAM_API_ID:-}" ] && [ -n "${MOE_TELEGRAM_API_HASH:-}" ]; then
    echo "  telegram: embedding the application pair from $TELEGRAM_CLIENT"
  else
    echo "✗ $TELEGRAM_CLIENT exists but has no api_id/api_hash — Telegram would ship dead" >&2
    exit 1
  fi
fi

TELEGRAM_PLIST=""
if [ -n "${MOE_TELEGRAM_API_ID:-}" ] && [ -n "${MOE_TELEGRAM_API_HASH:-}" ]; then
  xmlesc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  TELEGRAM_PLIST="
  <key>MoeTelegramAPIID</key>
  <string>$(xmlesc "$MOE_TELEGRAM_API_ID")</string>
  <key>MoeTelegramAPIHash</key>
  <string>$(xmlesc "$MOE_TELEGRAM_API_HASH")</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>        <string>Moe</string>
  <key>CFBundleIconFile</key>          <string>Moe</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <!-- Shown by Finder's Get Info and by the App Store-style panels macOS
       assembles from a bundle. There was no copyright key at all, so those
       read blank, and the app named nobody. Moe is one person's, not a
       company's, and the name here is the same one the Terms of Service
       name as the other party — moebot.app/terms. -->
  <key>NSHumanReadableCopyright</key>  <string>Copyright © 2026 Yisrael Gottlieb. All rights reserved.</string>
  <key>CFBundleShortVersionString</key><string>0.3.25</string>
  <key>CFBundleVersion</key>           <string>32</string>
  <!-- Which tree this binary came from. Without it CFBundleVersion is the
       only thing telling two builds apart, so an app built before a merge
       and one built after are both "16" — which is exactly how a missing
       feature stayed invisible while two people diagnosed it from a log.
       "+dirty" when the checkout had uncommitted changes, because a build
       from an edited tree matches no commit at all. -->
  <key>MoeCommit</key>                 <string>$COMMIT</string>
  <!-- 1 for the build publish-release.sh makes for everybody, 0 for every
       other build of the same version. See MOE_RELEASE_BUILD above. -->
  <key>MoeReleaseBuild</key>           <string>$MOE_RELEASE_BUILD</string>
  <!-- Whether this is a development build, readable without launching it:
       `defaults read /Applications/Memoe*.app/Contents/Info MoeDev`. The
       identifier above already says so, but a plain yes/no is what a
       script should branch on rather than parsing an identifier. -->
  <key>MoeDev</key>                    <string>$MOE_DEV</string>
  <!-- Where a development build keeps its own notes, memory and tokens.
       Empty for the real Moe, which uses ~/Library/Application Support/Moe.
       Paths reads this at launch, so one build can never write the other's
       home however it is started. -->
  <key>MoeHome</key>                   <string>$MOE_HOME_DEFAULT</string>
  <key>MoeCloudEdge</key>              <string>$MOE_CLOUD_EDGE</string>
  <!-- off, prepare or on: whether this build carries every model, carries
       them and copies the on-demand ones out, or leaves those out and
       fetches them. OnDemandMode reads it; docs/SLIM-DOWNLOAD.md. -->
  <key>MoeOnDemandComponents</key>     <string>$MOE_ON_DEMAND_COMPONENTS</string>
  <key>LSMinimumSystemVersion</key>    <string>15.0</string>

  <!-- The link the page Stripe lands on opens: moe://checkout?status=success
       or status=cancel, with the plan. moebot.app/thanks and
       /checkout-cancelled open it at once, so Moe asks the edge for the plan
       the moment the person pays instead of at the next hourly read. It
       carries no secret and Moe treats it as a hint: the tier the edge
       reports is the only truth. Moe Dev claims moe-dev, never moe.
       Sources/MoeCloud/CheckoutReturn.swift. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>       <string>$BUNDLE_ID.checkout</string>
      <key>CFBundleURLSchemes</key>
      <array><string>$URL_SCHEME</string></array>
    </dict>
  </array>

  <!-- A regular app: Dock icon, ⌘Q, app switcher. Setting this to <true/>
       is what made the first version impossible to quit or remove. -->
  <key>LSUIElement</key>               <false/>

  <!-- All of these must be present BEFORE first launch, or macOS denies
       silently with no prompt at all. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>Moe listens when you press the hotkey, or when you say “Hey Moe”, so you can talk to it.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Moe records the call’s audio during a meeting you start, so it can write the transcript and notes. Nothing leaves this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Moe turns your speech into text on this Mac. Nothing is sent to a speech service.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Moe reads your Notes, Reminders, Calendar and Contacts to answer questions about your day, and uses System Events to click and type for you when you ask it to drive the Mac.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Moe reads your calendar so it knows what you have on.</string>
  <key>NSRemindersUsageDescription</key>
  <string>Moe reads your reminders so it knows what you still owe people.</string>
  <!-- macOS 14+ EventKit asks for these when requesting full access; the
       two above are what older systems (and write-only access) read. -->
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Moe reads your calendar so it knows what you have on, and adds events when you ask. Nothing leaves this Mac.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Moe reads your reminders so it knows what you still owe people, and adds reminders when you ask. Nothing leaves this Mac.</string>
  <key>NSContactsUsageDescription</key>
  <string>Moe looks up the people you mention, and — if you switch it on in Settings › Voice — spells their names right when you dictate.</string>
  <!-- Asked the first time a question needs a place (moe_location), never
       at launch. macOS 11+ reads the WhenInUse key; the bare one is what
       older documentation names for the Mac, and costs nothing to carry. -->
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Moe uses this Mac’s location to answer when you ask something that depends on where you are, like the weather or what’s nearby. Only when you ask, never in the background.</string>
  <key>NSLocationUsageDescription</key>
  <string>Moe uses this Mac’s location to answer when you ask something that depends on where you are, like the weather or what’s nearby. Only when you ask, never in the background.</string>
$SPARKLE_PLIST$LICENCE_PLIST$TELEGRAM_PLIST
</dict>
</plist>
PLIST

# The plist is generated, so a mistake in the heredoc is a mistake in every
# build. This one shipped: the "Moe 0.3.10 (build 17)" bump clipped the
# opening `<!--` off the MoeCommit comment, leaving prose between two keys,
# and the only symptom was an error from codesign 350 seconds of compiling
# later — `Encountered unexpected character o on line 13`. A bare
# `plutil -lint … >/dev/null` was already here and `set -e` did stop the
# build, correctly; what it did not do is say that build.sh had generated the
# file, so the failure read as a corrupt bundle rather than a typo twelve
# lines up. Same check, a message that names its own cause.
if ! plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "✗ the Info.plist this build generated is not valid:" >&2
  plutil -lint "$APP/Contents/Info.plist" >&2
  echo "  The heredoc near 'CFBundleVersion' in build.sh produced it." >&2
  exit 1
fi

if [ -n "$STAGE_ONLY" ]; then
  echo "✓ staged $APP — Info.plist and Resources only, no compiler, no signature"
  exit 0
fi

# Sign it. Which identity, in what order, and why the order is the
# difference between a consent key that survives a rebuild and one that is
# re-minted (with a Google sign-in) after every catch-up: scripts/sign-build.sh.
#
# Local builds prefer our Developer ID (team 5Y8C3ZR5X6), then the self-signed
# "Moe Code Signing", then ad-hoc. A published build keeps its old order;
# release.sh re-signs it with the Developer ID, hardened and notarized.
#
# The certificate is not the unrotatable thing: Sparkle's SUUpdateValidator
# returns YES on `passedDSACheck || passedCodeSigning`, deliberately, "because
# this allows key rotation without breaking chain of trust". The EdDSA key is
# what may never change; the certificate may.
./scripts/sign-build.sh "$APP"

echo
echo "✓ built $APP"
echo
echo "  run it:      open $APP"
echo "  install it:  ./scripts/install.sh"
