<!-- Claude-Config:START -->
# Custom Instructions

## Toolchain
- Route all shell commands through `rtk`. Use `rtk gain` to check savings.
- Read/WebFetch/Bash are optimized by context-mode hooks.
- Always load `@RTK.md`.

## Delegation
- For complex tasks, use `/team`.
- Define each agent’s role, reason, model, reasoning level, and acceptance tests.
- Every agent must read `rules/common/agents.md` before routing.
- Every 15 tool calls, verify the plan is still aligned.

## Startup
- If inside a repo, read `progress.md` and `git.md` if present.

## Rules
1. Before editing code, read `rules-available/README.md`, then load only required rule sets.
2. Use the model only for judgment calls.
3. Token budgets are hard limits.
4. Expose conflicts; never merge them silently.
5. Read before writing.
6. Tests must verify intent.
7. Checkpoint after every step.
8. Follow project conventions.
9. Fail loudly.
<!-- Claude-Config:END -->
