#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh — Initialize BMAD Factory Pipeline in any project
#
# Usage:
#   bootstrap.sh --target ~/projects/my-app          # new or existing project
#   bootstrap.sh --target ~/projects/my-app --bare    # also set up bare repo
#   bootstrap.sh --here                               # current directory
#   bootstrap.sh --here --bare                        # current dir + bare repo
#
# What it does:
#   1. Copies hook scripts into .claude/hooks/
#   2. Places orchestration scripts at project root (or bare repo root)
#   3. Generates CLAUDE.md from template
#   4. Creates settings.local.json for hook mappings
#   5. Sets up _bmad-output/ directory structure
#   6. Optionally converts to bare repo layout
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Defaults
TARGET=""
SETUP_BARE=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target|-t) TARGET="$2"; shift 2 ;;
    --here)      TARGET="$(pwd)"; shift ;;
    --bare)      SETUP_BARE=true; shift ;;
    --force|-f)  FORCE=true; shift ;;
    --help|-h)
      cat <<'USAGE'
BMAD Factory Pipeline — Bootstrap

Usage:
  bootstrap.sh --target <dir>    Install pipeline into target directory
  bootstrap.sh --here            Install into current directory

Options:
  --bare                         Convert to bare repo layout (worktree-based)
  --force                        Overwrite existing hook files
  --help                         Show this help

The target must be a git repository (or --bare will create one).
USAGE
      exit 0
      ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if [[ -z "${TARGET}" ]]; then
  echo "ERROR: Specify --target <dir> or --here"
  exit 1
fi

TARGET="$(cd "${TARGET}" 2>/dev/null && pwd || echo "${TARGET}")"

# ---------------------------------------------------------------------------
# Resolve layout: bare repo or standard
# ---------------------------------------------------------------------------
if [[ "${SETUP_BARE}" == "true" ]]; then
  PROJECT_ROOT="${TARGET}"
  MAIN_WORKTREE="${PROJECT_ROOT}/main"

  if [[ ! -d "${PROJECT_ROOT}/.bare" ]]; then
    echo "Setting up bare repo layout..."
    if [[ -d "${TARGET}/.git" ]]; then
      # Convert existing repo to bare layout
      mv "${TARGET}/.git" "${TARGET}/.bare"
      echo "gitdir: .bare" > "${TARGET}/.git"
      git -C "${TARGET}" worktree add "${MAIN_WORKTREE}" main 2>/dev/null || \
        git -C "${TARGET}" worktree add "${MAIN_WORKTREE}" HEAD 2>/dev/null || {
          echo "ERROR: Could not create main worktree. Check your default branch name."
          exit 1
        }
    elif [[ ! -d "${TARGET}" ]]; then
      mkdir -p "${TARGET}"
      git init --bare "${TARGET}/.bare"
      echo "gitdir: .bare" > "${TARGET}/.git"
      git -C "${TARGET}" worktree add "${MAIN_WORKTREE}" --orphan main 2>/dev/null || true
    else
      echo "ERROR: ${TARGET} exists but is not a git repo. Use --bare with git repos only."
      exit 1
    fi
    echo "Bare repo layout created at ${PROJECT_ROOT}"
  else
    echo "Bare repo already exists at ${PROJECT_ROOT}"
    MAIN_WORKTREE="${PROJECT_ROOT}/main"
  fi
else
  # Standard repo layout — everything in one directory
  if [[ ! -d "${TARGET}/.git" && ! -f "${TARGET}/.git" ]]; then
    echo "ERROR: ${TARGET} is not a git repository. Use --bare to create one, or git init first."
    exit 1
  fi
  PROJECT_ROOT="${TARGET}"
  MAIN_WORKTREE="${TARGET}"
fi

echo ""
echo "Installing BMAD Factory Pipeline"
echo "  Project root:  ${PROJECT_ROOT}"
echo "  Main worktree: ${MAIN_WORKTREE}"
echo ""

# ---------------------------------------------------------------------------
# 1. Copy hook scripts
# ---------------------------------------------------------------------------
echo "  [1/5] Installing hooks..."
mkdir -p "${MAIN_WORKTREE}/.claude/hooks/lib"

for hook in bash-guard.sh file-scope-guard.sh phase-router.sh post-edit.sh session-init.sh stop-evaluator.sh; do
  src="${PIPELINE_ROOT}/hooks/${hook}"
  dst="${MAIN_WORKTREE}/.claude/hooks/${hook}"
  if [[ -f "${dst}" && "${FORCE}" != "true" ]]; then
    echo "    Skip: ${hook} (exists, use --force to overwrite)"
  else
    cp "${src}" "${dst}"
    chmod +x "${dst}"
    echo "    Installed: ${hook}"
  fi
done

# Common library
src="${PIPELINE_ROOT}/hooks/lib/common.sh"
dst="${MAIN_WORKTREE}/.claude/hooks/lib/common.sh"
if [[ -f "${dst}" && "${FORCE}" != "true" ]]; then
  echo "    Skip: lib/common.sh (exists)"
else
  cp "${src}" "${dst}"
  chmod +x "${dst}"
  echo "    Installed: lib/common.sh"
fi

# README
[[ -f "${PIPELINE_ROOT}/hooks/README.md" ]] && \
  cp "${PIPELINE_ROOT}/hooks/README.md" "${MAIN_WORKTREE}/.claude/hooks/" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Install orchestration scripts
# ---------------------------------------------------------------------------
echo "  [2/5] Installing orchestration scripts..."

# For bare repo: scripts go at PROJECT_ROOT (sibling of main/)
# For standard: scripts go in the repo root
ORCH_TARGET="${PROJECT_ROOT}"

for script in run-factories.sh dispatcher.sh monitor.sh bmad-converter.py; do
  src="${PIPELINE_ROOT}/orchestration/${script}"
  dst="${ORCH_TARGET}/${script}"
  if [[ -f "${dst}" && "${FORCE}" != "true" ]]; then
    echo "    Skip: ${script} (exists)"
  else
    cp "${src}" "${dst}"
    [[ "${script}" == *.sh ]] && chmod +x "${dst}"
    [[ "${script}" == *.py ]] && chmod +x "${dst}"
    echo "    Installed: ${script}"
  fi
done

# ---------------------------------------------------------------------------
# 3. Generate CLAUDE.md
# ---------------------------------------------------------------------------
echo "  [3/5] Generating CLAUDE.md..."
CLAUDE_MD="${MAIN_WORKTREE}/CLAUDE.md"

if [[ -f "${CLAUDE_MD}" && "${FORCE}" != "true" ]]; then
  echo "    Skip: CLAUDE.md (exists, use --force to regenerate)"
else
  sed "s|{{PROJECT_ROOT}}|${PROJECT_ROOT}|g" \
    "${SCRIPT_DIR}/CLAUDE.md.template" > "${CLAUDE_MD}"
  echo "    Generated: CLAUDE.md"
fi

# ---------------------------------------------------------------------------
# 4. Create settings.local.json
# ---------------------------------------------------------------------------
echo "  [4/5] Setting up hook configuration..."
SETTINGS="${MAIN_WORKTREE}/.claude/settings.local.json"

if [[ -f "${SETTINGS}" && "${FORCE}" != "true" ]]; then
  echo "    Skip: settings.local.json (exists)"
else
  cp "${SCRIPT_DIR}/settings.local.json.template" "${SETTINGS}"
  echo "    Created: settings.local.json"
fi

# ---------------------------------------------------------------------------
# 5. Create directory structure
# ---------------------------------------------------------------------------
echo "  [5/5] Creating directory structure..."
mkdir -p "${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/logs"
echo "    Created: _bmad-output/implementation-artifacts/"
echo "    Created: _bmad-output/implementation-artifacts/logs/"

# Create .gitignore entries if not present
GITIGNORE="${MAIN_WORKTREE}/.gitignore"
if [[ -f "${GITIGNORE}" ]]; then
  for pattern in ".claude/.phase-state" "_bmad-output/implementation-artifacts/progress.log" "*.claude-pid"; do
    grep -qF "${pattern}" "${GITIGNORE}" 2>/dev/null || echo "${pattern}" >> "${GITIGNORE}"
  done
  echo "    Updated: .gitignore"
else
  cat > "${GITIGNORE}" << 'GIEOF'
# BMAD Pipeline runtime files
.claude/.phase-state
.claude/.exhaustion-wait
_bmad-output/implementation-artifacts/progress.log
*.claude-pid
node_modules/
GIEOF
  echo "    Created: .gitignore"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "  ✓ BMAD Factory Pipeline installed successfully!"
echo ""
echo "  Next steps:"
echo "    1. Ensure _bmad/ methodology is present (copy or git submodule)"
echo "    2. Create your sprint-status.yaml in _bmad-output/implementation-artifacts/"
echo "    3. Run: cd ${PROJECT_ROOT} && ./run-factories.sh"
echo "    4. Monitor: ./monitor.sh"
echo ""
if [[ "${SETUP_BARE}" != "true" && "${PROJECT_ROOT}" == "${MAIN_WORKTREE}" ]]; then
  echo "  Note: Running in standard repo mode. For worktree-based parallel builds,"
  echo "  re-run with --bare to convert to bare repo layout."
  echo ""
fi
