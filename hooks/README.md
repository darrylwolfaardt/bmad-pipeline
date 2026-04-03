# BMAD Factory Pipeline — Bare Repo Layout

Autonomous development pipeline using Claude Code hooks, git worktrees, and a bare repo structure. Each story gets a fresh session with clean context. The story factory, build workers, and code review all run as isolated sessions with dependency-aware scheduling.

## Layout

```
ProjectAlpha/                           ← bare repo root
  .bare/                                ← git object database
  .git                                  ← gitdir pointer to .bare/
  main/                                 ← worktree: main branch
    _bmad/                              ← BMAD methodology (symlinked to worktrees)
    _bmad-output/
      implementation-artifacts/
        sprint-status.yaml              ← source of truth
        REMS-101/                       ← story artifacts from factory
        REMS-102/
        logs/
    .claude/
      hooks/                            ← all hook scripts (copied to worktrees)
      settings.local.json               ← hook config
    app/                                ← your application code
    ...
  REMS-101/                             ← worktree: feature/REMS-101 (build worker)
  REMS-103/                             ← worktree: feature/REMS-103 (build worker)
  run-factories.sh                      ← pipeline entry point (outside git)
  dispatcher.sh                         ← build worker launcher (outside git)
  setup-bare-repo.sh                    ← one-time setup
```

Everything under `main/` is tracked by git. The orchestration scripts (`run-factories.sh`, `dispatcher.sh`) live at the project root, outside any worktree. Feature worktrees appear as siblings of `main/` — clean, flat, and easy to navigate.

## Setup

```bash
# From a remote
./setup-bare-repo.sh git@github.com:yourorg/project.git ProjectAlpha

# From a local repo
./setup-bare-repo.sh /path/to/existing-repo ProjectAlpha

# Then copy the pipeline scripts to the project root
cp run-factories.sh dispatcher.sh setup-bare-repo.sh ProjectAlpha/

# Ensure hooks are in main/
ls ProjectAlpha/main/.claude/hooks/

# Make executable
chmod +x ProjectAlpha/run-factories.sh ProjectAlpha/dispatcher.sh
chmod +x ProjectAlpha/main/.claude/hooks/*.sh
```

After setup, verify:

```bash
cd ProjectAlpha
git worktree list
# .bare    (bare)
# main     abc1234 [main]
```

## Pipeline

```
┌─────────────────────────────────────────────────────────────────────────┐
│  STAGE 1: Story Factory                                                 │
│  Runs in: main/ worktree                                                │
│  One fresh Claude Code session per story                                │
│                                                                         │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐                  │
│  │ REMS-101│→ │ REMS-102│→ │ REMS-103│→ │ REMS-104│  (sequential)    │
│  │ create  │  │ create  │  │ create  │  │ create  │                  │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘                  │
│       └── artifacts written to main/_bmad-output/implementation-artifacts/ │
│                                                                         │
│  With --factory-parallel 2:                                             │
│  ┌─────────┐  ┌─────────┐                                             │
│  │ REMS-101│  │ REMS-103│  (concurrent — no cross-deps)               │
│  └─────────┘  └─────────┘                                             │
│  ┌─────────┐  ┌─────────┐                                             │
│  │ REMS-102│  │ REMS-104│  (next batch)                               │
│  └─────────┘  └─────────┘                                             │
├─────────────────────────────────────────────────────────────────────────┤
│  STAGE 2: Dispatcher                                                    │
│  Watches sprint-status.yaml for stories where:                          │
│    status == story-created AND all depends_on == done                   │
│  Creates worktrees at ProjectAlpha/{story-key}/                         │
│  Launches build workers up to --workers N                               │
├─────────────────────────────────────────────────────────────────────────┤
│  STAGE 3: Build Workers (parallel, in worktrees)                        │
│  Each in: ProjectAlpha/{story-key}/                                     │
│  Fresh context per story                                                │
│                                                                         │
│  dev-story ──→ code-review ──┐                                         │
│      ▲              │         │                                         │
│      └── fix ◄─── fail      pass ──→ done                              │
│           (max 3)            │                                          │
│                    dispatcher sees done → releases dependents            │
└─────────────────────────────────────────────────────────────────────────┘
```

## Usage

```bash
cd ProjectAlpha

# Full pipeline: sequential story factory → 2 parallel build workers
./run-factories.sh

# Parallel story creation + 3 build workers
./run-factories.sh --factory-parallel 2 --workers 3

# Step by step
./run-factories.sh --factory-only
./run-factories.sh --status
./run-factories.sh --dispatch-only --workers 3

# Single story (legacy — full pipeline in one session + worktree)
./run-factories.sh --story REMS-101

# Monitor
./run-factories.sh --status

# Clean up completed worktrees
./run-factories.sh --cleanup

# List all worktrees
git worktree list
```

## How Git Worktrees Work Here

The bare repo (`.bare/`) holds all git objects. The `.git` file at the project root points to `.bare/`, so git commands work from `ProjectAlpha/`. Each worktree is a separate checkout of a branch:

```bash
# What setup creates
git clone --bare <url> .bare
echo "gitdir: .bare" > .git
git worktree add main main

# What the dispatcher creates (one per story)
git worktree add REMS-101 -b feature/REMS-101 main
git worktree add REMS-103 -b feature/REMS-103 main

# What cleanup removes
git worktree remove REMS-101
git worktree prune
```

Each worktree is a full working directory on its own branch. Build workers can't interfere with each other because they're on different branches in different directories. The bash-guard hook prevents `git checkout` and `git worktree` commands inside sessions.

## Session Isolation

| Factory | Runs in | Context | Worktree? |
|---------|---------|---------|-----------|
| Story factory | `main/` | One story + deps from disk | No (writes artifacts to main) |
| Build worker | `{story-key}/` | One story + artifacts | Yes (sibling of main) |
| Legacy | `{story-key}/` | Full pipeline | Yes |

Every session starts with a clean context window. Cross-story information flows through **files on disk**, not accumulated context. The session-init hook injects only what's needed: the current story's brief, its dependency contracts, and the BMAD workflow template.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BMAD_FACTORY_MODE` | `legacy` | Set by scripts: story-factory / build-worker / legacy |
| `BMAD_STORY_KEY` | (auto) | Current story |
| `BMAD_BASE_BRANCH` | `main` | Worktree base |
| `BMAD_AUTO_PUSH` | `false` | Push feature branches |
| `BMAD_MAX_REVIEW_ITERATIONS` | `3` | Max review loops |
| `BMAD_CLAUDE_FLAGS` | (empty) | Extra `claude` CLI flags |

## Files Changed (This Revision)

| File | Change |
|------|--------|
| `setup-bare-repo.sh` | **New** — initialises bare repo + main worktree |
| `.claude/hooks/lib/common.sh` | Path model: `PROJECT_ROOT` = bare root, `MAIN_WORKTREE` = main/, worktrees at `PROJECT_ROOT/{key}/` |
| `run-factories.sh` | Sources from `main/.claude/hooks/`, launches factory in `main/`, dispatches from root |
| `dispatcher.sh` | Creates worktrees at `PROJECT_ROOT/{key}/`, copies hooks from `main/` |
| `.claude/hooks/session-init.sh` | Unchanged (derives paths from CLAUDE_PROJECT_DIR) |
| `.claude/hooks/stop-evaluator.sh` | Unchanged |
| All other hooks | Unchanged (they use common.sh path resolution) |
