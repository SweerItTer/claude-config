---
name: evidence-driven-analysis
description: Use when a technical conclusion must be justified from concrete evidence — logs, code, tests, metrics, diffs, packets, traces, or documents. Triggers for bug diagnosis, root-cause analysis, postmortems, incident findings, and architecture risk assessment. In Claude Code, triggers whenever a "why does this fail", "what causes X", "analyze this crash/log/diff", or "trace this regression" task requires traceable, intervention-grounded conclusions rather than plausible-sounding prose. Do not use for lightweight explanations, brainstorming, opinions, or tasks with no concrete evidence set.
---

# Evidence-Driven Analysis

## Overview

Produce conclusions another engineer can verify and act on without re-investigating.

**Core rule:** never let an unverified claim inherit the confidence of a verified one.
A log event may be verified while the explanation attached to it is still only an inference.

## Evidence Collection (Claude Code)

In Claude Code you have direct access to the source. Read before asserting.
A causal chain you have navigated with `rg` and `git blame` is stronger than one reconstructed from memory.

```bash
# Locate all sites relevant to the suspected mechanism
rg -n 'keyword_a|keyword_b' src/

# Understand recent changes to the suspect file
git log --oneline -20 -- suspect_file.c
git blame -L START,END suspect_file.c

# Inspect the commit that introduced the suspect line
git show <commit> -- suspect_file.c
```

For log or capture evidence, extract the relevant window first:

```bash
grep -n 'EVENT_A\|EVENT_B\|ERROR' run.log | head -60
awk '/START_MARKER/{p=1} p' run.log | head -100
```

**Pin every source claim to `file:line@commit`.** Commit hashes keep pointers stable across rebases.
**Never assert a location you have not read.** State the evidence gap instead.

---

## Output: Build in This Order

Confidence depends on completing step 5. Write a provisional verdict at step 1, then revise it after completing step 5.

---

### 1. Provisional Verdict

Open with what happened, observed impact, and a provisional confidence label. You will revise this after step 5.

```
❌  I examined the logs and then inspected the relevant code path…

✅  [Provisional] The worker OOM crash is probably caused by the request
    buffer growing unbounded on large uploads. Peak RSS: 2.1 GB before
    SIGKILL. Confidence: Probable — memory profile and code path match;
    no isolation test yet.
```

**Confidence scale:**

| Label | Meaning |
|---|---|
| **Confirmed** | Intervention or repeatable isolation changes the failure as predicted |
| **Probable** | Causal chain fits; major alternatives are less consistent with available evidence; no direct intervention yet |
| **Possible** | Evidence is consistent but incomplete; alternatives not ruled out |
| **Insufficient** | Evidence only narrows the space; do not recommend a fix |

Temporal adjacency alone never justifies **Probable** or higher.

---

### 2. Visualize When Structure Aids Understanding

Use a compact timeline, flow, or state diagram only for timing or transition problems. Mark the failure point with `←`.

```
T+0.0s  request received (800 MB payload)
T+0.3s  buffer allocated, no size cap
        └─ realloc loop begins
T+4.1s  RSS crosses cgroup limit        ← OOM killer triggers
T+4.1s  worker killed (SIGKILL)
```

Skip visualization when a short causal chain is clearer without it.

---

### 3. Separate Evidence from Interpretation

| Claim | Status | Evidence pointer |
|---|---|---|
| Worker killed at T+4.1s | Verified | `kern.log:2847`, `14:03:22.481` |
| Buffer has no size cap | Verified | `buffer.c:87@a1b2c3` |
| 800 MB × 2.6 growth factor triggers kill | Derived | `buffer.c:91`, formula applied to `kern.log` RSS trace |
| Unbounded growth causes the kill | Inference | causal chain, step 4 |
| Memory fragmentation adds overhead | Hypothesis | no profiler data |

**Status labels:**

- **Verified** — directly readable from logs, code, test output, or tool
- **Derived** — mechanically calculated from verified observations; not a judgment call (e.g., `800 MB × 2.6 = 2.08 GB > 2 GB limit`)
- **Inference** — interpretation connecting multiple verified or derived facts
- **Hypothesis** — consistent with evidence but missing a key observation
- **Contradicted** — evidence runs against this claim

When uncertain, use the lower-confidence label.

---

### 4. Trace the Causal Chain

Every material transition needs the most precise stable pointer available:

| Priority | Pointer type |
|---|---|
| Best | `file:line@commit`, or symbol + file + commit |
| Good | log timestamp or event ID; packet or frame number |
| Acceptable | test command + relevant output; metric + time window |
| Fallback | document section or screenshot region |

**Never invent a location. State the evidence gap when no pointer exists.**

```
1. http.c:203@a1b2c3  parse_request
   payload size unchecked → passed directly to allocate_buffer()

2. buffer.c:87@a1b2c3  allocate_buffer
   realloc() loop with no upper bound

3. buffer.c:91@a1b2c3
   growth factor 2.6× applied on each resize

4. kern.log:2847
   RSS exceeds cgroup limit → SIGKILL sent to worker

5. ∴ large payloads deterministically exhaust RSS  [Inference]
```

Steps 1–4 are source-backed. Step 5 is an inference until an intervention test changes the outcome as predicted.

---

### 5. Challenge the Preferred Explanation

**Before finalizing confidence**, record all four items:

- Strongest alternative explanation
- Evidence against that alternative
- Contradictory or non-reproducing samples
- The single observation or experiment that would falsify the preferred conclusion

```
Preferred:     Unbounded buffer growth on large uploads causes OOM.
Alternative:   Long-running connection pool leaks memory over time.
Against alt:   Fresh process with zero prior connections crashes on first large request.
Contradicts:   Requests under 10 MB never trigger the kill, even after 1000 requests.
Falsifier:     Adding a size cap to allocate_buffer() does not prevent the crash.
```

**If you cannot name a falsifier, confidence may not exceed Possible.**

When a trigger occurs 20 times and failure occurs once, lower confidence to **Possible** until the additional condition is identified. Do not recommend a fix at **Possible** or **Insufficient**; recommend the next discriminating test instead.

**After completing this section, revise the verdict in step 1.** If contradictions or the falsifier weaken the preferred explanation, lower the confidence label before proceeding.

---

### 6. Drive Action

| Priority | Action | Entry point | Risk | Verification |
|---|---|---|---|---|
| Recommended | Cap buffer at config limit | `buffer.c:87@a1b2c3` | rejects payloads above limit with 413 | large upload returns 413; worker stays alive |
| Diagnostic | Log RSS per request | `http.c` middleware | logging overhead | confirm growth profile matches prediction |
| Reject | Raise cgroup limit | deploy config | masks root cause | use only as emergency mitigation |

**Confidence is Possible or Insufficient?** Replace "Recommended" with "Next discriminating test." Do not prescribe a speculative patch.

If no safe fix is currently supported by evidence, recommend only the test that would move confidence to **Probable**.

---

## Minimum Report (Small Investigations)

1. Revised verdict with final confidence
2. Verified evidence and inference label for the main claim
3. Strongest alternative or explicit evidence gap
4. Recommended action or next discriminating test
5. Verification criteria

Tables and diagrams are conditional. These five items are not.

---

## Common Mistakes

| Mistake | Correction |
|---|---|
| Verdict finalized before step 5 | Complete step 5 first; revise confidence label after |
| Temporal adjacency treated as causation | Confidence ≤ Possible without intervention evidence |
| Only supporting samples shown | Include contradictions and non-reproducing cases |
| Inference labeled Verified | Use the lower-confidence label |
| Fix recommended at Possible/Insufficient | Recommend discriminating test instead |
| `file:line` asserted without reading | Read it in Claude Code, or state the evidence gap |
| Falsifier omitted | Name one, or cap confidence at Possible |
| "Less consistent" stated without specifics | State which evidence contradicts the alternative and why |
