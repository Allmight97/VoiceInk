# 5. macOS 27 adoption

macOS 27 is **Golden Gate**, announced 8 June 2026, shipped with Xcode 27.

A caveat that shapes this whole document: it was written without a Mac. Nothing
here has been compiled against the macOS 27 SDK. Statements about **what Apple
shipped** are sourced from Apple's developer material and are reliable.
Statements about **how this app behaves on 27** are hypotheses with a stated
way to check them — they are marked **VERIFY**.

## The lever that matters most

Everything else in this document is downstream of one choice.

The app target currently declares `MACOSX_DEPLOYMENT_TARGET = 14.4`, while the
project declares `15.0`. That inconsistency alone should be fixed. But the real
question is where the floor goes.

**DECIDE — deployment floor.**

| Floor | What it buys | What it costs |
|---|---|---|
| **14.4** (today) | runs on old Macs | no `Synchronization`, no `SpeechAnalyzer`, no Core AI, every modern API behind `#available` |
| **15.0** | stdlib `Synchronization` → **drop `swift-atomics`** | still gates everything else |
| **26.0** | `SpeechAnalyzer` becomes usable → **delete the `ENABLE_NATIVE_SPEECH_ANALYZER` flag, the dual-compilation stubs, and every `#available(macOS 26)`** | 2025 Macs and newer only |
| **27.0** | Core AI; every availability gate in the codebase disappears | current-OS only |

Raising the floor is **the single largest tidying lever in the repository**,
because it deletes complexity rather than reorganizing it. Concretely, at 26.0:
414 lines of `Transcription/Native/` stop being conditionally-compiled dead
weight, one compilation condition disappears from four build configurations,
and 13 `@available` / `#available` sites vanish.

For a personal daily-driver on your own Mac, **27.0** is defensible and by far
the simplest. It only becomes expensive if you later want to hand the app to
someone on an older machine.

Recommendation: **26.0 minimum, adopt 27-only APIs behind `if #available`.**
That captures almost all of the deletion win while leaving a year of headroom.
If you are certain the app is only ever for you, go straight to 27.0.

## Swift 6 and concurrency

Today: `SWIFT_VERSION = 5.0`, `SWIFT_STRICT_CONCURRENCY` unset, two
`@unchecked Sendable` conformances, `Unmanaged.passUnretained(self)` in a
real-time audio callback, and `MainActor.assumeIsolated` in a `deinit`.

The Swift 6 language mode implies complete strict concurrency, and errors
rather than warnings. Xcode's **Approachable Concurrency**
(`SWIFT_APPROACHABLE_CONCURRENCY`) plus `MainActor` default isolation is what
new projects get, and it is the right target here: this app is a menu-bar UI
with two genuinely concurrent islands (audio capture and inference). Under
`MainActor`-by-default, almost everything is correct with no annotations, and
those two islands become the deliberate, visible exceptions.

That maps exactly onto the isolation table in
[03](03-api-seams.md#isolation-at-a-glance) — which is not a coincidence. The
module boundaries were chosen partly so the concurrency migration has clean
edges.

**Do the migration per module, not per app.** This is the strongest practical
argument for local SPM packages
([02, Option B](02-module-map.md#how-the-boundaries-get-enforced)): each
package can adopt Swift 6 independently, so the audio layer's real-time
callback can be worked out while everything else is already migrated. Flipping
one flag on a single 55-file target produces a wall of errors and a bad
afternoon.

### Concrete wins

**Drop `swift-atomics`.** The stdlib `Synchronization` module provides `Atomic`
and `Mutex` on macOS 15+. `CoreAudioRecorder` uses `ManagedAtomic` for the
recording gate and the metering bit-patterns; `RecordingSampleBuffer` uses
`NSLock`. Both are replaceable. That takes the dependency count from two to
**one** — FluidAudio — which in turn makes the "how many third-party things do
I depend on?" answer a single name.

**Audit each `@unchecked Sendable`.** `CoreAudioRecorder` and
`RecordingSampleBuffer` are both real-time-adjacent and both end up inside
`AudioCapture`. Under Swift 6 each needs either a justified `@unchecked` with a
comment explaining the invariant, or a redesign. Containing both in one module
is deliberate.

**Nonisolated real-time path.** The AUHAL render callback must stay off any
actor. Swift 6 makes that explicit instead of implicit — which is an
improvement, because right now nothing in the type system says that callback is
special.

## Transcription on the 2026 stack

This is where the platform changed most, and it is the seam the
[`Transcriber` protocol](03-api-seams.md#transcriber) exists to protect.

There are now three credible local backends.

### 1. FluidAudio + Parakeet (current)

Pinned to revision `3c6e79f…`. Upstream is now at 0.12.4 and offers:

- **Parakeet TDT v3** — 25 European languages. The app is on **v2**
  (English-only, better English recall). v2 remains the right default for
  English dictation; v3 is the answer if you ever want another language.
- **`SlidingWindowAsrManager`** — real streaming with cancellation. This is the
  principled replacement for the current
  re-transcribe-the-whole-buffer-every-1.5s live transcript.
- **Parakeet EOU** — 320 ms chunks for genuine real-time.
- **Silero VAD** — could gate inference on actual speech.

**Action:** the pin is a year of drift behind. Update it deliberately, on its
own commit, with the live-transcript path A/B'd — do not bundle it with the
restructuring. **DECIDE:** pin to a release tag rather than a raw revision, so
the version is legible.

### 2. Apple `SpeechAnalyzer` (macOS 26+)

The app already contains a complete implementation that nothing can reach.

Arguments for making it real: **zero third-party dependencies**, OS-managed
model assets via `AssetInventory` (no several-hundred-MB first-run download of
your own), native **volatile partial results** — which is exactly what the live
transcript wants and cannot get from a batch API — and it is the same engine
Apple ships in Notes and Voice Memos. An independent July 2026 benchmark put
`SpeechTranscriber` at ~2.1% WER on LibriSpeech test-clean, roughly on par with
Parakeet v2's published 2.1%, at about 3× Whisper Small's speed.

Arguments against: ~30 locales versus Parakeet's coverage, **no custom
vocabulary API** (relevant if you dictate jargon or proper nouns), and it ties
you to Apple's release cadence.

The `Speech` API surface worth designing against:
`SpeechTranscriber.supportedLocale(equivalentTo:)`,
`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`,
`CaptureInputSequenceProvider`, `AssetInventory`, and a results `AsyncSequence`
carrying volatile-versus-final results.

**This has a direct consequence for `AudioCapture` today.**
`SpeechAnalyzer` wants `AVAudioPCMBuffer`s in a format *it* nominates, not
`[Float]` at a rate you chose. So the capture session must be able to vend
buffers in a requested format, not only canonical 16 kHz floats. Designing that
in now costs nothing; retrofitting it later means re-plumbing the hot path.
See [03](03-api-seams.md#audiocapture).

**DECIDE:** default backend once the floor is ≥26 — keep Parakeet, switch to
`SpeechAnalyzer`, or make it a setting? Recommendation: keep Parakeet as the
default (behavior preservation) and make `SpeechAnalyzer` a real, selectable,
tested second backend. That converts 414 lines of dead code into a genuine
choice and proves the `Transcriber` seam works — a two-implementation protocol
is a boundary, a one-implementation protocol is a guess.

### 3. Core AI (macOS 27, new)

Apple's new on-device inference framework — the one powering Apple
Intelligence, now exposed to apps. Relevant properties:

- Memory-safe Swift API for loading and running your own models.
- Models **automatically specialized for the hardware**, with ahead-of-time
  compilation for fast first load.
- **Fine-grained control over inference memory** and zero-copy data paths.
- Stateful execution.
- A `coreai-models` Swift package with runtime libraries, plus Xcode graph
  inspection and profiling and a standalone Core AI Debugger.

Why it matters here specifically: model residency is one of only two knobs this
app exposes (`UnloadModelAfterIdleMinutes`), and cold-load latency is the main
reason it exists. AOT compilation attacks load time; explicit memory control
attacks the residency tradeoff directly. It is also the most plausible route to
running a Parakeet-class model on iOS, where memory is tight
([06](06-multiplatform-constraint.md)).

**Do not adopt this now.** It is a rewrite of the inference layer with no
user-visible benefit until the boundaries exist. Treat it as the reason the
`Transcriber` protocol must not leak Core ML or FluidAudio concepts. Revisit
after the module map lands.

## UI: Liquid Glass and the menu bar rework

### The menu bar changed under the hood

In macOS 27 the entire menu bar renders as a **single window**; the per-icon
windows are gone. This broke every third-party menu-bar manager (Bartender,
Ice, Hidden Bar and others) on the first beta. There is also a new native
expand/collapse overflow button.

**VERIFY — highest-risk item in this document.** This app uses `MenuBarExtra`
with `.menuBarExtraStyle(.menu)`. The reported breakages concentrate on the
`.window` style — programmatic presentation became a silent no-op, and the
panel would not become key, so text fields received no input. Both were
reported fixed in later betas. The `.menu` style is a far smaller surface and
is probably unaffected, but "probably" is not a plan: run the app on 27 and
confirm the icon appears, the menu opens, and the `waveform.circle.fill` /
`mic.circle` label still swaps with state.

One thing that is *not* at risk: the `ShortcutRecorder` capture control lives
in the Settings window, a real key window, so the `MenuBarExtra(.window)`
key-window bug never applied to it. Worth knowing before someone
defensively rewrites it.

`MiniRecorderPanel` is an app-owned `NSPanel`, unaffected by the menu bar
rework. **VERIFY** its non-activating behavior separately — that property is
load-bearing (`[C]` in [01](01-behavior-contract.md)) and panel activation
semantics are exactly the kind of thing that shifts between releases.

### Liquid Glass

Introduced in macOS 26 and refined in 27: more uniform refraction and better
contrast, uniform toolbars, edge-to-edge sidebars, updated window shapes and
menu bar icons, and a **user-facing opacity slider** from ultra-clear to fully
tinted. Most of it applies automatically.

New in 27 and worth deliberate adoption:

- **Interactive glass "bounce"** on click, for controls and containers of
  controls. The recorder panel's record/close buttons are candidates. Apple's
  guidance is that a little goes a long way.
- **Concentricity** (`cornerConfiguration`) so content in a corner adapts to
  its container's shape — relevant to the rounded recorder panel.
- `NSScrollEdgeEffectStyle` now resolves to a hard edge when there is
  free-floating text such as a window title.

**VERIFY:** `LeanUIComponents.VisualEffectView` wraps `NSVisualEffectView`. On
27 that should either be replaced by a SwiftUI glass effect or confirmed to
still render correctly against the new material. Also check the panel under the
user opacity slider at both extremes — a floating panel that becomes
unreadable at "ultra-clear" is a real regression.

**DECIDE:** is UI modernization in scope for the restructuring, or a separate
pass? Recommendation: **separate.** Mixing a visual refresh into a boundary
refactor makes both harder to review, and a visual change is a behavior change
by any honest definition.

## Permissions and packaging

- **Accessibility** is required twice — for the CGEventTap and for synthetic
  ⌘V. **VERIFY** on 27 that `AXIsProcessTrusted()` still covers both, and that
  Input Monitoring is not separately demanded for the tap.
- The stable self-signed **`VoiceInk Local`** identity is what keeps TCC grants
  alive across rebuilds. Keep it. It is one of the better decisions already in
  the repo and it is easy to lose accidentally.
- **Login item** uses `SMAppService`, which is current.
- `Info.plist` declares `NSMicrophoneUsageDescription` only. **VERIFY** whether
  27 wants anything additional for event taps or Apple-event scripting (the
  AppleScript paste path talks to System Events, which may require
  `NSAppleEventsUsageDescription`).
- **DECIDE:** the bundle ID is still `com.prakashjoshipax.VoiceInk` and is
  baked into the Application Support path, the log subsystem, and every TCC
  grant. Changing it means re-granting permissions and migrating the history
  log. See [02](02-module-map.md#naming).

## Available in the 2026 stack, deliberately not adopted

Listed so the choice is visible rather than accidental, each with the condition
that would make it worth revisiting.

| Technology | Why not now | Revisit when |
|---|---|---|
| **Foundation Models** — `LanguageModel` protocol, Private Cloud Compute, multimodal, Dynamic Profiles | This is AI text enhancement, the largest deliberate cut in [`FELT-GAPS.md`](../FELT-GAPS.md). Adding it is a feature. | Raw dictation output repeatedly isn't good enough. Note it is now the *cheap* path — on-device, no API key. |
| **App Intents** — entity/intent schemas, View Annotations, `AppIntentsTesting` | Siri and Shortcuts integration is a feature. | You want to dictate into a Shortcut, or an iOS build needs a non-hotkey trigger ([06](06-multiplatform-constraint.md)). |
| **Evaluations framework** | Built for LLM behavior. | You adopt Foundation Models. |
| **`fm` CLI** | Genuinely useful for *your* workflow, but it is not this app. | — |
| **Music Understanding, NowPlaying, WidgetKit, Spatial Preview** | Unrelated. | — |

## Audit checklist

The verification pass, once you are on a Mac with Xcode 27. Roughly in
dependency order.

**Build**
- [ ] Builds clean against the macOS 27 SDK; triage every new warning
- [ ] Deployment floor decided and made consistent across project and target
- [ ] Swift 6 language mode, module by module
- [ ] Approachable Concurrency + `MainActor` default isolation
- [ ] Both `@unchecked Sendable` conformances justified or removed
- [ ] `swift-atomics` removed in favour of `Synchronization`
- [ ] FluidAudio pin updated to a tag; changelog reviewed
- [ ] `make local` and `make install` still produce a launchable, signed app
- [ ] Clean rebuild from an empty derived-data directory works

**Runtime**
- [ ] Menu bar icon appears; menu opens; label swaps with state
- [ ] Recorder panel appears, positions correctly, and does **not** steal focus
- [ ] Panel readable at both extremes of the Liquid Glass opacity slider
- [ ] Settings window opens; the shortcut recorder captures keys
- [ ] Global hotkey works in toggle mode and in push-to-talk
- [ ] Paste lands correctly in a native app, a browser, and an Electron app
- [ ] Mic and Accessibility prompts appear and deep-link to the right pane
- [ ] TCC grants survive a rebuild and reinstall
- [ ] Model download from a clean cache completes
- [ ] Device switch mid-recording still recovers

**Non-regression**
- [ ] Idle CPU matches the pre-migration baseline
- [ ] Zero timers at idle (confirm in Instruments, don't assume)
- [ ] `record` / `transcribe` / `paste` signpost durations comparable
- [ ] Memory with the model resident is comparable
- [ ] Every `[C]` statement in [01](01-behavior-contract.md) still holds
