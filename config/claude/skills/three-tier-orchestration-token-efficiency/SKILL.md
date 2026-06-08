---
name: three-tier-orchestration-token-efficiency
description: Use when handling multi-step implementation, OpenSpec apply, branch-by-branch analysis, reviewer/executor coordination, or any user request for TEAM execution. For qualifying work, this skill hard-requires TeamCreate and shared task ownership; ordinary parallel subagents are not an acceptable substitute.
---

# Three-Tier Orchestration & Token Efficiency

## Purpose

Use this skill to complete complex work with the least necessary context while preserving quality.

The goal is:

- assign the right work to the right tier
- make TEAM the control plane for qualifying implementation work
- keep expensive context out of higher tiers
- require evidence before claiming completion
- prevent raw logs, full files, and noisy executor output from traveling upward
- make failures explicit instead of silently merging uncertain results

## Trigger Conditions

Use this skill for:

- all multi-file or multi-step implementation work
- OpenSpec apply, change execution, or any task loop driven by explicit change tasks
- branch-by-branch analysis that feeds implementation, upgrade, or release conclusions
- refactors
- debugging sessions
- code reviews
- implementation plans
- research that affects implementation
- verification or test loops
- any task requiring reviewer / executor separation, retry control, task ownership, or acceptance gates
- any explicit user request for `TEAM`, `team`, coordinated team execution, or “do not use ordinary subagents”
- any request mentioning `/team`, `/opsx:apply`, `/opsx:explore`, `autopilot`, `ultrawork`, `ralph`, `ralplan`, `deep-analyze`, `deepsearch`, `tdd`, `review`, `verify`, or token/cost optimization

Do not use this skill for:

- trivial single-command answers
- simple Q&A
- text polishing
- single-line edits
- one-off explanations with no delegation or verification loop

## HARD GATE: TEAM Required for Qualifying Work

**Qualifying work** means any triggered task that is multi-step implementation, coordinated execution, OpenSpec apply, or any user-requested TEAM workflow.

For qualifying work:

1. Tier-1 **MUST** create a TEAM with `TeamCreate` before substantial execution begins.
2. Tier-1 **MUST** manage the workflow through shared tasks, named teammates, and explicit ownership.
3. Tier-1 **MUST NOT** substitute ordinary parallel subagents for the main workflow.
4. If the user explicitly asks for TEAM, TEAM is mandatory even if the task appears small.
5. If ordinary subagents were already launched for qualifying work, stop them and rebuild the workflow as a TEAM before continuing.
6. If there is doubt about whether work qualifies, default to TEAM.

**Parallel subagents are not TEAM.**

- Spawning several agents with good names is not enough.
- Having reviewer/executor roles without `TeamCreate` is not enough.
- Promising to convert to TEAM later is not enough.

Do not proceed with qualifying work until this gate is satisfied.

## Core Pipeline

```text
[TEAM Control Plane]
       |
[Tier-1: Conductor]  <->  [Tier-2: Reviewer]  <->  [Tier-3: Executor]
       Opus                    Sonnet                  Haiku
Strategy & Ownership       Verify & Gate         Atomic Execution
```

## Tier Responsibilities

### Tier-1: Conductor, Opus

Owns strategy and final decisions.

Must:

- define objective, constraints, and acceptance criteria
- establish the TEAM for qualifying work before dispatching execution
- decompose broad work into atomic tasks
- route tasks through TEAM-owned Tier-2 reviewers, never directly to Tier-3 as the main workflow
- assign or verify explicit task ownership
- resolve architecture, scope, and conflict decisions
- receive only consolidated, reviewed summaries from Tier-2
- request more evidence when reports are incomplete

Must not:

- implement code directly during `/team` execution
- edit files directly during delegated implementation
- run tests directly as a substitute for Tier-2 verification
- read full files when a summary and path reference are sufficient
- accept raw Tier-3 output as final evidence
- use ordinary parallel subagents as a substitute for TEAM on qualifying work
- perform the main branch-level analysis itself when TEAM is required
- continue qualifying work before `TeamCreate` has been used

### Tier-2: Reviewer, Sonnet

Owns task validation and retry control.

Must:

- receive atomic tasks from Tier-1 with explicit acceptance criteria
- operate within the TEAM’s shared ownership model
- dispatch bounded work to Tier-3
- retain task context across retries
- verify Tier-3 output against acceptance criteria
- reject and re-dispatch failed or incomplete work
- report upward only after criteria are met
- include evidence in every success report

Must not:

- escalate partial success as completion
- pass raw executor logs upward unless specifically requested
- approve work without evidence
- self-approve content created in the same active pass
- bypass TEAM task ownership for qualifying work

After 3 consecutive Tier-3 failures, Tier-2 must escalate to Tier-1 with a failure report.

### Tier-3: Executor, Haiku

Owns atomic execution only.

Must:

- handle one bounded task at a time
- operate on a single file, function, config block, command, or test whenever possible
- return a structured result and self-check notes
- keep output compact
- stop at the assigned scope

Must not:

- communicate with Tier-1 directly as the main execution path
- broaden scope
- rewrite architecture
- perform unrelated cleanup
- send long logs unless they are the minimal failure evidence
- replace the TEAM workflow itself

## Mode Selection

### Explore Mode, `/opsx:explore`

Use when the project or problem is not yet understood and the work is still exploratory rather than multi-step implementation.

Process:

1. Dispatch parallel subagents to inspect focused areas.
2. Each subagent returns only:
   - structure map
   - one-paragraph summary
   - relevant path references
   - risks or unknowns
3. No writes.
4. No full file contents.
5. Tier-1 assembles the project picture from summaries only.
6. If exploration turns into qualifying implementation work, stop exploration mode and create a TEAM before continuing.

### Apply Mode, `/opsx:apply`, `/team`, or any multi-step implementation

Use for implementation work.

Preconditions:

- `openspec/changes/*/tasks.md` exists and is non-empty, or equivalent explicit task list exists
- task boundaries are clear
- acceptance criteria are defined

**HARD GATE:**

- Do not proceed until `TeamCreate` has been used.
- Do not treat ordinary `Agent` fan-out as an acceptable substitute.
- If the user asked for TEAM or the work is qualifying implementation, stop and create the TEAM first.
- If ordinary subagents were already launched, stop them and rebuild the workflow as TEAM before continuing.

Process:

1. Tier-1 creates the TEAM with `TeamCreate`.
2. Tier-1 creates or aligns the shared task list.
3. Tier-1 selects the next task and assigns a Tier-2 reviewer owner.
4. Tier-2 dispatches atomic work to Tier-3.
5. Tier-3 edits, tests, or inspects only assigned scope.
6. Tier-2 verifies result.
7. Tier-2 either rejects and retries, or reports success with evidence.
8. Tier-1 updates overall plan and proceeds.

Ordinary subagents may only be used as tightly bounded helpers under a TEAM-owned workflow. They never replace TEAM as the main execution model.

### Direct Mode

Use for `/opsx:propose`, Q&A, single-line edits, small clarifications, and text polishing.

Rules:

- work directly
- do not spawn agents
- still follow project conventions
- still verify any factual completion claims
- if the task grows into multi-step implementation, exit Direct Mode and create a TEAM immediately

## TEAM Enforcement

Treat these as non-negotiable rules for qualifying work:

- `TeamCreate` is required before substantial implementation execution.
- `TaskCreate` / `TaskUpdate` style shared ownership is required for the main workflow.
- Parallel subagents are **not** equivalent to TEAM.
- Reviewer/executor naming without TEAM is **not** equivalent to TEAM.
- “I can keep the context small without TEAM” is not a valid justification.
- “I will start with subagents and convert later” is not allowed.
- “TEAM is just an implementation detail” is incorrect.

If any of the above is violated, stop and rebuild the workflow as TEAM before continuing.

## Task Packet Format

Tier-1 to Tier-2:

```text
TASK-ID: <stable id>
OBJECTIVE: <what must be achieved>
SCOPE: <files/functions/config blocks allowed>
CONSTRAINTS: <style, compatibility, no-go areas>
ACCEPTANCE: <observable success criteria>
EVIDENCE REQUIRED: <diff, test output, command output, reasoning summary>
CONTEXT LIMIT: <what may be read or forwarded>
```

Tier-2 to Tier-3:

```text
TASK-ID: <same id>
ACTION: <single atomic action>
TARGET: <single file/function/config/test>
INPUTS: <minimal relevant context>
OUTPUT REQUIRED:
- changed artifact or inspection result
- self-check notes
- minimal evidence
DO NOT:
- expand scope
- touch unrelated files
- include raw long logs
```

Tier-3 to Tier-2:

```text
TASK-ID: <same id>
RESULT: PASS | FAIL | BLOCKED
ARTIFACT: <diff summary, path, or produced output>
SELF-CHECK: <what was checked>
EVIDENCE: <minimal command/test/log snippet>
RISKS: <remaining uncertainty, if any>
```

Tier-2 to Tier-1:

```text
TASK-ID: <same id>
VERDICT: ACCEPTED | REJECTED | ESCALATED
SUMMARY: <compact result summary>
EVIDENCE: <minimal proof>
CHANGED PATHS: <paths only, no full code unless requested>
REMAINING RISKS: <explicit unknowns>
NEXT RECOMMENDATION: <continue, adjust scope, or stop>
```

Failure escalation after 3 Tier-3 attempts:

```text
TASK-ID: <same id>
VERDICT: FAILURE-ESCALATION
ATTEMPTS: 3
FAILURE MODE: <why it failed>
EVIDENCE: <minimal repeated error output>
LIKELY CAUSE: <best current hypothesis>
DECISION NEEDED: <what Tier-1 must decide>
```

## Token and Context Rules

Hard rules:

- token budgets are hard limits
- summaries go upward, not raw logs
- code diffs stay between Tier-3 and Tier-2 unless Tier-1 requests details
- retry context must send deltas only, not the full previous context
- do not re-read a full file that was already summarized during exploration
- prefer path references, symbol names, and line ranges over pasted file bodies
- do not include unrelated tool output
- do not preserve obsolete context after a decision is made

Context escalation ladder:

1. path only
2. symbol name only
3. short summary
4. relevant snippet
5. diff hunk
6. full file, only when unavoidable

## Verification Rules

Before claiming completion:

- confirm no pending delegated tasks remain
- verify success using the smallest adequate method
- include evidence appropriate to task size
- separate authoring and review passes
- never self-approve the same artifact in the same active context
- confirm the TEAM workflow was actually used for qualifying work

Verification sizing:

- small: quick check, focused command, or local reasoning
- standard: tests, build, lint, or reviewer pass
- large/security-sensitive: deeper review, adversarial cases, or architecture-level verification

Verification evidence may include:

- passing test command
- failing test turned passing
- focused diff summary
- build output
- lint output
- reviewer verdict
- exact reason a test could not be run

If evidence is missing, report the gap explicitly.

## Conflict Handling

Expose conflicts instead of silently merging them.

Common conflicts:

- user request vs. project convention
- speed vs. correctness
- token budget vs. necessary evidence
- implementation detail vs. acceptance criteria
- old plan vs. new discovery
- user-requested TEAM vs. attempted subagent shortcut

When conflict exists, Tier-1 must decide or state the chosen default clearly.

## Red Flags

If you think any of the following, stop and rebuild the workflow correctly:

- “I’ll first do a quick analysis myself.”
- “A few subagents should be enough.”
- “TEAM is just an implementation detail.”
- “The user asked for TEAM, but subagents are effectively equivalent.”
- “I’ll fix the structure after I get started.”
- “I can skip TeamCreate because the tiers are clear in my head.”
- “I already launched agents, so I should keep going.”

**All of these mean: stop, create or rebuild the TEAM, and only then continue.**

## Anti-Patterns

Avoid:

- sending complete files upward when a summary is enough
- letting Tier-3 choose architecture
- using agents for trivial work
- claiming completion without evidence
- merging partial success
- asking Tier-3 to “fix everything”
- forwarding full command logs by default
- repeating the entire task context on every retry
- treating tests as proof when they do not verify user intent
- treating ordinary parallel subagents as if they satisfy TEAM requirements
- doing the main qualifying analysis in the conductor context before TEAM setup
- promising to convert to TEAM later instead of doing it now

## Completion Checklist

Before final response:

- objective satisfied or gap clearly stated
- relevant tasks accepted by Tier-2
- evidence collected
- no pending tasks hidden
- changed paths summarized
- risks and skipped checks disclosed
- TEAM was used for qualifying work, if applicable
- final answer compact and actionable
