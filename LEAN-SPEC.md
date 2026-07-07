# VoiceInk Lean Fork — Target Spec

Personal fork (Allmight97/VoiceInk, branch `jstar/lean-local`). One job:
**global hotkey → record mic → local Parakeet v2 transcription → paste into the
frontmost app.** Idle cost must be structural zero: no timers, no network, one
CGEventTap, no persistent stores. Every optional feature ships OFF.

## Survives (KEEP)

| Area | Files | Notes |
|---|---|---|
| App root | `VoiceInk/VoiceInk.swift` | REWRITTEN ~100–150 lines: MenuBarExtra + wiring only |
| Audio capture | `CoreAudioRecorder.swift`, `Recorder.swift`, `Services/AudioDeviceManager.swift`, `Services/AudioDeviceConfiguration.swift` | Strip MediaController/PlaybackController/system-mute + NotificationManager calls from Recorder |
| Engine | `Transcription/Engine/` slimmed: `VoiceInkEngine`, `TranscriptionPipeline`, `TranscriptionDelivery`, `TranscriptionService`, `TranscriptionServiceRegistry`, `RecorderUIManager` (reduced), `TranscriptionSession` DELETED (streaming-only) | Pipeline = transcribe → OutputFilter → WordReplacement → deliver. No SwiftData, no modes, no enhancement, no license text, no auto-send, no shell output, no osascript window resolution |
| Engine impl | `Transcription/FluidAudio/FluidAudioTranscriptionService.swift`, `FluidAudioModelManager.swift` (v2-only slim) | Batch only. Delete Unified/Nemotron/streaming paths |
| Native A/B | `Transcription/Native/` (both files) | Kept behind `ENABLE_NATIVE_SPEECH_ANALYZER` + macOS 26 gate |
| Text processing | `Transcription/Processing/TranscriptionOutputFilter.swift`, `FillerWordManager.swift`, word replacement service | Cheap regex, keeps dictation clean |
| Paste | `Paste/CursorPaster.swift`, `ClipboardManager.swift`, `PasteMethod.swift`, slimmed `TranscriptionDelivery.swift` | Paste-only delivery |
| Hotkeys | `Shortcuts/ShortcutMonitor.swift`, `Shortcut.swift`, `ShortcutStore.swift`, `ShortcutRecorder.swift` (settings capture UI), `RecordingShortcutManager.swift` REDUCED | One tap; toggle + push-to-talk for ONE primary shortcut. Delete mode shortcuts, middle-click, paste-last/history/dictionary shortcuts, migrations |
| Models meta | `Models/TranscriptionModel.swift` + `TranscriptionModelRegistry.swift` slimmed to Parakeet v2 + native-apple entries | |
| UI | Minimal: menu bar menu (status, model state, start/stop, settings, quit), small Settings window (shortcut recorder, input device, filler words editor, launch-at-login SMAppService toggle, paste method), recorder indicator panel (existing mini recorder visual if cheap to keep, else NSPanel dot) | No dashboard/history/stats/onboarding/AI views |
| Sounds | Single start/stop beep via NSSound (system sound), setting default ON (it is core-loop feedback) | Delete SoundManager/CustomSoundManager/SoundPlaybackEngine if replaceable in <20 lines |

Dependencies kept: **FluidAudio (pin exact revision 3c6e79f)**, **swift-atomics**. Nothing else.

## Deleted (CUT) — directories/files

- `Views/` everything except the minimal surface above (Dashboard, History, Stats, Onboarding, AI Models UI, Power Mode UI, Markdown views, confetti, whisper model mgmt UI)
- `Modes/` entirely; `Services/AIEnhancement/` + `OllamaService.swift`; `Services/RecordingContextSnapshot.swift`, `SelectedTextService.swift`, `ScreenCaptureService.swift`; `Modes/ActiveWindowService.swift`, `BrowserURLService.swift`
- License/paywall: `Services/LicenseManager.swift`, `Models/LicenseViewModel.swift`, `Services/PolarService.swift` (+ all `LicenseViewModel()` call sites). Keychain helpers deleted if only used by license/AI keys
- Updater/announcements/support: Sparkle wiring (`UpdaterViewModel`), `Services/AnnouncementsService.swift`, `Notifications/Announcement*`, `EmailSupport.swift`; remove SUFeedURL/SUEnableAutomaticChecks/SUPublicEDKey/SUEnableInstallerLauncherService from Info.plist
- `Services/ModelPrewarmService.swift`
- `Transcription/Cloud/`, `Transcription/Streaming/`, `Transcription/Whisper/` (all), `VADModelManager`
- SwiftData: `Models/Transcription.swift`, `SessionMetric*`, `VocabularyWord`, dictionary/vocabulary services, migrations, `TranscriptionAutoCleanupService`, `AudioCleanupManager`; ModelContainer creation. WordReplacement: keep the replacement ALGORITHM on UserDefaults storage (drop its SwiftData model) — if that exceeds ~50 lines of rework, keep replacements out and note in backlog
- `AppIntents/`; `MediaController.swift`, `PlaybackController.swift`, `SoundManager.swift`, `SoundPlaybackEngine.swift`, `CustomSoundManager.swift`, `Resources/Sounds/` custom packs; `HistoryWindowController.swift`, `WindowManager.swift` (if only main-window mgmt)

## pbxproj edits

- Remove whisper.xcframework: PBXBuildFile lines (Frameworks + Embed Frameworks), PBXFileReference entries, membership in Frameworks/Embed phases and groups
- Remove XCRemoteSwiftPackageReference + XCSwiftPackageProductDependency + PBXBuildFile for: Sparkle, LLMkit, SelectedTextKit, swift-markdown-ui, Zip, LaunchAtLogin-Modern, mediaremote-adapter
- FluidAudio: change requirement from branch `main` to revision `3c6e79f1d74411cae1f3daf50260dd19a585dc2d`
- Validate with `plutil -lint VoiceInk.xcodeproj/project.pbxproj` after every edit

## Behavioral invariants

1. Idle = exactly one CGEventTap + prepared-but-stopped AUHAL + MenuBarExtra. Zero Timer/DispatchSourceTimer/network at idle. (17 ms level-meter timer allowed DURING recording only.)
2. Parakeet v2 loads on first dictation, stays resident; `UnloadModelAfterIdleMinutes` (default 0 = never) is the only residency knob.
3. Audio: recorder passes Float samples in memory to the engine. WAV written ONLY when `DebugKeepRecordings` default is true (default false). QoS: transcription `.userInitiated`; all housekeeping `.utility`.
4. `os_signpost` intervals: record, transcribe, paste (subsystem `com.prakashjoshipax.VoiceInk`, category `leanpath`).
5. Bundle ID stays `com.prakashjoshipax.VoiceInk`. Entitlements: `VoiceInk.local.entitlements` unchanged.
6. Defaults: everything optional OFF (launch-at-login off, sounds on as core feedback, debug recordings off). Remove dead default keys from `AppDefaults.swift`.
7. `make local` must produce a working app WITHOUT `~/VoiceInk-Dependencies` (whisper dep removed from Makefile `setup` chain).

## Non-goals (backlog, do NOT build now)

JSONL history log, SpeechAnalyzer default-on, VAD trimming, multi-shortcut support, DMG/release pipeline.
