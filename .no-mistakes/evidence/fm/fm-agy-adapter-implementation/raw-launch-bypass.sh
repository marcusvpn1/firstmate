#!/usr/bin/env bash
# Adversarial: can a raw launch command that does not *start* with `agy`
# bypass the raw-launch agy refusal (e.g. `env FOO=bar agy ...`)?
set -u
WT=/Users/marcusnascimento/.no-mistakes/worktrees/2e94fa377077/01M29CNCCFM9JW3JTJ5RGH3SX7
. "$WT/tests/lib.sh"
ROOT=$WT
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-bypass.XXXXXX")
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

try() {  # label raw-command
  local label=$1 raw=$2 rec cd home proj wt fakebin id out rc
  rec=$(make_case "$label"); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" --mode no-mistakes --yolo off "$id" "$proj" "$raw" 2>&1); rc=$?
  printf '\n### raw=%q\n exit=%s\n meta=%s\n output:\n%s\n' \
    "$raw" "$rc" "$([ -e "$home/state/$id.meta" ] && echo CREATED || echo absent)" "$out"
}

try prefix-env "env FOO=bar agy -p hello"
try prefix-command "command agy -p hello"
try prefix-nohup "nohup agy -p hello"
try absolute "/usr/local/bin/agy -p hello"
try prefix-dash "agy -p hello"
