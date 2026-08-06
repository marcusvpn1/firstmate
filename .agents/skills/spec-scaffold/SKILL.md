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
