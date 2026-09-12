#!/usr/bin/env bash
# Regression proof: the shipped raw-launch guard must refuse the quoted/escaped
# forms that the parent guard (d24196a) let through. Extracts the REAL
# raw_command_invokes_agy function body from each revision and calls it with the
# same command strings, so this fails before the fix and passes after.
set -u
WT=/Users/marcusnascimento/.no-mistakes/worktrees/2e94fa377077/01M29CNCCFM9JW3JTJ5RGH3SX7
cd "$WT" || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-regr.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

extract() {  # rev outfile
  local rev=$1 out=$2
  git show "$rev:bin/fm-spawn.sh" > "$TMP/src.sh"
  awk '/^raw_command_invokes_agy\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$TMP/src.sh" > "$out"
  [ -s "$out" ] || { echo "could not extract raw_command_invokes_agy from $rev" >&2; exit 1; }
}

probe() {  # funcfile cmd
  local func=$1 cmd=$2
  bash -c '. "$1"; if raw_command_invokes_agy "$2"; then echo REFUSE; else echo ALLOW; fi' _ "$func" "$cmd"
}

extract d24196a "$TMP/parent.sh"   # guard with metachar-normalize only (regressed)
extract HEAD      "$TMP/head.sh"   # guard with quote/backslash strip restored

cases=(
  'a"g"y -p hello'
  "a'g'y -p hello"
  'a\gy -p hello'
  "\$(printf 'a''g''y') -p hello"
  '(agy -p hello)'
  'A=agy; $A -p hello'
  '${AGY:-agy} -p hello'
  'agy -p hello'
  'env FOO=bar agy -p hello'
)
printf '%-34s %-9s %-9s %s\n' 'command' 'parent' 'HEAD' 'verdict'
fail=0
for c in "${cases[@]}"; do
  p=$(probe "$TMP/parent.sh" "$c")
  h=$(probe "$TMP/head.sh" "$c")
  v=ok
  if [ "$h" != REFUSE ]; then v=FAIL; fail=1; fi
  [ "$p" = REFUSE ] && v="$v(parent-also-refused)"
  printf '%-34s %-9s %-9s %s\n' "$c" "$p" "$h" "$v"
done
[ "$fail" -eq 0 ] && echo "RESULT: HEAD refuses every statically detectable form (regression restored)" || echo "RESULT: FAIL"
exit "$fail"
