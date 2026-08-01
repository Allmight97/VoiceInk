# 7. Sequencing

The order of work, and the gate that keeps behavior unchanged at every step.

Two principles drive the ordering:

1. **Build the net before working without one.** The app has no real tests. A
   restructuring with no regression net is a rewrite with extra steps.
2. **Cheapest and most certain first.** Deletions and pure extractions need no
   decisions and carry no risk. Do them first so the risky work happens in a
   smaller, clearer codebase.

## The gate

Every wave ends by passing the same four checks. A wave that can't pass them
gets reverted, not patched.

| Check | What it means |
|---|---|
| **Builds clean** | no new warnings, `make local` produces a launchable app |
| **Tests green** | every test that existed before the wave still passes, unmodified |
| **Smoke passes** | the manual script below, run once |
| **Idle unchanged** | timer count and idle CPU match the Wave 0 baseline |

Plus one rule with no exceptions: **if a wave changes observable behavior, it
says so in its commit message and cites the `[?]` item in
[01](01-behavior-contract.md) that authorised it.** Unannounced behavior change
is the specific failure mode this whole exercise exists to avoid.

### The smoke script

The parts no automated test can reach. Ten minutes, run at the end of each
wave.

1. Hotkey in **toggle** mode: dictate into TextEdit, confirm the text lands.
2. Hotkey in **push-to-talk**: hold, speak, release, confirm.
3. **Cancel** mid-recording via the cancel shortcut, and via double-Escape.
4. **Interrupt**: press the hotkey, then another key within a second — confirm
   the session cancels.
5. Dictate into a **browser** and an **Electron app** (the timing-sensitive
   cases).
6. **Unplug the active microphone mid-recording** — confirm it recovers rather
   than dropping the session.
7. Toggle **live transcript** on, dictate a long sentence, confirm partials.
8. Deny **Accessibility** in System Settings, attempt to dictate, confirm the
   alert, restore.
9. **Quit and relaunch** — confirm state resets and the panel is hidden.
10. Leave the app **idle for five minutes** — confirm zero CPU.

## Wave 0 — baseline and net

Nothing moves. This wave only makes the following waves checkable.

- **Measure the idle baseline.** Instruments: timer count, idle CPU samples,
  resident memory with and without the model loaded. Commit the numbers into
  the repo. Everything later compares against this file.
- **Characterization tests for pure logic**, written against the code *as it
  is today*: `TranscriptionOutputFilter`, `WordReplacementService`,
  `Shortcut` matching and encoding, `WAVEncoder`, `AppDefaults` registration.
  These must pass unchanged after every later wave — that is the entire point.
- **Capture a transcript corpus.** Twenty or thirty real raw ASR outputs with
  their expected shaped results. This is the golden data for
  [`ShapingRules.current`](03-api-seams.md#textshaping) and it cannot be
  reconstructed later.
- **Record the smoke script results once**, so "it worked before" is a fact
  rather than a memory.

Scope: two test targets, no app code. Risk: none.

**This wave is not optional.** Skipping it makes every later "no behavior
change" claim unverifiable.

## Wave 1 — free deletions

Everything in [04, DELETE](04-tidy-up-inventory.md#delete--verified-unreachable),
all verified unreachable.

- 5 dead Swift files under `VoiceInk/` (~314 lines)
- `.enhancing` and `.busy`, and their 11 handling sites across 5 files
- the unposted `dismissRecorderPanel` notification, `seedShortcut`,
  `removeShortcutStorage`, `affiliatePromotionDismissed`,
  `downloadFluidAudioModel`, the unused `@EnvironmentObject`
- 4 registered-but-unread default keys
- 18 unused imagesets
- `appcast.xml`, `announcements.json`, `Scripts/quic-vpn-repro.swift`

Scope: broad but shallow — many files, trivial edits. Risk: near zero; the
compiler catches any mistake. Dependencies: none.

Do this before anything else. Every subsequent wave is read in a smaller
codebase.

## Wave 2 — `Preferences`

Consolidate seven scattered locations into typed `PreferenceKey` declarations
and one store. Derive `registerDefaults()` from the declarations instead of
maintaining it alongside them.

Scope: touches almost every file, but each edit is mechanical — a string
literal becomes a typed accessor. Risk: **key-name typos silently reset a
user's settings.** Mitigate with a test asserting every declared key's name
against a frozen list, so a rename fails loudly.

Dependencies: Wave 1. Unblocks: everything, because every other module
currently reaches `UserDefaults` independently.

**DECIDE first:** `@AppStorage` in views, or bind to the store? See
[03](03-api-seams.md#preferences).

## Wave 3 — `TextShaping`, and the packaging pilot

Extract the pure text pipeline as a struct over `ShapingRules`. Golden test:
given `.current`, output is byte-identical to today's filter chain across the
Wave 0 corpus.

**Make this the first local SPM package.** It is the smallest, purest module in
the system, so it is the right place to work out the mechanics of
[02, Option B](02-module-map.md#how-the-boundaries-get-enforced): package
layout, test target, Swift 6 language mode, and the iOS compile check from
[06](06-multiplatform-constraint.md). Learning all that on a 150-line pure
module is much cheaper than learning it on the audio layer.

Scope: three files into one package. Risk: low, and fully covered by the golden
test. Dependencies: Wave 2.

If packaging turns out to be more friction than it is worth, this is where you
find out — cheaply, and with the option to fall back to directories.

## Wave 4 — break the engine ↔ UI cycle

The highest-leverage structural change, and the first one with real risk.

- `Dictation` publishes read-only `DictationState`.
- `Presentation` derives panel visibility from `state.isActive` instead of
  owning a mutable `isRecorderPanelVisible`.
- Delete the duplicated state machine in
  `RecorderUIManager.toggleRecorderPanel()`.
- Delete `RecorderStateProvider` and `RecorderPanelPresenting`.
- Move the permission `NSAlert`s out of the core into `Presentation`; the core
  reports missing permission as state.
- Core stops importing `AppKit`.

Scope: `VoiceInkEngine`, `RecorderUIManager`, `MiniWindowManager`,
`MenuBarView`, `VoiceInk.swift`. Invasive but concentrated.

Risk: **the highest of any wave.** Panel show/hide timing, the
dismiss-before-paste ordering, and launch reset are all subtle and all
currently emergent from two objects calling each other. Smoke items 1–3, 7 and
9 are the ones to watch.

Dependencies: Wave 2. Unblocks: Waves 5 and 6, both of which are much simpler
once there is one state machine.

## Wave 5 — collapse the pipeline; introduce `Transcriber`

- Fold `TranscriptionPipeline` + `TranscriptionDelivery` +
  `TranscriptionServiceRegistry` into `Dictation` (−110 lines of indirection).
- Introduce the [`Transcriber` protocol](03-api-seams.md#transcriber) with the
  FluidAudio adapter as its single implementation.
- Delete `TranscriptionModel`, `ModelProvider`, `TranscriptionModelRegistry`,
  and the `any TranscriptionModel` parameter from four signatures.
- Move model residency, warm-up, and idle unload inside `Transcriber`.
- Replace `shouldCancelRecording: Bool` with structured task cancellation.
- Introduce `TextSink` and `TranscriptHistory` as injected protocols.

Scope: the whole `Transcription/Engine` directory plus `Paste/`. Risk: moderate
— cancellation semantics are easy to get subtly wrong. Add contract tests with
a fake transcriber that can be made to hang, fail, or be cancelled.

Dependencies: Wave 4.

**DECIDE before starting:** does `TextSink` surface paste failure to the user?
That is [01, undefined behavior #1](01-behavior-contract.md) and it is a
behavior change either way — including the decision to keep it silent.

## Wave 6 — `AudioCapture`

The largest and most valuable capability extraction.

- `CaptureSession` replaces the `onAudioChunk` closure, `@Published
  audioMeter`, and the 17 ms `DispatchSourceTimer`.
- `AudioDeviceManager` stops being a singleton and moves inside.
- WAV writing leaves the hot path, becoming a `Diagnostics` observer.
- The two NotificationCenter back-channels become internal calls or
  `CaptureEvent`s.
- Design in the ability to vend `AVAudioPCMBuffer` in a requested format — the
  prerequisite for `SpeechAnalyzer` ([05](05-macos-27-adoption.md)).

Scope: ~2,200 lines across four files, the densest code in the repo. Risk:
high, but *contained* — it is one subsystem with a narrow interface, and the
smoke script covers it well (items 1, 2, 6, 10). The 30-minute buffer ceiling
and the device hot-swap path both need explicit testing.

Dependencies: Waves 4 and 5.

## Wave 7 — remaining packages, `ShortcutHub` inversion

- Extract the remaining modules as packages, following Wave 3's pattern.
- Invert `ShortcutHub` to emit `DictationIntent` rather than holding
  `weak var engine`; collapse the two `ShortcutMonitor` instances.
- Surface `TapInstallation` so event-tap failure stops being silent.
- Turn on the iOS compile check for the portable five
  ([06](06-multiplatform-constraint.md)).

Scope: 1,650 lines of shortcut code, plus package plumbing. Risk: moderate; the
shortcut internals stay intact, only the seam moves.

Dependencies: Waves 3, 4, 6.

At the end of this wave the module map in [02](02-module-map.md) is real and
compiler-enforced. **This is the natural stopping point** if the appetite runs
out — everything after it is modernization rather than restructuring.

## Wave 8 — macOS 27 and Swift 6

Now, and not before: modernizing code you are about to move is wasted work.

- Deployment floor decision, made consistent across project and target.
- Swift 6 language mode per package, plus Approachable Concurrency and
  `MainActor` default isolation.
- Drop `swift-atomics` for stdlib `Synchronization`.
- Justify or remove both `@unchecked Sendable` conformances.
- Update the FluidAudio pin to a tag.
- Work the [audit checklist](05-macos-27-adoption.md#audit-checklist).

Scope: build settings plus targeted rewrites. Risk: moderate, but per-package
migration keeps each step small. Dependencies: Wave 7 (packages are what make
this incremental).

## Wave 9 — prove the seam

Add `SpeechAnalyzer` as a real, selectable, tested second `Transcriber`,
replacing the 414 lines of currently-unreachable `Transcription/Native/` code.

This is not a feature — it is the **validation** of the whole exercise. A
protocol with one implementation is a guess. A protocol with two is a boundary.
If adding the second backend requires changing the interface, the interface was
wrong, and this is the cheapest possible moment to learn that.

Adopt the native volatile-partial-results path here too, replacing the
re-transcribe-everything live transcript loop.

Dependencies: Wave 8 (needs the raised floor).

## Then: UI modernization, separately

Liquid Glass adoption, the interactive glass effect, concentric corners, and
the `NSVisualEffectView` question. Kept out of every wave above on purpose — a
visual change is a behavior change, and mixing it into a boundary refactor
makes both impossible to review.

## Risk register

| Risk | Where | Mitigation |
|---|---|---|
| Idle cost regresses silently | Waves 4, 6 | Wave 0 baseline compared at every gate; it is a gate, not a nice-to-have |
| Panel timing changes break the dismiss-before-paste ordering | Wave 4 | smoke items 1–3; keep the ordering explicit in `Dictation` |
| Cancellation becomes subtly wrong | Wave 5 | contract tests with a fake transcriber that hangs and fails |
| Real-time audio thread violated under Swift 6 | Waves 6, 8 | keep the callback `nonisolated`; contain both `@unchecked Sendable` in one module |
| Preference key renamed, settings silently reset | Wave 2 | frozen-key-name test |
| Package extraction turns out to be more friction than value | Wave 3 | that is why Wave 3 is the pilot, on the smallest module, with a cheap fallback |
| Scope creep into features | every wave | [01](01-behavior-contract.md) is the contract; new wants go to [`FELT-GAPS.md`](../FELT-GAPS.md), not into a wave |
| macOS 27 breaks something unforeseen | Wave 8 | run the [audit checklist](05-macos-27-adoption.md#audit-checklist) on 27 **before** Wave 8, so surprises land as known work rather than mid-migration discoveries |

That last one is worth acting on early: running the app on macOS 27 and working
the runtime half of the audit checklist costs almost nothing and can be done
today, in parallel with Wave 0.
