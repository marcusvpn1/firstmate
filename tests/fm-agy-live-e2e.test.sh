#!/usr/bin/env bash
# Live guard for the real, installed Agy CLI (bin/fm-test-run.sh's
# live-harness-optin family). Opt-in: it submits a real prompt and spends model
# tokens. Agy is refused by normal dispatch (bin/fm-spawn.sh), so this guard is
# the ONLY sanctioned way to execute the real binary: it invokes agy directly
# with the documented `--output-format json` + `-p=` one-shot print shape (the
# same shape bin/fm-agy-lib.sh's launch template documents) and proves the real
# binary publishes a valid SUCCESS result under the observed schema.
#
# The version pin is a hard gate: when agy IS installed but its version differs
# from the pinned one, this guard fails loudly naming both versions rather than
# silently skipping, so an auto-updated agy with a drifted CLI surface can never
# pass as "verified".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# Opt-in: a real run submits a prompt and spends model tokens.
fm_live_gate opt-in FM_AGY_LIVE agy

# shellcheck source=bin/fm-agy-lib.sh
. "$ROOT/bin/fm-agy-lib.sh"

AGY_BIN=$(command -v agy 2>/dev/null || true)
[ -x "${AGY_BIN:-}" ] || fail "FM_AGY_LIVE=1 but no real agy executable is installed"

VERSION_OUT=$(fm_agy_version 2>&1 || true)
echo "BOOTSTRAP_INFO: live agy version: ${VERSION_OUT:-unknown} (pinned ${FM_AGY_PINNED_VERSION:-1.2.1})"
if ! fm_agy_version_pinned; then
  fail "agy installed version ${VERSION_OUT:-unknown} does not match pinned ${FM_AGY_PINNED_VERSION:-1.2.1}; refusing"
fi

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-live.XXXXXX") || fail "could not create the isolated Agy lab"
cleanup() { rm -rf -- "$LAB"; }
trap cleanup EXIT

RESULT="$LAB/result.json"
LOG="$LAB/agy.log"
MODEL_FLAG=
[ -n "${FM_AGY_LIVE_MODEL:-}" ] && MODEL_FLAG="--model ${FM_AGY_LIVE_MODEL}"

# The exact one-shot print shape fm-spawn.sh places: flags first, then the
# prompt attached to -p with `=`, stdout redirected to the result artifact.
# shellcheck disable=SC2086 # MODEL_FLAG is a deliberate single flag string
if ! "$AGY_BIN" --output-format json $MODEL_FLAG --print-timeout 120s --log-file "$LOG" \
    -p='Reply with exactly the word: hello' > "$RESULT" 2>"$LAB/stderr.txt"; then
  fail "real agy print run exited nonzero: $(head -c 400 "$LAB/stderr.txt" 2>/dev/null)"
fi

[ -s "$RESULT" ] || fail "real agy produced no result artifact"

fm_agy_validate_result "$RESULT" || fail "real agy result failed schema validation"
fm_agy_result_success "$RESULT" || fail "real agy result status was not SUCCESS"

echo "BOOTSTRAP_INFO: live agy result status: $(fm_agy_result_status "$RESULT")"

pass "real agy ${VERSION_OUT:-unknown} submits a prompt and publishes a valid SUCCESS result"
