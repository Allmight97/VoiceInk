# VoiceInk

This repository is the lean-local macOS fork. `LEAN-SPEC.md` defines the
retained product contract, including narrowly restored behavior. When
implementation, tests, and that contract disagree, establish current behavior
from code and proof, then update the contract in the same change.

## Product boundary

- Preserve the core path: one global shortcut controls microphone capture,
  the selected local backend transcribes it, and the filtered result is pasted
  into the frontmost app. Parakeet v2 is the default; Apple Speech is the only
  optional backend.
- Backend selection and Apple locale are captured when recording starts.
  Dictation never acquires assets or falls back to another backend; acquisition
  and reservation release are explicit Settings actions.
- Keep the idle path free of timers, network work, and recurring persistence
  tasks.
- Do not reintroduce the removed cloud, AI-enhancement, licensing, updater,
  SwiftData/database, multi-mode, or multi-shortcut surfaces without an
  explicit product decision and an update to the owning spec.
- Use the existing single macOS app target and file layout as a starting point,
  not an architectural constraint. Prefer native Swift, SwiftUI, Observation,
  and actor isolation. Add a protocol, package, or deeper module only when a
  concrete behavior boundary or test seam requires it; do not add speculative
  deep-module architecture.

## Proof contract

Swift 6 language mode on macOS 27 is a release criterion, not deferred cleanup.
Every behavior change must add or update an automated test or targeted macOS
runtime proof. Keep `VoiceInkTests` (Swift Testing) and `VoiceInkUITests`
(XCTest) meaningful; replace placeholder coverage when a change depends on it.

## Build and test commands

- Use Xcode 27 per command; do not change global `xcode-select`:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- Discover the project scheme and valid macOS destination before proving a
  slice:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project VoiceInk.xcodeproj -list` and
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project VoiceInk.xcodeproj -showdestinations -scheme VoiceInk`.
- Build and test the shared `VoiceInk` scheme with the selected macOS
  destination. Use `make local` only when a runnable local app is required;
  it owns `.local-build` and the local entitlements path.
- After any `VoiceInk.xcodeproj/project.pbxproj` edit, run
  `plutil -lint VoiceInk.xcodeproj/project.pbxproj`.
- `FluidAudio` is the sole current Swift package dependency, not a permanent
  requirement. Add no package without a named retained behavior; remove a
  current package when the migration proves it unnecessary.

Keep roadmap state, issue links, session history, and agent/model routing out
of this file.
