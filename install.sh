#!/usr/bin/env bash
#
# install.sh - standard installer for the solana-program-upgrade skill.
# Installs to ~/.claude/skills/, copies CLAUDE.md to ~/.claude/, and pulls the
# core dependency solana-dev-skill unless it is already present.
#
# Usage:
#   ./install.sh            # interactive confirm
#   ./install.sh -y         # non-interactive (assume yes)
#   ./install.sh --skip-deps  # do not pull solana-dev-skill
#
set -euo pipefail

SKILL_NAME="solana-program-upgrade"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
SKILLS_DIR="${CLAUDE_DIR}/skills"
DEV_SKILL_REPO="https://github.com/solana-foundation/solana-dev-skill.git"

ASSUME_YES=0
SKIP_DEPS=0

for arg in "$@"; do
  case "$arg" in
    -y|--yes)    ASSUME_YES=1 ;;
    --skip-deps) SKIP_DEPS=1 ;;
    -h|--help)
      echo "Usage: ./install.sh [-y] [--skip-deps]"
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "Error: git is required." >&2; exit 1; }

echo "solana-program-upgrade installer"
echo "  skill   -> ${SKILLS_DIR}/${SKILL_NAME}"
echo "  agents  -> ${CLAUDE_DIR}/agents"
echo "  commands-> ${CLAUDE_DIR}/commands"
echo "  rules   -> ${CLAUDE_DIR}/rules"
echo "  CLAUDE.md-> ${CLAUDE_DIR}/CLAUDE.md"
echo

if [ "$ASSUME_YES" -ne 1 ]; then
  printf "Proceed with installation? [y/N] "
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

mkdir -p "${SKILLS_DIR}/${SKILL_NAME}" \
         "${CLAUDE_DIR}/agents" \
         "${CLAUDE_DIR}/commands" \
         "${CLAUDE_DIR}/rules"

# Skill hub + focused files
cp -R "${SCRIPT_DIR}/skill/." "${SKILLS_DIR}/${SKILL_NAME}/"
echo "Installed skill files."

# Agents, commands, rules
cp "${SCRIPT_DIR}"/agents/*.md   "${CLAUDE_DIR}/agents/"   2>/dev/null || true
cp "${SCRIPT_DIR}"/commands/*.md "${CLAUDE_DIR}/commands/" 2>/dev/null || true
cp "${SCRIPT_DIR}"/rules/*.md    "${CLAUDE_DIR}/rules/"    2>/dev/null || true
echo "Installed agents, commands, and rules."

# CLAUDE.md - back up an existing one rather than clobbering it.
if [ -f "${CLAUDE_DIR}/CLAUDE.md" ]; then
  backup="${CLAUDE_DIR}/CLAUDE.md.bak.$(date +%Y%m%d%H%M%S)"
  cp "${CLAUDE_DIR}/CLAUDE.md" "$backup"
  echo "Existing CLAUDE.md backed up to ${backup}"
fi
cp "${SCRIPT_DIR}/CLAUDE.md" "${CLAUDE_DIR}/CLAUDE.md"
echo "Installed CLAUDE.md."

# Core dependency: solana-dev-skill (pulled unless present).
if [ "$SKIP_DEPS" -eq 1 ]; then
  echo "Skipping solana-dev-skill (--skip-deps)."
elif [ -d "${SKILLS_DIR}/solana-dev-skill" ]; then
  echo "Core dependency solana-dev-skill already present; skipping."
else
  echo "Pulling core dependency solana-dev-skill..."
  git clone --depth 1 "${DEV_SKILL_REPO}" "${SKILLS_DIR}/solana-dev-skill"
fi

echo
echo "Done. Next steps:"
echo "  1. Restart Claude Code (or reload skills) so it picks up the new skill."
echo "  2. Try: \"I changed my Vault account struct and now get AccountDidNotDeserialize\""
echo "  3. Commands: /plan-upgrade, /simulate-upgrade, /check-upgrade-authority"
