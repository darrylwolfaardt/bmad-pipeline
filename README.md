# BMAD Factory Pipeline

Autonomous development pipeline built on Claude Code hooks and git worktrees. Reads a BMAD sprint backlog, creates story specifications, implements code, runs code reviews, and promotes learnings — all orchestrated by bash scripts launching Claude Code sessions.

## What It Does

```
Sprint Backlog → Story Factory (Opus) → Dev Workers (Sonnet) → Code Review (Opus) → Retrospective (Opus)
                     ↑                        ↑                       ↑                      ↑
              creates specs            implements code          reviews & fixes       promotes to baseline
```

- **Story Factory**: Creates implementation artifacts (component specs, interface contracts, test stubs) for each story
- **Dispatcher**: Launches parallel build workers as stories become eligible, respecting dependencies
- **Build Workers**: Implement code (Sonnet) then review (Opus) in isolated git worktrees
- **Retrospective**: After each epic completes, reconciles what was built against specs and updates baseline docs
- **Exhaustion Handling**: Detects rate limits, waits for reset, retries automatically
- **Live Monitor**: Real-time dashboard with progress bars, spinners, and status tracking

## Quick Start

```bash
# Install into an existing git project
./setup/bootstrap.sh --target ~/projects/my-app

# Or with bare repo layout (enables parallel worktree builds)
./setup/bootstrap.sh --target ~/projects/my-app --bare

# Then add your BMAD methodology and sprint backlog, and run:
cd ~/projects/my-app
./run-factories.sh
./monitor.sh  # in another terminal
```

## Requirements

- Claude Code CLI (`claude`) installed and authenticated
- Git 2.20+ (worktree support)
- Python 3.6+ (YAML parsing, format conversion)
- Bash 4+ (associative arrays)
- PyYAML (`pip install pyyaml`)

## Project Structure

```
bmad-pipeline/
  hooks/                     # Claude Code hook scripts
    bash-guard.sh            # Blocks destructive commands
    file-scope-guard.sh      # Enforces worktree boundaries
    phase-router.sh          # Injects phase-specific context
    post-edit.sh             # Auto-formats and stages files
    session-init.sh          # Sets up session context
    stop-evaluator.sh        # Handles phase transitions
    lib/common.sh            # Shared functions and helpers
  orchestration/             # Pipeline scripts
    run-factories.sh         # Main entry point
    dispatcher.sh            # Parallel build worker manager
    monitor.sh               # Live dashboard
    bmad-converter.py        # BMAD ↔ pipeline format sync
  setup/                     # Installation
    bootstrap.sh             # One-command installer
    setup-bare-repo.sh       # Bare repo initializer
    settings.local.json.template
    CLAUDE.md.template
```

## Pipeline Lifecycle

```
ready-for-dev → story-created → dev-complete → done
                                     ↓
                                review-failed → (retry, max 3)
                                     ↓
                                review-escalated (human needed)

Epic complete → retrospective → baseline docs updated → next epic
```

## Configuration

Environment variables:
- `BMAD_MODEL_CREATE` — Model for story creation (default: `claude-opus-4-6`)
- `BMAD_MODEL_DEV` — Model for implementation (default: `claude-sonnet-4-6`)
- `BMAD_MODEL_REVIEW` — Model for code review (default: `claude-opus-4-6`)
- `BMAD_EXHAUSTION_POLL_INTERVAL` — Seconds between rate limit polls (default: 300)
- `BMAD_MAX_REVIEW_ITERATIONS` — Max review/fix cycles before escalation (default: 3)

## Commands

```bash
./run-factories.sh                 # Full pipeline
./run-factories.sh --factory-only  # Create stories only
./run-factories.sh --dispatch-only # Build workers only
./run-factories.sh --story 1-1     # Single story, full pipeline
./run-factories.sh --status        # Show sprint status
./run-factories.sh --cleanup       # Remove completed worktrees
./monitor.sh                       # Live dashboard
./monitor.sh --once                # Print status once
./monitor.sh --tail                # Status + tail active log
```
