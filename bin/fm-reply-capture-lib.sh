#!/usr/bin/env bash
# fm-reply-capture-lib.sh - write firstmate's own conversational reply to a
# corr-tagged file, for an external caller that cannot read firstmate's
# terminal directly (voice-p2 architecture report section 3.3, Option B).
#
# When an external caller delivers firstmate a message carrying a
# corr=<16hex> token (the same token contract bin/fm-pending-reply-lib.sh
# already uses for parent-owned secondmate replies - see that file's header),
# a harness-specific turn-end adapter extracts firstmate's reply text for that
# turn and calls fm_reply_capture_write here to record it. This library owns
# only the corr-token contract reuse and the atomic record write; it has no
# opinion on how a caller delivers the tagged message or which harness turn-end
# hook invokes it.
#
# Record location (this home's state dir):
#   state/voice-replies/<corr_id>
# Each record is a small key=value header followed by the literal `reply=`
# sentinel line, then the raw (possibly multi-line) reply text verbatim to end
# of file. The header alone cannot carry free-form prose safely (embedded
# newlines would corrupt line-based key=value parsing), so the reply body is
# never encoded into a header value - it is written exactly as firstmate
# produced it.
#   schema=fm-voice-reply.v1
#   corr_id=            same 16-lowercase-hex token contract as pending-replies
#   captured_epoch=     when this record was written
#   request_summary=    short sanitized summary of the tagged input (reuses
#                        fm_pending_reply_summarize)
#   reply=               sentinel; everything after this line to EOF is the body
#
# A record is overwritten in place if the same corr_id is captured twice; there
# is no versioning or recovery/escalation dance here because, unlike a
# secondmate reply, the write happens synchronously inside the same turn that
# produced the text - there is nothing to await or recover.
#
# No automatic pruning: a consumed or abandoned record is left in place. This
# mirrors keeping the mechanism to exactly "one corr-tagged request, one reply
# file" rather than growing a queue or expiry system; a caller that wants
# cleanup removes its own consumed files.
#
# No side effects on source. set -u safe.

_FM_REPLY_CAPTURE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_REPLY_CAPTURE_LIB_DIR="."
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$_FM_REPLY_CAPTURE_LIB_DIR/fm-pending-reply-lib.sh"

FM_REPLY_CAPTURE_SCHEMA='fm-voice-reply.v1'

fm_reply_capture_dir() {  # <state-dir>
  printf '%s/voice-replies' "$1"
}

fm_reply_capture_path() {  # <state-dir> <corr_id>
  printf '%s/%s' "$(fm_reply_capture_dir "$1")" "$2"
}

# Extract the corr=<16hex> token from free text, or empty. Delegates to
# bin/fm-pending-reply-lib.sh so the token format is defined exactly once.
fm_reply_capture_extract_corr() {  # <text>
  fm_pending_reply_extract_corr "$1"
}

# Atomically write one reply record for <corr_id>. Overwrites any existing
# record for the same corr_id.
fm_reply_capture_write() {  # <state-dir> <corr_id> <request_summary> <reply_text>
  local state=$1 corr=$2 summary=$3 reply=$4 dir rec tmp
  [ -n "$state" ] || return 2
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || return 2
  dir=$(fm_reply_capture_dir "$state")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  rec=$(fm_reply_capture_path "$state" "$corr")
  tmp="$dir/.${corr}.tmp.$$"
  {
    printf 'schema=%s\n' "$FM_REPLY_CAPTURE_SCHEMA"
    printf 'corr_id=%s\n' "$corr"
    printf 'captured_epoch=%s\n' "$(fm_pending_reply_now)"
    printf 'request_summary=%s\n' "$summary"
    printf 'reply=\n'
    printf '%s' "$reply"
  } > "$tmp" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec"
}
