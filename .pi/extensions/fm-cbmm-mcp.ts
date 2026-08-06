/**
 * fm-cbmm-mcp — Pi extension that exposes codebase-memory-mcp tools via the CLI.
 *
 * Each registered tool shells out to `codebase-memory-mcp cli <tool>` and
 * returns the JSON result. The project ID is resolved once at first use by
 * matching the current working directory against `list_projects`.
 *
 * Installed alongside the primary turn-end guard and watcher extensions.
 * See data/cbmm-moderate-test/report.md for the full-mode validation.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { execSync } from "node:child_process";
const BINARY = "/Users/marcusnascimento/.local/bin/codebase-memory-mcp";

// ---------------------------------------------------------------------------
// Project-id resolution
// ---------------------------------------------------------------------------

let _projectId: string | null = null;

function resolveProjectId(cwd: string): string | null {
  if (_projectId !== null) return _projectId || null;
  try {
    const raw = execSync(`${BINARY} cli list_projects 2>/dev/null`, {
      encoding: "utf-8",
      timeout: 5_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const parsed = JSON.parse(raw);
    const projects: Array<{ name: string; root_path: string }> =
      parsed?.projects ?? [];
    // Prefer exact root_path match, then canonical-root match, then the
    // first project.
    const exact = projects.find((p) => p.root_path === cwd);
    _projectId = exact?.name ?? projects[0]?.name ?? "";
  } catch {
    _projectId = "";
  }
  return _projectId || null;
}

// ---------------------------------------------------------------------------
// CLI helper
// ---------------------------------------------------------------------------

interface CliArgs {
  [key: string]: string | number | boolean | string[] | undefined;
}

function callCli(tool: string, args: CliArgs, projectId: string): unknown {
  const parts: string[] = [];
  for (const [key, value] of Object.entries(args)) {
    if (value === undefined || value === false) continue;
    const flag = `--${key}`;
    if (value === true) {
      parts.push(flag);
      continue;
    }
    if (Array.isArray(value)) {
      parts.push(`${flag} '${JSON.stringify(value)}'`);
      continue;
    }
    parts.push(`${flag} '${String(value)}'`);
  }
  const argStr = parts.join(" ");
  const cmd = `${BINARY} cli ${tool} --project '${projectId}' ${argStr}`;
  const stdout = execSync(cmd, {
    encoding: "utf-8",
    maxBuffer: 10 * 1024 * 1024,
    timeout: 30_000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return JSON.parse(stdout);
}

// ---------------------------------------------------------------------------
// Extension factory
// ---------------------------------------------------------------------------

export default function (pi: ExtensionAPI) {
  // -- search_graph ----------------------------------------------------------

  pi.registerTool({
    name: "cbmm_search_graph",
    label: "CBMM Search Graph",
    description:
      "BM25 keyword search over the codebase knowledge graph. Best for finding functions, classes, and symbols by name or purpose. Returns ranked results with file paths and line numbers. Use this for symbol/function search; use cbmm_search_code for literal text search.",
    parameters: Type.Object({
      query: Type.String({
        description:
          "Natural-language or keyword search query. Tokens split on whitespace; camelCase identifiers indexed as individual words (updateCloudClient → update, cloud, client).",
      }),
      limit: Type.Optional(
        Type.Number({ description: "Max results (default 20, max 50)" }),
      ),
      label: Type.Optional(
        Type.String({
          description:
            "Filter by node label: Function, Class, Method, Route, etc.",
        }),
      ),
      name_pattern: Type.Optional(
        Type.String({ description: "Regex pattern to filter by node name." }),
      ),
      file_pattern: Type.Optional(
        Type.String({ description: "Glob pattern to filter by file path." }),
      ),
      relationship: Type.Optional(
        Type.String({
          description:
            "Filter nodes by edge type: CALLS, HTTP_CALLS, IMPORTS, DEFINES, etc.",
        }),
      ),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const projectId = resolveProjectId(ctx.cwd);
      if (!projectId)
        return {
          content: [
            {
              type: "text",
              text: "Error: no codebase-memory index found. Run 'codebase-memory-mcp cli index_repository --repo-path <path> --mode full' first.",
            },
          ],
        };
      try {
        const result = callCli("search_graph", params, projectId);
        return {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return { content: [{ type: "text", text: `Error: ${msg}` }] };
      }
    },
  });

  // -- search_code -----------------------------------------------------------

  pi.registerTool({
    name: "cbmm_search_code",
    label: "CBMM Search Code",
    description:
      "Ripgrep-like text search across the indexed codebase. Best for finding literal patterns, strings, or content that BM25 may miss. Returns matching file paths with line numbers. Use this for content search; use cbmm_search_graph for symbol/structural search.",
    parameters: Type.Object({
      pattern: Type.String({
        description: "Literal text or regex pattern to search for.",
      }),
      limit: Type.Optional(
        Type.Number({ description: "Max results (default 20)." }),
      ),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const projectId = resolveProjectId(ctx.cwd);
      if (!projectId)
        return {
          content: [
            {
              type: "text",
              text: "Error: no codebase-memory index found.",
            },
          ],
        };
      try {
        const result = callCli("search_code", params, projectId);
        return {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return { content: [{ type: "text", text: `Error: ${msg}` }] };
      }
    },
  });

  // -- query_graph (Cypher) --------------------------------------------------

  pi.registerTool({
    name: "cbmm_query_graph",
    label: "CBMM Query Graph",
    description:
      "Run a Cypher query against the codebase knowledge graph. Best for dependency tracing, call-path analysis, and cross-service edge inspection. Edge types: CALLS, HTTP_CALLS, ASYNC_CALLS, IMPORTS, DEFINES, DEFINES_METHOD, HANDLES, IMPLEMENTS, OVERRIDE, USAGE. Results capped at 200 rows.",
    parameters: Type.Object({
      query: Type.String({
        description:
          "Cypher query. Examples: 'MATCH (a)-[r:CALLS]->(b) RETURN a.name, type(r), b.name LIMIT 30', 'MATCH (f:Function) WHERE f.name =~ \".*Handler.*\" RETURN f.name, f.file_path', 'MATCH (a)-[r:HTTP_CALLS]->(b) RETURN a.name, b.name, r.url_path LIMIT 20'.",
      }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const projectId = resolveProjectId(ctx.cwd);
      if (!projectId)
        return {
          content: [
            {
              type: "text",
              text: "Error: no codebase-memory index found.",
            },
          ],
        };
      try {
        const result = callCli("query_graph", params, projectId);
        return {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return { content: [{ type: "text", text: `Error: ${msg}` }] };
      }
    },
  });

  // -- get_architecture ------------------------------------------------------

  pi.registerTool({
    name: "cbmm_get_architecture",
    label: "CBMM Get Architecture",
    description:
      "Return a structured architecture overview of the codebase: layers (core/entry/internal/leaf), top-10 hotspots by fan-in, clusters with cohesion scores, cross-package boundaries, languages, and file tree. Use this for codebase orientation before diving into specific files.",
    parameters: Type.Object({
      aspects: Type.Optional(
        Type.String({
          description:
            "Comma-separated aspects to include: layers, hotspots, clusters, boundaries, languages, file_tree, all (default: layers,hotspots).",
        }),
      ),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const projectId = resolveProjectId(ctx.cwd);
      if (!projectId)
        return {
          content: [
            {
              type: "text",
              text: "Error: no codebase-memory index found.",
            },
          ],
        };
      try {
        const result = callCli(
          "get_architecture",
          { aspects: params.aspects ?? "layers,hotspots" },
          projectId,
        );
        return {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return { content: [{ type: "text", text: `Error: ${msg}` }] };
      }
    },
  });

  // -- trace_path ------------------------------------------------------------

  pi.registerTool({
    name: "cbmm_trace_path",
    label: "CBMM Trace Path",
    description:
      "Trace call paths to/from a function. Direction: inbound (who calls X), outbound (what X calls), both (full context). Optionally include risk labels. Requires the exact function name — use cbmm_search_graph first to discover names.",
    parameters: Type.Object({
      function_name: Type.String({
        description: "Exact qualified function name to trace.",
      }),
      direction: Type.Optional(
        Type.String({
          description:
            "Trace direction: inbound, outbound, or both (default: both).",
        }),
      ),
      depth: Type.Optional(
        Type.Number({ description: "Max depth (default 3)." }),
      ),
      risk_labels: Type.Optional(
        Type.Boolean({
          description: "Include risk classification labels.",
        }),
      ),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const projectId = resolveProjectId(ctx.cwd);
      if (!projectId)
        return {
          content: [
            {
              type: "text",
              text: "Error: no codebase-memory index found.",
            },
          ],
        };
      try {
        const result = callCli("trace_path", params, projectId);
        return {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return { content: [{ type: "text", text: `Error: ${msg}` }] };
      }
    },
  });

  // -- get_code_snippet ------------------------------------------------------

  pi.registerTool({
    name: "cbmm_get_code_snippet",
    label: "CBMM Get Code Snippet",
    description:
      "Retrieve source code for a node identified by its qualified name from the graph. Use after cbmm_search_graph to read the actual source of a matched symbol.",
    parameters: Type.Object({
      qualified_name: Type.String({
        description:
          "Fully qualified node name from the graph, e.g. 'bin/fm-watch-arm.sh:healthy_watcher'.",
      }),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const projectId = resolveProjectId(ctx.cwd);
      if (!projectId)
        return {
          content: [
            {
              type: "text",
              text: "Error: no codebase-memory index found.",
            },
          ],
        };
      try {
        const result = callCli("get_code_snippet", params, projectId);
        return {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return { content: [{ type: "text", text: `Error: ${msg}` }] };
      }
    },
  });

  // -- list_projects ---------------------------------------------------------

  pi.registerTool({
    name: "cbmm_list_projects",
    label: "CBMM List Projects",
    description:
      "List all indexed codebase-memory projects. Use to check whether the current project has a knowledge graph index available.",
    parameters: Type.Object({}),
    async execute() {
      try {
        const raw = execSync(`${BINARY} cli list_projects 2>/dev/null`, {
          encoding: "utf-8",
          timeout: 5_000,
          stdio: ["ignore", "pipe", "pipe"],
        });
        const result = JSON.parse(raw);
        return {
          content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        };
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return { content: [{ type: "text", text: `Error: ${msg}` }] };
      }
    },
  });
}
