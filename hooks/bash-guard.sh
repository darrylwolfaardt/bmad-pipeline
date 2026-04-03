#!/usr/bin/env bash
# ============================================================================
# bash-guard.sh — PreToolUse hook (matcher: Bash)
#
# Fires on: every Bash tool invocation
# Purpose:  Block destructive commands, enforce worktree boundaries
# Exit 0:   allow, Exit 2: block
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INPUT=$(read_hook_input)

# Extract the command being run
COMMAND=$(echo "${INPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ti = data.get('tool_input', {})
print(ti.get('command', ti.get('input', '')))
" 2>/dev/null || echo "")

if [[ -z "${COMMAND}" ]]; then
  exit 0  # no command to evaluate
fi

STORY_KEY=$(get_current_story_key)

# ---------------------------------------------------------------------------
# 1. Block destructive commands (always)
# ---------------------------------------------------------------------------
DESTRUCTIVE_PATTERNS=(
  'rm -rf /'
  'rm -rf \.'
  'rm -rf ~'
  'DROP TABLE'
  'DROP DATABASE'
  'TRUNCATE TABLE'
  'DELETE FROM .* WHERE 1'
  'mkfs\.'
  'dd if=.* of=/dev/'
  '> /dev/sd'
  'chmod -R 777 /'
  'curl .* [|] sh'
  'wget .* [|] sh'
)

for pattern in "${DESTRUCTIVE_PATTERNS[@]}"; do
  if echo "${COMMAND}" | grep -qE "${pattern}"; then
    echo "BLOCKED: Destructive command detected — ${pattern}" >&2
    log_error "Blocked destructive command: ${COMMAND}"
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# 2. Block git branch switching (worktree isolation)
# ---------------------------------------------------------------------------
if echo "${COMMAND}" | grep -qE 'git (checkout|switch) [^-]'; then
  # Allow checkout of files (git checkout -- file) but not branches
  if ! echo "${COMMAND}" | grep -qE 'git checkout (--|\.)'; then
    echo "BLOCKED: Do not switch branches. You are in a worktree on feature/${STORY_KEY}." >&2
    echo "All work must stay on the current branch." >&2
    exit 2
  fi
fi

# Block git worktree manipulation (the orchestrator manages worktrees)
if echo "${COMMAND}" | grep -qE 'git worktree (add|remove|prune)'; then
  echo "BLOCKED: Worktree management is handled by the orchestrator." >&2
  exit 2
fi

# Block direct commits (the stop-evaluator handles commits)
if echo "${COMMAND}" | grep -qE 'git commit'; then
  echo "BLOCKED: Commits are managed by the pipeline hooks. Focus on implementation." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 3. Enforce worktree boundary (if a story is active)
# ---------------------------------------------------------------------------
if [[ -n "${STORY_KEY}" ]]; then
  WT_PATH=$(worktree_path "${STORY_KEY}")

  # Check if the command references paths outside the worktree
  # Allow common safe commands that don't modify files
  SAFE_COMMANDS='(ls|cat|head|tail|grep|find|wc|file|stat|which|echo|printf|test|true|false|pwd|env|whoami)'
  if ! echo "${COMMAND}" | grep -qE "^${SAFE_COMMANDS}"; then
    # Check for absolute paths outside worktree
    if echo "${COMMAND}" | grep -qE '(^|[ ;|&])/(?!tmp|dev/null)' && \
       ! echo "${COMMAND}" | grep -q "${WT_PATH}"; then
      # Warn but don't block — some commands legitimately need system paths
      log_warn "Command references paths outside worktree: ${COMMAND}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Log and allow
# ---------------------------------------------------------------------------
log_info "Bash allowed: ${COMMAND:0:120}"
exit 0
