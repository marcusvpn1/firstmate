#!/usr/bin/env bash
# Voice-mode progress hook: marker bytes, marked-message round trip, near-miss
# rejection, and the terminal-free side-channel contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-voice-progress.sh"
# shellcheck source=/dev/null
. "$OWNER"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

# Create temp homes with raw mktemp and register them for the shared cleanup.
# fm_test_tmproot's first call installs an EXIT trap that, invoked inside a
# command-substitution subshell, deletes the dir on subshell exit
# (tests/wake-helpers.sh), so a call that must survive for later writes cannot
# go through command substitution.
make_home() {  # <prefix> <result-var>
  local prefix=${1-} result_var=${2-} dir
  [ -n "$result_var" ] || return 2
  dir=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  FM_TEST_CLEANUP_DIRS+=("$dir")
  printf -v "$result_var" '%s' "$dir"
}

mark_cli() {
  "$OWNER" mark "$1" "$2" 2>/dev/null
}

parse_cli() {
  printf '%s' "$1" | "$OWNER" parse 2>/dev/null
}

emit_cli() {  # <fm-home> <turn-id> <phase>
  FM_HOME="$1" "$OWNER" emit "$2" "$3" 2>/dev/null
}

test_marker_bytes() {
  local prefix_hex
  prefix_hex=$(printf '%s' "$FM_VOICE_PREFIX" | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a346495253544d4154455f564f4943453a20 ] \
    || fail "voice prefix lost the U+2063 FIRSTMATE_VOICE: bytes: $prefix_hex"
  pass "voice progress: the marker retains the landed invisible-separator byte and its distinct label"
}

test_mark_parse_roundtrip() {
  local marked turn utterance
  fm_voice_progress_mark "turn-1" "what's happening with Mercanta?" marked \
    || fail "could not construct a marked fixture"
  fm_voice_progress_parse "$marked" turn utterance \
    || fail "could not parse a marked fixture"
  [ "$turn" = "turn-1" ] || fail "marked fixture turn became $turn"
  [ "$utterance" = "what's happening with Mercanta?" ] \
    || fail "marked fixture utterance changed"
  [ "$(parse_cli "$marked")" = "$(printf 'turn=turn-1\nutterance=what'"'"'s happening with Mercanta?')" ] \
    || fail "cross-language CLI lost the marked round trip"
  pass "voice progress: a marked turn round-trips its turn id and utterance"
}

test_parse_rejects_non_voice() {
  local marker fixture parsed_turn parsed_utterance
  marker=$FM_VOICE_MARK
  while IFS= read -r fixture || [ -n "$fixture" ]; do
    [ -n "$fixture" ] || continue
    ! fm_voice_progress_parse "$fixture" parsed_turn parsed_utterance \
      || fail "genuine near miss parsed as a voice turn ($parsed_turn / $parsed_utterance): $fixture"
    [ -z "$(parse_cli "$fixture" || true)" ] \
      || fail "CLI parsed a genuine near miss: $fixture"
  done <<EOF
hello captain
FIRSTMATE_VOICE: turn-1 hello
$marker arbitrary captain text
Captain quote: ${FM_VOICE_PREFIX}turn-1 hello
${FM_VOICE_PREFIX}
${FM_VOICE_PREFIX} hello
${FM_VOICE_PREFIX}turn-1
EOF
  pass "voice progress: ordinary and near-miss messages are never treated as voice turns"
}

test_emit_side_channel_is_terminal_free() {
  local home stdout_log log
  make_home fm-voice-progress home
  stdout_log="$home/stdout"
  emit_cli "$home" "turn-1" "found the task" > "$stdout_log"
  [ ! -s "$stdout_log" ] || fail "emit wrote to stdout, not only the side channel"
  log="$home/state/voice-progress.jsonl"
  [ -f "$log" ] || fail "emit did not create the side-channel file"
  assert_grep '"schema":"fm-voice-progress.v1"' "$log" "side channel lost its schema"
  assert_grep '"turn":"turn-1"' "$log" "side channel lost the turn id"
  assert_grep '"text":"found the task"' "$log" "side channel lost the phase text"
  pass "voice progress: emit writes only to the side channel, never the terminal"
}

test_emit_appends_and_escapes() {
  local home log line_count
  make_home fm-voice-progress-append home
  emit_cli "$home" "turn-1" 'he said "hi" \ backslash'
  emit_cli "$home" "turn-1" "second phase"
  log="$home/state/voice-progress.jsonl"
  line_count=$(wc -l < "$log" | tr -d ' ')
  [ "$line_count" = 2 ] || fail "emit did not append: $line_count lines"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; [json.loads(l) for l in open('$log')]" \
      || fail "emit produced a non-JSON side channel line"
  fi
  pass "voice progress: emit appends one JSON line per event and escapes text"
}

test_emit_rejects_invalid_input() {
  local home output long_id
  make_home fm-voice-progress-invalid home
  long_id=$(printf 'a%.0s' $(seq 1 65))
  ! emit_cli "$home" 'bad id!' 'x' || fail "turn id with spaces was accepted"
  ! emit_cli "$home" '.hidden' 'x' || fail "dot-leading turn id was accepted"
  ! emit_cli "$home" "$long_id" 'x' || fail "over-long turn id was accepted"
  ! emit_cli "$home" 'turn-1' '' || fail "empty phase was accepted"
  output=$(mark_cli 'bad id!' 'x') && fail "mark accepted an invalid turn id"
  [ -z "$output" ] || fail "mark printed data for an invalid turn id"
  output=$(mark_cli 'turn-1' '') && fail "mark accepted an empty utterance"
  [ -z "$output" ] || fail "mark printed data for an empty utterance"
  pass "voice progress: emit and mark reject invalid turn ids and empty bodies"
}

test_marker_bytes
test_mark_parse_roundtrip
test_parse_rejects_non_voice
test_emit_side_channel_is_terminal_free
test_emit_appends_and_escapes
test_emit_rejects_invalid_input
