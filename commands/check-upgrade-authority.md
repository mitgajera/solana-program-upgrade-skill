---
description: Query a program's upgrade authority, report single-key vs multisig, flag rug risk, and recommend Squads if single-key.
argument-hint: "[program id] [--url devnet|mainnet-beta|...]"
---

# /check-upgrade-authority

Audit who controls a Solana program's code. Report whether the upgrade authority
is a single key or a multisig, flag the rug/compromise risk, and recommend a fix.
Read-only - this command never changes authority or deploys.

Target: $ARGUMENTS

## Steps

1. **Resolve the program id** from `$ARGUMENTS` (or ask). Pick the cluster from
   `--url`; default to a read-only query (no mutation regardless of cluster).
2. **Query the program:** `solana program show <PROGRAM_ID> --url <CLUSTER>`. Read
   the `Authority`, data length, and last deployed slot.
3. **Classify the authority:**
   - `None` -> the program is **immutable** (`--final`). Report that code can never
     change; note the tradeoff (no bug fixes, no migrations) per
     `skill/upgrade-authority.md`.
   - A **plain wallet** address -> **single-key control**. High rug/compromise
     risk: one key can replace all program logic.
   - A **Squads vault PDA / multisig** -> lower risk. Note the threshold and
     whether a timelock is configured if you can determine it.
4. **Assess risk** in context: does the program hold value? Is it actively used?
   A single hot key on a value-holding program is a red flag.
5. **Report** with: the authority address, the classification (single-key /
   multisig / immutable), a plain-language risk level, and a recommendation.

## Recommendation rules

- **Single-key + holds value:** strongly recommend moving authority to a **Squads
  v4 multisig** (+ timelock). Point to the transfer steps in
  `skill/upgrade-authority.md` (`set-upgrade-authority` with
  `--skip-new-upgrade-authority-signer-check`, or Squads Safe Authority Transfer).
- **Multisig:** confirm the threshold is meaningful (not 1-of-N) and suggest a
  timelock if absent.
- **Immutable:** confirm this was intentional; if the program may need fixes or
  migrations, note that this is irreversible.

## Rules

- Read-only. Never run `set-upgrade-authority`, `deploy`, or `--final` from this
  command.
- Verify CLI flags with `solana program show --help` for the installed version.
