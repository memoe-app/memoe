# Third-party licences and attribution

Audited 2026-08-29; WhisperKit and Parakeet v3 added 2026-08-30. Source of
truth for the in-app **Licenses** screen.

**Verdict: no blocker.** Every component we ship permits commercial use.
Two of the six models require *mandatory attribution* (CC-BY-4.0), which
means the notices below must be visible in the shipped app — not buried in a
repo file.

---

## Software

| Component | Role | Licence | Commercial |
|---|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Swift ASR/TTS framework | Apache-2.0 | Yes |
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (`argmax-oss-swift`, product `WhisperKit`) | Whisper on CoreML | MIT | Yes |
| [Hermes Agent](https://github.com/NousResearch/hermes-agent) (© 2025 Nous Research) | Agent runtime, separate process launched by Memoe | MIT | Yes |
| [Memoe's Hermes fork](https://github.com/Izzy-Gottz/hermes-agent) (branch `claude-code-runtime`, pinned in `scripts/install-hermes.sh`) | The Hermes build Memoe installs and bundles: upstream plus Memoe's changes | MIT (same as upstream) | Yes |
| [cua-driver](https://github.com/trycua/cua) (© 2025 Cua AI, Inc.) | Mac control through the accessibility tree; a separate program Hermes installs and runs, not linked into Memoe | MIT | Yes |
| [OpenWhispr](https://github.com/OpenWhispr/OpenWhispr) (© 2024 OpenWhispr Team) | Transcript cleanup and dictionary prompts adapted (`PolishPrompt.swift`); no code linked | MIT | Yes |
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.6.4 | Auto-updates; ships as `Contents/Frameworks/Sparkle.framework` | MIT (+ bundled BSD-2, MIT, zlib components) | Yes |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) 1.24.2 via [onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager) (© Microsoft Corporation) | Runs the Smart Turn and wake-word ONNX models in-process | MIT | Yes |
| [LiveKit WakeWord](https://github.com/livekit/livekit-wakeword) 0.2.1 (© 2026 LiveKit, Inc.) | Training pipeline for "Hey Moe"; the detector design (`WakeHead.swift` is Memoe's own port, no LiveKit code linked) | Apache-2.0 | Yes |

Apache-2.0 requires shipping the licence text and retaining NOTICE content.
MIT requires the copyright and permission notice in the distribution —
NOTICE and the in-app screen carry it. `argmax-oss-swift` pulls in
`swift-argument-parser` (Apache-2.0) for its CLI target only; Memoe links the
`WhisperKit` library product, which depends on nothing but `ArgmaxCore` from
the same package, so nothing new is statically linked.

### Statically linked via FluidAudio

Found on review, not in the original audit. FluidAudio's own
`ThirdPartyLicenses/` and `Package.swift` pull these into our binary:

| Component | Role | Licence | Obligation |
|---|---|---|---|
| [text-processing-rs](https://github.com/FluidInference/text-processing-rs) v0.3.0 (`NemoTextProcessing.xcframework`) | Byte-exact NeMo text normalisation | Apache-2.0 | NOTICE |
| [NVIDIA NeMo Text Processing](https://github.com/NVIDIA/NeMo-text-processing) | Compiled FST grammars inside the above | Apache-2.0 | NOTICE (© NVIDIA CORPORATION & AFFILIATES) |
| [rustfst](https://github.com/Garvys/rustfst), [flate2](https://github.com/rust-lang/flate2-rs) and transitive crates | FST runtime, gzip | MIT OR Apache-2.0 | NOTICE |
| [VBx](https://github.com/BUTSpeechFIT/VBx) (`Diarizer/Offline/Clustering`) | Speaker clustering | Apache-2.0 | NOTICE (© 2021-2024 BUT Speech@FIT) |
| [fastcluster](https://github.com/fastcluster/fastcluster) (`FastClusterWrapper`) | Hierarchical clustering | BSD-3-Clause | **Copyright notice, conditions and disclaimer must be reproduced in binary distributions** — done in NOTICE and the in-app screen |

Memoe doesn't call the diarizer, but the code is linked, so the notices ship.

---

## Models

All are downloaded at runtime by FluidAudio, not bundled in the app binary —
but we cause the download and present the output, so the obligations apply.

| Model | Role | Licence | Commercial | Obligation |
|---|---|---|---|---|
| [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) via [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | **Main transcriber** (English + 24 European languages) | CC-BY-4.0 | Yes | **Attribution required** |
| [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) via [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) (`openai_whisper-large-v3-v20240930_turbo`) | Transcriber for the languages Parakeet lacks; long-form audio | MIT (weights) / MIT (conversion) | Yes | Copyright + permission notice |
| [nvidia/parakeet-tdt_ctc-110m](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m) via [FluidInference/parakeet-ctc-110m-coreml](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml) | Vocabulary boosting: CTC keyword spotting over the audio so a name the main model mangles can be recovered (`VocabularyBoost`). ~99 MB, downloaded only when the user has vocabulary terms | CC-BY-4.0 | Yes | **Attribution required** (see note) |
| [nvidia/parakeet_realtime_eou_120m-v1](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1) via [FluidInference/parakeet-realtime-eou-120m-coreml](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml) | Streaming / endpointing | NVIDIA Open Model License | Yes | NOTICE + guardrail clause |
| [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) via [FluidInference/kokoro-82m-coreml](https://huggingface.co/FluidInference/kokoro-82m-coreml) | Default voice | Apache-2.0 | Yes | NOTICE (+ see note) |
| [FluidInference/inflect-v2-coreml](https://huggingface.co/FluidInference/inflect-v2-coreml) (from Inflect-Micro/Nano-v2) | Text normalisation | Apache-2.0 | Yes | NOTICE |
| [pipecat-ai/smart-turn-v3](https://huggingface.co/pipecat-ai/smart-turn-v3) (`smart-turn-v3.2-cpu.onnx`, © 2025 Daily) | Turn completion for voice mode; fetched once into `~/.moe/models/smart-turn` | BSD-2-Clause | Yes | Copyright, conditions and disclaimer reproduced — `THIRD_PARTY_LICENSES/SmartTurn-BSD-2-Clause.txt` |
| Google `speech_embedding` (TF Hub) as `Resources/WakeWord/embedding_model.onnx`, the ONNX conversion shipped by [openWakeWord](https://github.com/dscripka/openWakeWord) and [livekit-wakeword](https://github.com/livekit/livekit-wakeword) | Wake-word backbone (frozen) | Apache-2.0 (Google LLC) | Yes | NOTICE. openWakeWord labels its *own* trained heads CC-BY-NC-SA; the backbone weights are Google's, not theirs. |
| `Resources/WakeWord/melspectrogram.onnx` | Wake-word mel front end | Memoe's own export of the public formula (`scripts/wake-mel-export.py`; constants verified against the reference by `scripts/wake-mel-constants.py`) | Yes | none |
| `Resources/WakeWord/hey-moe.onnx` | The "Hey Moe" classifier, trained here with livekit-wakeword (`--skip-acav`) | Ours. **Training data:** Piper VITS synthesis (checkpoint from rhasspy/piper-sample-generator, MIT; LibriTTS voices, CC-BY-4.0), LibriSpeech test-clean as general-speech negatives (CC-BY-4.0), MUSAN noise (CC-BY-4.0 / public domain), MIT room impulse responses (licence unlisted, non-commercial not asserted). No ACAV100M (CC-BY-NC-SA) — see VOICE-PLAN.md §10 | Yes | NOTICE (LibriTTS/LibriSpeech attribution) |

**Note — the CTC 110M licence.** The two model cards disagree. FluidInference's
conversion card says Apache-2.0, "same as the original NVIDIA model"; NVIDIA's
own card for `parakeet-tdt_ctc-110m` says "License to use this model is covered
by the CC-BY-4.0." NVIDIA's card governs the weights, so **CC-BY-4.0** is what
we ship against — the stricter of the two, and the one that requires
attribution. Commercial use is permitted either way. Checked 2026-08-31.

---

## Signal support — downloaded on first use, never bundled, never modified

Connecting Signal (and only that) downloads two things onto the person's own
Mac, from their upstream releases, byte for byte as published. Neither is
part of Memoe's download, neither is linked into Memoe, and neither is changed in
any way. `scripts/fetch-signal-cli.sh` pins both by SHA-256; docs/SIGNAL.md
has the measurements and the reasoning.

| Component | Role | Licence | How Memoe uses it |
|---|---|---|---|
| [signal-cli](https://github.com/AsamK/signal-cli/tree/v0.14.8) 0.14.8 (© AsamK and contributors) | Talks to Signal as a linked device | **GPL-3.0-or-later** | A **separate program**: started as its own process, spoken to over local HTTP/JSON-RPC on 127.0.0.1. Never linked, never patched |
| [libsignal](https://github.com/signalapp/libsignal/tree/v0.102.1) 0.102.1 (© Signal Messenger, LLC) | The Signal protocol, inside signal-cli | **AGPL-3.0-only** | Ships inside signal-cli's own jar and runs inside signal-cli's process. Memoe never loads it |
| [Eclipse Temurin JRE](https://adoptium.net/) 25.0.4.1+1 | The Java runtime signal-cli needs | **GPL-2.0 with the Classpath Exception** | Downloaded from Adoptium unmodified, carrying its own `legal/` texts |

**Why Memoe's own code is unaffected.** signal-cli runs as a separate program
and communicates with Memoe at arm's length; under the FSF's
[mere-aggregation reading](https://www.gnu.org/licenses/gpl-faq.html#MereAggregation)
that is aggregation rather than a combined work. Nothing GPL or AGPL is
linked into Memoe's binary. The AGPL's §13 network clause keys on *modified*
versions; nothing here is modified — which is exactly why the libsignal
native library is left inside its jar for libsignal itself to extract at run
time, and why the Java runtime is Temurin's published build rather than a
jlink'd tree of ours.

Full texts: `THIRD_PARTY_LICENSES/GPL-3.0.txt`, `THIRD_PARTY_LICENSES/AGPL-3.0.txt`
(and Temurin's own, in the runtime it downloads). Both ride inside the app
bundle — `build.sh` copies `THIRD_PARTY_LICENSES/` into `Contents/Resources`.

**Written offer of source.** **Owner decision, 2026-09-14: offer the
source, ship it** — and Signal support stays a download on connect. The offer
in NOTICE names the exact versions, links each one's source at its exact
upstream tag — signal-cli at [`v0.14.8`](https://github.com/AsamK/signal-cli/tree/v0.14.8), libsignal at
[`v0.102.1`](https://github.com/signalapp/libsignal/tree/v0.102.1), and the Java runtime at
Adoptium's [`jdk-25.0.4.1+1_adopt`](https://github.com/adoptium/jdk25u/tree/jdk-25.0.4.1+1_adopt), the tag
Temurin's own build record names as its source — and undertakes in writing,
for three years, to supply the complete corresponding source to anyone who
asks (hello@moebot.app, the contact address published on memoe.app). The
same paragraph is shown in the app (Settings › About & Licences,
`Licenses.notice`) and on memoe.app/licenses; `Tests/MoeAppTests` and
`scripts/test-legal-pages.sh` fail if either stops matching NOTICE, and
`scripts/test-legal-pages.sh` also fails if NOTICE, the app, the site or this
file names a signal-cli, libsignal or Java version other than the ones
`scripts/fetch-signal-cli.sh` pins.

**There is no mirror.** Memoe hosts no copy of these sources — not beside the
release on `Izzy-Gottz/moe-releases`, not anywhere. The links point at the
upstream projects, and availability is covered by the written three-year
offer: if an upstream copy ever goes away, supplying the source is on us.

---

## Required notices — ship this text verbatim

> **Speech recognition** — Parakeet TDT 0.6B v3, Parakeet TDT-CTC 110M and
> Parakeet Realtime EOU 120M by NVIDIA Corporation. Parakeet TDT 0.6B v3 and
> Parakeet TDT-CTC 110M are used under
> [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). Parakeet Realtime
> EOU 120M is licensed by NVIDIA Corporation under the NVIDIA Open Model
> License. CoreML conversions by the FluidInference team. Whisper
> large-v3-turbo © OpenAI, MIT; CoreML conversion by Argmax, Inc., MIT.
>
> **Speech recognition framework** — WhisperKit © 2024 Argmax, Inc., MIT.
>
> **Speech synthesis** — Kokoro-82M by hexgrad, Apache-2.0. Inflect text
> normalisation © the Inflect authors, Apache-2.0. CoreML conversions by the
> FluidInference team.
>
> **Audio framework** — FluidAudio by FluidInference, Apache-2.0.
>
> Kokoro-82M training data includes material from Koniwa (CC BY 3.0) and
> SIWIS (CC BY 4.0).
>
> **Signal** — if you connect Signal, Moe downloads
> [signal-cli](https://github.com/AsamK/signal-cli/tree/v0.14.8) 0.14.8 (© AsamK and
> contributors, GPL-3.0-or-later), which contains
> [libsignal](https://github.com/signalapp/libsignal/tree/v0.102.1) 0.102.1 (© Signal
> Messenger, LLC, AGPL-3.0-only), and an
> [Eclipse Temurin](https://adoptium.net/) JRE 25.0.4.1+1 (GPL-2.0 with the
> Classpath Exception). All three are used unmodified, and signal-cli runs as
> a separate program that Moe talks to over a local connection. For at least
> three years from the date you received this software, we will give anyone
> who asks the complete corresponding source for those exact versions, on a
> physical medium or by download, for no more than the cost of distribution —
> write to the contact address published at https://memoe.app. Source, at the
> exact upstream tags: signal-cli's at
> https://github.com/AsamK/signal-cli/tree/v0.14.8, libsignal's at
> https://github.com/signalapp/libsignal/tree/v0.102.1, and the Java runtime's
> at https://github.com/adoptium/jdk25u/tree/jdk-25.0.4.1+1_adopt.

---

## Constraints that affect product decisions

### 1. Attribution is not optional
Two models are CC-BY-4.0 (Parakeet TDT v3, Parakeet TDT-CTC 110M), and Kokoro's training data
carries CC-BY credits of its own. That licence has teeth and its sole condition is
credit. A visible **Licenses** screen in Settings satisfies it; a line in a
GitHub README does not, because most users never see the repo. Build the
screen before charging money.

### 2. NVIDIA Open Model License — automatic termination on guardrail bypass
If we "bypass, disable, reduce the efficacy of, or circumvent any technical
limitation, safety guardrail" without substituting a comparable one, our
rights **terminate automatically**. We don't do this today. It is a reason not
to start, and a reason to keep this note where a future contributor sees it.

### 3. The voice-cloning constraint has lapsed, and would come back
Two constraints used to sit here and no longer bind us, because the models
they came from are gone: PocketTTS (CC-BY-4.0 plus Kyutai's acceptable-use
terms, which prohibit voice impersonation without consent) and Supertonic-3
(OpenRAIL-M, with use-based restrictions that pass through to everyone we
redistribute to). Memoe renders with Kokoro and speaks with Apple's voices;
`TtsEngineKind` has no other case, `Models/` stages neither, and neither is
a package dependency.

Kept as a note rather than deleted, because "voice cloning is off the table
while PocketTTS ships" was a **product decision** with a licence for a
reason. The reason has gone. Anyone reinstating either model reinstates the
restriction with it — and in Supertonic's case, note that the FluidAudio
docs label it Apache-2.0, which is wrong; the model card and LICENSE file in
`Supertone/supertonic-3` are authoritative.

---

## Residual unknowns

- **Kokoro's upstream.** Kokoro-82M is Apache-2.0, which is what binds us, but
  it is finetuned from `yl4579/StyleTTS2-LJSpeech`, whose licence is not
  stated on the model card. Low risk — the released weights carry a clear
  licence — but it is an unverified link in the chain.

---

## Housekeeping found during the audit

- **No LICENCE of our own.** The repo has no `LICENSE` file. Decide the
  product's own licence (§12.4 of PRODUCT.md) and add one.
- **FluidAudio is pinned** to `from: "0.9.1"` in Package.swift and resolved
  at **0.15.6** in Package.resolved. Re-check this file when bumping — a
  major-version bump can change what's statically linked.
- **argmax-oss-swift is pinned** to `from: "1.0.0"`, resolved at **1.1.0**.
  Its `Package.swift` adds Vapor and the OpenAPI stack only when a server
  build flag is set; a bump that turns that on by default would change the
  linked set.
- **Parakeet Unified EN 0.6B** (`parakeet-unified-en-0.6b-coreml`, the
  English-only model the v2 line above previously pointed at) is no longer
  downloaded. Anyone who ran an earlier build still has it under
  `~/Library/Application Support/FluidAudio/Models/`; safe to delete.
- **`DynamicNotchKit` is a stale checkout**, present in `.build/checkouts` but
  absent from `Package.resolved` and unreferenced in `Sources`. Not a
  dependency. Safe to delete.
