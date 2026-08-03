# VoiceInk

This repository is the lean-local macOS fork. `LEAN-SPEC.md` defines the
retained product contract, including narrowly restored behavior. When
implementation, tests, and that contract disagree, establish current behavior
from code and proof, then update the contract in the same change.

## Product boundary

- Preserve the core path: one global shortcut controls microphone capture,
  local Parakeet v2 transcribes it, and the filtered result is pasted into the
  frontmost app.
- Keep optional features off by default and keep the idle path free of timers,
  network work, and recurring persistence tasks.
- Do not reintroduce the removed cloud, AI-enhancement, licensing, updater,
  SwiftData/database, multi-mode, or multi-shortcut surfaces without an
  explicit product decision and an update to the owning spec.
- Use the existing single macOS app target and file layout as a starting point,
  not an architectural constraint. Prefer native Swift, SwiftUI, Observation,
  and actor isolation. Add a protocol, package, or deeper module only when a
  concrete behavior boundary or test seam requires it; do not add speculative
  deep-module architecture.

## Migration and proof contract

Work in vertical slices that prove behavior before the next slice or cleanup:

1. Establish the Xcode 27 build baseline and record warnings.
2. Migrate recorder/capture concurrency ownership; prove start, stop, cancel,
   and meter updates.
3. Migrate UI and notification isolation; prove menu-bar and recorder-panel
   behavior.
4. Fix Core Audio pointer boundaries; prove device enumeration and capture.
5. Enable Swift 6 language mode on macOS 27 and require a warning-free build.

Swift 6 language mode on macOS 27 is a release criterion, not deferred cleanup.
Every slice must add or update a test or targeted macOS runtime proof for its
behavior. Keep `VoiceInkTests` (Swift Testing) and `VoiceInkUITests` (XCTest)
meaningful; replace placeholder coverage when a slice depends on it.

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
- `FluidAudio` and `swift-atomics` are the current package dependencies, not
  permanent requirements. Add no package without a named retained behavior;
  remove a current package when the migration proves it unnecessary.

Keep roadmap state, issue links, session history, and agent/model routing in
issues or ordinary documentation, not this file.
