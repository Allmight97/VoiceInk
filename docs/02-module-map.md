# 2. Module map

The proposal: **ten modules in four tiers**, of which five are genuinely deep.

This document argues for that cut. [03 — API seams](03-api-seams.md) specifies
the interfaces.

## What "deep" means here

A module's *depth* is the ratio of complexity it hides to complexity it
exposes. `CoreAudioRecorder` is deep: 1,200 lines of AUHAL, ring buffers,
atomics and resampling behind roughly "start, stop, give me samples."
`TranscriptionDelivery` is shallow: 16 lines that call three other things, so
its interface is nearly as complex as its body.

Shallow modules aren't harmless. Each one is a name to learn, a file to open,
and a hop to trace, in exchange for hiding almost nothing. The test applied
throughout this document is: **if I inlined this into its only caller, would
the system get simpler?** If yes, it isn't a module.

The second test is *information leakage*: when one design decision — the shape
of a preference key, the fact that audio is 16 kHz, the choice of ASR
backend — is known in several modules, those modules are coupled no matter what
the call graph says.

## What's wrong with the current structure

Not "it's messy." Specific, load-bearing problems, each of which the new
boundaries are designed to solve.

### 1. The state machine exists in two places

`VoiceInkEngine` owns `recordingState` and switches on it in `toggleRecord()`.
`RecorderUIManager.toggleRecorderPanel()` **switches on the same state again**
to decide whether to toggle, cancel, or dismiss. And they hold references to
each other: the engine has `weak var recorderUIManager`, the UI manager has
`weak var engine`.

```
VoiceInkEngine ──weak──► RecorderPanelPresenting
       ▲                          │
       └──────────weak────────────┘
```

Panel visibility is an independently mutated `@Published Bool` whose `didSet`
shows or hides a window, when it should be a *derived function* of the
dictation state. This is the single highest-leverage thing to fix, because it
is the reason the control flow is hard to follow: to answer "what happens when
I press the hotkey?" you have to read two objects that call back into each
other.

### 2. Three shallow modules in the hot path

| Module | Lines | What it actually does |
|---|---|---|
| `TranscriptionPipeline` | 48 | calls transcribe, then two filters, then delivery, then the log |
| `TranscriptionDelivery` | 16 | plays a sound, hides a window, pastes |
| `TranscriptionServiceRegistry` | 46 | switches on `model.provider` — one live branch |

Together, 110 lines of indirection between the engine and the work. Worse, they
leak: the "pipeline" reaches into `WordReplacementService.shared`, performs a
disk write via `TranscriptionLog.append`, and triggers UI dismissal. It is an
orchestration script wearing a module's clothes.

### 3. `VoiceInkEngine` is broad, not deep

318 lines owning: the state machine, permission gating (via a **blocking
`NSAlert`**), WAV file lifecycle, signpost intervals, the partial-transcript
loop, model warm-up, idle-unload scheduling, and error toasts. It imports
`AppKit`. It reads `UserDefaults` with three bare string literals. It calls
`NotificationManager.shared`.

The orchestrator should be the *thinnest* interesting thing in the system — a
state machine over injected capabilities. Right now it is where policy from
five different domains has collected.

### 4. Preference knowledge is smeared across every layer

The same decision — a key's name, type, and default — is known in up to five
places:

```
AppDefaults.registerDefaults()        canonical defaults
AppDefaults.<constant>                some names
UserDefaults.Keys                     device names
"DebugKeepRecordings" literal         inline in VoiceInkEngine
@AppStorage("ShowLiveTranscript")     inline in views
FillerWordManager.fillerWordsKey      private, elsewhere
PasteMethod.userDefaultsKey           private, elsewhere again
```

Four keys are registered and never read. Two whole preference types
(`AppAppearancePreference`, `AppLanguagePreference`) have no call sites. This
is textbook information leakage, and it is why adding a setting currently means
touching four files.

### 5. Four singletons are four invisible dependency edges

`NotificationManager.shared`, `WordReplacementService.shared`,
`AudioDeviceManager.shared`, `FillerWordManager.shared`. None appear in the
composition root, so the object graph in `VoiceInk.swift` is a lie by
omission — and nothing that touches them can be tested without also standing
up global state.

### 6. Abstraction at the wrong seam

`TranscriptionModel` (protocol) + `ModelProvider` (enum) + a two-entry registry
+ `TranscriptionServiceRegistry` exist to support pluggable backends. But
`any TranscriptionModel` is threaded through four call signatures, and the one
caller passes a hardcoded constant.

The abstraction isn't wrong — swappable backends are exactly right for
[macOS 27](05-macos-27-adoption.md). It's placed wrong. **Backend choice is a
construction-time decision, not a per-call parameter.** Move it to composition
and four signatures get shorter while the system gets *more* pluggable.

### 7. Cross-boundary back-channels via NotificationCenter

`AudioDeviceManager` posts `audioDeviceSwitchRequired` and a string-literal
`"AudioDeviceChanged"`; `Recorder` observes both. That is a hidden edge between
two objects that already have a direct relationship. `dismissRecorderPanel` has
an observer and no poster at all.

## The proposed modules

Ten modules, four tiers. Dependencies point **downward and inward only**.

```
┌─ EDGE ────────────────────────────────────────────────────────┐
│  ShortcutHub                    Presentation                  │
│  (intents out)                  (state in, intents out)       │
└───────────────┬───────────────────────┬───────────────────────┘
                │  DictationIntent      │  DictationState
                ▼                       ▼
┌─ CORE ────────────────────────────────────────────────────────┐
│  Dictation — the state machine. No AppKit. No UI. No I/O.     │
└───┬──────────────┬──────────────┬──────────────┬──────────────┘
    ▼              ▼              ▼              ▼
┌─ CAPABILITIES ────────────────────────────────────────────────┐
│ AudioCapture  Transcriber   TextShaping    TextSink           │
└───────────────────────────────────────────────────────────────┘
┌─ SUPPORT (available to all tiers, depends on none) ───────────┐
│  Preferences        Diagnostics        TranscriptHistory      │
└───────────────────────────────────────────────────────────────┘

AppComposition — the only place that knows all ten exist.
```

Two rules make this real rather than aspirational:

- **`Dictation` and the four capabilities never import AppKit or SwiftUI.**
- **Exactly one file in the repo imports FluidAudio.**

### Core

#### `Dictation`

*Owns: what happens between "the user wants to dictate" and "the text is
somewhere useful."*

Hides: the state machine and its legal transitions; cancellation at every
stage (before capture, mid-capture, mid-inference, mid-delivery); the race
guards that today are `activeRecordingID` and `shouldCancelRecording`;
push-to-talk versus toggle reconciliation; when to warm the model and when to
release it; whether and how often to request a partial transcript; what counts
as a completed dictation.

Exposes: five verbs (`toggle`, `begin`, `end`, `cancel`, `setHeld`) and one
observable state value.

Explicitly *not* owned: how audio is captured, which ASR runs, how text is
cleaned, how text reaches the app, what a panel looks like, where preferences
live.

This is the module that makes the app comprehensible. Read it and you know the
system. It should be around 200 lines and import nothing but Foundation and
the capability protocols.

### Capabilities

#### `AudioCapture`

*Owns: turning a microphone into a stream of samples.*

Hides: AUHAL setup and teardown; device enumeration, the three selection modes,
and the priority list; hot-swap when a device disappears mid-recording; format
negotiation and resampling to the canonical 16 kHz mono; the lock-free ring
buffer and its backpressure counters; level metering; the microphone permission
state; the memory ceiling on a single utterance.

The key interface change: today the engine sets a mutable
`recorder.onAudioChunk` closure, separately observes `@Published audioMeter`,
and separately drives a 17 ms `DispatchSourceTimer`. That's three coupling
channels for one relationship. Replace all three with **one `AsyncStream` of
capture events**. Levels become just another event, and there is exactly one
lifetime to reason about.

Not owned: file writing (moves to `Diagnostics` as an observer), what the
samples are *for*.

#### `Transcriber`

*Owns: audio in, text out, on this machine.*

Hides: which backend is running; model download, cache location, disk-presence
checks, load, residency, and release; warm-up; backend quirks (the 1 s silence
pad, `TextNormalizer`); the sample-rate contract; the mapping from backend
errors to something a user can act on.

Exposes: an availability value, `prepare()`, `transcribe(_:)`, `release()`.
**No model parameter.** The caller says what it wants done, not how.

Three implementations are on the table — FluidAudio/Parakeet today, Apple's
`SpeechAnalyzer`, and Core AI on macOS 27 (see
[05](05-macos-27-adoption.md)). The interface has to be honest about the fact
that they differ in one important way: `SpeechAnalyzer` produces *volatile
partial results natively*, which would replace today's
re-transcribe-the-whole-buffer loop. That belongs in an optional
`StreamingTranscriber` capability, not in the base protocol — otherwise every
backend pays for a feature only one can provide.

#### `TextShaping`

*Owns: the difference between what the model emitted and what the user wants
pasted.*

Hides: filler-word removal, bracket policy, whitespace normalisation, word
replacement (including the longest-key-first ordering and the Latin-versus-CJK
matching split), and — in future — casing and punctuation policy.

Pure, synchronous, `Sendable`, no I/O, no globals. Rules arrive as a value
type; it does not read `UserDefaults` itself. That makes it the one module that
is trivially exhaustively testable, which is why it is the right place to start
(see [07](07-sequencing.md)).

#### `TextSink`

*Owns: getting text from this app into the one the user is looking at.*

Hides: clipboard snapshot and restore with session ownership checks; the two
paste strategies and the keyboard-layout detection that chooses between them;
the Accessibility trust check; the timing constants; classifying what went
wrong.

The one interface change worth arguing for: **`insert` returns an outcome
rather than swallowing failure.** Today a failed paste is logged and the user
sees nothing (see [01, undefined behavior #1](01-behavior-contract.md)). A sink
that can't report failure forces every caller to assume success.

This is also the module that will look completely different on iOS, which is
exactly why it must be a protocol. See [06](06-multiplatform-constraint.md).

### Edges

#### `ShortcutHub`

*Owns: the global keyboard surface.*

Hides: the CGEventTap and its lifecycle and install failures; key/modifier
matching; toggle versus push-to-talk semantics; the 1 s interruption window;
double-Escape cancel while the panel is up; shortcut persistence, validation,
and conflict detection; the capture UI used to assign a shortcut.

**Dependency inversion:** today `RecordingShortcutManager` holds
`weak var engine` and calls methods on it. Instead the hub vends an
`AsyncStream<DictationIntent>`. Shortcuts stop knowing what dictation is; they
just report what the user pressed. That also lets the two separate
`ShortcutMonitor` instances collapse behind one owner.

#### `Presentation`

*Owns: everything the user sees.*

Hides: the menu bar item; the Settings scene; the recorder panel's window
class, placement, non-activating behavior and lifetime; transient
notifications; the live-transcript view; all Liquid Glass adoption.

Consumes `DictationState`, emits `DictationIntent`. It **never calls into
`Dictation`'s internals and never re-implements the state machine.** Panel
visibility becomes `state.isActive` — a derived value, not an independently
mutated boolean — which deletes the duplicated switch in
`RecorderUIManager.toggleRecorderPanel()` and breaks the bidirectional
reference.

Presentation is also where the *blocking* `NSAlert` permission prompts move.
The core should surface "microphone permission is missing" as state; only the
UI layer decides to put a modal on screen.

### Support

#### `Preferences`

*Owns: every setting's name, type, default, migration, and observation.*

One typed store. Modules receive a narrow read-only slice
(`CaptureSettings`, `ShapingRules`, …) rather than the whole thing, so a module
can't reach a setting it has no business reading. **No other module touches
`UserDefaults`.**

That single rule collapses seven scattered locations into one, makes "what
settings exist?" answerable by opening one file, and makes the four
never-read keys visible as the dead code they are.

#### `Diagnostics`

*Owns: what gets recorded about the app's own behavior.*

Logging subsystem and categories, signpost intervals, and debug audio
retention. Debug WAV writing moves here as an *optional observer of the capture
stream* — which takes file I/O out of the hot path entirely and means the
common case never touches the disk.

#### `TranscriptHistory`

*Owns: the record of what was dictated.*

The append-only JSONL log, reading the most recent entry, and any future
retention policy. Small, but it has user-visible semantics ("Copy Last
Transcription"), so it is a product surface rather than diagnostics.

## What this deletes

Not moved — deleted, because the boundary makes them unnecessary:

| Gone | Why |
|---|---|
| `TranscriptionPipeline` | its five lines of sequencing live in `Dictation` |
| `TranscriptionDelivery` | pass-through over three unrelated things |
| `TranscriptionServiceRegistry` | backend chosen at composition, not per call |
| `TranscriptionModel`, `ModelProvider`, `TranscriptionModelRegistry` | model identity is internal to `Transcriber` |
| `RecorderUIManager`'s state switch | panel visibility derives from state |
| `RecorderStateProvider`, `RecorderPanelPresenting` | artifacts of the bidirectional coupling |
| 4 singletons | become constructor parameters |
| `.enhancing`, `.busy` | never assigned, yet handled at 11 sites across 5 files |
| `AppAppearancePreference`, `AppLanguagePreference`, `ParagraphFormatter`, `AudioDeviceConfiguration`, `VoiceInkEngineError` | no call sites |
| `swift-atomics` | replaceable by stdlib `Synchronization` — see [05](05-macos-27-adoption.md) |

Full file-by-file classification in [04](04-tidy-up-inventory.md).

## How the boundaries get enforced

A directory convention is a suggestion. A compiler error is a boundary.

**DECIDE — the most consequential structural choice in this document.**

**Option A — directories only.** Keep one app target and the existing
filesystem-synchronized group. Zero build changes, zero friction. But nothing
stops a future edit (or an agent) from importing AppKit into `Dictation` or
calling a singleton across a tier. Conventions rot; this one already did once.

**Option B — local SPM packages for Core + Capabilities + Support; app target
keeps Presentation and AppComposition.** Recommended.

- A package that doesn't link AppKit **cannot** import it. The rule enforces
  itself.
- A package that doesn't depend on FluidAudio **cannot** reach it. "Exactly one
  file imports FluidAudio" becomes structural.
- Swift 6 language mode can be adopted **per package**, so the concurrency
  migration in [05](05-macos-27-adoption.md) becomes incremental rather than a
  single all-or-nothing flag flip.
- Each package gets a test target for free, with no app launch.
- It is the precondition for [iOS](06-multiplatform-constraint.md): the shared
  core is exactly the set of packages, and "does it still build for iOS?" is a
  one-command check.

Costs, honestly: `project.pbxproj` churn, slower clean builds, and losing the
convenience of the synchronized group inside packages.

**Option C — one package containing all non-UI modules as separate targets.**
Most of Option B's enforcement with one `Package.swift` to maintain. A
reasonable compromise if B feels heavy.

Recommendation: **B**, because the enforcement is the point. Everything in
this document is a convention until the build system agrees with it.

## Naming

Module names here are deliberately functional and carry no product name,
because the app may be renamed. `Dictation`, `AudioCapture`, `Transcriber`,
`TextShaping`, `TextSink`, `ShortcutHub`, `Presentation`, `Preferences`,
`Diagnostics`, `TranscriptHistory` all survive a rename untouched.

**DECIDE:** the bundle identifier is still `com.prakashjoshipax.VoiceInk`, and
it is baked into the Application Support path, the log subsystem, and every
existing TCC grant. Changing it means re-granting microphone and accessibility
permission and migrating (or abandoning) the existing history log and settings.
That is a one-time cost best paid deliberately, at a moment of your choosing —
and best paid *before* a lot of new code hardcodes the old string. Worth
deciding now even if it is executed later.
