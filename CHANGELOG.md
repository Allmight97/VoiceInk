# Changelog

This is the release history for the independently maintained lean-local
VoiceInk fork. It is derived from VoiceInk and remains licensed under GPL-3.0.

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
