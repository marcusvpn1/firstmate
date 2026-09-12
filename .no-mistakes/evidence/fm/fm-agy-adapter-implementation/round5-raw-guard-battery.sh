#!/usr/bin/env bash
# Round-5 adversarial battery for the agy raw-launch refusal.
#
# Drives the REAL bin/fm-spawn.sh against an isolated disposable home + git
# worktree. The fake tmux shim records every send-keys invocation, so a case
# that reaches the launch path is observable as tmux-sendkeys=yes + meta=yes,
# while a refused case exits nonzero with the refusal diagnostic and no endpoint.
#
# Statically detectable spellings (the documented guarantee) MUST be refused.
# Runtime-computed names ($'a\x67y', a$(printf g)y) are documented as OUTSIDE
# the static-scan guarantee and are reported for honesty, not as failures.
set -u
WT=/Users/marcusnascimento/.no-mistakes/worktrees/2e94fa377077/01M29CNCCFM9JW3JTJ5RGH3SX7
. "$WT/tests/lib.sh"
ROOT=$WT
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-r5.XXXXXX")
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
  # tmux shim: record every invocation (argv) into the case dir, exit 0.
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tmux.log"
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

# classify: expected = refuse|outside-guarantee
try() {
  local expected=$1 label=$2 raw=$3
  local rec cd home proj wt fakebin id outf rc waited verdict meta sendkeys
  rec=$(make_case "$label"); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
  outf="$cd/out.txt"
  : > "$cd/tmux.log"
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
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 12 ]; do sleep 0.5; waited=$((waited+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    rc="timeout(reached-launch-path)"
  else
    wait "$pid" 2>/dev/null
    rc=$(grep -o 'RC=[0-9]*' "$outf" | tail -1)
  fi
  if grep -q 'refused by normal dispatch' "$outf"; then verdict=REFUSED; else verdict=NOT-REFUSED; fi
  if [ -e "$home/state/$id.meta" ]; then meta=CREATED; else meta=absent; fi
  if [ -s "$cd/tmux.log" ]; then sendkeys=yes; else sendkeys=no; fi
  local ok=OK
  if [ "$expected" = refuse ]; then
    { [ "$verdict" = REFUSED ] && [ "$meta" = absent ] && [ "$sendkeys" = no ]; } || ok=FAIL
  else
    ok=INFO
  fi
  printf '%-6s %-9s %-16s %-11s meta=%-7s sendkeys=%-3s %s\n' \
    "$ok" "$expected" "$label" "$verdict" "$meta" "$sendkeys" "$raw"
  if [ "$ok" = FAIL ]; then
    sed 's/^/       | /' "$outf"
  fi
}

echo "### Round-5 agy raw-launch refusal battery (real bin/fm-spawn.sh) ###"
echo "### guard: bin/fm-spawn.sh raw_command_invokes_agy (HEAD $(cd "$WT" && git rev-parse --short HEAD)) ###"
echo
echo "-- regression: quoted/escaped fragments (the round-5 fix) --"
try refuse double-quoted-concat 'a"g"y -p hello'
try refuse single-quoted-concat "a'g'y -p hello"
try refuse backslash-escaped    'a\gy -p hello'
try refuse literal-cmdsubst     "\$(printf 'a''g''y') -p hello"
echo
echo "-- regression: previously-detected statically detectable forms --"
try refuse literal            'agy -p hello'
try refuse env-wrapper        'env FOO=bar agy -p hello'
try refuse command-builtin    'command agy -p hello'
try refuse nohup-wrapper      'nohup agy -p hello'
try refuse sh-c-wrapper       "sh -c 'agy -p hello'"
try refuse uppercase          'AGY -p hello'
try refuse uppercase-env      'env FOO=bar AGY -p hello'
try refuse grouped-subshell   '(agy -p hello)'
try refuse assignment-expand  'A=agy; $A -p hello'
try refuse param-expansion    '${AGY:-agy} -p hello'
try refuse cmdsubst-print     'sh -c "$(printf agy) -p hello"'
try refuse abs-path           '/Users/marcusnascimento/.local/bin/agy -p hello'
echo
echo "-- outside the documented static guarantee (runtime-computed; may proceed) --"
try outside ansi-c-hex        "\$'a\\x67y' -p hello"
try outside embedded-cmdsubst 'a$(printf g)y -p hello'
echo
echo "### done ###"
