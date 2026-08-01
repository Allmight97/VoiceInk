# 1. Behavior contract

"Restructure without changing behavior" is only enforceable if *behavior* is
written down. This document is that baseline: the observable contract of the
app as it exists on `jstar/lean-local`.

Three kinds of statement appear here:

- **`[C]` Contract** — deliberate, must survive the restructuring unchanged.
- **`[I]` Incidental** — true today, but nobody chose it. Free to change; say
  so explicitly when you do.
- **`[?]` Undefined** — the code does *something*, but there is no decision
  behind it. These need a product answer before "preserve behavior" means
  anything. Collected and prioritised at the end.

## Outcomes this app exists to deliver

Everything below serves these four. If a statement can't be traced to one of
them, it is probably incidental.

1. **Speak, and the words appear where you were typing.** No window switch, no
   copy-paste step, no cursor repositioning.
2. **Nothing leaves the machine.** No network in the dictation path, ever.
3. **It costs nothing to leave running.** Idle is structurally free, so the app
   can live in the menu bar permanently without being noticed.
4. **It is fast enough to be unremarkable.** The gap between releasing the key
   and seeing text should not break your train of thought.

## Activation

| | Statement |
|---|---|
| `[C]` | A single user-assigned global shortcut starts and stops dictation, from any app, without focus change. |
| `[C]` | The shortcut has two modes: **toggle** (press to start, press again to stop) and **push-to-talk** (hold to record, release to stop). Toggle is the default. |
| `[C]` | Exactly one dictation shortcut exists. No per-mode, per-app, or secondary hotkeys. |
| `[C]` | The menu bar menu can start and stop dictation, equivalently to the hotkey. |
| `[C]` | While the recorder panel is visible, a cancel shortcut discards the recording. If none is assigned, pressing Escape twice within 1.5 s cancels, and the first Escape shows a hint. |
| `[C]` | Pressing an unrelated key within 1 s of the dictation shortcut cancels the recording. This exists so that a hotkey fired mid-typing doesn't hijack the session. |
| `[I]` | With no shortcut assigned, the event tap is not installed and only the menu bar can start dictation. |
| `[I]` | The stop-dictation menu item is disabled during `starting` and `transcribing`. |

## Capture

| | Statement |
|---|---|
| `[C]` | Audio is captured from the microphone at the moment of activation with no perceptible warm-up. |
| `[C]` | The app **never changes the system's default input device.** |
| `[C]` | Input device selection has three modes: follow the system default, a specific pinned device, or an ordered priority list with fallback. |
| `[C]` | If the active input device disappears mid-recording, the app switches to the next available device and keeps recording rather than dropping the session. |
| `[C]` | Audio is normalised to 16 kHz mono before transcription. |
| `[I]` | Recordings longer than ~30 minutes overflow the in-memory buffer; the excess is dropped and a warning toast is shown. |
| `[I]` | Resampling is a hand-rolled linear interpolation rather than `AVAudioConverter`. |

## Feedback while recording

| | Statement |
|---|---|
| `[C]` | A floating panel appears on activation showing that recording is live, and disappears when the text is delivered. |
| `[C]` | The panel is non-activating: it never steals focus from the app you are typing into. |
| `[C]` | The panel shows a live audio level so you can tell the mic is actually hearing you. |
| `[C]` | Panel position is a setting: bottom-center or top-center. |
| `[C]` | A start sound and a stop sound play, on by default. They are core feedback, not decoration — they are how you know the hotkey registered without looking. |
| `[C]` | Live transcript is opt-in and **off** by default. When on, partial text appears in the panel while you speak. |
| `[I]` | The live transcript is produced by re-transcribing the *entire* buffer every 1.5 s, so cost grows with utterance length and earlier text can change retroactively. |
| `[I]` | The level meter publishes to the main actor every 17 ms while recording. |

## Transcription

| | Statement |
|---|---|
| `[C]` | Transcription is **fully local**. No audio and no text is sent anywhere. |
| `[C]` | The model loads on first use and stays resident, so the second and every later dictation is fast. |
| `[C]` | Model residency has exactly one knob: unload after N idle minutes, default `0` = never unload. At the default, no timer is ever scheduled. |
| `[C]` | If the model isn't on disk, it is downloaded on first dictation. This is the only network access in the app. |
| `[I]` | The model is hardcoded to Parakeet TDT v2 (English-only). No model picker exists. |
| `[I]` | The engine appends 1 s of trailing silence to clips under ~15 s, a workaround for the ASR's chunking. |
| `[I]` | Warm-up is kicked off when recording *starts*, not at launch, and only if the model is already downloaded. |

## Text shaping

Applied in this order to the raw ASR output:

| | Statement |
|---|---|
| `[C]` | `<TAG>…</TAG>` blocks are removed. |
| `[C]` | Configured filler words are removed, case-insensitively, on word boundaries, along with a trailing comma or period. Twelve defaults ship (`uh`, `um`, `hmm`, …) and the list is user-editable. |
| `[C]` | Runs of whitespace collapse to a single space; the result is trimmed. |
| `[C]` | User-defined word replacements are applied after filtering, off by default, longest key first, word-boundary matched for Latin scripts and substring-matched for scripts without word boundaries. |
| `[C]` | If the shaped text is empty, nothing is pasted, nothing is logged, and the panel simply dismisses. |
| `[?]` | **All bracketed content is deleted** — `[...]`, `(...)`, and `{...}`. Dictating a genuine parenthetical silently loses it. Inherited from a Whisper-era hallucination filter that Parakeet may not need. |

## Delivery

| | Statement |
|---|---|
| `[C]` | Text is inserted at the cursor in the frontmost app via the clipboard plus a synthetic ⌘V. |
| `[C]` | The panel is dismissed *before* the paste, so focus is settled when the keystroke lands. |
| `[C]` | An AppleScript paste path exists for keyboard layouts that remap ⌘V (layouts whose name ends in `⌘` use physical key code 9). |
| `[C]` | Clipboard restore is opt-in and off by default. When on, the previous clipboard is restored after a delay, but only if the pasteboard is still owned by this paste session. |
| `[I]` | Fixed timings: 100 ms before pasting, 10 ms between key events, ≥250 ms before clipboard restore. |
| `[I]` | The paste method has no Settings UI; it is reachable only by writing the `pasteMethod` default by hand. |
| `[?]` | **Paste failure is silent.** If Accessibility permission is missing at paste time, or the CGEvents can't be created, the app logs an error and shows the user nothing. The text is on the clipboard but the user has no idea. |

## History

| | Statement |
|---|---|
| `[C]` | Each delivered transcription appends one JSON line to `transcriptions.jsonl` in Application Support. On by default. |
| `[C]` | "Copy Last Transcription" in the menu re-copies the most recent entry. |
| `[C]` | There is no database, no history window, and no paste-last shortcut. |
| `[I]` | The log grows without bound. No rotation, no size cap, no pruning. |
| `[I]` | Turning the setting off stops writing but does not delete what's there. |

## Permissions and failure

| | Statement |
|---|---|
| `[C]` | Microphone and Accessibility are both checked before recording starts. If either is missing, an alert offers to open the relevant System Settings pane and recording does not begin. |
| `[C]` | Transcription failure plays the stop sound, shows an error toast, and dismisses the panel. Nothing is pasted. |
| `[C]` | Recording that fails to start shows a toast and returns to idle. |
| `[C]` | On launch, any leftover recording state is reset and the panel is hidden. |
| `[?]` | If the event tap fails to install, hotkeys silently stop working with no indication anywhere in the UI. |
| `[?]` | Model download failure surfaces as a generic "Transcription failed: …" toast — the same message as an inference error, with no distinction, no progress, and no retry. |

## Idle cost

This is the invariant most at risk during a restructuring, so it is stated
separately and should be measured, not assumed.

| | Statement |
|---|---|
| `[C]` | At idle the app runs **one** CGEventTap, **one** prepared-but-stopped audio unit, and the menu bar item. Nothing else. |
| `[C]` | Zero timers, zero polling, zero network at idle. The 17 ms meter timer exists only between start and stop. |
| `[C]` | No persistent store is opened. No `URLSession` is created (`URLCache` is explicitly zeroed at launch). |
| `[C]` | The app is `.accessory`: no Dock icon, no app menu, no main window. |

## Things that are true but were never decided

Ordered by how much they matter. Each needs a yes/no before "preserve current
behavior" is unambiguous.

1. **Silent paste failure.** The single most user-hostile behavior in the app:
   you speak, the panel dismisses, and nothing appears. Fixing it is a
   *behavior change*, which is why it needs an explicit call.
   **DECIDE:** should `TextSink` report failure to the user? Recommendation:
   yes, as a toast that says the text is on the clipboard.
2. **Parenthetical deletion.** `(...)` stripping is a Whisper-era artifact.
   **DECIDE:** keep, restrict to bracket types Parakeet actually emits, or
   drop? Recommendation: keep `[...]` only, pending observation.
3. **Panel close button during recording.** The X calls
   `dismissRecorderPanel()`, which hides the panel *without stopping the
   recording or the engine*. The audio unit keeps running with no visible UI.
   **DECIDE:** X should cancel. This looks like a bug, not a feature.
4. **Model download has no first-run experience.** The first dictation on a new
   machine silently downloads several hundred MB before producing any text,
   with no progress and no explanation. There is even a
   `downloadFluidAudioModel` method with progress reporting — it just has no
   caller. **DECIDE:** is silent-first-run acceptable, or does the model state
   belong in the menu (which already shows "Loaded/Unloaded")?
5. **`.enhancing` and `.busy` states.** Never assigned, handled in three
   switches. **DECIDE:** delete. (No behavior change; they are unreachable.)
6. **Unbounded history log.** **DECIDE:** cap by lines or by age, or leave it.
7. **30-minute buffer ceiling.** A deliberate memory bound, or a number nobody
   revisited? **DECIDE:** confirm the number, then document it as a contract.

## Frustrations to fill in

You mentioned minor frustrations with the current build. Reading the code, here
is where friction most plausibly lives — treat this as a checklist to confirm
or correct, not as findings:

- **Cold start on the first dictation of a session** if idle unload is enabled,
  or if the app was just launched and the model hasn't been warmed.
- **Live transcript feels laggy or rewrites itself**, because it re-transcribes
  the whole buffer on a 1.5 s loop rather than streaming.
- **Filler-word stripping is too aggressive or not aggressive enough**, and the
  only control is a flat word list with no context.
- **No sentence casing or punctuation policy** — you get exactly what the model
  emits.
- **Dictation into a slow or Electron app loses characters**, because the paste
  timing constants are fixed rather than adaptive.
- **No way to know the app is broken** — event-tap failure and paste failure
  are both silent.

**DECIDE:** which of these are real for you, and are there others? Every one
that is real should become a `[C]` statement here or an entry in
[`FELT-GAPS.md`](../FELT-GAPS.md) before feature work resumes.

## How this contract gets enforced

Prose alone will drift. The behavior-preservation gate proposed in
[07 — Sequencing](07-sequencing.md) is:

- **Unit tests** for everything pure — text shaping, shortcut matching,
  WAV encoding, settings defaults and migration. These can be written
  *before* any code moves and must pass unchanged after.
- **Contract tests** against each module protocol using fakes, so the state
  machine is verified without a microphone.
- **One manual smoke script** for the parts no test can reach: hotkey in both
  modes, cancel, device switch mid-recording, permission denial, paste into a
  real app.
- **A measured idle baseline** — CPU samples and a timer count — recorded
  before the restructuring starts and compared after.
