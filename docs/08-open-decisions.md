# 8. Open decisions

Every `DECIDE:` from the other documents, in one place, numbered so they can be
answered by number.

Each has a recommendation. The recommendations are consistent with each other —
if you overturn one, check the ones near it.

## Blocking — decide before any code moves

These change what gets built, not just how.

**D1. Boundary enforcement: directories, or local SPM packages?**
→ [02](02-module-map.md#how-the-boundaries-get-enforced)

Directories are a suggestion; packages are a compiler error. Packages also make
the Swift 6 migration incremental and make the iOS check possible.
**Recommend: local packages for Core + Capabilities + Support, with
[Wave 3](07-sequencing.md#wave-3--textshaping-and-the-packaging-pilot) as a
low-cost pilot on the smallest module.** Everything in these documents is a
convention until the build system agrees with it.

**D2. Deployment floor: 14.4, 15.0, 26.0, or 27.0?**
→ [05](05-macos-27-adoption.md#the-lever-that-matters-most)

The largest single tidying lever, because it deletes complexity rather than
moving it. At 26.0: 414 lines of dead `Transcription/Native/` become live, one
compile flag and 13 availability gates disappear.
**Recommend: 26.0 minimum with 27-only APIs behind `if #available`.** Go
straight to 27.0 if the app is only ever for you.

**D3. Does the module map look right?**
→ [02](02-module-map.md#the-proposed-modules)

Ten modules, four tiers, five genuinely deep. This is the thing to argue with
hardest — everything else follows from it. Specifically: is `Dictation` the
right thing to make central, and are `ShortcutHub` and `Presentation` correctly
treated as edges rather than as part of the core?

**D4. Bundle identifier and product name.**
→ [02](02-module-map.md#naming)

Still `com.prakashjoshipax.VoiceInk`, baked into the Application Support path,
the log subsystem, and every TCC grant. Changing it costs re-granting
permissions and migrating the history log — a one-time cost, cheapest paid
before a lot of new code hardcodes the old string.
**Recommend: decide now, execute whenever.** Module names in these documents
deliberately carry no product name, so a rename touches nothing here.

## Product — decide before the wave that touches them

Each is a real behavior question, not a technical one.

**D5. Should paste failure be visible?** → [01, #1](01-behavior-contract.md)
Today: you speak, the panel dismisses, nothing appears, and the app says
nothing. The text is on the clipboard but you don't know that.
**Recommend: yes — a toast saying the text is on the clipboard.** This is the
most user-hostile behavior in the app. Needed before
[Wave 5](07-sequencing.md#wave-5--collapse-the-pipeline-introduce-transcriber).

**D6. Bracket-stripping policy.** → [01, #2](01-behavior-contract.md)
`[...]`, `(...)` and `{...}` are all deleted, inherited from a Whisper-era
hallucination filter. Dictating a genuine parenthetical silently loses it.
**Recommend: `.removeSquareOnly`, after watching real Parakeet output.** Ship
the setting with today's `.removeAll` default so nothing changes until you
choose.

**D7. What should the panel's close button do during recording?**
→ [01, #3](01-behavior-contract.md)
Today it hides the panel without stopping the recording — the audio unit keeps
running with no visible UI. **Recommend: cancel. This is a bug.**

**D8. First-run model download experience.** → [01, #4](01-behavior-contract.md)
The first dictation on a new machine silently downloads several hundred MB with
no progress and no explanation, and a download failure produces the same
message as an inference failure. There is already a progress-reporting
`downloadFluidAudioModel` with no caller.
**Recommend: surface `TranscriberAvailability` in the menu, which already shows
"Loaded / Unloaded".**

**D9. History log retention.** → [01, #6](01-behavior-contract.md)
Grows without bound; turning it off doesn't delete it.
**Recommend: cap at a few thousand lines with a note in Settings.**

**D10. Confirm the 30-minute buffer ceiling.** → [01, #7](01-behavior-contract.md)
Deliberate memory bound, or a number nobody revisited?
**Recommend: confirm, then promote it to a `[C]` contract statement.**

**D11. Which frustrations are real?**
→ [01, frustrations](01-behavior-contract.md#frustrations-to-fill-in)
Six candidates inferred from the code — cold start, laggy live transcript,
filler-word aggressiveness, no casing/punctuation policy, paste timing in
Electron apps, silent failures. **This one only you can answer**, and it is the
most valuable input in this list: it determines what the restructuring should
make *easy*, and it feeds [`FELT-GAPS.md`](../FELT-GAPS.md) rather than a wave.

## Technical — decide during the relevant wave

**D12. `@AppStorage` in views, or bind to the preference store?**
→ [03](03-api-seams.md#preferences)
`@AppStorage` reads `UserDefaults` directly, violating the single-source rule.
**Recommend: the store**, so settings can be observed by non-UI code and
eventually migrated off `UserDefaults`. Needed for
[Wave 2](07-sequencing.md#wave-2--preferences).

**D13. Add a `.delivering` phase?** → [03](03-api-seams.md#dictation)
Makes the phase list honest; invisible unless the menu label changes.
**Recommend: add it, keep the menu showing "Transcribing" across both.**

**D14. Default transcription backend once the floor is ≥26.**
→ [05](05-macos-27-adoption.md#2-apple-speechanalyzer-macos-26)
**Recommend: keep Parakeet as the default, make `SpeechAnalyzer` a real
selectable second backend.** A protocol with one implementation is a guess; a
protocol with two is a boundary. This is what
[Wave 9](07-sequencing.md#wave-9--prove-the-seam) is for.

**D15. Pin FluidAudio to a tag instead of a raw revision.**
→ [05](05-macos-27-adoption.md#1-fluidaudio--parakeet-current)
Currently `3c6e79f…`, roughly a year behind 0.12.4.
**Recommend: yes, and update on its own commit** — upstream now has streaming
and VAD that bear on the live-transcript design.

**D16. Give `PasteMethod` a Settings UI, or remove the option?**
→ [04](04-tidy-up-inventory.md#into-textsink)
It exists, works, and is reachable only by hand-writing a default.
**Recommend: expose it.** The AppleScript path exists for a real keyboard-layout
problem; an option nobody can find is a bug report waiting to happen.

**D17. Is UI modernization in scope?**
→ [05](05-macos-27-adoption.md#liquid-glass)
**Recommend: separate pass, after the boundaries land.** A visual change is a
behavior change; mixing it into a refactor makes both unreviewable.

**D18. Adopt the iOS-compiles check as a standing gate?**
→ [06](06-multiplatform-constraint.md#the-cheap-forcing-function)
One command, and the only mechanical proof that the core stayed
platform-neutral. **Recommend: yes**, once packages exist. It is not about
building an iOS app.

## Repo hygiene — low stakes, quick answers

**D19. `README.md` rewrite.** Currently describes upstream: modes, AI
assistant, context awareness, licensing, six removed dependencies. Entangled
with D4. *This PR adds only a pointer to `docs/`.*
**Recommend: rewrite once D4 is settled.**

**D20. `.github/ISSUE_TEMPLATE/`** points at upstream's support channels.
**Recommend: delete** — a personal fork doesn't need issue triage.

**D21. `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`** are upstream community docs
for a project that doesn't accept contributions.
**Recommend: delete**, or replace `CONTRIBUTING.md` with a short note on how
*you* work in this repo, which is more useful to an agent anyway.

**D22. Delete `.enhancing` and `.busy`.** → [01, #5](01-behavior-contract.md)
Never assigned; handled at 11 sites across 5 files. No behavior change since
they are unreachable. **Recommend: yes**, in
[Wave 1](07-sequencing.md#wave-1--free-deletions).

## Already actioned in this PR

Zero-risk, factually-wrong-documentation fixes that needed no decision:

- **`BUILDING.md`** rewritten — it instructed you to build `whisper.cpp` and
  run `make whisper` / `make setup`, none of which exist any more, and omitted
  `make install` and `make archive-stock`, which do.
- **`.github/PULL_REQUEST_TEMPLATE.md`** replaced — it was upstream's "this
  project does not accept pull requests, please close this PR", which
  auto-populated every PR opened on this fork.
- **`AGENTS.md`** added — repo orientation for coding agents.
- **`README.md`** — a short pointer to `docs/` and a note that the fork has
  diverged. No rewrite pending D4/D19.
