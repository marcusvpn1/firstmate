#!/usr/bin/env bash
# Evidence driver for the agy artifact-privacy / cleanup change.
# Drives the REAL bin/fm-agy-lib.sh public interface (no mocks of the code
# under test); the only stub is the `agy` executable the launch template runs.
set -u
ROOT=/Users/marcusnascimento/.no-mistakes/worktrees/2e94fa377077/01M2CNWA2AG4BZCTWWBYGK5WA9
AGY_LIB="$ROOT/bin/fm-agy-lib.sh"
WORK=$(mktemp -d /tmp/fm-agy-evidence.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
echo "work=$WORK"

mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

run_template() {  # <template> <dir> <result>
  local template=$1 dir=$2 result=$3 fakebin brief
  brief="$dir/brief.md"
  printf 'say hello\n' > "$brief"
  mkdir -p "$dir/worktree"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/agy" <<SH
#!/usr/bin/env bash
mode=\$( { stat -c '%a' "$result.tmp" 2>/dev/null || stat -f '%Lp' "$result.tmp"; } )
printf '%s' "\$mode" > "$dir/partial-mode-at-write"
printf '%s\n' "\$mode"
printf '{"status":"SUCCESS"}\n'
SH
  cat > "$fakebin/opinput" <<'SH'
#!/usr/bin/env bash
printf 'encoded-brief\n'
SH
  chmod +x "$fakebin/agy" "$fakebin/opinput"
  template=${template//__WORKTREE__/$dir/worktree}
  template=${template//__BRIEF__/$brief}
  template=${template//__OPINPUT__/opinput}
  template=${template//__AGYRESULT__/$result}
  template=${template//__AGYLOGFILE__/$dir/agy.log}
  template=${template//__MODELFLAG__/}
  template=${template//__EFFORTFLAG__/}
  FM_AGY_PRINT_TIMEOUT=600 PATH="$fakebin:$PATH" bash -c "$template" >/dev/null 2>&1
  echo "rc=$?"
}

echo
echo "=== SCENARIO 1: partial result artifact privacy (fix present) ==="
D1="$WORK/s1"; R1="$D1/result.json"; mkdir -p "$D1"
T1=$(bash -c '. "$1"; fm_agy_launch_template' _ "$AGY_LIB")
echo "template prefix: $(printf '%s' "$T1" | cut -c1-40)..."
echo "partial mode observed by agy while writing: $(run_template "$T1" "$D1" "$R1"; cat "$D1/partial-mode-at-write" 2>/dev/null)"
echo "published final artifact mode: $(mode_of "$R1")"

echo
echo "=== SCENARIO 1-ADVERSARIAL: same template with 'umask 077; ' removed ==="
D1b="$WORK/s1b"; R1b="$D1b/result.json"; mkdir -p "$D1b"
T1b=${T1/umask 077; /}
echo "template starts with umask 077? $(case "$T1b" in 'umask 077; '*) echo yes;; *) echo no;; esac)"
run_template "$T1b" "$D1b" "$R1b" >/dev/null
echo "partial mode observed by agy while writing: $(cat "$D1b/partial-mode-at-write" 2>/dev/null)"
echo "published final artifact mode: $(mode_of "$R1b")"

echo
echo "=== SCENARIO 2: cleanup removes final + partial + log, keeps unrelated ==="
TASK="evidence-cleanup-$$"
DIR=$(bash -c '. "$1"; fm_agy_ensure_result_dir "$2"' _ "$AGY_LIB" "$TASK")
F=$(bash -c '. "$1"; fm_agy_result_file "$2" g1' _ "$AGY_LIB" "$TASK")
printf '{"status":"SUCCESS"}\n' > "$F"
printf 'partial-no-pid\n' > "${F}.tmp"          # exactly what the launch template leaves mid-write
printf 'partial-with-pid\n' > "${F}.tmp.12345"  # publish_result temp
printf 'log\n' > "$DIR/agy-g1.log"
printf 'operator file\n' > "$DIR/unrelated.txt"
echo "before: $(ls "$DIR")"
bash -c '. "$1"; fm_agy_cleanup "$2"' _ "$AGY_LIB" "$TASK"
echo "after:  $(ls "$DIR")"
[ -e "${F}.tmp" ] && echo "FAIL: exact .tmp partial survived" || echo "OK: exact .tmp partial removed"
[ -e "${F}.tmp.12345" ] && echo "FAIL: pid temp survived" || echo "OK: pid temp removed"
[ -e "$F" ] && echo "FAIL: final result survived" || echo "OK: final result removed"
[ -e "$DIR/agy-g1.log" ] && echo "FAIL: log survived" || echo "OK: log removed"
[ -e "$DIR/unrelated.txt" ] && echo "OK: unrelated file preserved" || echo "FAIL: unrelated file deleted"
rm -rf "$DIR"

echo
echo "=== SCENARIO 2-ADVERSARIAL: old glob pattern would miss the exact .tmp ==="
TASK2="evidence-cleanup-old-$$"
DIR2=$(bash -c '. "$1"; fm_agy_ensure_result_dir "$2"' _ "$AGY_LIB" "$TASK2")
F2=$(bash -c '. "$1"; fm_agy_result_file "$2" g1' _ "$AGY_LIB" "$TASK2")
printf 'x\n' > "${F2}.tmp"
rm -f "$DIR2"/result-*.json.tmp.* 2>/dev/null || true   # the pre-fix glob
[ -e "${F2}.tmp" ] && echo "pre-fix glob leaves the exact .tmp partial in place (regression reproduced)" || echo "unexpected: pre-fix glob removed it"
rm -rf "$DIR2"
