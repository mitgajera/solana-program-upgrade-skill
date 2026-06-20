# Realloc Migration

`realloc` resizes an existing account in place so new code can store a changed
layout in the same account (same address, same PDA, same discriminator). This is
the portable baseline for migration - it works on any Anchor version and maps
directly to native code. The Anchor `Migration` type (see
`anchor-migration-type.md`) is sugar over this; if it is not in your version, do
this manually.

> Verify against your installed versions: `anchor --version`, and the
> `solana-program` version in `Cargo.lock` (the realloc growth cap and the
> `realloc::zero` semantics live in the runtime). Do not hardcode constants you
> have not confirmed.

## Contents

- [The Anchor realloc constraint group](#the-anchor-realloc-constraint-group)
- [Critical: the constraint cannot migrate a changed layout](#critical-the-constraint-cannot-migrate-a-changed-layout)
- [Lazy migrate-on-touch (manual, robust)](#lazy-migrate-on-touch-manual-robust)
- [Idempotency](#idempotency)
- [Growing vs shrinking and rent direction](#growing-vs-shrinking-and-rent-direction)
- [The `realloc::zero = false` footgun](#the-realloczero--false-footgun)
- [The ~10 KB per-transaction growth cap](#the-10-kb-per-transaction-growth-cap)
- [Lazy vs eager](#lazy-vs-eager)
- [Native manual equivalent](#native-manual-equivalent)
- [Common errors](#common-errors)

## The Anchor realloc constraint group

```rust
#[derive(Accounts)]
pub struct Grow<'info> {
    #[account(
        mut,
        realloc = 8 + Registry::INIT_SPACE,   // new total byte length (incl. 8-byte discriminator)
        realloc::payer = payer,               // who funds (or receives) the rent delta
        realloc::zero = false,                // zero-init the new region?
    )]
    pub registry: Account<'info, Registry>,
    #[account(mut)]
    pub payer: Signer<'info>,                 // must be mut + Signer
    pub system_program: Program<'info, System>, // required to move rent lamports
}
```

- `realloc = <len>` is the **new total size in bytes**, including the 8-byte
  discriminator. Compute it from `8 + T::INIT_SPACE` (Anchor's `#[derive(InitSpace)]`)
  rather than counting by hand.
- `realloc::payer` funds rent when growing and **receives** the freed rent when
  shrinking. It must be `mut` and a `Signer`.
- `realloc::zero` controls whether the reallocated memory is zeroed (see the
  footgun section).
- `system_program` must be present because the rent delta is a lamport transfer.

This constraint is for **growing the dynamic content of the same type** - for
example a `Vec` that needs more capacity. Anchor reallocs the account during
account resolution, before your instruction body runs.

## Critical: the constraint cannot migrate a changed layout

The biggest realloc footgun in practice: you **cannot** put the new struct type
on an old account and rely on the realloc constraint to fix it.

`Account<'info, NewType>` deserializes the account **before** the realloc runs.
An old, shorter account has no bytes for the new field, so borsh fails with
`AccountDidNotDeserialize` (`Not all bytes read` / unexpected EOF) and the
instruction aborts before realloc ever happens.

So the constraint works when the **type is unchanged** (e.g. a growing `Vec`),
but a **schema change** (new fixed field, new layout) must be migrated manually in
the instruction body, where you control the order: read old bytes, resize, write
new bytes. That is the pattern below. (The `Migration` type solves the ordering
for you; this manual version is the portable fallback.)

## Lazy migrate-on-touch (manual, robust)

Migrate an account the first time any instruction touches it. Use
`UncheckedAccount` so Anchor does not try to deserialize the new layout
prematurely, then do everything explicitly.

```rust
use anchor_lang::prelude::*;

pub const VAULT_VERSION: u8 = 2;

// Old layout - deserialize-only (NOT an #[account]; keeps the on-chain
// discriminator stable). Assumes v1 already carried a leading version byte.
#[derive(AnchorDeserialize)]
pub struct VaultV1 {
    pub version: u8,
    pub authority: Pubkey,
    pub amount: u64,
}

#[account]
#[derive(InitSpace)]
pub struct Vault {
    pub version: u8,
    pub authority: Pubkey,
    pub amount: u64,
    pub locked_until: i64, // v2 addition
}

#[derive(Accounts)]
pub struct TouchVault<'info> {
    /// CHECK: deserialized manually to support both old and new layouts
    #[account(mut)]
    pub vault: UncheckedAccount<'info>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn touch_vault(ctx: Context<TouchVault>) -> Result<()> {
    let vault_ai = ctx.accounts.vault.to_account_info();
    require_keys_eq!(*vault_ai.owner, crate::ID);

    // 1. Idempotency guard: read the stored version, bail if already current.
    let stored_version = {
        let data = vault_ai.try_borrow_data()?;
        require!(data.len() >= 9, MyError::AccountTooSmall); // 8 disc + 1 version
        data[8] // version byte sits right after the discriminator
    };
    if stored_version >= VAULT_VERSION {
        return Ok(()); // no-op: safe to call repeatedly
    }

    // 2. Decode the old layout from the front (ignore trailing bytes).
    let old = {
        let data = vault_ai.try_borrow_data()?;
        VaultV1::deserialize(&mut &data[8..])
            .map_err(|_| error!(MyError::AccountDidNotDeserialize))?
    };

    // 3. Grow and top up rent for the larger size, then realloc.
    let new_len = 8 + Vault::INIT_SPACE;
    let needed = Rent::get()?.minimum_balance(new_len);
    let current = vault_ai.lamports();
    if needed > current {
        anchor_lang::system_program::transfer(
            CpiContext::new(
                ctx.accounts.system_program.to_account_info(),
                anchor_lang::system_program::Transfer {
                    from: ctx.accounts.payer.to_account_info(),
                    to: vault_ai.clone(),
                },
            ),
            needed - current,
        )?;
    }
    vault_ai.realloc(new_len, false)?; // we overwrite the whole body below

    // 4. Write the new layout. try_serialize writes discriminator + borsh body.
    let migrated = Vault {
        version: VAULT_VERSION,
        authority: old.authority,
        amount: old.amount,
        locked_until: 0, // default for the new field
    };
    let mut data = vault_ai.try_borrow_mut_data()?;
    let mut cursor = std::io::Cursor::new(&mut data[..]);
    migrated.try_serialize(&mut cursor)?;
    Ok(())
}
```

After migration the account carries `version = 2` and the full new layout. Every
later instruction can safely type it as `Account<'info, Vault>` once you are
confident all accounts are migrated, or keep the version branch for as long as
old accounts may exist.

## Idempotency

A migration must be a **no-op when run again**. Two callers (or a retried crank
transaction) must not double-apply it.

- Always gate on `stored_version < CURRENT` and return early otherwise (step 1
  above).
- Set the new version as part of the same write (step 4). Never migrate without
  bumping the version.
- This makes the instruction safe to fan out over a crank and safe to retry. Prove
  it in tests: run the migration twice and assert the second call changes nothing
  (`fork-simulation.md`).

## Growing vs shrinking and rent direction

Rent-exemption scales with size, so resizing moves lamports:

- **Growing**: `minimum_balance(new_len) > current` - transfer the difference
  **into** the account (from `realloc::payer` / your payer) so it stays
  rent-exempt. The Anchor constraint does this for you; the manual path does it in
  step 3.
- **Shrinking**: `minimum_balance(new_len) < current` - the excess is **refunded
  to** `realloc::payer`. With the constraint this is automatic; manually you debit
  the account and credit the payer.

Note: shrinking discards the bytes past the new length. If real data lives there,
you cannot shrink in place without losing it - copy to a new account instead
(`migration-strategies.md`).

## The `realloc::zero = false` footgun

`realloc::zero = false` does **not** guarantee the newly exposed bytes are zero.
The runtime zeroes appended bytes at the start of an instruction, but **not**
across multiple reallocs within the same instruction - so reused memory can hold
**stale bytes**. If you grow an account and then read the new region without
writing it, you may read garbage.

Two safe rules:

- If you **overwrite the whole body** during migration (as above), `false` is
  correct and cheaper.
- If you grow and **rely on the new region being zero** without writing it, set
  `realloc::zero = true`, or zero it yourself.

Confirm the exact zeroing behavior against your Anchor and runtime versions before
depending on it.

## The ~10 KB per-transaction growth cap

An account can grow by at most **`MAX_PERMITTED_DATA_INCREASE` = 10,240 bytes
(10 KB) per transaction**. A single `realloc` (or the sum of reallocs in one tx)
that exceeds this fails.

```rust
use anchor_lang::solana_program::entrypoint::MAX_PERMITTED_DATA_INCREASE; // = 10 * 1024
```

For migrations this rarely matters (you usually add a small field). When you must
grow a large account past 10 KB, do it in **multiple transactions**, each adding
up to 10 KB, advancing toward the target length:

```rust
let step = (target_len - current_len).min(MAX_PERMITTED_DATA_INCREASE);
let next_len = current_len + step;
// fund rent for next_len, realloc to next_len, repeat in the next tx
```

Make each step idempotent and resumable (store progress) - see the crank pattern
in `migration-strategies.md`.

## Lazy vs eager

The same `touch_vault` body serves both: call it **lazily** from real
instructions (migrate-on-touch, zero upfront cost, old accounts linger until
used) or call it from an **eager** crank that pages over every account (clean
cutover, costs transactions proportional to account count). Pick per account
count and downtime tolerance in `migration-strategies.md`.

## Native manual equivalent

No Anchor sugar: you own the version byte, `realloc`, and the rent transfer.

```rust
use solana_program::{
    account_info::AccountInfo, program::invoke, program_error::ProgramError,
    rent::Rent, system_instruction, sysvar::Sysvar,
};

pub fn migrate_native(
    vault: &AccountInfo,
    payer: &AccountInfo,
    system_program: &AccountInfo,
    new_len: usize,
) -> Result<(), ProgramError> {
    if vault.owner != &crate::ID {
        return Err(ProgramError::IllegalOwner); // can only realloc your own accounts
    }

    let needed = Rent::get()?.minimum_balance(new_len);
    let current = vault.lamports();

    if needed > current {
        // grow: fund rent from the payer (system-owned signer) into the account
        invoke(
            &system_instruction::transfer(payer.key, vault.key, needed - current),
            &[payer.clone(), vault.clone(), system_program.clone()],
        )?;
    } else if current > needed {
        // shrink: refund the freed rent directly (both accounts we control)
        let refund = current - needed;
        **vault.try_borrow_mut_lamports()? -= refund;
        **payer.try_borrow_mut_lamports()? += refund;
    }

    vault.realloc(new_len, false)?; // same 10 KB/tx cap applies
    // ...then read old bytes (front cursor), write the new layout + version byte.
    Ok(())
}
```

The version branching and old/new borsh decode are in `account-versioning.md`
(native section). Everything Anchor does automatically (rent top-up, resize,
serialize) you do explicitly here.

## Common errors

| Error / symptom | Cause | Fix |
| --- | --- | --- |
| `AccountDidNotDeserialize` using `Account<NewType>` + realloc constraint | Anchor deserializes the new type from old, shorter bytes before realloc runs | Migrate in the body via `UncheckedAccount` (above), or use the `Migration` type |
| realloc fails / "data increase exceeds maximum" | Grew more than 10,240 bytes in one transaction | Split the growth across multiple transactions, each adding up to 10 KB |
| Account no longer rent-exempt after grow | Resized without topping up lamports | Transfer `minimum_balance(new_len) - current` into the account before/after realloc |
| New field reads as garbage | Assumed `realloc::zero = false` leaves zeros | Overwrite the new region explicitly, or set `realloc::zero = true` |
| `IllegalOwner` / realloc rejected (native) | Tried to realloc an account your program does not own | Only resize program-owned accounts |
| Migration double-applies or version resets | Missing `version < CURRENT` guard | Gate on the stored version and bump it in the same write |
| Lamports lost / payer not refunded on shrink | Forgot to move freed rent back | Use `realloc::payer` (Anchor) or debit/credit lamports manually (native) |

Next: the `Migration` type sugar in `anchor-migration-type.md`, or pick lazy vs
eager vs copy-to-new in `migration-strategies.md`.
