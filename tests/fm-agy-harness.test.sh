#!/usr/bin/env bash
# Behavior tests for the AGY headless-crewmate harness adapter.
#
# These exercise the adapter through its public functions and the fm-spawn.sh
# interface. They never assert implementation-source bytes; the launch command
# shape is pinned by calling fm_agy_launch_template and asserting the observable
# contract (the -p= fix, the generation-bound redirect, the json output mode).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside Cursor/Claude/Pi/Grok/Gemini/rovo/omp inherits those markers,
# which outrank the fake ancestry the detection cases set up. Drop the ambient
# markers so the asserted verdict does not depend on which harness launched
# the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI FM_OMP_HARNESS

AGY_LIB="$ROOT/bin/fm-agy-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL_LIB="$ROOT/bin/fm-control-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}
PINNED_VERSION="1.2.1"

# ---- helpers --------------------------------------------------------------

# A valid real-schema result object (observed agy 1.2.1).
agy_result_json() {  # <status>
  local status=$1 err=''
  if [ "$status" = ERROR ]; then
    err=',"error":"something failed"'
  fi
  printf '{"conversation_id":"c-1","status":"%s","response":"done","duration_seconds":1.5,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":2,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":12}%s}' \
    "$status" "$err"
}

# ---- agy lib unit tests ---------------------------------------------------

test_agy_detect_finds_installed_binary() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-ok")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
printf '1.2.1\n'
SH
  chmod +x "$fakebin/agy"

  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" bash -c '. "$1"; fm_agy_detect' _ "$AGY_LIB" 2>&1) || rc=$?
  expect_code 0 "$rc" "agy_detect failed on a found binary"
  assert_contains "$out" "1.2.1" "agy_detect did not report version"
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

test_agy_version_pinned_accepts_match() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/version-match")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
printf '1.2.1\n'
SH
  chmod +x "$fakebin/agy"

  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" bash -c '. "$1"; fm_agy_version_pinned' _ "$AGY_LIB" 2>&1) || rc=$?
  expect_code 0 "$rc" "version_pinned rejected a matching version"
  assert_contains "$out" "version-ok" "version_pinned did not report version-ok"
  pass "agy_version_pinned accepts the pinned version"
}

test_agy_version_pinned_rejects_mismatch() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/version-mismatch")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
printf '9.9.9\n'
SH
  chmod +x "$fakebin/agy"

  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" bash -c '. "$1"; fm_agy_version_pinned' _ "$AGY_LIB" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "version_pinned accepted a mismatching version"
  assert_contains "$out" "version-mismatch" "version_pinned diagnostic wrong"
  pass "agy_version_pinned refuses a mismatching version"
}

test_agy_auth_status_ok() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/auth-ok")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  models) printf 'Available models:\n  model-a\n'; exit 0 ;;
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
  pass "agy_auth_status fails when agy models command fails"
}

# ---- result path generation binding --------------------------------------

test_agy_result_file_binds_generation() {
  local f1 f2
  f1=$(bash -c '. "$1"; fm_agy_result_file t gen-a' _ "$AGY_LIB")
  f2=$(bash -c '. "$1"; fm_agy_result_file t gen-b' _ "$AGY_LIB")
  [ "$f1" != "$f2" ] || fail "result file did not change with generation"
  assert_contains "$f1" "result-gen-a.json" "result file missing generation token"
  assert_contains "$f2" "result-gen-b.json" "result file missing generation token"
  pass "result file path is bound to task id plus spawn generation"
}

test_agy_result_file_refuses_unsafe_task_id() {
  if bash -c '. "$1"; fm_agy_result_dir "../etc"' _ "$AGY_LIB" >/dev/null 2>&1; then
    fail "result dir accepted a path-traversal task id"
  fi
  pass "result dir refuses a path-traversal task id"
}

# ---- launch template contract --------------------------------------------

test_agy_launch_template_contract() {
  local out
  out=$(bash -c '. "$1"; fm_agy_launch_template' _ "$AGY_LIB")
  assert_contains "$out" 'agy --output-format json' "template missing invocation/output mode"
  assert_contains "$out" '--dangerously-skip-permissions' "template missing permission flag"
  assert_contains "$out" '--add-dir __WORKTREE__' "template missing the worktree --add-dir"
  # shellcheck disable=SC2016 # literal search string: the -p= placeholder
  assert_contains "$out" '-p="$(__OPINPUT__ encode launch-brief < __BRIEF__)"' "template missing the -p= attached prompt"
  assert_contains "$out" '> __AGYRESULT__.tmp' "template missing generation-bound redirect"
  assert_contains "$out" 'mv -f __AGYRESULT__.tmp __AGYRESULT__' "template missing atomic rename"
  assert_contains "$out" 'chmod 600 __AGYRESULT__' "template missing private-mode chmod"
  assert_contains "$out" 'unset STITCH_X_GOOG_API_KEY STITCH_API_KEY ANTHROPIC_API_KEY APIFY_API_KEY HF_TOKEN' "template missing the ambient-secret scrub"
  assert_contains "$out" '_API_KEY' "template missing the wildcard secret-pattern scrub"
  if printf '%s' "$out" | grep -q -- '-p '; then
    fail "template still uses the bare -p flag (the dashline bug)"
  fi
  if printf '%s' "$out" | grep -q 'exit'; then
    fail "template still ends the pane shell with 'exit' (destroys the endpoint)"
  fi
  pass "launch template fixes the -p flag, redirects to a generation-bound temp file, and scrubs ambient secrets"
}

test_agy_env_scrub_removes_secrets_preserves_others() {
  local out
  # The emitted fragment must unset the named secrets plus every other
  # *_API_KEY / *_TOKEN / *_SECRET var, while leaving unrelated vars intact.
  out=$(STITCH_X_GOOG_API_KEY=sk1 STITCH_API_KEY=sk2 ANTHROPIC_API_KEY=ak APIFY_API_KEY=af HF_TOKEN=hf \
        GITHUB_TOKEN=gh MY_CUSTOM_SECRET=sec KEEP_ME=kept PATH="$PATH" \
        bash -c '
    . "$1"
    eval "$(fm_agy_env_scrub_code)"
    for _v in STITCH_X_GOOG_API_KEY STITCH_API_KEY ANTHROPIC_API_KEY APIFY_API_KEY HF_TOKEN GITHUB_TOKEN MY_CUSTOM_SECRET; do
      [ -z "${!_v:-}" ] || { printf "leaked:%s\n" "$_v"; exit 1; }
    done
    [ "${KEEP_ME:-}" = kept ] || { printf "dropped:KEEP_ME\n"; exit 1; }
    printf "scrub-ok\n"
  ' _ "$AGY_LIB" 2>&1) || {
    fail "env scrub leaked a secret or dropped an unrelated var: $out"
  }
  assert_contains "$out" 'scrub-ok' "env scrub did not reach the ok marker"
  pass "env scrub removes every secret-patterned var and preserves unrelated vars"
}

# ---- result publication ---------------------------------------------------

test_agy_publish_result_atomic() {
  local dir file out
  dir="$TMP_ROOT/publish"
  mkdir -p "$dir"
  file="$dir/result.json"
  out=$(bash -c '. "$1"; fm_agy_publish_result "$2" "$3"' _ "$AGY_LIB" "$file" '{"status":"SUCCESS"}')
  assert_contains "$out" "publish-ok" "publish did not report ok"
  assert_present "$file" "result file not created"
  [ "$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file")" = 600 ] || fail "result file not private mode"
  pass "publish writes the result atomically with private mode"
}

test_agy_publish_result_rejects_empty() {
  local out rc
  rc=0
  out=$(bash -c '. "$1"; fm_agy_publish_result "$2" ""' _ "$AGY_LIB" "$TMP_ROOT/empty.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "publish accepted empty result"
  assert_contains "$out" "empty" "publish empty diagnostic wrong"
  pass "publish rejects an empty result"
}

test_agy_publish_result_rejects_oversized() {
  local out rc
  rc=0
  out=$(FM_AGY_RESULT_MAX_BYTES=10 bash -c '. "$1"; fm_agy_publish_result "$2" "$3"' _ "$AGY_LIB" "$TMP_ROOT/big.json" 'this is far more than ten bytes' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "publish accepted oversized result"
  assert_contains "$out" "oversized" "publish oversized diagnostic wrong"
  pass "publish rejects an oversized result"
}

# ---- result validation ----------------------------------------------------

test_agy_validate_accepts_success() {
  local dir out rc
  dir="$TMP_ROOT/validate-ok"
  mkdir -p "$dir"
  agy_result_json SUCCESS > "$dir/result.json"
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  expect_code 0 "$rc" "validate rejected a valid SUCCESS result"
  pass "validate accepts a valid SUCCESS result"
}

test_agy_validate_accepts_error() {
  local dir out rc
  dir="$TMP_ROOT/validate-err"
  mkdir -p "$dir"
  agy_result_json ERROR > "$dir/result.json"
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  expect_code 0 "$rc" "validate rejected a valid ERROR result"
  pass "validate accepts a valid ERROR result"
}

test_agy_validate_rejects_missing_file() {
  local out rc
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$TMP_ROOT/nope.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate accepted a missing file"
  assert_contains "$out" "not found" "validate missing-file diagnostic wrong"
  pass "validate rejects a missing file"
}

test_agy_validate_rejects_empty() {
  local dir out rc
  dir="$TMP_ROOT/validate-empty"
  mkdir -p "$dir"
  : > "$dir/result.json"
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate accepted an empty file"
  assert_contains "$out" "empty" "validate empty diagnostic wrong"
  pass "validate rejects an empty file"
}

test_agy_validate_rejects_malformed_json() {
  local dir out rc
  dir="$TMP_ROOT/validate-malformed"
  mkdir -p "$dir"
  printf 'not json at all\n' > "$dir/result.json"
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate accepted malformed JSON"
  pass "validate rejects malformed JSON"
}

test_agy_validate_rejects_unknown_top_level_key() {
  local dir out rc
  dir="$TMP_ROOT/validate-unknown-key"
  mkdir -p "$dir"
  printf '{"status":"SUCCESS","response":"x","conversation_id":"","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"surprise":true}\n' > "$dir/result.json"
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate accepted an unknown top-level key"
  pass "validate rejects an unknown top-level key"
}

test_agy_validate_rejects_unknown_usage_key() {
  local dir out rc
  dir="$TMP_ROOT/validate-unknown-usage"
  mkdir -p "$dir"
  printf '{"status":"SUCCESS","response":"x","conversation_id":"","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0,"extra":1}}\n' > "$dir/result.json"
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate accepted an unknown usage key"
  pass "validate rejects an unknown usage key"
}

test_agy_validate_rejects_wrong_type() {
  local dir out rc
  dir="$TMP_ROOT/validate-wrong-type"
  mkdir -p "$dir"
  printf '{"status":7,"response":"x","conversation_id":"","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}\n' > "$dir/result.json"
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate accepted a wrong status type"
  pass "validate rejects a wrong type"
}

test_agy_validate_rejects_unknown_status() {
  local dir out rc
  dir="$TMP_ROOT/validate-unknown-status"
  mkdir -p "$dir"
  agy_result_json SUCCESS | sed 's/"SUCCESS"/"PARTIAL"/' > "$dir/result.json"
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate accepted an unknown status"
  pass "validate rejects an unknown terminal status"
}

test_agy_validate_rejects_oversized_file() {
  local dir out rc
  dir="$TMP_ROOT/validate-oversized"
  mkdir -p "$dir"
  head -c 2000000 /dev/zero | tr '\0' 'x' > "$dir/result.json"
  rc=0
  out=$(bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "validate accepted an oversized file"
  assert_contains "$out" "oversized" "validate oversized diagnostic wrong"
  pass "validate rejects an oversized file"
}

# ---- result interpretation ------------------------------------------------

test_agy_result_success_detects_status() {
  local dir
  dir="$TMP_ROOT/result-success"
  mkdir -p "$dir"
  agy_result_json SUCCESS > "$dir/result.json"
  bash -c '. "$1"; fm_agy_result_success "$2"' _ "$AGY_LIB" "$dir/result.json" \
    || fail "result_success returned false for SUCCESS"
  pass "result_success returns true for status SUCCESS"
}

test_agy_result_success_rejects_error() {
  local dir
  dir="$TMP_ROOT/result-error"
  mkdir -p "$dir"
  agy_result_json ERROR > "$dir/result.json"
  if bash -c '. "$1"; fm_agy_result_success "$2"' _ "$AGY_LIB" "$dir/result.json"; then
    fail "result_success returned true for ERROR"
  fi
  pass "result_success returns false for status ERROR"
}

test_agy_denied_actions_not_success() {
  local dir
  dir="$TMP_ROOT/result-denied"
  mkdir -p "$dir"
  # status SUCCESS but a tool action was auto-denied: a real agy field that
  # must validate, yet never count as success (the work did not happen).
  printf '{"status":"SUCCESS","response":"","conversation_id":"","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"denied_actions":[{"action":"command","display_name":"RunCommand"}]}\n' > "$dir/result.json"
  bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$dir/result.json" >/dev/null \
    || fail "validate rejected a real denied_actions result"
  if bash -c '. "$1"; fm_agy_result_success "$2"' _ "$AGY_LIB" "$dir/result.json"; then
    fail "result_success returned true when a tool action was denied"
  fi
  pass "denied_actions validates as a real field but never counts as success"
}

# ---- cleanup --------------------------------------------------------------

test_agy_cleanup_removes_result_artifacts() {
  local dir task_id f
  task_id=cleanup-test-01
  dir=$(bash -c '. "$1"; fm_agy_ensure_result_dir "$2"' _ "$AGY_LIB" "$task_id")
  f=$(bash -c '. "$1"; fm_agy_result_file "$2" g1' _ "$AGY_LIB" "$task_id")
  printf '{"status":"SUCCESS"}\n' > "$f"
  assert_present "$f" "result file not created"

  bash -c '. "$1"; fm_agy_cleanup "$2"' _ "$AGY_LIB" "$task_id"
  assert_absent "$f" "result file survived cleanup"
  pass "cleanup removes the task's agy result artifacts"
}

# ---- liveness -------------------------------------------------------------

test_agy_is_running() {
  local out rc
  rc=0
  out=$(bash -c '
    . "$1"
    fm_backend_tmux_current_command() { printf "agy\n"; }
    fm_agy_is_running t
  ' _ "$AGY_LIB" 2>&1) || rc=$?
  expect_code 0 "$rc" "is_running did not detect the agy process"
  pass "is_running detects the exact agy process name"
}

test_agy_is_running_not_idle_shell() {
  local rc
  rc=0
  bash -c '
    . "$1"
    fm_backend_tmux_current_command() { printf "bash\n"; }
    fm_agy_is_running t
  ' _ "$AGY_LIB" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "an idle shell was mistaken for a live agy process"
  pass "is_running never mistakes an idle shell for agy"
}

# ---- harness detection ----------------------------------------------------

make_fake_ps() {  # <dir> <comm-for-target-pid>
  local dir=$1 comm=$2
  local fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "\$@"; do
  [ "\$prev" = -o ] && field=\$arg
  [ "\$prev" = -p ] && pid=\$arg
  prev=\$arg
done
case "\$field:\$pid" in
  comm=:4242) printf '$comm\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_agy_harness_detection_exact_match() {
  local fakebin out
  fakebin=$(make_fake_ps "$TMP_ROOT/detect-ancestry-ok" '/usr/local/bin/agy')
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "exact agy ancestry returned '$out'"
  pass "fm-harness detects the exact agy process name"
}

test_agy_harness_detection_not_glob() {
  local fakebin out
  fakebin=$(make_fake_ps "$TMP_ROOT/detect-ancestry-fragment" '/usr/local/bin/magy')
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" != agy ] || fail "a non-agy command with the fragment was elevated to agy"
  pass "fm-harness does not glob-match unrelated commands as agy"
}

# ---- mock spawn tests -----------------------------------------------------

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
  cat > "$fakebin/agy" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) printf '$PINNED_VERSION\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/agy"
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
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task

## Captain's intent
agy brief for test

## Firstmate spec
do it
EOF
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
    "$SPAWN" --mode no-mistakes --yolo off "$id" "$proj" agy 2>&1
}

test_agy_spawn_refused() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case spawn-refused)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn should be refused, not launched: $out"
  assert_contains "$out" "refused by normal dispatch" "agy spawn refusal diagnostic wrong"
  pass "fm-spawn: agy is refused by normal dispatch even on tmux with a matching version"
}

test_agy_spawn_refused_creates_no_meta() {
  local rec case_dir home proj wt fakebin id out meta
  rec=$(make_spawn_case spawn-refused-meta)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  meta="$home/state/$id.meta"
  assert_absent "$meta" "a refused agy spawn still created a meta file"
  pass "fm-spawn: a refused agy spawn creates no meta file"
}

test_agy_spawn_refused_via_config() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case spawn-config-refused)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  printf 'agy\n' > "$home/config/crew-harness"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" --mode no-mistakes --yolo off "$id" "$proj" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "config/crew-harness=agy spawn should be refused"
  assert_contains "$out" "refused by normal dispatch" "agy config refusal diagnostic wrong"
  pass "fm-spawn: config/crew-harness=agy is refused"
}

test_agy_spawn_rejects_secondmate() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case spawn-secondmate)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" --secondmate "$id" "$home" agy 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "agy secondmate spawn should be refused"
  assert_contains "$out" "refused by normal dispatch" "agy secondmate refusal diagnostic wrong"
  pass "fm-spawn: agy secondmate is refused"
}

test_agy_spawn_refused_on_herdr() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case spawn-refused-herdr)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" --mode no-mistakes --yolo off --backend herdr "$id" "$proj" agy 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn on herdr should be refused, not launched: $out"
  assert_contains "$out" "refused by normal dispatch" "agy herdr refusal diagnostic wrong"
  pass "fm-spawn: agy is refused on the herdr backend before endpoint creation"
}

# The raw launch escape hatch derives the harness from the first command word,
# so a command that wraps agy behind a launcher (env/command/nohup/sh -c) hid it
# from the first-word refusal and reached the launch path. This drives the real
# fm-spawn.sh for each wrapper and asserts the refusal fires before any endpoint.
# Case variants are covered because the executable lookup is case-insensitive on
# the target platform, so `AGY` resolves to the same binary.
test_agy_spawn_refused_wrapped_raw_command() {
  local raw rec case_dir home proj wt fakebin id out status idx=0 failures=''
  for raw in 'env FOO=bar agy -p hello' 'command agy -p hello' 'nohup agy -p hello' "sh -c 'agy -p hello'" 'AGY -p hello' 'env FOO=bar AGY -p hello'; do
    idx=$((idx + 1))
    rec=$(make_spawn_case "spawn-raw-wrapped-$idx")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
      FM_AGY_PRINT_TIMEOUT=600 \
      PATH="$fakebin:$BASE_PATH" \
      "$SPAWN" --mode no-mistakes --yolo off "$id" "$proj" "$raw" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] || ! printf '%s' "$out" | grep -q 'refused by normal dispatch'; then
      failures="$failures
raw='$raw' status=$status: $out"
    fi
    if [ -e "$home/state/$id.meta" ]; then
      failures="$failures
raw='$raw' created $home/state/$id.meta"
    fi
  done
  [ -z "$failures" ] || fail "a wrapped raw launch command bypassed the agy refusal:$failures"
  pass "fm-spawn: a raw command wrapping agy behind env/command/nohup/sh, or spelling it in another case, is refused"
}

# A raw command can also resolve to agy through shell grouping or expansion
# rather than a literal word: a subshell `(agy ...)`, an assignment plus `$A`,
# a parameter expansion `${AGY:-agy}`, or a command substitution
# `$(printf agy)`. Those operators fuse agy to their syntax, so the refusal
# normalizes shell metacharacters into word boundaries before scanning and
# rejects the command before any endpoint is created.
test_agy_spawn_refused_expansion_raw_command() {
  local raw rec case_dir home proj wt fakebin id out status idx=0 failures=''
  for raw in '(agy -p hello)' 'A=agy; $A -p hello' 'A=agy; env $A -p hello' '${AGY:-agy} -p hello' 'sh -c "$(printf agy) -p hello"' 'AGYBIN=agy; exec $AGYBIN -p hello'; do
    idx=$((idx + 1))
    rec=$(make_spawn_case "spawn-raw-expand-$idx")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
      FM_AGY_PRINT_TIMEOUT=600 \
      PATH="$fakebin:$BASE_PATH" \
      "$SPAWN" --mode no-mistakes --yolo off "$id" "$proj" "$raw" 2>&1)
    status=$?
    if [ "$status" -eq 0 ] || ! printf '%s' "$out" | grep -q 'refused by normal dispatch'; then
      failures="$failures
raw='$raw' status=$status: $out"
    fi
    if [ -e "$home/state/$id.meta" ]; then
      failures="$failures
raw='$raw' created $home/state/$id.meta"
    fi
  done
  [ -z "$failures" ] || fail "an expanded raw launch command bypassed the agy refusal:$failures"
  pass "fm-spawn: a raw command that resolves to agy through grouping or expansion is refused"
}

test_agy_control_refused() {
  if bash -c '. "$1"; fm_control_harness_supported agy' _ "$CONTROL_LIB" 2>/dev/null; then
    fail "agy control was reported harness-supported"
  fi
  if bash -c '. "$1"; fm_control_harness_family agy' _ "$CONTROL_LIB" 2>/dev/null; then
    fail "agy was mapped to a control family"
  fi
  pass "agy control verbs are refused (no control family, not harness-supported)"
}

test_agy_stale_generation_rejected() {
  local task_id dir stale cur rc
  task_id="stale-gen-test-$$"
  dir=$(bash -c '. "$1"; fm_agy_ensure_result_dir "$2"' _ "$AGY_LIB" "$task_id")
  stale=$(bash -c '. "$1"; fm_agy_result_file "$2" gen-old' _ "$AGY_LIB" "$task_id")
  cur=$(bash -c '. "$1"; fm_agy_result_file "$2" gen-new' _ "$AGY_LIB" "$task_id")
  [ "$stale" != "$cur" ] || fail "stale and current generation share a result path"
  agy_result_json SUCCESS > "$stale"
  agy_result_json SUCCESS > "$cur"
  rc=0
  bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$AGY_LIB" "$cur" 2>/dev/null || rc=$?
  expect_code 0 "$rc" "the current generation's valid artifact was rejected"
  bash -c '. "$1"; fm_agy_cleanup "$2"' _ "$AGY_LIB" "$task_id"
  assert_absent "$stale" "stale artifact survived cleanup"
  assert_absent "$cur" "current artifact survived cleanup"
  rmdir "$dir" 2>/dev/null || true
  pass "generation-bound paths keep a stale artifact out of the current result, and cleanup retires both"
}

test_agy_harness_detection_exact_match
test_agy_harness_detection_not_glob
test_agy_detect_finds_installed_binary
test_agy_detect_reports_not_found
test_agy_version_pinned_accepts_match
test_agy_version_pinned_rejects_mismatch
test_agy_auth_status_ok
test_agy_auth_status_failed
test_agy_result_file_binds_generation
test_agy_result_file_refuses_unsafe_task_id
test_agy_launch_template_contract
test_agy_env_scrub_removes_secrets_preserves_others
test_agy_publish_result_atomic
test_agy_publish_result_rejects_empty
test_agy_publish_result_rejects_oversized
test_agy_validate_accepts_success
test_agy_validate_accepts_error
test_agy_validate_rejects_missing_file
test_agy_validate_rejects_empty
test_agy_validate_rejects_malformed_json
test_agy_validate_rejects_unknown_top_level_key
test_agy_validate_rejects_unknown_usage_key
test_agy_validate_rejects_wrong_type
test_agy_validate_rejects_unknown_status
test_agy_validate_rejects_oversized_file
test_agy_result_success_detects_status
test_agy_result_success_rejects_error
test_agy_denied_actions_not_success
test_agy_cleanup_removes_result_artifacts
test_agy_is_running
test_agy_is_running_not_idle_shell
test_agy_control_refused
test_agy_stale_generation_rejected
test_agy_spawn_refused
test_agy_spawn_refused_creates_no_meta
test_agy_spawn_refused_via_config
test_agy_spawn_rejects_secondmate
test_agy_spawn_refused_on_herdr
test_agy_spawn_refused_wrapped_raw_command
test_agy_spawn_refused_expansion_raw_command
