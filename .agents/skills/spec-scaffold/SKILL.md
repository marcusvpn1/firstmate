---
name: spec-scaffold
description: >-
  Agent-only structured spec and plan templates with self-review checklist.
  Load when a crewmate receives a scout task that requires producing a feature specification, when the captain asks for a spec, or when an implementation plan is needed before coding.
user-invocable: false
metadata:
  internal: true
---

# spec-scaffold

This skill is the single owner of the structured feature specification template, the specification self-review checklist, and the implementation plan template.
The concise trigger remains always loaded in `AGENTS.md` section 13.

## Feature specification template

Produce a specification document with every section below.
Do not skip a section even if the answer is "none identified."
Mark every uncertain item with `[NEEDS CLARIFICATION: <concrete question>]` so reviewers can see exactly what is unresolved.
Never leave a `[NEEDS CLARIFICATION]` marker without a concrete question following the colon.

### 1. Summary
One paragraph describing what this feature does and why it matters.
Keep it technology-agnostic: describe the user-visible outcome, not the implementation.

### 2. User stories
List user stories ordered by priority (P1 highest).
Every story must be independently testable: a reader should be able to judge from the story alone whether the feature satisfies it, without reading other stories.
Use the format:
- **P1:** As a `<role>`, I want `<goal>` so that `<reason>`.
- **P2:** As a `<role>`, I want `<goal>` so that `<reason>`.
- **P3:** As a `<role>`, I want `<goal>` so that `<reason>`.

Each priority tier may contain more than one story.
A story at a lower priority must not be a prerequisite for a higher-priority story.

### 3. Acceptance scenarios
For each user story in section 2, provide at least one concrete acceptance scenario in Given/When/Then format:
- **Given** `<precondition>`
- **When** `<action>`
- **Then** `<expected outcome>`

Scenarios must be testable without knowing implementation details.
Cover the happy path and at least one failure or edge path per story.

### 4. Functional requirements
List specific, testable functional requirements.
Each requirement must be a single sentence that can be verified true or false.
Group related requirements together.
Mark any requirement that depends on an unresolved decision with `[NEEDS CLARIFICATION: <question>]`.

### 5. Success criteria
List measurable, technology-agnostic outcomes that define success.
Each criterion must include a metric, a baseline (current state), and a target (desired state).
Example: "Page load time (metric) from 3.2s p95 (baseline) to under 1.5s p95 (target)."
Avoid implementation-specific criteria such as "uses Redis" or "written in Rust."

### 6. Assumptions
List every assumption the spec makes.
For each assumption, state what happens if it turns out to be false.
If no assumptions, write "None identified."

### 7. Edge cases and error handling
List edge cases, error conditions, and failure modes the feature must handle.
For each, describe the expected behavior.
Include: empty input, maximum input, concurrent use, network failure, auth failure, stale data, and any domain-specific boundary conditions.

## Self-review checklist

Before reporting the spec as done, verify every item below.
The checklist is mandatory, not optional.

1. **Placeholder scan:** Search the document for `TODO`, `FIXME`, `TBD`, `???`, `...`, `etc.`, and bare `[NEEDS CLARIFICATION]` markers without a concrete question.
   Every remaining `[NEEDS CLARIFICATION]` marker must have a specific, answerable question after the colon.
2. **Ambiguity scan:** Read each functional requirement and ask: could two reasonable people disagree on whether this is satisfied?
   If yes, make it more specific.
3. **Internal contradiction scan:** Check each pair of requirements for conflicts.
   Common conflicts: one requirement mandates a behavior another forbids, two stories describe incompatible flows, a success criterion contradicts a functional requirement.
4. **Coverage scan:** Verify every user story has at least one acceptance scenario.
   Verify every acceptance scenario maps to a user story.
5. **Testability check:** Verify every functional requirement can be verified true or false without knowing implementation details.
   Verify every success criterion includes a metric, baseline, and target.
6. **Edge-case coverage:** Verify the edge cases section covers empty input, maximum input, concurrent use, network failure, and auth failure.
7. **Assumption validation:** For every assumption, verify the consequence of it being false is stated.

## Spec granularity guideline

A spec is warranted when at least **two** of the following are true.
If fewer than two are true, a spec is overhead — ship directly with clear acceptance criteria in the task brief.

1. **New user-facing capability:** the change introduces a behavior a user (human or API consumer) can observe, as opposed to a bug fix, internal refactor, or cleanup.
2. **Cross-subsystem scope:** the change touches 3+ files across 2+ distinct subsystems, packages, or modules that are not already tightly coupled.
3. **Public API or data model change:** the change modifies a public interface, wire format, schema migration, or persistent data layout.
4. **Non-obvious user story:** at least one P1 user story does not follow trivially from a one-sentence task description — the desired behavior would need explanation to a new teammate.
5. **Decision record exists:** the feature has a documented ADR, an open decision hold, or a `[NEEDS CLARIFICATION]` marker that must be resolved before implementation.
6. **Design ambiguity:** two reasonable engineers starting from the same task description could produce materially different implementations.

A spec is NOT warranted for bug fixes (expected behavior is already defined; a regression test suffices), single-subsystem refactors, dependency bumps, tooling changes, config-only changes, or trivial feature additions where the acceptance criteria are a single sentence.

When in doubt, start a spec.
It is cheaper to discard a spec you did not need than to discover mid-implementation that you needed one.

## Spec organization and index convention

Target repos maintain a `docs/specs/` directory with a `README.md` index that maps topic areas to their files.
The index is a lightweight bullet list, not a taxonomy — a new teammate should be able to scan it in under 30 seconds.
Example:

```
# Specs index

- **Performance:** performance-benchmarks.md
- **CLI / user interface:** cli-ux.md
- **Data model:** data-model.md
- **Integrations:** github-integration.md, gitlab-integration.md
```

When authoring a spec (this spec-scaffold skill is loaded):

1. Read `docs/specs/README.md` first.
   If the directory or index does not exist yet, create both as the first spec.
2. If the feature is a natural extension of an existing topic, append to or modify that topic's file.
   Start a new top-level heading (`##`) within the file for the new feature.
3. If the feature is a genuinely new topic per the granularity guideline above, create a new file and add it to the index.
4. Update the index either way so the next author sees the current map.

Each committed spec entry is a frozen point-in-time record.
Prepend a status block to each entry so a reader can tell at a glance that it is historical:

```
> **Spec:** <task-id> | **Date:** <YYYY-MM-DD> | **Status:** shipped (frozen record)
```

## Commit-forward convention for ship workers

When a spec-driven feature ships (this spec-scaffold skill is loaded by the promoted ship worker):

1. Read the spec report at the path given in the promotion message (usually `data/<task-id>/report.md` in the firstmate home).
2. Resolve or explicitly re-open every `[NEEDS CLARIFICATION: ...]` marker.
   A marker you resolve should state how the implementation resolved it.
   A marker left open must be explicitly acknowledged — never silently dropped.
3. Commit the spec content into the appropriate doc per the index convention above.
   If the spec was appended to an existing doc, commit the updated doc.
   If a new doc was created, commit it and update `docs/specs/README.md`.
   The committed spec gets the frozen-record status block shown above.
4. Do not expect future work to keep the committed spec in sync — it is a point-in-time artifact, like an ADR.

## Spec: intent-line requirement

When driving no-mistakes for a spec-driven ship task, include a `Spec:` line in `--intent` so review can discover and check the spec:

```
no-mistakes axi run --intent "... Spec: docs/specs/<file>.md ..."
```

This line is the bridge between the committed spec and the review agent.
The `review.path_instructions` entry (configured separately in the target repo's `.no-mistakes.yaml`) uses it to locate the spec and verify P1/P2 story coverage, `[NEEDS CLARIFICATION]` resolution, and divergence documentation.
For local-only and direct-PR delivery projects, include `Spec: docs/specs/<file>.md` in the commit message body instead.

## Implementation plan template

Produce an implementation plan document with every section below.
The plan translates a completed spec into concrete implementation steps.

### 1. Technical context
Summarize the relevant parts of the existing codebase: which modules, services, or subsystems the feature touches.
List the key files, APIs, and data stores involved.
Note any technical debt in the affected area that the implementation should address or avoid worsening.

### 2. Constitution check gate
Read the project's `AGENTS.md` and any project-specific constitution or architectural rules.
List every rule that applies to this feature.
For each rule, state whether the plan complies.
If the plan violates a rule, document:
- Why the violation is necessary.
- What simpler alternatives were considered and why they were rejected.
- What compensating controls will be put in place.
Re-run this check after the design is complete and note any changes.

### 3. Project structure
Describe the files and directories the implementation will create, modify, or delete.
Use a tree format for new files.
For each file, note its responsibility in one sentence.
Mark files that are new with `(new)`, modified with `(modified)`, and deleted with `(deleted)`.

### 4. Interfaces
For each component the plan introduces or changes, document:
- **Consumes:** what inputs, APIs, or data it reads.
- **Produces:** what outputs, APIs, or data it writes.
- **Contracts:** invariants, error behavior, and performance guarantees.

### 5. Complexity tracking
List every design decision that adds complexity beyond the simplest possible implementation.
For each decision:
- State what the simplest approach would have been.
- State why it is insufficient.
- State what the chosen approach adds (new abstraction, new dependency, new state machine, etc.).
- State what would make the simpler approach sufficient in the future (so the complexity can be removed).
