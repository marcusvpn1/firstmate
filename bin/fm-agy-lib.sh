#!/usr/bin/env bash
# bin/fm-agy-lib.sh - AGY headless-crewmate adapter contract.
#
# AGY is an EXPERIMENTAL, unverified Firstmate crewmate harness. It is not in
# the verified adapter list (AGENTS.md section 4, bin/fm-control-lib.sh,
# bin/fm-quota-choose.sh) and is REFUSED by normal dispatch everywhere:
# bin/fm-spawn.sh refuses every agy dispatch (explicit, config/crew-harness,
# secondmate, and the raw launch escape hatch), so no production path reaches
# this library. The only sanctioned way to exercise agy is the opt-in live
# guard (tests/fm-agy-live-e2e.test.sh, FM_AGY_LIVE=1), which invokes the binary
# directly under the PG4 ambient-secret scrub and validates its result through
# the functions below. There is
# deliberately no production watcher/collection consumer: the publication,
# validation, liveness, and cleanup helpers are exercised only by that guard
# and the portable test suite.
#
# Agy runs headless: a single `agy --output-format json ... -p="<brief>"`
# invocation processes the brief, performs tool work inside the task worktree,
# writes one JSON result object to stdout, and exits. There is no interactive
# TUI, no turn-end hook, and no data-plane steering.
#
# Contract (observed against agy 1.2.1, 2026-09-11):
# - Kind: none by normal dispatch (refused for every kind); the live guard
#   exercises a one-shot print run only.
# - Backend: normal dispatch refuses every backend (tmux included) before
#   creating an endpoint (see bin/fm-spawn.sh); the live guard runs agy as a
#   direct subprocess, not through a runtime backend.
# - One-shot: completion is proven only by a validated result artifact, never
#   by exit code alone and never by rendered spinner text.
# - Result publication: bounded, atomic, task-owned, and generation-bound
#   (fm_agy_publish_result / fm_agy_result_file); exercised by the live guard
#   and the portable test suite, never by a production dispatch.
# - Version: exact pin (FM_AGY_PINNED_VERSION, default 1.2.1). The live guard
#   refuses a mismatch; it is never a warning.
# - Environment scrub: the launch template unsets the named ambient secrets
#   (STITCH_X_GOOG_API_KEY, STITCH_API_KEY, ANTHROPIC_API_KEY, APIFY_API_KEY,
#   HF_TOKEN) and every other *_API_KEY / *_TOKEN / *_SECRET var in the pane
#   shell before agy runs, so agy's MCP children never inherit ambient
#   credentials (the live guard applies the same scrub in its launch subshell).
#   The operator's own shell (and the Stitch MCP server it feeds)
#   is untouched: the unset happens only in the pane shell.
#
# Result schema (the real `--output-format json` object, observed 1.2.1):
#   {
#     "conversation_id": string,          # "" before a conversation starts
#     "status": "SUCCESS" | "ERROR",      # uppercase terminal status
#     "response": string,                 # model text ("" on error)
#     "error": string,                    # present only on error
#     "denied_actions": [ {..}, .. ],     # present when a tool action is auto-denied
#     "duration_seconds": number,
#     "num_turns": number,
#     "usage": { "input_tokens": number, "output_tokens": number,
#                "thinking_tokens": number, "cache_read_tokens": number,
#                "total_tokens": number }
#   }
# A `status` of SUCCESS with a non-empty `denied_actions` is a FAILED task: the
# conversation completed but a required tool action was denied, so the work did
# not happen. Success therefore requires SUCCESS and no denied actions.
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

# The model/effort vocabulary for agy is owned by model_flag_for_harness /
# effort_flag_for_harness in bin/fm-spawn.sh (--model passthrough, --effort
# low|medium|high); the lib deliberately holds no parallel copy that could
# drift from the flags a launch would actually use.

# The launch template is the documented reference shape for a one-shot agy run
# (exercised by the portable template-contract test, not by normal dispatch:
# agy is refused before it can reach a launch). The prompt is attached to -p
# with `=` so the flag does NOT swallow the next flag as its prompt (the
# "dashline" bug), and stdout is redirected through a per-generation temp file
# that is atomically renamed on completion. The template deliberately does NOT
# end in `exit $rc`: an `exit` would destroy the pane shell and turn a finished
# task's endpoint `missing` rather than `dead`, breaking relaunch. Completion
# is proven only by the validated result artifact, never by the shell exit
# status.
#
# Placeholders (resolved only by a test harness, never by fm-spawn.sh):
#   __MODELFLAG__   model flag (empty when default)
#   __EFFORTFLAG__  effort flag (empty when default)
#   __AGYLOGFILE__  per-generation log file path
#   __AGYRESULT__   per-generation result file path
#   __OPINPUT__     fm-operational-input.sh path
#   __BRIEF__       brief file path
# Emit the environment-scrub prefix that runs in the pane shell before agy. It
# unsets the named ambient secrets plus every other *_API_KEY / *_TOKEN /
# *_SECRET var, so agy and its MCP children never inherit ambient credentials.
# The unset runs only in the pane shell that launches agy; the operator's own
# environment (which feeds the Stitch MCP server) is left untouched.
fm_agy_env_scrub_code() {
  # shellcheck disable=SC2016 # emitted literally: expands in the pane shell
  printf '%s' 'unset STITCH_X_GOOG_API_KEY STITCH_API_KEY ANTHROPIC_API_KEY APIFY_API_KEY HF_TOKEN 2>/dev/null; for _fm_agy_k in $(env | awk -F= "\$1 ~ /_API_KEY\$|_TOKEN\$|_SECRET\$/ {print \$1}"); do unset "$_fm_agy_k" 2>/dev/null; done; '
}

fm_agy_launch_template() {
  # shellcheck disable=SC2016 # template literal: placeholders expand in the pane
  printf '%s%s' "$(fm_agy_env_scrub_code)" 'agy --output-format json --dangerously-skip-permissions --add-dir __WORKTREE__ __MODELFLAG____EFFORTFLAG__--print-timeout ${FM_AGY_PRINT_TIMEOUT:-600}s --log-file __AGYLOGFILE__ -p="$(__OPINPUT__ encode launch-brief < __BRIEF__)" > __AGYRESULT__.tmp; mv -f __AGYRESULT__.tmp __AGYRESULT__; chmod 600 __AGYRESULT__ 2>/dev/null'
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
    def allowed: ["conversation_id","status","response","error","denied_actions","duration_seconds","num_turns","usage"];
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
    and (if has("denied_actions") then (.denied_actions | type == "array") else true end)
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
  local result_file=$1 status denied
  command -v jq >/dev/null 2>&1 || {
    printf 'interpret-error: jq required for agy result interpretation\n' >&2
    return 1
  }
  status=$(jq -r '.status // empty' "$result_file" 2>/dev/null || true)
  [ "$status" = SUCCESS ] || return 1
  denied=$(jq -r '(.denied_actions | length) // 0' "$result_file" 2>/dev/null || true)
  [ "$denied" = 0 ]
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
