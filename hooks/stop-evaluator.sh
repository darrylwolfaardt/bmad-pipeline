#!/usr/bin/env bash
# ============================================================================
# stop-evaluator.sh — Stop hook (factory-aware)
#
# Modes:
#   story-factory  → detect single story completion, exit 0 (one session per story)
#   build-worker   → dev-story ↔ code-review loop, exit 0 when story done
#   legacy         → full create→dev→review pipeline
#
# Exit 0: session complete | Exit 2: loop (stderr → Claude's next prompt)
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

INPUT=$(read_hook_input)
STORY_KEY=$(get_current_story_key)
FACTORY_MODE=$(get_current_factory_mode)

log_info "Stop hook fired: story=${STORY_KEY:-NONE} mode=${FACTORY_MODE} phase_file=${PHASE_STATE_FILE}"

if [[ -z "${STORY_KEY}" ]]; then
  log_info "Stop hook: no story key, exiting"
  exit 0
fi

PHASE=$(get_current_phase)
TITLE=$(get_story_title "${STORY_KEY}")
WT_PATH=$(worktree_path "${STORY_KEY}")

# Parse Claude's last output
STOP_REASON=$(echo "${INPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Try multiple known JSON structures from Claude Code stop hook
content = ''
# Structure 1: {content: [...]} (array of content blocks)
c = data.get('content', '')
if isinstance(c, list):
    content = ' '.join(str(blk.get('text', '')) for blk in c if isinstance(blk, dict))
elif isinstance(c, str) and c:
    content = c
# Structure 2: {message: {content: ...}}
if not content:
    m = data.get('message', '')
    if isinstance(m, str):
        content = m
    elif isinstance(m, dict):
        mc = m.get('content', '')
        if isinstance(mc, list):
            content = ' '.join(str(blk.get('text', '')) for blk in mc if isinstance(blk, dict))
        elif isinstance(mc, str):
            content = mc
# Structure 3: {result: ...} or {text: ...}
if not content:
    content = str(data.get('result', data.get('text', data.get('stop_reason', ''))))
# Structure 4: fallback to full JSON dump for pattern matching
if not content or content == 'None':
    content = json.dumps(data)
print(str(content)[:3000])
" 2>/dev/null || echo "")

log_info "Stop hook STOP_REASON (first 200 chars): ${STOP_REASON:0:200}"

# Review iteration tracking
REVIEW_COUNT_FILE="${WT_PATH:-${WORKTREE_DIR}}/.claude/.review-count"
MAX_REVIEW_ITERATIONS="${BMAD_MAX_REVIEW_ITERATIONS:-3}"

# ═══════════════════════════════════════════════════════════════════════════
# STORY FACTORY MODE — one story per session, no looping
# ═══════════════════════════════════════════════════════════════════════════
if [[ "${FACTORY_MODE}" == "story-factory" ]]; then

  if echo "${STOP_REASON}" | grep -qiE "story artifacts complete for ${STORY_KEY}|story artifacts complete|phase create-story complete for ${STORY_KEY}|phase create-story complete"; then

    # Read dependency declaration if the story factory wrote one
    DEPS_FILE="${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/${STORY_KEY}/deps.yaml"
    if [[ -f "${DEPS_FILE}" ]]; then
      DECLARED_DEPS=$(python3 -c "
import yaml
with open('${DEPS_FILE}') as f:
    data = yaml.safe_load(f)
deps = data.get('depends_on', [])
if deps:
    print(','.join(str(d) for d in deps))
else:
    print('none')
" 2>/dev/null || echo "none")

      if [[ "${DECLARED_DEPS}" != "none" && -n "${DECLARED_DEPS}" ]]; then
        update_story_deps "${STORY_KEY}" "${DECLARED_DEPS}"
        log_info "Story factory: ${STORY_KEY} deps → ${DECLARED_DEPS}"
      fi
    fi

    update_story_status "${STORY_KEY}" "story-created"
    log_info "Story factory: ${STORY_KEY} → story-created"
    echo '{"status": "story-created", "story": "'"${STORY_KEY}"'"}'
    exit 0
  fi

  # If Claude finished without the completion signal, it may still be working
  # or may have hit an issue. Let it end — the outer loop will detect the
  # status is still ready-for-dev and can retry.
  log_warn "Story factory: ${STORY_KEY} session ended without completion signal"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# RETROSPECTIVE MODE — epic-level doc promotion
# ═══════════════════════════════════════════════════════════════════════════
if [[ "${FACTORY_MODE}" == "retrospective" ]]; then
  if echo "${STOP_REASON}" | grep -qiE "phase retrospective complete|retrospective complete for ${STORY_KEY}"; then
    update_retro_status "${STORY_KEY}" "done"
    log_info "Retrospective: ${STORY_KEY} → done"
    echo '{"status": "retro-complete", "epic": "'"${STORY_KEY}"'"}'
    exit 0
  fi

  log_warn "Retrospective: ${STORY_KEY} session ended without completion signal"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# BUILD WORKER MODE — one phase per session, dispatcher manages transitions
# Each phase exits 0 so dispatcher can relaunch with the correct model:
#   dev-story  → Sonnet  |  code-review → Opus
# ═══════════════════════════════════════════════════════════════════════════
if [[ "${FACTORY_MODE}" == "build-worker" ]]; then

  case "${PHASE}" in

    dev-story)
      if echo "${STOP_REASON}" | grep -qiE "phase dev-story complete"; then
        git_wip_commit "${STORY_KEY}" "dev-story"
        update_story_status "${STORY_KEY}" "dev-complete"
        set_phase_state "${STORY_KEY}" "code-review"
        log_info "Build worker: ${STORY_KEY} dev-story complete → awaiting code-review (Opus)"
        echo '{"status": "dev-complete", "story": "'"${STORY_KEY}"'", "next_phase": "code-review"}'
        exit 0  # dispatcher will relaunch with Opus
      fi

      if echo "${STOP_REASON}" | grep -qiE "phase.*failed|FAILED"; then
        update_story_status "${STORY_KEY}" "failed"
        git_wip_commit "${STORY_KEY}" "dev-story-failed"
        log_error "Build worker: ${STORY_KEY} dev-story FAILED"
        exit 0
      fi
      exit 0
      ;;

    code-review)
      if echo "${STOP_REASON}" | grep -qiE "phase code-review complete"; then
        git_final_commit "${STORY_KEY}" "${TITLE}"
        update_story_status "${STORY_KEY}" "done"
        set_phase_state "${STORY_KEY}" "done"
        rm -f "${REVIEW_COUNT_FILE}"

        if [[ "${BMAD_AUTO_PUSH:-false}" == "true" ]]; then
          git_in_worktree push -u origin "feature/${STORY_KEY}" 2>/dev/null || true
          log_info "Pushed feature/${STORY_KEY}"
        fi

        log_info "Build worker COMPLETE: ${STORY_KEY}"
        echo '{"status": "complete", "story": "'"${STORY_KEY}"'", "branch": "feature/'"${STORY_KEY}"'"}'
        exit 0
      fi

      if echo "${STOP_REASON}" | grep -qiE "phase.*failed|FAILED|critical.*issue"; then
        REVIEW_COUNT=$(cat "${REVIEW_COUNT_FILE}" 2>/dev/null || echo "0")
        REVIEW_COUNT=$((REVIEW_COUNT + 1))
        echo "${REVIEW_COUNT}" > "${REVIEW_COUNT_FILE}"

        if [[ ${REVIEW_COUNT} -ge ${MAX_REVIEW_ITERATIONS} ]]; then
          update_story_status "${STORY_KEY}" "review-escalated"
          git_wip_commit "${STORY_KEY}" "review-escalated-iter-${REVIEW_COUNT}"
          log_error "Build worker: ${STORY_KEY} escalated after ${REVIEW_COUNT} iterations"
          exit 0
        fi

        git_wip_commit "${STORY_KEY}" "review-fixes-iter-${REVIEW_COUNT}"
        update_story_status "${STORY_KEY}" "review-failed"
        set_phase_state "${STORY_KEY}" "dev-story"
        log_info "Build worker: ${STORY_KEY} review failed → awaiting dev-story fixes (Sonnet)"
        echo '{"status": "review-failed", "story": "'"${STORY_KEY}"'", "iteration": '"${REVIEW_COUNT}"'}'
        exit 0  # dispatcher will relaunch with Sonnet for fixes
      fi
      exit 0
      ;;

    *) exit 0 ;;
  esac
fi

# ═══════════════════════════════════════════════════════════════════════════
# LEGACY MODE — full create→dev→review pipeline in one session
# ═══════════════════════════════════════════════════════════════════════════

phase_complete() {
  echo "${STOP_REASON}" | grep -qiE "phase ${PHASE} complete|${PHASE}.*complete for ${STORY_KEY}"
}
phase_failed() {
  echo "${STOP_REASON}" | grep -qiE "phase.*failed|FAILED for ${STORY_KEY}|cannot.*fix|critical.*issue"
}

case "${PHASE}" in

  create-story)
    if phase_complete; then
      git_wip_commit "${STORY_KEY}" "create-story"
      update_story_status "${STORY_KEY}" "story-created"
      set_phase_state "${STORY_KEY}" "dev-story"
      log_info "Legacy: ${STORY_KEY} create-story → dev-story"
      cat >&2 <<EOF
Phase create-story complete. Now execute dev-story for ${STORY_KEY} — ${TITLE}.
Worktree: ${WT_PATH}. Implement per acceptance criteria. Write tests.
When done: "Phase dev-story complete for ${STORY_KEY}"
EOF
      exit 2
    fi
    exit 0
    ;;

  dev-story)
    if phase_complete; then
      git_wip_commit "${STORY_KEY}" "dev-story"
      echo "0" > "${REVIEW_COUNT_FILE}"
      update_story_status "${STORY_KEY}" "dev-complete"
      set_phase_state "${STORY_KEY}" "code-review"
      log_info "Legacy: ${STORY_KEY} dev-story → code-review"
      cat >&2 <<EOF
Phase dev-story complete. Now execute code-review for ${STORY_KEY} — ${TITLE}.
Worktree: ${WT_PATH}. Fix ALL issues directly. No task lists.
When done: "Phase code-review complete for ${STORY_KEY}"
EOF
      exit 2
    fi
    if phase_failed; then
      update_story_status "${STORY_KEY}" "failed"
      git_wip_commit "${STORY_KEY}" "dev-story-failed"
      exit 0
    fi
    exit 0
    ;;

  code-review)
    if phase_complete; then
      git_final_commit "${STORY_KEY}" "${TITLE}"
      update_story_status "${STORY_KEY}" "done"
      set_phase_state "${STORY_KEY}" "done"
      rm -f "${REVIEW_COUNT_FILE}"
      [[ "${BMAD_AUTO_PUSH:-false}" == "true" ]] && \
        git_in_worktree push -u origin "feature/${STORY_KEY}" 2>/dev/null || true
      log_info "Legacy COMPLETE: ${STORY_KEY}"
      echo '{"status": "complete", "story": "'"${STORY_KEY}"'"}'
      exit 0
    fi
    if phase_failed; then
      REVIEW_COUNT=$(cat "${REVIEW_COUNT_FILE}" 2>/dev/null || echo "0")
      REVIEW_COUNT=$((REVIEW_COUNT + 1))
      echo "${REVIEW_COUNT}" > "${REVIEW_COUNT_FILE}"
      if [[ ${REVIEW_COUNT} -ge ${MAX_REVIEW_ITERATIONS} ]]; then
        update_story_status "${STORY_KEY}" "review-escalated"
        git_wip_commit "${STORY_KEY}" "review-escalated-iter-${REVIEW_COUNT}"
        exit 0
      fi
      git_wip_commit "${STORY_KEY}" "review-fixes-iter-${REVIEW_COUNT}"
      set_phase_state "${STORY_KEY}" "dev-story"
      update_story_status "${STORY_KEY}" "review-failed"
      cat >&2 <<EOF
Code review issues (iteration ${REVIEW_COUNT}/${MAX_REVIEW_ITERATIONS}).
Fix all issues for ${STORY_KEY}. When done: "Phase dev-story complete for ${STORY_KEY}"
EOF
      exit 2
    fi
    exit 0
    ;;

  *) exit 0 ;;
esac
