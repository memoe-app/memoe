import AppKit
import MoeDesign
import SwiftUI

/// Third-party attribution, shown in the main window.
///
/// Two of the models Moe downloads are CC-BY-4.0, whose one condition is
/// visible credit — a line in the repo doesn't count because users never see
/// the repo. This screen is what discharges that. The notice text is
/// duplicated from LICENSES.md / NOTICE on purpose: build.sh copies only the
/// bare executable into Memoe.app, so a SwiftPM resource bundle would never
/// make it into the shipped app and `Bundle.module` would trap at launch. A
/// string constant is the one thing guaranteed to be wherever the binary is.
enum Licenses {
    struct Component: Identifiable {
        let name: String, role: String, licence: String, url: String
        var id: String { name }
    }

    static let software: [Component] = [
        Component(name: "FluidAudio", role: "Swift ASR/TTS framework", licence: "Apache-2.0",
                  url: "https://github.com/FluidInference/FluidAudio"),
        Component(name: "WhisperKit", role: "Whisper on CoreML (argmax-oss-swift)", licence: "MIT",
                  url: "https://github.com/argmaxinc/argmax-oss-swift"),
        // Statically linked inside FluidAudio; see its ThirdPartyLicenses/.
        Component(name: "NeMo Text Processing", role: "FST grammars, via text-processing-rs",
                  licence: "Apache-2.0",
                  url: "https://github.com/NVIDIA/NeMo-text-processing"),
        Component(name: "text-processing-rs", role: "NemoTextProcessing.xcframework",
                  licence: "Apache-2.0",
                  url: "https://github.com/FluidInference/text-processing-rs"),
        Component(name: "rustfst", role: "FST runtime", licence: "MIT OR Apache-2.0",
                  url: "https://github.com/Garvys/rustfst"),
        Component(name: "flate2", role: "Grammar decompression", licence: "MIT OR Apache-2.0",
                  url: "https://github.com/rust-lang/flate2-rs"),
        Component(name: "VBx", role: "Speaker clustering", licence: "Apache-2.0",
                  url: "https://github.com/BUTSpeechFIT/VBx"),
        Component(name: "fastcluster", role: "Hierarchical clustering", licence: "BSD-3-Clause",
                  url: "https://github.com/fastcluster/fastcluster"),
        // The only dependency that ships as a framework inside the app rather
        // than linked into the binary, which is why its licence text is in
        // Contents/Resources/THIRD_PARTY_LICENSES too.
        Component(name: "Sparkle", role: "Software updates", licence: "MIT",
                  url: "https://github.com/sparkle-project/Sparkle"),
        // Not in this app at all unless the person connects Signal: then it
        // is downloaded to their own Mac, unmodified, and run as a separate
        // program Moe talks to over a local connection (docs/SIGNAL.md §4).
        // Listed because they were told to expect it, and because the offer
        // of source in `notice` is only honest if the components are named.
        // That offer — both repositories and the three-year undertaking — is
        // NOTICE's Signal paragraph word for word; MoeAppTests fails if the
        // two ever disagree or the paragraph goes (owner decision 2026-09-14:
        // offer the source, ship it).
        Component(name: "signal-cli", role: "Signal, as a linked device (downloaded if you connect Signal)",
                  licence: "GPL-3.0-or-later", url: "https://github.com/AsamK/signal-cli"),
        Component(name: "libsignal", role: "The Signal protocol, inside signal-cli",
                  licence: "AGPL-3.0-only", url: "https://github.com/signalapp/libsignal"),
        Component(name: "Eclipse Temurin JRE", role: "The Java runtime signal-cli needs",
                  licence: "GPL-2.0 with Classpath Exception", url: "https://adoptium.net/"),
    ]

    static let models: [Component] = [
        Component(name: "Parakeet TDT 0.6B v3", role: "Transcriber, English & European",
                  licence: "CC-BY-4.0",
                  url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"),
        Component(name: "Whisper large-v3-turbo", role: "Transcriber, other languages",
                  licence: "MIT",
                  url: "https://huggingface.co/argmaxinc/whisperkit-coreml"),
        Component(name: "Parakeet Realtime EOU 120M", role: "Streaming / endpointing",
                  licence: "NVIDIA Open Model License",
                  url: "https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1"),
        Component(name: "Parakeet TDT-CTC 110M", role: "Vocabulary boosting",
                  licence: "CC-BY-4.0",
                  url: "https://huggingface.co/nvidia/parakeet-tdt_ctc-110m"),
        Component(name: "Kokoro-82M", role: "Default voice", licence: "Apache-2.0",
                  url: "https://huggingface.co/hexgrad/Kokoro-82M"),
        Component(name: "Inflect v2", role: "Text normalisation", licence: "Apache-2.0",
                  url: "https://huggingface.co/FluidInference/inflect-v2-coreml"),
    ]

    /// The required notices from LICENSES.md, verbatim. Keep in sync with NOTICE.
    static let notice = """
    Speech recognition — Parakeet TDT 0.6B v3, Parakeet TDT-CTC 110M and Parakeet \
    Realtime EOU 120M by NVIDIA Corporation. Parakeet TDT 0.6B v3 and Parakeet \
    TDT-CTC 110M are used under CC-BY-4.0 \
    (https://creativecommons.org/licenses/by/4.0/). Parakeet Realtime EOU 120M is \
    licensed by NVIDIA Corporation under the NVIDIA Open Model License. CoreML \
    conversions by the FluidInference team. Whisper large-v3-turbo © OpenAI, \
    MIT; CoreML conversion by Argmax, Inc., MIT.

    Speech recognition framework — WhisperKit © 2024 Argmax, Inc., MIT.

    Speech synthesis — Kokoro-82M by hexgrad, Apache-2.0. Inflect \
    text normalisation © the Inflect authors, Apache-2.0. CoreML conversions by \
    the FluidInference team.

    Audio framework — FluidAudio by FluidInference, Apache-2.0.

    Signal — connecting Signal (and nothing else) downloads signal-cli 0.14.8 \
    (© AsamK and contributors, GPL-3.0-or-later), which contains libsignal \
    0.102.1 (© Signal Messenger, LLC, AGPL-3.0-only), and an Eclipse Temurin JRE \
    25.0.4.1+1 (GPL-2.0 with the Classpath Exception). All three are used \
    unmodified; signal-cli runs as a separate program that Moe talks to over a \
    local connection, and nothing of it is linked into Moe. Full texts: \
    THIRD_PARTY_LICENSES/GPL-3.0.txt and THIRD_PARTY_LICENSES/AGPL-3.0.txt, and \
    the runtime's own legal/ directory. Source, at the exact upstream tags: \
    signal-cli's at https://github.com/AsamK/signal-cli/tree/v0.14.8, \
    libsignal's at https://github.com/signalapp/libsignal/tree/v0.102.1, and \
    the Java runtime's at \
    https://github.com/adoptium/jdk25u/tree/jdk-25.0.4.1+1_adopt. For at least \
    three years from the date you received this software, we will give anyone \
    who asks the complete corresponding source for those exact versions, on a \
    physical medium or by download, for no more than the cost of distribution \
    — write to the contact address published at https://memoe.app.

    Software updates — Sparkle © 2006-2013 Andy Matuschak, © 2009-2013 Elgato \
    Systems GmbH, © 2011-2014 Kornel Lesiński, © 2015-2017 Mayur Pawashe, \
    © 2014 C.W. Betts, © 2014 Petroules Corporation, © 2014 Big Nerd Ranch, \
    MIT. It carries its own components: bsdiff/bspatch © 2003-2005 Colin \
    Percival, BSD-2-Clause; sais-lite © 2008-2010 Yuta Mori, MIT; a portable \
    Ed25519 implementation © 2015 Orson Peters, zlib; SUSignatureVerifier.m \
    © 2011 Mark Hamlin, BSD-2-Clause. Full texts in the app's \
    Resources/THIRD_PARTY_LICENSES/Sparkle-MIT.txt.

    MIT License (WhisperKit, Whisper, Sparkle) — Permission is hereby granted, free of \
    charge, to any person obtaining a copy of this software and associated \
    documentation files (the "Software"), to deal in the Software without \
    restriction, including without limitation the rights to use, copy, modify, \
    merge, publish, distribute, sublicense, and/or sell copies of the Software, \
    and to permit persons to whom the Software is furnished to do so, subject \
    to the following conditions: The above copyright notice and this \
    permission notice shall be included in all copies or substantial portions \
    of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY \
    KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF \
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN \
    NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, \
    DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR \
    OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE \
    USE OR OTHER DEALINGS IN THE SOFTWARE.

    Kokoro-82M training data includes material from Koniwa (CC BY 3.0) and \
    SIWIS (CC BY 4.0).

    Statically linked via FluidAudio — NeMo Text Processing FST grammars \
    © NVIDIA CORPORATION & AFFILIATES, Apache-2.0, compiled as \
    text-processing-rs by FluidInference, Apache-2.0, with rustfst \
    © Alexandre Caulier and the rustfst contributors and flate2 © Alex Crichton \
    and the flate2 contributors, each MIT OR Apache-2.0. VBx clustering \
    © 2021-2024 BUT Speech@FIT, Apache-2.0.

    fastcluster — Copyright © 2011 Daniel Müllner (until 1.1.23); © Google Inc. \
    (from 1.1.24). All rights reserved. Redistribution and use in source and \
    binary forms, with or without modification, are permitted provided that \
    the following conditions are met: redistributions of source code must \
    retain the above copyright notice, this list of conditions and the \
    following disclaimer; redistributions in binary form must reproduce the \
    above copyright notice, this list of conditions and the following \
    disclaimer in the documentation and/or other materials provided with the \
    distribution. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND \
    CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT \
    NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A \
    PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER \
    OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, \
    EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, \
    PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; \
    OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, \
    WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR \
    OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF \
    ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """

    /// "1.0 (1)" from Info.plist, or "dev" when run straight from .build
    /// without a bundle.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return "dev" }
        if let build = info["CFBundleVersion"] as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}

/// Settings › About & Licences: which Moe this is and how to get a newer
/// one, then the credits.
///
/// The credits carry a rule: three of the models are CC-BY-4.0 and visible
/// credit is the licence's only condition, so every credit string is shown
/// unchanged and is one click from the pane, never further. What changed
/// is that the version and "Check for Updates" now lead — there was no
/// About anywhere in Settings. Uninstall used to sit at the bottom; it went
/// (docs/DEFAULTS.md row 41), because a second way out that left the
/// person's data behind contradicted the one in Privacy, *Erase Memoe from
/// this Mac*, which stops the background jobs and the login item too.
struct LicensesView: View {
    @State private var showModels = false
    @State private var showSoftware = false
    @State private var showNotices = false
    /// Whether this build is current with the project, when this Mac has a
    /// copy of it. Nil on a stranger's machine, and nil until asked — it
    /// shells out to git, so it is answered off the main thread once.
    @State private var currency: BuildInfo.Currency?
    @State private var live: PublishedRelease.Info?
    /// One refresh at a time: the fetch can take longer than the interval,
    /// and stacking them would put several `git fetch`es on one repository.
    @State private var refreshing = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("About & Licences")
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    about
                    credits
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            }
        }
        .background(Theme.raised)
        // Refreshed when the pane opens and every two minutes after, and
        // NOT with an infinite `.task`, which is what the first version of
        // this was and what made the pane draw as an empty card.
        //
        // `.task { while true { … } }` never returns. Anything that waits
        // for a view's work to settle then waits forever: `Moe
        // --settings-snapshot` hung with its main thread parked in
        // `completeTaskAndRelease` — the main actor holding an await that
        // could not complete — and the pane rendered as a bordered rectangle
        // with nothing in it, because its body never got evaluated.
        //
        // A timer instead. Each tick starts a task that finishes, so nothing
        // is ever left holding the main actor, and SwiftUI cancels it with
        // the view.
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 120, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    /// Ask the two questions the About pane answers, off the main thread.
    ///
    /// Both are slow and both block the thread they run on — `git fetch` is a
    /// process, the feed is a network round trip — so they go to detached
    /// tasks and only the two assignments come back to the main actor.
    private func refresh() {
        // Nothing to draw on a Mac that only runs Moe, so nothing to ask.
        // This is not only about the pane: the two questions cost a `git
        // fetch` and an uncached fetch of the appcast, every two minutes,
        // for the whole time the pane is open. Gating the views alone would
        // have left a customer's Mac quietly doing both to render nothing.
        guard BuildInfo.isMaintainerMac else { return }
        guard !refreshing else { return }
        refreshing = true
        let repo = BuildInfo.repoPath()
        Task {
            let answer = await Task.detached(priority: .utility) {
                BuildInfo.currency(refreshing: true)
            }.value
            let published = await Task.detached(priority: .utility) {
                PublishedRelease.read(comparingAgainst: repo)
            }.value
            await MainActor.run {
                currency = answer
                live = published
                refreshing = false
            }
        }
    }

    /// Bring this Mac's Moe up to what has landed, in a Terminal window the
    /// person can watch and stop.
    ///
    /// All of the deciding lives in `scripts/catch-up.sh`, and none of it
    /// here. This button must not be a second, subtly different way to
    /// build the app: the script is what a person can also run by hand, is
    /// what a test can run, and is what gets fixed when the build inputs
    /// change. A button that pastes its own commands is a copy that goes
    /// stale silently.
    ///
    /// In particular it does NOT build in `repo`. That checkout is shared —
    /// on 2026-09-03 `~/moe` sat on a feature branch while the owner's Moe
    /// was rebuilt from it repeatedly — so the script keeps its own
    /// checkout pinned to `origin/main` and builds that.
    ///
    /// It catches up the app you pressed it in, and only that one. In Moe
    /// Dev it passes `dev`, so the workbench updates the workbench. Without
    /// that word it would install over the real Moe from inside Moe Dev —
    /// the same accident as every other one this week, in its politest
    /// form: a button, in front of somebody, doing the obvious thing to
    /// the wrong app.
    ///
    /// The three lines below take the script OUT OF `origin/main` rather
    /// than running the one in `repo`'s working tree, and that is the whole
    /// of the bootstrap. The first press of this button failed on exactly
    /// that: `~/moe` was sitting on a branch that predates the script, so
    /// the path did not exist and zsh said "no such file or directory". A
    /// shared checkout is on somebody's branch — that is its normal state,
    /// not a bad day — so nothing in the app may depend on what is checked
    /// out in it. Only the `.git` beside it, which every branch has.
    ///
    /// These lines fetch, extract and run. Everything that decides anything
    /// is inside the extracted script, where it can be read, tested and
    /// fixed; if this ever grows a fourth line that makes a decision, that
    /// decision is in the wrong file.
    private func catchUp(_ repo: String) {
        let quoted = shellQuote(repo)
        let script = """
        set -e
        echo 'Fetching the current catch-up…'
        git -C \(quoted) fetch --quiet origin main
        tmp=$(mktemp -d)/catch-up.sh
        git -C \(quoted) show origin/main:scripts/catch-up.sh > "$tmp"
        chmod +x "$tmp"
        MOE_CATCHUP_REPO=\(quoted) "$tmp"\(BuildInfo.isDev ? " dev" : "")
        """
        runInTerminal(script, what: "catch up")
    }

    /// Open Terminal and run a script in it.
    ///
    /// Terminal rather than a progress sheet, deliberately. These builds take
    /// minutes, quit and relaunch this very app partway through, ask
    /// questions, and fail for reasons worth reading — a missing model, a
    /// guard refusing, a push that lost a race. A spinner that ends in a dead
    /// app is the worst version of this, and hiding the output is how a
    /// person ends up staring at a Mac with no Moe on it.
    private func runInTerminal(_ script: String, what: String) {
        let osa = "tell application \"Terminal\"\n"
            + "activate\n"
            + "do script \(appleScriptQuote(script))\n"
            + "end tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        do {
            try p.run()
            Log.write("\(what): opened Terminal")
        } catch {
            Log.write("\(what): could not open Terminal: \(error)")
        }
    }

    /// Cut a release of what is on `main`, in a Terminal window.
    ///
    /// Same bootstrap as `catchUp` and for the same reason: take the script
    /// out of `origin/main` rather than out of a working tree that is on
    /// somebody's branch. And in Terminal rather than in-app, more so than
    /// catch-up — ship.sh stops halfway and asks a person to edit the
    /// release notes, which is the one part of a release that cannot be
    /// mechanical. A progress bar cannot do that.
    private func publish(_ repo: String) {
        let quoted = shellQuote(repo)
        let script = """
        set -e
        echo 'Fetching the current release script…'
        git -C \(quoted) fetch --quiet origin main
        tmp=$(mktemp -d)/ship-from-main.sh
        git -C \(quoted) show origin/main:scripts/ship-from-main.sh > "$tmp"
        chmod +x "$tmp"
        MOE_CATCHUP_REPO=\(quoted) "$tmp"
        """
        runInTerminal(script, what: "publish")
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private var about: some View {
        // Two rows, not one.
        //
        // Everything used to sit in a single HStack: icon, a column of text,
        // a spacer, and the buttons. That was fine when the column held two
        // short lines and there was one button. It now holds up to four
        // lines — two of them long sentences about which build is where —
        // and there can be three buttons, which take their intrinsic width
        // and leave the text whatever is left. On this Mac that was about
        // ninety points, so every line wrapped mid-word and the card was a
        // ninety-point-wide ribbon of syllables.
        //
        // So the identity and the buttons share the top row, where both are
        // short, and the status lines get the full width of the card
        // underneath, which is what a sentence needs.
        VStack(alignment: .leading, spacing: Theme.Space.cosy) {
            HStack(alignment: .center, spacing: Theme.Space.cosy) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    // "Beta" sits beside the version rather than in a banner
                    // of its own. This is the screen a person opens when
                    // something has gone wrong and they want to know what
                    // they are running; the answer to "which Moe is this?"
                    // is the version AND the fact that it is early, and the
                    // two belong on one line.
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                        Text("Memoe \(Licenses.appVersion)")
                            .font(Theme.Typo.heading(19))
                            .foregroundStyle(Theme.ink)
                        Text("BETA")
                            .font(Theme.Typo.label(9))
                            .tracking(Theme.tracking)
                            .foregroundStyle(Theme.ink3)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(
                                Capsule().strokeBorder(Theme.rule,
                                                       lineWidth: Theme.Stroke.edge)
                            )
                    }
                    // A build of main between two releases has the last
                    // release's version, so it says here that it is not that
                    // release, and which commit it is.
                    if let note = BuildInfo.unreleasedNote(Bundle.main.infoDictionary) {
                        Text(note)
                            .font(Theme.Typo.ui(12))
                            .foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Text(Updates.controller == nil
                         ? "Built from source — updates come from wherever you got it."
                         : "Keeps itself up to date: a new version is downloaded quietly, and Memoe asks before restarting to install it.")
                        .font(Theme.Typo.ui(12))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: Theme.Space.base)
            }

            // What beta means, in the one place a person goes looking when
            // it has just bitten them — and pointing at the route that
            // actually works from inside the app. Not an email address:
            // telling Moe reaches us with the version, the machine and what
            // it was doing, none of which a person should have to type out.
            Text("You're on an early version. Bugs, edge cases and rough corners are part of the deal for now — when you hit one, just tell Moe. Say it out loud or type it; it comes to us with everything needed to fix it, and it is what makes the next version better.")
                .font(Theme.Typo.prose(12))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The three answers to "which Moe is this?", full width.
            //
            // The version above cannot answer it: it names the RELEASE and
            // changes only when one is cut, so every build between two
            // releases shows the same pair. That is how one build replacing
            // another stayed invisible for hours.
            if BuildInfo.isMaintainerMac, currency != nil || live != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let currency {
                        Text("This Mac — " + currency.text)
                            .font(Theme.Typo.ui(11))
                            .foregroundStyle(currency.current ? Theme.ink3 : Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // What is live in the world: the release everybody else
                    // is running, and what a stranger downloads today. It is
                    // usually a long way behind main, which is normal; it
                    // only matters when nobody can see it.
                    if let live {
                        Text("Everyone — " + live.text)
                            .font(Theme.Typo.ui(11))
                            .foregroundStyle(Theme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The buttons get a row of their own rather than the right-hand
            // end of the first one. There can be three of them, each taking
            // its intrinsic width, and beside a sentence they win: the text
            // column collapsed to about ninety points and wrapped mid-word.
            // On their own row nothing competes for the space.
            //
            // Two different "behind", and only one of them is an update.
            // "Check for Updates" is the answer for everyone: a newer
            // RELEASE, fetched and installed by Sparkle. "Catch up" is for a
            // Mac that has the project checked out and is behind the work
            // that has landed since the last release — not an update at all,
            // a compile, and no user ever sees it because `currency` is nil
            // without a checkout. "Publish a release" is the other
            // direction: put main in front of everyone.
            //
            // All of them open Terminal rather than working in place. These
            // builds take minutes, quit and relaunch this app partway, and
            // fail for reasons worth reading; a spinner that ends in a dead
            // app is the worst version of this.
            //
            // All three are behind `isMaintainerMac`, including "Check for
            // Updates…", which is the one that would have been reasonable to
            // leave. It goes with the others because the row is the whole
            // reason a customer would look at this card twice, and because
            // hiding it costs nobody an update: Sparkle checks on its own
            // schedule and offers what it finds. What is removed is a button
            // that invites a person to worry about their version, on a
            // screen that otherwise just says which one they have.
            if BuildInfo.isMaintainerMac {
                HStack(spacing: Theme.Space.cosy) {
                    Spacer(minLength: 0)
                    if let currency, !currency.current, let repo = BuildInfo.repoPath() {
                        PaneButton(title: "Catch up…") { catchUp(repo) }
                    }
                    if !BuildInfo.isDev, let repo = BuildInfo.repoPath(),
                       let live, live.behind == nil || (live.behind ?? 0) > 0 {
                        PaneButton(title: "Publish a release…") { publish(repo) }
                    }
                    if let controller = Updates.controller {
                        PaneButton(title: "Check for Updates…") { controller.checkForUpdates(nil) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var credits: some View {
        SettingGroup(title: "Built on open models and open source") {
            Text("Everything below runs on this Mac.")
                .font(Theme.Typo.prose(12.5))
                .foregroundStyle(Theme.ink3)
            SettingRow(title: "Models",
                       detail: Licenses.models.map(\.name).joined(separator: ", ")) {
                PaneButton(title: showModels ? "Hide" : "Show credits") { showModels.toggle() }
            }
            if showModels {
                VStack(spacing: 0) {
                    ForEach(Licenses.models) { LicenceRow(component: $0) }
                }
                .padding(.leading, Theme.Space.base)
            }
            SettingRow(title: "Software",
                       detail: Licenses.software.map(\.name).joined(separator: ", ")) {
                PaneButton(title: showSoftware ? "Hide" : "Show credits") { showSoftware.toggle() }
            }
            if showSoftware {
                VStack(spacing: 0) {
                    ForEach(Licenses.software) { LicenceRow(component: $0) }
                }
                .padding(.leading, Theme.Space.base)
            }
            // The required notices, one tap away rather than a page-long
            // wall under everything (2026-09-28).
            SettingRow(title: "Licence notices",
                       detail: "The full notices the licences above require.") {
                PaneButton(title: showNotices ? "Hide" : "Show") { showNotices.toggle() }
            }
            if showNotices {
                Text(Licenses.notice)
                    .font(Theme.Typo.prose(12.5))
                    .foregroundStyle(Theme.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.measure, alignment: .leading)
                    .padding(.leading, Theme.Space.base)
            }
        }
    }
}

struct LicenceRow: View {
    let component: Licenses.Component
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.base) {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                    .font(Theme.Typo.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                // Role and licence together, because the licence is the part
                // that has to be readable — it is the credit, not a footnote.
                Text("\(component.role) · \(component.licence)")
                    .font(Theme.Typo.ui(11))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.small)
            PaneButton(title: "Their website") {
                if let url = URL(string: component.url) { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.vertical, Theme.Space.base)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }
}
