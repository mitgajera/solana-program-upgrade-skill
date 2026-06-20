# Fork Simulation

This is the core safety step: run the **exact** upgrade and migration against
**real cloned mainnet state** before you touch mainnet, and prove with byte diffs
that nothing corrupts. Skip this and you are testing in production with users'
accounts. Never deploy a migration to mainnet that you have not first run on a
fork and asserted clean.

> Verify tool specifics against current docs: Surfpool ([docs.surfpool.run](https://docs.surfpool.run/),
> also available as a kit MCP), LiteSVM, and Mollusk. CLI flags and cheatcode RPC
> method names evolve - confirm with `surfpool start --help` and each library's
> README before relying on exact names below.

## Contents

- [Two layers of testing](#two-layers-of-testing)
- [Surfpool: fork mainnet and clone real accounts](#surfpool-fork-mainnet-and-clone-real-accounts)
- [Run the real upgrade on the fork](#run-the-real-upgrade-on-the-fork)
- [Snapshot and diff account bytes](#snapshot-and-diff-account-bytes)
- [LiteSVM unit tests with versioned fixtures](#litesvm-unit-tests-with-versioned-fixtures)
- [Mollusk single-instruction tests](#mollusk-single-instruction-tests)
- [Asserting idempotency](#asserting-idempotency)
- [Dry-run deploy](#dry-run-deploy)
- [Common errors](#common-errors)

## Two layers of testing

Use both, in this order:

1. **Unit (LiteSVM / Mollusk):** fast, deterministic tests of the migration
   instruction against hand-built **versioned fixtures** (a synthetic v1 account).
   Run on every change. Proves the logic and idempotency in milliseconds.
2. **Fork (Surfpool):** the migration run against **actual mainnet accounts**
   cloned just-in-time. Catches the things fixtures cannot: real account sizes,
   odd historical layouts, accounts you forgot existed, rent edge cases.

Unit tests prove the code; the fork proves it against reality.

## Surfpool: fork mainnet and clone real accounts

Surfpool is a drop-in replacement for `solana-test-validator` that **forks
mainnet and fetches real accounts just-in-time** from a datasource RPC. You do
not pre-download anything: reference a real program id or account address in a
transaction and Surfpool pulls its current mainnet state on demand.

```bash
# Start a local surfnet that forks mainnet (accounts fetched on first touch).
# Verify the datasource flag name with `surfpool start --help`.
surfpool start --rpc-url https://api.mainnet-beta.solana.com
# RPC now serves at http://127.0.0.1:8899 with mainnet state behind it.
```

Your real program and its accounts are now reachable locally at their **mainnet
addresses**. Surfpool also exposes **cheatcodes** (RPC methods) to manipulate
state: set account data/balances, time-travel, etc. - useful to override the
upgrade authority so you can perform the upgrade locally without the real
multisig:

```bash
# Conceptual: override the program's upgrade authority to a local test key so the
# fork can execute the upgrade. Confirm the exact cheatcode method name (e.g. a
# surfnet_* RPC) in the Surfpool docs - do not assume the spelling.
# This is fork-only; it never affects mainnet.
```

## Run the real upgrade on the fork

Point the standard buffer flow (`program-deploy-upgrade.md`) at the local fork RPC
and upgrade against cloned state:

```bash
# Build the new binary, then upgrade on the fork (localhost = the surfnet).
solana program write-buffer target/deploy/my_program.so --url localhost
# -> Buffer: <BUFFER_ADDRESS>

solana program deploy \
  --buffer <BUFFER_ADDRESS> \
  --program-id <REAL_PROGRAM_ID> \
  --upgrade-authority <LOCAL_TEST_AUTHORITY> \
  --url localhost
```

Then run your **migration instruction** against the real account addresses (they
clone in on first touch). Use the same client/test you will use on mainnet, just
with `--url localhost`. Anchor also integrates: recent Anchor can run
`anchor test` / `anchor localnet` on Surfpool, so your existing test suite can
execute against forked state.

## Snapshot and diff account bytes

This is how you **prove no corruption**: dump the raw account bytes before and
after the migration and diff them. Carried-over fields must be byte-identical;
only the intended region (new field + version byte) may change.

```bash
# Before migrating
solana account <REAL_VAULT> --url localhost --output json-compact > before.json

# ... run the migration instruction against <REAL_VAULT> on the fork ...

# After migrating
solana account <REAL_VAULT> --url localhost --output json-compact > after.json

# Compare the base64 account data (the [data, encoding] tuple)
diff <(jq -r '.account.data[0]' before.json) <(jq -r '.account.data[0]' after.json)
```

Decode both and assert field-by-field: `authority` and `amount` unchanged, the
version byte went 1 -> 2, and the appended field is its expected default. Repeat
across a sample of real accounts (smallest, largest, oldest) - not just one.

## LiteSVM unit tests with versioned fixtures

LiteSVM runs the SVM in-process for fast, deterministic tests. Seed an account
with **hand-built v1 bytes**, run the migration, assert the new layout.

```rust
use litesvm::LiteSVM;
use solana_sdk::{account::Account, pubkey::Pubkey, signature::Keypair,
                 signer::Signer, transaction::Transaction};

// Build a synthetic v1 account: discriminator + version=1 + old fields.
fn vault_v1_bytes(disc: [u8; 8], authority: Pubkey, amount: u64) -> Vec<u8> {
    let mut d = Vec::new();
    d.extend_from_slice(&disc);
    d.push(1);                              // version byte
    d.extend_from_slice(authority.as_ref()); // 32
    d.extend_from_slice(&amount.to_le_bytes()); // 8
    d
}

#[test]
fn migrates_v1_to_v2_without_corruption() {
    let mut svm = LiteSVM::new();
    let program_id = Pubkey::new_unique();
    svm.add_program_from_file(program_id, "target/deploy/my_program.so").unwrap();

    let payer = Keypair::new();
    svm.airdrop(&payer.pubkey(), 10_000_000_000).unwrap();

    let vault = Pubkey::new_unique();
    let authority = Pubkey::new_unique();
    let before = vault_v1_bytes(VAULT_DISC, authority, 42);
    svm.set_account(vault, Account {
        lamports: 5_000_000,
        data: before.clone(),
        owner: program_id,
        executable: false,
        rent_epoch: 0,
    }).unwrap();

    let ix = build_migrate_ix(program_id, vault, payer.pubkey()); // your ix builder
    let tx = Transaction::new_signed_with_payer(
        &[ix], Some(&payer.pubkey()), &[&payer], svm.latest_blockhash());
    svm.send_transaction(tx).expect("migration should succeed");

    let after = svm.get_account(&vault).unwrap().data;
    assert_eq!(after[8], 2, "version bumped to 2");
    assert_eq!(&after[9..49], &before[9..49], "authority+amount preserved");
    assert_eq!(&after[49..57], &0i64.to_le_bytes(), "new field defaulted to 0");
}
```

LiteSVM also has a TypeScript binding if your tests live in TS; the shape is the
same (set the account, send the tx, read it back).

## Mollusk single-instruction tests

Mollusk is a lighter harness focused on one instruction - ideal for asserting the
migration's account results and compute usage.

```rust
use mollusk_svm::{Mollusk, result::Check};

#[test]
fn migrate_ix_succeeds_and_writes_v2() {
    let program_id = Pubkey::new_unique();
    let mollusk = Mollusk::new(&program_id, "my_program"); // loads target/deploy/*.so

    let vault = Pubkey::new_unique();
    let old = Account { /* lamports, owner: program_id, data: v1 bytes ... */ };
    let payer = (payer_pk, Account::new(1_000_000_000, 0, &system_program::id()));

    let ix = build_migrate_ix(program_id, vault, payer_pk);
    let result = mollusk.process_and_validate_instruction(
        &ix,
        &[(vault, old), payer /*, system_program */],
        &[Check::success()],
    );

    let migrated = result.get_account(&vault).unwrap();
    assert_eq!(migrated.data[8], 2);
}
```

Confirm the exact Mollusk constructor/result API against its README for your
version (the surface has changed across releases).

## Asserting idempotency

A migration must be a no-op the second time. Prove it explicitly - this is what
makes a crank safe to retry and lazy migration safe under concurrency.

```rust
// ... after the first successful migration above ...
let snapshot = svm.get_account(&vault).unwrap().data.clone();

let ix2 = build_migrate_ix(program_id, vault, payer.pubkey());
let tx2 = Transaction::new_signed_with_payer(
    &[ix2], Some(&payer.pubkey()), &[&payer], svm.latest_blockhash());
svm.send_transaction(tx2).expect("second run should be a no-op, not an error");

assert_eq!(svm.get_account(&vault).unwrap().data, snapshot,
           "running the migration twice must not change bytes");
```

On the fork, do the same: re-run the migration against an already-migrated real
account and diff - the second `after.json` must equal the first.

## Dry-run deploy

The fork itself is your dry-run: deploying to the Surfpool surfnet exercises the
real buffer flow, `extend` needs, rent, and authority checks without risking
mainnet. Before any mainnet deploy, confirm on the fork that:

- `solana program write-buffer` + `deploy --buffer` succeed end to end.
- The new `.so` fits (no surprise `extend` needed - or run `extend` on the fork
  first and confirm).
- The migration instruction runs against cloned accounts and the byte diffs are
  clean.
- Re-running the migration is a no-op.

Only when all four pass do you repeat the exact steps against mainnet.

## Common errors

| Error / symptom | Cause | Fix |
| --- | --- | --- |
| Upgrade fails on the fork: authority mismatch | Real authority is a multisig you do not hold | Use a Surfpool cheatcode to set the upgrade authority to a local key (fork-only) |
| Account "not found" on the fork | Referenced before it was touched / wrong datasource | Ensure the datasource RPC is set; reference the real mainnet address so it clones in |
| LiteSVM `add_program_from_file` fails | Wrong path or program not built | `anchor build` first; point at `target/deploy/<name>.so` |
| Byte diff shows unexpected changes | Migration corrupts carried fields (wrong offsets, reorder) | Fix offsets; only the version byte + appended region should change |
| Second migration errors instead of no-op | Missing idempotency guard | Gate on `version < CURRENT` (see `realloc-migration.md`) |
| Fork passes but mainnet differs | Tested one account; mainnet has odd layouts | Sample many real accounts (smallest/largest/oldest) on the fork |

Next: have a rollback and half-migration recovery plan ready before you deploy
(`rollback-recovery.md`).
