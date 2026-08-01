# 6. Multiplatform as a boundary constraint

An iOS version is not on the roadmap for this work. But the *question* is
useful right now, for one reason:

> **iOS is the best available test of whether the module boundaries are real.**

A boundary you can only describe is a boundary you have not verified. Asking
"could this module compile and run on a phone?" forces an honest answer about
whether it actually hides what it claims to hide. So this document treats iOS
as a **design constraint applied today**, not a feature to build later.

## What survives a platform change, and what doesn't

Take the ten modules from [02](02-module-map.md) and ask which are about
*dictation* and which are about *macOS*.

| Module | Portable? | Why |
|---|---|---|
| `Dictation` | **Yes, unchanged** | a state machine over protocols; if it needs an `#if os(macOS)`, the design failed |
| `TextShaping` | **Yes, unchanged** | pure string transformation |
| `Preferences` | **Yes, unchanged** | typed keys over `UserDefaults` |
| `TranscriptHistory` | **Yes, unchanged** | JSONL in the app container |
| `Diagnostics` | **Yes, unchanged** | `os_log` and signposts are cross-platform |
| `Transcriber` | **Protocol yes, adapters vary** | FluidAudio and `SpeechAnalyzer` both support iOS; model size and memory pressure differ sharply |
| `AudioCapture` | **Protocol yes, implementation no** | AUHAL vs `AVAudioEngine`; iOS adds `AVAudioSession`, route changes, and interruptions |
| `TextSink` | **Protocol yes, implementation entirely different** | see below |
| `ShortcutHub` | **No** | `CGEventTap` does not exist on iOS |
| `Presentation` | **No** | no menu bar, no floating panel, no `NSPanel` |

Five modules port untouched. Three port behind their protocol. Two are
inherently platform surfaces — and those two are precisely the ones the module
map already isolates as *edges*.

That symmetry is the useful result. **The iOS question and the deep-module
question have the same answer.** Both are asking: is the core independent of
how it is triggered and where its output goes?

## The two genuinely hard problems

Worth stating plainly, because they are the reason an iOS build would be a
different product rather than a port.

### Triggering

macOS has a global hotkey. iOS has nothing equivalent — no background process
may observe input system-wide. The realistic triggers are an Action Button or
Control Center control, a Shortcuts action via App Intents, a Lock Screen
widget, or the app itself in the foreground.

**Consequence for today:** `ShortcutHub` must not be the only thing that can
produce a `DictationIntent`. The
[`DictationIntent` stream](03-api-seams.md#shortcuthub) already handles this —
any source can emit intents, and `Dictation` never asks where one came from.
That property is worth protecting even with no iOS build in sight, because it
is also what makes the menu item, the panel button, and the hotkey
interchangeable today.

### Delivery

"Paste into the frontmost app" has no iOS equivalent. There is no frontmost
app you can reach, no synthetic keystroke, no Accessibility-trust equivalent.
The realistic sinks are a custom keyboard extension, the share sheet, the
system pasteboard plus a user-initiated paste, or returning text to a Shortcut.

**Consequence for today:** `TextSink` must stay a protocol whose contract is
"make this text available to the user," not "press ⌘V." The
[`InsertionOutcome`](03-api-seams.md#textsink) design already accommodates
this: `copiedToClipboardOnly` is a *first-class success-ish outcome* on macOS
and it is the *only* outcome on iOS. That case was added because paste failure
is silently swallowed today — but it turns out to be the seam that makes the
sink portable. Good boundaries tend to pay twice.

## Transcription on a phone

Parakeet TDT 0.6B via FluidAudio runs on iOS, but a 0.6B-parameter model on a
memory-constrained device with aggressive background eviction is a different
engineering problem from the same model on a Mac with 32 GB. Three options,
roughly in order of practicality:

1. **`SpeechAnalyzer`** (iOS 26+). Apple manages the assets, so no
   several-hundred-MB in-app download, and the OS handles memory pressure. The
   obvious default for a phone.
2. **FluidAudio/Parakeet.** Same code as the Mac, same accuracy — pay for it in
   memory and app size.
3. **Core AI** (iOS 27+). Explicitly designed for this: fine-grained inference
   memory control, hardware specialization, AOT compilation. The most
   interesting long-term answer if you want to own the model choice on both
   platforms. See [05](05-macos-27-adoption.md).

**Consequence for today:** none, beyond what
[`Transcriber`](03-api-seams.md#transcriber) already requires. The protocol has
no model parameter and no provider concept, so backend choice is per-platform
composition. That is the same property that makes the macOS 27 backend
question tractable.

## The cheap forcing function

Do **not** create an iOS target in this work. It would be a product decision
with UI, App Store, and provisioning consequences, and none of that serves the
current goals.

Instead, once [02, Option B](02-module-map.md#how-the-boundaries-get-enforced)
lands and the core is a set of local SPM packages:

```bash
swift build --triple arm64-apple-ios18.0    # or via xcodebuild -destination
```

If the portable five compile for iOS, the boundaries are real. If they don't,
the error message tells you exactly which module leaked a platform assumption
and where. That is a one-command architecture test, and it costs nothing to run
in a pre-commit hook or CI.

This is the whole reason iOS appears in this document. Not to build a phone
app — to get a compiler to check the claim in [02](02-module-map.md) that
`Dictation` and the capabilities are platform-neutral.

**DECIDE:** adopt the iOS-compiles check as a standing gate, or treat iOS as
out of scope entirely and rely on review discipline? Recommendation: adopt it.
It is nearly free and it is the only mechanical check that the core stayed
clean.

## If an iOS app ever happens

Recorded so the thinking isn't lost, explicitly out of scope:

- It is a **different product with a shared core**, not a port. Different
  trigger, different delivery, different UI.
- The most plausible shape is a Shortcuts-and-keyboard-extension app: dictate
  from anywhere via an App Intent, and insert via a custom keyboard.
- App Intents ([05](05-macos-27-adoption.md)) is the enabling technology, and
  it is also useful on macOS — which is a hint that if iOS ever becomes real,
  App Intents is the first thing to adopt on *both* platforms.
- Settings and history would want to sync, which reopens CloudKit — deliberately
  removed in the lean strip. That is a genuine cost to weigh, not an oversight.
