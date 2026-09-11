---
name: progress-ledger
description: >-
  Agent-only procedure for durable progress tracking that survives context compaction and proactive relaunches.
  Load on every usage-metered crewmate ship or scout brief, every multi-task ship brief, at secondmate idle checkpoints, and when stuck-crewmate-recovery reconciles work after a dead-endpoint or stale-crewmate event.
  Prevents catastrophic re-execution of completed tasks after context loss.
user-invocable: false
metadata:
  internal: true
---

# progress-ledger

Use this procedure on every multi-task ship brief, every ship or scout brief dispatched on a usage-metered model, at a usage-metered secondmate's natural idle checkpoint, and when reconciling work after a crewmate endpoint dies or goes stale.
This skill is the single owner of the durable progress-ledger pattern.
`bin/fm-classify-lib.sh` owns the keyed-status lifecycle; this skill owns the scratch ledger that preserves forward progress across compactions and crewmate restarts.

## Proactive checkpoint and relaunch policy

Apply this policy only when the worker's pinned model or harness is usage-metered.
No harness currently exposes a reliable context-percentage signal, so use continued-work rounds as the proxy.

### Crewmates

For a ship or scout task, checkpoint at the existing natural boundary whenever possible, and after roughly 15-20 rounds of continued work without a clean stopping point.
At the checkpoint, commit applicable work, append one substantive status line, and record the checkpoint in `.fm-progress.md`.
Then request a relaunch with a continuation note via `bin/fm-control.sh <id> relaunch --note '<checkpoint and next unfinished work>'`, rather than continuing indefinitely in one session.
The continuation note must identify the durable checkpoint and the next unfinished work.

### Persistent secondmates

Checkpoint only at a natural idle boundary already present in the secondmate workflow, such as immediately after tearing down a finished child task or immediately before dispatching the next one.
Never relaunch mid-reasoning or while directly interacting with the captain.
Skip this policy entirely when the pinned secondmate seat is flat-rate rather than usage-metered.
At the boundary, record the durable state before requesting any relaunch, including a continuation note if relaunch is selected.

### Primary firstmate

Do not apply automatic or periodic relaunch to the primary firstmate session.
The primary is in a live captain conversation on the captain's own seat and is already restart-safe through the session-start digest.
Leave clearing or session reset to the captain's own timing.

### Load-bearing caveat

This optimization is safe only when the durable-state habit holds.
If a worker stops writing substantive status or ledger state before checkpointing, an early relaunch loses context as well as tokens.

## Ledger file convention

The ledger lives at `<worktree>/.fm-progress.md`.
It is local scratch — never commit it, never read it outside this procedure, and never let it influence git operations.
The repo's `.gitignore` covers this path only in the firstmate repo itself, so exclude it in the target worktree before creating it:

```sh
printf '.fm-progress.md\n' >> "$(git rev-parse --git-path info/exclude)"
```

The format is a Markdown file with one task header per multi-task item and a dated completion line beneath it.

Template:

```markdown
# Progress ledger — <brief-id>

## Task 1: <description>
- [x] 2025-07-17 14:30 UTC — commit `abc1234`

## Task 2: <description>
- [ ] not started
```

At a proactive checkpoint, replace the task's pending line with a checkpoint line and leave it unfinished until the task is complete:

```markdown
- [~] 2025-07-17 14:30 UTC — checkpoint commit `abc1234`; next: <unfinished work>
```

## On task start

1. If this is not a multi-task brief and the worker is not a usage-metered crewmate task at a proactive checkpoint, stop - the ledger is not needed.
2. If `<worktree>/.fm-progress.md` exists, read it and note every task marked `[x]` as already completed.
   Skip those tasks entirely — do not re-execute, re-inspect, or re-verify them.
3. If the ledger does not exist, first exclude it from git in this worktree
   (see Ledger file convention), then create it from the task list in the brief.
   Mark every task `[ ] not started`.
4. Proceed with the first incomplete task, or with the next unfinished checkpoint named in the continuation note.

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
   Every task marked `[ ] not started`, `[~] checkpoint`, or with no completion line is pending.
4. The ledger plus the brief's task list is the authoritative record of what remains.
   Do not re-discover task completion from git log or file inspection unless the ledger is absent or corrupt.
5. If the ledger is internally inconsistent, treat only an `[x]` entry with a commit hash as complete and repair the ledger; a `[~]` checkpoint remains pending even when it includes a commit hash.
