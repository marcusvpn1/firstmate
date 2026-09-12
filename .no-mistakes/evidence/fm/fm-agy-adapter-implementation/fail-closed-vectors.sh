#!/usr/bin/env bash
# Additional fail-closed vectors: --harness=agy, --harness 'agy -p ...',
# config/secondmate-harness=agy, and relaunch of a recorded agy task.
set -u
WT=/Users/marcusnascimento/.no-mistakes/worktrees/2e94fa377077/01M29CNCCFM9JW3JTJ5RGH3SX7
. "$WT/tests/lib.sh"
ROOT=$WT
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-vectors.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

make_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"; home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  id="agy-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
x
## Firstmate spec
do it
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id" >/dev/null 2>&1
  touch "$home/state/.last-watcher-beat"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  chmod +x "$fakebin/tmux" "$fakebin/agy"
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id"
}

envrun() { local home=$1 fakebin=$2; shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" PATH="$fakebin:$BASE_PATH" "$@"
}

show() { local label=$1 out=$2 rc=$3 meta=$4
  printf '\n### %s\n exit=%s meta=%s\n %s\n' "$label" "$rc" "$([ -e "$meta" ] && echo CREATED || echo absent)" "$out"
}

rec=$(make_case hflag); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
out=$(envrun "$home" "$fakebin" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off --harness agy 2>&1); rc=$?
show "--harness agy" "$out" "$rc" "$home/state/$id.meta"

rec=$(make_case heq); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
out=$(envrun "$home" "$fakebin" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off --harness=agy 2>&1); rc=$?
show "--harness=agy" "$out" "$rc" "$home/state/$id.meta"

rec=$(make_case hraw); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
out=$(envrun "$home" "$fakebin" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off --harness 'agy -p hello' 2>&1); rc=$?
show "--harness 'agy -p hello'" "$out" "$rc" "$home/state/$id.meta"

rec=$(make_case smcfg); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
printf 'agy\n' > "$home/config/secondmate-harness"
out=$(envrun "$home" "$fakebin" "$SPAWN" --secondmate "$id" "$home" 2>&1); rc=$?
show "config/secondmate-harness=agy (no positional)" "$out" "$rc" "$home/state/$id.meta"

rec=$(make_case relaunch); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
cat > "$home/state/$id.meta" <<EOF
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$wt
project=$proj
harness=agy
kind=crewmate
mode=no-mistakes
yolo=off
EOF
out=$(envrun "$home" "$fakebin" "$SPAWN" "$id" --relaunch 2>&1); rc=$?
show "relaunch of a task recorded harness=agy" "$out" "$rc" "$home/state/$id.meta"
