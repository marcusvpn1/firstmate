# Agy CLI

EXPERIMENTAL and unverified.
Not added to the verified adapter list, and refused by normal dispatch in every form (explicit `fm-spawn ... agy`, `config/crew-harness`, secondmate, and every statically detectable spelling of the raw launch escape hatch), so no dispatch path statically resolved to agy reaches a launch. The only sanctioned execution is the opt-in live guard (`tests/fm-agy-live-e2e.test.sh`, `FM_AGY_LIVE=1`), which invokes the binary directly under the PG4 ambient-secret scrub and validates its result.

Observed on Agy 1.2.2 (2026-09-13) via the live guard; prior 1.2.1 observations are retained as historical evidence in `../../../docs/verification/runtime-backends.md`.
The installed binary auto-updates, so the exact version pin is load-bearing: the live guard refuses any version other than the pinned one (`fm_agy_version_pinned`) rather than trusting a CLI surface that may have drifted.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `agy`, resolved from `PATH` (`~/.local/bin/agy`); the live process name is the exact word `agy` (a Go binary). |
| Version | Exact pin `FM_AGY_PINNED_VERSION` (default `1.2.2`); `fm_agy_version_pinned` refuses a mismatch. |
| Kind | None by normal dispatch (refused for every kind). The live guard exercises a one-shot print run only. |
| Backend | Normal dispatch refuses every backend (tmux included) before an endpoint is created. The live guard runs agy as a direct subprocess, not through a runtime backend. |
| Launch | `agy --output-format json --dangerously-skip-permissions --add-dir <worktree> <--model> <--effort> --print-timeout Ns --log-file <log> -p="<encoded brief>"`, owned by `fm_agy_launch_template` in `../../../bin/fm-agy-lib.sh`. |
| Worktree write | `--add-dir <worktree>` is load-bearing: without it agy's file tool writes into `~/.gemini/antigravity-cli/scratch/` instead of the task worktree. |
| One-shot | A single `-p` (print) invocation processes the brief and exits. No TUI, no interactive steer, no data-plane steering, no turn-end hook. |
| Prompt flag | The prompt must be attached to `-p` with `=` (`-p="..."`). A bare `-p <flag>` swallows the next flag as its prompt and ignores the real prompt (the "dashline" bug). |
| Models | `agy models` lists the current catalog (observed: `gemini-3.8/3.7/3.6-flash-{high,medium,low}`, `gemini-3.1-pro-{high,low}`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium`). The model flag passes through; agy rejects an unknown model with a nonzero exit and an `ERROR` result. |
| Effort | `--effort low\|medium\|high` only. `xhigh` and `max` are unsupported and omitted, never guessed. |
| Result | One JSON object on stdout, `--output-format json`, with schema `{conversation_id, status, response, error?, denied_actions?, duration_seconds, num_turns, usage}` and `status` being `SUCCESS` or `ERROR` (uppercase). `denied_actions` is present when a tool action is auto-denied, and a `SUCCESS` result with a non-empty `denied_actions` is a failed task, not a success. Completion is proven only by a validated, generation-bound result artifact, never by exit code alone. |
| Environment scrub | `fm_agy_env_scrub_code` unsets `STITCH_X_GOOG_API_KEY`, `STITCH_API_KEY`, `ANTHROPIC_API_KEY`, `APIFY_API_KEY`, `HF_TOKEN`, and every other `*_API_KEY` / `*_TOKEN` / `*_SECRET` var in the pane shell (and in the live guard's launch subshell) before agy runs, so agy's MCP children never inherit ambient credentials; the operator's own shell is untouched. |
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

`bin/fm-spawn.sh` refuses every agy launch before endpoint creation (explicit selection, `config/crew-harness`, secondmate, and the statically detectable spellings of the raw launch escape hatch all fail closed), so no dispatch reaches a launch template.
The launch template is owned by `../../../bin/fm-agy-lib.sh` as the documented reference shape (exercised by the portable template-contract test and the live guard's shape, not by dispatch), so the command shape, the `-p=` fix, and the result contract have one owner.

The result path is task-owned and generation-bound: `/tmp/fm-<task-id>/result-<spawn_gen>.json`.
A stale artifact from a previous generation lives at a different path and is never read as this generation's result.

## Failure semantics

Every non-success case fails closed: a nonzero exit, a missing or empty result artifact, malformed JSON, an unknown top-level or usage key, a wrong type, an oversized artifact, a missing terminal status, or an unknown status value all reject the result.
jq is a hard dependency for validation and interpretation; its absence fails explicitly rather than degrading to a weak structural check.

## Not verified

The permission boundary is now handled by these explicit, documented limitations rather than left as an open question:

1. **Scrubbed launch environment.** `fm_agy_env_scrub_code` unsets the named ambient secrets (`STITCH_X_GOOG_API_KEY`, `STITCH_API_KEY`, `ANTHROPIC_API_KEY`, `APIFY_API_KEY`, `HF_TOKEN`) plus every other `*_API_KEY` / `*_TOKEN` / `*_SECRET` var in the pane shell before agy runs, so no ambient credential reaches agy's MCP children. The operator's own shell (and the Stitch MCP server it feeds) is untouched.
2. **Unverified MCP sandbox.** Agy's MCP children are treated as network-unrestricted: their `--sandbox` behavior is unverified, so no permission proof exists for their network or home access.
3. **Statically detectable raw-launch refusal only.** The raw-launch guard scans the literal command text. It refuses agy spelled directly, wrapped behind `env`/`command`/`nohup`/`sh -c`, in another letter case, assembled from quoted or backslash-escaped fragments (`a"g"y`, `a'g'y`, `a\gy`), or fused with grouping/assignment/parameter-expansion/command-substitution syntax that still contains a literal `agy` (`(agy ...)`, `A=agy; $A`, `${AGY:-agy}`, `$(printf agy)`). A command that computes the executable name at runtime from characters that never appear contiguously (for example `$'a\x67y'` or `a$(printf g)y`) cannot be resolved by a static scan and is outside that guarantee. The raw-launch escape hatch is a generic arbitrary-command mechanism; it must not be used to launch agy.

The real-binary result schema, version pin, and the PG4 ambient-secret scrub are exercised by the opt-in live guard on agy 1.2.2 (`../../../docs/verification/runtime-backends.md`); the earlier end-to-end Hello World spawn is recorded there as historical proof-gate evidence, but normal dispatch is now refused, so the live guard is the only sanctioned execution.
Agy stays out of the verified adapter list and fails closed wherever it is named.
