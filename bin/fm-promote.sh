#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the project's delivery mode).
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
KIND=$(grep '^kind=' "$META" | cut -d= -f2)
case "$KIND" in
  scout|spec|plan) ;;
  *) echo "error: task $ID is not a promotable task (kind=$KIND, expected scout, spec, or plan)" >&2; exit 1 ;;
esac

if [ "$KIND" = spec ] || [ "$KIND" = plan ]; then
  REPORT="$FM_HOME/data/$ID/report.md"
  [ -f "$REPORT" ] || { echo "error: task $ID has no report at $REPORT; the spec/plan must complete and produce a report before promotion" >&2; exit 1; }
fi

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"

if [ "$KIND" = spec ] || [ "$KIND" = plan ]; then
  echo "spec/plan report: $REPORT"
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: load .agents/skills/spec-scaffold/SKILL.md and follow its commit-forward convention; read the spec/plan at $REPORT; review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; commit the spec content into the right doc per docs/specs/README.md; resolve or explicitly re-open every [NEEDS CLARIFICATION] marker; include Spec: <path> in --intent (no-mistakes) or commit message (local-only); implement; report done>'"
else
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
fi
