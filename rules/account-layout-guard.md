---
description: Guard against silent account-layout breaks. When editing an #[account] struct, require a version bump + migration path before proceeding.
globs:
  - "**/*.rs"
  - "**/state.rs"
  - "**/state/**.rs"
---

# Account Layout Guard

This file may define on-chain account layouts (`#[account]` structs / borsh state).
Changing a layout that is already deployed can brick existing accounts. Before
making or accepting any edit to an account struct, run this check.

## When an edit touches an `#[account]` struct (or borsh state), classify it

- **Additive** (safe): appending a new field at the **end**, or renaming a field.
- **Breaking** (dangerous): adding a field in the **middle**, **reordering**,
  **removing**, **retyping** a field, or **renaming the struct** (changes the
  Anchor discriminator).

## If the change is breaking, STOP and require all of the following before proceeding

1. A **version tag** is present and **bumped** (e.g. leading `version: u8`, or
   enum-tagged state). If the struct has no version tag, add one first.
2. A **migration path** exists for already-deployed accounts (manual `realloc` or
   the `Migration` type; or copy-to-new for changes that cannot happen in place).
3. The migration is **idempotent** (migrates only when `version < CURRENT`).
4. A **fork-simulation** plan exists to prove no byte corruption before mainnet.

Do not silently rewrite the struct. Surface the layout risk to the user, propose
the version bump + migration, and only proceed once the path is in place.

## If the change is additive

Still confirm: the account is grown (`realloc`) and the new field is populated by a
migration; "additive" means it will not corrupt, not that it is free.

## Route to depth

- Versioning patterns: `skill/account-versioning.md`
- In-place migration: `skill/realloc-migration.md` /
  `skill/anchor-migration-type.md`
- Strategy choice: `skill/migration-strategies.md`
- Proof before mainnet: `skill/fork-simulation.md`
