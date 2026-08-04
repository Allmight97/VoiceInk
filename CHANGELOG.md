# Changelog

This is the release history for the independently maintained lean-local
VoiceInk fork. It is derived from VoiceInk and remains licensed under GPL-3.0.

## Unreleased

- Add Apple Speech as an optional on-device transcription backend while keeping
  Parakeet v2 as the default.
- Add Apple Speech language selection, readiness, explicit asset acquisition,
  and reservation-release controls to Settings. Recording never downloads or
  silently falls back to another backend.
- Show the live transcript in the recorder by default, with a Settings toggle
  that disables both the preview and its transcription work.
- Fix idle model eviction and Core Audio device-change callbacks so they
  release cached backend resources without crashing the app or disabling its
  shortcut.
- Remove unreachable upstream assets, unused formatting and error types, and
  dormant convenience APIs from the recorder, shortcut, paste, notification,
  and Core Audio paths.
- Retire hidden legacy prioritized-device, AppleScript-paste, and configurable
  cancel-shortcut behavior; keep explicit system/custom input selection,
  native CGEvent paste, and double-Escape cancellation.
- Preserve the local model registry and acquisition-management substrate for
  the model selection roadmap tracked in issue #10.

## 1.0.0 — Lean-local baseline

- Establish the fork's independent release line and macOS 27 minimum.
- Adopt Swift 6 language mode with complete strict concurrency and
  warning-free Debug and Release builds.
- Make Parakeet v2 acquisition explicit in Settings; dictation stays local and
  never starts a model download.
- Harden recorder lifecycle, cancellation, delivery, UI isolation, and Core
  Audio boundaries with targeted automated proof.
- Remove migration-proven unreachable service paths while preserving the
  retained product contract in `LEAN-SPEC.md`.
