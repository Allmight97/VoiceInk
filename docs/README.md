# Architecture alignment docs

These documents exist to answer one question before any restructuring code is
written: **what are the modules, what complexity does each own, and what is the
boundary between them?**

They are written to be read cold — by the author after a month away, and by a
coding agent with no prior context.

Read in order:

| # | Document | Answers |
|---|---|---|
| 0 | [Re-onboarding](00-reonboarding.md) | What is this app right now? What is FluidAudio? Where does everything live? |
| 1 | [Behavior contract](01-behavior-contract.md) | What does "don't change current behavior" actually mean, as testable statements? |
| 2 | [Module map](02-module-map.md) | Which modules, what complexity each hides, why this cut and not another |
| 3 | [API seams](03-api-seams.md) | The concrete public surface of each module: types, errors, cancellation, isolation, effects |
| 4 | [Tidy-up inventory](04-tidy-up-inventory.md) | Every file classified retain / reshape / replace / delete, with evidence |
| 5 | [macOS 27 adoption](05-macos-27-adoption.md) | What Apple's 2026 stack changes for this app, and what to deliberately skip |
| 6 | [Multiplatform constraint](06-multiplatform-constraint.md) | What an eventual iOS build demands of the boundaries — today, not later |
| 7 | [Sequencing](07-sequencing.md) | The order of work, and the gate that keeps behavior unchanged at each step |

## Status

Every document is a **proposal pending alignment**. Nothing here has been
implemented.

Open decisions are marked inline with `DECIDE:`. They are collected in
[08-open-decisions.md](08-open-decisions.md). Those are the things worth
arguing about before code moves; everything else follows from them.

## Ground rules these docs assume

Three constraints shape every recommendation. If one of these is wrong, say so
early, because most of the design hangs off them.

1. **No new features, no removed features.** The observable behavior in
   [01](01-behavior-contract.md) is the contract. Restructuring is the work.
2. **Deep modules.** A module earns its existence by hiding more complexity
   than its interface exposes. A module whose interface is nearly as
   complicated as its implementation should be inlined into its caller instead.
3. **Design for the outcome, not for what exists.** The current directory tree
   is an artifact of an upstream project plus a subtractive strip. It is
   evidence, not a constraint.
