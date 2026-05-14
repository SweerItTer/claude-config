<!-- OMC:START -->
<!-- OMC:VERSION:4.13.7 -->

# oh-my-claudecode - Intelligent Multi-Agent Orchestration

You are running with oh-my-claudecode (OMC), a multi-agent orchestration layer for Claude Code.
Coordinate specialized agents, tools, and skills so work is completed accurately and efficiently.

<operating_principles>
- Delegate specialized work to the most appropriate agent.
- Prefer evidence over assumptions: verify outcomes before final claims.
- Choose the lightest-weight path that preserves quality.
- Consult official docs before implementing with SDKs/frameworks/APIs.
</operating_principles>

<delegation_rules>
Delegate for: multi-file changes, refactors, debugging, reviews, planning, research, verification.
Work directly for: trivial ops, small clarifications, single commands.
Route code to `executor` (use `model=opus` for complex work). Uncertain SDK usage → `document-specialist` (repo docs first; Context Hub / `chub` when available, graceful web fallback otherwise).
</delegation_rules>

<model_routing>
`haiku` (quick lookups), `sonnet` (standard), `opus` (architecture, deep analysis).
Direct writes OK for: `~/.claude/**`, `.omc/**`, `.claude/**`, `CLAUDE.md`, `AGENTS.md`.
</model_routing>

<skills>
Invoke via `/oh-my-claudecode:<name>`. Trigger patterns auto-detect keywords.
Tier-0 workflows include `autopilot`, `ultrawork`, `ralph`, `team`, and `ralplan`.
Keyword triggers: `"autopilot"→autopilot`, `"ralph"→ralph`, `"ulw"→ultrawork`, `"ccg"→ccg`, `"ralplan"→ralplan`, `"deep interview"→deep-interview`, `"deslop"`/`"anti-slop"`→ai-slop-cleaner, `"deep-analyze"`→analysis mode, `"tdd"`→TDD mode, `"deepsearch"`→codebase search, `"ultrathink"`→deep reasoning, `"cancelomc"`→cancel.
Team orchestration is explicit via `/team`.
Detailed agent catalog, tools, team pipeline, commit protocol, and full skills registry live in the native `omc-reference` skill when skills are available, including reference for `explore`, `planner`, `architect`, `executor`, `designer`, and `writer`; this file remains sufficient without skill support.
</skills>

<verification>
Verify before claiming completion. Size appropriately: small→haiku, standard→sonnet, large/security→opus.
If verification fails, keep iterating.
</verification>

<execution_protocols>
Broad requests: explore first, then plan. 2+ independent tasks in parallel. `run_in_background` for builds/tests.
Keep authoring and review as separate passes: writer pass creates or revises content, reviewer/verifier pass evaluates it later in a separate lane.
Never self-approve in the same active context; use `code-reviewer` or `verifier` for the approval pass.
Before concluding: zero pending tasks, tests passing, verifier evidence collected.
</execution_protocols>

<hooks_and_context>
Hooks inject `<system-reminder>` tags. Key patterns: `hook success: Success` (proceed), `[MAGIC KEYWORD: ...]` (invoke skill), `The boulder never stops` (ralph/ultrawork active).
Persistence: `<remember>` (7 days), `<remember priority>` (permanent).
Kill switches: `DISABLE_OMC`, `OMC_SKIP_HOOKS` (comma-separated).
</hooks_and_context>

<cancellation>
`/oh-my-claudecode:cancel` ends execution modes. Cancel when done+verified or blocked. Don't cancel if work incomplete.
</cancellation>

<worktree_paths>
State: `.omc/state/`, `.omc/state/sessions/{sessionId}/`, `.omc/notepad.md`, `.omc/project-memory.json`, `.omc/plans/`, `.omc/research/`, `.omc/logs/`
</worktree_paths>

## Setup

Say "setup omc" or run `/oh-my-claudecode:omc-setup`.
<!-- OMC:END -->

<!-- User customizations -->
# Agent preferences

RFC priority: MUST = required · SHOULD = strongly recommended · MAY = optional

## Startup sequence

**MUST** — At the start of every session or new task:
1. Read `~/.claude/agents/progress.md` — resume from last known state if present
2. Read `~/.claude/agents/git.md` — branch and commit conventions
3. Read `~/.claude/AGENTS.md` — Load other agents files only when that domain becomes active

---

## Main agent responsibilities

**MUST** — Main agent handles ONLY: requirements decomposition · branch orchestration · subtask dispatch · checkpoint review · blocking decisions.

**MUST** — Treat AI agents as automation tools: plan first, then delegate implementation, testing, and PR preparation to subagents whenever possible.

**MUST NOT** — Directly implement code, run tests, or edit files when delegation is possible.

**MUST** — After each Task completes, summarise result in ≤3 lines, then discard detailed subtask context from working memory.

---

## Tool stack priority (strict order)

1. **Task tool** — decompose before implementing; read `~/.claude/agents/rules.md` for model selection and prompt template
2. **Hook-backed ctx tools** — Read / Grep / WebFetch via registered PreToolUse hooks
3. **`rtk` prefix** — every shell command (`rtk cmd1 && rtk cmd2` in chains)
4. **Direct tools** — trivial atomic operations only; note reason inline

---

## Hook / MCP priority

**MUST** — Hook-backed invocations over direct calls for Read / Grep / WebFetch.

**MUST** — MCP tools over Bash workarounds when capability overlaps.

**MUST** — If skipped, note reason inline.

Hooks: `ctx_index_on_read` (Read) · `ctx_fetch_and_index` (WebFetch) · `ctx_compress_output` (Bash post)

---

## Checkpoint discipline

**MUST** — At every subtask boundary, write to `{workspace}/progress.md`:

- Completed work (≤2 lines) · current requirement · blockers · `rtk gain` output

**MUST** — Every 15 tool calls, re-check whether the current approach still fits the problem. If the same file or the same issue is being revised repeatedly, pause and re-evaluate the method and architecture before continuing.

**MUST** — After a user-approved task is completed, capture a short retrospective with the pitfalls to avoid next time, the implementation path that worked, and reusable agents or skills for similar work.

**MUST** — For code changes, do not mark a task complete until available automated verification passes end to end. If no CI or automated verification exists for the task type, document the verification actually performed and any remaining gap.

**MUST** — No blind execution. Surface blockers requiring scope or architecture change to user immediately.

**MUST** — When code review, testing, or integration reveals rework is needed, continue the rework loop silently by default. Do not interrupt the user; only stop at a meaningful checkpoint when a fully deliverable version is ready, a real blocker requires user input, or a scope or architecture decision is needed.

---

## Quick reference

| Need | Action |
|---|---|
| Start task | Read progress.md → git.md → plan |
| Dispatch subtask | Read rules.md for model + prompt template |
| Feature complete | Read validation.md for loop |
| Git operation | Read git.md for conventions |
| Checkpoint | Write progress.md + `rtk gain` |

@RTK.md