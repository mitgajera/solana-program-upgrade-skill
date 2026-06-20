# Anchor `Migration` Type

Anchor [PR #4060](https://github.com/coral-xyz/anchor/pull/4060) adds a
`Migration<'info, From, To>` account container that turns the manual
"deserialize old, resize, write new, mark migrated" dance into a typed account
plus a `.migrate(..)` call. It is sugar over the same `realloc` mechanics covered
in `realloc-migration.md`.

> ## Read this first: verify it is in your Anchor version
>
> The latest stable Anchor is **1.0.x (1.0.2 as of mid-2026)**, and PR #4060
> (`Migration<'info, From, To>`) is **merged**. But "merged" is not the same as
> "in the build you have installed" - verify before you rely on it, never assume.
>
> **Verify (do not assume):**
> 1. `anchor --version` to see what you actually have.
> 2. Check the [Anchor CHANGELOG](https://github.com/coral-xyz/anchor/blob/master/CHANGELOG.md)
>    for the `Migration` entry and the exact release it landed in.
> 3. Try to import it: `use anchor_lang::prelude::Migration;` (or wherever the
>    changelog says it lives) and `anchor build`. If it does not resolve, your
>    installed 1.0.x does not expose it.
>
> **If it is absent, use the manual `realloc`/`resize` pattern in
> `realloc-migration.md`.** That pattern is the portable default and works on every
> Anchor version. The `Migration` type only saves boilerplate where it is available.

## Contents

- [What it does](#what-it-does)
- [Constraint and type usage](#constraint-and-type-usage)
- [The `migrate` call and strict mode](#the-migrate-call-and-strict-mode)
- [`into_inner` / `into_inner_mut`](#into_inner--into_inner_mut)
- [Errors](#errors)
- [When to prefer the manual pattern](#when-to-prefer-the-manual-pattern)
- [Common errors](#common-errors)

## What it does

`Migration<'info, From, To>` wraps an account that may currently hold **either**
the old (`From`) or new (`To`) layout. On deserialization it detects which version
is on chain. You then call `.migrate(..)` to convert `From` into `To`. The type
system enforces that a `From` account is not silently written back unconverted -
that is the "strict" design (see below).

This solves the exact ordering problem from `realloc-migration.md`: a plain
`Account<'info, To>` fails to deserialize an old, shorter account before realloc
can run. `Migration` deserializes the *old* layout successfully and gives you a
typed path to the new one.

## Constraint and type usage

The account uses the standard `realloc` constraint group, sized for the **new**
(`To`) layout, with the field typed as `Migration<'info, From, To>`:

```rust
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct MigrateVault<'info> {
    #[account(
        mut,
        realloc = 8 + VaultV2::INIT_SPACE,   // NEW layout size; Anchor 1.0: VaultV2::DISCRIMINATOR.len() + VaultV2::INIT_SPACE
        realloc::payer = payer,
        realloc::zero = false,
    )]
    pub vault: Migration<'info, VaultV1, VaultV2>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}
```

The constraint syntax above is quoted from PR #4060. `VaultV1` and `VaultV2` are
your two layouts; only `VaultV2` (the destination) needs to be the live
`#[account]` type. Confirm the exact bounds Anchor requires on `From`/`To`
(`InitSpace`, the (de)serialize traits) against the shipped API.

## The `migrate` call and strict mode

PR #4060 ships a **strict-mode-only** design: the conversion must be performed
explicitly with `.migrate(..)`, and the type system / serialization on exit
prevents leaving the account unconverted. Conceptually:

```rust
pub fn migrate_vault(ctx: Context<MigrateVault>) -> Result<()> {
    let vault = &mut ctx.accounts.vault;

    // Build the new layout from the old one, then commit the migration.
    // Shape per PR #4060 - verify the exact source-accessor and signature
    // against the released API/docs before relying on it.
    vault.migrate(VaultV2 {
        version: 2,
        authority: /* carried from the old VaultV1 */,
        amount:    /* carried from the old VaultV1 */,
        locked_until: 0, // default for the new field
    })?;

    Ok(())
}
```

If the spec/changelog for your version exposes a `migrate = "strict"` constraint
attribute (the spec references it), prefer the spelling the changelog documents;
the PR's own example expresses strictness through the type, not an attribute.
Either way: do not invent the spelling - read it from the release.

## `into_inner` / `into_inner_mut`

After the account is in (or has been migrated to) the `To` layout, access the
inner value with:

- `.into_inner()` - read the inner value.
- `.into_inner_mut()` - mutable access to the inner value, e.g. to keep editing
  the freshly migrated account in the same instruction.

```rust
let migrated: &mut VaultV2 = ctx.accounts.vault.into_inner_mut();
migrated.amount = migrated.amount.checked_add(1).unwrap();
```

Treat the exact return types and borrow shapes as version-specific; confirm them
against the API your version ships.

## Errors

PR #4060 adds two error variants:

| Error | Meaning | Typical cause |
| --- | --- | --- |
| `AccountAlreadyMigrated` | Tried to migrate an account already in the `To` layout | Re-running migration without an idempotency check at the call site |
| `AccountNotMigrated` | The instruction tried to exit while the account was still `From` | Forgot to call `.migrate(..)` in a code path |

`AccountAlreadyMigrated` gives you idempotency for free at the type level: a
second migration attempt errors instead of double-applying. (With the manual
pattern you get this by guarding on `version < CURRENT` yourself.)

## When to prefer the manual pattern

Use the manual `realloc` migration (`realloc-migration.md`) when:

- Your Anchor version does not ship `Migration` (the common case today).
- You target native / Pinocchio, where there is no Anchor sugar at all.
- You need lazy migrate-on-touch inside arbitrary instructions, or custom resize
  stepping for the 10 KB cap, that does not fit the single typed-account model.

Use `Migration` when it is available and the migration is a clean one-shot
`From -> To` per account: it removes boilerplate and gives type-enforced
strictness and idempotency.

## Common errors

| Error / symptom | Cause | Fix |
| --- | --- | --- |
| `Migration` type / import does not resolve | Your installed Anchor does not expose it (older than the 1.0.x release that ships it) | Upgrade to the release that ships it, or use the manual pattern in `realloc-migration.md` |
| `AccountNotMigrated` on exit | A code path reached the end without calling `.migrate(..)` | Call `.migrate(..)` on every path, or branch out early before touching the account |
| `AccountAlreadyMigrated` | Migration ran on an account already converted | Guard the call site (skip already-`To` accounts), or treat the error as "already done" |
| Build fails on `From`/`To` bounds | Missing trait bounds Anchor requires on the layouts | Add the (de)serialize / `InitSpace` derives the changelog specifies |
| Account not rent-exempt after migrate | `realloc::payer` not funded / wrong size in `realloc =` | Size `realloc` to the `To` layout and ensure the payer is a funded `mut` Signer |

Next: prove the migration is correct and idempotent on a fork in
`fork-simulation.md`, or choose the overall approach in `migration-strategies.md`.
