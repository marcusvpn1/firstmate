#!/usr/bin/env bash
# fm-voice-progress.sh - voice-mode-only progress/event hook for the silent
# pre-first-token phase of a firstmate-voice bridge turn.
#
# This file is both a source-safe shell library and the cross-language CLI the
# firstmate-voice bridge (Python) and the firstmate agent use. It is the single
# owner of the voice-turn marker, the marked-message parse, and the progress
# side-channel format.
#
# Voice-turn marker:
#   U+2063 FIRSTMATE_VOICE: <turn-id> <utterance>
#
# The firstmate-voice bridge prefixes every turn it originates with the marker
# so a bridge turn is distinguishable from an ordinary captain-typed message.
# U+2063 INVISIBLE SEPARATOR has no normal keyboard keystroke and survives
# terminal transport as UTF-8 text, so an ordinary typed message cannot carry
# the marker by accident. The separator byte is the same invisible marker the
# operational-input protocol owns in bin/fm-operational-input.sh; the distinct
# FIRSTMATE_VOICE label keeps the two protocols apart.
#
# Progress side channel (never written to the terminal, so an ordinary turn is
# never changed even if the hook is misused):
#   <FM_HOME>/state/voice-progress.jsonl, one JSON object per line:
#   {"schema":"fm-voice-progress.v1","ts":<epoch-seconds>,"turn":"<turn-id>","text":"<phase>"}
# The bridge tails this file and narrates events whose turn matches its active
# turn.
#
# CLI:
#   fm-voice-progress.sh mark <turn-id> <utterance>  # marked message on stdout
#   fm-voice-progress.sh parse                       # message on stdin -> turn + utterance
#   fm-voice-progress.sh emit <turn-id> <phase>      # append one progress event
#   fm-voice-progress.sh --help
#
# All successful data commands print exactly the documented value and no
# diagnostics. parse exits 1 silently when the input is not a voice-marked
# message. Invalid use exits 2. Bash 3.2 compatible.
set -u

FM_VOICE_MARK=$'\xE2\x81\xA3'
FM_VOICE_PREFIX="${FM_VOICE_MARK}FIRSTMATE_VOICE: "
FM_VOICE_SCHEMA='fm-voice-progress.v1'
FM_VOICE_MAX_TURN_ID=64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
VOICE_PROGRESS_LOG="$STATE/voice-progress.jsonl"

fm_voice_turn_id_valid() {  # <turn-id>
  local id=${1-}
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le "$FM_VOICE_MAX_TURN_ID" ] || return 1
  return 0
}

fm_voice_progress_mark() {  # <turn-id> <utterance> <result-var>
  local id=${1-} utterance=${2-} result_var=${3-}
  [ -n "$result_var" ] || return 2
  fm_voice_turn_id_valid "$id" || return 2
  [ -n "$utterance" ] || return 2
  printf -v "$result_var" '%s%s %s' "$FM_VOICE_PREFIX" "$id" "$utterance"
}

fm_voice_progress_parse() {  # <message> <turn-var> <utterance-var>
  local message=${1-} turn_var=${2-} utterance_var=${3-} parsed_remainder parsed_turn_id parsed_utterance
  [ -n "$turn_var" ] && [ -n "$utterance_var" ] || return 2
  parsed_remainder=${message#"$FM_VOICE_PREFIX"}
  [ "$parsed_remainder" != "$message" ] || return 1
  parsed_turn_id=${parsed_remainder%% *}
  fm_voice_turn_id_valid "$parsed_turn_id" || return 1
  parsed_utterance=${parsed_remainder#* }
  [ "$parsed_utterance" != "$parsed_remainder" ] && [ -n "$parsed_utterance" ] || return 1
  printf -v "$turn_var" '%s' "$parsed_turn_id"
  printf -v "$utterance_var" '%s' "$parsed_utterance"
  return 0
}

fm_voice_json_escape() {  # <text> <result-var>
  local text=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  text=${text//$'\n'/ }
  text=${text//$'\t'/ }
  text=${text//$'\r'/ }
  # JSON requires every C0 control byte to be escaped or absent; \n \t \r are
  # normalized above, so strip the remaining unescaped C0 range here.
  text=$(printf '%s' "$text" | LC_ALL=C tr -d '\001-\010\013\014\016-\037')
  printf -v "$result_var" '%s' "$text"
}

fm_voice_progress_emit() {  # <turn-id> <phase>
  local id=${1-} phase=${2-} escaped ts
  fm_voice_turn_id_valid "$id" || return 2
  [ -n "$phase" ] || return 2
  fm_voice_json_escape "$phase" escaped
  mkdir -p "$STATE" 2>/dev/null || return 2
  ts=$(date +%s)
  printf '{"schema":"%s","ts":%s,"turn":"%s","text":"%s"}\n' \
    "$FM_VOICE_SCHEMA" "$ts" "$id" "$escaped" >> "$VOICE_PROGRESS_LOG" || return 2
  return 0
}

fm_voice_read_stdin() {  # <result-var>
  local result_var=${1-} value
  [ -n "$result_var" ] || return 2
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

fm_voice_progress_usage() {
  cat <<'EOF'
Usage:
  bin/fm-voice-progress.sh mark <turn-id> <utterance>  # marked message on stdout
  bin/fm-voice-progress.sh parse                       # message on stdin -> turn + utterance
  bin/fm-voice-progress.sh emit <turn-id> <phase>      # append one progress event

mark is how the firstmate-voice bridge constructs a marked turn without
duplicating the marker bytes. parse detects a marked message and prints
"turn=<id>" then "utterance=<text>"; it exits 1 silently for a non-marked
message. emit appends one side-channel event to <FM_HOME>/state/voice-progress.jsonl
and never writes to the terminal.
EOF
}

fm_voice_progress_main() {
  local command=${1-} input turn utterance output
  case "$command" in
    -h|--help|help)
      fm_voice_progress_usage
      ;;
    mark)
      [ "$#" -eq 3 ] || return 2
      fm_voice_progress_mark "$2" "$3" output || return 2
      printf '%s' "$output"
      ;;
    parse)
      [ "$#" -eq 1 ] || return 2
      fm_voice_read_stdin input || return 2
      fm_voice_progress_parse "$input" turn utterance || return 1
      printf 'turn=%s\nutterance=%s\n' "$turn" "$utterance"
      ;;
    emit)
      [ "$#" -eq 3 ] || return 2
      fm_voice_progress_emit "$2" "$3" || return 2
      ;;
    *)
      fm_voice_progress_usage >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_voice_progress_main "$@"
  exit $?
fi
