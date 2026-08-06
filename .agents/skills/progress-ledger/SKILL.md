---
name: progress-ledger
description: >-
  Agent-only procedure for durable multi-task progress tracking that survives context compaction.
  Load on every multi-task ship brief (the brief instructs it) and when stuck-crewmate-recovery reconciles work after a dead-endpoint or stale-crewmate event.
  Prevents catastrophic re-execution of completed tasks after context loss.
user-invocable: false
metadata:
  internal: true
---

# progress-ledger

Use this procedure on every multi-task ship brief and when reconciling work after a crewmate endpoint dies or goes stale.
This skill is the single owner of the durable progress-ledger pattern.
`bin/fm-classify-lib.sh` owns the keyed-status lifecycle; this skill owns the scratch ledger that preserves forward progress across compactions and crewmate restarts.

## Ledger file convention

The ledger lives at `<worktree>/.fm-progress.md`.
It is gitignored scratch — never commit it, never read it outside this procedure, and never let it influence git operations.
The format is a Markdown file with one task header per multi-task item and a dated completion line beneath it.

Template:

```markdown
# Progress ledger — <brief-id>

## Task 1: <description>
- [x] 2025-07-17 14:30 UTC — commit `abc1234`

## Task 2: <description>
- [ ] not started
```

## On task start

1. If this brief does not contain multiple independent tasks, stop — the ledger is not needed.
2. If `<worktree>/.fm-progress.md` exists, read it and note every task marked `[x]` as already completed.
   Skip those tasks entirely — do not re-execute, re-inspect, or re-verify them.
3. If the ledger does not exist, create it from the task list in the brief.
   Mark every task `[ ] not started`.
4. Proceed with the first incomplete task.

## After each task completion

Append one dated line immediately after committing:

```markdown
- [x] <YYYY-MM-DD HH:MM UTC> — commit `<hash>`
```

Replace the previous `[ ] not started` line for that task.
Do not batch multiple task completions into one line.

## On recovery (load from stuck-crewmate-recovery)

When reconciling work after a dead endpoint or stale crewmate:

1. Check whether `<worktree>/.fm-progress.md` exists.
2. If it does not exist, this brief either had no multi-task structure or the ledger was never created.
   Proceed with normal recovery — inspect `git log` and file state to determine completed work.
3. If it exists, read it.
   Every task marked `[x]` with a commit hash is complete — skip it.
   Every task marked `[ ] not started` or with no completion line is pending.
4. The ledger plus the brief's task list is the authoritative record of what remains.
   Do not re-discover task completion from git log or file inspection unless the ledger is absent or corrupt.
5. If the ledger is internally inconsistent (e.g., a task has a commit hash but no `[x]`), trust the commit hash as completed and repair the ledger.
