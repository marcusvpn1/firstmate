#!/usr/bin/env bash
# fm-reply-capture-claude.sh - Claude Code Stop-hook adapter for
# bin/fm-reply-capture-lib.sh (see that file's header for the record format
# and corr-token contract).
#
# Claude Code's Stop hook payload carries transcript_path, a JSONL transcript
# of this session. This adapter reads it once per Stop event to find the most
# recent genuine human-authored turn - isSidechain false (excludes a subagent
# Task-tool transcript appended to the same file) and isMeta false (excludes a
# synthetic system-injected turn) - and checks its text for a corr=<16hex>
# token, using the same token contract as bin/fm-pending-reply-lib.sh. When
# found, it concatenates every text block from every non-sidechain assistant
# entry that follows - the conversational reply firstmate just gave, including
# any narration text emitted between tool calls in the same turn - and writes
# it via fm_reply_capture_write.
#
# Scope: primary firstmate homes only (main or a genuine secondmate home),
# using the same fm_primary_scope_matches predicate as bin/fm-turnend-guard.sh.
# This file ships tracked into every worktree of this repo, including
# crewmate/scout task worktrees, and must stay a silent no-op in those.
#
# Always exits 0: this is purely observational and must never block a Stop
# event or surface as a visible failure. Missing jq, an unreadable or absent
# transcript_path, no corr-tagged turn this Stop, or a scope mismatch are all
# ordinary no-ops, not errors.
#
# Compatibility: Claude only. Codex, OpenCode, Pi, and Grok's existing
# turn-end hook payloads carry no verified equivalent of transcript_path in
# this repo, and Kimi's Stop hook payload carries no conversation content at
# all (docs/turnend-guard.md). Extending reply capture to another harness
# needs that harness's own verified transcript-access contract; nothing here
# assumes one exists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r 'if type == "object" then (.transcript_path // empty) else empty end' 2>/dev/null) || exit 0
[ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0

# One pass over the transcript: locate the last genuine human turn and, if one
# exists, everything the assistant said after it. jq -s slurps the JSONL file
# into one array; to_entries preserves position so the assistant slice below
# can start right after the matched turn.
TURN_JSON=$(jq -s '
  (map(select(.isSidechain != true))) as $lines
  | ($lines | to_entries
     | map(select(
         .value.type == "user"
         and ((.value.isMeta // false) == false)
         and (
           (.value.message.content | type) == "string"
           or ([.value.message.content[]? | select(.type == "text")] | length) > 0
         )
       ))
     | last) as $anchor
  | if $anchor == null then null
    else
      ($anchor.value.message.content // "") as $c
      | (if ($c | type) == "string" then $c
         else ([$c[]? | select(.type == "text") | (.text // "")] | join("\n"))
         end) as $utext
      | ($lines[($anchor.key + 1):]
         | map(select(.type == "assistant"))
         | map(.message.content[]? | select(.type == "text") | (.text // ""))
         | join("\n")) as $reply
      | {utext: $utext, reply: $reply}
    end
' "$TRANSCRIPT" 2>/dev/null) || exit 0
[ -n "$TURN_JSON" ] && [ "$TURN_JSON" != "null" ] || exit 0

UTEXT=$(printf '%s' "$TURN_JSON" | jq -r '.utext // empty' 2>/dev/null) || exit 0
[ -n "$UTEXT" ] || exit 0

# shellcheck source=bin/fm-reply-capture-lib.sh
. "$SCRIPT_DIR/fm-reply-capture-lib.sh"

CORR=$(fm_reply_capture_extract_corr "$UTEXT")
[ -n "$CORR" ] || exit 0

REPLY=$(printf '%s' "$TURN_JSON" | jq -r '.reply // ""' 2>/dev/null) || exit 0
SUMMARY=$(fm_pending_reply_summarize "$UTEXT")

fm_reply_capture_write "$STATE" "$CORR" "$SUMMARY" "$REPLY" 2>/dev/null
exit 0
