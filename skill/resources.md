# Resources

Curated, authoritative links for program upgrades and account migration. Every
URL below was verified to resolve at the time of writing - but docs move and APIs
change, so treat these as starting points and **always confirm specifics against
the version you have installed** (`anchor --version`, `solana --version`).

## Program deployment & the Upgradeable Loader

- **Deploying Programs (Solana docs)** - the canonical CLI flow: `deploy`,
  `write-buffer`, `extend`, `set-upgrade-authority`, `--final`.
  https://solana.com/docs/programs/deploying
- **Programs / Loader-v3 (Solana docs core)** - how upgradeable programs, program
  data accounts, and the BPF Upgradeable Loader (loader-v3) work; upgrade
  authority and immutability.
  https://solana.com/docs/core/programs

## Anchor: realloc & the Migration type

- **Anchor account constraints (`realloc`, `realloc::payer`, `realloc::zero`)** -
  the in-place resize constraint group.
  https://www.anchor-lang.com/docs/account-constraints
- **Anchor PR #4060 - `Migration<'info, From, To>` type** - the new migration
  account container (merged for the 1.x line; verify it is in your version before
  relying on it).
  https://github.com/coral-xyz/anchor/pull/4060

## Account versioning & data migration

- **Solana Cookbook - Program Accounts Data Migration** - the version-field +
  conversion-on-unpack pattern.
  https://solanacookbook.com/guides/data-migration.html
- **Solana Cookbook - Program references (realloc / account size)** - changing
  account size and keeping it rent-exempt.
  https://solanacookbook.com/references/programs.html
- **dtmrc/versioning-solana** - worked example of a `data_version` field and
  v0 -> v1 account upgrade.
  https://github.com/dtmrc/versioning-solana

## Upgrade authority & multisig (Squads v4)

- **Squads docs** - multisig setup, program management, Safe Authority Transfer,
  timelocks.
  https://docs.squads.so/
- **Squads - Programs (developer assets)** - transferring upgrade authority and
  executing upgrades through the multisig.
  https://docs.squads.so/main/navigating-your-squad/developers-assets/programs
- **Squads-Protocol/squads-v4-program-upgrade** - GitHub Action to initialize a
  program upgrade through a Squads multisig from CI/CD.
  https://github.com/Squads-Protocol/squads-v4-program-upgrade
- **solana-developers/squads-program-action** - GitHub Action to propose program +
  IDL buffer upgrades to a Squad from CI.
  https://github.com/solana-developers/squads-program-action

## Fork simulation & testing

- **Surfpool docs** - mainnet-fork local validator with just-in-time account
  cloning and cheatcodes (also available as a kit MCP).
  https://docs.surfpool.run/
- **solana-foundation/surfpool** - source, install, CLI reference.
  https://github.com/solana-foundation/surfpool
- **LiteSVM** - fast in-process SVM for unit-testing migration instructions
  (companion crates: `litesvm-loader`, `anchor-litesvm`).
  https://github.com/LiteSVM/litesvm
- **anza-xyz/mollusk** - lightweight single-instruction test harness.
  https://github.com/anza-xyz/mollusk

## Related skills

- **solana-dev-skill** - the core skill this one extends (greenfield Anchor /
  Pinocchio / testing basics).
  https://github.com/solana-foundation/solana-dev-skill
