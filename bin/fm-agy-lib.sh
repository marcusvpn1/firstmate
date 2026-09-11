#!/usr/bin/env bash
# bin/fm-agy-lib.sh - AGY headless-crewmate adapter contract.
#
# AGY is an EXPERIMENTAL, unverified Firstmate crewmate harness. It is not in
# the verified adapter list (AGENTS.md section 4, bin/fm-control-lib.sh,
# bin/fm-quota-choose.sh) and must never be selected by normal dispatch until
# the full proof gate in docs/verification/runtime-backends.md passes.
#
# Agy runs headless: a single `agy --output-format json ... -p="<brief>"`
# invocation processes the brief, performs tool work inside the task worktree,
# writes one JSON result object to stdout, and exits. There is no interactive
# TUI, no turn-end hook, and no data-plane steering.
#
# Contract (observed against agy 1.2.1, 2026-09-11):
# - Kind: crewmate and scout only. No secondmate, no primary.
# - Backend: tmux only. fm-spawn refuses every other backend before creating
#   an endpoint (see bin/fm-spawn.sh).
# - One-shot: completion is proven only by a validated result artifact, never
#   by exit code alone and never by rendered spinner text.
# - Result publication: agy stdout is redirected to a per-generation temp file
#   and atomically renamed into place by the launch wrapper, so a reader never
#   observes a half-written result.
# - Version: exact pin (FM_AGY_PINNED_VERSION, default 1.2.1). A mismatch
#   refuses launch; it is never a warning.
#
# Result schema (the real `--output-format json` object, observed 1.2.1):
#   {
#     "conversation_id": string,          # "" before a conversation starts
#     "status": "SUCCESS" | "ERROR",      # uppercase terminal status
#     "response": string,                 # model text ("" on error)
#     "error": string,                    # present only on error
#     "duration_seconds": number,
#     "num_turns": number,
#     "usage": { "input_tokens": number, "output_tokens": number,
#                "thinking_tokens": number, "cache_read_tokens": number,
#                "total_tokens": number }
#   }
# Validation is strict: malformed JSON, unknown top-level keys, unknown usage
# keys, wrong types, a missing terminal status, or an oversized artifact all
# fail closed. jq is a hard dependency for validation and interpretation; its
# absence fails explicitly rather than degrading to a weak grep.
set -u

# The exact version this adapter was verified against. Override only with a
# version that has been verified end to end; a different value refuses launch.
FM_AGY_PINNED_VERSION=${FM_AGY_PINNED_VERSION:-1.2.1}
# Hard cap on the published result artifact, in bytes.
FM_AGY_RESULT_MAX_BYTES=${FM_AGY_RESULT_MAX_BYTES:-1048576}

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

# Exact-version enforcement: return 0 only when the installed version equals the
# pinned version. A mismatch prints a diagnostic and returns 1 so callers refuse
# launch. The prior "warn but continue" behavior is gone: an unverified version
# must not be launched.
fm_agy_version_pinned() {
  local pinned=${FM_AGY_PINNED_VERSION:-1.2.1} current
  current=$(fm_agy_version)
  if [ "$current" = "$pinned" ]; then
    printf 'agy: version-ok %s\n' "$current"
    return 0
  fi
  printf 'agy: version-mismatch: installed %s, pinned %s; refusing launch\n' \
    "${current:-unknown}" "$pinned" >&2
  return 1
}

fm_agy_auth_status() {
  local out rc=0
  out=$(agy models 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'agy: auth-unverified\n'
    return 1
  fi
  if printf '%s\n' "$out" | grep -qi 'error\|unauthorized\|authentication' 2>/dev/null; then
    printf 'agy: auth-failed\n'
    return 1
  fi
  printf 'agy: auth-ok\n'
}

# ---- task-owned, generation-bound artifact paths --------------------------

# The artifact directory is task-owned (/tmp/fm-<task-id>), matching the spawn
# path's TASK_TMP. It is never a shared or predictable cross-task path.
fm_agy_result_dir() {  # <task_id>
  local task_id=$1
  case "$task_id" in
    ''|*/*|*'..'*) return 1 ;;
  esac
  printf '/tmp/fm-%s' "$task_id"
}

# The result artifact is bound to task id AND spawn generation: a stale
# artifact from a previous generation lives at a different path and is never
# read as this generation's result.
fm_agy_result_file() {  # <task_id> <spawn_gen>
  local task_id=$1 spawn_gen=$2 dir
  case "$spawn_gen" in
    ''|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  dir=$(fm_agy_result_dir "$task_id") || return 1
  printf '%s/result-%s.json' "$dir" "$spawn_gen"
}

fm_agy_log_file() {  # <task_id> <spawn_gen>
  local task_id=$1 spawn_gen=$2 dir
  case "$spawn_gen" in
    ''|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  dir=$(fm_agy_result_dir "$task_id") || return 1
  printf '%s/agy-%s.log' "$dir" "$spawn_gen"
}

fm_agy_ensure_result_dir() {  # <task_id>
  local task_id=$1 dir
  dir=$(fm_agy_result_dir "$task_id") || return 1
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# ---- launch ---------------------------------------------------------------

fm_agy_model_flag() {  # <model>
  local model=$1
  [ -n "$model" ] && [ "$model" != default ] || return 0
  printf -- '--model %s ' "$model"
}

fm_agy_effort_flag() {  # <effort>
  local effort=$1
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$effort" in
    low|medium|high) printf -- '--effort %s ' "$effort" ;;
  esac
}

# The launch template, emitted for bin/fm-spawn.sh's placeholder substitution.
# Unlike the historical template, the prompt is attached to -p with `=` so the
# flag does NOT swallow the following flag as its prompt (the "dashline" bug),
# and stdout is redirected through a per-generation temp file that is atomically
# renamed on completion, preserving agy's exit code.
#
# Placeholders substituted by fm-spawn.sh:
#   __MODELFLAG__   model flag (empty when default)
#   __EFFORTFLAG__  effort flag (empty when default)
#   __AGYLOGFILE__  per-generation log file path
#   __AGYRESULT__   per-generation result file path
#   __OPINPUT__     fm-operational-input.sh path
#   __BRIEF__       brief file path
fm_agy_launch_template() {
  # shellcheck disable=SC2016 # template literal: placeholders expand in the pane
  printf '%s' 'agy --output-format json --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__--print-timeout ${FM_AGY_PRINT_TIMEOUT:-600}s --log-file __AGYLOGFILE__ -p="$(__OPINPUT__ encode launch-brief < __BRIEF__)" > __AGYRESULT__.tmp; rc=$?; mv -f __AGYRESULT__.tmp __AGYRESULT__; exit $rc'
}

# ---- result publication ---------------------------------------------------

# Atomically publish a bounded raw result string to <result_file>. The write
# goes to a private-mode temp file first and is renamed into place, so a reader
# never observes a partial artifact. Empty and oversized inputs fail closed.
fm_agy_publish_result() {  # <result_file> <raw_json>
  local result_file=$1 raw=$2 tmp
  [ -n "$raw" ] || { printf 'publish-error: empty result\n'; return 1; }
  [ "${#raw}" -le "${FM_AGY_RESULT_MAX_BYTES:-1048576}" ] || {
    printf 'publish-error: oversized result (%s bytes > %s)\n' \
      "${#raw}" "${FM_AGY_RESULT_MAX_BYTES:-1048576}"
    return 1
  }
  tmp="${result_file}.tmp.$$"
  if ! ( umask 077; printf '%s\n' "$raw" > "$tmp" ) 2>/dev/null; then
    printf 'publish-error: write failed\n'
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$result_file" 2>/dev/null; then
    printf 'publish-error: atomic replace failed\n'
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  printf 'publish-ok: %s\n' "$result_file"
}

# ---- validation -----------------------------------------------------------

# fm_agy_validate_result: strict validation against the observed 1.2.1 schema.
# Rejects a missing/empty/oversized file, malformed JSON, unknown top-level or
# usage keys, wrong types, and an unknown terminal status. jq is required; its
# absence fails explicitly rather than silently accepting.
fm_agy_validate_result() {  # <result_file>
  local result_file=$1 size out

  [ -f "$result_file" ] || {
    printf 'validate-error: result file not found: %s\n' "$result_file"
    return 1
  }
  [ -s "$result_file" ] || {
    printf 'validate-error: result file is empty\n'
    return 1
  }
  size=$(wc -c < "$result_file" 2>/dev/null | tr -d ' ')
  case "$size" in
    ''|*[!0-9]*) size=0 ;;
  esac
  [ "$size" -le "${FM_AGY_RESULT_MAX_BYTES:-1048576}" ] || {
    printf 'validate-error: result file oversized (%s bytes)\n' "$size"
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'validate-error: jq required for agy result validation\n'
    return 1
  }

  out=$(jq -e '
    def allowed: ["conversation_id","status","response","error","duration_seconds","num_turns","usage"];
    def usage_allowed: ["input_tokens","output_tokens","thinking_tokens","cache_read_tokens","total_tokens"];
    type == "object"
    and (all(keys_unsorted[]; . as $k | allowed | index($k) != null))
    and (has("conversation_id") and has("status") and has("response")
         and has("duration_seconds") and has("num_turns") and has("usage"))
    and (.status | type == "string")
    and (.status == "SUCCESS" or .status == "ERROR")
    and (.conversation_id | type == "string")
    and (.response | type == "string")
    and (.duration_seconds | type == "number")
    and (.num_turns | type == "number")
    and (if has("error") then (.error | type == "string") else true end)
    and (.usage | type == "object")
    and (all(.usage | keys_unsorted[]; . as $k | usage_allowed | index($k) != null))
    and (.usage.input_tokens | type == "number")
    and (.usage.output_tokens | type == "number")
    and (.usage.thinking_tokens | type == "number")
    and (.usage.cache_read_tokens | type == "number")
    and (.usage.total_tokens | type == "number")
  ' "$result_file" 2>&1) || {
    printf 'validate-error: schema mismatch: %s\n' "$out"
    return 1
  }

  case "$out" in
    true) printf 'validate-ok\n'; return 0 ;;
    *) printf 'validate-error: schema rejected\n'; return 1 ;;
  esac
}

# ---- result interpretation ------------------------------------------------

# Success means the validated artifact carries status "SUCCESS". jq is a hard
# dependency here, and its absence fails explicitly rather than reporting a
# silent false. Callers must validate first; this only interprets.
fm_agy_result_success() {  # <result_file>
  local result_file=$1 status
  command -v jq >/dev/null 2>&1 || {
    printf 'interpret-error: jq required for agy result interpretation\n' >&2
    return 1
  }
  status=$(jq -r '.status // empty' "$result_file" 2>/dev/null || true)
  [ "$status" = SUCCESS ]
}

fm_agy_result_status() {  # <result_file>
  local result_file=$1
  command -v jq >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  jq -r '.status // "unknown"' "$result_file" 2>/dev/null || printf 'unknown\n'
}

# The human-readable outcome: the error field on ERROR, otherwise the response
# text trimmed to a bounded length.
fm_agy_result_summary() {  # <result_file>
  local result_file=$1
  if fm_agy_result_success "$result_file" 2>/dev/null; then
    jq -r '.response // empty' "$result_file" 2>/dev/null | head -c 2000 || true
  else
    jq -r '.error // empty' "$result_file" 2>/dev/null | head -c 2000 || true
  fi
}

# ---- observe / control (tmux) ---------------------------------------------

fm_agy_is_running() {  # <target>
  local target=$1
  fm_backend_tmux_current_command "$target" 2>/dev/null | grep -qx 'agy'
}

fm_agy_pane_pid() {  # <target>
  local target=$1
  tmux list-panes -t "$target" -F '#{pane_pid}' 2>/dev/null | head -1
}

# Interrupt an agy run: SIGINT first, then SIGTERM, then SIGKILL on the pane's
# process group, with bounded waits between escalations. Returns nonzero only
# when the process is still alive after every escalation.
fm_agy_terminate() {  # <target>
  local target=$1 pane_pid
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

# Remove this task's agy artifacts (result, log, temp) without ever deleting a
# path outside the task-owned directory. The directory itself is left to the
# task cleanup owner; only the adapter's own files are retired here.
fm_agy_cleanup() {  # <task_id>
  local task_id=$1 dir
  dir=$(fm_agy_result_dir "$task_id") || return 1
  rm -f "$dir"/result-*.json "$dir"/result-*.json.tmp.* "$dir"/agy-*.log 2>/dev/null || true
}

# ---- harness registration -------------------------------------------------

fm_agy_harness_name() {
  printf 'agy'
}
