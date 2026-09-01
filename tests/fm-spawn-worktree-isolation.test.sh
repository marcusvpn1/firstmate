#!/usr/bin/env bash
# Regression test for bin/fm-spawn.sh's worktree-isolation guard (issue #2654).
#
# The guard must compare the launched worktree path against the primary
# checkout by directory identity, not as literal text. On a case-insensitive
# filesystem (the default macOS APFS) two spellings that differ only in case
# name the same directory, while `cd ... && pwd -P` resolves symlinks but
# preserves the case you typed. The live incident ran a crewmate in the primary
# checkout because the project was registered under one case spelling and the
# pane reported the primary under its on-disk case; the guard's string
# comparisons saw two different strings and let the primary through as if it
# were an isolated worktree.
#
# This test drives the real fm-spawn.sh spawn flow with a fake tmux/treehouse.
# It registers the primary project under a case-variant spelling, makes the
# fake pane report the primary under its on-disk case for two reads, then the
# real pooled worktree, and asserts the primary is never recorded as the
# worktree. The false-pass can only be reproduced on a case-insensitive
# filesystem, so the test probes for one and skips cleanly on case-sensitive
# filesystems (e.g. Linux CI), where a case-variant path cannot name the same
# directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-isolation)

# case_insensitive_fs <dir> exits 0 when the filesystem under <dir> resolves a
# case-variant spelling to the same directory entry.
case_insensitive_fs() {
  local dir=$1 probe
  probe="$dir/CaseProbe"
  mkdir -p "$probe" || return 1
  if [ -d "$dir/caseprobe" ]; then
    rmdir "$probe" 2>/dev/null || true
    return 0
  fi
  rmdir "$probe" 2>/dev/null || true
  return 1
}

if ! case_insensitive_fs "$TMP_ROOT"; then
  echo "skip: filesystem is case-sensitive; cannot exercise the case-insensitive isolation-guard false-pass"
  exit 0
fi

# make_fakebin <dir> builds a fake tmux whose `#{pane_current_path}` query
# returns FM_FAKE_PANE_PRIMARY for the first FM_FAKE_PANE_PRIMARY_READS calls,
# then FM_FAKE_PANE_PATH forever after - reproducing a pane that first reports
# the primary checkout under its on-disk case before settling into the real
# worktree.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_PRIMARY_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_PRIMARY:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_isolation_case <name> <id> builds a home, a primary project whose on-disk
# directory name is "Proj", a case-variant spelling "proj" used when registering
# the project with fm-spawn, and a real pooled worktree, then prints a
# pipe-delimited record.
make_isolation_case() {
  local name=$1 id=$2 case_dir home primary primary_variant wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/Proj"
  primary_variant="$case_dir/proj"
  wt="$case_dir/wt"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$primary" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$primary|$primary_variant|$wt|$fakebin|$countfile"
}

read_isolation_record() {
  IFS='|' read -r _ HOME_DIR PRIMARY_DIR PRIMARY_VARIANT_DIR WT_DIR FAKEBIN_DIR COUNTFILE <<EOF
$1
EOF
}

# Run fm-spawn with the project registered under the case-variant spelling
# (PRIMARY_VARIANT_DIR) while the fake pane reports the primary under its
# on-disk case (PRIMARY_DIR) first, then the real worktree (WT_DIR).
run_isolation_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_PRIMARY="$PRIMARY_DIR" \
    FM_FAKE_PANE_PRIMARY_READS="2" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PRIMARY_VARIANT_DIR" 2>&1
}

# The primary checkout reported under its on-disk case must not be accepted as
# the worktree, even when the project was registered under a different case
# spelling and even though the pane reports it twice in a row. The spawn should
# keep waiting, land on the real worktree, and record that instead.
test_case_variant_primary_is_not_accepted() {
  local rec id out status
  id=isolation-case-variant-z1
  rec=$(make_isolation_case case-variant "$id")
  read_isolation_record "$rec"

  out=$(run_isolation_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles into the real worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the real worktree"
  assert_no_grep "worktree=$PRIMARY_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the primary checkout as the worktree"
  pass "the primary checkout under a different case spelling is not accepted as the worktree"
}

test_case_variant_primary_is_not_accepted

echo "# all fm-spawn-worktree-isolation tests passed"
