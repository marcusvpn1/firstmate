#!/usr/bin/env bash
# Manual end-to-end driver for the agy fail-closed dispatch contract.
# Runs the REAL bin/fm-spawn.sh / bin/fm-bootstrap.sh / bin/fm-harness.sh /
# bin/fm-control-lib.sh against an isolated disposable home + git worktree.
# tmux/agy shims exist only so PATH resolution is hermetic; the refusal paths
# under test never reach a backend or the agy binary.
set -u
WT=/Users/marcusnascimento/.no-mistakes/worktrees/2e94fa377077/01M29CNCCFM9JW3JTJ5RGH3SX7
. "$WT/tests/lib.sh"
ROOT=$WT
SPAWN="$ROOT/bin/fm-spawn.sh"
PINNED_VERSION="1.2.1"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-manual.XXXXXX")
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
agy brief for test

## Firstmate spec
do it
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id" >/dev/null 2>&1
  touch "$home/state/.last-watcher-beat"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/agy" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version) printf '$PINNED_VERSION\n'; exit 0 ;; *) exit 0 ;; esac
SH
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  chmod +x "$fakebin/tmux" "$fakebin/agy"
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id"
}

run_spawn() {  # home proj wt fakebin id [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5; shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$@" 2>&1
}

echo "===== S1: explicit agy dispatch refuses and creates no endpoint/meta ====="
rec=$(make_case explicit); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off "$id" "$proj" agy); rc=$?
echo "exit=$rc"
echo "$out"
echo "-- meta present? --"; [ -e "$home/state/$id.meta" ] && echo "META-CREATED (bad)" || echo "no meta (good)"

echo; echo "===== S2: config/crew-harness=agy refuses ====="
rec=$(make_case config); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
printf 'agy\n' > "$home/config/crew-harness"
out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off "$id" "$proj"); rc=$?
echo "exit=$rc"; echo "$out"; [ -e "$home/state/$id.meta" ] && echo "META-CREATED (bad)" || echo "no meta (good)"

echo; echo "===== S3: agy secondmate refuses ====="
rec=$(make_case secondmate); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
out=$(run_spawn "$home" "$home" "$wt" "$fakebin" "$id" --secondmate "$id" "$home" agy); rc=$?
echo "exit=$rc"; echo "$out"

echo; echo "===== S4: raw launch 'agy ...' escape hatch refuses ====="
rec=$(make_case rawlaunch); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off "$id" "$proj" 'agy -p hello'); rc=$?
echo "exit=$rc"; echo "$out"; [ -e "$home/state/$id.meta" ] && echo "META-CREATED (bad)" || echo "no meta (good)"

echo; echo "===== S5: --backend herdr refuses before endpoint creation ====="
rec=$(make_case herdr); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_PANE_PATH="$wt" PATH="$fakebin:$BASE_PATH" \
  "$SPAWN" --mode no-mistakes --yolo off --backend herdr "$id" "$proj" agy 2>&1); rc=$?
echo "exit=$rc"; echo "$out"; [ -e "$home/state/$id.meta" ] && echo "META-CREATED (bad)" || echo "no meta (good)"

echo; echo "===== S6: bootstrap crew-dispatch.json naming agy is rejected ====="
rec=$(make_case bootstrap); IFS='|' read -r cd home proj wt fakebin id <<EOF
$rec
EOF
cat > "$home/config/crew-dispatch.json" <<'EOF'
{"default":[{"harness":"agy","effort":"high"}]}
EOF
out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_DETECT_ONLY=1 \
  PATH="$fakebin:$BASE_PATH" bash "$ROOT/bin/fm-bootstrap.sh" 2>&1)
echo "$out" | grep -E 'CREW_DISPATCH|unverified' || echo "(no CREW_DISPATCH line)"

echo; echo "===== S7: control plane refuses agy verbs ====="
bash -c '. "$1"; fm_control_harness_supported agy' _ "$ROOT/bin/fm-control-lib.sh"; echo "control_supported exit=$?"
bash -c '. "$1"; fm_control_harness_family agy' _ "$ROOT/bin/fm-control-lib.sh"; echo "control_family exit=$?"

echo; echo "===== S8: detection exact 'agy' only, 'magy' not elevated ====="
fakebin=$(fm_fakebin "$TMP_ROOT/ps-exact")
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=; pid=; prev=
for arg in "$@"; do [ "$prev" = -o ] && field=$arg; [ "$prev" = -p ] && pid=$arg; prev=$arg; done
case "$field:$pid" in
  comm=:4242) printf '/usr/local/bin/agy\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
chmod +x "$fakebin/ps"
echo -n "detect('/usr/local/bin/agy') -> "; unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI FM_OMP_HARNESS; PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh"
fakebin=$(fm_fakebin "$TMP_ROOT/ps-glob")
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=; pid=; prev=
for arg in "$@"; do [ "$prev" = -o ] && field=$arg; [ "$prev" = -p ] && pid=$arg; prev=$arg; done
case "$field:$pid" in
  comm=:4242) printf '/usr/local/bin/magy\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
chmod +x "$fakebin/ps"
echo -n "detect('/usr/local/bin/magy') -> "; PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh"

echo; echo "===== S9: PG4 scrub removes secrets in the launch subshell, parent untouched ====="
STITCH_X_GOOG_API_KEY=k1 STITCH_API_KEY=k2 ANTHROPIC_API_KEY=k3 APIFY_API_KEY=k4 HF_TOKEN=k5 \
GOOGLE_TOKEN=tok MY_SVC_SECRET=sec KEEP_ME=kept \
bash -c '
  . "$1"
  # child process that inherits exactly what agy would inherit, via the real scrub
  ( eval "$(fm_agy_env_scrub_code)"
    for v in STITCH_X_GOOG_API_KEY STITCH_API_KEY ANTHROPIC_API_KEY APIFY_API_KEY HF_TOKEN GOOGLE_TOKEN MY_SVC_SECRET; do
      if [ -n "${!v:-}" ]; then echo "LEAKED:$v=${!v}"; fi
    done
    echo "child KEEP_ME=${KEEP_ME:-<unset>}"
    echo "child-scrub-done" )
  echo "parent STITCH_API_KEY=${STITCH_API_KEY:-<unset>}"
' _ "$ROOT/bin/fm-agy-lib.sh"

echo; echo "===== S10: strict result validation + denied_actions ====="
d=$(mktemp -d "$TMP_ROOT/validate.XXXXXX")
printf '{"conversation_id":"c","status":"SUCCESS","response":"hi","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":1,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":2}}\n' > "$d/ok.json"
printf 'not json\n' > "$d/bad.json"
printf '{"conversation_id":"c","status":"SUCCESS","response":"hi","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":1,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":2},"denied_actions":[{"action":"x"}]}\n' > "$d/denied.json"
for f in ok bad denied; do
  if bash -c '. "$1"; fm_agy_validate_result "$2"' _ "$ROOT/bin/fm-agy-lib.sh" "$d/$f.json" >/dev/null 2>&1; then v=valid; else v=invalid; fi
  if bash -c '. "$1"; fm_agy_result_success "$2"' _ "$ROOT/bin/fm-agy-lib.sh" "$d/$f.json" >/dev/null 2>&1; then s=success; else s=not-success; fi
  echo "$f.json: validation=$v interpretation=$s"
done
rm -rf "$d"
echo; echo "ALL MANUAL SCENARIOS DRIVEN"
