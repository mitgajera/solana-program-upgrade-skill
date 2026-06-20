# Migration Strategies

Pick the migration approach *before* you write code - it determines your
versioning, your instructions, and your operational cost. There are three core
strategies; the right one depends on account count, downtime tolerance, and rent.

## Selection table

| | Eager (one-shot crank) | Lazy (migrate-on-touch) | Copy-to-new-account |
| --- | --- | --- | --- |
| **How** | A keeper cranks a migrate ix over every account up front | Each account migrates the first time an instruction touches it | Create a new account in the new layout, copy data, close the old |
| **Best when** | Small/medium account count; you want a clean cutover | Large count; not every account is active; no downtime budget | Layout change is impossible in place (shrink past data, type change, new PDA seeds) |
| **Upfront cost** | High: txs + rent proportional to account count | None: spread over normal usage | High: rent for new accounts (old rent refunded on close) |
| **Time to "done"** | Bounded (you finish the crank) | Unbounded (stale accounts linger until touched) | Bounded per account, but two-step |
| **Old-version branch** | Drop it soon after the crank completes | Keep it indefinitely | Drop once all old accounts are closed |
| **Downtime** | Optional brief pause for a clean cutover | None | None (per-account swap) |
| **Complexity** | Medium (crank + progress tracking) | Low (one guarded branch) | High (new accounts, pointer updates, closes) |
| **In-place?** | Yes (`realloc`) | Yes (`realloc`) | No (new account) |

Default: **lazy** for large or mostly-idle account sets; **eager** when the count
is manageable and you want to retire the old branch; **copy-to-new** only when an
in-place change is impossible.

## When in-place `realloc` is impossible

`realloc` can only grow/shrink the same account and reinterpret its bytes. It
cannot help when:

- **Shrinking past real data.** Removing a field shifts everything after it;
  shrinking discards the tail. The bytes are gone - you cannot recover the moved
  fields in place.
- **Type changes / reordering.** Changing a field's width or position misaligns
  every later field. There is no in-place reinterpretation that fixes this.
- **PDA seed changes.** If the new design derives the account from different
  seeds, it is a different address - by definition a new account.
- **Owner/program changes.** Moving accounts under a new program id (see
  `program-deploy-upgrade.md`) means new accounts owned by the new program.

In all of these, use **copy-to-new-account**: read the old account, create a new
one with the new layout, write the translated data, then `close` the old account
(refunding its rent to the user/payer). Keep the old account until the new one is
verified - never close before the copy is confirmed.

```rust
// Sketch: copy-to-new. Old account is read-only here; new account is init'd to
// the new layout, then the old is closed (rent refunded to `receiver`).
#[derive(Accounts)]
pub struct CopyMigrate<'info> {
    #[account(mut, close = receiver)]          // refund old rent on close
    pub old: Account<'info, VaultV1>,
    #[account(init, payer = payer, space = 8 + VaultV2::INIT_SPACE,
              seeds = [b"vault_v2", old.authority.as_ref()], bump)]
    pub new: Account<'info, VaultV2>,
    #[account(mut)]
    pub payer: Signer<'info>,
    /// CHECK: rent receiver
    #[account(mut)]
    pub receiver: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}
```

## Batch migration via keeper / crank (large sets)

For eager migration of a large account set, a keeper pages through accounts and
submits migrate transactions. Make it boring and resumable.

- **Enumerate** the target accounts with `getProgramAccounts` plus a **memcmp
  filter on the version byte** (offset 8 for a leading version byte after the
  discriminator) so you only fetch the not-yet-migrated ones. Use `dataSlice` to
  fetch minimal bytes when you only need keys.
- **Paginate** in fixed-size pages (e.g. a few hundred accounts) and batch several
  migrate ixs per transaction (respecting the 1232-byte tx size and compute
  limits). Confirm each batch before advancing.
- **Idempotency is mandatory** - each migrate ix is a no-op when `version >=
  CURRENT` (`realloc-migration.md`). This makes retries and overlapping keepers
  safe.
- **Rate-limit** to your RPC's capacity; add priority fees if you need the crank to
  land promptly. Spread load to avoid throttling.
- **Progress metric:** the count of accounts still on the old version. It must
  trend to zero:
  ```
  remaining = getProgramAccounts(programId, { filters: [memcmp(offset=8, byte=0x01)] }).length
  ```
  Log `migrated / total` each page; migration is done when `remaining == 0`.
- **Resumable:** because enumeration filters on the version byte, a crashed keeper
  just restarts and picks up the remaining accounts. No external checkpoint needed.

## Cost, downtime, and rent

Choose by weighing three axes:

- **Account count.** Tens of accounts: eager is trivial. Tens of thousands: eager
  costs real SOL and time (one+ tx per account); lazy amortizes it to zero upfront,
  or copy-to-new if you must. For the "~40k accounts" case, lazy (if accounts are
  touched in normal use) or a rate-limited eager crank with priority fees is the
  cheapest safe path - simulate the cost on a fork first (`fork-simulation.md`).
- **Downtime tolerance.** Lazy and copy-to-new need no downtime. Eager can run live
  (with a both-versions branch) or behind a brief pause for a clean cutover - your
  call.
- **Rent.** Growing accounts requires rent top-up (paid by your payer or the user);
  shrinking refunds it. Copy-to-new pays new-account rent but refunds the old on
  close, so net rent is roughly the size delta. Decide who pays: protocol-funded
  (you eat it, smoother UX) vs user-funded (charged when they touch the account,
  natural fit for lazy).

Rule of thumb: **lazy** unless you need a hard cutover; **eager** for manageable
counts where retiring the old branch matters; **copy-to-new** only when the layout
change cannot happen in place. Whichever you pick, prove it on a fork before
mainnet.

## Common errors

| Error / symptom | Cause | Fix |
| --- | --- | --- |
| Eager crank too expensive / slow | One tx per account at scale | Switch to lazy, or batch ixs per tx and rate-limit with priority fees |
| Crank never finishes | Not filtering on the version byte; re-processing migrated accounts | Enumerate with a memcmp filter on the version; track `remaining` to zero |
| Tried to shrink an account and lost data | In-place realloc discards the tail | Use copy-to-new-account; never shrink past real data in place |
| New PDA can't find old data | Changed seeds = different address | Copy-to-new under the new seeds; migrate the pointer/refs |
| Old account rent stuck after copy | Forgot to close the old account | `close = receiver` to refund rent once the new account is verified |
| Mixed versions confuse the program | Dropped the old-version branch too early | Keep both-version handling until `remaining == 0` |

Next: implement the chosen approach (`realloc-migration.md` or
`anchor-migration-type.md`), then prove it on a fork (`fork-simulation.md`).
