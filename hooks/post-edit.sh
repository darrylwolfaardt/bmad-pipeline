#!/usr/bin/env bash
# ============================================================================
# post-edit.sh — PostToolUse hook (matcher: Write|Edit|MultiEdit)
#
# Fires on: after every file write/edit completes
# Purpose:  Auto-format, stage changes, track progress
# Exit 0:   always (post hooks are non-blocking)
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INPUT=$(read_hook_input)
STORY_KEY=$(get_current_story_key)

# Extract the file path from tool input
FILE_PATH=$(echo "${INPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ti = data.get('tool_input', {})
print(ti.get('file_path', ti.get('path', '')))
" 2>/dev/null || echo "")

if [[ -z "${FILE_PATH}" || -z "${STORY_KEY}" ]]; then
  exit 0
fi

WT_PATH=$(worktree_path "${STORY_KEY}")
WORK_DIR="${WT_PATH:-${WORKTREE_DIR}}"

# ---------------------------------------------------------------------------
# 1. Auto-format based on file extension
# ---------------------------------------------------------------------------
EXT="${FILE_PATH##*.}"

format_file() {
  local file="$1"
  local ext="$2"

  case "${ext}" in
    php)
      # Laravel: use Pint if available
      if [[ -f "${WORK_DIR}/vendor/bin/pint" ]]; then
        "${WORK_DIR}/vendor/bin/pint" "${file}" --quiet 2>/dev/null || true
        log_info "Formatted (Pint): ${file}"
      fi
      ;;
    js|jsx|ts|tsx|vue|css|scss|json|md|yaml|yml)
      # Use Prettier if available
      if command -v npx &>/dev/null && [[ -f "${WORK_DIR}/node_modules/.bin/prettier" ]]; then
        npx --prefix "${WORK_DIR}" prettier --write "${file}" --log-level silent 2>/dev/null || true
        log_info "Formatted (Prettier): ${file}"
      fi
      ;;
    py)
      # Python: use Black or Ruff if available
      if command -v ruff &>/dev/null; then
        ruff format "${file}" --quiet 2>/dev/null || true
        log_info "Formatted (Ruff): ${file}"
      elif command -v black &>/dev/null; then
        black "${file}" --quiet 2>/dev/null || true
        log_info "Formatted (Black): ${file}"
      fi
      ;;
    blade.php)
      # Blade files — use blade-formatter if available
      if command -v blade-formatter &>/dev/null; then
        blade-formatter --write "${file}" 2>/dev/null || true
        log_info "Formatted (Blade): ${file}"
      fi
      ;;
  esac
}

# Handle blade.php separately (double extension)
if [[ "${FILE_PATH}" == *.blade.php ]]; then
  format_file "${FILE_PATH}" "blade.php"
else
  format_file "${FILE_PATH}" "${EXT}"
fi

# ---------------------------------------------------------------------------
# 2. Stage the file in git (within worktree)
# ---------------------------------------------------------------------------
if [[ -d "${WT_PATH}" ]]; then
  git -C "${WT_PATH}" add "${FILE_PATH}" 2>/dev/null || true
else
  git -C "${WORKTREE_DIR}" add "${FILE_PATH}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3. Track progress
# ---------------------------------------------------------------------------
PHASE=$(get_current_phase)
log_info "[${STORY_KEY}/${PHASE}] Edited: ${FILE_PATH}"

exit 0
