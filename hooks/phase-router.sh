#!/usr/bin/env bash
# ============================================================================
# phase-router.sh — UserPromptSubmit hook
#
# Fires on: every user prompt submission
# Purpose:  Enrich the prompt with current phase context; reject if invalid
# Output:   stdout → additionalContext prepended to prompt
# Exit 0:   allow prompt, Exit 2: reject prompt
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

STORY_KEY=$(get_current_story_key)

# If no story is active, let the prompt through unmodified
if [[ -z "${STORY_KEY}" ]]; then
  exit 0
fi

PHASE=$(get_current_phase)
WT_PATH=$(worktree_path "${STORY_KEY}")
TITLE=$(get_story_title "${STORY_KEY}")

# ---------------------------------------------------------------------------
# Parse the user's prompt from hook input
# ---------------------------------------------------------------------------
INPUT=$(read_hook_input)
USER_PROMPT=$(echo "${INPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('prompt', data.get('content', '')))
" 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# Reject prompts that would derail the current phase
# ---------------------------------------------------------------------------
# If user tries to manually switch stories mid-session, warn them
if echo "${USER_PROMPT}" | grep -qiE 'switch (to )?story|work on [A-Z]+-[0-9]+'; then
  echo "Cannot switch stories mid-session. Current story: ${STORY_KEY} [${PHASE}]." >&2
  echo "Complete or abandon this story first, then start a new session." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Inject phase-specific context
# ---------------------------------------------------------------------------
cat <<EOF
[BMAD Context — ${PHASE}]
Story: ${STORY_KEY} — ${TITLE}
Worktree: ${WT_PATH}
All file operations must target: ${WT_PATH}
EOF

# Phase-specific guidance
case "${PHASE}" in
  create-story)
    cat <<'GUIDANCE'

PHASE: create-story
- Read the story brief from the sprint backlog
- Generate implementation artifacts: component specs, interface contracts, test stubs
- Place artifacts in _bmad-output/implementation-artifacts/
- Do NOT write application code yet
- When done, state: "Phase create-story complete for STORY_KEY"
GUIDANCE
    ;;

  dev-story)
    cat <<'GUIDANCE'

PHASE: dev-story
- Implement the story according to the acceptance criteria and architecture docs
- Follow existing codebase patterns and conventions
- Write tests alongside implementation
- Run tests to verify they pass
- When done, state: "Phase dev-story complete for STORY_KEY"
GUIDANCE
    ;;

  code-review)
    cat <<'GUIDANCE'

PHASE: code-review
- Review all changes made during dev-story
- Check against acceptance criteria, architecture docs, and coding standards
- Fix ALL issues directly — do not create a task list
- If issues are found and fixed, run tests again
- When done with no remaining issues, state: "Phase code-review complete for STORY_KEY"
- If critical issues cannot be fixed, state: "Phase code-review FAILED for STORY_KEY"
GUIDANCE
    ;;
esac

# Replace STORY_KEY placeholder in guidance
# (sed on stdout would need a temp approach; Python is cleaner)

exit 0
