#!/usr/bin/env bash
#
# install-custom.sh - custom installer for the solana-program-upgrade skill.
# Interactive: choose personal / project / custom location, detect an existing
# solana-dev-skill (and skip it), and choose where CLAUDE.md goes.
#
# Non-interactive testing: answers can be piped on stdin, e.g.
#   printf '1\n1\n' | ./install-custom.sh --skip-deps
#
set -euo pipefail

SKILL_NAME="solana-program-upgrade"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_SKILL_REPO="https://github.com/solana-foundation/solana-dev-skill.git"

SKIP_DEPS=0
for arg in "$@"; do
  case "$arg" in
    --skip-deps) SKIP_DEPS=1 ;;
    -h|--help)
      echo "Usage: ./install-custom.sh [--skip-deps]"
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "Error: git is required." >&2; exit 1; }

echo "solana-program-upgrade custom installer"
echo
echo "Where should the skill be installed?"
echo "  1) Personal  (~/.claude/skills/)"
echo "  2) Project   (./.claude/skills/)"
echo "  3) Custom    (you provide a path)"
printf "Choose [1-3]: "
read -r choice

case "$choice" in
  1) BASE_DIR="${HOME}/.claude" ;;
  2) BASE_DIR="$(pwd)/.claude" ;;
  3)
    printf "Enter the base directory (a .claude-style dir will be used as given): "
    read -r custom_path
    BASE_DIR="${custom_path%/}"
    ;;
  *) echo "Invalid choice."; exit 1 ;;
esac

SKILLS_DIR="${BASE_DIR}/skills"

echo
echo "Where should CLAUDE.md go?"
echo "  1) ${BASE_DIR}/CLAUDE.md"
echo "  2) Skip CLAUDE.md"
printf "Choose [1-2]: "
read -r claude_choice

mkdir -p "${SKILLS_DIR}/${SKILL_NAME}" \
         "${BASE_DIR}/agents" \
         "${BASE_DIR}/commands" \
         "${BASE_DIR}/rules"

cp -R "${SCRIPT_DIR}/skill/." "${SKILLS_DIR}/${SKILL_NAME}/"
cp "${SCRIPT_DIR}"/agents/*.md   "${BASE_DIR}/agents/"   2>/dev/null || true
cp "${SCRIPT_DIR}"/commands/*.md "${BASE_DIR}/commands/" 2>/dev/null || true
cp "${SCRIPT_DIR}"/rules/*.md    "${BASE_DIR}/rules/"    2>/dev/null || true
echo "Installed skill, agents, commands, and rules to ${BASE_DIR}."

case "$claude_choice" in
  1)
    if [ -f "${BASE_DIR}/CLAUDE.md" ]; then
      backup="${BASE_DIR}/CLAUDE.md.bak.$(date +%Y%m%d%H%M%S)"
      cp "${BASE_DIR}/CLAUDE.md" "$backup"
      echo "Existing CLAUDE.md backed up to ${backup}"
    fi
    cp "${SCRIPT_DIR}/CLAUDE.md" "${BASE_DIR}/CLAUDE.md"
    echo "Installed CLAUDE.md."
    ;;
  *) echo "Skipped CLAUDE.md." ;;
esac

# Core dependency: detect an existing solana-dev-skill and skip it.
if [ "$SKIP_DEPS" -eq 1 ]; then
  echo "Skipping solana-dev-skill (--skip-deps)."
elif [ -d "${SKILLS_DIR}/solana-dev-skill" ]; then
  echo "Core dependency solana-dev-skill already present; skipping."
else
  printf "Pull core dependency solana-dev-skill now? [y/N] "
  read -r dep_reply
  case "$dep_reply" in
    y|Y|yes|YES)
      git clone --depth 1 "${DEV_SKILL_REPO}" "${SKILLS_DIR}/solana-dev-skill" ;;
    *) echo "Skipped solana-dev-skill. Install it separately if not already present." ;;
  esac
fi

echo
echo "Done. Restart Claude Code (or reload skills) to pick up the new skill."
