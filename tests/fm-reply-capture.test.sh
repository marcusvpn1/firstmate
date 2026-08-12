#!/usr/bin/env bash
# Corr-tagged voice reply capture (bin/fm-reply-capture-lib.sh,
# bin/fm-reply-capture-claude.sh).
#
# Reproduces the Claude Stop-hook path end to end: a fake JSONL transcript on
# disk, a Stop payload naming it on stdin, and the real repo hook script
# invoked with scope overrides pointed at a disposable fixture directory (so
# fm_primary_scope_matches evaluates against the fixture while every sourced
# sibling script still resolves from the real repo bin/ - no need to copy the
# whole bin/ tree per fixture).
#
# Coverage:
#   1. A corr-tagged human turn writes a reply record: right corr id, right
#      request_summary, and a raw multi-block reply body concatenated in order
#   2. A turn with no corr token writes nothing
#   3. A system-injected (isMeta) pseudo-turn can never become the anchor, and
#      a subagent (isSidechain) assistant entry never leaks into the reply
#   4. A tool_result entry (also type=="user") is never mistaken for the
#      anchor human turn
#   5. Record directory/file permissions match the pending-replies convention
#   6. A crew/scout child worktree is scoped out (same predicate as
#      fm-turnend-guard.sh; exhaustive predicate coverage lives in that suite)
#   7. Missing jq and an absent/unreadable transcript_path both fail open
#   8. fm_reply_capture_write itself: same-corr overwrite, invalid-corr refusal
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-reply-capture-lib.sh
. "$ROOT/bin/fm-reply-capture-lib.sh"

HOOK="$ROOT/bin/fm-reply-capture-claude.sh"
TMP_ROOT=$(fm_test_tmproot fm-reply-capture)

# --- fixtures ---------------------------------------------------------------

# A primary-shaped directory: real git repo (git-dir == git-common-dir),
# AGENTS.md, bin/, state/ - everything fm_primary_scope_matches requires. The
# hook itself still runs from $ROOT/bin, so this never needs real sibling
# scripts copied into it.
make_primary_dir() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree of a base primary dir - the shape fm-spawn.sh
# hands crew/scout tasks. git-dir != git-common-dir and no secondmate marker,
# so fm_primary_scope_matches must exempt it exactly like fm-turnend-guard.sh.
make_child_worktree_dir() {
  local base=$1 dir="$TMP_ROOT/$2-$RANDOM"
  git -C "$base" worktree add --quiet -b "fm/reply-capture-test-$RANDOM" "$dir"
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

run_hook() {  # <root-dir> <transcript-path>
  local root=$1 transcript=$2 payload
  payload=$(jq -n --arg tp "$transcript" '{transcript_path: $tp, session_id: "test", stop_hook_active: false}')
  printf '%s' "$payload" \
    | FM_ROOT_OVERRIDE="$root" FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" bash "$HOOK"
}

reply_path() {  # <root-dir> <corr>
  fm_reply_capture_path "$1/state" "$2"
}

file_mode() {  # <path> -> octal mode, no leading zeros
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

# --- tests --------------------------------------------------------------

test_corr_tagged_turn_writes_reply_record() {
  local dir transcript corr=abcdef0123456789 rec body
  dir=$(make_primary_dir corr-write)
  transcript="$dir/t.jsonl"
  cat > "$transcript" <<EOF
{"type":"user","isSidechain":false,"isMeta":false,"message":{"content":"status please corr=$corr"}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"Captain, all green."}]}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","isSidechain":false,"message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":" No blockers."}]}}
EOF
  run_hook "$dir" "$transcript" >/dev/null 2>&1
  rec=$(reply_path "$dir" "$corr")
  assert_present "$rec" "reply record must be written for a corr-tagged turn"
  assert_grep "schema=fm-voice-reply.v1" "$rec" "record must carry the schema line"
  assert_grep "corr_id=$corr" "$rec" "record must carry the corr id"
  assert_grep "request_summary=status please corr=$corr" "$rec" "record must carry a sanitized summary of the tagged input"
  assert_grep "reply=" "$rec" "record must carry the reply sentinel"
  body=$(cat "$rec")
  assert_contains "$body" "Captain, all green." "reply body must include the first text block"
  assert_contains "$body" " No blockers." "reply body must include the text block after the tool round-trip"
  pass "corr-tagged turn writes a reply record with header + raw multi-block body"
}

test_no_corr_writes_nothing() {
  local dir transcript
  dir=$(make_primary_dir no-corr)
  transcript="$dir/t.jsonl"
  cat > "$transcript" <<'EOF'
{"type":"user","isSidechain":false,"isMeta":false,"message":{"content":"just an ordinary captain message"}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"Aye captain."}]}}
EOF
  run_hook "$dir" "$transcript" >/dev/null 2>&1
  assert_absent "$dir/state/voice-replies" "no corr token must never create the voice-replies directory"
  pass "a turn with no corr token writes nothing"
}

test_meta_and_sidechain_entries_excluded() {
  local dir transcript real_corr=1111111111111111 meta_corr=2222222222222222 rec body
  dir=$(make_primary_dir meta-sidechain)
  transcript="$dir/t.jsonl"
  cat > "$transcript" <<EOF
{"type":"user","isSidechain":false,"isMeta":false,"message":{"content":"corr=$real_corr real captain turn"}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"First part of reply."}]}}
{"type":"user","isSidechain":false,"isMeta":true,"message":{"content":"corr=$meta_corr system-injected, must never anchor"}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"Second part of reply."}]}}
{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"SUBAGENT LEAK"}]}}
EOF
  run_hook "$dir" "$transcript" >/dev/null 2>&1
  rec=$(reply_path "$dir" "$real_corr")
  assert_present "$rec" "the real (non-meta) turn's corr must get a reply record"
  body=$(cat "$rec")
  assert_contains "$body" "First part of reply." "reply body must include text before the meta injection"
  assert_contains "$body" "Second part of reply." "reply body must include text after the meta injection (same turn continues)"
  assert_not_contains "$body" "SUBAGENT LEAK" "a sidechain (subagent) assistant entry must never leak into the reply"
  assert_absent "$(reply_path "$dir" "$meta_corr")" "an isMeta system-injected turn must never become the anchor"
  pass "isMeta system turns cannot anchor and isSidechain subagent text never leaks into the reply"
}

test_tool_result_not_mistaken_for_human_turn() {
  local dir transcript corr=9999888877776666 rec body
  dir=$(make_primary_dir tool-result)
  transcript="$dir/t.jsonl"
  cat > "$transcript" <<EOF
{"type":"user","isSidechain":false,"isMeta":false,"message":{"content":"corr=$corr real question"}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","isSidechain":false,"message":{"content":[{"type":"tool_result","content":"tool output, not a human turn"}]}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"Final answer."}]}}
EOF
  run_hook "$dir" "$transcript" >/dev/null 2>&1
  rec=$(reply_path "$dir" "$corr")
  assert_present "$rec" "reply record must be written despite an intervening tool_result user entry"
  body=$(cat "$rec")
  assert_contains "$body" "Final answer." "reply body must include the text after the tool round-trip"
  assert_not_contains "$body" "tool output, not a human turn" "a tool_result entry's content must never appear as reply text"
  pass "a tool_result entry (type==user, no text block) is never mistaken for the anchor human turn"
}

test_record_permissions_match_pending_reply_convention() {
  local dir transcript corr=aaaa1111bbbb2222 rec
  dir=$(make_primary_dir perms)
  transcript="$dir/t.jsonl"
  cat > "$transcript" <<EOF
{"type":"user","isSidechain":false,"isMeta":false,"message":{"content":"corr=$corr"}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"ok"}]}}
EOF
  run_hook "$dir" "$transcript" >/dev/null 2>&1
  rec=$(reply_path "$dir" "$corr")
  assert_present "$rec" "reply record must exist for permission check"
  [ "$(file_mode "$(dirname "$rec")")" = 700 ] || fail "voice-replies dir must be mode 700, got $(file_mode "$(dirname "$rec")")"
  [ "$(file_mode "$rec")" = 600 ] || fail "reply record must be mode 600, got $(file_mode "$rec")"
  pass "record directory and file permissions match the pending-replies convention"
}

test_child_worktree_is_scoped_out() {
  local base child transcript corr=deadbeefdeadbeef
  base=$(make_primary_dir scope-base)
  child=$(make_child_worktree_dir "$base" scope-child)
  transcript="$base/t.jsonl"
  cat > "$transcript" <<EOF
{"type":"user","isSidechain":false,"isMeta":false,"message":{"content":"corr=$corr from a child worktree"}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"should never be captured"}]}}
EOF
  run_hook "$child" "$transcript" >/dev/null 2>&1
  assert_absent "$(reply_path "$child" "$corr")" "a crew/scout child worktree must never capture a reply"
  pass "a child crew/scout worktree is scoped out, matching fm-turnend-guard.sh"
}

test_missing_jq_fails_open() {
  local dir transcript fakebin t code corr=0000111122223333
  dir=$(make_primary_dir no-jq)
  transcript="$dir/t.jsonl"
  cat > "$transcript" <<EOF
{"type":"user","isSidechain":false,"isMeta":false,"message":{"content":"corr=$corr"}}
{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"ok"}]}}
EOF
  fakebin=$(fm_fakebin "$dir")
  for t in bash sh dirname cat mkdir chmod mv grep sed cut basename git tr head tail awk; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$fakebin/$t"
  done
  printf '%s' "$(jq -n --arg tp "$transcript" '{transcript_path: $tp}')" \
    | FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" PATH="$fakebin" bash "$HOOK"
  code=$?
  expect_code 0 "$code" "hook must exit 0 even without jq"
  assert_absent "$dir/state/voice-replies" "missing jq must never create a partial record"
  pass "missing jq fails open silently"
}

test_missing_transcript_path_fails_open() {
  local dir code
  dir=$(make_primary_dir no-transcript)
  printf '%s' '{"session_id":"x","stop_hook_active":false}' \
    | FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash "$HOOK"
  code=$?
  expect_code 0 "$code" "hook must exit 0 when transcript_path is absent"
  assert_absent "$dir/state/voice-replies" "an absent transcript_path must never create a record"
  pass "an absent transcript_path fails open silently"
}

test_write_overwrites_same_corr() {
  local state corr=abcabcabcabcabca rec
  state="$TMP_ROOT/overwrite-$RANDOM/state"
  mkdir -p "$state"
  fm_reply_capture_write "$state" "$corr" "first" "first reply" || fail "first write failed"
  fm_reply_capture_write "$state" "$corr" "second" "second reply" || fail "second write failed"
  rec=$(fm_reply_capture_path "$state" "$corr")
  assert_grep "request_summary=second" "$rec" "second write must replace the header"
  assert_contains "$(cat "$rec")" "second reply" "second write must replace the body"
  assert_not_contains "$(cat "$rec")" "first reply" "a stale body must never survive a same-corr overwrite"
  pass "fm_reply_capture_write overwrites an existing record for the same corr"
}

test_write_refuses_invalid_corr() {
  local state
  state="$TMP_ROOT/invalid-corr-$RANDOM/state"
  mkdir -p "$state"
  if fm_reply_capture_write "$state" "not-hex-16" "s" "r" 2>/dev/null; then
    fail "fm_reply_capture_write must refuse a non-16-lowercase-hex corr id"
  fi
  assert_absent "$state/voice-replies" "an invalid corr id must never create the voice-replies directory"
  pass "fm_reply_capture_write refuses an invalid corr id"
}

# --- run ----------------------------------------------------------------

test_corr_tagged_turn_writes_reply_record
test_no_corr_writes_nothing
test_meta_and_sidechain_entries_excluded
test_tool_result_not_mistaken_for_human_turn
test_record_permissions_match_pending_reply_convention
test_child_worktree_is_scoped_out
test_missing_jq_fails_open
test_missing_transcript_path_fails_open
test_write_overwrites_same_corr
test_write_refuses_invalid_corr

printf 'ok - all reply-capture tests passed\n'
