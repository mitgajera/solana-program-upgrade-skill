---
description: Analyze account structs and proposed changes, then produce a migration plan and risk report. No execution.
argument-hint: "[path to program / state.rs, or describe the change]"
---

# /plan-upgrade

Produce a **migration plan + risk report** for an upcoming Solana program upgrade.
This command plans only. It never deploys, never touches mainnet, and writes no
on-chain state.

Target: $ARGUMENTS

## Steps

1. **Locate the account schema.** Read the program's `#[account]` structs (e.g.
   `state.rs`, `lib.rs`, or the path the user gave). If the proposed change is not
   already in the code, ask the user for the new struct (or read it from a branch
   / diff).
2. **Diff old vs new** field by field. Classify each change as **additive**
   (append-only, safe) or **breaking** (reorder / remove / retype / seed change).
   Apply `skill/account-versioning.md`.
3. **Gather constraints** if not provided: account count (order of magnitude),
   activity pattern, downtime tolerance, who pays rent, Anchor vs native, and the
   Anchor version (to know if the `Migration` type is available).
4. **Choose a strategy** using the selection table in
   `skill/migration-strategies.md` (eager / lazy / copy-to-new). State why, and
   why the alternatives were rejected.
5. **Design versioning + mechanism** - version tag, branch logic, and manual
   `realloc` (`skill/realloc-migration.md`) or the `Migration` type if available
   (`skill/anchor-migration-type.md`, with the version caveat). Include the
   `realloc` size, rent direction, idempotency guard, and the 10 KB/tx cap if
   relevant.
6. **Estimate cost** - rent deltas and (for eager) transaction count; note who
   pays.
7. **Write the plan** with these sections: Summary, Schema diff analysis, Chosen
   strategy + why, Versioning plan, Migration mechanism, Cost estimate,
   Verification plan (fork + unit, `skill/fork-simulation.md`), Rollback plan
   (`skill/rollback-recovery.md`), and a **Risk report table** (risk, likelihood,
   impact, mitigation).

## Rules

- Do not execute anything. Output is a document, not a deployment.
- Do not invent APIs; flag anything version-specific as "verify against your
  version."
- Default to forward-only data design; for lossy changes, recommend copy-to-new,
  never in-place shrink.
- For a deeper, multi-step engagement, hand off to the `program-migration-architect`
  agent.
