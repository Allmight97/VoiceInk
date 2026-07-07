# Felt Gaps — restore ledger

Philosophy: nothing returns until it is *felt* in daily use. Each entry: what
was missed, when it was felt, and the restore decision. Keep restores small and
opt-in by default.

## Wave 1 — 2026-07-07 (first day of daily-driving the lean build)

| Gap | Felt when | Decision |
|---|---|---|
| Live transcript while speaking | First dictations — recorder panel shows waveform only | RESTORE opt-in: partial passes of the in-memory buffer every ~1.5 s feed `partialTranscript`; `ShowLiveTranscript` default false. Zero cost when off; recording-time cost only when on |
| Recorder panel position + live-text toggle | Same session | RESTORE: `RecorderPanelPosition` setting (bottom-center / top-center) + Settings toggle for live text |
| Transcription history | Anticipated: "what did I dictate?" / lost paste | RESTORE minimal: append-only JSONL at Application Support/com.prakashjoshipax.VoiceInk/transcriptions.jsonl + "Copy Last Transcription" menu item. No database. Paste-last *shortcut* stays out (single-hotkey invariant) |
| Word-replacement editor | Old SwiftData pairs lost; no UI to re-add | RESTORE: small Settings tab editing the UserDefaults-backed pairs |

## Known cuts, not yet felt (watchlist)

AI enhancement (biggest cut — revisit only if raw output repeatedly isn't
audience-ready), audio-file transcription (revisit as a scriptable CLI, cf.
upstream #801), auto-send, per-app modes, multiple hotkeys, middle-click,
custom vocabulary hints, non-English (SpeechAnalyzer flag is the escape hatch),
custom sounds, onboarding/permission-repair UI, update notifications
(antidote: occasional `git fetch upstream` review).
