#!/usr/bin/env bash
# ============================================================================
# dispatcher.sh — Dependency-aware build worker dispatcher
#
# Lives at: ProjectAlpha/ (bare repo root)
# Creates:  ProjectAlpha/{story-key}/ worktrees as siblings of main/
# ============================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_WORKTREE="${PROJECT_ROOT}/main"

export CLAUDE_PROJECT_DIR="${MAIN_WORKTREE}"
source "${MAIN_WORKTREE}/.claude/hooks/lib/common.sh"

MAX_WORKERS=2
POLL_INTERVAL=15
DRY_RUN=false
BASE_BRANCH="${BMAD_BASE_BRANCH:-main}"
CLAUDE_FLAGS="${BMAD_CLAUDE_FLAGS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers|-w)       MAX_WORKERS="$2"; shift 2 ;;
    --poll-interval|-i) POLL_INTERVAL="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --help|-h)          echo "Usage: $0 [--workers N] [--poll-interval S] [--dry-run]"; exit 0 ;;
    *)                  echo "Unknown: $1"; exit 1 ;;
  esac
done

mkdir -p "${LOG_DIR}"

# ---------------------------------------------------------------------------
# Worker tracking
# ---------------------------------------------------------------------------
declare -A ACTIVE_WORKERS=()
declare -A LAUNCH_COUNTS=()
MAX_RELAUNCH=3

cleanup_finished_workers() {
  local keys=("${!ACTIVE_WORKERS[@]}")
  [[ ${#keys[@]} -eq 0 ]] && return
  for key in "${keys[@]}"; do
    local pid="${ACTIVE_WORKERS[$key]}"
    if ! kill -0 "${pid}" 2>/dev/null; then
      local status
      status=$(get_story_status "${key}")
      log "Worker finished: ${key} (PID ${pid}) → ${status}"
      unset "ACTIVE_WORKERS[${key}]"
      rm -f "${PROJECT_ROOT}/${key}/.claude-pid" 2>/dev/null || true
    fi
  done
}

active_worker_count() {
  cleanup_finished_workers
  echo "${#ACTIVE_WORKERS[@]}"
}

is_worker_active() {
  local key="$1"
  [[ ${#ACTIVE_WORKERS[@]} -gt 0 && -n "${ACTIVE_WORKERS[$key]+x}" ]]
}

# ---------------------------------------------------------------------------
# Launch a build worker in its own worktree
# Usage: launch_worker <story_key> <phase>
#   phase: dev-story (Sonnet) or code-review (Opus)
# ---------------------------------------------------------------------------
launch_worker() {
  local story_key="$1"
  local phase="${2:-dev-story}"
  local title
  title=$(get_story_title "${story_key}")
  local model
  model=$(model_for_phase "${phase}")
  local wt_path="${PROJECT_ROOT}/${story_key}"

  log "┌── Launching: ${story_key} — ${title}"
  log "│   Phase: ${phase} | Model: ${model}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "│   [DRY RUN] Would create worktree at ${wt_path}"
    log "└── Skipped"
    return
  fi

  # Create worktree as sibling of main/
  worktree_create "${story_key}" "${BASE_BRANCH}"

  # Clean up stale exhaustion sentinel
  rm -f "${wt_path}/.claude/.exhaustion-wait" 2>/dev/null || true

  # Copy hooks, settings, artifacts from main/ into the worktree
  mkdir -p "${wt_path}/.claude/hooks/lib"
  cp -r "${MAIN_WORKTREE}/.claude/hooks/"* "${wt_path}/.claude/hooks/" 2>/dev/null || true
  chmod +x "${wt_path}/.claude/hooks/"*.sh 2>/dev/null || true
  [[ -f "${MAIN_WORKTREE}/.claude/settings.local.json" ]] && \
    cp "${MAIN_WORKTREE}/.claude/settings.local.json" "${wt_path}/.claude/" 2>/dev/null || true

  # Symlink BMAD methodology (shared, read-only)
  [[ -d "${MAIN_WORKTREE}/_bmad" ]] && ln -sfn "${MAIN_WORKTREE}/_bmad" "${wt_path}/_bmad" 2>/dev/null || true

  # Copy story artifacts + sprint file
  mkdir -p "${wt_path}/_bmad-output/implementation-artifacts"
  [[ -d "${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/${story_key}" ]] && \
    cp -r "${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/${story_key}" \
          "${wt_path}/_bmad-output/implementation-artifacts/" 2>/dev/null || true
  # Copy dependency artifacts too
  local deps
  deps=$(get_story_dependencies "${story_key}")
  for dep in ${deps}; do
    [[ -d "${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/${dep}" ]] && \
      cp -r "${MAIN_WORKTREE}/_bmad-output/implementation-artifacts/${dep}" \
            "${wt_path}/_bmad-output/implementation-artifacts/" 2>/dev/null || true
  done
  [[ -f "${SPRINT_FILE}" ]] && \
    cp "${SPRINT_FILE}" "${wt_path}/_bmad-output/implementation-artifacts/pipeline-status.yaml" 2>/dev/null || true

  # Build the prompt based on phase
  local prompt
  case "${phase}" in
    dev-story)
      prompt="Implement story ${story_key}: ${title}. Follow the BMAD dev-story workflow."
      ;;
    code-review)
      prompt="Code review story ${story_key}: ${title}. Review all changes, fix all issues directly. Follow the BMAD code-review workflow."
      ;;
    *)
      prompt="Work on story ${story_key}: ${title}"
      ;;
  esac

  local log_file="${LOG_DIR}/${story_key}-${phase}.log"

  # Launch Claude Code in the worktree with phase-appropriate model
  (
    cd "${wt_path}" && \
    BMAD_FACTORY_MODE=build-worker \
    BMAD_STORY_KEY="${story_key}" \
    BMAD_BASE_BRANCH="${BASE_BRANCH}" \
    BMAD_AUTO_PUSH="${BMAD_AUTO_PUSH:-false}" \
    BMAD_MAX_REVIEW_ITERATIONS="${BMAD_MAX_REVIEW_ITERATIONS:-3}" \
    run_claude_with_retry "worker:${story_key}:${phase}" \
      -p "${prompt}" \
      --model "${model}" \
      --dangerously-skip-permissions \
      ${CLAUDE_FLAGS}
  ) >> "${log_file}" 2>&1 &

  local pid=$!
  ACTIVE_WORKERS["${story_key}"]="${pid}"
  echo "${pid}" > "${wt_path}/.claude-pid"

  log "│   Worktree: ${wt_path}"
  log "│   Branch:   feature/${story_key}"
  log "│   PID:      ${pid}"
  log "└── Launched"
}

# ---------------------------------------------------------------------------
# Main dispatch loop
# ---------------------------------------------------------------------------
log "═══════════════════════════════════════════════════════════"
log "  BMAD Build Dispatcher"
log "  Project:  ${PROJECT_ROOT}"
log "  Workers:  ${MAX_WORKERS} | Poll: ${POLL_INTERVAL}s"
log "═══════════════════════════════════════════════════════════"

build_dependency_graph

IDLE_CYCLES=0
MAX_IDLE_CYCLES=40

while true; do
  # Run cleanup in main process so array modifications persist
  cleanup_finished_workers
  active="${#ACTIVE_WORKERS[@]}"

  # Build launchable queue: key:phase pairs
  # Each status maps to a specific phase and model
  unset LAUNCH_QUEUE 2>/dev/null || true
  declare -A LAUNCH_QUEUE

  # story-created + deps satisfied → dev-story (Sonnet)
  ELIGIBLE=$(get_eligible_stories)
  if [[ -n "${ELIGIBLE}" ]]; then
    while IFS= read -r key; do
      if ! is_worker_active "${key}"; then
        count="${LAUNCH_COUNTS[${key}]:-0}"
        if [[ ${count} -lt ${MAX_RELAUNCH} ]]; then
          LAUNCH_QUEUE["${key}"]="dev-story"
        else
          log "Skipping ${key}: relaunched ${count} times without progress"
        fi
      fi
    done <<< "${ELIGIBLE}"
  fi

  # dev-complete → code-review (Opus)
  DEV_DONE=$(get_stories_by_status "dev-complete")
  if [[ -n "${DEV_DONE}" ]]; then
    while IFS= read -r key; do
      is_worker_active "${key}" || LAUNCH_QUEUE["${key}"]="code-review"
    done <<< "${DEV_DONE}"
  fi

  # review-failed → dev-story fixes (Sonnet)
  RETRYABLE=$(get_stories_by_status "review-failed")
  if [[ -n "${RETRYABLE}" ]]; then
    while IFS= read -r key; do
      is_worker_active "${key}" || LAUNCH_QUEUE["${key}"]="dev-story"
    done <<< "${RETRYABLE}"
  fi

  slots=$((MAX_WORKERS - active))
  launch_keys=("${!LAUNCH_QUEUE[@]}")

  if [[ ${#launch_keys[@]} -gt 0 && ${slots} -gt 0 ]]; then
    IDLE_CYCLES=0
    launched=0
    for key in "${launch_keys[@]}"; do
      [[ ${launched} -ge ${slots} ]] && break
      phase="${LAUNCH_QUEUE[$key]}"
      launch_worker "${key}" "${phase}"
      LAUNCH_COUNTS["${key}"]=$(( ${LAUNCH_COUNTS[${key}]:-0} + 1 ))
      launched=$((launched + 1))
      sleep 2
    done
  else
    IDLE_CYCLES=$((IDLE_CYCLES + 1))

    if [[ ${active} -eq 0 ]]; then
      remaining=false
      for s in ready-for-dev story-created dev-complete review-failed; do
        c=$(get_stories_by_status "${s}" | wc -l | tr -d ' ')
        [[ ${c} -gt 0 ]] && { remaining=true; break; }
      done

      if [[ "${remaining}" == "false" ]]; then
        log ""
        log "═══════════════════════════════════════════════════════════"
        log "  All stories processed. Dispatcher complete."
        log "═══════════════════════════════════════════════════════════"
        done_c=$(get_stories_by_status "done" | wc -l | tr -d ' ')
        failed_c=$(get_stories_by_status "failed" | wc -l | tr -d ' ')
        esc_c=$(get_stories_by_status "review-escalated" | wc -l | tr -d ' ')
        log "  Done: ${done_c} | Failed: ${failed_c} | Escalated: ${esc_c}"
        break
      fi

      # Only count toward deadlock if there are dispatcher-actionable stories
      # ready-for-dev stories are handled by the factory, not the dispatcher
      actionable_count=0
      for s in story-created dev-complete review-failed; do
        c=$(get_stories_by_status "${s}" | wc -l | tr -d ' ')
        c=${c:-0}
        actionable_count=$((actionable_count + c))
      done

      if [[ ${actionable_count} -eq 0 ]]; then
        # Only ready-for-dev remain — factory is responsible, not us
        log "No actionable stories (only ready-for-dev). Exiting dispatcher — factory will relaunch if needed."
        break
      fi

      if [[ ${IDLE_CYCLES} -ge ${MAX_IDLE_CYCLES} ]]; then
        log ""
        log "WARNING: Idle for $((IDLE_CYCLES * POLL_INTERVAL))s — possible deadlock."
        for s in story-created dev-complete review-failed; do
          stuck=$(get_stories_by_status "${s}")
          [[ -n "${stuck}" ]] && while IFS= read -r key; do
            deps=$(get_story_dependencies "${key}")
            log "  ${key} [${s}] → waiting on: ${deps:-nothing}"
          done <<< "${stuck}"
        done
        break
      fi
    fi

    [[ $((IDLE_CYCLES % 4)) -eq 0 ]] && log "Waiting... (${active} active, idle ${IDLE_CYCLES})"
  fi

  sleep "${POLL_INTERVAL}"
done
