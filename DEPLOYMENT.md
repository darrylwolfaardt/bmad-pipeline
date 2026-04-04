# BMAD Factory Pipeline - Deployment Guide

## Prerequisites

- Claude Code CLI - installed and authenticated
- Git 2.20+ - worktree support
- Python 3.6+ with PyYAML (pip install pyyaml)
- Bash 4+

## Scenario A: New Greenfield Project

1. Create project and bootstrap:
   mkdir my-project && cd my-project && git init
   git clone https://github.com/darrylwolfaardt/bmad-pipeline.git /tmp/bmad-pipeline
   /tmp/bmad-pipeline/setup/bootstrap.sh --here --bare

2. Add BMAD methodology into main/:
   cd main
   # copy or submodule your _bmad/ directory

3. Run interactive BMAD planning:
   claude
   # create product brief, PRD, architecture, epics, sprint planning

4. Run autonomous pipeline:
   cd ..
   ./run-factories.sh

5. Monitor: ./monitor.sh

## Scenario B: Existing Brownfield Project

1. Clone pipeline and bootstrap (non-destructive):
   cd ~/projects/existing-app
   git clone https://github.com/darrylwolfaardt/bmad-pipeline.git /tmp/bmad-pipeline
   /tmp/bmad-pipeline/setup/bootstrap.sh --here --bare

2. Add BMAD methodology, then plan and run as above.

## Scenario C: Brownfield with Linear Tickets

Ticket-per-requirement workflow with isolated planning per Linear ticket.

For each new requirement:

1. Create ticket worktree:
   cd ~/projects/my-app
   git worktree add RZP-1029 main

2. BMAD planning in ticket worktree:
   cd RZP-1029
   claude
   # Product brief, sub-PRD, architecture, epics, sprint planning
   # Artifacts land in _bmad-output/RZP-1029/

3. Run pipeline with ticket isolation:
   cd ..
   ./run-factories.sh --ticket RZP-1029

4. Monitor: ./monitor.sh

5. On completion, retrospective automatically:
   - Reads ticket sub-PRD + story artifacts
   - Reconciles against baseline prd.md
   - Promotes proven patterns to baseline docs
   - Archives the sub-PRD
   - Commits: retro(epic-N): promote patterns to baseline

6. Next ticket starts against updated baseline:
   git worktree add RZP-1030 main
   cd RZP-1030
   claude  # baseline docs now reflect RZP-1029

## Directory Layout

my-project/
  .bare/                              git object database
  main/                               main branch worktree
    .claude/hooks/                    pipeline hook scripts
    _bmad/                            BMAD methodology (you provide)
    _bmad-output/
      planning-artifacts/             BASELINE (canonical prd.md, architecture.md)
      implementation-artifacts/       default artifacts (no ticket)
      RZP-1029/                       ticket-namespaced (when using --ticket)
        planning-artifacts/           sub-PRD for this requirement
        implementation-artifacts/     sprint-status, story artifacts, logs
    CLAUDE.md                         system context
  run-factories.sh                    pipeline entry point
  dispatcher.sh                       build worker manager
  monitor.sh                          live dashboard
  bmad-converter.py                   format converter

## Commands

./run-factories.sh                     Full pipeline
./run-factories.sh --ticket RZP-1029   Ticket-isolated pipeline
./run-factories.sh --factory-only      Story factory only
./run-factories.sh --dispatch-only     Build workers only
./run-factories.sh --story 1-1         Single story
./run-factories.sh --status            Sprint status
./run-factories.sh --cleanup           Remove completed worktrees
./monitor.sh                           Live dashboard
./monitor.sh --once                    Print once
./monitor.sh --tail                    Status + tail active log

## Configuration (Environment Variables)

BMAD_TICKET          (none)           Linear ticket ID for namespacing
BMAD_MODEL_CREATE    claude-opus-4-6  Model for story creation
BMAD_MODEL_DEV       claude-sonnet-4-6 Model for implementation
BMAD_MODEL_REVIEW    claude-opus-4-6  Model for code review
BMAD_BASE_BRANCH     main             Base branch for worktrees
BMAD_AUTO_PUSH       false            Auto-push completed branches
BMAD_MAX_REVIEW_ITERATIONS 3          Review/fix cycles before escalation
BMAD_EXHAUSTION_POLL_INTERVAL 300     Seconds between rate limit polls

## Updating

git -C /tmp/bmad-pipeline pull
/tmp/bmad-pipeline/setup/bootstrap.sh --target ~/projects/my-app --force

## Troubleshooting

cat main/.claude/.phase-state                                     Phase state
tail -50 main/_bmad-output/implementation-artifacts/progress.log  Progress log
ls main/_bmad-output/implementation-artifacts/logs/               Story logs
python3 bmad-converter.py status                                  Pipeline status
