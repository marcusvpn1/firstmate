#!/usr/bin/env bash
# bin/fm-agy-lib.sh - AGY headless-crewmate adapter contract.
#
# AGY is an EXPERIMENTAL harness for Firstmate crewmates.
# Unlike the interactive TUI harnesses (claude, codex, opencode, pi, grok,
# kimi), AGY runs headless: a single `agy -p` invocation processes the brief,
# performs tool work inside the task worktree, writes structured JSON to stdout,
# and exits.
#
# Because agy is headless, this adapter does not participate in composer
# classification, turn-end hooks, or interactive-steer loops.
# Instead it owns a detection / launch / observe / collect / cleanup contract.
#
# Key design decisions:
# - AGY is always launched inside a PTY (tmux pane) so it sees a TTY.
#   Piped stdout is explicitly NOT the protocol.
# - Exit code 0 is NOT treated as success.
#   Completion is proven only by a valid result.json artifact.
# - The result schema is strict and reject-unknown.
# - Transient AGY tokens and auth state stay in memory; they are never persisted
#   or logged.
# - Graceful cancellation (Ctrl-C) tries SIGINT first, then SIGTERM, then
#   SIGKILL after a bounded wait.
#
# Experimental status: single-worker only, no secondmate support, and model
# discovery is not integrated with quota-axi.
# Pinned version requirement: the adapter was verified against agy 1.1.8.
# A version mismatch warns but does not refuse launch.
# Known risk: agy --print may behave differently without a TTY; the PTY-backed
# runner is the mitigation.
# Promotion criteria: validate with real agy end-to-end, add quota-axi
# integration, verify secondmate support, and confirm no version-specific
# output-format drift before graduating from experimental.
#
# Result schema (strict, reject-unknown):
# {
#   "status": "success" | "error" | "cancelled",
#   "changed_files": ["relative/path", ...],
#   "exit_code": 0,
#   "error": null,
#   "summary": "What was done",
#   "duration_ms": 12345
# }
set -u

# ---- detect ---------------------------------------------------------------

fm_agy_detect() {
  local agy_bin version
  agy_bin=$(command -v agy 2>/dev/null || true)
  if [ -z "$agy_bin" ]; then
    printf 'agy: not-found\n'
    return 1
  fi
  version=$(agy --version 2>/dev/null || true)
  if [ -z "$version" ]; then
    printf 'agy: %s (version unknown)\n' "$agy_bin"
    return 0
  fi
  printf 'agy: %s (%s)\n' "$agy_bin" "$version"
}

fm_agy_version() {
  agy --version 2>/dev/null || true
}

fm_agy_version_pinned() {
  local pinned=${FM_AGY_PINNED_VERSION:-1.1.8}
  local current
  current=$(fm_agy_version)
  [ "$current" = "$pinned" ] && return 0
  printf 'warning: agy version %s (pinned %s); adapter may behave differently\n' \
    "$current" "$pinned" >&2
  return 0
}

fm_agy_auth_status() {
  local out rc
  out=$(agy models 2>&1) || rc=$?
  if [ "${rc:-0}" -ne 0 ]; then
    printf 'agy: auth-unverified\n'
    return 1
  fi
  if printf '%s\n' "$out" | grep -qi 'error\|unauthorized\|authentication' 2>/dev/null; then
    printf 'agy: auth-failed\n'
    return 1
  fi
  printf 'agy: auth-ok\n'
}

# ---- launch ---------------------------------------------------------------

fm_agy_result_dir() {
  local task_id=$1
  printf '/tmp/fm-%s' "$task_id"
}

fm_agy_result_file() {
  local task_id=$1
  printf '%s/result.json' "$(fm_agy_result_dir "$task_id")"
}

fm_agy_log_file() {
  local task_id=$1
  printf '%s/agy.log' "$(fm_agy_result_dir "$task_id")"
}

fm_agy_ensure_result_dir() {
  local task_id=$1 dir
  dir=$(fm_agy_result_dir "$task_id")
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

fm_agy_model_flag() {
  local model=$1
  [ -n "$model" ] && [ "$model" != default ] || return 0
  printf -- '--model %s ' "$model"
}

fm_agy_effort_flag() {
  local effort=$1
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$effort" in
    low|medium|high) printf -- '--effort %s ' "$effort" ;;
  esac
}

# Build the AGY headless launch command.
# The command runs inside a PTY (tmux pane), never piped.
# Output goes to the pane naturally; the watcher captures it after exit.
fm_agy_launch_cmd() {
  local brief_file=$1 result_file=$2 log_file=$3 model=${4:-} effort=${5:-}
  local cmd model_flag effort_flag

  model_flag=$(fm_agy_model_flag "$model")
  effort_flag=$(fm_agy_effort_flag "$effort")

  cmd='agy -p --output-format json --dangerously-skip-permissions'
  cmd="$cmd --print-timeout ${FM_AGY_PRINT_TIMEOUT:-600}s"
  cmd="$cmd --log-file $log_file"
  cmd="$cmd $model_flag"
  cmd="$cmd $effort_flag"
  cmd="$cmd \"\$(cat $brief_file)\""
  printf '%s' "$cmd"
}

# ---- observe --------------------------------------------------------------

# fm_agy_is_running: return 0 if an agy process is alive in the target pane.
fm_agy_is_running() {
  local target=$1
  fm_backend_tmux_current_command "$target" 2>/dev/null | grep -q 'agy' 2>/dev/null
}

# fm_agy_wait_for_completion: poll until agy exits.
# Returns 0 when agy is no longer running, 1 on timeout.
fm_agy_wait_for_completion() {
  local target=$1 timeout=${2:-600} i=0
  while [ "$i" -lt "$timeout" ]; do
    if ! fm_agy_is_running "$target"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# ---- collect --------------------------------------------------------------

# fm_agy_collect_output: capture the pane and extract JSON result.
# The pane may contain shell prompts and other noise;
# this extracts the last complete JSON object.
fm_agy_collect_output() {
  local target=$1 result_file=$2
  local capture json_start rel_end json_end

  capture=$(fm_backend_tmux_capture "$target" 2000 "fm-agy-collect" 2>/dev/null || true)
  if [ -z "$capture" ]; then
    printf 'collect-error: empty capture\n'
    return 1
  fi

  json_start=$(printf '%s\n' "$capture" | grep -n '^{' | tail -1 | cut -d: -f1 || true)
  if [ -z "$json_start" ]; then
    printf 'collect-error: no JSON object found in capture\n'
    return 1
  fi

  rel_end=$(printf '%s\n' "$capture" | tail -n +"$json_start" | grep -n '^}' | head -1 | cut -d: -f1 || true)
  if [ -z "$rel_end" ]; then
    printf 'collect-error: no closing brace found in capture\n'
    return 1
  fi
  json_end=$((json_start + rel_end - 1))

  printf '%s\n' "$capture" | sed -n "${json_start},${json_end}p" > "$result_file" 2>/dev/null || {
    printf 'collect-error: could not write result file\n'
    return 1
  }
  printf 'collect-ok: %s\n' "$result_file"
}

# ---- validate -------------------------------------------------------------

# fm_agy_validate_schema: validate result.json against the strict schema.
# Uses jq if available, falls back to grep-based structural checks.
fm_agy_validate_schema() {
  local result_file=$1

  [ -f "$result_file" ] || {
    printf 'validate-error: result file not found: %s\n' "$result_file"
    return 1
  }

  [ -s "$result_file" ] || {
    printf 'validate-error: result file is empty\n'
    return 1
  }

  if command -v jq >/dev/null 2>&1; then
    fm_agy_validate_jq "$result_file" || return 1
  else
    fm_agy_validate_grep "$result_file" || return 1
  fi

  printf 'validate-ok\n'
  return 0
}

fm_agy_validate_jq() {
  local result_file=$1
  local out

  out=$(jq -e '
    type == "object"
    and has("status")
    and (.status | type == "string")
    and (.status | IN("success", "error", "cancelled"))
    and has("changed_files")
    and (.changed_files | type == "array")
    and (if has("exit_code") then (.exit_code | type == "number") else true end)
    and (if has("error") then (.error | type == "string" or .error == null) else true end)
    and (if has("summary") then (.summary | type == "string") else true end)
    and (if has("duration_ms") then (.duration_ms | type == "number") else true end)
  ' "$result_file" 2>&1) || {
    printf 'validate-error: schema mismatch: %s\n' "$out"
    return 1
  }

  case "$out" in
    true) return 0 ;;
    *)
      printf 'validate-error: schema rejected (got %s)\n' "$out"
      return 1
      ;;
  esac
}

fm_agy_validate_grep() {
  local result_file=$1
  local status

  grep -q '"status"' "$result_file" || {
    printf 'validate-error: missing status field\n'
    return 1
  }
  grep -q '"changed_files"' "$result_file" || {
    printf 'validate-error: missing changed_files field\n'
    return 1
  }
  return 0
}

# ---- result interpretation ------------------------------------------------

fm_agy_result_success() {
  local result_file=$1
  local status
  status=$(jq -r '.status // empty' "$result_file" 2>/dev/null || true)
  [ "$status" = success ]
}

fm_agy_result_status() {
  local result_file=$1
  jq -r '.status // "unknown"' "$result_file" 2>/dev/null || printf 'unknown\n'
}

fm_agy_result_summary() {
  local result_file=$1
  jq -r '.summary // empty' "$result_file" 2>/dev/null || true
}

fm_agy_result_changed_files() {
  local result_file=$1
  jq -r '.changed_files[]?' "$result_file" 2>/dev/null || true
}

# ---- interrupt / cancel ---------------------------------------------------

fm_agy_interrupt() {
  local target=$1
  fm_backend_tmux_send_key "$target" C-c 2>/dev/null || true
}

fm_agy_pane_pid() {
  local target=$1
  tmux list-panes -t "$target" -F '#{pane_pid}' 2>/dev/null | head -1
}

fm_agy_terminate() {
  local target=$1
  local pane_pid

  fm_backend_tmux_send_key "$target" C-c 2>/dev/null || true
  sleep 2
  fm_agy_is_running "$target" || return 0

  printf 'agy: interrupt did not stop process; escalating to SIGTERM\n' >&2
  pane_pid=$(fm_agy_pane_pid "$target")
  if [ -n "$pane_pid" ]; then
    kill -TERM -- "-$pane_pid" 2>/dev/null || kill -TERM "$pane_pid" 2>/dev/null || true
    sleep 2
    if fm_agy_is_running "$target"; then
      printf 'agy: SIGTERM did not stop process; escalating to SIGKILL\n' >&2
      kill -KILL -- "-$pane_pid" 2>/dev/null || kill -KILL "$pane_pid" 2>/dev/null || true
      sleep 1
    fi
  fi

  if fm_agy_is_running "$target"; then
    printf 'agy: process still running after SIGKILL\n' >&2
    return 1
  fi
}

# ---- cleanup --------------------------------------------------------------

fm_agy_cleanup() {
  local task_id=$1
  local dir
  dir=$(fm_agy_result_dir "$task_id")
  rm -rf "$dir" 2>/dev/null || true
}

# ---- harness registration (for fm-spawn.sh) -------------------------------

# fm_agy_harness_name: the adapter name used in config/crew-harness.
fm_agy_harness_name() {
  printf 'agy'
}
