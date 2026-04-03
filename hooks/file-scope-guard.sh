#!/usr/bin/env bash
# ============================================================================
# file-scope-guard.sh — PreToolUse hook (matcher: Write|Edit|MultiEdit)
#
# Fires on: every file write/edit tool invocation
# Purpose:  Ensure edits stay within the worktree; block protected files
# Exit 0:   allow, Exit 2: block
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INPUT=$(read_hook_input)
STORY_KEY=$(get_current_story_key)

# Extract the file path from the tool input
FILE_PATH=$(echo "${INPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ti = data.get('tool_input', {})
print(ti.get('file_path', ti.get('path', '')))
" 2>/dev/null || echo "")

if [[ -z "${FILE_PATH}" ]]; then
  exit 0  # no file path to check
fi

# ---------------------------------------------------------------------------
# 1. Protected files — never modify these via automation
# ---------------------------------------------------------------------------
PROTECTED_PATTERNS=(
  '\.env$'
  '\.env\.'
  'docker-compose\.prod'
  'Dockerfile\.prod'
  '/migrations/.*\.php$'  # existing migrations; new ones are OK via artisan
  'composer\.lock$'
  'package-lock\.json$'
  'yarn\.lock$'
  '\.claude/settings\.json$'
  '\.claude/hooks/'
  'sprint-status\.yaml$'
  'pipeline-status\.yaml$'
)

for pattern in "${PROTECTED_PATTERNS[@]}"; do
  if echo "${FILE_PATH}" | grep -qE "${pattern}"; then
    echo "BLOCKED: ${FILE_PATH} is a protected file." >&2
    echo "This file should not be modified during automated development." >&2
    log_warn "Blocked edit to protected file: ${FILE_PATH}"
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# 2. Worktree boundary enforcement
# ---------------------------------------------------------------------------
if [[ -n "${STORY_KEY}" ]]; then
  WT_PATH=$(worktree_path "${STORY_KEY}")

  if [[ -d "${WT_PATH}" ]]; then
    # Resolve to absolute path for comparison
    ABS_FILE=$(realpath -m "${FILE_PATH}" 2>/dev/null || echo "${FILE_PATH}")
    ABS_WT=$(realpath "${WT_PATH}" 2>/dev/null || echo "${WT_PATH}")

    if [[ "${ABS_FILE}" != "${ABS_WT}"* ]]; then
      echo "BLOCKED: File ${FILE_PATH} is outside the worktree (${WT_PATH})." >&2
      echo "All edits must be within the story worktree." >&2
      log_warn "Blocked out-of-worktree edit: ${FILE_PATH}"
      exit 2
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3. Phase-appropriate file checks
# ---------------------------------------------------------------------------
PHASE=$(get_current_phase)

case "${PHASE}" in
  create-story)
    # During create-story, only allow writes to BMAD artifact dirs
    if ! echo "${FILE_PATH}" | grep -qE '(_bmad-output|\.claude|docs|specs)'; then
      echo "BLOCKED: During create-story phase, only artifact/spec files should be created." >&2
      echo "Application code changes belong in the dev-story phase." >&2
      exit 2
    fi
    ;;
  code-review)
    # During code-review, allow fixes but log them prominently
    log_info "Code-review fix: ${FILE_PATH}"
    ;;
esac

log_info "File edit allowed: ${FILE_PATH}"
exit 0
