---
name: three-tier-orchestration
description: Use for multi-step implementation, hardware/embedded debugging, or any TEAM request. Requires TeamCreate; parallel subagents are never a substitute.
---

# Three-Tier Orchestration

> **Triggers:** multi-step implementation · refactor · code review · debug · OpenSpec apply · hardware interface (serial / bus / debug probe / embedded target) · firmware · bootloader · register · device log · `/team` `/opsx:apply` `/opsx:explore` `autopilot` `ultrawork` `tdd` `review` `verify` `ralph` `ralplan` `deep-analyze` `deepsearch`
> **Skip:** single-command answers · Q&A · text polish · single-line edits

## Pipeline

```
Tier-1: Conductor (Opus)   — strategy, ownership, decompose
Tier-2: Reviewer  (Sonnet) — verify, gate, retry control
Tier-3: Executor  (Haiku)  — atomic execution only
```

## HARD GATE — Self-Check Before First Action

```
1. Qualifying work? (multi-step / hardware I/O / implementation / TEAM requested)
   NO → Direct Mode.   YES → continue.
2. TeamCreate called this session?
   NO → call TeamCreate NOW. No files, commands, or agents before this.
3. Next action Tier-3 type? (run / edit / touch device)
   YES → STOP. Write a task packet. Assign it.
```

Skipping this check is a protocol violation.

**Parallel subagents ≠ TEAM.** Named roles without `TeamCreate` ≠ TEAM. "Convert later" ≠ allowed.

**Rollback:** If any edit or command ran before `TeamCreate` — stop, document changed paths only, call `TeamCreate`, assign review of pre-TEAM changes as the first Tier-2 task.

**Teammate absence:** Reassign, escalate as BLOCKED, or re-ping. Tier-1 picking up implementation is never an option.

**Scope-shrink:** More than one file, or any build system file = qualifying work, regardless of description.

## Tier Responsibilities

**Tier-1 — Conductor:** define objective + constraints + acceptance criteria → `TeamCreate` → decompose → assign to Tier-2 → receive reviewed summaries only → decide on conflicts and blocks. Must not implement, touch hardware/I/O, or forward raw device output into conductor context.

**Tier-2 — Reviewer:** dispatch atomic tasks to Tier-3 → verify against acceptance criteria → reject and retry on failure → report upward only with evidence. Must not approve without evidence, self-approve same-pass content, or pass raw output upward. After 3 Tier-3 failures → escalate to Tier-1.

**Tier-3 — Executor:** one bounded task, one target. Return structured result + self-check + compact evidence. Must not broaden scope, contact Tier-1 directly, forward raw hardware output, return > 50 lines of device output, or leave a hardware connection open across task boundaries.

## Mode Selection

**Explore** `/opsx:explore`: parallel subagents, read-only. Each returns structure map + one-paragraph summary + path references + risks. No writes, no full files. Exploration → implementation = stop, create TEAM.

**Apply** `/opsx:apply` `/team`: `TeamCreate` → task list → Tier-1 assigns to Tier-2 → Tier-2 dispatches to Tier-3 → Tier-3 executes → Tier-2 verifies → repeat.

**Direct**: Q&A, single-line edits, no agents. Grows into multi-step → create TEAM immediately.

## Embedded & Hardware Debugging

### I/O Isolation — Non-Negotiable

Tier-1 and Tier-2 must never directly open, read, write, or poll any hardware interface, issue attach/memory/register commands, block-wait on hardware, or capture unbounded output streams. Every hardware action is a Tier-3 task packet.

### Hardware Task Packet (additional required fields)
```
INTERFACE:        <connection type and parameters>
TIMEOUT_MS:       <hard limit — no open-ended waits>
MAX_OUTPUT_LINES: <ceiling on raw capture, default 50>
FILTER_PATTERN:   <pattern to extract signal from noise>
OPEN_CLOSE_SCOPE: <connection must open and close within this task>
```
Missing any of these fields → Tier-2 rejects the packet.

### Hardware Output Discipline (Tier-3, before reporting)
1. Capture raw (respect MAX_OUTPUT_LINES)
2. Apply FILTER_PATTERN — matching lines only
3. Annotate: timestamp, line number, error/warning tag
4. If truncated: state count and what was lost
5. Return filtered + annotated only — never the raw stream

### Hardware Retry Sequence
```
RETRY-1: retry — verify device still enumerated
RETRY-2: close + reopen interface — retry
RETRY-3: reset or power-cycle target — retry
FAIL:     escalate: error type / interface state / enumeration / hypothesis
```

### Hardware State Record (Tier-1, updated each Tier-2 verdict)
```
TARGET:            <device identifier>
INTERFACE:         <current connection parameters>
LAST_KNOWN_STATE:  responsive | unresponsive | unknown | flashing | booting
LAST_CONFIRMED_AT: <task-id>
PENDING_RESET:     yes | no
```
State `unresponsive` or `unknown` → probe task before any functional task.

## Task Packet Formats

**Tier-1 → Tier-2:**
```
TASK-ID:         <stable id>
OBJECTIVE:       <what must be achieved>
SCOPE:           <targets allowed>
CONSTRAINTS:     <style, compatibility, no-go areas>
ACCEPTANCE:      <observable success criteria>
EVIDENCE NEEDED: <diff / test output / command output / reasoning>
CONTEXT LIMIT:   <what may be read or forwarded>
[+ hardware fields if applicable]
```

**Tier-2 → Tier-3:**
```
TASK-ID: <same id>
ACTION:  <single atomic action>
TARGET:  <single file / function / config / command>
INPUTS:  <minimal relevant context>
OUTPUT:  artifact + self-check + minimal evidence
DO NOT:  expand scope / touch unrelated targets / include raw long output
```

**Tier-3 → Tier-2:**
```
TASK-ID:    <same id>
RESULT:     PASS | FAIL | BLOCKED
ARTIFACT:   <diff summary, path, or output>
SELF-CHECK: <what was verified>
EVIDENCE:   <minimal snippet>
RISKS:      <remaining uncertainty>
```

**Tier-2 → Tier-1:**
```
TASK-ID:       <same id>
VERDICT:       ACCEPTED | REJECTED | ESCALATED
SUMMARY:       <compact result>
EVIDENCE:      <minimal proof>
CHANGED PATHS: <paths only>
RISKS:         <explicit unknowns>
NEXT:          continue | adjust scope | stop
```

**Failure escalation (after 3 attempts):**
```
VERDICT:         FAILURE-ESCALATION
FAILURE MODE:    <why>
EVIDENCE:        <minimal repeated error>
LIKELY CAUSE:    <hypothesis>
DECISION NEEDED: <what Tier-1 must decide>
```

**Blocked teammate:**
```
STATUS:  BLOCKED — teammate has not responded
OPTIONS: A) reassign  B) escalate to user  C) split and reassign
NOTE:    Tier-1 will not pick up implementation directly
```

## Teammate Control

**`SendMessage`:** use for continuous work on the same teammate — add context, correct direction, or assign the next step when the teammate remains trustworthy and its context is still valuable.

**`TaskStop`:** use to stop a running background task when new mainline context makes the prior execution stale, wrong, or wasteful. This stops the task, not the teammate.

**`shutdown_request`:** use when the teammate itself should be retired — task completed, context polluted, repeated factual mismatch, or continued use costs more than restarting with a fresh teammate.

**Decision rule:**
Task wrong, teammate still useful   → TaskStop + SendMessage
Task wrong, teammate unreliable     → TaskStop + shutdown_request
Need more context / next step only  → SendMessage
Work finished / no further use      → shutdown_request

**No hard interrupt:** teammates do not have a user-style immediate interrupt. `SendMessage` updates direction on the next turn; `TaskStop` cancels the running task layer; `shutdown_request` ends the teammate after its current turn boundary.

## Verification

Claim completion only when: all delegated tasks accepted by Tier-2 with evidence, authoring and review are separate passes, TEAM was used for qualifying work. Missing evidence → report the gap explicitly.

## Stop Conditions (Red Flags)

Any of the following = stop, rebuild the TEAM, then continue:

- "I'll do a quick analysis myself first" / "A few subagents should be enough"
- "TEAM is just an implementation detail" / "Subagents are equivalent to TEAM"
- "I'll fix the structure after I get started" / "I already launched agents, so I'll keep going"
- "This is only a minimal change" / "Just two files"
- "Let me connect to the device to see what's happening" / "I need to see the raw output myself"
- "I'll poll until I get a response, then assign it"
- "The teammate didn't respond, so I'll do it myself"

## Completion Checklist

- [ ] objective satisfied or gap stated
- [ ] all tasks Tier-2 accepted with evidence
- [ ] no hidden pending tasks
- [ ] changed paths summarized, no full content unless requested
- [ ] risks and skipped checks disclosed
- [ ] TEAM used for qualifying work
- [ ] hardware: state record current, all connections closed