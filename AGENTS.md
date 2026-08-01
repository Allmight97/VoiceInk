# Working in this repository

Orientation for coding agents and for humans returning to the project. Read
this before making changes.

## What this is

A macOS menu-bar dictation app. Global hotkey → record the microphone →
transcribe locally with NVIDIA Parakeet via FluidAudio → paste into the
frontmost app. Fully offline, no account, no database.

It is a **personal fork** of upstream VoiceInk that has diverged substantially
and will diverge further. Upstream's structure and feature set are history, not
constraints. Do not restore upstream behavior because upstream had it.

Swift, SwiftUI + AppKit, one app target, 55 files, ~7,600 lines, two package
dependencies.

## Read before changing anything

| If you're doing this | Read |
|---|---|
| Anything at all, first time | [`docs/00-reonboarding.md`](docs/00-reonboarding.md) |
| Changing runtime behavior | [`docs/01-behavior-contract.md`](docs/01-behavior-contract.md) |
| Moving code between files | [`docs/02-module-map.md`](docs/02-module-map.md), [`docs/03-api-seams.md`](docs/03-api-seams.md) |
| Deleting something | [`docs/04-tidy-up-inventory.md`](docs/04-tidy-up-inventory.md) |
| Touching build settings or platform APIs | [`docs/05-macos-27-adoption.md`](docs/05-macos-27-adoption.md) |
| Wondering what order to work in | [`docs/07-sequencing.md`](docs/07-sequencing.md) |
| Unsure whether something is decided | [`docs/08-open-decisions.md`](docs/08-open-decisions.md) |

## Hard rules

1. **No new features.** The project is mid-reorganization. Wants go in
   [`FELT-GAPS.md`](FELT-GAPS.md), not into code.
2. **No silent behavior change.** [`docs/01`](docs/01-behavior-contract.md)
   lists what is contractual. Changing a `[C]` statement requires saying so
   explicitly in the commit message and citing the decision that authorized it.
3. **Protect the idle-cost invariant.** At rest: one CGEventTap, one prepared
   audio unit, the menu bar item. **Zero timers, zero polling, zero network.**
   Adding a `Timer`, a `DispatchSourceTimer`, or a background poll to the idle
   path breaks the app's central property. If you think you need one, you
   probably need an event instead.
4. **Everything local.** No network in the dictation path, ever. The one
   exception is the initial model download.
5. **One file imports FluidAudio.** Today that is
   `FluidAudioTranscriptionService.swift`. Keep it that way — it is what makes
   the backend swappable.
6. **Don't add a dependency** without a strong argument. There are two. The
   goal is fewer.
7. **Don't guess about macOS 27.** Nothing in `docs/05` has been compiled
   against the 27 SDK. Items marked **VERIFY** are hypotheses.

## Build and verify

```bash
make local      # Release, self-signed, → ~/Downloads/VoiceInk.app
make install    # → /Applications, and launch
make build      # Debug, unsigned; compiles but may not launch
```

Use `make local` for anything you intend to run — Debug builds lose TCC
permission grants and can be rejected at launch. See
[`BUILDING.md`](BUILDING.md).

**There is no meaningful automated test coverage.** `VoiceInkTests/` and
`VoiceInkUITests/` contain Xcode's generated stubs. A change that compiles is
not a change that works. If you touch the core loop, run the smoke script in
[`docs/07-sequencing.md`](docs/07-sequencing.md#the-smoke-script).

## Repo facts that will trip you up

- **The Xcode project uses `PBXFileSystemSynchronizedRootGroup`.** Every
  `.swift` file under `VoiceInk/` compiles automatically. There is no
  "add to target" step, and no file can be orphaned. Creating a file adds it to
  the build; deleting it removes it. Do not hand-edit `project.pbxproj` to add
  sources.
- **`README.md` describes upstream, not this fork.** Modes, AI assistant,
  context awareness, licensing, Sparkle, Zip, SelectedTextKit — none of that
  exists here. Do not treat it as a source of truth. (Pending
  [D19](docs/08-open-decisions.md).)
- **There is a lot of unreachable code.** The whole
  `Transcription/Native/` SpeechAnalyzer path, `ParagraphFormatter`,
  `AppAppearancePreference`, `AppLanguagePreference`, `VoiceInkEngineError`,
  `AudioDeviceConfiguration`, `RecordingState.enhancing` and `.busy`. Full list
  with evidence in [`docs/04`](docs/04-tidy-up-inventory.md). **Do not "fix" or
  extend dead code** — check whether it has a caller first.
- **Zero image assets are used.** The UI is entirely SF Symbols. The 18
  imagesets in `Assets.xcassets` are fossils.
- **The bundle ID is `com.prakashjoshipax.VoiceInk`** and it is baked into the
  Application Support path, the log subsystem, and every TCC grant. Do not
  change it casually ([D4](docs/08-open-decisions.md)).

## Conventions

- **Logging:** `Logger(subsystem: "com.prakashjoshipax.voiceink", category: …)`.
  Use `privacy: .public` for non-sensitive values. **Never log transcribed
  text.**
- **Signposts:** `record`, `transcribe`, `paste` under subsystem
  `com.prakashjoshipax.VoiceInk`, category `leanpath`. Keep them working — they
  are the only performance visibility the project has.
- **Preferences:** `UserDefaults`, keys in `AppDefaults.swift`. Prefer adding
  to that file over a bare string literal — the existing literals are a known
  problem being consolidated ([Wave 2](docs/07-sequencing.md#wave-2--preferences)).
- **Concurrency:** Swift 5 mode, no strict concurrency yet. UI and
  orchestration are `@MainActor`; audio uses dedicated queues. Do not
  block the main actor with inference or file I/O.
- **Comments** explain constraints the code can't show. Not what the next line
  does, not where the change came from, not why it is correct.
- **Commits:** one logical change each. If a commit changes behavior, the
  message says so on its own line.

## Where things are

```
VoiceInk/
├── VoiceInk.swift              @main, composition root, permission alerts
├── CoreAudioRecorder.swift     1,200 lines of AUHAL — the deepest file
├── Recorder.swift              @MainActor façade over the above
├── AppDefaults.swift           UserDefaults keys and defaults
├── Models/                     model metadata + registry (one live entry)
├── Notifications/              toast panel + NotificationManager singleton
├── Paste/                      CursorPaster, ClipboardManager, PasteMethod
├── Services/                   AudioDeviceManager (575 lines), TranscriptionLog
├── Shortcuts/                  event tap, shortcut model, store, validator, UI
├── Transcription/
│   ├── Engine/                 VoiceInkEngine (state machine), pipeline,
│   │                           delivery, service protocol, sample buffer
│   ├── FluidAudio/             the only files that import FluidAudio
│   ├── Native/                 unreachable SpeechAnalyzer path
│   └── Processing/             output filter, filler words, replacements
└── Views/                      menu bar, settings, floating recorder panel
```

The core loop, traced end to end with threads and queues, is in
[`docs/00-reonboarding.md`](docs/00-reonboarding.md#the-core-loop-end-to-end).

## If you are unsure

Prefer asking over guessing, and prefer a smaller change over a clever one.
The reorganization has a deliberate order
([`docs/07`](docs/07-sequencing.md)); work that jumps ahead of it usually has
to be redone.
