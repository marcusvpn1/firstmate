#!/usr/bin/env bash
# tests/fm-backend-herdr-workspace-race.test.sh - test for the workspace
# creation TOCTOU race fix in fm_backend_herdr_workspace_ensure.
#
# This test uses the stateful fake herdr to verify that concurrent calls to
# fm_backend_herdr_workspace_ensure do not create duplicate workspaces with
# the same label. The race is described in detail in
# data/fm-herdr-concurrent-spawn-cross-contamination/report.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# Forget inherited herdr pane identity
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-workspace-race-tests)
export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0

# For atomic state updates, we use mkdir for lock directories
# which is atomic on both Linux and macOS (two processes cannot both
# succeed in creating the same directory)

# Create the stateful fake herdr (inline version from fm-backend-herdr.test.sh)
make_herdr_statefake() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

# Atomic state operations using directory-based locking (cross-platform)
# mkdir is atomic: if two processes try to create the same directory,
# only one succeeds and the other gets EEXIST
jq_state() { jq "$@" "$STATE"; }

acquire_lock() {
  local lockdir="$STATE.lockdir"
  local max_wait=5 waited=0
  while [ $waited -lt $max_wait ]; do
    if mkdir "$lockdir" 2>/dev/null; then
      echo "$lockdir"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

release_lock() {
  rmdir "$1" 2>/dev/null || true
}

# Atomic read-modify-write using directory locks.
# Takes multiple arguments exactly as they should be passed to jq:
#   --arg name value ... 'filter expression'
# All arguments are forwarded verbatim to jq, so the filter can span multiple lines.
atomic_update() {
  local lockdir tmp rc
  lockdir=$(acquire_lock) || return 1
  tmp="$STATE.tmp.$$"
  jq "$@" "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  rc=$?
  release_lock "$lockdir"
  return $rc
}

cmd=${1:-}; sub=${2:-}
ws=""; label=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    # Atomically read current state and compute next values
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    # Atomically update state with new workspace
    atomic_update \
      --arg wsid "$wsid" \
      --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" \
      --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)'
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  *)
    printf '{"error":"unhandled command"}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

FAKEBIN=$(make_herdr_statefake "$TMP_ROOT")
export FM_FAKE_HERDR_STATE="$TMP_ROOT/state.json"
export FM_HERDR_LOG="$TMP_ROOT/herdr.log"
export FM_HERDR_RESPONSES="$TMP_ROOT/responses"
mkdir -p "$FM_HERDR_RESPONSES"
echo 0 > "$FM_HERDR_RESPONSES/.count"

# Add fakebin to PATH
export PATH="$FAKEBIN:$PATH"

# Source the herdr backend
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh" || die "failed to source herdr.sh"

# Set FM_BACKEND_HERDR_ROOT to the repo root
export FM_BACKEND_HERDR_ROOT="$ROOT"

fail() { printf 'not ok - %s\n' "$1" >&2; rm -rf "$TMP_ROOT"; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# test_workspace_race_no_duplicates: verify that concurrent calls to
# fm_backend_herdr_workspace_ensure do not create duplicate workspaces.
test_workspace_race_no_duplicates() {
  local session="test-race" cwd="$TMP_ROOT" label="test-label"
  local ws1 ws2 final_count

  # Reset the fake herdr state
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$FM_FAKE_HERDR_STATE"

  # Call workspace_ensure twice in parallel (simulate the race)
  # We use background processes to run in parallel
  (
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    # Mock the secondmate marker to force label-based lookup
    FM_HOME="$TMP_ROOT/home1"
    mkdir -p "$FM_HOME"
    unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
    ws1=$(fm_backend_herdr_workspace_ensure "$session" "$cwd" launcher-home)
    echo "$ws1"
  ) > "$TMP_ROOT/ws1.out" 2>&1 &
  local pid1=$!

  (
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    # Mock the secondmate marker to force label-based lookup
    FM_HOME="$TMP_ROOT/home2"
    mkdir -p "$FM_HOME"
    unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
    ws2=$(fm_backend_herdr_workspace_ensure "$session" "$cwd" launcher-home)
    echo "$ws2"
  ) > "$TMP_ROOT/ws2.out" 2>&1 &
  local pid2=$!

  wait "$pid1"
  wait "$pid2"

  ws1=$(cat "$TMP_ROOT/ws1.out")
  ws2=$(cat "$TMP_ROOT/ws2.out")

  # Verify both calls succeeded
  [ -n "$ws1" ] || fail "first call failed: $(cat "$TMP_ROOT/ws1.out")"
  [ -n "$ws2" ] || fail "second call failed: $(cat "$TMP_ROOT/ws2.out")"

  # Both should have gotten the SAME workspace (the first one created)
  [ "$ws1" = "$ws2" ] || fail "concurrent calls got different workspaces: ws1=$ws1 ws2=$ws2"

  # Verify there is only ONE workspace with the label in the fake state
  final_count=$(jq -r '[.workspaces[] | select(.label == "firstmate")] | length' "$FM_FAKE_HERDR_STATE")
  [ "$final_count" = "1" ] || fail "expected 1 workspace, found $final_count"

  pass "fm_backend_herdr_workspace_ensure: concurrent calls do not create duplicate workspaces"
}

# test_workspace_lock_path: verify the lock path function works
test_workspace_lock_path() {
  local session="test-session" label="test-label" lock_path

  lock_path=$(fm_backend_herdr_workspace_lock_path "$session" "$label") || fail "workspace_lock_path failed"
  [ -n "$lock_path" ] || fail "workspace_lock_path returned empty"

  # Verify the lock path is in the expected namespace
  case "$lock_path" in
    /tmp/firstmate-herdr-presentation/workspace-*.lock) ;;
    *) fail "workspace_lock_path returned unexpected path: $lock_path" ;;
  esac

  pass "fm_backend_herdr_workspace_lock_path: returns valid lock path"
}

# Run tests
echo "TAP version 13"
echo "1..2"

test_workspace_lock_path
test_workspace_race_no_duplicates

# Cleanup
rm -rf "$TMP_ROOT"