# solana-program-upgrade-skill

A Claude Code [Agent Skill](https://code.claude.com/docs/en/skills)
that makes **upgrading a live Solana program and migrating its on-chain account
data safe** - versioning, lazy `realloc` migration, the Anchor `Migration` type,
upgrade-authority hygiene (Squads multisig), fork-simulation before mainnet, and
rollback/recovery.

> ## Extends `solana-dev-skill`
>
> This is an **addon**, not a fork. It extends
> [`solana-foundation/solana-dev-skill`](https://github.com/solana-foundation/solana-dev-skill),
> which owns greenfield Anchor / Pinocchio / testing basics. This skill owns only
> the **upgrade + migration lifecycle** - reach for it once a program is already
> deployed and needs to change.

## Overview

```
            your prompt: "I changed my Vault struct and now it won't deserialize"
                                     |
                                     v
        +-------------------------------------------------------+
        |   solana-program-upgrade   (this addon)               |
        |   versioning . realloc . Migration type . fork sim    |
        |   upgrade authority . rollback . strategy guide       |
        +-------------------------------------------------------+
                                     |  delegates basics to
                                     v
        +-------------------------------------------------------+
        |   solana-dev-skill   (core)                           |
        |   Anchor / Pinocchio scaffolding, testing, deploy     |
        +-------------------------------------------------------+
```

The skill is a lean hub (`skill/SKILL.md`) that routes to focused files. Claude
loads only the file it needs for the situation at hand (progressive disclosure).

## The problem it solves

Upgrading a deployed program is the single most catastrophic, under-tooled step in
the Solana lifecycle. A deployed program's accounts are raw bytes interpreted by
the current code; the moment you change an `#[account]` struct and redeploy, the
new code misreads old bytes and you get `AccountDidNotDeserialize`, wrong values,
or silent corruption of user funds. There is no dedicated skill that packages
program-upgrade **plus** account-data migration - this fills that gap with
concrete, version-aware, simulate-first guidance so teams can iterate on a live
program without bricking it or corrupting accounts.

## What's included

| File | What it covers |
| --- | --- |
| `skill/SKILL.md` | The hub: golden rules, the upgrade workflow, and the routing table |
| `skill/account-versioning.md` | Version tags, discriminator vs version, safe vs breaking changes, AccountV1/V2 |
| `skill/realloc-migration.md` | Anchor `realloc` constraint, lazy migrate-on-touch, idempotency, the 10 KB cap, native equivalent |
| `skill/anchor-migration-type.md` | The Anchor `Migration<From, To>` type (PR #4060), flagged as possibly-unreleased |
| `skill/program-deploy-upgrade.md` | BPFLoaderUpgradeable, buffer flow, `extend`, IDL, `--final`, in-place vs new id |
| `skill/upgrade-authority.md` | What the authority can do, Squads v4 multisig, timelock, immutability, key management |
| `skill/fork-simulation.md` | Surfpool mainnet fork, byte diffs, LiteSVM/Mollusk tests, idempotency proof |
| `skill/rollback-recovery.md` | Keep the prior `.so`, half-migration recovery, pause/guard, post-incident verification |
| `skill/migration-strategies.md` | Decision guide: eager vs lazy vs copy-to-new; crank/keeper for large sets |
| `skill/resources.md` | Curated, verified links current to 2026 |

## Installation

```bash
git clone https://github.com/mitgajera/solana-program-upgrade-skill.git
cd solana-program-upgrade-skill

# Standard: install to ~/.claude/skills/ and copy CLAUDE.md to ~/.claude/
./install.sh            # add -y for non-interactive

# Custom: choose personal / project / custom path interactively
./install-custom.sh
```

| | `install.sh` | `install-custom.sh` |
| --- | --- | --- |
| Location | `~/.claude/skills/` (default) | personal / project / custom path |
| `CLAUDE.md` | copied to `~/.claude/` | you choose placement |
| `solana-dev-skill` | pulled unless present | detected and skipped if present |
| Mode | defaults, `-y` for non-interactive | interactive menu |

Both scripts are shell-only and make no network calls beyond `git`.

## Default stack (2026)

| Layer | Tool |
| --- | --- |
| Framework | Anchor 0.31+ / 1.x (verify `anchor --version`) |
| Loader / CLI | Solana CLI with BPFLoaderUpgradeable |
| Client | `@solana/kit` |
| Fork simulation | Surfpool (also a kit MCP) |
| Unit testing | LiteSVM / Mollusk |
| Authority | Squads v4 multisig |

## Agents

| Agent | Model | Role |
| --- | --- | --- |
| `program-migration-architect` | opus | Plan a migration from a schema diff + constraints; output a plan + risk report |
| `migration-qa-engineer` | opus | Write fork/LiteSVM/Mollusk tests, verify no corruption + idempotency before mainnet |

## Commands

| Command | What it does |
| --- | --- |
| `/plan-upgrade` | Analyze structs + proposed changes into a migration plan + risk report (no execution) |
| `/simulate-upgrade` | Surfpool fork, clone accounts, run upgrade + migration, diff state, report pass/fail |
| `/check-upgrade-authority` | Query the upgrade authority, flag single-key rug risk, recommend Squads |

## Usage examples

- "I added two fields to my `Vault` account struct and now my program throws
  `AccountDidNotDeserialize` on existing accounts. How do I migrate them?"
- "Walk me through upgrading my Anchor program on mainnet safely - it's currently
  controlled by a single keypair."
- "I have ~40k existing position accounts that need a new field. What's the
  cheapest safe migration strategy and how do I simulate it before mainnet?"
- "Make my program immutable - but first tell me what I lose."

## Repository structure

```
solana-program-upgrade-skill/
├── CLAUDE.md
├── README.md
├── LICENSE
├── install.sh
├── install-custom.sh
├── .gitmodules
├── skill/
│   ├── SKILL.md
│   ├── account-versioning.md
│   ├── realloc-migration.md
│   ├── anchor-migration-type.md
│   ├── program-deploy-upgrade.md
│   ├── upgrade-authority.md
│   ├── fork-simulation.md
│   ├── rollback-recovery.md
│   ├── migration-strategies.md
│   └── resources.md
├── agents/
│   ├── program-migration-architect.md
│   └── migration-qa-engineer.md
├── commands/
│   ├── plan-upgrade.md
│   ├── simulate-upgrade.md
│   └── check-upgrade-authority.md
└── rules/
    └── account-layout-guard.md
```

## Safety model

The golden rules the skill enforces:

1. Never change a live account layout without a version tag + migration path.
2. Always simulate the upgrade against real cloned mainnet state before mainnet.
3. Multisig the upgrade authority - a single hot key is a rug vector.
4. On-chain data migrations are usually forward-only; design additive + resumable.
5. Keep the previous `.so` to roll back the code even when data can't be reverted.
6. Default every example to devnet/localnet/fork - never auto-target mainnet.

## Related

- [solana-dev-skill](https://github.com/solana-foundation/solana-dev-skill) - the
  core skill this extends.
- [solana-ai-kit](https://github.com/solanabr/solana-ai-kit) - the kit this
  registers into as `ext/program-upgrade`.

## Contributing

Issues and PRs welcome. Keep the accuracy contract: no fabricated APIs, verify
flags/types against installed versions, no dead links, and default examples to
devnet/localnet.

## License

MIT - see [LICENSE](LICENSE).

Maintained by <YOUR HANDLE>.
