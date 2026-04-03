#!/usr/bin/env python3
"""
bmad-converter.py — Bidirectional sync between BMAD and pipeline sprint formats.

BMAD format (source of truth):
    development_status:
      epic-1: backlog
      1-1-project-scaffolding: backlog
      1-2-add-new-todo-items: backlog

Pipeline format (internal, used by hooks):
    stories:
      - key: "1-1"
        slug: "1-1-project-scaffolding"
        title: "Project Scaffolding"
        epic: "epic-1"
        status: ready-for-dev
        priority: 1
        depends_on: []

Commands:
    python3 bmad-converter.py convert   — BMAD → pipeline format
    python3 bmad-converter.py sync-back — pipeline status → BMAD format
    python3 bmad-converter.py status    — show current state of both files

Status mapping:
    BMAD             Pipeline
    ─────────────    ──────────────
    backlog       →  ready-for-dev
    ready-for-dev →  story-created
    in-progress   →  dev-complete (or in-progress)
    review        →  dev-complete
    done          →  done
"""

import sys
import re
import yaml
from pathlib import Path

# ---------------------------------------------------------------------------
# Status mapping
# ---------------------------------------------------------------------------
BMAD_TO_PIPELINE = {
    "backlog": "ready-for-dev",
    "ready-for-dev": "story-created",
    "in-progress": "dev-complete",
    "review": "dev-complete",
    "done": "done",
    "optional": None,  # skip retrospectives
}

PIPELINE_TO_BMAD = {
    "ready-for-dev": "backlog",
    "story-created": "ready-for-dev",
    "dev-complete": "in-progress",
    "review-failed": "in-progress",
    "review-escalated": "review",
    "done": "done",
    "failed": "backlog",
}


def find_paths(project_root: Path):
    """Locate BMAD and pipeline sprint files."""
    main_wt = project_root / "main"
    bmad_file = main_wt / "_bmad-output" / "implementation-artifacts" / "sprint-status.yaml"
    pipeline_file = main_wt / "_bmad-output" / "implementation-artifacts" / "pipeline-status.yaml"
    return bmad_file, pipeline_file


def parse_bmad(bmad_file: Path) -> dict:
    """Parse BMAD sprint-status.yaml."""
    with open(bmad_file) as f:
        data = yaml.safe_load(f)
    return data or {}


def extract_stories(bmad_data: dict) -> list:
    """
    Extract stories from BMAD development_status.
    
    Stories have keys like '1-1-project-scaffolding-and-todo-list-display'.
    Epics have keys like 'epic-1'.
    Retrospectives have keys like 'epic-1-retrospective'.
    
    Returns list of story dicts in pipeline format.
    """
    dev_status = bmad_data.get("development_status", {})
    if not dev_status:
        return []

    stories = []
    epics = {}
    priority = 0

    # First pass: identify epics
    for key, status in dev_status.items():
        if key.startswith("epic-") and not key.endswith("-retrospective"):
            # Extract epic number
            epic_match = re.match(r"epic-(\d+)", key)
            if epic_match:
                epics[epic_match.group(1)] = {
                    "key": key,
                    "status": status,
                }

    # Second pass: extract stories, grouped by epic
    current_epic = None
    prev_story_in_epic = None  # for inferring intra-epic sequence

    for key, status in dev_status.items():
        # Skip epics and retrospectives
        if key.startswith("epic-") or key.endswith("-retrospective"):
            if key.startswith("epic-") and not key.endswith("-retrospective"):
                epic_match = re.match(r"epic-(\d+)", key)
                if epic_match:
                    current_epic = key
                    prev_story_in_epic = None
            continue

        # Skip optional/null statuses
        pipeline_status = BMAD_TO_PIPELINE.get(status)
        if pipeline_status is None:
            continue

        # Parse story key: "1-1-project-scaffolding-and-todo-list-display"
        story_match = re.match(r"(\d+)-(\d+)-(.+)", key)
        if not story_match:
            continue

        epic_num = story_match.group(1)
        story_num = story_match.group(2)
        slug = story_match.group(3)

        # Build readable title from slug
        title = slug.replace("-", " ").title()

        # Short key for branch names etc.
        short_key = f"{epic_num}-{story_num}"

        priority += 1

        story = {
            "key": short_key,
            "slug": key,
            "title": title,
            "epic": f"epic-{epic_num}",
            "status": pipeline_status,
            "priority": priority,
            "depends_on": [],  # populated later by create-story phase
        }

        stories.append(story)
        prev_story_in_epic = short_key

    return stories


def generate_pipeline_file(bmad_data: dict, stories: list, output_path: Path):
    """Write pipeline-status.yaml."""
    pipeline_data = {
        "sprint": bmad_data.get("project", "unknown"),
        "base_branch": "main",
        "generated_from": "bmad-converter.py",
        "bmad_project": bmad_data.get("project", ""),
        "bmad_project_key": bmad_data.get("project_key", ""),
        "stories": stories,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        yaml.dump(pipeline_data, f, default_flow_style=False, sort_keys=False)

    return pipeline_data


def sync_back(bmad_file: Path, pipeline_file: Path):
    """
    Write pipeline statuses back to BMAD format.
    Reads pipeline-status.yaml, maps statuses, updates BMAD sprint-status.yaml.
    """
    if not pipeline_file.exists():
        print(f"Pipeline file not found: {pipeline_file}")
        return False

    with open(pipeline_file) as f:
        pipeline_data = yaml.safe_load(f)

    bmad_data = parse_bmad(bmad_file)
    dev_status = bmad_data.get("development_status", {})

    updated = 0
    for story in pipeline_data.get("stories", []):
        slug = story.get("slug", "")
        pipeline_status = story.get("status", "")
        bmad_status = PIPELINE_TO_BMAD.get(pipeline_status)

        if bmad_status and slug in dev_status:
            if dev_status[slug] != bmad_status:
                dev_status[slug] = bmad_status
                updated += 1

        # Also update epic status if all stories in epic are done
        epic = story.get("epic", "")
        if epic and pipeline_status == "done":
            # Check if all stories in this epic are done
            all_done = all(
                s.get("status") == "done"
                for s in pipeline_data.get("stories", [])
                if s.get("epic") == epic
            )
            if all_done and epic in dev_status:
                dev_status[epic] = "done"
                updated += 1

    if updated > 0:
        # Write back — preserve comments by doing line-level replacement
        with open(bmad_file) as f:
            lines = f.readlines()

        with open(bmad_file, "w") as f:
            for line in lines:
                # Match lines like "  1-1-slug: status"
                m = re.match(r"(\s+)([\w-]+):\s*(\w[\w-]*)\s*$", line)
                if m:
                    indent, key, old_status = m.group(1), m.group(2), m.group(3)
                    if key in dev_status and dev_status[key] != old_status:
                        f.write(f"{indent}{key}: {dev_status[key]}\n")
                        continue
                f.write(line)

        print(f"Synced {updated} status changes back to BMAD format.")
    else:
        print("No status changes to sync.")

    return True


def update_story_deps(pipeline_file: Path, story_key: str, depends_on: list):
    """Update depends_on for a specific story in pipeline-status.yaml."""
    if not pipeline_file.exists():
        return False

    with open(pipeline_file) as f:
        data = yaml.safe_load(f)

    for story in data.get("stories", []):
        if story.get("key") == story_key:
            story["depends_on"] = depends_on
            break

    with open(pipeline_file, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)

    return True


def update_story_status_pipeline(pipeline_file: Path, story_key: str, new_status: str):
    """Update status for a specific story in pipeline-status.yaml."""
    if not pipeline_file.exists():
        return False

    with open(pipeline_file) as f:
        data = yaml.safe_load(f)

    for story in data.get("stories", []):
        if story.get("key") == story_key:
            story["status"] = new_status
            break

    with open(pipeline_file, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)

    return True


def show_status(bmad_file: Path, pipeline_file: Path):
    """Display current state of both files."""
    print("\n  BMAD Sprint Status")
    print("  ══════════════════\n")

    if bmad_file.exists():
        bmad_data = parse_bmad(bmad_file)
        dev_status = bmad_data.get("development_status", {})
        print(f"  Project: {bmad_data.get('project', '?')}")
        print(f"  BMAD file: {bmad_file}\n")
        for key, status in dev_status.items():
            marker = "✓" if status == "done" else "○" if status != "backlog" else "·"
            print(f"    {marker} {key}: {status}")
    else:
        print(f"  BMAD file not found: {bmad_file}")

    print(f"\n  Pipeline Status")
    print("  ══════════════════\n")

    if pipeline_file.exists():
        with open(pipeline_file) as f:
            data = yaml.safe_load(f)
        print(f"  Pipeline file: {pipeline_file}\n")
        for story in data.get("stories", []):
            key = story.get("key", "?")
            title = story.get("title", "?")
            status = story.get("status", "?")
            deps = story.get("depends_on", [])
            dep_str = ", ".join(deps) if deps else "(none)"
            marker = "✓" if status == "done" else "○" if status != "ready-for-dev" else "·"
            print(f"    {marker} {key}: {title} [{status}] deps: {dep_str}")
    else:
        print(f"  Pipeline file not found: {pipeline_file}")
        print("  Run: python3 bmad-converter.py convert")

    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    if len(sys.argv) < 2:
        print("Usage: python3 bmad-converter.py <convert|sync-back|status|update-deps|update-status>")
        print("       python3 bmad-converter.py convert [project-root]")
        print("       python3 bmad-converter.py sync-back [project-root]")
        print("       python3 bmad-converter.py status [project-root]")
        print("       python3 bmad-converter.py update-deps <story-key> <dep1,dep2,...> [project-root]")
        print("       python3 bmad-converter.py update-status <story-key> <new-status> [project-root]")
        sys.exit(1)

    command = sys.argv[1]

    # Determine project root
    if command in ("update-deps", "update-status"):
        project_root = Path(sys.argv[4]) if len(sys.argv) > 4 else Path.cwd()
    else:
        project_root = Path(sys.argv[2]) if len(sys.argv) > 2 else Path.cwd()

    bmad_file, pipeline_file = find_paths(project_root)

    if command == "convert":
        if not bmad_file.exists():
            print(f"ERROR: BMAD file not found: {bmad_file}")
            sys.exit(1)
        bmad_data = parse_bmad(bmad_file)
        stories = extract_stories(bmad_data)
        if not stories:
            print("No stories found in BMAD file.")
            sys.exit(1)
        generate_pipeline_file(bmad_data, stories, pipeline_file)
        print(f"Converted {len(stories)} stories → {pipeline_file}")
        for s in stories:
            print(f"  {s['key']}: {s['title']} [{s['status']}] (epic: {s['epic']})")

    elif command == "sync-back":
        sync_back(bmad_file, pipeline_file)

    elif command == "status":
        show_status(bmad_file, pipeline_file)

    elif command == "update-deps":
        if len(sys.argv) < 4:
            print("Usage: python3 bmad-converter.py update-deps <story-key> <dep1,dep2,...>")
            sys.exit(1)
        story_key = sys.argv[2]
        deps = [d.strip() for d in sys.argv[3].split(",") if d.strip()]
        if deps == ["none"] or deps == [""]:
            deps = []
        if update_story_deps(pipeline_file, story_key, deps):
            print(f"Updated deps for {story_key}: {deps}")
        else:
            print(f"Failed to update deps for {story_key}")

    elif command == "update-status":
        if len(sys.argv) < 4:
            print("Usage: python3 bmad-converter.py update-status <story-key> <new-status>")
            sys.exit(1)
        story_key = sys.argv[2]
        new_status = sys.argv[3]
        if update_story_status_pipeline(pipeline_file, story_key, new_status):
            print(f"Updated {story_key} → {new_status}")
            # Also sync back to BMAD
            sync_back(bmad_file, pipeline_file)
        else:
            print(f"Failed to update {story_key}")

    else:
        print(f"Unknown command: {command}")
        sys.exit(1)


if __name__ == "__main__":
    main()
