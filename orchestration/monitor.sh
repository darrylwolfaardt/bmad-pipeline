#!/usr/bin/env bash
# ============================================================================
# monitor.sh — Live pipeline monitor with spinners and failure detection
#
# Usage:
#   ./monitor.sh              Watch the pipeline (updates every 3s)
#   ./monitor.sh --once       Print status once and exit
#   ./monitor.sh --tail       Monitor + tail latest active log
#
# Sits alongside run-factories.sh at the project root.
# ============================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_WORKTREE="${PROJECT_ROOT}/main"
export CLAUDE_PROJECT_DIR="${MAIN_WORKTREE}"
source "${MAIN_WORKTREE}/.claude/hooks/lib/common.sh"

POLL=15
MODE="watch"
[[ "${1:-}" == "--once" ]] && MODE="once"
[[ "${1:-}" == "--tail" ]] && MODE="tail"

# ---------------------------------------------------------------------------
# Colours and symbols
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  R='\033[0;31m'    # red
  G='\033[0;32m'    # green
  Y='\033[0;33m'    # yellow
  B='\033[0;34m'    # blue
  M='\033[0;35m'    # magenta
  C='\033[0;36m'    # cyan
  W='\033[1;37m'    # white bold
  D='\033[0;90m'    # dim
  N='\033[0m'       # reset
  UL='\033[4m'      # underline
else
  R=''; G=''; Y=''; B=''; M=''; C=''; W=''; D=''; N=''; UL=''
fi

SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
SPIN_IDX=0

spin() {
  local char="${SPINNER_CHARS:SPIN_IDX:1}"
  SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER_CHARS} ))
  echo -n "${char}"
}

# ---------------------------------------------------------------------------
# Status symbols and labels
# ---------------------------------------------------------------------------
status_icon() {
  local status="$1"
  case "${status}" in
    ready-for-dev)     echo -e "${D}○${N}" ;;
    story-created)     echo -e "${B}◆${N}" ;;
    dev-complete)      echo -e "${C}◆${N}" ;;
    review-failed)     echo -e "${Y}↻${N}" ;;
    review-escalated)  echo -e "${R}⚠${N}" ;;
    done)              echo -e "${G}✓${N}" ;;
    failed)            echo -e "${R}✗${N}" ;;
    *)                 echo -e "${D}?${N}" ;;
  esac
}

status_label() {
  local status="$1"
  case "${status}" in
    ready-for-dev)     echo -e "${D}queued${N}" ;;
    story-created)     echo -e "${B}spec'd${N}" ;;
    dev-complete)      echo -e "${C}built${N}" ;;
    review-failed)     echo -e "${Y}fix needed${N}" ;;
    review-escalated)  echo -e "${R}escalated${N}" ;;
    done)              echo -e "${G}done${N}" ;;
    failed)            echo -e "${R}FAILED${N}" ;;
    *)                 echo -e "${D}${status}${N}" ;;
  esac
}

phase_label() {
  local phase="$1"
  case "${phase}" in
    create-story) echo -e "${M}create-story${N} ${D}(Opus)${N}" ;;
    dev-story)    echo -e "${C}dev-story${N} ${D}(Sonnet)${N}" ;;
    code-review)  echo -e "${Y}code-review${N} ${D}(Opus)${N}" ;;
    done)         echo -e "${G}complete${N}" ;;
    *)            echo "${phase}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Elapsed time formatting
# ---------------------------------------------------------------------------
format_elapsed() {
  local seconds="$1"
  if [[ ${seconds} -lt 60 ]]; then
    echo "${seconds}s"
  elif [[ ${seconds} -lt 3600 ]]; then
    echo "$((seconds / 60))m $((seconds % 60))s"
  else
    echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
  fi
}

# ---------------------------------------------------------------------------
# Detect active processes
# ---------------------------------------------------------------------------
get_worker_pid() {
  local key="$1"
  local wt="${PROJECT_ROOT}/${key}"
  local pid_file="${wt}/.claude-pid"
  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}" 2>/dev/null)
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      echo "${pid}"
      return 0
    fi
  fi
  return 1
}

get_factory_pid() {
  # Check for factory claude process running in main worktree
  ps aux 2>/dev/null | grep -E "claude -p.*Create implementation" | grep -v grep | awk '{print $2}' | head -1
}

get_factory_story() {
  # Read current factory story from main phase-state
  local ps_file="${MAIN_WORKTREE}/.claude/.phase-state"
  if [[ -f "${ps_file}" ]]; then
    local mode key
    mode=$(grep '^FACTORY_MODE=' "${ps_file}" 2>/dev/null | cut -d= -f2)
    key=$(grep '^STORY_KEY=' "${ps_file}" 2>/dev/null | cut -d= -f2)
    if [[ "${mode}" == "story-factory" && -n "${key}" ]]; then
      echo "${key}"
    fi
  fi
}

is_exhaustion_waiting() {
  local key="$1"
  local sentinel="${PROJECT_ROOT}/${key}/.claude/.exhaustion-wait"
  [[ -f "${sentinel}" ]]
}

get_exhaustion_info() {
  local key="$1"
  local sentinel="${PROJECT_ROOT}/${key}/.claude/.exhaustion-wait"
  if [[ -f "${sentinel}" ]]; then
    cat "${sentinel}" 2>/dev/null
  fi
}

# Get elapsed time since phase-state was updated
get_phase_elapsed() {
  local key="$1"
  local ps_file="${PROJECT_ROOT}/${key}/.claude/.phase-state"
  [[ -f "${ps_file}" ]] || { ps_file="${MAIN_WORKTREE}/.claude/.phase-state"; }
  if [[ -f "${ps_file}" ]]; then
    local updated_at
    updated_at=$(grep '^UPDATED_AT=' "${ps_file}" 2>/dev/null | cut -d= -f2)
    if [[ -n "${updated_at}" ]]; then
      local then_epoch now_epoch
      then_epoch=$(date -d "${updated_at}" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      if [[ ${then_epoch} -gt 0 ]]; then
        echo $(( now_epoch - then_epoch ))
        return
      fi
    fi
  fi
  echo ""
}

# Get last meaningful log activity for a story
last_activity() {
  local key="$1"
  # Check for most recent log file for this story
  local latest=""
  for f in "${LOG_DIR}/${key}"*.log; do
    [[ -f "${f}" ]] && latest="${f}"
  done
  if [[ -n "${latest}" ]]; then
    # Get last non-empty line, trim to 55 chars
    tail -3 "${latest}" 2>/dev/null | grep -v '^$' | tail -1 | cut -c1-55
  fi
}

# Count files changed in a worktree vs main
files_changed() {
  local key="$1"
  local wt="${PROJECT_ROOT}/${key}"
  if [[ -d "${wt}" ]]; then
    git -C "${wt}" diff main --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo ""
  fi
}

# ---------------------------------------------------------------------------
# Pipeline process detection
# ---------------------------------------------------------------------------
is_pipeline_running() {
  ps aux 2>/dev/null | grep -q "[r]un-factories" && return 0
  ps aux 2>/dev/null | grep "[d]ispatcher.sh --workers" | grep -qv grep && return 0
  return 1
}

get_pipeline_info() {
  local factory_pid dispatcher_pid
  factory_pid=$(ps aux 2>/dev/null | grep "[r]un-factories" | awk '{print $2}' | head -1)
  dispatcher_pid=$(ps aux 2>/dev/null | grep "[d]ispatcher.sh --workers" | grep -v grep | awk '{print $2}' | head -1)

  local parts=()
  [[ -n "${factory_pid}" ]] && parts+=("factory PID ${factory_pid}")
  [[ -n "${dispatcher_pid}" ]] && parts+=("dispatcher PID ${dispatcher_pid}")

  if [[ ${#parts[@]} -gt 0 ]]; then
    echo "${parts[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Render the dashboard
# ---------------------------------------------------------------------------
render() {
  local now
  now=$(date '+%H:%M:%S')

  # Counts
  local n_queued n_created n_dev n_fixing n_done n_failed n_escalated
  n_queued=$(get_stories_by_status "ready-for-dev" | wc -l | tr -d ' ')
  n_created=$(get_stories_by_status "story-created" | wc -l | tr -d ' ')
  n_dev=$(get_stories_by_status "dev-complete" | wc -l | tr -d ' ')
  n_fixing=$(get_stories_by_status "review-failed" | wc -l | tr -d ' ')
  n_done=$(get_stories_by_status "done" | wc -l | tr -d ' ')
  n_failed=$(get_stories_by_status "failed" | wc -l | tr -d ' ')
  n_escalated=$(get_stories_by_status "review-escalated" | wc -l | tr -d ' ')
  n_queued=${n_queued:-0}; n_created=${n_created:-0}; n_dev=${n_dev:-0}
  n_fixing=${n_fixing:-0}; n_done=${n_done:-0}; n_failed=${n_failed:-0}; n_escalated=${n_escalated:-0}
  local n_total=$((n_queued + n_created + n_dev + n_fixing + n_done + n_failed + n_escalated))
  local n_active=$((n_created + n_dev + n_fixing))

  # Progress bar
  local bar_width=40
  local done_width=0 active_width=0 fail_width=0
  if [[ ${n_total} -gt 0 ]]; then
    done_width=$(( n_done * bar_width / n_total ))
    active_width=$(( n_active * bar_width / n_total ))
    fail_width=$(( (n_failed + n_escalated) * bar_width / n_total ))
  fi
  local remaining_width=$((bar_width - done_width - active_width - fail_width))
  [[ ${remaining_width} -lt 0 ]] && remaining_width=0

  local bar="" active_bar="" fail_bar="" empty_bar=""
  for ((i=0; i<done_width; i++)); do bar="${bar}█"; done
  for ((i=0; i<active_width; i++)); do active_bar="${active_bar}▓"; done
  for ((i=0; i<fail_width; i++)); do fail_bar="${fail_bar}█"; done
  for ((i=0; i<remaining_width; i++)); do empty_bar="${empty_bar}░"; done

  # Header
  echo -e ""
  echo -e "  ${W}BMAD Pipeline${N}  ${D}${now}${N}"

  # Pipeline process status
  if is_pipeline_running; then
    local pinfo
    pinfo=$(get_pipeline_info)
    echo -e "  ${G}●${N} Pipeline running  ${D}${pinfo}${N}"
  else
    echo -e "  ${D}○${N} Pipeline idle"
  fi

  echo -e ""
  echo -e "  ${G}${bar}${C}${active_bar}${R}${fail_bar}${D}${empty_bar}${N}  ${G}${n_done}${N}/${n_total} done  ${D}${n_queued} queued · ${n_active} active${N}"
  echo -e ""

  # Status summary line
  local summary_parts=()
  [[ ${n_queued} -gt 0 ]]    && summary_parts+=("${D}○${N}${n_queued}")
  [[ ${n_created} -gt 0 ]]   && summary_parts+=("${B}◆${N}${n_created}")
  [[ ${n_dev} -gt 0 ]]       && summary_parts+=("${C}◆${N}${n_dev}")
  [[ ${n_fixing} -gt 0 ]]    && summary_parts+=("${Y}↻${N}${n_fixing}")
  [[ ${n_done} -gt 0 ]]      && summary_parts+=("${G}✓${N}${n_done}")
  [[ ${n_failed} -gt 0 ]]    && summary_parts+=("${R}✗${N}${n_failed}")
  [[ ${n_escalated} -gt 0 ]] && summary_parts+=("${R}⚠${N}${n_escalated}")
  [[ ${#summary_parts[@]} -gt 0 ]] && echo -e "  ${summary_parts[*]}" || true
  echo -e ""

  # Factory status
  local factory_key factory_pid
  factory_key=$(get_factory_story 2>/dev/null || true)
  factory_pid=$(get_factory_pid 2>/dev/null || true)

  if [[ -n "${factory_key}" && -n "${factory_pid}" ]]; then
    local elapsed
    elapsed=$(get_phase_elapsed "${factory_key}")
    local elapsed_str=""
    [[ -n "${elapsed}" && "${elapsed}" -gt 0 ]] 2>/dev/null && elapsed_str=" $(format_elapsed ${elapsed})"
    echo -e "  $(spin) ${M}Factory${N}  creating ${W}${factory_key}${N}${D}${elapsed_str}${N}"

    # Check exhaustion wait on main worktree
    if [[ -f "${MAIN_WORKTREE}/.claude/.exhaustion-wait" ]]; then
      local einfo
      einfo=$(cat "${MAIN_WORKTREE}/.claude/.exhaustion-wait" 2>/dev/null)
      echo -e "    ${Y}⏳ Waiting for rate limit reset${N}  ${D}${einfo}${N}"
    fi
    echo ""
  fi

  # Story details
  echo -e "  ${UL}${D}Story                                 Status       Phase${N}"

  local all_stories has_active=false
  all_stories=$(get_all_stories)

  if [[ -n "${all_stories}" ]]; then
    while IFS= read -r key; do
      [[ -z "${key}" ]] && continue
      local status title icon label
      status=$(get_story_status "${key}")
      title=$(get_story_title "${key}")
      icon=$(status_icon "${status}")
      label=$(status_label "${status}")

      # Check for active worker
      local active_pid=""
      active_pid=$(get_worker_pid "${key}" 2>/dev/null || true)

      if [[ -n "${active_pid}" ]]; then
        has_active=true
        local phase_file="${PROJECT_ROOT}/${key}/.claude/.phase-state"
        local current_phase="working"
        [[ -f "${phase_file}" ]] && current_phase=$(grep '^PHASE=' "${phase_file}" 2>/dev/null | cut -d= -f2)

        local phase_disp elapsed elapsed_str nfiles nfiles_str
        phase_disp=$(phase_label "${current_phase}")
        elapsed=$(get_phase_elapsed "${key}")
        elapsed_str=""
        [[ -n "${elapsed}" ]] && [[ "${elapsed}" -gt 0 ]] 2>/dev/null && elapsed_str=" ${D}$(format_elapsed ${elapsed})${N}" || true
        nfiles=$(files_changed "${key}" 2>/dev/null || true)
        nfiles_str=""
        [[ -n "${nfiles}" ]] && nfiles_str=" ${D}(${nfiles} files)${N}"

        echo -e "  $(spin) ${W}${key}${N}  ${title}"
        echo -e "         ${phase_disp}${elapsed_str}${nfiles_str}"

        # Check exhaustion wait
        if is_exhaustion_waiting "${key}"; then
          local einfo
          einfo=$(get_exhaustion_info "${key}")
          echo -e "         ${Y}⏳ Rate limit — waiting for reset${N}  ${D}${einfo}${N}"
        fi
      else
        # Check if factory is currently creating this story
        if [[ -n "${factory_key}" && "${key}" == "${factory_key}" && -n "${factory_pid}" ]]; then
          local fe fe_str
          fe=$(get_phase_elapsed "${factory_key}")
          fe_str=""
          [[ -n "${fe}" ]] && [[ "${fe}" -gt 0 ]] 2>/dev/null && fe_str=" ${D}$(format_elapsed ${fe})${N}" || true
          echo -e "  $(spin) ${W}${key}${N}  ${title}"
          echo -e "         ${M}create-story${N} ${D}(Opus)${N}${fe_str}"
        else
          # Compact line for inactive stories
          printf "  %b  %-6s %-36s %b\n" "${icon}" "${key}" "${title}" "${label}"
        fi
      fi
    done <<< "${all_stories}"
  else
    echo -e "  ${D}No stories found. Run: python3 bmad-converter.py convert${N}"
  fi

  echo ""

  # Epic retrospective status
  retro_epics=$(epics_needing_retro 2>/dev/null || true)
  if [[ -n "${retro_epics}" ]]; then
    echo -e "  ${M}━━━ RETROSPECTIVE PENDING ━━━${N}"
    while IFS= read -r epic; do
      [[ -z "${epic}" ]] && continue
      echo -e "  ${M}↻${N}  ${epic} — all stories done, awaiting doc promotion"
    done <<< "${retro_epics}"
    echo ""
  fi

  # Check for active retro session
  retro_pid=$(ps aux 2>/dev/null | grep -E "claude.*retrospective" | grep -v grep | awk '{print $2}' | head -1 || true)
  if [[ -n "${retro_pid}" ]]; then
    echo -e "  $(spin) ${M}Retrospective running${N}  ${D}PID ${retro_pid}${N}"
    echo ""
  fi

  # Failure alerts
  if [[ ${n_failed} -gt 0 || ${n_escalated} -gt 0 ]]; then
    echo -e "  ${R}━━━ ATTENTION NEEDED ━━━${N}"
    if [[ ${n_failed} -gt 0 ]]; then
      local failed_stories
      failed_stories=$(get_stories_by_status "failed")
      while IFS= read -r key; do
        echo -e "  ${R}✗${N}  ${key} — ${LOG_DIR}/${key}*.log"
      done <<< "${failed_stories}"
    fi
    if [[ ${n_escalated} -gt 0 ]]; then
      local esc_stories
      esc_stories=$(get_stories_by_status "review-escalated")
      while IFS= read -r key; do
        echo -e "  ${Y}⚠${N}  ${key} — review escalated, needs human"
      done <<< "${esc_stories}"
    fi
    echo ""
  fi

  # Sprint complete check — keep polling if retros pending or running
  local retro_remaining retro_active
  retro_remaining=$(epics_needing_retro 2>/dev/null | wc -l | tr -d ' ')
  retro_remaining=${retro_remaining:-0}
  retro_active=""
  [[ -n "${retro_pid:-}" ]] && retro_active="yes"

  if [[ ${n_total} -gt 0 && ${n_queued} -eq 0 && ${n_created} -eq 0 && ${n_dev} -eq 0 && ${n_fixing} -eq 0 ]]; then
    if [[ "${has_active}" == "false" ]]; then
      # Still have retros to run — keep watching
      if [[ ${retro_remaining} -gt 0 || -n "${retro_active}" ]]; then
        return 0
      fi
      if [[ ${n_failed} -eq 0 && ${n_escalated} -eq 0 ]]; then
        echo -e "  ${G}━━━ Sprint complete! All retrospectives done. ━━━${N}"
      else
        echo -e "  ${Y}Sprint finished with issues.${N}"
      fi
      echo ""
      return 1  # signal to stop watching
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "once" ]]; then
  render
  exit 0
fi

if [[ "${MODE}" == "tail" ]]; then
  render || true
  echo -e "  ${D}─── tailing latest log ───${N}"
  echo ""
  latest=$(ls -t "${LOG_DIR}"/*.log 2>/dev/null | head -1)
  if [[ -n "${latest}" ]]; then
    tail -f "${latest}"
  else
    echo "No logs yet."
  fi
  exit 0
fi

# Watch mode
trap 'echo -e "\n  ${D}Monitor stopped.${N}"; exit 0' INT

while true; do
  clear
  if ! render; then
    break
  fi
  echo -e "  ${D}Refreshing every ${POLL}s · Ctrl+C to stop${N}"
  sleep "${POLL}"
done
