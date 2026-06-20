# Upgrade Authority

The upgrade authority is the **single most powerful key in your program's
security model**. Whoever holds it can replace 100% of your program's code at any
time - which means it can bypass every on-chain access control you wrote, because
it can rewrite the code that enforces them. Securing it is the highest-leverage
security decision you make. This file is the cross-domain (security) heart of the
skill.

> Verify against current docs and your CLI: `solana program set-upgrade-authority
> --help`, and the [Squads v4 docs](https://docs.squads.so/). Squads' app flow,
> CLI, and the GitHub action evolve; confirm exact steps before running on real
> funds.

## Contents

- [What the upgrade authority can do](#what-the-upgrade-authority-can-do)
- [The single-hot-key rug vector](#the-single-hot-key-rug-vector)
- [Inspecting the current authority](#inspecting-the-current-authority)
- [Transferring authority (`set-upgrade-authority`)](#transferring-authority-set-upgrade-authority)
- [Moving authority to a Squads v4 multisig](#moving-authority-to-a-squads-v4-multisig)
- [How an upgrade executes through the multisig](#how-an-upgrade-executes-through-the-multisig)
- [Timelock and governance options](#timelock-and-governance-options)
- [`--final` immutability and when NOT to use it](#--final-immutability-and-when-not-to-use-it)
- [Key management checklist](#key-management-checklist)
- [Common errors](#common-errors)

## What the upgrade authority can do

It can call the BPF Upgradeable Loader's upgrade instruction to swap the program
data account's bytes for a new `.so`. There is no on-chain check on *what* the new
code does. So the authority can, unilaterally and instantly:

- Replace the program with code that drains every account the program owns.
- Disable your access controls, mint/withdraw guards, or pause logic.
- Brick the program (deploy broken or empty code), then make it `--final`.

Treat the upgrade authority as the **trust root** of the entire deployment. Every
audit, every access-control check, every invariant in your program is only as
trustworthy as the key that can replace all of it.

## The single-hot-key rug vector

A program controlled by one keypair is the classic Solana rug/compromise vector:

- **Malice:** one person can push a draining upgrade with zero approvals.
- **Compromise:** one phished seed phrase, one leaked CI secret, one infected dev
  laptop, and an attacker owns the program outright.
- **Loss:** lose that single key and you can never upgrade again (only recourse is
  a new program id + full account migration - see `program-deploy-upgrade.md`).

Users and auditors increasingly check this. A single hot key is a red flag; a
multisig (ideally with a timelock) is the expected standard for any program
holding real value.

## Inspecting the current authority

Always confirm who controls a program before trusting it or upgrading it:

```bash
solana program show <PROGRAM_ID> --url devnet
```

The output's `Authority` line is the upgrade authority. `None` means the program
is immutable (`--final`). If it is a plain wallet address rather than a multisig
vault, flag the single-key risk (the `/check-upgrade-authority` command automates
this judgment).

## Transferring authority (`set-upgrade-authority`)

Rotate the authority to a new key (e.g. from a deploy key to a multisig vault):

```bash
# Devnet: move authority to a new keypair you control
solana program set-upgrade-authority <PROGRAM_ID> \
  --new-upgrade-authority <NEW_AUTHORITY_PUBKEY_OR_KEYPAIR> \
  --url devnet
```

When the new authority is a **PDA** (like a Squads vault) it cannot sign, so the
CLI requires you to acknowledge that explicitly:

```bash
solana program set-upgrade-authority <PROGRAM_ID> \
  --new-upgrade-authority <SQUADS_VAULT_PDA> \
  --skip-new-upgrade-authority-signer-check \
  --url devnet
```

Confirm that flag name against `set-upgrade-authority --help` for your version.
Double-check the new authority address before running - set it to the wrong place
and you may lock yourself out permanently.

## Moving authority to a Squads v4 multisig

Squads v4 is the ecosystem standard for program-authority custody. v4 adds time
locks, roles, spending limits, sub-accounts, and address lookup table support over
v3. High-level setup:

1. Create a Squad (multisig) in the Squads app. Choose members and a **threshold**
   (e.g. 2-of-3 or 3-of-5). Each member should sign from a hardware wallet.
2. Note the Squad's **vault PDA** - that address becomes the program's upgrade
   authority.
3. Transfer the program's upgrade authority to that vault PDA. Two ways:
   - **CLI** with `set-upgrade-authority ... --skip-new-upgrade-authority-signer-check`
     (above), or
   - **Safe Authority Transfer (SAT)** in Squads, which creates a transaction
     signed by both the Squad's vault PDA and the current authority holder so the
     handoff cannot land the authority somewhere unusable. Prefer SAT for mainnet.

After transfer, your old key can no longer upgrade directly; all upgrades go
through the multisig.

## How an upgrade executes through the multisig

Once the vault PDA is the authority, an upgrade is a proposal the members approve:

```bash
# 1. Build the new buffer (does not touch the live program)
solana program write-buffer target/deploy/my_program.so --url devnet
# -> Buffer: <BUFFER_ADDRESS>

# 2. Set the buffer's authority to the Squads vault so the multisig can consume it
solana program set-buffer-authority <BUFFER_ADDRESS> \
  --new-buffer-authority <SQUADS_VAULT_PDA> --url devnet
```

3. In Squads, create a **Program Upgrade** proposal pointing at `<PROGRAM_ID>` and
   `<BUFFER_ADDRESS>` (the app / `squads-v4-program-upgrade` tooling builds this;
   the official GitHub action can do steps 1-3 from CI).
4. Members **approve** until the threshold is met (and any timelock elapses).
5. **Execute** - the multisig invokes the loader's upgrade, swapping program data
   to the buffer. Leftover buffer rent returns to the configured spill account.

This is the buffer flow from `program-deploy-upgrade.md` with the multisig as the
authority on both the program and the buffer.

## Timelock and governance options

- **Timelock (Squads v4):** configure a delay between approval and execution.
  Users get a public window to react (withdraw, raise alarms) before any code
  change lands - turning a silent upgrade into a pre-announced one.
- **Threshold + roles:** require enough independent signers that no one person can
  act; use roles to separate proposers from approvers.
- **SPL Governance / Realms:** for DAO-governed programs, the upgrade authority can
  be a governance account so token holders vote on upgrades. Heavier than a
  multisig; appropriate for protocols that have decentralized.

Match the control to the value at risk: small/early - a 2-of-3; large/mature - a
higher-threshold multisig with a timelock, or full on-chain governance.

## `--final` immutability and when NOT to use it

`--final` permanently removes the upgrade authority (covered mechanically in
`program-deploy-upgrade.md`). It is the strongest trust signal: no one - not even
the multisig - can ever change the code.

**Do NOT make a program immutable when:**

- It is young or under active development (you will need to ship fixes).
- It is complex or unaudited (the odds of a latent bug are high, and you will have
  no way to patch it).
- It may need future account-data migrations that require code changes.
- You have not first proven it on a fork and on devnet for a meaningful period.

**Reasonable to consider immutability when:** the program is small, audited,
battle-tested, and its value proposition is trustlessness (a fixed primitive users
must be able to rely on never changing). Even then, a high-threshold multisig with
a timelock often gives most of the trust benefit while keeping an emergency path.
`--final` is a one-way door; prefer reversible controls until you are certain.

## Key management checklist

- Never let a single hot key be the upgrade authority for anything holding value.
- Keep the **deploy payer separate** from the **upgrade authority**; the payer can
  be hot, the authority must not be.
- Store signer keys on **hardware wallets**; distribute them across people and,
  ideally, organizations.
- Never put the upgrade authority key in CI/CD or on a deploy server. Use the
  Squads GitHub action to *propose* upgrades; approval/execution stays with humans
  on hardware wallets.
- Add a **timelock** so upgrades are observable before they execute.
- Document who the signers are and have a recovery plan for a lost signer (within
  the threshold) so loss of one key is not catastrophic.

## Common errors

| Error / symptom | Cause | Fix |
| --- | --- | --- |
| `set-upgrade-authority` rejects a PDA as new authority | PDAs cannot sign | Add `--skip-new-upgrade-authority-signer-check` (verify the flag for your version) |
| Locked out: nobody can upgrade | Authority set to a wrong/unowned address, or made `--final` | If `--final`, deploy a new program id and migrate; otherwise recover the intended authority key |
| Multisig cannot execute the upgrade | Buffer authority not set to the vault PDA, or buffer authority != program authority | `set-buffer-authority` to the vault PDA before proposing |
| `Authority` shows a plain wallet on a value-holding program | Single-key control (rug/compromise risk) | Move authority to a Squads multisig (+ timelock) |
| Upgrade executes instantly with no review window | No timelock configured | Enable a Squads v4 timelock so changes are announced before landing |
| Lost a single signer and threshold can't be met | Threshold set too tight / no recovery plan | Design threshold with margin; rotate/replace signers per your recovery plan |

Next: simulate the exact upgrade + migration on a fork before touching mainnet
(`fork-simulation.md`), and keep a rollback path ready (`rollback-recovery.md`).
