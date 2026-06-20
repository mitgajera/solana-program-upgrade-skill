# CLAUDE.md

**solana-program-upgrade** - safely upgrade live Solana programs and migrate
on-chain account data without bricking the program or corrupting accounts.

**Addon.** This skill extends
[`solana-dev-skill`](https://github.com/solana-foundation/solana-dev-skill). It
owns only the upgrade + migration lifecycle; delegate greenfield Anchor /
Pinocchio / testing basics to the core skill. The hub is `skill/SKILL.md`; load
focused files from its routing table as needed.

## Two-strike rule

If a build or test fails **twice on the same issue**, stop and ask the user rather
than trying a third variation. Surface what failed, the error, and your two
attempts; let the user decide.

## Golden rules

1. Never change a live account layout without a version tag + migration path.
2. Always simulate the upgrade against real cloned mainnet state before mainnet.
3. Multisig the upgrade authority - a single hot key is a rug vector.
4. On-chain data migrations are usually forward-only; design additive + resumable.
5. Keep the previous `.so` to roll back the code even when data can't be reverted.
6. Default every example to devnet/localnet/fork - never auto-target mainnet.

## Accuracy contract

No fabricated APIs. Verify every CLI flag, Anchor constraint, crate, and account
type against installed versions (`anchor --version`, `solana --version`). Treat the
Anchor `Migration` type as possibly-unreleased; the manual `realloc` pattern is the
portable default.
