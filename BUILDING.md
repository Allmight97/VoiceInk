# Building

Build instructions for this fork (`Allmight97/VoiceInk`, branch
`jstar/lean-local`).

> This fork diverges substantially from upstream VoiceInk. Whisper, cloud
> transcription, AI enhancement, the updater and most other subsystems were
> removed. If you followed upstream's build instructions before, ignore them:
> **there is no whisper.cpp step any more.**

## Prerequisites

- macOS 14.4 or later (see the deployment-floor question in
  [`docs/05-macos-27-adoption.md`](docs/05-macos-27-adoption.md))
- Xcode, with command line tools
- `git`

That is the whole list. There are no external frameworks to fetch and no
`~/VoiceInk-Dependencies` directory. The only dependencies are two Swift
packages — [FluidAudio](https://github.com/FluidInference/FluidAudio) and
[swift-atomics](https://github.com/apple/swift-atomics) — which Xcode resolves
automatically.

## Quick start

```bash
git clone https://github.com/Allmight97/VoiceInk.git
cd VoiceInk
make install
```

`make install` builds a Release binary, signs it, copies it to `/Applications`,
and launches it.

## Targets

| Target | What it does |
|---|---|
| `make check` (`healthcheck`) | verifies `git`, `xcodebuild` and `swift` are present |
| `make build` | unsigned Debug build via `xcodebuild` |
| `make local` | **Release** build, self-signed, copied to `~/Downloads/VoiceInk.app` |
| `make install` | `make local`, then quit any running copy, install to `/Applications`, and launch |
| `make run` | launch an already-built app |
| `make dev` | `build` then `run` |
| `make all` | `check` then `build` (the default target) |
| `make archive-stock` | zip whatever is currently in `/Applications/VoiceInk.app` as a backup |
| `make clean` | remove `.local-build/` |
| `make help` | list targets |

## Use `make local`, not `make build`

For anything you intend to actually run, use `make local` or `make install`.

`make local` builds Release with a **stable self-signed identity** named
`VoiceInk Local`, configured in `LocalBuild.xcconfig` and passed on the
`xcodebuild` command line. That identity matters more than it looks:

- **macOS keys TCC permission grants partly on code signature.** With a stable
  identity, your Microphone and Accessibility grants survive rebuilds. Without
  one, every build looks like a new app and you re-grant permissions each time.
- Debug builds link debug dylibs that a self-signed identity cannot ship, so
  `make build` output can be rejected at launch.
- Release is also what you want for real use — the transcription path is
  meaningfully faster optimized.

### One-time signing identity setup

`make local` expects a code-signing identity named `VoiceInk Local` in your
login keychain. Create it once via **Keychain Access → Certificate Assistant →
Create a Certificate**:

- Name: `VoiceInk Local`
- Identity Type: Self Signed Root
- Certificate Type: Code Signing

Then verify:

```bash
security find-identity -v -p codesigning | grep "VoiceInk Local"
```

To use a different name, override it:

```bash
make local LOCAL_SIGN_IDENTITY="My Identity"
```

## First run

1. Launch the app. It appears in the menu bar only — no Dock icon, no window.
2. Open **Settings** from the menu bar and assign a dictation shortcut. Until
   you do, only the menu can start dictation.
3. The first dictation prompts for **Microphone** and **Accessibility**
   permission. Both are required: the microphone to record, Accessibility both
   for the global hotkey (`CGEventTap`) and to paste via a synthetic ⌘V.
4. The first dictation also downloads the Parakeet model. **This currently
   happens silently and can take a while** on a slow connection — see
   [D8](docs/08-open-decisions.md).

## Where things end up

```
.local-build/                     derived data for `make local` (gitignored)
~/Downloads/VoiceInk.app          output of `make local`
/Applications/VoiceInk.app        output of `make install`

~/Library/Application Support/com.prakashjoshipax.VoiceInk/
├── Recordings/                   deleted after transcription unless
│                                 DebugKeepRecordings is set
└── transcriptions.jsonl          history log
```

FluidAudio manages the Parakeet model cache in its own directory.

## Troubleshooting

**The app launches but the hotkey does nothing.** Almost always Accessibility
permission. Check System Settings → Privacy & Security → Accessibility. Note
that a failed event tap is currently silent — the app looks fine while its main
input is dead ([D5 and related](docs/08-open-decisions.md)).

**Permissions are requested again after every build.** The `VoiceInk Local`
signing identity is missing or changed. See the setup section above.

**The first dictation takes a long time and produces nothing.** The model is
downloading. Watch for network activity, or check Console for the
`com.prakashjoshipax.voiceink` subsystem.

**Nothing is pasted, but the app seems fine.** The text is probably on your
clipboard — try ⌘V. Paste failure is currently not reported ([D5](docs/08-open-decisions.md)).

**Stale build artifacts.** `make clean`, then `make local`. To go further,
delete `~/Library/Developer/Xcode/DerivedData/VoiceInk-*`.

## Debugging

The app logs under subsystem `com.prakashjoshipax.voiceink`:

```bash
log stream --predicate 'subsystem == "com.prakashjoshipax.voiceink"' --level debug
```

It also emits `os_signpost` intervals for `record`, `transcribe` and `paste`
under subsystem `com.prakashjoshipax.VoiceInk`, category `leanpath`. Open
Instruments with the os_signpost instrument to see where time goes in the core
loop.

To keep recorded WAV files for inspection:

```bash
defaults write com.prakashjoshipax.VoiceInk DebugKeepRecordings -bool true
```

## Further reading

- [`docs/`](docs/README.md) — architecture, behavior contract, and the
  in-progress reorganization
- [`LEAN-SPEC.md`](LEAN-SPEC.md) — what the lean strip removed and why
- [`FELT-GAPS.md`](FELT-GAPS.md) — the ledger of what has been restored
