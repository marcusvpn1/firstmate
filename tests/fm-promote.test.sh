#!/usr/bin/env bash
# Behavior tests for bin/fm-promote.sh.
#
# Regression coverage for the spec/plan promotion dead branch: fm-spawn.sh has no
# --spec/--plan flag, so every spec/plan-scaffolded task lands in its meta as
# kind=scout and promote always took the generic scout branch. The spec/plan ship
# instructions (commit-forward convention, NEEDS CLARIFICATION resolution,
# Spec: line) therefore never fired. promote now recovers the real kind from the
# contract marker fm-brief.sh --spec/--plan writes into the brief.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-promote)

# Set up an isolated FM_HOME with state/, data/, a scout-kind meta, and a brief
# carrying the given kind marker (scout|spec|plan). Returns the task id.
seed_task() {
  local id=$1 marker=$2 with_report=${3:-0}
  local home="$TMP_ROOT/$id"
  mkdir -p "$home/state" "$home/data/$id"
  # Real metas always carry more than kind=; the promote path rewrites the file by
  # filtering out the kind= line, so a kind=-only meta would trip set -e on the
  # empty grep -v result. Write a minimal but realistic meta.
  {
    printf 'kind=scout\n'
    printf 'window=w\n'
    printf 'worktree=/tmp/x\n'
  } > "$home/state/$id.meta"
  case "$marker" in
    spec) cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Write a feature spec.

## Firstmate spec
Investigate and write it.

# Setup
This is a SPEC task: the deliverable is a structured feature specification, not a PR.
EOF
      ;;
    plan) cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Write an implementation plan.

## Firstmate spec
Investigate and plan it.

# Setup
This is a PLAN task: the deliverable is a structured implementation plan, not a PR.
EOF
      ;;
    scout) cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Investigate the bug.

## Firstmate spec
Reproduce it.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
EOF
      ;;
  esac
  if [ "$with_report" = 1 ]; then
    printf 'report\n' > "$home/data/$id/report.md"
  fi
  printf '%s\n' "$home"
}

test_spec_brief_promotes_via_spec_branch() {
  local home id out instructions meta_kind
  id="promote-spec-s1"
  home=$(seed_task "$id" spec 1)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off 2>&1)
  instructions="$home/data/$id/ship-instructions.md"
  assert_present "$instructions" "spec promotion did not write ship instructions"
  assert_grep "commit-forward convention" "$instructions" \
    "spec promotion must carry the commit-forward convention ship instruction"
  assert_grep "NEEDS CLARIFICATION" "$instructions" \
    "spec promotion must carry the NEEDS CLARIFICATION resolution ship instruction"
  assert_grep "Spec: docs/specs/<file>.md" "$instructions" \
    "spec promotion must carry the Spec: line ship instruction"
  meta_kind=$(grep '^kind=' "$home/state/$id.meta")
  [ "$meta_kind" = "kind=ship" ] || fail "spec promotion must flip meta kind to ship (got: $meta_kind)"
  pass "fm-promote.sh: spec brief takes the spec promotion branch"
}

test_plan_brief_promotes_via_plan_branch() {
  local home id out instructions meta_kind
  id="promote-plan-p1"
  home=$(seed_task "$id" plan 1)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off 2>&1)
  instructions="$home/data/$id/ship-instructions.md"
  assert_present "$instructions" "plan promotion did not write ship instructions"
  assert_grep "commit-forward convention" "$instructions" \
    "plan promotion must carry the commit-forward convention ship instruction"
  meta_kind=$(grep '^kind=' "$home/state/$id.meta")
  [ "$meta_kind" = "kind=ship" ] || fail "plan promotion must flip meta kind to ship (got: $meta_kind)"
  pass "fm-promote.sh: plan brief takes the plan promotion branch"
}

test_scout_brief_keeps_generic_scout_branch() {
  local home id out instructions meta_kind
  id="promote-scout-g1"
  home=$(seed_task "$id" scout 1)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off 2>&1)
  instructions="$home/data/$id/ship-instructions.md"
  assert_present "$instructions" "scout promotion did not write ship instructions"
  assert_no_grep "This task was promoted from a" "$instructions" \
    "scout promotion must not carry the spec/plan commit-forward instruction"
  assert_grep "If you reproduced a bug" "$instructions" \
    "scout promotion must carry the generic scout ship instruction"
  meta_kind=$(grep '^kind=' "$home/state/$id.meta")
  [ "$meta_kind" = "kind=ship" ] || fail "scout promotion must flip meta kind to ship (got: $meta_kind)"
  pass "fm-promote.sh: scout brief keeps the generic scout promotion branch"
}

test_spec_brief_without_report_fails() {
  local home id out status
  id="promote-spec-noreport-s1"
  home=$(seed_task "$id" spec 0)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off 2>&1); status=$?
  expect_code 1 "$status" "spec promotion without a report must fail"
  assert_contains "$out" "no report at $home/data/$id/report.md" \
    "spec promotion without a report must explain the missing report"
  meta_kind=$(grep '^kind=' "$home/state/$id.meta")
  [ "$meta_kind" = "kind=scout" ] || fail "failed spec promotion must not flip meta kind (got: $meta_kind)"
  pass "fm-promote.sh: spec brief without a report refuses to promote"
}

test_non_promotable_kind_rejected() {
  local home id out status
  id="promote-ship-h1"
  home="$TMP_ROOT/$id"
  mkdir -p "$home/state" "$home/data/$id"
  printf 'kind=ship\nwindow=w\n' > "$home/state/$id.meta"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off 2>&1); status=$?
  expect_code 1 "$status" "promoting a ship task must fail"
  assert_contains "$out" "not a promotable task" \
    "promoting a ship task must name the non-promotable kind"
  pass "fm-promote.sh: a non-promotable kind is rejected"
}

test_spec_brief_promotes_via_spec_branch
test_plan_brief_promotes_via_plan_branch
test_scout_brief_keeps_generic_scout_branch
test_spec_brief_without_report_fails
test_non_promotable_kind_rejected
