---
description: Spin a Surfpool mainnet fork, clone real accounts, run the upgrade + migration, diff state, and report pass/fail.
argument-hint: "[program id] [sample account addresses...]"
---

# /simulate-upgrade

Prove the upgrade + migration on a **Surfpool mainnet fork** against real cloned
accounts before any mainnet step. Report a clear pass/fail. This runs only against
a local fork - never mainnet.

Target: $ARGUMENTS

## Steps

1. **Confirm prerequisites.** The new program is built (`anchor build` ->
   `target/deploy/<name>.so`), Surfpool is installed (`surfpool --version`), and
   the user supplied the program id plus a few real mainnet account addresses to
   clone (ideally smallest, largest, oldest). Ask if missing.
2. **Start the fork.** Launch a Surfpool surfnet that forks mainnet (real accounts
   fetched just-in-time). Verify the datasource flag with `surfpool start --help`.
   The local RPC serves at `http://127.0.0.1:8899`.
3. **Take the BEFORE snapshot.** For each sample account, dump raw bytes:
   `solana account <ADDR> --url localhost --output json-compact > before_<ADDR>.json`.
4. **Override authority (fork-only).** Use a Surfpool cheatcode to set the
   program's upgrade authority to a local test key so the fork can perform the
   upgrade without the real multisig. Confirm the cheatcode method name in the
   Surfpool docs.
5. **Run the upgrade.** Buffer flow against the fork: `solana program write-buffer
   ... --url localhost` then `solana program deploy --buffer ... --program-id
   <ID> --url localhost`. Run `solana program extend` first if the new `.so` is
   larger.
6. **Run the migration** instruction against each cloned account (the same client
   you would use on mainnet, with `--url localhost`).
7. **Take the AFTER snapshot** and **diff** each account. Decode and assert:
   carried fields byte-identical, version byte advanced, new field defaulted.
8. **Check idempotency.** Re-run the migration on an already-migrated account;
   assert no error and no byte change.
9. **Report.** A pass/fail table per account (diff clean? version bumped?
   idempotent?), plus an overall **GO / NO-GO** with any blocking issues.

## Rules

- Fork only. Never run the upgrade or migration against mainnet from this command.
- A clean run requires: clean diffs on every sampled account, idempotency holding,
  and the buffer/extend flow succeeding. Anything else is NO-GO.
- See `skill/fork-simulation.md` for the detailed method and assertions.
- For writing the actual test suite, hand off to the `migration-qa-engineer` agent.
