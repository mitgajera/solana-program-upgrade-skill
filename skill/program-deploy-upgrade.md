# Program Deploy & Upgrade

Upgrading the binary is the step that replaces your program's code on chain. Get
the account-data migration right first (the rest of this skill); this file is the
mechanics of shipping the new `.so` safely. Every example targets **devnet or
localnet** - never mainnet by default.

> Verify flags against your installed CLI: run `solana --version`, then
> `solana program deploy --help`, `solana program write-buffer --help`, and
> `solana program extend --help`. Flag names and defaults shift between releases;
> confirm before scripting anything.

## Contents

- [The BPFLoaderUpgradeable model](#the-bpfloaderupgradeable-model)
- [Direct deploy / upgrade](#direct-deploy--upgrade)
- [The buffer flow (preferred for real upgrades)](#the-buffer-flow-preferred-for-real-upgrades)
- [Extending program size when the .so grew](#extending-program-size-when-the-so-grew)
- [Checking program account size](#checking-program-account-size)
- [Anchor upgrade and IDL upgrade](#anchor-upgrade-and-idl-upgrade)
- [`--final` immutability and its tradeoff](#--final-immutability-and-its-tradeoff)
- [Redeploy in place vs deploy a new program id](#redeploy-in-place-vs-deploy-a-new-program-id)
- [Common errors](#common-errors)

## The BPFLoaderUpgradeable model

An upgradeable program is stored across two accounts:

- The **program account** (the program id you call) - small, points to its data.
- The **program data account** (a PDA of the program) - holds the actual `.so`
  bytes and records the **upgrade authority** and last-deployed slot.

`solana program deploy` and the BPF Upgradeable Loader write the new bytes into
the program data account, leaving the program id unchanged. Because the id never
moves, every PDA derived from it and every existing account keeps working - the
upgrade swaps code, not addresses. That property is the whole reason in-place
upgrades are safe (see the last section).

## Direct deploy / upgrade

Deploying a new program and upgrading an existing one use the **same command**.
On upgrade, pass the existing `--program-id` and the upgrade authority:

```bash
# Upgrade in place on devnet (new + upgrade use the same command)
solana program deploy target/deploy/my_program.so \
  --program-id target/deploy/my_program-keypair.json \
  --upgrade-authority ~/.config/solana/id.json \
  --url devnet
```

Reserve extra space on the **initial** deploy so future upgrades that grow the
binary do not need a separate extend step:

```bash
# Localnet: pre-allocate headroom up front
solana program deploy target/deploy/my_program.so --max-len 400000 --url localhost
```

A direct deploy streams the bytes in many transactions. If it fails midway it
leaves a funded intermediate buffer; the error prints a seed phrase to recover the
buffer keypair (`solana-keygen recover`) so you can resume rather than lose the
rent. The buffer flow below makes that recovery explicit.

## The buffer flow (preferred for real upgrades)

Write the new `.so` to a standalone **buffer account** first, then swap it into
the program in one step. This separates the slow upload from the actual cutover,
makes failed uploads resumable, and is the handoff point for a multisig authority.

```bash
# 1. Upload the new binary to a buffer (does NOT touch the live program)
solana program write-buffer target/deploy/my_program.so --url devnet
# -> prints:  Buffer: <BUFFER_ADDRESS>

# 2. Upgrade the live program from that buffer
solana program deploy \
  --buffer <BUFFER_ADDRESS> \
  --program-id target/deploy/my_program-keypair.json \
  --upgrade-authority ~/.config/solana/id.json \
  --url devnet
```

If the upload in step 1 fails, re-run it with the same buffer keypair to resume;
nothing on chain changed until step 2. To hand the upgrade to a **Squads v4
multisig**, transfer the buffer's authority to the multisig before the cutover:

```bash
solana program set-buffer-authority <BUFFER_ADDRESS> \
  --new-buffer-authority <MULTISIG_AUTHORITY> --url devnet
```

The multisig then executes the upgrade-from-buffer instruction. Full authority
handling is in `upgrade-authority.md`. Confirm the exact buffer flags with
`solana program deploy --help` / `write-buffer --help` for your version.

## Extending program size when the .so grew

The program data account is allocated to a fixed length. If the new `.so` is
**larger** than the current allocation, the upgrade fails until you grow it. Add
bytes with:

```bash
# Add 50,000 bytes of headroom to the program data account (devnet)
solana program extend <PROGRAM_ID> 50000 --url devnet
```

`solana program extend <program-id> <bytes>` takes the **additional** bytes to
add, not the new total. Size it to at least `(new .so size) - (current allocated
size)`, ideally with extra headroom so the next upgrade does not need another
extend. Some CLI versions auto-extend during deploy; do not assume it - check your
version, or extend explicitly.

## Checking program account size

Inspect the deployed program before and after an upgrade:

```bash
solana program show <PROGRAM_ID> --url devnet
```

This reports the program data length (bytes), the upgrade authority, the
deployed slot, and the balance. Use it to confirm the authority is what you
expect (single key vs multisig - see `check-upgrade-authority`), and to compare
the allocated length against your new `.so` size to decide whether you need
`extend`.

## Anchor upgrade and IDL upgrade

Anchor wraps the same loader. To upgrade the program binary:

```bash
anchor upgrade target/deploy/my_program.so \
  --program-id <PROGRAM_ID> \
  --provider.cluster devnet
```

The on-chain **IDL** is a separate account and does **not** update automatically.
After changing instructions or account layouts, push the new IDL so clients and
explorers stay in sync:

```bash
anchor idl upgrade <PROGRAM_ID> \
  --filepath target/idl/my_program.json \
  --provider.cluster devnet
```

Verify the IDL subcommands against your Anchor version (`anchor idl --help`); the
init/upgrade/set-authority surface has changed across releases.

## `--final` immutability and its tradeoff

`--final` removes the upgrade authority **permanently**. It can be set at deploy
time or via the authority command:

```bash
# Make a program immutable (irreversible). Shown on devnet for practice only.
solana program set-upgrade-authority <PROGRAM_ID> --final --url devnet
```

Tradeoff: immutability is a strong trust signal (no one can ever swap the code or
rug via upgrade) but it is **irreversible** - you can never patch a bug, ship a
fix, migrate code, or rotate the authority. Once final, your only path forward is
deploying a *new program id* and migrating users across (expensive, below). Treat
`--final` as a one-way door; prefer a multisig + timelock until the program is
genuinely battle-tested. Details and alternatives in `upgrade-authority.md`.

## Redeploy in place vs deploy a new program id

**Redeploy in place (default, almost always right):** same program id, new code in
the program data account. Every PDA derived from the program id stays valid, every
existing account keeps the same owner, and clients/CPIs that reference the id keep
working. Combine with account-data migration for layout changes.

**Deploy a new program id (last resort):** a fresh keypair means a brand-new
program. The cost is severe:

- All PDAs change - they are derived from the program id, so every PDA address is
  different under the new program.
- Existing accounts are owned by the **old** program id; the new program cannot
  read or write them without an account-by-account migration (copy data to new
  accounts under the new program - see `migration-strategies.md`).
- Every client, CPI caller, and integration referencing the old id breaks until
  updated.

You are forced into a new id only when in-place upgrade is impossible: the program
was made `--final`, or the upgrade authority is lost. Otherwise, keep the id and
upgrade in place.

## Common errors

| Error / symptom | Cause | Fix |
| --- | --- | --- |
| Upgrade fails because the new `.so` is larger than allocated | Program data account too small for the new binary | `solana program extend <PROGRAM_ID> <bytes>` (additional bytes), then redeploy |
| "insufficient funds" mid-deploy / hanging buffer | Direct deploy ran out of lamports partway | Fund the payer and resume with the same buffer keypair (the error prints recovery info) |
| Deploy says authority mismatch / not authorized | Wrong `--upgrade-authority` keypair, or authority is a multisig | Use the correct authority key; for a multisig, execute via Squads (`upgrade-authority.md`) |
| Clients/explorer show stale instructions after upgrade | IDL not pushed | `anchor idl upgrade <PROGRAM_ID> -f target/idl/<name>.json` |
| Cannot upgrade at all anymore | Program was set `--final` (immutable) | No in-place fix; deploy a new program id and migrate accounts across |
| Existing accounts unreadable after "upgrade" | Deployed to a new program id instead of in place | Redeploy in place to the original id; never change the id for a routine upgrade |
| Buffer rent stuck after a failed deploy | Intermediate buffer left funded | Recover the buffer keypair and resume, or `solana program close <BUFFER>` to reclaim |

Next: prove the upgrade + migration on a fork before doing any of this on mainnet
(`fork-simulation.md`), and lock the authority down first (`upgrade-authority.md`).
