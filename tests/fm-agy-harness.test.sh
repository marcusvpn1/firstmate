#!/usr/bin/env bash
# Behavior tests for the AGY headless-crewmate harness adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGY_LIB="$ROOT/bin/fm-agy-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

# ---- agy lib unit tests ---------------------------------------------------

test_agy_detect_finds_installed_binary() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-ok")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
printf '1.1.8\n'
SH
  chmod +x "$fakebin/agy"

  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" bash -c '. "$1"; fm_agy_detect' _ "$AGY_LIB" 2>&1) || rc=$?
  expect_code 0 "$rc" "agy_detect failed on a found binary"
  assert_contains "$out" "1.1.8" "agy_detect did not report version"
  pass "agy_detect finds and reports the installed version"
}

test_agy_detect_reports_not_found() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-missing")

  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" bash -c '. "$1"; fm_agy_detect' _ "$AGY_LIB" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "agy_detect succeeded when agy was not on PATH"
  assert_contains "$out" "not-found" "agy_detect did not report not-found"
  pass "agy_detect fails when agy is not on PATH"
}

test_agy_auth_status_ok() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/auth-ok")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  models) printf 'Available models:\n  model-a\n  model-b\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/agy"

  out=$(PATH="$fakebin:$BASE_PATH" bash -c '. "$1"; fm_agy_auth_status' _ "$AGY_LIB" 2>&1)
  assert_contains "$out" "auth-ok" "agy_auth did not report ok"
  pass "agy_auth_status reports ok when models list succeeds"
}

test_agy_auth_status_failed() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/auth-fail")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
printf 'error: authentication failed\n' >&2
exit 1
SH
  chmod +x "$fakebin/agy"

  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" bash -c '. "$1"; fm_agy_auth_status' _ "$AGY_LIB" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "agy_auth succeeded when models command failed"
  assert_contains "$out" "auth-unverified" "agy_auth did not report failure"
  pass "agy_auth_status fails when agy models command fails"
}

test_agy_launch_cmd_shape() {
  local fakebin brief result log out
  fakebin=$(fm_fakebin "$TMP_ROOT/launch")
  brief="$TMP_ROOT/brief.md"
  result="$TMP_ROOT/result.json"
  log="$TMP_ROOT/agy.log"
  printf 'task description\n' > "$brief"

  out=$(bash -c '. "$1"; fm_agy_launch_cmd "$2" "$3" "$4"' _ \
    "$AGY_LIB" "$brief" "$result" "$log" 2>&1)
  assert_contains "$out" 'agy -p' "launch cmd missing agy invocation"
  assert_contains "$out" '--output-format json' "launch cmd missing output format"
  assert_contains "$out" '--dangerously-skip-permissions' "launch cmd missing permissions flag"
  assert_contains "$out" '--print-timeout' "launch cmd missing timeout"
  assert_contains "$out" '--log-file' "launch cmd missing log file"
  pass "agy_launch_cmd produces the expected command shape"
}

test_agy_launch_cmd_includes_model() {
  local fakebin brief result log out
  fakebin=$(fm_fakebin "$TMP_ROOT/launch-model")
  brief="$TMP_ROOT/brief.md"
  result="$TMP_ROOT/result.json"
  log="$TMP_ROOT/agy.log"
  printf 'task description\n' > "$brief"

  out=$(bash -c '. "$1"; fm_agy_launch_cmd "$2" "$3" "$4" "custom/model" ""' _ \
    "$AGY_LIB" "$brief" "$result" "$log" 2>&1)
  assert_contains "$out" '--model custom/model' "launch cmd missing model flag"
  pass "agy_launch_cmd includes model when specified"
}

test_agy_launch_cmd_includes_effort() {
  local fakebin brief result log out
  fakebin=$(fm_fakebin "$TMP_ROOT/launch-effort")
  brief="$TMP_ROOT/brief.md"
  result="$TMP_ROOT/result.json"
  log="$TMP_ROOT/agy.log"
  printf 'task description\n' > "$brief"

  out=$(bash -c '. "$1"; fm_agy_launch_cmd "$2" "$3" "$4" "" "high"' _ \
    "$AGY_LIB" "$brief" "$result" "$log" 2>&1)
  assert_contains "$out" '--effort high' "launch cmd missing effort flag"
  pass "agy_launch_cmd includes effort when specified"
}

test_agy_launch_cmd_omits_unsupported_effort() {
  local fakebin brief result log out
  fakebin=$(fm_fakebin "$TMP_ROOT/launch-effort-xhigh")
  brief="$TMP_ROOT/brief.md"
  result="$TMP_ROOT/result.json"
  log="$TMP_ROOT/agy.log"
  printf 'task description\n' > "$brief"

  out=$(bash -c '. "$1"; fm_agy_launch_cmd "$2" "$3" "$4" "" "xhigh"' _ \
    "$AGY_LIB" "$brief" "$result" "$log" 2>&1)
  if printf '%s\n' "$out" | grep -q 'effort'; then
    fail "agy_launch_cmd emitted unsupported effort xhigh"
  fi
  pass "agy_launch_cmd omits unsupported effort xhigh"
}

# ---- collect output tests --------------------------------------------------

test_agy_collect_output_multiline_json() {
  local dir out rc
  dir="$TMP_ROOT/collect-multiline"
  mkdir -p "$dir"

  rc=0
  out=$(bash -c '
    . "$1"
    fm_backend_tmux_capture() {
      printf "%s\n" \
        "some banner line" \
        "{" \
        "  \"status\": \"success\"," \
        "  \"changed_files\": [\"a.txt\"]," \
        "  \"summary\": \"done\"" \
        "}" \
        "user@host:~\$ "
    }
    fm_agy_collect_output dummy-target "$2"
  ' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  expect_code 0 "$rc" "collect_output failed on pretty multi-line JSON"
  assert_contains "$out" "collect-ok" "collect_output did not report ok"
  bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" "$dir/result.json" >/dev/null \
    || fail "collected multi-line JSON failed schema validation"
  grep -q 'user@host' "$dir/result.json" && fail "trailing prompt noise leaked into result.json"
  pass "collect_output extracts pretty multi-line JSON and drops trailing noise"
}

test_agy_collect_output_singleline_json() {
  local dir out rc
  dir="$TMP_ROOT/collect-singleline"
  mkdir -p "$dir"

  rc=0
  out=$(bash -c '
    . "$1"
    fm_backend_tmux_capture() {
      printf "%s\n" \
        "some banner line" \
        "{\"status\": \"success\", \"changed_files\": [\"a.txt\"], \"summary\": \"done\"}" \
        "user@host:~\$ "
    }
    fm_agy_collect_output dummy-target "$2"
  ' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  expect_code 0 "$rc" "collect_output failed on compact single-line JSON"
  assert_contains "$out" "collect-ok" "collect_output did not report ok"
  bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" "$dir/result.json" >/dev/null \
    || fail "collected single-line JSON failed schema validation"
  grep -q 'user@host' "$dir/result.json" && fail "trailing prompt noise leaked into result.json"
  pass "collect_output extracts compact single-line JSON and drops trailing noise"
}

# ---- result schema validation tests ---------------------------------------

make_valid_result() {
  local dir=$1 status=${2:-success}
  cat > "$dir/result.json" <<EOF
{
  "status": "$status",
  "changed_files": ["src/main.py", "tests/test_main.py"],
  "exit_code": 0,
  "summary": "Fixed the bug in main.py",
  "duration_ms": 12345
}
EOF
}

test_agy_validate_accepts_valid_result() {
  local dir out rc
  dir="$TMP_ROOT/validate-ok"
  mkdir -p "$dir"
  make_valid_result "$dir" success

  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  expect_code 0 "$rc" "validate_schema rejected a valid result"
  assert_contains "$out" "validate-ok" "validate_schema did not report ok"
  pass "validate_schema accepts a valid success result"
}

test_agy_validate_accepts_error_result() {
  local dir out rc
  dir="$TMP_ROOT/validate-error"
  mkdir -p "$dir"
  make_valid_result "$dir" error

  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  expect_code 0 "$rc" "validate_schema rejected a valid error result"
  assert_contains "$out" "validate-ok" "validate_schema did not report ok"
  pass "validate_schema accepts a valid error result"
}

test_agy_validate_rejects_missing_file() {
  local out rc
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" \
    "$TMP_ROOT/nonexistent.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate_schema accepted a nonexistent file"
  assert_contains "$out" "not found" "validate_schema missing-file diagnostic wrong"
  pass "validate_schema rejects a missing result file"
}

test_agy_validate_rejects_empty_file() {
  local dir out rc
  dir="$TMP_ROOT/validate-empty"
  mkdir -p "$dir"
  : > "$dir/result.json"

  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate_schema accepted an empty result file"
  assert_contains "$out" "empty" "validate_schema empty-file diagnostic wrong"
  pass "validate_schema rejects an empty result file"
}

test_agy_validate_rejects_missing_status() {
  local dir out rc
  dir="$TMP_ROOT/validate-no-status"
  mkdir -p "$dir"
  printf '{"changed_files": []}\n' > "$dir/result.json"

  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate_schema accepted result without status"
  assert_contains "$out" "schema mismatch" "validate_schema diagnostic wrong for missing status"
  pass "validate_schema rejects a result missing the status field"
}

test_agy_validate_rejects_missing_changed_files() {
  local dir out rc
  dir="$TMP_ROOT/validate-no-files"
  mkdir -p "$dir"
  printf '{"status": "success"}\n' > "$dir/result.json"

  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate_schema accepted result without changed_files"
  assert_contains "$out" "schema mismatch" "validate_schema diagnostic wrong for missing changed_files"
  pass "validate_schema rejects a result missing the changed_files field"
}

test_agy_validate_rejects_invalid_status() {
  local dir out rc
  dir="$TMP_ROOT/validate-bad-status"
  mkdir -p "$dir"
  printf '{"status": "partial", "changed_files": []}\n' > "$dir/result.json"

  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate_schema accepted invalid status value"
  assert_contains "$out" "schema mismatch" "validate_schema diagnostic wrong for invalid status"
  pass "validate_schema rejects an invalid status value"
}

test_agy_validate_rejects_changed_files_not_array() {
  local dir out rc
  dir="$TMP_ROOT/validate-bad-files"
  mkdir -p "$dir"
  printf '{"status": "success", "changed_files": "main.py"}\n' > "$dir/result.json"

  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_schema "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate_schema accepted changed_files as string"
  pass "validate_schema rejects changed_files that is not an array"
}

test_agy_validate_falls_back_to_grep_without_jq() {
  local dir out rc fakebin
  dir="$TMP_ROOT/validate-nojq"
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq-fake")
  mkdir -p "$dir"
  make_valid_result "$dir" success
  rm -f "$fakebin/jq"

  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" bash -c '. "$1"; fm_agy_validate_schema "$2"' _ \
    "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  expect_code 0 "$rc" "validate_schema without jq rejected a valid result"
  assert_contains "$out" "validate-ok" "validate_schema without jq did not report ok"
  pass "validate_schema falls back to grep when jq is absent"
}

# ---- result interpretation tests ------------------------------------------

test_agy_result_success_detects_status() {
  local dir
  dir="$TMP_ROOT/result-success"
  mkdir -p "$dir"
  make_valid_result "$dir" success

  bash -c '. "$1"; fm_agy_result_success "$2"' _ "$AGY_LIB" "$dir/result.json" \
    || fail "result_success returned false for status=success"
  pass "result_success returns true when status is success"
}

test_agy_result_success_rejects_error() {
  local dir
  dir="$TMP_ROOT/result-error"
  mkdir -p "$dir"
  make_valid_result "$dir" error

  if bash -c '. "$1"; fm_agy_result_success "$2"' _ "$AGY_LIB" "$dir/result.json"; then
    fail "result_success returned true for status=error"
  fi
  pass "result_success returns false when status is error"
}

# ---- cleanup tests --------------------------------------------------------

test_agy_cleanup_removes_result_dir() {
  local dir task_id
  task_id=cleanup-test-01
  dir=$(bash -c '. "$1"; fm_agy_ensure_result_dir "$2"' _ "$AGY_LIB" "$task_id")
  assert_present "$dir" "result dir was not created"

  bash -c '. "$1"; fm_agy_cleanup "$2"' _ "$AGY_LIB" "$task_id"
  assert_absent "$dir" "result dir survived cleanup"
  pass "cleanup removes the per-task result directory"
}

# ---- busy regex tests -----------------------------------------------------

test_agy_busy_regex_matches_expected_patterns() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"

  printf 'Thinking...\n' | fm_busy_lines_match agy || fail "Thinking... not busy"
  printf 'Working...\n' | fm_busy_lines_match agy || fail "Working... not busy"
  printf 'Analyzing...\n' | fm_busy_lines_match agy || fail "Analyzing... not busy"
  printf 'Executing...\n' | fm_busy_lines_match agy || fail "Executing... not busy"
  printf 'Processing...\n' | fm_busy_lines_match agy || fail "Processing... not busy"
  printf 'Task 3/7\n' | fm_busy_lines_match agy || fail "Task N/M not busy"
  printf 'Step 1/5\n' | fm_busy_lines_match agy || fail "Step N/M not busy"

  if printf 'Idle output\n' | fm_busy_lines_match agy; then
    fail "ordinary output was misread as busy"
  fi
  if printf 'esc to interrupt\n' | fm_busy_lines_match agy; then
    fail "non-AGY busy token leaked into AGY matcher"
  fi
  pass "agy busy regex matches expected patterns and rejects idle output"
}

test_agy_busy_regex_does_not_leak_to_other_harnesses() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"

  if printf 'Task 3/7\n' | fm_busy_lines_match claude; then
    fail "AGY busy token leaked into claude matcher"
  fi
  if printf 'Step 1/5\n' | fm_busy_lines_match codex; then
    fail "AGY busy token leaked into codex matcher"
  fi
  pass "agy busy regex is harness-scoped and does not leak"
}

# ---- spawn launch template tests ------------------------------------------

test_agy_launch_template_is_in_spawn() {
  assert_source_line() {
    grep -Fq -- "$1" "$SPAWN" || fail "expected line missing from fm-spawn: $1"
  }
  assert_source_line \
    "    agy) printf '%s' 'agy -p --output-format json --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__--print-timeout \${FM_AGY_PRINT_TIMEOUT:-600}s --log-file __AGYLOGFILE__ \"\$(cat __BRIEF__)\"' ;;"
  pass "fm-spawn: agy launch template uses raw brief passthrough"
}

test_agy_model_effort_in_spawn() {
  assert_source_line() {
    grep -Fq -- "$1" "$SPAWN" || fail "expected line missing from fm-spawn: $1"
  }
  assert_source_line \
    "    claude|codex|opencode|pi|pi-signed|grok|kimi|agy)"
  pass "fm-spawn: agy is in model_flag_for_harness"
}

test_agy_harness_detection_records_agy() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-ancestry")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf '/usr/local/bin/agy\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "agy ancestry detection returned '$out'"
  pass "fm-harness: agy is detected by process ancestry"
}

# ---- mock spawn test ------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="agy-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'agy brief for test\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_agy_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_AGY_PRINT_TIMEOUT=600 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" agy 2>&1
}

test_agy_spawn_succeeds() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case spawn-ok)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "agy spawn should succeed"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"
  pass "fm-spawn: agy spawn reports expected output"
}

test_agy_spawn_records_meta() {
  local rec case_dir home proj wt fakebin id out status meta
  rec=$(make_spawn_case spawn-meta)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  meta="$home/state/$id.meta"
  assert_present "$meta" "meta file was not created for agy spawn"
  assert_grep 'harness=agy' "$meta" "meta did not record harness=agy"
  pass "fm-spawn: agy spawn records harness=agy in meta"
}

# ---- existing launch templates byte-pinned test ---------------------------

test_existing_launch_templates_stay_byte_pinned() {
  assert_source_line() {
    grep -Fqx -- "$1" "$SPAWN" || fail "existing launch template changed: $1"
  }
  assert_source_line "    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  assert_source_line "        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c \"notify=[\\\"bash\\\",\\\"-c\\\",\\\"touch __TURNEND__\\\"]\" \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\\''{\"permission\":{\"*\":\"allow\"}}'\\'' opencode __MODELFLAG__--prompt \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  assert_source_line "        printf '%s%s' \"\$harness\" ' __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "        printf '%s%s' \"\$harness\" ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  pass "fm-spawn: the five pre-existing adapters' launch templates stay byte-pinned"
}

test_tracked_files_have_no_user_absolute_paths() {
  local pattern matches
  pattern="/""Users/"
  matches=$(git -C "$ROOT" grep -n -F "$pattern" -- . 2>/dev/null || true)
  [ -z "$matches" ] || fail "tracked files contain user-specific absolute paths: $matches"
  pass "repository: tracked files contain no user-specific absolute paths"
}

# ---- main ----------------------------------------------------------------

test_agy_detect_finds_installed_binary
test_agy_detect_reports_not_found
test_agy_auth_status_ok
test_agy_auth_status_failed
test_agy_launch_cmd_shape
test_agy_launch_cmd_includes_model
test_agy_launch_cmd_includes_effort
test_agy_launch_cmd_omits_unsupported_effort
test_agy_collect_output_multiline_json
test_agy_collect_output_singleline_json
test_agy_validate_accepts_valid_result
test_agy_validate_accepts_error_result
test_agy_validate_rejects_missing_file
test_agy_validate_rejects_empty_file
test_agy_validate_rejects_missing_status
test_agy_validate_rejects_missing_changed_files
test_agy_validate_rejects_invalid_status
test_agy_validate_rejects_changed_files_not_array
test_agy_validate_falls_back_to_grep_without_jq
test_agy_result_success_detects_status
test_agy_result_success_rejects_error
test_agy_cleanup_removes_result_dir
test_agy_busy_regex_matches_expected_patterns
test_agy_busy_regex_does_not_leak_to_other_harnesses
test_agy_launch_template_is_in_spawn
test_agy_model_effort_in_spawn
test_agy_harness_detection_records_agy
test_agy_spawn_succeeds
test_agy_spawn_records_meta
test_existing_launch_templates_stay_byte_pinned
test_tracked_files_have_no_user_absolute_paths
