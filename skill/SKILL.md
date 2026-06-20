---
name: solana-program-upgrade
description: >-
  Safely upgrade live Solana programs and migrate on-chain account data without
  bricking the program or corrupting user accounts. Use whenever the user changes
  an `#[account]` struct (adds/removes/reorders/retypes fields), redeploys or
  upgrades a deployed program, hits a size-mismatch or `AccountDidNotDeserialize`
  error after an upgrade, works with `realloc`/buffer accounts/`solana program
  extend`, manages upgrade authority or a Squads multisig, makes a program
  `--final`/immutable, or plans, simulates, or rolls back a program upgrade -
  even if they never say the word "migration." Trigger on any program upgrade,
  redeploy, account layout change, schema change, or upgrade-authority topic.
---

# solana-program-upgrade

Upgrade a live Solana program and migrate its on-chain account data **safely** -
versioning, lazy `realloc` migration, fork simulation, upgrade-authority hygiene,
and rollback. This is the single most catastrophic lifecycle step in Solana dev,
made survivable.

> **Addon to [`solana-dev-skill`](https://github.com/solana-foundation/solana-dev-skill).**
> That skill owns greenfield Anchor/Pinocchio/testing basics. This one owns only
> the **upgrade + migration lifecycle** - reach for it once a program is already
> deployed and needs to change.

---

## Golden rules (the safety spine)

1. **Never change a live account layout without a version tag + migration path.**
   Old accounts are raw bytes; new code reading them with a changed struct →
   `AccountDidNotDeserialize` or silent corruption. The 8-byte discriminator
   gates *type*, not *version*.
2. **Simulate against real cloned mainnet state before mainnet.** Always run the
   exact upgrade + migration on a fork first and diff account bytes. No exceptions.
3. **Multisig the upgrade authority.** A single hot key that can replace all
   program logic is a rug/compromise vector. Move it to Squads v4.
4. **On-chain data migrations are usually forward-only.** Design additive and
   resumable; do not assume you can revert data.
5. **Keep the previous `.so`.** You can always roll back the *code* fast even when
   the *data* can't be reverted.
6. **Default to devnet/localnet/fork.** Never auto-target mainnet in any example.

---

## The upgrade workflow

Follow in order. Each step routes to a focused file for depth.

1. **Diff the schema** - compare old vs new `#[account]` structs. Identify
   additive vs breaking changes (reorder/remove/retype = breaking).
2. **Pick a strategy** - eager crank vs lazy migrate-on-touch vs copy-to-new
   account → `migration-strategies.md`.
3. **Write versioned structs** - add a version tag, branch on stored version →
   `account-versioning.md`.
4. **Implement the migration** - manual `realloc` (portable baseline) →
   `realloc-migration.md`; or the Anchor `Migration` type *if your version has it*
   → `anchor-migration-type.md`.
5. **Simulate on a fork** - clone real accounts, run the upgrade, diff bytes,
   assert idempotency → `fork-simulation.md`.
6. **Secure the authority** - verify/move to Squads multisig before touching
   mainnet → `upgrade-authority.md`.
7. **Deploy the binary** - buffer flow, `extend` if larger, IDL, `--final` →
   `program-deploy-upgrade.md`.
8. **Verify & keep a rollback plan** - confirm accounts deserialize; retain prior
   `.so` and a half-migration recovery path → `rollback-recovery.md`.

---

## Routing table

Find the row that matches the situation and read that file.

| Symptom / task | Read |
| --- | --- |
| `AccountDidNotDeserialize` / size mismatch / wrong values after an upgrade | `account-versioning.md`, then `realloc-migration.md` |
| Added/removed/reordered/retyped a field on an `#[account]` struct | `account-versioning.md` |
| "How do I version my account so I can change it later?" | `account-versioning.md` |
| Need to grow/shrink an existing account in place | `realloc-migration.md` |
| Lazy "migrate-on-touch" vs eager one-shot migration | `realloc-migration.md`, `migration-strategies.md` |
| `realloc::zero` stale-bytes footgun / rent top-up direction | `realloc-migration.md` |
| Per-instruction 10 KB realloc growth limit, large grows | `realloc-migration.md` |
| Want the new Anchor `Migration<'info, From, To>` type | `anchor-migration-type.md` |
| `AccountAlreadyMigrated` / `AccountNotMigrated` errors | `anchor-migration-type.md` |
| Choosing eager vs lazy vs copy-to-new-account | `migration-strategies.md` |
| Migrating a large account set (e.g. tens of thousands) cheaply | `migration-strategies.md` |
| Batch/crank/keeper migration, pagination, progress tracking | `migration-strategies.md` |
| In-place realloc impossible (shrinking past data, type change) | `migration-strategies.md` |
| Redeploying / upgrading the program binary | `program-deploy-upgrade.md` |
| `solana program write-buffer` / `deploy --buffer` flow | `program-deploy-upgrade.md` |
| New `.so` is bigger than the deployed one (`solana program extend`) | `program-deploy-upgrade.md` |
| Upgrading the IDL (`anchor idl upgrade`) | `program-deploy-upgrade.md` |
| Deploy-in-place vs new program id (effect on PDAs/accounts) | `program-deploy-upgrade.md` |
| Who controls the program? Single key vs multisig | `upgrade-authority.md` |
| Move upgrade authority to a Squads v4 multisig | `upgrade-authority.md` |
| `set-upgrade-authority`, timelock, key management | `upgrade-authority.md` |
| Make the program immutable (`--final`) and what it costs | `upgrade-authority.md` |
| Test the upgrade before mainnet / clone real state | `fork-simulation.md` |
| Surfpool mainnet fork; diff account bytes pre/post | `fork-simulation.md` |
| LiteSVM / Mollusk unit tests for the migration instruction | `fork-simulation.md` |
| Prove the migration is idempotent (running twice = no-op) | `fork-simulation.md` |
| Upgrade went wrong - get the old code back fast | `rollback-recovery.md` |
| Half-migrated account set; resume safely | `rollback-recovery.md` |
| Pause / migration-guard / emergency feature flag | `rollback-recovery.md` |
| Native / Pinocchio program (no Anchor sugar) | `realloc-migration.md`, `account-versioning.md` |
| Authoritative links & docs (verify current) | `resources.md` |

---

## Companion tools

- **Commands:** `/plan-upgrade` (schema diff → migration plan + risk report),
  `/simulate-upgrade` (fork, clone, run, diff), `/check-upgrade-authority`
  (audit single-key vs multisig).
- **Agents:** `program-migration-architect` (design the migration from a schema
  diff), `migration-qa-engineer` (write fork/LiteSVM tests, verify no corruption).
- **Rule:** `account-layout-guard` auto-fires on edits to `#[account]` structs /
  `state.rs` and requires a version bump + migration path.

---

## Accuracy contract

Every CLI flag, Anchor constraint, crate, and account type in the routed files
must be **real and verifiable**. When unsure, verify against the *installed*
versions (`anchor --version`, `solana --version`, the Anchor changelog) - never
invent. Treat the `Migration` type as possibly-unreleased; the manual `realloc`
pattern is the portable default.
