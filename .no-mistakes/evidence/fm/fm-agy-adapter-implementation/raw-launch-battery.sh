#!/usr/bin/env bash
# Adversarial battery: can any raw launch command that resolves to the real
# agy executable bypass the raw-launch agy refusal? Each case runs the real
# bin/fm-spawn.sh in an isolated fake home/worktree and is capped at 10s so a
# non-refused case cannot stall on the treehouse wait loop.
set -u
WT=/Users/marcusnascimento/.no-mistakes/worktrees/2e94fa377077/01M29CNCCFM9JW3JTJ5RGH3SX7
. "$WT/tests/lib.sh"
ROOT=$WT
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-battery.XXXXXX")
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
  cat > "$fakebin/AGY" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  chmod +x "$fakebin/tmux" "$fakebin/agy" "$fakebin/AGY"
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id"
}

try() {  # label raw-command
  local label=$1 raw=$2 rec cd home proj wt fakebin id out rc meta
  rec=$(make_case "$label"); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
  local outf="$cd/out.txt"
  (
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" --mode no-mistakes --yolo off "$id" "$proj" "$raw" >"$outf" 2>&1
    echo "RC=$?" >> "$outf"
  ) &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do sleep 0.5; waited=$((waited+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    out="<TIMED OUT after 10s: reached the launch path, not refused>"
    rc="timeout"
  else
    wait "$pid" 2>/dev/null
    out=$(cat "$outf")
    rc=$(printf '%s' "$out" | grep -o 'RC=[0-9]*' | tail -1)
  fi
  if [ -e "$home/state/$id.meta" ]; then meta=CREATED; else meta=absent; fi
  if printf '%s' "$out" | grep -q 'refused by normal dispatch'; then
    verdict=REFUSED
  else
    verdict=NOT-REFUSED
  fi
  printf '%-28s %-11s %-8s %s\n' "$label" "$verdict" "meta=$meta" "$raw"
  printf '%s\n' "$out" | sed 's/^/      | /'
}

echo "### raw-launch agy refusal battery (real fm-spawn.sh, 10s cap) ###"
try still-first-word   "agy -p hello"
try abs-path           "/Users/marcusnascimento/.local/bin/agy -p hello"
try dot-slash          "./agy -p hello"
try env-wrapper        "env FOO=bar agy -p hello"
try env-var-quoted     "env 'FOO=bar' agy -p hello"
try command-builtin    "command agy -p hello"
try nohup-wrapper      "nohup agy -p hello"
try sh-c-wrapper       "sh -c 'agy -p hello'"
try bash-c-wrapper     "bash -c 'agy -p hello'"
try backslash-escape   "\\agy -p hello"
try double-quoted      "\"agy\" -p hello"
try uppercase-name     "AGY -p hello"
try uppercase-env      "env FOO=bar AGY -p hello"
try nested-path        "agy/../agy -p hello"
echo "### done ###"
