# 0. Re-onboarding: what this app is today

Written for someone returning after a month, and for an agent starting cold.
Everything here describes the code **as it exists on `jstar/lean-local`**, not
as it should be.

## The one-sentence version

A macOS menu-bar app that records your microphone while you hold or toggle a
global hotkey, transcribes the audio locally with an NVIDIA Parakeet model, and
pastes the resulting text into whatever app you were typing in.

Nothing leaves the machine. There is no account, no server, no database.

## Size and shape

- 55 Swift files, roughly 7,600 lines, in `VoiceInk/`.
- Two Swift package dependencies: **FluidAudio** and **swift-atomics**.
- One app target. Two test targets that contain only Xcode's generated stubs.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so **every
  `.swift` file under `VoiceInk/` is compiled automatically**. There is no
  "add to target" step, and no file can be orphaned by being left out of a
  build phase. Deleting a file from disk deletes it from the build.

## Glossary — the terms you will have forgotten

**FluidAudio** — a third-party open-source Swift package
([FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio),
Apache 2.0). It is the *only* reason this app can transcribe. It packages
NVIDIA's Parakeet speech-recognition models converted to Core ML, and gives you
a Swift API that downloads the model, loads it onto the Apple Neural Engine,
and turns 16 kHz mono float samples into text. It also does speaker
diarization and voice-activity detection, none of which this app uses. Pinned
in the project to revision `3c6e79f1d7441…` rather than a version tag.

The specific FluidAudio API surface this app touches is small: `AsrModels`
(download/cache/existence checks), `AsrManager` (load models, `transcribe`,
`cleanup`), `AsrModelVersion` (`.v2`), `TdtDecoderState`, and
`TextNormalizer`. That narrow usage is why swapping the backend later is
tractable.

**Parakeet** — the model family itself, from NVIDIA. `parakeet-tdt-0.6b-v2` is
English-only with the best English recall; `parakeet-tdt-0.6b-v3` covers 25
European languages with slightly weaker English on rare words. **This app is
pinned to v2.** ("TDT" is Token Duration Transducer, the architecture; 0.6b is
the parameter count.)

**AUHAL** — Audio Unit Hardware Abstraction Layer. The low-level Core Audio
API used to pull microphone samples directly, without `AVAudioEngine`. It is
why `CoreAudioRecorder.swift` is 1,200 lines. The payoff is that the app can
hold a *prepared but stopped* audio unit at idle with no timers running, and
start capture with minimal latency.

**SpeechAnalyzer / SpeechTranscriber** — Apple's own on-device speech
framework, new in macOS 26. The app contains a complete but **unreachable**
implementation of this path (see "Dead weight" below).

**CGEventTap** — the macOS mechanism for observing keyboard events system-wide.
It is how the global hotkey works, and it is why the app requires Accessibility
permission.

**TCC** — Transparency, Consent and Control. Apple's permission database. It
keys grants partly on code signature, which is why the Makefile signs local
builds with a stable self-signed `VoiceInk Local` identity: without it, every
rebuild would look like a new app and you would re-grant microphone and
accessibility permission every time.

**Signposts** — `os_signpost` intervals emitted under subsystem
`com.prakashjoshipax.VoiceInk`, category `leanpath`, for `record`,
`transcribe`, and `paste`. Open Instruments and you can see where time goes.

**The lean strip** — the seven commits on this branch that removed Whisper,
cloud transcription, AI enhancement, per-app modes, the dashboard, history
database, licensing, the updater, and most onboarding from upstream VoiceInk.
Recorded in [`LEAN-SPEC.md`](../LEAN-SPEC.md).

**Felt gaps** — the discipline recorded in [`FELT-GAPS.md`](../FELT-GAPS.md):
nothing that was cut comes back until it is actually missed in daily use. Four
things have been restored so far (live transcript, panel position, a JSONL
history log, and the word-replacement editor).

## The core loop, end to end

Press hotkey → text appears in the frontmost app. Here is the actual path.

```
CGEventTap (main run loop)
  └─ ShortcutMonitor              matches the key combo
     └─ RecordingShortcutManager  toggle vs push-to-talk semantics
        └─ RecorderUIManager      plays start sound, shows the floating panel
           └─ VoiceInkEngine      the state machine
              ├─ PermissionAlert  mic + accessibility gate (blocking NSAlert)
              ├─ Recorder ──────► CoreAudioRecorder ──► AUHAL callback
              │                       │                   (real-time thread)
              │                       ├─ resample to 16 kHz mono
              │                       ├─ write WAV to disk
              │                       └─ push chunk to RecordingSampleBuffer
              │
              │  ── second hotkey press ──
              │
              └─ TranscriptionPipeline
                 ├─ TranscriptionServiceRegistry
                 │     └─ FluidAudioTranscriptionService ──► Parakeet v2 / ANE
                 ├─ TranscriptionOutputFilter    strips tags, brackets, fillers
                 ├─ WordReplacementService       user-defined substitutions
                 ├─ TranscriptionDelivery
                 │     ├─ stop sound
                 │     ├─ dismiss the panel
                 │     └─ CursorPaster ─► clipboard + synthetic ⌘V
                 └─ TranscriptionLog             appends one JSONL line
```

Everything in that chain except the audio internals and the ASR call runs on
`@MainActor`.

### Where the threads actually are

| Work | Where it runs |
|---|---|
| Hotkey event tap callback | main run loop, then hops to `DispatchQueue.main` |
| Orchestration, state, UI | `@MainActor` |
| AUHAL render callback | real-time audio thread |
| Resample / WAV write | `audioProcessingQueue`, `.userInitiated` |
| Level metering | `DispatchSourceTimer` on `audioMeterQueue` at 17 ms, **only while recording** |
| Parakeet inference | cooperative pool (`FluidAudioTranscriptionService` is not actor-isolated) |
| WAV deletion, history log | `DispatchQueue.global(qos: .utility)` |

### The idle-cost invariant

At rest the app is meant to be structurally free: one CGEventTap, one prepared
but stopped audio unit, one `MenuBarExtra`, and **zero timers, zero network,
zero polling**. This is the property most worth protecting through any
restructuring — it is the reason the app can sit in the menu bar all day.
The 17 ms meter timer exists only between start and stop of a recording.

## Where things live

| Directory | Contains |
|---|---|
| `VoiceInk/` root | `VoiceInk.swift` (composition root), `AppDelegate`, `AppDefaults`, `Recorder`, `CoreAudioRecorder`, `StartStopSound` |
| `Models/` | `TranscriptionModel` protocol, `ModelProvider` enum, the two-entry registry |
| `Notifications/` | Toast panel + the `NotificationManager` singleton |
| `Paste/` | `CursorPaster`, `ClipboardManager`, `PasteMethod` |
| `Services/` | `AudioDeviceManager` (575 lines), `TranscriptionLog`, plus several unused preference types |
| `Shortcuts/` | Event tap, shortcut model, store, validator, recorder UI, two shortcut managers |
| `Transcription/Engine/` | `VoiceInkEngine`, pipeline, delivery, service protocol + registry, sample buffer, `RecorderUIManager` |
| `Transcription/FluidAudio/` | The two files that touch FluidAudio |
| `Transcription/Native/` | The unreachable Apple SpeechAnalyzer path |
| `Transcription/Processing/` | Output filter, filler words, word replacements, an unused paragraph formatter |
| `Views/` | Menu bar, settings, the floating recorder panel, shared UI bits |

## Settings, and where they are stored

All preferences are `UserDefaults`. There is no settings file and no database.

| Setting | Key | Default | Read by |
|---|---|---|---|
| Sound feedback | `IsSoundFeedbackEnabled` | on | `StartStopSound` |
| Live transcript | `ShowLiveTranscript` | off | engine + panel |
| Panel position | `RecorderPanelPosition` | bottom-center | panel |
| Word replacement on/off | `IsWordReplacementEnabled` | off | `WordReplacementService` |
| Word replacement pairs | `WordReplacements` | `{}` | `WordReplacementService` |
| Filler words | `FillerWords` | 12 defaults (`uh`, `um`, …) | output filter |
| History log | `EnableHistoryLog` | on | `TranscriptionLog` |
| Idle model unload | `UnloadModelAfterIdleMinutes` | `0` (never) | engine |
| Keep WAV files | `DebugKeepRecordings` | off | engine |
| Clipboard restore | `restoreClipboardAfterPaste` | off | `CursorPaster` |
| Paste method | `pasteMethod` | standard (⌘V) | `CursorPaster` — **no UI** |
| Hotkey + mode | `primaryRecordingShortcut`, `…Mode`, `Shortcut_*` | none | shortcut managers |
| Input device | `audioInputMode`, `selectedAudioDeviceUID`, … | system default | `AudioDeviceManager` |

Four keys are registered as defaults and never read by anything:
`SelectedLanguage`, `AppendTrailingSpace`, `RecorderType`, `IsMenuBarOnly`.

## Where files are written

```
~/Library/Application Support/com.prakashjoshipax.VoiceInk/
├── Recordings/<uuid>.wav        every recording; deleted right after
│                                transcription unless DebugKeepRecordings
└── transcriptions.jsonl         one {"ts":…,"text":…} line per dictation
```

Plus FluidAudio's own model cache, in a directory FluidAudio chooses.

## Dead weight you will trip over

These exist in the build but nothing reaches them. Knowing this up front saves
an hour of confused reading.

- **The entire Apple SpeechAnalyzer path.** `NativeAppleTranscriptionService`
  and `NativeAppleSpeechAssetManager` are fully written, compiled behind the
  `ENABLE_NATIVE_SPEECH_ANALYZER` flag, and gated on `macOS 26`. They are
  unreachable at runtime because `VoiceInkEngine` hardcodes
  `let model: FluidAudioModel = TranscriptionModelRegistry.parakeetV2`. The
  registry's dispatch-by-provider machinery therefore has exactly one live
  branch.
- **`RecordingState.enhancing` and `.busy`** are never assigned, but are
  handled in three separate switch statements.
- **`AppAppearancePreference`, `AppLanguagePreference`, `ParagraphFormatter`,
  `VoiceInkEngineError`, `AudioDeviceConfiguration`** — whole files with no
  call sites.
- **`Notification.Name.dismissRecorderPanel`** has an observer and no poster.
- **15 `provider-*` image assets** (OpenAI, Anthropic, Deepgram, …) left from
  the cloud-provider UI that was cut. The app draws SF Symbols only.
- **`FluidAudioModelManager.downloadFluidAudioModel`** has no caller — the
  model is downloaded implicitly on the first transcription instead, inside
  `FluidAudioTranscriptionService`.
- **`Scripts/quic-vpn-repro.swift`** is unrelated to this app.

## Documentation that is currently wrong

- **`BUILDING.md`** tells you to build `whisper.cpp` and run `make whisper` /
  `make setup`. Whisper was removed and those targets no longer exist. It also
  omits `make install` and `make archive-stock`, which do. *(Fixed in this PR
  — it was actively misleading both humans and agents.)*
- **`README.md`** describes upstream VoiceInk: modes, AI assistant, context
  awareness, personal dictionary, licensing, Sparkle, KeyboardShortcuts, Zip,
  SelectedTextKit. None of that is in this fork.
- **`.github/PULL_REQUEST_TEMPLATE.md`** is upstream's "this project does not
  accept pull requests — please close this PR", which auto-populates every PR
  opened on the fork. *(Fixed in this PR.)*

## How to build it

```bash
make local      # Release build, self-signed, lands in ~/Downloads
make install    # same, then installs to /Applications and launches
```

`make build` produces an unsigned Debug build, which is fine for compiling but
will lose TCC permission grants. Use `make local` for anything you intend to
actually run. See [`BUILDING.md`](../BUILDING.md).

## What to read next

[01 — Behavior contract](01-behavior-contract.md), which turns the above into
statements that can be checked, so "don't change behavior" stops being a
feeling.
