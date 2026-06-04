# Executor Throttle Policy (Haiku Rate-Limit Mitigation)

Applied unconditionally when Haiku is in the Tier-3 slot.

- **Batch before dispatch** — group sequential atomic tasks into one prompt (max 5 sub-tasks)
- **Retry with delta only** — failed task: original context + failure reason; never cold-start
- **Pre-validate clarity** — ambiguous task → clarify with Tier-1 before dispatching
- **Cool-down gate** — rate-limit error: wait 60s; after 3 errors → switch to fallback model, notify Tier-1
- **Token discipline** — Tier-3 prompt: task spec + minimal code context + constraints only; no project-wide context
