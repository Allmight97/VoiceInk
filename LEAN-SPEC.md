# Lean-local product contract

VoiceInk has one job: a global shortcut controls microphone capture, local
Parakeet v2 transcription turns the recording into text, and the shaped result
is pasted into the frontmost app.

GitHub issue #3 owns migration order and implementation state. This file owns
only the product behavior that work on that roadmap must preserve.

## Retained behavior

- One configurable shortcut supports toggle and push-to-talk recording.
- Recording uses the selected input device and publishes a live audio meter.
- The recorder panel supports top-center and bottom-center placement.
- Live transcription is opt-in and performs work only while recording.
- Parakeet v2 acquisition is an explicit Settings action. Recording is blocked
  until the local model exists and while it is downloading. FluidAudio network
  access is disabled outside that action; dictation never initiates a download.
- Final transcription runs locally through Parakeet v2.
- Filler-word filtering and user-defined text replacements shape final output.
- Text is pasted into the frontmost app. Clipboard restoration remains an
  explicit setting rather than an assumed behavior.
- Optional append-only JSONL history supports Copy Last Transcription without a
  database or history browser.
- Sound feedback, launch at login, model residency, and retained debug
  recordings remain explicit settings.
- Microphone and accessibility failures produce user-visible recovery paths.

## Operating invariants

- No cloud transcription, account, or network dependency belongs in the
  dictation path.
- Idle work has no timer, network request, or recurring persistence task.
- Optional behavior performs no work while disabled.
- Audio samples remain in memory for transcription unless retained debug
  recording is enabled.
- A feature, abstraction, service, or package remains only while it supports a
  retained behavior or a proof seam required by the active roadmap.

## Excluded until a new product decision

- Multiple transcription backends or model-selection UI.
- AI enhancement, per-app modes, context capture, cloud providers, or accounts.
- Multiple shortcuts, audio-file transcription, updater, licensing, paywall,
  analytics, dashboard, history database/browser, or upstream-sync machinery.
- Intel or pre-macOS 27 compatibility.

Any change to retained behavior must update this contract and include an
automated test or focused macOS runtime receipt that proves the new outcome.
