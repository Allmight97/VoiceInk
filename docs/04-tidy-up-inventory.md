# 4. Tidy-up inventory

Every file on `jstar/lean-local`, classified. This is the answer to "what else
needs tidying up in support of the reorganization."

| | Meaning |
|---|---|
| **RETAIN** | Move as-is into its new module. Logic is fine. |
| **RESHAPE** | Logic is fine, interface is not. Same behavior, new seam. |
| **REPLACE** | Rewrite against a modern API or a corrected design. |
| **DELETE** | No call sites, or absorbed by a boundary that makes it unnecessary. |

Every DELETE below was verified by grep, and the evidence is stated. None are
guesses.

## The headline

**Six files, ~314 lines, are verified unreachable today** — five in `VoiceInk/`
plus one stray script. Deleting them changes no behavior, requires no
decisions, and depends on nothing. Add the 11 dead-state sites, the 18 unused
imagesets, and the stale repo furniture, and that is the cheapest possible
first commit.

A further ~190 lines across six types (`TranscriptionPipeline`,
`TranscriptionDelivery`, `TranscriptionServiceRegistry`, `TranscriptionModel`,
`TranscriptionModelRegistry`, `RecorderStateProvider`) disappear not because
they are unused, but because the boundary in [02](02-module-map.md) makes them
unnecessary. Those come out during the restructuring, not before it.

Everything else is RETAIN (mostly UI leaves and small value types), RESHAPE
(the bulk of the work — same logic, new seam), or REPLACE (concurrency,
resampling, composition, and the macOS 27 surfaces).

## DELETE — verified unreachable

| File | Lines | Evidence |
|---|---|---|
| `Services/AppAppearancePreference.swift` | 55 | only self-references; no reader, no UI |
| `Services/AppLanguagePreference.swift` | 69 | same; writes `AppleLanguages` from a method nothing calls |
| `Transcription/Processing/ParagraphFormatter.swift` | 123 | **exactly one** reference repo-wide: its own declaration |
| `Transcription/Engine/VoiceInkEngineError.swift` | 22 | declared, never thrown, never caught |
| `Services/AudioDeviceConfiguration.swift` | 45 | both members unreferenced; its observer factory is never called |
| `Scripts/quic-vpn-repro.swift` | — | unrelated to this app; not in any target |

Also delete, without removing their files:

| Item | Evidence |
|---|---|
| `RecordingState.enhancing`, `.busy` | never assigned anywhere; handled at **11 sites across 5 files** (`RecorderUIManager`, `VoiceInkEngine`, `MenuBarView`, `RecorderComponents` ×5, `RecordingState`) |
| `Notification.Name.dismissRecorderPanel` | observed in `RecorderUIManager:125`; **posted nowhere** |
| `UserDefaults.Keys.affiliatePromotionDismissed` | accessor only; the promotion UI was cut |
| `ShortcutStore.seedShortcut`, `.removeShortcutStorage` | declared, never called |
| `FluidAudioModelManager.downloadFluidAudioModel` | no caller — download happens implicitly inside the transcription service |
| `AppDefaults` keys `SelectedLanguage`, `AppendTrailingSpace`, `RecorderType`, `IsMenuBarOnly` | registered as defaults; **one reference each**, the registration itself |
| `MenuBarView`'s `modelManager` `@EnvironmentObject` | declared, unused in the body — and an unused `@EnvironmentObject` is a latent crash if the injection is ever dropped |

### Assets

**Zero image assets are referenced from Swift.** There is not a single
`Image("…")` or `NSImage(named:)` call in the codebase — the UI is entirely SF
Symbols. Delete 18 imagesets, keeping `AppIcon` and `AccentColor`:

```
provider-{anthropic,assemblyai,cartesia,cerebras,deepgram,elevenlabs,
          gemini,groq,mistral,openai,openrouter,soniox,speechmatics,xai}
momentum-hero-bg, nvidia-logo, menuBarIcon
```

The 14 `provider-*` logos are the visible fossil of the cloud-transcription UI
that was stripped. They also ship in the binary.

### Documentation and repo furniture

| File | Problem |
|---|---|
| `BUILDING.md` | Instructs you to clone and build `whisper.cpp`, run `make whisper` / `make setup`, and manage `~/VoiceInk-Dependencies`. Whisper is gone and **those targets no longer exist**. Omits `make install` and `make archive-stock`, which do. **Rewritten in this PR** — it was actively misleading agents. |
| `.github/PULL_REQUEST_TEMPLATE.md` | Upstream's "this project does not accept pull requests — please close this PR." It auto-populates every PR on this fork. **Replaced in this PR.** |
| `README.md` | Describes upstream: modes, AI assistant, context awareness, personal dictionary, licensing, and six dependencies that were removed. **DECIDE:** full rewrite is entangled with the naming question — see [02](02-module-map.md). This PR adds only a pointer to `docs/`. |
| `.github/ISSUE_TEMPLATE/` | Points at upstream's support channels. **DECIDE:** keep, retarget, or delete for a personal fork. |
| `appcast.xml`, `announcements.json` | Sparkle updater feed and the announcements service — both subsystems were deleted in the strip. DELETE. |
| `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` | Upstream community docs for a project that doesn't accept contributions. **DECIDE:** meaningless on a personal fork. |
| `VoiceInkTests/`, `VoiceInkUITests/` | Xcode's generated stubs, no real tests. RESHAPE into real per-module test targets — see [07](07-sequencing.md). |

## RESHAPE — right logic, wrong boundary

### Into `Dictation`

| File | Lines | What changes |
|---|---|---|
| `Transcription/Engine/VoiceInkEngine.swift` | 318 | Becomes the state machine and nothing else. Sheds: the `AppKit` import, the blocking `NSAlert` permission gate, WAV file lifecycle, `NotificationManager.shared` calls, three bare `UserDefaults` string literals, idle-unload scheduling (→ `Transcriber`), and the partial-transcript loop (→ streaming capability). Should land near 200 lines. |
| `Transcription/Engine/RecordingState.swift` | 10 | → `DictationPhase`, minus the two dead cases, plus `.delivering`. |
| `Transcription/Engine/TranscriptionPipeline.swift` | 48 | DELETE as a type; its five lines of sequencing move into `Dictation`. |
| `Transcription/Engine/TranscriptionDelivery.swift` | 16 | DELETE as a type; a pass-through over a sound, a window, and a paste. |

### Into `AudioCapture`

| File | Lines | What changes |
|---|---|---|
| `CoreAudioRecorder.swift` | 1,207 | The genuinely deep one. Keep the AUHAL work; see REPLACE for the resampler and the spin-wait. |
| `Recorder.swift` | 288 | The `onAudioChunk` closure, `@Published audioMeter`, and the 17 ms `DispatchSourceTimer` all collapse into one `CaptureSession` event stream. |
| `Services/AudioDeviceManager.swift` | 575 | Stops being a singleton. Its two NotificationCenter back-channels become internal calls or `CaptureEvent`s. |
| `Services/UserDefaultsManager.swift` | 36 | Device keys move into `Preferences`; the file goes away. |
| `Transcription/Engine/RecordingSampleBuffer.swift` | 132 | Becomes the session's internal buffer. `NSLock` → `Mutex` (see [05](05-macos-27-adoption.md)). `WAVEncoder` moves to `Diagnostics`. |

### Into `Transcriber`

| File | Lines | What changes |
|---|---|---|
| `Transcription/FluidAudio/FluidAudioTranscriptionService.swift` | 118 | Becomes the FluidAudio adapter — **the only file in the repo importing FluidAudio**. Absorbs residency and warm-up. |
| `Transcription/FluidAudio/FluidAudioModelManager.swift` | 160 | Merges into the adapter; download/existence checks are internal, surfaced only as `TranscriberAvailability`. |
| `Transcription/Engine/TranscriptionService.swift` | 27 | → `Transcriber`. The temp-WAV protocol-extension bridge disappears: `PCMAudio` is the contract, so no backend needs a file. |
| `Transcription/Engine/TranscriptionServiceRegistry.swift` | 46 | DELETE. Backend chosen once in composition. |
| `Models/TranscriptionModel.swift` | 50 | DELETE as public surface. Model identity is internal to the adapter. |
| `Models/TranscriptionModelRegistry.swift` | 27 | DELETE. |
| `Transcription/Native/NativeAppleTranscriptionService.swift` | 168 | See REPLACE — currently unreachable. |
| `Transcription/Native/NativeAppleSpeechAssetManager.swift` | 246 | See REPLACE. |

### Into `TextShaping`

| File | Lines | What changes |
|---|---|---|
| `Transcription/Processing/TranscriptionOutputFilter.swift` | 43 | Pure function taking `ShapingRules`; stops reaching `FillerWordManager.shared`. Bracket stripping becomes `BracketPolicy`. |
| `Transcription/Processing/FillerWordManager.swift` | 39 | Singleton → the `fillerWords` field of `ShapingRules`. |
| `Transcription/Processing/WordReplacementService.swift` | 71 | Singleton → a pure function; keeps the longest-key-first and Latin/CJK matching logic verbatim. |

### Into `TextSink`

| File | Lines | What changes |
|---|---|---|
| `Paste/CursorPaster.swift` | 216 | Static methods → an instance conforming to `TextSink`. Returns `InsertionOutcome` instead of logging failure. Timing constants become injected config. |
| `Paste/ClipboardManager.swift` | 46 | Internal to the sink. |
| `Paste/PasteMethod.swift` | 43 | → `InsertionSettings`. **DECIDE:** it has no Settings UI today; give it one or remove the option. |

### Into `ShortcutHub`

`Shortcut.swift` (435), `ShortcutMonitor.swift` (364), `ShortcutRecorder.swift`
(308), `ShortcutValidator.swift` (135), `ShortcutStore.swift` (93),
`ShortcutAction.swift` (51), `RecordingShortcutManager.swift` (134),
`RecorderPanelShortcutManager.swift` (130) — **1,650 lines, the second-largest
subsystem after audio.**

The internals are fine. Two things change at the seam: the hub emits
`DictationIntent` instead of holding `weak var engine`, and the two
`ShortcutMonitor` instances collapse behind one owner with panel scope driven
by `DictationState`. `TapInstallation` becomes observable so a failed tap stops
being silent.

### Into `Presentation`

`MenuBarView` (65), `SettingsView` (123), `LeanUIComponents` (115),
`FillerWordsSettingsView` (136), `WordReplacementsSettingsView` (74),
`MiniRecorderView` (59), `MiniRecorderPanel` (69), `MiniWindowManager` (59),
`AudioVisualizerView` (66), `RecorderComponents` (260),
`NotificationManager` (118), `AppNotificationView` (157),
`StartStopSound` (24).

Mostly RETAIN as views. The structural changes: `RecorderUIManager` (141)
loses its duplicated state switch and its `weak var engine`, becoming a window
lifecycle owner driven by `state.isActive`; `NotificationManager` stops being a
singleton; `PermissionAlert` moves here out of `VoiceInk.swift`.

### Into `Preferences` / `Diagnostics` / `TranscriptHistory`

| File | Lines | Notes |
|---|---|---|
| `AppDefaults.swift` | 60 | → typed `PreferenceKey` declarations; `registerDefaults()` derived rather than hand-maintained |
| `Services/TranscriptionLog.swift` | 64 | → `TranscriptHistory`, injected instead of static |
| `LeanSignpost` (in `RecordingSampleBuffer.swift`) | — | → `Diagnostics` |

## REPLACE — rewrite, don't move

| Target | Why |
|---|---|
| `CoreAudioRecorder`'s resampler | Hand-rolled linear interpolation. `AVAudioConverter` does proper sample-rate conversion without aliasing. Arguably an accuracy improvement, so treat as a behavior change and A/B it. |
| `CoreAudioRecorder.waitForRenderCallbacksToFinish` | A `Thread.sleep(0.001)` spin loop. Replace with a semaphore or continuation. |
| `RecordingSampleBuffer`'s `NSLock`, and `swift-atomics` | Both replaceable by the stdlib `Synchronization` module (`Mutex`, `Atomic`) on macOS 15+. **This removes one of the two remaining package dependencies.** See [05](05-macos-27-adoption.md). |
| `Transcription/Native/*` | 414 lines of fully-written, entirely unreachable `SpeechAnalyzer` code behind a compile flag and a `macOS 26` gate. Once the deployment floor rises ([05](05-macos-27-adoption.md)), delete the flag, the stubs, and every `#available`, and make it a real selectable backend — or delete it outright. Do not leave it in its current state. |
| `VoiceInk.swift` composition root | Rebuilt around the new graph; the `Task { @MainActor }` fired from `init()` and the post-init `engine.recorderUIManager = …` back-reference both disappear. |
| `AudioDeviceManager`'s property-listener teardown | `deinit` removes the listener with a pointer that cannot match what was added, so the listener leaks. Correctness fix. |
| `@unchecked Sendable` on `CoreAudioRecorder` and `RecordingSampleBuffer` | Under Swift 6 these must be justified or removed. Both are inside `AudioCapture`, so the unsafe surface stays contained. |
| Project build settings | Deployment target is inconsistent — project `15.0`, app target `14.4`. Swift 5, no strict concurrency. See [05](05-macos-27-adoption.md). |

## RETAIN

`AppDelegate.swift` (11), `Notifications/AppNotifications.swift` (7),
`RecorderStateProvider.swift` (8, then deleted with the coupling it exists to
serve), and the view leaves listed under Presentation. Small, correct, no
boundary problems.

## Ordered by value

If only some of this gets done, do it in this order.

1. **Delete the 6 dead files, 11 dead-state sites, and 18 unused imagesets.**
   No behavior change, no decisions required, and it makes everything after it
   easier to read. This is the first commit.
2. **Fix `BUILDING.md` and the PR template.** Wrong documentation actively
   misleads agents. *(Done in this PR.)*
3. **Extract `TextShaping` as a pure struct with tests.** Lowest risk, and it
   produces the first real regression net.
4. **Consolidate `Preferences`.** Unblocks everything else, because every other
   module currently reaches `UserDefaults` on its own.
5. **Break the `VoiceInkEngine` ↔ `RecorderUIManager` cycle.** The single
   highest-leverage structural change; deletes the duplicated state machine.
6. **Collapse `Pipeline` + `Delivery` + `Registry` into `Dictation`.** −110
   lines of indirection.
7. **`AudioCapture` session interface.** Largest, riskiest, most valuable.
8. **macOS 27 adoption.** [05](05-macos-27-adoption.md), after the boundaries
   exist — otherwise you are modernizing code you are about to move.
