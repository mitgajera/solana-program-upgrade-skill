# Account Versioning

Version your on-chain account data **before** you ever need to change it. A
deployed program's accounts are raw bytes interpreted by the current code; the
moment new code reads old bytes with a changed layout you get
`AccountDidNotDeserialize`, wrong values, or silent corruption. A version tag is
what lets new code recognize old accounts and migrate them deliberately instead
of misreading them.

> Verify every API below against your installed versions: `anchor --version`,
> and the `borsh` / `solana-program` versions in `Cargo.lock`. Helper names and
> module paths move between releases - confirm before relying on them.

## Contents

- [Why the discriminator is not a version](#why-the-discriminator-is-not-a-version)
- [Pattern 1: leading `version: u8`](#pattern-1-leading-version-u8)
- [Pattern 2: enum-tagged state](#pattern-2-enum-tagged-state)
- [Safe vs breaking changes](#safe-vs-breaking-changes)
- [`try_from_slice` vs `try_from_slice_unchecked`](#try_from_slice-vs-try_from_slice_unchecked)
- [The AccountV1 / AccountV2 pattern](#the-accountv1--accountv2-pattern)
- [Native / borsh manual equivalent](#native--borsh-manual-equivalent)
- [Common errors](#common-errors)

## Why the discriminator is not a version

Anchor prepends an **8-byte discriminator** to every `#[account]` type:
`sha256("account:<StructName>")[..8]`. On deserialize, Anchor checks those 8
bytes match the expected type and rejects the account otherwise
(`AccountDiscriminatorMismatch`).

It gates **type**, not **version**. If you keep the struct name `Vault` but add a
field, the discriminator is identical - so Anchor happily accepts an old, shorter
account and then fails *inside* borsh when it runs out of bytes for the new
field. The discriminator cannot tell you "this is an old layout." You need your
own version marker for that.

## Pattern 1: leading `version: u8`

The portable default. Put a version byte first in the data so any code can read
it cheaply and branch.

```rust
use anchor_lang::prelude::*;

pub const VAULT_VERSION: u8 = 2;

#[account]
#[derive(InitSpace)]
pub struct Vault {
    pub version: u8,        // bump this whenever the layout changes
    pub authority: Pubkey,
    pub amount: u64,
    // v2 additions (always append at the end):
    pub locked_until: i64,
}

impl Vault {
    pub fn needs_migration(&self) -> bool {
        self.version < VAULT_VERSION
    }
}
```

Branch on the stored version when you touch the account (lazy migration lives in
`realloc-migration.md`):

```rust
if vault.version < VAULT_VERSION {
    // run the migration, then:
    vault.version = VAULT_VERSION;
}
```

Why a `u8` first: it is one byte, it never moves (always the first field), and it
costs nothing to read. Reserve room (e.g. up to 255 versions) - you will not run
out.

## Pattern 2: enum-tagged state

Borsh serializes an enum as a single **variant-index byte** followed by that
variant's fields. That leading byte doubles as a version tag, and the type system
forces you to handle every version.

```rust
use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub enum VaultState {
    V1 { authority: Pubkey, amount: u64 },
    V2 { authority: Pubkey, amount: u64, locked_until: i64 },
}

#[account]
pub struct Vault {
    pub state: VaultState,
}

impl VaultState {
    pub fn migrate(self) -> VaultState {
        match self {
            VaultState::V1 { authority, amount } => VaultState::V2 {
                authority,
                amount,
                locked_until: 0, // sensible default for the new field
            },
            v2 => v2,
        }
    }
}
```

Trade-off: cleaner exhaustiveness and explicit upgrades, but every read pattern
matches on the enum, and the account size varies by variant. Use it when versions
differ structurally, not just by an appended field.

## Safe vs breaking changes

Borsh is positional: fields are written back-to-back in declaration order with no
field names on chain. So the only safe edit to a live layout is **appending**.

| Change | Safe? | Why |
| --- | --- | --- |
| Append a new field at the **end** | Yes (additive) | Old bytes still decode; new field needs a default + migration to populate |
| Add a field in the **middle** | No | Shifts every later field; old bytes misalign |
| **Reorder** fields | No | Same byte positions now mean different fields |
| **Remove** a field | No | Later fields shift left; sizes mismatch |
| **Retype** a field (`u32` -> `u64`) | No | Byte width changes; everything after shifts |
| Rename a field (same type/position) | Yes | Names are not stored on chain |
| Rename the **struct** | No (Anchor) | Changes the discriminator; old accounts rejected |

Even an additive change still requires growing the account (`realloc`) and a
migration to fill the new field - "safe" means it does not corrupt, not that it
is free. Anything in the No rows requires copy-to-new-account (see
`migration-strategies.md`), never an in-place edit.

## `try_from_slice` vs `try_from_slice_unchecked`

This distinction bites during migration because a migrated account is often
**larger than its current data** (zero-padded after `realloc`).

- `BorshDeserialize::try_from_slice(&data)` deserializes **and requires every
  byte to be consumed**. Trailing/padding bytes cause `Not all bytes read`. Do
  not use it on a padded or over-sized account buffer.
- `try_from_slice_unchecked` (a `solana_program` borsh helper) deserializes from
  the front and **ignores trailing bytes** - the right tool for reading an
  account whose buffer is bigger than the struct. The exact module path is
  version-specific (historically under `solana_program::borsh*`); confirm the one
  your `solana-program` exposes rather than guessing.

Inside Anchor, `Account<'info, T>` does not call `try_from_slice`. The `#[account]`
macro generates `try_deserialize` (check discriminator, then a cursor-based
`AnchorDeserialize::deserialize` that tolerates trailing bytes), which is why
Anchor accounts can legally be larger than their data. When you read **old** bytes
manually during a migration, mirror that: deserialize from the front, do not
demand exact length.

## The AccountV1 / AccountV2 pattern

Use this when the change is breaking and you must read the old layout explicitly,
then write the new one. Keep the deserialization structs separate so each is an
exact picture of one layout.

```rust
use anchor_lang::prelude::*;

// Old layout - kept only so we can decode existing bytes.
#[derive(AnchorDeserialize)]
pub struct VaultV1 {
    pub authority: Pubkey,
    pub amount: u64,
}

// Current on-chain type.
#[account]
#[derive(InitSpace)]
pub struct Vault {
    pub version: u8,
    pub authority: Pubkey,
    pub amount: u64,
    pub locked_until: i64,
}

pub fn migrate_v1_to_v2(data_after_discriminator: &[u8]) -> Result<Vault> {
    // Decode old bytes from the front (ignore trailing padding).
    let old = VaultV1::deserialize(&mut &data_after_discriminator[..])?;
    Ok(Vault {
        version: 2,
        authority: old.authority,
        amount: old.amount,
        locked_until: 0,
    })
}
```

**Discriminator caveat:** if `VaultV1` had been a real `#[account] struct VaultV1`
its discriminator would differ from `Vault`, and existing accounts (written with
the `Vault` discriminator) would not match it. Keep the live struct name stable
(`Vault`) and treat `VaultV1` as a plain deserialize-only struct, not an
`#[account]`. The discriminator on disk stays `Vault`'s throughout.

## Native / borsh manual equivalent

No Anchor sugar: you own the discriminator (if any), the version byte, and the
length checks. Branch on the first data byte.

```rust
use borsh::{BorshDeserialize, BorshSerialize};
use solana_program::{account_info::AccountInfo, program_error::ProgramError};

#[derive(BorshSerialize, BorshDeserialize)]
pub struct VaultV1 { pub authority: [u8; 32], pub amount: u64 }

#[derive(BorshSerialize, BorshDeserialize)]
pub struct VaultV2 { pub authority: [u8; 32], pub amount: u64, pub locked_until: i64 }

pub fn load_vault(acc: &AccountInfo) -> Result<VaultV2, ProgramError> {
    let data = acc.try_borrow_data()?;
    let version = *data.first().ok_or(ProgramError::InvalidAccountData)?;
    let body = &data[1..]; // first byte is our version tag
    match version {
        1 => {
            let v1 = VaultV1::try_from_slice(body)
                .map_err(|_| ProgramError::InvalidAccountData)?;
            Ok(VaultV2 { authority: v1.authority, amount: v1.amount, locked_until: 0 })
        }
        2 => VaultV2::try_from_slice(body).map_err(|_| ProgramError::InvalidAccountData),
        _ => Err(ProgramError::InvalidAccountData),
    }
}
```

In native code you must also handle the version byte on **write**, resize with
`AccountInfo::realloc`, and top up rent yourself (see `realloc-migration.md`).
There is no discriminator unless you add one - many native programs use the
leading version byte as their only tag.

## Common errors

| Error / symptom | Cause | Fix |
| --- | --- | --- |
| `AccountDidNotDeserialize` after an upgrade | New struct expects more/rearranged bytes than the old account holds | Add a version tag, read old bytes with the old layout, migrate, then write new layout |
| `Not all bytes read` | Used `try_from_slice` on a padded / over-sized buffer | Use `try_from_slice_unchecked` (or front-cursor `deserialize`) for over-sized accounts |
| `AccountDiscriminatorMismatch` | Renamed the `#[account]` struct, or read with the wrong account type | Keep the struct name stable; use a deserialize-only `VaultV1`, not a second `#[account]` |
| New field reads as garbage / wrong values | Field added in the middle or fields reordered | Only append at the end; for anything else, copy to a new account (`migration-strategies.md`) |
| Migration runs every time / double-applies | No idempotency guard | Gate on `version < CURRENT` and set the version after migrating |
| Old amounts look shifted/huge | Retyped a field width (e.g. `u32` -> `u64`) | Treat as breaking; migrate via explicit V1 -> V2 decode/encode |

Next: implement the actual resize and lazy migration in `realloc-migration.md`,
or pick the overall approach in `migration-strategies.md`.
