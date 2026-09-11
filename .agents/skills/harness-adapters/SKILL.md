---
name: harness-adapters
description: >-
  Agent-only reference for firstmate harness operations.
  Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
  Contains verified facts for claude, codex, opencode, pi, pi-signed, pi-qwen-alienware, grok, kimi, cursor, gemini, muse, rovo, and omp.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

This is the one skill, trigger, and routing owner for harness-specific Firstmate operations.
Load this router first, then exactly the common reference and one harness reference selected below.
When an action spans rows, load the union once rather than every reference.
Files under `references/` are resources of this skill, not additional catalogued skills.

## Path contract

The skill directory is the directory containing this `SKILL.md`.
Resolve on-demand reference links and relative links to their executable, documentation, or sibling-skill owners against the skill directory, including links named by a nested reference.
Operational paths keep the context named by their owner: `config/` and active-home settings belong to the active Firstmate home, `state/` belongs to that home, and project settings such as `.claude/settings.json` belong to the target project.

## Non-negotiable safety

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names one, tell the captain under `../../../AGENTS.md` section 9 that the requested worker runtime is not verified, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime for future work.
Do not pause current work for that choice.

On `unknown`, ask the captain instead of guessing.
A current captain override beats detection, while a per-task override governs only that dispatch.
For recovery and control, use the exact `harness=` in `state/<id>.meta`; never infer it from a model or provider.

Deliver lifecycle actions only through `../../../bin/fm-control.sh <task-id> interrupt|exit|relaunch`.
Never type an interrupt key or exit command through `fm-send`, where routing-marked lifecycle text becomes chat.
Trust handling is complete only when inspection proves the target started processing its instructions; delivery success alone is not proof.
Muse and Gemini are verified only for crewmate and scout work, never a secondmate or primary.

## Detection

`../../../bin/fm-harness.sh` prints firstmate's own harness from verified environment markers, then process ancestry.
Only `FM_PI_HARNESS=pi-signed` at the launch boundary together with `PI_CODING_AGENT=true` selects Pi-signed; shared unmarked launcher ancestry remains Pi.
omp publishes no marker of its own; `FM_OMP_HARNESS=omp` is Firstmate's launch marker and the anchored process name `omp` is its ancestry evidence, as `references/harness/omp.md` records.
`../../../bin/fm-spawn.sh` owns worker marker establishment, while the README launch command owns the signed-primary boundary.
`../../../bin/fm-harness.sh crew` resolves `config/crew-harness`, where absent or `default` means firstmate's own harness.
`../../../bin/fm-harness.sh secondmate` resolves `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own harness.
`../../../bin/fm-spawn.sh` re-resolves on every spawn, and an explicit per-spawn argument wins for that spawn.
A new adapter's verified marker and command name must land in `../../../bin/fm-harness.sh`.

## Operation-to-reference matrix

Every emitted plan appends the selected or recorded harness reference after the named common references.
The `harness-adapter-routing-v1` object is the machine-readable and human-visible selection contract: choose the operation, choose the scenario within it, then append the selected harness reference.
`default` is the normal scenario when no narrower scenario applies.
Kimi establishes its unsupported primary boundary in its selected harness reference; Muse and Gemini follow Non-negotiable safety above.
A new tool remains undispatchable until the `verify` plan, its harness entry, every named owner, and the live checks land.

```json harness-adapter-routing-v1
{
  "operations": {
    "start": {
      "default": ["references/common/dispatch.md", "references/common/model-and-effort.md"],
      "trust-dialog": ["references/common/control-and-recovery.md"]
    },
    "trust": {"default": ["references/common/control-and-recovery.md"]},
    "skill": {"default": ["references/common/control-and-recovery.md"]},
    "interrupt": {"default": ["references/common/control-and-recovery.md"]},
    "exit": {"default": ["references/common/control-and-recovery.md"]},
    "resume": {"default": ["references/common/control-and-recovery.md"]},
    "recovery": {
      "default": ["references/common/control-and-recovery.md"],
      "replacement-profile": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md"],
      "secondmate": ["references/common/control-and-recovery.md", "references/common/primary-hooks.md"],
      "replacement-secondmate": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md", "references/common/primary-hooks.md"]
    },
    "primary": {"default": ["references/common/primary-hooks.md"]},
    "model-effort": {
      "default": ["references/common/model-and-effort.md"],
      "configured-profile": ["references/common/model-and-effort.md", "references/common/dispatch.md"]
    },
    "verify": {"default": ["references/common/dispatch.md", "references/common/control-and-recovery.md", "references/common/primary-hooks.md", "references/common/model-and-effort.md"]}
  },
  "harnesses": {
    "claude": "references/harness/claude.md",
    "codex": "references/harness/codex.md",
    "opencode": "references/harness/opencode.md",
    "pi": "references/harness/pi.md",
    "pi-signed": "references/harness/pi.md",
    "grok": "references/harness/grok.md",
    "kimi": "references/harness/kimi.md",
    "cursor": "references/harness/cursor.md",
    "gemini": "references/harness/gemini.md",
    "muse": "references/harness/muse.md",
    "rovo": "references/harness/rovo.md",
    "omp": "references/harness/omp.md",
    "agy": "references/harness/agy.md"
  }
}
```

## codebase-memory-mcp MCP server

Codebase-memory-mcp v0.9.0 is configured as an MCP server for crewmate harnesses.
The codebase-memory-mcp binary, installed via its own install script and available on PATH, indexes the firstmate repo with `--mode full` (6,998 nodes, 27,390 edges, includes `bin/` and `docs/`).
Validation evidence: `data/cbmm-firstmate-test/report.md` (fast-mode baseline) and `data/cbmm-moderate-test/report.md` (full-mode validation).

**Harness support:**

| Harness | Config path | Mechanism |
|---------|-------------|-----------|
| claude | `~/.claude/.mcp.json` (global) | Native MCP, tools auto-discovered |
| codex | `~/.codex/config.toml` (global) | Native MCP, `[mcp_servers.codebase-memory-mcp]` |
| opencode | `~/.config/opencode/opencode.json` (global) | Native MCP, `mcp` key |
| grok | `.mcp.json` (project root) | Native MCP, Claude-compatible |
| pi / pi-signed | `.pi/extensions/fm-cbmm-mcp.ts` (project-local) | Extension-registered tools via CLI |

kimi and agy have no verified MCP integration surface.

**Tool selection for crewmates:**

| Query type | Tool | Notes |
|-----------|------|-------|
| Find function/symbol by name | `search_graph` | BM25 keyword search; use `name_pattern` for regex |
| Find text/pattern in files | `search_code` | Ripgrep-like; fall back when `search_graph` misses |
| Trace call dependencies | `query_graph` (Cypher) | `MATCH (a)-[r:CALLS]->(b) RETURN …` |
| Codebase orientation | `get_architecture` | Layers, hotspots, clusters, boundaries |
| Call-path from known function | `trace_path` | `direction=inbound\|outbound\|both` |
| Read source for graph node | `get_code_snippet` | Use after `search_graph` to read matched code |
| Check index availability | `list_projects` | Confirm project is indexed before other calls |

**Index must be `--mode full`.** Fast and moderate modes exclude `bin/` and `docs/` — the core of the firstmate codebase.
Full mode indexes 299 files including 213 Bash scripts in 1.39 seconds.
The index artifact (`.codebase-memory/graph.db.zst`) is gitignored and cached under `~/.cache/codebase-memory-mcp/`.

**Pi extension details.** The `.pi/extensions/fm-cbmm-mcp.ts` extension registers `cbmm_search_graph`, `cbmm_search_code`, `cbmm_query_graph`, `cbmm_get_architecture`, `cbmm_trace_path`, `cbmm_get_code_snippet`, and `cbmm_list_projects`.
Each tool shells out to `codebase-memory-mcp cli <tool>` and returns JSON.
The project ID is resolved once per session from `list_projects` matching the current cwd or its canonical path.
Error output (the `level=info msg=mem.init` line on stderr) is suppressed.

## pi-qwen-alienware (EXPERIMENTAL 2026-08-17)

This is a one-shot scout adapter, not an interactive Pi-family primary or secondmate harness.
Select it explicitly with `--scout --harness pi-qwen-alienware --model ollama-alienware/qwen3:8b` while the worker-only SSH tunnel is available on localhost port 21434.
`bin/fm-pi-qwen-alienware.py` owns the deny-default sandbox, scrubbed environment, tool allowlist, 300-second default process-group deadline, report-only durable write boundary, and structured run record.
It refuses ship launches, exposes no shell tool, requires a clean worktree after completion, and reports failure when the report is absent.
Do not recover it as an interactive Pi pane; inspect `data/<task>/run-record.json`, the task status, and the durable report instead.
