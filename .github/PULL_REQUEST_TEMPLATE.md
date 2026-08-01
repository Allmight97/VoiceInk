## What changed

<!-- One or two sentences. Lead with the outcome, not the mechanics. -->

## Why

<!-- Which outcome or open decision does this serve?
     Link the relevant doc: docs/01-behavior-contract.md, docs/08-open-decisions.md, ... -->

## Behavior impact

<!-- Pick one and delete the rest. -->

- [ ] **No observable behavior change** — pure restructuring, deletion, or docs
- [ ] **Deliberate behavior change** — cite the `[?]` item in
      `docs/01-behavior-contract.md` or the `D-number` in
      `docs/08-open-decisions.md` that authorized it
- [ ] **New or removed feature** — should not happen during the reorganization;
      justify or move it to `FELT-GAPS.md`

## Gate

<!-- See docs/07-sequencing.md#the-gate -->

- [ ] Builds clean, no new warnings; `make local` produces a launchable app
- [ ] Pre-existing tests pass unmodified
- [ ] Smoke script run (`docs/07-sequencing.md#the-smoke-script`)
- [ ] Idle cost unchanged against the Wave 0 baseline

## Notes for review

<!-- Anything subtle: ordering that matters, a boundary that moved,
     something you were unsure about. -->
