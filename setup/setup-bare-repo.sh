#!/usr/bin/env bash
# ============================================================================
# setup-bare-repo.sh — Initialise the bare repo + worktree structure
#
# Creates:
#   ProjectAlpha/
#     .bare/              ← bare git repository
#     .git                ← gitdir pointer (so git works from root)
#     main/               ← worktree for main branch
#
# Usage:
#   From an existing repo:
#     ./setup-bare-repo.sh /path/to/existing-repo ProjectAlpha
#
#   From a remote:
#     ./setup-bare-repo.sh git@github.com:user/project.git ProjectAlpha
#
#   Convert current directory (already a git repo):
#     ./setup-bare-repo.sh . ProjectAlpha
# ============================================================================
set -euo pipefail

SOURCE="${1:?Usage: $0 <source-repo-or-url> <project-dir>}"
PROJECT_DIR="${2:?Usage: $0 <source-repo-or-url> <project-dir>}"
MAIN_BRANCH="${3:-main}"  # override if your default branch is different

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(timestamp)] $*"; }

# ---------------------------------------------------------------------------
# Create project root
# ---------------------------------------------------------------------------
if [[ -d "${PROJECT_DIR}" ]]; then
  echo "ERROR: ${PROJECT_DIR} already exists."
  exit 1
fi

mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}"
PROJECT_DIR="$(pwd)"

log "Creating bare repo structure in ${PROJECT_DIR}"

# ---------------------------------------------------------------------------
# Clone or copy bare repo
# ---------------------------------------------------------------------------
if [[ "${SOURCE}" == "." ]]; then
  # Converting current repo — clone it bare
  ORIGINAL_DIR="$(cd .. && pwd)/$(basename "$(pwd)")"
  log "Cloning from local repo: ${ORIGINAL_DIR}"
  git clone --bare "${ORIGINAL_DIR}" .bare
elif [[ -d "${SOURCE}/.git" ]] || [[ -d "${SOURCE}" && "$(git -C "${SOURCE}" rev-parse --is-bare-repository 2>/dev/null)" == "true" ]]; then
  # Local repo path
  log "Cloning from local repo: ${SOURCE}"
  git clone --bare "${SOURCE}" .bare
else
  # Remote URL
  log "Cloning from remote: ${SOURCE}"
  git clone --bare "${SOURCE}" .bare
fi

# ---------------------------------------------------------------------------
# Create .git pointer so git commands work from project root
# ---------------------------------------------------------------------------
echo "gitdir: .bare" > .git

# Configure fetch to track all remote branches
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

# Fetch to ensure we have all branch refs
git fetch origin 2>/dev/null || true

log "Bare repo ready at ${PROJECT_DIR}/.bare"

# ---------------------------------------------------------------------------
# Create main worktree
# ---------------------------------------------------------------------------
git worktree add main "${MAIN_BRANCH}"
log "Main worktree created at ${PROJECT_DIR}/main"

# ---------------------------------------------------------------------------
# Copy orchestration scripts to project root (outside git)
# ---------------------------------------------------------------------------
cat > "${PROJECT_DIR}/.gitignore" <<'GITIGNORE'
# Bare repo internals
.bare/
.git

# Orchestration scripts (live outside git)
run-factories.sh
dispatcher.sh
setup-bare-repo.sh

# Worktrees (managed by scripts, not tracked)
# Each worktree directory except main/ is temporary
GITIGNORE

log ""
log "═══════════════════════════════════════════════════════════"
log "  Setup complete!"
log "═══════════════════════════════════════════════════════════"
log ""
log "  Project root:  ${PROJECT_DIR}"
log "  Bare repo:     ${PROJECT_DIR}/.bare"
log "  Main worktree: ${PROJECT_DIR}/main"
log ""
log "  Next steps:"
log "    1. Copy run-factories.sh and dispatcher.sh to ${PROJECT_DIR}/"
log "    2. Copy .claude/hooks/ into ${PROJECT_DIR}/main/.claude/hooks/"
log "    3. Ensure sprint-status.yaml is in main/_bmad-output/..."
log "    4. Run: cd ${PROJECT_DIR} && ./run-factories.sh"
log ""
log "  Worktree commands (from ${PROJECT_DIR}):"
log "    git worktree list"
log "    git worktree add REMS-101 -b feature/REMS-101 ${MAIN_BRANCH}"
log "    git worktree remove REMS-101"
log ""
