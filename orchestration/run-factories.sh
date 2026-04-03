#!/usr/bin/env bash
# ============================================================================
# run-factories.sh — BMAD Factory Pipeline
#
# Lives at: ProjectAlpha/ (bare repo root, outside any worktree)
#
# Flow:
#   1. Convert BMAD sprint-status.yaml → pipeline-status.yaml
#   2. Story factory creates stories (one session each, sequential)
#      ↕ runs concurrently with ↕
#   3. Dispatcher launches build workers as stories become eligible
#
# The factory and dispatcher run in parallel. As each story is created
# (with dependencies discovered), the dispatcher immediately evaluates
# whether to launch a build worker for it.
# ============================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_WORKTREE="${PROJECT_ROOT}/main"
CONVERTER="${PROJECT_ROOT}/bmad-converter.py"

export CLAUDE_PROJECT_DIR="${MAIN_WORKTREE}"
source "${MAIN_WORKTREE}/.claude/hooks/lib/common.sh"

# Defaults
MODE="full"
MAX_WORKERS=2
FACTORY_PARALLEL=1
SINGLE_STORY=""
BASE_BRANCH="${BMAD_BASE_BRANCH:-main}"
CLAUDE_FLAGS="${BMAD_CLAUDE_FLAGS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers|-w)           MAX_WORKERS="$2"; shift 2 ;;
    --factory-parallel|-fp) FACTORY_PARALLEL="$2"; shift 2 ;;
    --skip-factory)         MODE="dispatch-only"; shift ;;
    --factory-only)         MODE="factory-only"; shift ;;
    --dispatch-only)        MODE="dispatch-only"; shift ;;
    --story)                MODE="single"; SINGLE_STORY="$2"; shift 2 ;;
    --status)               MODE="status"; shift ;;
    --cleanup)              MODE="cleanup"; shift ;;
    --convert)              MODE="convert"; shift ;;
    --base)                 BASE_BRANCH="$2"; shift 2 ;;
    --ticket|-t)            export BMAD_TICKET="$2"; shift 2 ;;
    --push)                 export BMAD_AUTO_PUSH="true"; shift ;;
    --help|-h)
      cat <<'USAGE'
BMAD Factory Pipeline (bare repo layout)

Pipeline:
  (default)              Full: convert → factory + dispatcher concurrent
  --skip-factory         Skip to build dispatch
  --factory-only         Story factory only
  --dispatch-only        Build dispatcher only
  --story KEY            Single story, full pipeline (legacy)
  --convert              Convert BMAD format only, then stop

Options:
  --ticket ID            Linear ticket / requirement ID (e.g., RZP-1029)
  --workers N            Max parallel build workers (default: 2)
  --factory-parallel N   Parallel story creation (default: 1 = sequential)
  --base BRANCH          Base branch for worktrees (default: main)
  --push                 Auto-push on completion
  --status               Sprint status
  --cleanup              Remove completed worktrees
USAGE
      exit 0
      ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

# Re-source common.sh now that BMAD_TICKET may be set from --ticket flag
if [[ -n "${BMAD_TICKET:-}" ]]; then
  source "${MAIN_WORKTREE}/.claude/hooks/lib/common.sh"
  mkdir -p "${BMAD_ARTIFACTS_BASE}/logs"
  mkdir -p "${BMAD_PLANNING_BASE}"
fi

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(timestamp)] $*"; }

ensure_bare_repo() {
  if [[ ! -d "${PROJECT_ROOT}/.bare" ]] && [[ ! -f "${PROJECT_ROOT}/.git" ]]; then
    echo "ERROR: Not a bare repo layout. Run setup-bare-repo.sh first."
    exit 1
  fi
  [[ -d "${MAIN_WORKTREE}" ]] || { echo "ERROR: main/ worktree not found."; exit 1; }
}

ensure_converter() {
  [[ -f "${CONVERTER}" ]] || { echo "ERROR: bmad-converter.py not found at ${CONVERTER}"; exit 1; }
}

# ---------------------------------------------------------------------------
# Convert BMAD format → pipeline format
# ---------------------------------------------------------------------------
run_converter() {
  ensure_converter
  if [[ ! -f "${BMAD_SPRINT_FILE}" ]]; then
    echo "ERROR: BMAD sprint file not found: ${BMAD_SPRINT_FILE}"
    exit 1
  fi
  log "Converting BMAD format → pipeline format..."
  python3 "${CONVERTER}" convert "${PROJECT_ROOT}"
  log ""
}

# ---------------------------------------------------------------------------
# Prepare a worktree with hooks + artifacts from main/
# ---------------------------------------------------------------------------
prepare_worktree() {
  local target_dir="$1"
  mkdir -p "${target_dir}/.claude/hooks/lib"
  cp -r "${MAIN_WORKTREE}/.claude/hooks/"* "${target_dir}/.claude/hooks/" 2>/dev/null || true
  chmod +x "${target_dir}/.claude/hooks/"*.sh 2>/dev/null || true
  [[ -f "${MAIN_WORKTREE}/.claude/settings.local.json" ]] && \
    cp "${MAIN_WORKTREE}/.claude/settings.local.json" "${target_dir}/.claude/" 2>/dev/null || true
  [[ -d "${MAIN_WORKTREE}/_bmad" ]] && \
    ln -sfn "${MAIN_WORKTREE}/_bmad" "${target_dir}/_bmad" 2>/dev/null || true
  if [[ -d "${MAIN_WORKTREE}/_bmad-output" ]]; then
    mkdir -p "${target_dir}/_bmad-output/implementation-artifacts"
    cp -r "${BMAD_ARTIFACTS_BASE}/"* \
          "${target_dir}/_bmad-output/implementation-artifacts/" 2>/dev/null || true
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# STATUS
# ═══════════════════════════════════════════════════════════════════════════
if [[ "${MODE}" == "status" ]]; then
  ensure_bare_repo
  # Run converter status if available
  if [[ -f "${CONVERTER}" ]]; then
    python3 "${CONVERTER}" status "${PROJECT_ROOT}"
  fi
  echo "  Worktrees:"
  git -C "${PROJECT_ROOT}" worktree list 2>/dev/null | while IFS= read -r line; do
    echo "    ${line}"
  done
  echo ""
  # Also show pipeline status if it exists
  if [[ -f "${SPRINT_FILE}" ]]; then
    for status in ready-for-dev story-created dev-complete review-failed review-escalated done failed; do
      stories=$(get_stories_by_status "${status}")
      [[ -z "${stories}" ]] && continue
      count=$(echo "${stories}" | wc -l | tr -d ' ')
      echo "  ${status} (${count}):"
      while IFS= read -r key; do
        title=$(get_story_title "${key}")
        deps=$(get_story_dependencies "${key}")
        dep_ok="✓"; [[ -n "${deps}" ]] && { deps_satisfied "${key}" || dep_ok="✗"; }
        wt=""; [[ -d "${PROJECT_ROOT}/${key}" ]] && wt=" [worktree]"
        active=""
        [[ -f "${PROJECT_ROOT}/${key}/.claude-pid" ]] && {
          pid=$(cat "${PROJECT_ROOT}/${key}/.claude-pid")
          kill -0 "${pid}" 2>/dev/null && active=" [ACTIVE]"
        }
        echo "    ${key} — ${title} (deps: ${dep_ok})${wt}${active}"
      done <<< "${stories}"
      echo ""
    done
  fi
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# CONVERT ONLY
# ═══════════════════════════════════════════════════════════════════════════
if [[ "${MODE}" == "convert" ]]; then
  ensure_bare_repo
  run_converter
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════════
if [[ "${MODE}" == "cleanup" ]]; then
  ensure_bare_repo
  log "Cleaning up completed worktrees..."
  if [[ -f "${SPRINT_FILE}" ]]; then
    for status in done failed review-escalated; do
      stories=$(get_stories_by_status "${status}")
      [[ -z "${stories}" ]] && continue
      while IFS= read -r key; do
        wt_path="${PROJECT_ROOT}/${key}"
        [[ -d "${wt_path}" ]] && {
          git -C "${PROJECT_ROOT}" worktree remove "${wt_path}" --force 2>/dev/null && \
            log "Removed: ${wt_path}" || log "Failed: ${wt_path}"
        }
      done <<< "${stories}"
    done
  fi
  git -C "${PROJECT_ROOT}" worktree prune 2>/dev/null || true
  # Sync statuses back to BMAD
  [[ -f "${CONVERTER}" ]] && python3 "${CONVERTER}" sync-back "${PROJECT_ROOT}" 2>/dev/null || true
  log "Done."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# SINGLE STORY (legacy)
# ═══════════════════════════════════════════════════════════════════════════
if [[ "${MODE}" == "single" ]]; then
  ensure_bare_repo; ensure_converter
  run_converter
  title=$(get_story_title "${SINGLE_STORY}")
  log "═══ Single Story: ${SINGLE_STORY} — ${title} ═══"

  worktree_create "${SINGLE_STORY}" "${BASE_BRANCH}"
  wt_path="${PROJECT_ROOT}/${SINGLE_STORY}"
  prepare_worktree "${wt_path}"

  (
    cd "${wt_path}" && \
    BMAD_FACTORY_MODE=legacy \
    BMAD_STORY_KEY="${SINGLE_STORY}" \
    BMAD_BASE_BRANCH="${BASE_BRANCH}" \
    run_claude_with_retry "legacy:${SINGLE_STORY}" \
      -p "Work on story ${SINGLE_STORY}: ${title}" \
      --model "${MODEL_CREATE}" \
      --dangerously-skip-permissions \
      ${CLAUDE_FLAGS}
  )

  # Sync back
  python3 "${CONVERTER}" sync-back "${PROJECT_ROOT}" 2>/dev/null || true
  log "Done."
  exit 0
fi

ensure_bare_repo
ensure_converter
mkdir -p "${LOG_DIR}"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 0: CONVERT
# ═══════════════════════════════════════════════════════════════════════════
run_converter

if [[ ! -f "${SPRINT_FILE}" ]]; then
  echo "ERROR: Conversion failed — ${SPRINT_FILE} not created."
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# STAGE 1 + STAGE 2: CONCURRENT FACTORY + DISPATCHER
#
# The story factory creates stories one at a time (sequential within epics).
# After each creation, it updates pipeline-status.yaml with deps.
# Meanwhile, the dispatcher watches for eligible stories and launches
# build workers as dependencies clear.
#
# This means a story with no deps can start building while later stories
# are still being created by the factory.
# ═══════════════════════════════════════════════════════════════════════════

# Outer loop: keep running factory + dispatcher passes until all stories are processed
# This handles the case where factory sessions fail (e.g., rate limits) and need retry
MAX_PIPELINE_PASSES=5
PIPELINE_PASS=0

while true; do
  PIPELINE_PASS=$((PIPELINE_PASS + 1))
  READY_COUNT=$(get_stories_by_status "ready-for-dev" | wc -l | tr -d ' ')
  CREATED_COUNT=$(get_stories_by_status "story-created" | wc -l | tr -d ' ')

if [[ "${MODE}" == "dispatch-only" ]]; then
  log ""
  log "═══════════════════════════════════════════════════════════"
  log "  Dispatch-only: ${MAX_WORKERS} workers"
  log "═══════════════════════════════════════════════════════════"
  exec "${PROJECT_ROOT}/dispatcher.sh" --workers "${MAX_WORKERS}"
fi

log ""
log "═══════════════════════════════════════════════════════════"
log "  BMAD Factory Pipeline"
log "  Stories: ${READY_COUNT} ready, ${CREATED_COUNT} created"
log "  Factory parallel: ${FACTORY_PARALLEL}"
log "  Build workers: ${MAX_WORKERS}"
log "═══════════════════════════════════════════════════════════"

RETRO_PENDING=$(epics_needing_retro | wc -l | tr -d ' ')
RETRO_PENDING=${RETRO_PENDING:-0}

if [[ ${READY_COUNT} -eq 0 && ${CREATED_COUNT} -eq 0 && ${RETRO_PENDING} -eq 0 ]]; then
  log "No stories to process and no retrospectives pending."
  exit 0
fi

# If only retros are pending (no stories to create/build), skip to retro phase
if [[ ${READY_COUNT} -eq 0 && ${CREATED_COUNT} -eq 0 && ${RETRO_PENDING} -gt 0 ]]; then
  log ""
  log "  No stories to process. ${RETRO_PENDING} retrospective(s) pending."
  log "  Skipping factory and dispatcher — running retrospectives only."
fi

# ---------------------------------------------------------------------------
# Launch dispatcher in background (it will wait for eligible stories)
# ---------------------------------------------------------------------------
DISPATCHER_PID=""
if [[ "${MODE}" != "factory-only" && ( ${READY_COUNT} -gt 0 || ${CREATED_COUNT} -gt 0 ) ]]; then
  log ""
  log "  Starting dispatcher in background (${MAX_WORKERS} workers)..."
  "${PROJECT_ROOT}/dispatcher.sh" --workers "${MAX_WORKERS}" &
  DISPATCHER_PID=$!
  log "  Dispatcher PID: ${DISPATCHER_PID}"
fi

# ---------------------------------------------------------------------------
# Run story factory (foreground)
# ---------------------------------------------------------------------------
if [[ ${READY_COUNT} -gt 0 ]]; then
  log ""
  log "  Starting story factory..."

  READY_STORIES=$(get_stories_by_status "ready-for-dev")

  if [[ ${FACTORY_PARALLEL} -le 1 ]]; then
    # Sequential: each story gets a fresh session
    while IFS= read -r story_key; do
      [[ -z "${story_key}" ]] && continue
      # Re-check status (dispatcher might have been fed this story via another path)
      status=$(get_story_status "${story_key}")
      [[ "${status}" != "ready-for-dev" ]] && { log "  Skip ${story_key} (${status})"; continue; }

      # Retro gate: don't create stories if a completed epic still needs retrospective
      if ! is_retro_gate_clear; then
        log "  Skip ${story_key} — waiting for retrospective to complete"
        continue
      fi

      title=$(get_story_title "${story_key}")
      log ""
      log "  ┌── Creating: ${story_key} — ${title}"

      FACTORY_LOG="${LOG_DIR}/${story_key}-create.log"

      (
        cd "${MAIN_WORKTREE}" && \
        BMAD_FACTORY_MODE=story-factory \
        BMAD_STORY_KEY="${story_key}" \
        BMAD_BASE_BRANCH="${BASE_BRANCH}" \
        run_claude_with_retry "factory:${story_key}" \
          -p "Create implementation artifacts for story ${story_key}: ${title}" \
          --model "${MODEL_CREATE}" \
          --dangerously-skip-permissions \
          ${CLAUDE_FLAGS}
      ) >> "${FACTORY_LOG}" 2>&1 || true

      new_status=$(get_story_status "${story_key}")
      if [[ "${new_status}" == "story-created" ]]; then
        deps=$(get_story_dependencies "${story_key}")
        log "  └── Done: ${story_key} → story-created (deps: ${deps:-none})"
      else
        log "  └── WARNING: ${story_key} still ${new_status}"
        [[ -d "${BMAD_ARTIFACTS_BASE}/${story_key}" ]] && {
          update_story_status "${story_key}" "story-created"
          log "       Forced → story-created (artifacts exist)"
        }
      fi

    done <<< "${READY_STORIES}"

  else
    # Parallel factory
    declare -A FACTORY_PIDS=()

    while IFS= read -r story_key; do
      [[ -z "${story_key}" ]] && continue
      status=$(get_story_status "${story_key}")
      [[ "${status}" != "ready-for-dev" ]] && continue

      while [[ ${#FACTORY_PIDS[@]} -ge ${FACTORY_PARALLEL} ]]; do
        for k in "${!FACTORY_PIDS[@]}"; do
          if ! kill -0 "${FACTORY_PIDS[$k]}" 2>/dev/null; then
            wait "${FACTORY_PIDS[$k]}" 2>/dev/null || true
            ns=$(get_story_status "${k}")
            log "  Factory done: ${k} → ${ns}"
            [[ "${ns}" != "story-created" ]] && \
              [[ -d "${BMAD_ARTIFACTS_BASE}/${k}" ]] && \
              update_story_status "${k}" "story-created"
            unset "FACTORY_PIDS[${k}]"
          fi
        done
        [[ ${#FACTORY_PIDS[@]} -ge ${FACTORY_PARALLEL} ]] && sleep 5
      done

      title=$(get_story_title "${story_key}")
      log "  Launching factory: ${story_key} — ${title}"

      (
        cd "${MAIN_WORKTREE}" && \
        BMAD_FACTORY_MODE=story-factory \
        BMAD_STORY_KEY="${story_key}" \
        BMAD_BASE_BRANCH="${BASE_BRANCH}" \
        run_claude_with_retry "factory:${story_key}" \
          -p "Create implementation artifacts for story ${story_key}: ${title}" \
          --model "${MODEL_CREATE}" \
          --dangerously-skip-permissions \
          ${CLAUDE_FLAGS}
      ) >> "${LOG_DIR}/${story_key}-create.log" 2>&1 &

      FACTORY_PIDS["${story_key}"]=$!
      sleep 2
    done <<< "${READY_STORIES}"

    for k in "${!FACTORY_PIDS[@]}"; do
      wait "${FACTORY_PIDS[$k]}" 2>/dev/null || true
      ns=$(get_story_status "${k}")
      [[ "${ns}" != "story-created" ]] && \
        [[ -d "${BMAD_ARTIFACTS_BASE}/${k}" ]] && \
        update_story_status "${k}" "story-created"
    done
  fi

  FINAL_CREATED=$(get_stories_by_status "story-created" | wc -l | tr -d ' ')
  log ""
  log "  Story factory complete. Created: ${FINAL_CREATED}"
fi

# ---------------------------------------------------------------------------
# Wait for dispatcher to finish (if running)
# ---------------------------------------------------------------------------
if [[ -n "${DISPATCHER_PID}" ]]; then
  if [[ "${MODE}" == "factory-only" ]]; then
    # Kill the dispatcher if factory-only mode
    kill "${DISPATCHER_PID}" 2>/dev/null || true
    log "Factory-only mode. Dispatcher stopped."
  else
    log ""
    log "  Factory complete. Waiting for dispatcher to finish all build workers..."
    wait "${DISPATCHER_PID}" 2>/dev/null || true
    log "  Dispatcher complete."
  fi
fi

  # ---------------------------------------------------------------------------
  # Run retrospectives for completed epics (promotion gate)
  # This reconciles what was built against specs and updates baseline docs
  # so the next epic's create-story phase has accurate context.
  # ---------------------------------------------------------------------------
  RETRO_EPICS=$(epics_needing_retro)
  if [[ -n "${RETRO_EPICS}" ]]; then
    while IFS= read -r epic; do
      [[ -z "${epic}" ]] && continue
      epic_num=$(get_epic_number "${epic}")
      log ""
      log "  ┌── Retrospective: ${epic}"
      log "  │   Promoting proven patterns to baseline docs"

      RETRO_LOG="${LOG_DIR}/${epic}-retrospective.log"

      (
        cd "${MAIN_WORKTREE}" && \
        BMAD_FACTORY_MODE=retrospective \
        BMAD_STORY_KEY="${epic}" \
        run_claude_with_retry "retro:${epic}" \
          -p "Run the BMAD retrospective for ${epic} (epic ${epic_num}). All stories in this epic are done.

Your job is doc PROMOTION, not just review. You must:

1. ANALYZE: Read completed story artifacts in ${BMAD_ARTIFACTS_BASE}/ for all stories in this epic. Read the baseline docs at ${BMAD_BASELINE_BASE}/ (prd.md, architecture.md, epics.md). Also read the ticket sub-PRD at ${BMAD_PLANNING_BASE}/ if it exists and differs from baseline — reconcile what was built against what was specified.

2. WRITE RETRO REPORT: Save to ${BMAD_ARTIFACTS_BASE}/${epic}-retro-$(date +%Y-%m-%d).md with: what was built, what diverged from spec, lessons learned, action items.

3. PROMOTE TO BASELINE - this is the critical step. Update the BASELINE living docs (not the ticket sub-PRD):
   - ${BMAD_BASELINE_BASE}/prd.md: mark delivered FRs/NFRs as DELIVERED, note scope changes
   - ${BMAD_BASELINE_BASE}/architecture.md: promote speculative decisions to PROVEN, add patterns discovered during implementation. Create this file if it does not exist.
   - ${BMAD_BASELINE_BASE}/epics.md: mark this epic as COMPLETED with summary

4. ARCHIVE: If a ticket sub-PRD exists at ${BMAD_PLANNING_BASE}/prd.md and it differs from baseline, add an ARCHIVED header with the date.

5. The pipeline handles the git log. Your baseline doc changes ARE the promotion. The next create-story reads these updated docs for accurate context.

Do NOT ask for confirmation. Proceed autonomously. When complete, state: Phase retrospective complete for ${epic}" \
          --model "${MODEL_REVIEW}" \
          --dangerously-skip-permissions \
          ${CLAUDE_FLAGS}
      ) >> "${RETRO_LOG}" 2>&1 || true

      # Check if retro completed (look for completion in log or just mark done)
      if grep -qiE "phase retrospective complete|retrospective complete for ${epic}" "${RETRO_LOG}" 2>/dev/null; then
        update_retro_status "${epic}" "done"
        log "  └── Done: ${epic} retrospective complete"
      else
        # Force done if log exists and has content (retro ran but may not have used exact phrase)
        if [[ -s "${RETRO_LOG}" ]]; then
          update_retro_status "${epic}" "done"
          log "  └── Done: ${epic} retrospective complete (forced)"
        else
          log "  └── WARNING: ${epic} retrospective may have failed"
        fi
      fi

      # Sync back to pipeline format
      python3 "${CONVERTER}" sync-back "${PROJECT_ROOT}" 2>/dev/null || true

    done <<< "${RETRO_EPICS}"
  fi

  # Check if there are remaining stories needing processing
  REMAINING_READY=$(get_stories_by_status "ready-for-dev" | wc -l | tr -d ' ')
  REMAINING_ACTIONABLE=$(( $(get_stories_by_status "story-created" | wc -l | tr -d ' ') + $(get_stories_by_status "dev-complete" | wc -l | tr -d ' ') + $(get_stories_by_status "review-failed" | wc -l | tr -d ' ') ))

  REMAINING_RETRO=$(epics_needing_retro | wc -l | tr -d ' ')
  REMAINING_RETRO=${REMAINING_RETRO:-0}

  if [[ ${REMAINING_READY} -eq 0 && ${REMAINING_ACTIONABLE} -eq 0 && ${REMAINING_RETRO} -eq 0 ]]; then
    log ""
    log "  All stories processed and retrospectives complete."
    break
  fi

  if [[ ${REMAINING_READY} -eq 0 && ${REMAINING_ACTIONABLE} -eq 0 && ${REMAINING_RETRO} -gt 0 ]]; then
    log ""
    log "  Stories done. ${REMAINING_RETRO} retrospective(s) remaining — looping."
  fi

  if [[ ${PIPELINE_PASS} -ge ${MAX_PIPELINE_PASSES} ]]; then
    log ""
    log "  WARNING: Max pipeline passes (${MAX_PIPELINE_PASSES}) reached."
    log "  Remaining: ${REMAINING_READY} ready-for-dev, ${REMAINING_ACTIONABLE} actionable"
    break
  fi

  log ""
  log "  Pipeline pass ${PIPELINE_PASS} complete. ${REMAINING_READY} stories still need creation."
  log "  Starting pass $((PIPELINE_PASS + 1))..."
  # Re-sync before next pass
  python3 "${CONVERTER}" sync-back "${PROJECT_ROOT}" 2>/dev/null || true

done  # end outer pipeline loop

# ---------------------------------------------------------------------------
# Final sync back to BMAD
# ---------------------------------------------------------------------------
python3 "${CONVERTER}" sync-back "${PROJECT_ROOT}" 2>/dev/null || true
log ""
log "Pipeline complete. BMAD sprint-status.yaml synced."
