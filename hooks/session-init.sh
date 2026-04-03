#!/usr/bin/env bash
# ============================================================================
# session-init.sh — SessionStart hook (factory-aware)
#
# Modes (BMAD_FACTORY_MODE):
#   story-factory  → single story creation, fresh context per story
#   build-worker   → single story dev+review in worktree
#   legacy         → single story full pipeline
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INPUT=$(read_hook_input)
SESSION_TYPE=$(echo "${INPUT}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type','startup'))" 2>/dev/null || echo "startup")
FACTORY_MODE=$(get_current_factory_mode)

# ---------------------------------------------------------------------------
# Resume / compact — re-read existing state
# ---------------------------------------------------------------------------
if [[ "${SESSION_TYPE}" == "resume" || "${SESSION_TYPE}" == "compact" ]]; then
  STORY_KEY=$(get_current_story_key)
  if [[ -n "${STORY_KEY}" ]]; then
    PHASE=$(get_current_phase)
    TITLE=$(get_story_title "${STORY_KEY}")
    WT_PATH=$(worktree_path "${STORY_KEY}")
    cat <<EOF
[BMAD Session Resumed — ${FACTORY_MODE}]
Story: ${STORY_KEY} — ${TITLE} | Phase: ${PHASE}
Worktree: ${WT_PATH}
Continue the current phase. Do not restart.
EOF
    exit 0
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# STORY FACTORY MODE — one story per session, fresh context
# ═══════════════════════════════════════════════════════════════════════════
if [[ "${FACTORY_MODE}" == "story-factory" ]]; then

  STORY_KEY="${BMAD_STORY_KEY:-}"
  if [[ -z "${STORY_KEY}" ]]; then
    echo "[BMAD Story Factory] ERROR: BMAD_STORY_KEY not set."
    exit 0
  fi

  TITLE=$(get_story_title "${STORY_KEY}")
  DEPS=$(get_story_dependencies "${STORY_KEY}")
  set_phase_state "${STORY_KEY}" "create-story"

  # Build a list of all stories in the sprint for cross-reference context
  ALL_STORIES=""
  while IFS= read -r key; do
    t=$(get_story_title "${key}")
    s=$(get_story_status "${key}")
    d=$(get_story_dependencies "${key}")
    ALL_STORIES="${ALL_STORIES}
  - ${key}: ${t} [${s}] (depends on: ${d:-none})"
  done <<< "$(get_all_stories)"

  cat <<EOF
[BMAD Story Factory — Single Story Session]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Story:        ${STORY_KEY} — ${TITLE}
Dependencies: ${DEPS:-none}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Sprint context (all stories):${ALL_STORIES}

INSTRUCTIONS:
1. Create implementation artifacts for story ${STORY_KEY}:
   - Component specifications
   - Interface contracts (inputs, outputs, API shapes)
   - Test stubs / acceptance-criteria checklists
   - Any architectural notes specific to this story
2. Place ALL artifacts in: _bmad-output/implementation-artifacts/${STORY_KEY}/
3. DEPENDENCY ANALYSIS — this is critical:
   - Review the sprint context above and any prior story artifacts on disk
   - Determine which other stories THIS story depends on
   - A dependency exists if this story needs code, interfaces, or data from another story
   - Write a file: _bmad-output/implementation-artifacts/${STORY_KEY}/deps.yaml
     containing exactly:
       depends_on:
         - "1-1"    # example: key of story this depends on
     or if no dependencies:
       depends_on: []
   - Be precise — false dependencies block parallel execution
   - If unsure, err toward no dependency (the code review will catch issues)
4. When complete, state: "Story artifacts complete for ${STORY_KEY}"
5. Do NOT write application code — only specs and planning artifacts
EOF

  # Reference artifacts from previously-created stories (on disk, not in context)
  ARTIFACT_BASE="${MAIN_WORKTREE}/_bmad-output/implementation-artifacts"
  PRIOR_STORIES=""

  # Check ALL created stories for relevant context (not just declared deps)
  CREATED=$(get_stories_by_status "story-created")
  if [[ -n "${CREATED}" ]]; then
    while IFS= read -r prior_key; do
      [[ -d "${ARTIFACT_BASE}/${prior_key}" ]] && PRIOR_STORIES="${PRIOR_STORIES} ${prior_key}"
    done <<< "${CREATED}"
  fi

  if [[ -n "${PRIOR_STORIES}" ]]; then
    echo ""
    echo "--- Dependency artifacts available on disk ---"
    for dep in ${PRIOR_STORIES}; do
      echo ""
      echo "=== ${dep} ==="
      for f in "${ARTIFACT_BASE}/${dep}"/*.md "${ARTIFACT_BASE}/${dep}"/*.yaml "${ARTIFACT_BASE}/${dep}"/*.json; do
        [[ -f "${f}" ]] || continue
        echo "  File: $(basename "${f}")"
        # Include key interface files in context, summarise others
        if echo "${f}" | grep -qiE '(interface|contract|api|schema)'; then
          echo "  --- content ---"
          head -100 "${f}"
          echo "  --- end ---"
        else
          echo "  (available at ${f} — read if needed)"
        fi
      done
    done
    echo "--- end dependency artifacts ---"
  fi

  # Load BMAD create-story workflow template
  BMAD_FILE=$(find_bmad_file "create-story" 2>/dev/null || true)
  if [[ -n "${BMAD_FILE}" ]]; then
    echo ""
    echo "--- BMAD create-story workflow ---"
    cat "${BMAD_FILE}"
    echo "--- end workflow ---"
  fi

  log_info "Story factory session: ${STORY_KEY}"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# BUILD WORKER MODE — single story dev+review in worktree
# ═══════════════════════════════════════════════════════════════════════════
if [[ "${FACTORY_MODE}" == "build-worker" ]]; then

  STORY_KEY="${BMAD_STORY_KEY:-}"
  if [[ -z "${STORY_KEY}" ]]; then
    echo "[BMAD Build Worker] ERROR: BMAD_STORY_KEY not set."
    exit 0
  fi

  TITLE=$(get_story_title "${STORY_KEY}")
  STATUS=$(get_story_status "${STORY_KEY}")
  BASE_BRANCH="${BMAD_BASE_BRANCH:-main}"

  PHASE="dev-story"
  if [[ "${STATUS}" == "dev-complete" ]]; then
    PHASE="code-review"
  elif [[ "${STATUS}" == "review-failed" ]]; then
    PHASE="dev-story"
  fi

  worktree_create "${STORY_KEY}" "${BASE_BRANCH}"
  WT_PATH=$(worktree_path "${STORY_KEY}")

  # Copy story artifacts into worktree
  if [[ -d "${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/${STORY_KEY}" ]]; then
    mkdir -p "${WT_PATH}/_bmad-output/implementation-artifacts/"
    cp -r "${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/${STORY_KEY}" \
          "${WT_PATH}/_bmad-output/implementation-artifacts/" 2>/dev/null || true
  fi
  # Also copy dependency story artifacts so the worker can reference interfaces
  DEPS=$(get_story_dependencies "${STORY_KEY}")
  if [[ -n "${DEPS}" ]]; then
    for dep in ${DEPS}; do
      if [[ -d "${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/${dep}" ]]; then
        cp -r "${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/${dep}" \
              "${WT_PATH}/_bmad-output/implementation-artifacts/" 2>/dev/null || true
      fi
    done
  fi
  if [[ -f "${SPRINT_FILE}" ]]; then
    mkdir -p "$(dirname "${WT_PATH}/_bmad-output/implementation-artifacts/pipeline-status.yaml")"
    cp "${SPRINT_FILE}" "${WT_PATH}/_bmad-output/implementation-artifacts/pipeline-status.yaml" 2>/dev/null || true
  fi

  set_phase_state "${STORY_KEY}" "${PHASE}"

  cat <<EOF
[BMAD Build Worker]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Story:     ${STORY_KEY} — ${TITLE}
Phase:     ${PHASE}
Worktree:  ${WT_PATH}
Branch:    feature/${STORY_KEY}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

INSTRUCTIONS:
- All file operations MUST target: ${WT_PATH}
- Execute BMAD /${PHASE} for story ${STORY_KEY}
- Follow acceptance criteria precisely
- Do not switch branches or modify files outside the worktree
- When complete: "Phase ${PHASE} complete for ${STORY_KEY}"
EOF

  # Inject story artifacts
  ARTIFACT_DIR="${WT_PATH}/_bmad-output/implementation-artifacts/${STORY_KEY}"
  if [[ -d "${ARTIFACT_DIR}" ]]; then
    echo ""
    echo "--- Story Artifacts (from story factory) ---"
    for f in "${ARTIFACT_DIR}"/*.md "${ARTIFACT_DIR}"/*.yaml "${ARTIFACT_DIR}"/*.json; do
      [[ -f "${f}" ]] || continue
      echo ""
      echo "=== $(basename "${f}") ==="
      head -200 "${f}"
    done
    echo "--- end artifacts ---"
  fi

  BMAD_FILE=$(find_bmad_file "${PHASE}" 2>/dev/null || true)
  if [[ -n "${BMAD_FILE}" ]]; then
    echo ""
    echo "--- BMAD ${PHASE} workflow ---"
    cat "${BMAD_FILE}"
    echo "--- end workflow ---"
  fi

  log_info "Build worker: ${STORY_KEY} [${PHASE}] in ${WT_PATH}"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# LEGACY MODE — single story, full pipeline
# ═══════════════════════════════════════════════════════════════════════════
STORY_KEY="${BMAD_STORY_KEY:-}"
[[ -z "${STORY_KEY}" ]] && STORY_KEY=$(next_ready_story)
if [[ -z "${STORY_KEY}" ]]; then
  echo "[BMAD] No stories with status 'ready-for-dev'."
  exit 0
fi

TITLE=$(get_story_title "${STORY_KEY}")
STATUS=$(get_story_status "${STORY_KEY}")
BASE_BRANCH="${BMAD_BASE_BRANCH:-main}"

case "${STATUS}" in
  ready-for-dev)  PHASE="create-story" ;;
  story-created)  PHASE="dev-story" ;;
  dev-complete)   PHASE="code-review" ;;
  review-failed)  PHASE="dev-story" ;;
  *)              PHASE="create-story" ;;
esac

worktree_create "${STORY_KEY}" "${BASE_BRANCH}"
WT_PATH=$(worktree_path "${STORY_KEY}")
[[ -f "${SPRINT_FILE}" ]] && {
  mkdir -p "$(dirname "${WT_PATH}/_bmad-output/implementation-artifacts/pipeline-status.yaml")"
  cp "${SPRINT_FILE}" "${WT_PATH}/_bmad-output/implementation-artifacts/pipeline-status.yaml" 2>/dev/null || true
}
set_phase_state "${STORY_KEY}" "${PHASE}"

cat <<EOF
[BMAD Autonomous Development]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Story: ${STORY_KEY} — ${TITLE} | Phase: ${PHASE}
Worktree: ${WT_PATH} | Branch: feature/${STORY_KEY}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- All file operations target: ${WT_PATH}
- Execute BMAD /${PHASE} for ${STORY_KEY}
- When complete: "Phase ${PHASE} complete for ${STORY_KEY}"
EOF

BMAD_FILE=$(find_bmad_file "${PHASE}" 2>/dev/null || true)
[[ -n "${BMAD_FILE}" ]] && { echo ""; cat "${BMAD_FILE}"; }
log_info "Legacy session: ${STORY_KEY} [${PHASE}]"
exit 0
