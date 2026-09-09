#!/usr/bin/env bash
# Behavior tests for the bounded local-Qwen one-shot scout runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-pi-qwen-alienware.py"
if [ "$(uname -s)" != "Darwin" ]; then
  pass "Darwin-only test: bounded scout requires macOS sandbox-exec; skipping on Linux"
  exit 0
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-qwen-alienware.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

make_world() {
  local name=$1 root
  root="$TMP_ROOT/$name"
  mkdir -p "$root/worktree" "$root/data/task" "$root/state" "$root/tasktmp"
  git -C "$root/worktree" init -q
  git -C "$root/worktree" config user.name Test
  git -C "$root/worktree" config user.email test@example.com
  printf 'fixture evidence\n' > "$root/worktree/evidence.txt"
  git -C "$root/worktree" add evidence.txt
  git -C "$root/worktree" commit -qm baseline
  printf '# Task\nInspect evidence.txt and report the exact text.\n\n# Setup\nIgnored inherited setup.\n' > "$root/data/task/brief.md"
  printf '%s\n' "$root"
}

test_success_writes_only_report_and_record() {
  local root fake out status
  root=$(make_world success)
  fake="$root/tasktmp/fake-pi"
  cat > "$fake" <<EOF
#!/bin/sh
printf 'fixture evidence\\n' > '$root/data/task/report.md'
printf '{"type":"agent_end"}\\n'
EOF
  chmod +x "$fake"

  out=$("$RUNNER" --id task --worktree "$root/worktree" \
    --brief "$root/data/task/brief.md" --report "$root/data/task/report.md" \
    --status "$root/state/task.status" --run-record "$root/data/task/run-record.json" \
    --task-tmp "$root/tasktmp" --timeout 5 --pi "$fake" 2>&1)
  status=$?
  expect_code 0 "$status" "bounded scout runner should pass a clean report-only run"
  assert_grep '"result": "pass"' "$root/data/task/run-record.json" "run record did not pass"
  assert_grep '"permitted_commands": []' "$root/data/task/run-record.json" "run record permits commands"
  assert_grep '"network": "localhost:21434 only"' "$root/data/task/run-record.json" "run record lost network boundary"
  assert_grep 'done: bounded local-Qwen scout pass' "$root/state/task.status" "status did not report done"
  [ -z "$(git -C "$root/worktree" status --porcelain)" ] || fail "bounded scout modified its worktree"
  assert_contains "$out" '"result": "pass"' "runner output did not expose pass result"
  pass "bounded local-Qwen scout writes only its report/evidence and records the boundary"
}

test_timeout_kills_process_group_and_fails() {
  local root fake out status
  root=$(make_world timeout)
  fake="$root/tasktmp/fake-pi"
  cat > "$fake" <<'EOF'
#!/bin/sh
sleep 30
EOF
  chmod +x "$fake"

  out=$("$RUNNER" --id task --worktree "$root/worktree" \
    --brief "$root/data/task/brief.md" --report "$root/data/task/report.md" \
    --status "$root/state/task.status" --run-record "$root/data/task/run-record.json" \
    --task-tmp "$root/tasktmp" --timeout 1 --pi "$fake" 2>&1)
  status=$?
  expect_code 1 "$status" "timed-out bounded scout should fail"
  assert_grep '"timed_out": true' "$root/data/task/run-record.json" "timeout was not recorded"
  assert_grep '"result": "fail"' "$root/data/task/run-record.json" "timeout did not fail the run"
  assert_grep 'failed: bounded local-Qwen scout fail' "$root/state/task.status" "timeout did not report failure"
  pgrep -f "$fake" >/dev/null 2>&1 && fail "timed-out fake Pi process survived cleanup"
  assert_contains "$out" '"timed_out": true' "runner output did not expose timeout"
  pass "bounded local-Qwen scout kills its process group at the hard deadline"
}

test_prompt_contains_only_task_and_boundary() {
  local root fake captured
  root=$(make_world prompt)
  fake="$root/tasktmp/fake-pi"
  captured="$root/tasktmp/prompt.txt"
  cat > "$fake" <<EOF
#!/bin/sh
for arg in "\$@"; do printf '%s\n' "\$arg"; done > '$captured'
printf 'fixture evidence\n' > '$root/data/task/report.md'
printf '{"type":"agent_end"}\n'
EOF
  chmod +x "$fake"

  "$RUNNER" --id task --worktree "$root/worktree" \
    --brief "$root/data/task/brief.md" --report "$root/data/task/report.md" \
    --status "$root/state/task.status" --run-record "$root/data/task/run-record.json" \
    --task-tmp "$root/tasktmp" --timeout 5 --pi "$fake" >/dev/null 2>&1
  assert_grep 'TASK:' "$captured" "narrow prompt omitted task marker"
  assert_grep 'Inspect evidence.txt' "$captured" "narrow prompt omitted task text"
  if grep -q 'Ignored inherited setup' "$captured"; then
    fail "narrow prompt leaked inherited brief sections"
  fi
  pass "bounded local-Qwen prompt contains the task without inherited FirstMate boilerplate"
}

test_success_writes_only_report_and_record
test_timeout_kills_process_group_and_fails
test_prompt_contains_only_task_and_boundary

echo "# all fm-pi-qwen-alienware tests passed"
