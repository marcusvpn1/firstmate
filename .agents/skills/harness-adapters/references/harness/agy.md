# Agy CLI

EXPERIMENTAL and unverified.
Not added to the verified adapter list, not selectable by normal dispatch, and refused for secondmate and primary work until the full proof gate in `../../../../docs/verification/runtime-backends.md` passes.

Observed on Agy 1.2.1 (2026-09-11) for crewmate and scout work only.
The installed binary auto-updates, so the exact version pin is load-bearing: `bin/fm-spawn.sh` refuses launch on any version other than the pinned one rather than trusting a CLI surface that may have drifted.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `agy`, resolved from `PATH` (`~/.local/bin/agy`); the live process name is the exact word `agy` (a Go binary). |
| Version | Exact pin `FM_AGY_PINNED_VERSION` (default `1.2.1`); `fm_agy_version_pinned` refuses a mismatch. |
| Kind | Crewmate and scout only. No secondmate, no primary (no turn-end hook, no primary supervision protocol). |
| Backend | tmux only. Every other backend is refused before an endpoint is created. |
| Launch | `agy --output-format json --dangerously-skip-permissions --add-dir <worktree> <--model> <--effort> --print-timeout Ns --log-file <log> -p="<encoded brief>"`, owned by `fm_agy_launch_template` in `../../../bin/fm-agy-lib.sh`. |
| Worktree write | `--add-dir <worktree>` is load-bearing: without it agy's file tool writes into `~/.gemini/antigravity-cli/scratch/` instead of the task worktree. |
| One-shot | A single `-p` (print) invocation processes the brief and exits. No TUI, no interactive steer, no data-plane steering, no turn-end hook. |
| Prompt flag | The prompt must be attached to `-p` with `=` (`-p="..."`). A bare `-p <flag>` swallows the next flag as its prompt and ignores the real prompt (the "dashline" bug). |
| Models | `agy models` lists the current catalog (observed: `gemini-3.8/3.7/3.6-flash-{high,medium,low}`, `gemini-3.1-pro-{high,low}`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium`). The model flag passes through; agy rejects an unknown model with a nonzero exit and an `ERROR` result. |
| Effort | `--effort low\|medium\|high` only. `xhigh` and `max` are unsupported and omitted, never guessed. |
| Result | One JSON object on stdout, `--output-format json`, with schema `{conversation_id, status, response, error?, denied_actions?, duration_seconds, num_turns, usage}` and `status` being `SUCCESS` or `ERROR` (uppercase). `denied_actions` is present when a tool action is auto-denied, and a `SUCCESS` result with a non-empty `denied_actions` is a failed task, not a success. Completion is proven only by a validated, generation-bound result artifact, never by exit code alone. |
| Result publication | stdout is redirected to a per-generation temp file and atomically renamed on completion, so a reader never sees a partial artifact (`fm_agy_publish_result`). |
| Exit | Exit code `0` on success and `1` on error, but the result artifact is the source of truth for completion. |
| Control | Refused. Interrupt/exit/relaunch postconditions are unverified against the live binary, so `../../../bin/fm-control-lib.sh` omits agy and the control plane refuses its verbs. |
| Quota | No single provider family: agy spans Gemini, Claude, and GPT-OSS. `quota-axi` reports an `agy` provider whose effective availability is empty, so quota is unmeasurable and `../../../bin/fm-quota-choose.sh` rejects agy rather than guessing. |
| Busy state | No spinner and no semantic busy writer. Running/terminal state comes from backend process liveness plus the validated result artifact, never from rendered text. |

## Detection

`../../../bin/fm-harness.sh` matches the exact process name `agy` in the ancestry walk, beside `pi`, `omp`, and `kimi`.
The match is anchored, never `*agy*`, so an unrelated command carrying the fragment in its name is not elevated to this harness.
Detection alone never authorizes a launch: `bin/fm-spawn.sh` and `bin/fm-bootstrap.sh` still refuse the unverified adapter.

## Launch and result

`bin/fm-spawn.sh` refuses an agy launch before endpoint creation when any of these holds: the kind is secondmate, the backend is not tmux, or the installed version does not equal the pinned version.
The launch template is owned by `../../../bin/fm-agy-lib.sh` so the command shape, the `-p=` fix, and the result contract have one owner.

The result path is task-owned and generation-bound: `/tmp/fm-<task-id>/result-<spawn_gen>.json`.
A stale artifact from a previous generation lives at a different path and is never read as this generation's result.

## Failure semantics

Every non-success case fails closed: a nonzero exit, a missing or empty result artifact, malformed JSON, an unknown top-level or usage key, a wrong type, an oversized artifact, a missing terminal status, or an unknown status value all reject the result.
jq is a hard dependency for validation and interpretation; its absence fails explicitly rather than degrading to a weak structural check.

## Not verified

The following remain unproven until the proof gate passes: the permission boundary (no writes outside the worktree, no credential leakage), live liveness through the backend, live interrupt/cancel/exit postconditions, and a full end-to-end prompt-submitting run.
Until then agy stays out of the verified adapter list and fails closed wherever it is named.
