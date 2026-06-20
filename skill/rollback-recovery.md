# Rollback & Recovery

When an upgrade goes wrong, you need a plan you wrote *before* the incident, not
one you improvise while accounts are corrupting. Read this as an incident-response
playbook: the asymmetry to internalize is that **code is reversible, on-chain data
usually is not**. You can almost always redeploy the old `.so`; you often cannot
un-migrate the bytes. Design for that asymmetry up front.

> Verify any CLI here against your version (`solana program deploy --help`,
> `solana program show`). Default every command to devnet/localnet while
> rehearsing; only run against mainnet during a real, confirmed incident.

## Contents

- [The reversibility asymmetry](#the-reversibility-asymmetry)
- [Before you ship: prepare the rollback](#before-you-ship-prepare-the-rollback)
- [Incident response: roll back the code](#incident-response-roll-back-the-code)
- [Why data migration is usually forward-only](#why-data-migration-is-usually-forward-only)
- [Recovering a half-migrated account set](#recovering-a-half-migrated-account-set)
- [The migration-guard / pause feature flag](#the-migration-guard--pause-feature-flag)
- [Emergency pause](#emergency-pause)
- [Post-incident verification](#post-incident-verification)
- [Common errors](#common-errors)

## The reversibility asymmetry

- **Code rollback is cheap and fast.** The previous `.so` redeploys to the same
  program id in one upgrade. The program id, PDAs, and accounts are untouched.
- **Data rollback is usually impossible.** A migration that overwrote bytes
  (resized, rewrote fields) has discarded the old layout. There is no general
  "undo" - the old bytes are gone.

Therefore: make code rollback trivially available, and make data changes
**additive and resumable** so that "roll back" usually means "redeploy old code +
stop the migration," not "restore old data."

## Before you ship: prepare the rollback

Do all of this *before* the upgrade, as part of the release:

- **Archive the currently-deployed `.so`.** Pull the live binary so you can
  redeploy the exact bytes that are working now:
  ```bash
  solana program dump <PROGRAM_ID> prev_program.so --url devnet
  ```
  Store `prev_program.so` (and ideally the matching commit/tag) somewhere durable.
- **Record current state:** `solana program show <PROGRAM_ID>` (authority, data
  length, deployed slot) so you can confirm a clean revert later.
- **Keep the prior buffer** if you used the buffer flow - a pre-written old buffer
  makes re-upgrade instant.
- **Have the authority ready to act.** If a Squads multisig controls upgrades,
  pre-stage the rollback proposal or ensure signers are reachable; a timelock that
  protects you normally can slow an emergency, so plan for it.

## Incident response: roll back the code

When the new code misbehaves, redeploy the archived old `.so` to the same id:

```bash
# Redeploy the previous, known-good binary in place (devnet shown).
solana program deploy prev_program.so \
  --program-id <PROGRAM_ID> \
  --upgrade-authority <AUTHORITY_KEYPAIR> \
  --url devnet
```

Through a multisig, this is a normal Program Upgrade proposal pointing at a buffer
of the old `.so` (`upgrade-authority.md`). After redeploy, confirm with
`solana program show` that the deployed slot advanced and the data length matches
the old binary.

Caveat: if the bad code already **migrated some accounts** to a new layout, the
old code may not understand those accounts. Rolling back the code does not roll
back the data - see the next two sections. This is exactly why you keep a version
branch and design migrations to be forward-compatible with the old reader where
possible.

## Why data migration is usually forward-only

A migration rewrites account bytes in place. Once `realloc` + reserialize has run,
the old field order/sizes are overwritten; shrinking discards the tail entirely.
There is no stored copy to restore from. Consequences for design:

- **Prefer additive changes** (append fields) so the old reader can still parse
  the prefix if you must roll the code back.
- **Never destroy information you might need.** If a change is lossy (removing or
  retyping a field), copy to a **new account** and keep the old one until you are
  certain (`migration-strategies.md`), rather than overwriting in place.
- **Make it resumable** so a partial run can be finished or safely abandoned,
  never leaving accounts in an unreadable state.

Assume forward-only. Your "rollback" for data is a forward fix-up migration, not a
restore.

## Recovering a half-migrated account set

A batch/eager crank can stop mid-run (failed tx, RPC limits, ran out of funds),
leaving some accounts on v2 and some on v1. The version tag is what saves you.

- **The program must handle both versions** for the entire migration window. Every
  instruction branches on the stored version (`account-versioning.md`); never
  assume all accounts are migrated until you have proven it.
- **Resume, do not restart.** The crank is idempotent (each account migrates only
  when `version < CURRENT`), so simply re-run it - already-migrated accounts are
  skipped, remaining ones get done.
- **Track progress** so you know what is left:
  ```bash
  # Count accounts still on the old version (filter on the version byte's offset).
  # memcmp offset = 8 (discriminator) for a leading version byte; value 01 = v1.
  solana program show --programs --url devnet   # sanity-check the program first
  # Then use getProgramAccounts with a memcmp filter { offset: 8, bytes: "<base58 of 0x01>" }
  ```
  Migration is complete when the v1 count reaches zero. Keep cranking until then.
- **Only drop the old-version branch** from the code after the count is zero and
  you have confirmed it on a fork/devnet snapshot.

## The migration-guard / pause feature flag

Give yourself a kill switch so a discovered problem does not keep corrupting
accounts while you respond. Store a flag in a config/global account the program
checks:

```rust
#[account]
pub struct Config {
    pub admin: Pubkey,
    pub migration_paused: bool, // flip to halt migrations instantly
    pub paused: bool,           // flip to halt sensitive user instructions
}

pub fn migrate(ctx: Context<Migrate>) -> Result<()> {
    require!(!ctx.accounts.config.migration_paused, MyError::MigrationPaused);
    // ... idempotent migration body ...
    Ok(())
}
```

Flipping `migration_paused` is a tiny, fast transaction (and can itself be behind
the multisig). It stops new migrations without redeploying code - the first lever
you reach for in an incident.

## Emergency pause

For a serious incident (suspected corruption, exploit, draining), pause the
sensitive instructions too:

- Gate withdrawals/state-changing instructions on `!config.paused` with an early
  `require!`.
- Make `set_paused` callable by an admin or multisig, ideally with a lower
  threshold than upgrades so you can react fast.
- Pausing is reversible and instant; a code rollback is heavier. Pause first to
  stop the bleeding, then diagnose, then roll back or fix forward.
- Communicate: announce the pause and the reason. A silent freeze erodes trust
  faster than an explained one.

## Post-incident verification

Before unpausing and declaring it over:

- **Re-run fork simulation** (`fork-simulation.md`) of the corrected upgrade
  against cloned current mainnet state; diff bytes; prove idempotency.
- **Confirm the deployed code:** `solana program show` shows the expected slot and
  size; the upgrade authority is still the intended multisig.
- **Audit the account set:** the v1 count is zero (or matches your lazy-migration
  expectation), and a sample of accounts deserialize correctly under the new code.
- **Verify no value moved unexpectedly** during the incident (balances, supply,
  vault totals reconcile).
- **Unpause deliberately**, then watch metrics. Write the post-mortem: what broke,
  why the fork test missed it, what guard you are adding so it cannot recur.

## Common errors

| Error / symptom | Cause | Fix |
| --- | --- | --- |
| No old binary to roll back to | Forgot to archive the live `.so` before upgrading | `solana program dump` the current binary as part of every release, before deploying |
| Rolled back code, accounts still broken | Bad code already migrated some accounts; old code can't read them | Keep a both-versions branch; fix forward with a corrective migration |
| Crank died partway, accounts in mixed versions | Non-resumable or non-idempotent migration | Re-run the idempotent crank; it skips migrated accounts and finishes the rest |
| Cannot stop an in-progress bad migration | No pause flag | Add a `migration_paused` guard now; flip it to halt instantly |
| Emergency action blocked by upgrade timelock | Same high threshold/timelock as normal upgrades | Use a separate, faster `pause` path; reserve the timelock for code upgrades |
| Unpaused too early, problem recurred | Skipped post-incident verification | Re-simulate on a fork and audit accounts before unpausing |

This closes the lifecycle: version (`account-versioning.md`), migrate
(`realloc-migration.md`), simulate (`fork-simulation.md`), secure
(`upgrade-authority.md`), deploy (`program-deploy-upgrade.md`), and recover (here).
Choose the overall approach in `migration-strategies.md`.
