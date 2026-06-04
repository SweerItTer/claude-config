# Information Transmission Protocol (ITP)

> Every inter-tier message contains only what the receiver needs to act.
> Code does not travel up. Escalation is triggered by failure, not habit.

## Message Formats

**Opus → Sonnet — TASK-CARD**
```
id:          <TASK-001>
objective:   <one measurable sentence>
scope:       <file(s) / module(s) / function(s)>
constraints: <immutable rules>
acceptance:  <binary criteria>
```
Forbidden: rationale, history, unrelated files, code beyond the function at issue.

**Sonnet → Haiku — EXEC-UNIT**
```
id:          <TASK-001.1>
action:      <imperative verb phrase — one thing>
input:       <file path + line range OR minimal snippet>
output:      <exact artifact: path, function signature, test name>
constraints: <copied verbatim from TASK-CARD>
self-check:  <what Haiku verifies before returning>
```
Forbidden: project-wide context, other sub-tasks' history, Opus-level rationale.

**Haiku → Sonnet — RESULT-PACKET**
```
id:          <TASK-001.1>
status:      PASS | FAIL | BLOCKED
diff:        <unified diff, ±3 lines context only>
self-check:  <each item: PASS/FAIL + one-line evidence>
error:       <if FAIL/BLOCKED: message + first relevant stack line>
```
Forbidden: explanations, unchanged code, full test output.

**Sonnet → Opus — SUMMARY-REPORT** (success)
```
task-id:     <TASK-001>
verdict:     ACCEPTED
evidence:    <criterion → met/not-met + proof token, one line each>
net-change:  <files: N | added: N | removed: N>
anomalies:   <resolved surprises, one line each>
```
Forbidden: diffs, logs, code, per-sub-task details. Opus reads verdicts, not code.

**Sonnet → Opus — DECISION-REQUEST** (mid-task blocker)
```
task-id:     <TASK-001>
blocker:     <one sentence>
option-A:    <approach + trade-off>
option-B:    <approach + trade-off>
recommended: <A | B | neither + one-line reason>
context-ref: <file:line pointer — never inline code>
```
Forbidden: diffs, implementation details, anything resolvable at Tier-2.

**Sonnet → Opus — FAILURE-ESCALATION** (after 3 failures)
```
task-id:     <TASK-001>
attempts:    3
failures:    <attempt → what failed, one line each>
hypothesis:  <root cause, one sentence>
request:     <clarify constraint | change scope | abort>
```

## Transmission Rules

- Code does not travel up — diffs stay at Haiku→Sonnet only
- Context stays at its tier — retry sends delta only, not full context
- Failure gates escalation — pass results never include a DECISION-REQUEST
- Acceptance criteria are binary — unverifiable criteria must be clarified before dispatch
- Summary is not a log — skimmable in 10 seconds, no raw output
- IDs chain — every message carries parent task ID; orphans are rejected

## Escalation Flow

```
Haiku → RESULT-PACKET
  PASS → Sonnet checks acceptance criteria
           all met   → SUMMARY-REPORT to Opus
           any unmet → re-dispatch EXEC-UNIT (delta only, attempt+1)
  FAIL/BLOCKED
           attempt < 3 → re-dispatch with failure delta
           attempt = 3 → FAILURE-ESCALATION to Opus
                           Opus decides → new TASK-CARD → attempt resets
```
