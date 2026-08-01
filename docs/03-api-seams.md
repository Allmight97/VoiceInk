# 3. API seams

The concrete public surface of each module from [02](02-module-map.md).

These are proposals to argue with. The signatures matter more than the names —
if a signature forces a caller to know something it shouldn't, the boundary is
wrong and should be moved before any code does.

## Rules every seam follows

1. **Intent, not strategy.** A caller says what it wants. It never selects an
   implementation, passes a model identifier, or knows a provider's mechanics.
2. **Effects are visible in the signature.** Anything that writes a file, hits
   the network, touches the pasteboard, or shows UI says so — by return type,
   by throwing, or by living in a module whose whole job is that effect.
3. **Errors are classified, not forwarded.** A module translates its
   dependencies' errors into cases a caller can actually branch on. Nobody
   propagates a raw `NSError` across a boundary.
4. **Cancellation is structured.** Swift task cancellation plus a session
   token, not a shared mutable `Bool` read from three places.
5. **Isolation is declared at the seam,** not discovered by the compiler later.
   See the isolation table at the end.
6. **A protocol is for variation or for an effect boundary.** Pure functions
   are structs. `TextShaping` has no protocol because there is nothing to vary
   and nothing to fake.

## Shared value types

```swift
/// Mono PCM at the canonical rate. The only audio representation that
/// crosses a module boundary.
struct PCMAudio: Sendable, Equatable {
    static let canonicalSampleRate = 16_000

    let samples: [Float]        // normalized -1...1
    let sampleRate: Int
    var duration: Duration { .seconds(Double(samples.count) / Double(sampleRate)) }
    var isEmpty: Bool { samples.isEmpty }
}

/// Normalized 0...1, already smoothed. Presentation does not do DSP.
struct AudioLevel: Sendable, Equatable {
    let value: Double
    static let silent = AudioLevel(value: 0)
}
```

Pinning `canonicalSampleRate` in one place is deliberate: today "16 kHz" is
knowledge shared by the recorder, the FluidAudio adapter, and the WAV encoder.

## `AudioCapture`

```swift
protocol AudioCapture: Sendable {
    var availableInputs: [AudioInput] { get async }
    var selectedInput: AudioInput? { get async }
    func selectInput(_ selection: AudioInputSelection) async

    var permission: MicrophonePermission { get async }
    func requestPermission() async -> MicrophonePermission

    /// Idempotent. Warms the hardware path without capturing.
    func prepare() async

    /// Fails rather than returning an unusable session.
    func beginSession() async throws(CaptureFailure) -> any CaptureSession
}

/// A live capture. Holding one *is* the proof that capture is running,
/// which is why `AudioCapture` has no `isRecording` flag.
protocol CaptureSession: Sendable {
    var events: AsyncStream<CaptureEvent> { get }

    /// Copy of everything captured so far. Does not end the session.
    func snapshot() async -> PCMAudio

    /// Ends capture and yields the full utterance.
    func finish() async -> PCMAudio

    /// Ends capture and discards. Never yields audio.
    func discard() async
}

enum CaptureEvent: Sendable {
    case level(AudioLevel)
    case inputSwitched(to: AudioInput, from: AudioInput)
    case reachedCapacityLimit
    case interrupted(CaptureFailure)
}

enum AudioInputSelection: Sendable, Equatable, Codable {
    case systemDefault
    case specific(deviceUID: String)
    case prioritized([String])          // UIDs, first available wins
}

enum CaptureFailure: Error, Sendable, Equatable {
    case permissionDenied
    case noInputDevice
    case deviceUnavailable(uid: String)
    case hardwareFailed(code: Int32)    // OSStatus, already logged
}

enum MicrophonePermission: Sendable, Equatable {
    case granted, denied, notDetermined
}
```

**What changed, and why.**

*Three coupling channels collapse into one.* Today `Recorder` exposes a mutable
`onAudioChunk` closure that the engine assigns, a separate `@Published
audioMeter`, and a separate 17 ms `DispatchSourceTimer` publishing to the main
actor. All three describe one relationship, with three lifetimes to get right.
One session with one event stream replaces them, and the 17 ms main-actor hop
disappears — levels ride the stream that already exists.

*Samples are not in the event stream.* `CaptureEvent` carries levels and
incidents, not audio. Streaming every buffer through an `AsyncStream` to a
`@MainActor` consumer would move the hot path onto the main actor, which is
exactly backwards. The session accumulates internally; `snapshot()` serves
partials and `finish()` serves the final utterance. If a real streaming ASR
backend arrives ([05](05-macos-27-adoption.md)), the session gains a second,
opt-in sample stream consumed off the main actor — without changing this
interface.

*Device management moves inside.* `AudioDeviceManager.shared` disappears as a
global. Settings talks to `availableInputs` / `selectInput`, and the
`"AudioDeviceChanged"` NotificationCenter back-channel becomes an internal
detail — or an `inputSwitched` event when it is worth telling the user.

*WAV writing leaves.* Today every recording is written to disk and then
deleted. Debug retention becomes a `Diagnostics` observer, so the common path
never touches the filesystem.

**Effects:** microphone hardware, TCC prompt. No disk, no network.
**Isolation:** `actor` internally; the AUHAL callback stays `nonisolated` on
the real-time thread and hands off through a lock-free buffer.

## `Transcriber`

```swift
protocol Transcriber: Sendable {
    var availability: TranscriberAvailability { get async }
    var availabilityUpdates: AsyncStream<TranscriberAvailability> { get }

    /// Download if needed, then load. Idempotent. Safe to call speculatively.
    func prepare() async throws(TranscriptionFailure)

    /// Honors task cancellation.
    func transcribe(_ audio: PCMAudio) async throws(TranscriptionFailure) -> Transcript

    /// Release model memory. `prepare()` afterwards must work.
    func release() async
}

struct Transcript: Sendable, Equatable {
    let text: String
    let confidence: Double?
    let locale: Locale?
}

enum TranscriberAvailability: Sendable, Equatable {
    case notPrepared
    case needsDownload(estimatedBytes: Int64?)
    case downloading(fraction: Double)
    case ready
    case unavailable(reason: String)
}

enum TranscriptionFailure: Error, Sendable {
    case modelNotAvailable(TranscriberAvailability)
    case downloadFailed(underlying: any Error)
    case audioRejected(reason: String)      // empty, too short, wrong rate
    case inferenceFailed(underlying: any Error)
    case cancelled
}
```

**No `model:` parameter, no `any TranscriptionModel`, no registry.** Backend
choice is made once in `AppComposition` from settings. Four call sites get
shorter and the system becomes *more* pluggable, because the pluggability now
lives at the seam where implementations actually differ.

`downloadFailed` is separated from `inferenceFailed` for one concrete reason:
today both surface as the same "Transcription failed: …" toast, so a user on a
new machine with a slow connection sees the same message as a user with a
corrupt model. See [01, undefined behavior #4](01-behavior-contract.md).

**Optional capability, for backends that stream natively:**

```swift
protocol StreamingTranscriber: Transcriber {
    func beginStream() async throws(TranscriptionFailure) -> any TranscriptionStream
}

protocol TranscriptionStream: Sendable {
    func append(_ audio: PCMAudio) async
    /// Volatile hypotheses followed by finalized segments.
    var results: AsyncStream<PartialTranscript> { get }
    func finish() async throws(TranscriptionFailure) -> Transcript
}

struct PartialTranscript: Sendable, Equatable {
    let text: String
    let isFinal: Bool
}
```

This is where the live-transcript feature belongs. Today `Dictation`'s
equivalent re-transcribes the entire buffer every 1.5 s — cost grows with
utterance length and earlier text rewrites itself. Apple's `SpeechAnalyzer`
produces volatile results natively; FluidAudio has `SlidingWindowAsrManager`.
Keeping this off the base protocol means a non-streaming backend doesn't have
to pretend.

`Dictation` uses the streaming path when the injected transcriber conforms and
the setting is on, and falls back to the current snapshot loop otherwise.

**Effects:** network on first download, disk for the model cache, significant
memory while resident.
**Isolation:** `actor`. Inference must not run on the main actor.

## `TextShaping`

```swift
struct ShapingRules: Sendable, Equatable, Codable {
    var fillerWords: [String]
    var removesTagBlocks: Bool
    var brackets: BracketPolicy
    var replacements: [String: String]
    var replacementsEnabled: Bool
    var collapsesWhitespace: Bool
    var appendsTrailingSpace: Bool

    static let current: ShapingRules   // exactly today's behavior
}

enum BracketPolicy: Sendable, Equatable, Codable {
    case keepAll
    case removeSquareOnly
    case removeAll                     // today's behavior
}

struct TextShaper: Sendable {
    let rules: ShapingRules
    func shape(_ raw: String) -> String
}
```

A struct, not a protocol. There is no variation to abstract and nothing to
fake — a protocol here would be pure ceremony.

`BracketPolicy` exists to make [undefined behavior #2](01-behavior-contract.md)
an explicit setting rather than a hardcoded regex. Default stays `.removeAll`
so nothing changes until you decide it should.

`ShapingRules.current` is the behavior-preservation anchor: the migration is
correct when the new shaper, given `.current`, produces byte-identical output
to `TranscriptionOutputFilter` + `WordReplacementService` for a corpus of real
transcripts. That is a test that can be written **before** anything moves.

**Effects:** none. Pure. **Isolation:** `nonisolated`, `Sendable`.

## `TextSink`

```swift
protocol TextSink: Sendable {
    var readiness: SinkReadiness { get async }
    func insert(_ text: String) async -> InsertionOutcome
}

enum SinkReadiness: Sendable, Equatable {
    case ready
    case needsAccessibilityPermission
    case unavailable(reason: String)
}

enum InsertionOutcome: Sendable, Equatable {
    case inserted
    /// Text is on the clipboard, keystroke never landed. Recoverable: ⌘V works.
    case copiedToClipboardOnly(InsertionFailure)
    /// Text is nowhere. Not recoverable by the user.
    case failed(InsertionFailure)
}

enum InsertionFailure: Sendable, Equatable {
    case accessibilityPermissionMissing
    case clipboardUnavailable
    case keystrokeRejected
    case scriptingFailed
}
```

`insert` does not throw. Failure is an *outcome*, because the caller must act
on it — and because the difference between "your text is safe on the clipboard"
and "your words are gone" is the difference between an annoyance and a reason
to distrust the app. Today both are a log line.

Surfacing that outcome to the user is a behavior change, gated on
[undefined behavior #1](01-behavior-contract.md).

**Effects:** pasteboard, synthetic keyboard events, possibly Apple events.
**Isolation:** `@MainActor` — CGEvent posting and `NSPasteboard` want it.

## `Dictation`

```swift
enum DictationPhase: Sendable, Equatable {
    case idle
    case starting        // permissions, hardware
    case listening
    case transcribing
    case delivering
}

struct DictationState: Sendable, Equatable {
    var phase: DictationPhase = .idle
    var level: AudioLevel = .silent
    var partialText: String = ""
    var transcriber: TranscriberAvailability = .notPrepared
    var lastFailure: DictationFailure?

    var isActive: Bool { phase != .idle }
}

enum DictationIntent: Sendable, Equatable {
    case toggle
    case begin
    case end
    case cancel
    case setHeld(Bool)      // push-to-talk
}

enum DictationFailure: Sendable, Equatable {
    case microphonePermissionMissing
    case accessibilityPermissionMissing
    case captureFailed(CaptureFailure)
    case transcriptionFailed(String)     // already user-facing
    case deliveryFailed(InsertionFailure)
    case producedNoText
}

@MainActor
protocol DictationController: AnyObject, Observable {
    var state: DictationState { get }
    func handle(_ intent: DictationIntent) async
}
```

**One entry point.** Every edge — hotkey, menu item, panel button — produces a
`DictationIntent` and hands it over. There is exactly one place where "what
does pressing the hotkey do right now?" is answered, and it is a switch over
`(phase, intent)`.

**State is read-only to everyone else.** `Presentation` derives panel
visibility from `state.isActive` rather than owning a mutable
`isRecorderPanelVisible`. That deletes the duplicated state machine in
`RecorderUIManager.toggleRecorderPanel()` and the engine↔UI reference cycle in
one move.

**Cancellation.** `shouldCancelRecording: Bool` — currently written by the
engine and read from inside the pipeline's escaping closure — is replaced by
holding the in-flight `Task` and cancelling it. `Transcriber.transcribe` honors
`Task.isCancelled`; the `CaptureSession` is discarded rather than finished. The
`activeRecordingID` race guard is subsumed by the session object: a stale
session is one you no longer hold.

**`.delivering` is new.** Today delivery happens inside `.transcribing`.
Splitting it makes the phase list honest and is invisible to the user *unless*
the menu label changes. **DECIDE:** keep the menu showing "Transcribing" across
both phases to preserve behavior exactly.

`Dictation` imports Foundation and the capability protocols. Not AppKit, not
SwiftUI, not FluidAudio, not `UserDefaults`.

**Effects:** none of its own. It only sequences its dependencies' effects.
**Isolation:** `@MainActor`, because it publishes state to SwiftUI. All actual
work is `await`ed into actors, so the main actor coordinates and never
computes.

## `ShortcutHub`

```swift
@MainActor
protocol ShortcutHub: AnyObject {
    /// Everything the user pressed, as intents. The hub does not know
    /// what dictation is.
    var intents: AsyncStream<DictationIntent> { get }

    var installation: TapInstallation { get }

    func binding(for action: ShortcutAction) -> Shortcut?
    func setBinding(_ shortcut: Shortcut?, for action: ShortcutAction) throws(ShortcutError)
    func setActivationMode(_ mode: ActivationMode)

    /// Panel-scoped shortcuts (cancel, double-Escape) follow dictation state.
    func setPanelScopeActive(_ isActive: Bool)
}

enum ActivationMode: String, Sendable, Codable { case toggle, pushToTalk }

enum TapInstallation: Sendable, Equatable {
    case installed
    case notInstalled(noShortcutConfigured: Bool)
    case failed(reason: String)     // must be surfaced, not swallowed
}

enum ShortcutError: Error, Sendable, Equatable {
    case systemReserved, alreadyBound(to: ShortcutAction), modifiersRequired
}
```

**Dependency inversion.** Today `RecordingShortcutManager` holds
`weak var engine` and calls `engine.setPushToTalkRecording(isPressed:)`. The
hub instead emits values. Shortcuts become testable without an engine, and
toggle-versus-push-to-talk translation happens in exactly one place.

`TapInstallation` is exposed specifically because event-tap failure is
currently silent ([01, undefined behavior](01-behavior-contract.md)) — the app
looks alive while its main input is dead. Making it part of the interface
means `Presentation` can show it.

The two `ShortcutMonitor` instances (global, and panel-scoped) collapse behind
one owner, with panel scope driven by `setPanelScopeActive` from
`DictationState` rather than by a second manager holding its own UI reference.

**Effects:** installs a CGEventTap; requires Accessibility.
**Isolation:** `@MainActor`; the tap callback hops in.

## `Presentation`

Not a protocol — it is the SwiftUI/AppKit layer. Its *contract* is a
restriction:

- **Consumes** `DictationState`, `TranscriberAvailability`, `TapInstallation`,
  `SinkReadiness`, and the preference store.
- **Emits** `DictationIntent` and preference writes.
- **May not** call any capability module directly, hold a reference to
  `DictationController` beyond `handle(_:)`, or re-derive state it was given.

The permission `NSAlert`s move here. Today `VoiceInkEngine` runs a **blocking
modal** from inside the core loop. Instead the core reports
`.microphonePermissionMissing` as state, and the UI decides what to put on
screen — which also means the core stops importing AppKit.

## `Preferences`

```swift
struct PreferenceKey<Value: Sendable>: Sendable {
    let name: String
    let defaultValue: Value
}

enum Prefs {
    static let soundFeedback   = PreferenceKey(name: "IsSoundFeedbackEnabled", defaultValue: true)
    static let liveTranscript  = PreferenceKey(name: "ShowLiveTranscript",     defaultValue: false)
    static let idleUnloadMins  = PreferenceKey(name: "UnloadModelAfterIdleMinutes", defaultValue: 0)
    // ...one line per setting, and only here
}

@MainActor @Observable
final class PreferenceStore {
    var capture: CaptureSettings
    var transcription: TranscriptionSettings
    var shaping: ShapingRules
    var insertion: InsertionSettings
    var presentation: PresentationSettings
    var diagnostics: DiagnosticsSettings
}
```

Name, type, and default are declared **once**, and `registerDefaults()` is
derived from the same list rather than maintained beside it. Today that
knowledge is spread across `AppDefaults`, `UserDefaults.Keys`, bare string
literals in `VoiceInkEngine`, `@AppStorage` in views, and two private key
constants — which is how four keys ended up registered and never read.

Modules receive their slice, not the store. `Transcriber` gets
`TranscriptionSettings` and structurally cannot read the panel position.

**DECIDE:** views currently bind with `@AppStorage`, which is convenient and
reads `UserDefaults` directly, violating the single-source rule. Either accept
`@AppStorage` as the sanctioned exception for Presentation only, or bind views
to `@Observable` store properties. Recommendation: the store, so settings can
be observed by non-UI code and eventually migrated off `UserDefaults`.

## `Diagnostics` and `TranscriptHistory`

```swift
protocol Diagnostics: Sendable {
    func log(_ event: DiagnosticEvent)
    func interval(_ name: StaticString) -> SignpostInterval
    /// Optional capture observer; inert unless debug retention is on.
    func retain(_ audio: PCMAudio, for id: DictationID) async
}

protocol TranscriptHistory: Sendable {
    func record(_ text: String, at date: Date) async
    func mostRecent() async -> String?
}
```

Both are injected, both are no-op-able, and both are trivially faked in tests —
which matters because `Dictation` currently calls `TranscriptionLog.append`
statically, so nothing downstream of it can be tested without writing a file.

## Effects at a glance

| Module | Disk | Network | UI | Hardware | Global state |
|---|---|---|---|---|---|
| `Dictation` | — | — | — | — | — |
| `AudioCapture` | — | — | TCC prompt | microphone | — |
| `Transcriber` | model cache | first download | — | ANE/GPU | — |
| `TextShaping` | — | — | — | — | — |
| `TextSink` | — | — | — | synthetic keys | pasteboard |
| `ShortcutHub` | — | — | — | event tap | — |
| `Presentation` | — | — | all of it | — | — |
| `Preferences` | `UserDefaults` | — | — | — | — |
| `Diagnostics` | debug WAV, os_log | — | — | — | — |
| `TranscriptHistory` | JSONL | — | — | — | — |

The top row is the point: the module that orchestrates everything has no
effects of its own.

## Isolation at a glance

| Module | Isolation | Notes |
|---|---|---|
| `Dictation` | `@MainActor` | coordinates; never computes |
| `AudioCapture` | `actor` | AUHAL callback stays `nonisolated` real-time |
| `Transcriber` | `actor` | inference off the main actor |
| `TextShaping` | `nonisolated` | pure, `Sendable` |
| `TextSink` | `@MainActor` | CGEvent / `NSPasteboard` |
| `ShortcutHub` | `@MainActor` | tap callback hops in |
| `Presentation` | `@MainActor` | |
| `Preferences` | `@MainActor` | `@Observable` |
| `Diagnostics` | `nonisolated` | |
| `TranscriptHistory` | `actor` | serializes appends |

Under Swift 6 with `MainActor` default isolation
([05](05-macos-27-adoption.md)) most of this is what you get for free; the
actors and the `nonisolated` real-time path are the deliberate exceptions. The
two current `@unchecked Sendable` conformances (`CoreAudioRecorder`,
`RecordingSampleBuffer`) both live inside `AudioCapture`, so the unsafe surface
is contained to one module by construction.

## Composition

```swift
// AppComposition — the only file that knows all ten modules exist.
let prefs       = PreferenceStore()
let diagnostics = OSDiagnostics(settings: prefs.diagnostics)
let capture     = CoreAudioCapture(settings: prefs.capture, diagnostics: diagnostics)
let transcriber = makeTranscriber(prefs.transcription, diagnostics)   // ← the only backend decision
let shaper      = TextShaper(rules: prefs.shaping)
let sink        = PasteTextSink(settings: prefs.insertion)
let history     = JSONLTranscriptHistory(enabled: prefs.diagnostics.historyEnabled)

let dictation   = DictationEngine(
    capture: capture, transcriber: transcriber, shaper: shaper,
    sink: sink, history: history, diagnostics: diagnostics
)

let shortcuts   = CGEventShortcutHub(settings: prefs.capture.shortcuts)
Task { for await intent in shortcuts.intents { await dictation.handle(intent) } }
```

Every dependency is visible in one screen, with no singletons and no hidden
edges. `makeTranscriber` is the single place backend selection happens —
compare against threading `any TranscriptionModel` through four signatures to
reach the same outcome.
