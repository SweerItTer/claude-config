# Agent Entry Index

## Startup

- Session resume -> `~/.claude/agents/progress.md`
- Git conventions -> `~/.claude/agents/git.md`
- Rules index -> `~/.claude/rules/README.md`

## Routing

### Planning and architecture
- planning, implementation plan, decomposition, phases, risks -> `~/.claude/agents/planner.md`
- architecture, system design, boundaries, scalability -> `~/.claude/agents/architect.md`

### Development workflow
- tdd, tests first, red-green-refactor, coverage -> `~/.claude/agents/tdd-guide.md`
- code review, maintainability, refactor advice, quality gate -> `~/.claude/agents/code-reviewer.md`
- documentation, codemaps, README refresh, docs drift -> `~/.claude/agents/doc-updater.md`
- dead code, cleanup, simplification -> `~/.claude/agents/refactor-cleaner.md`

### Security and validation
- security, auth, secrets, input validation, OWASP, pre-commit security -> `~/.claude/agents/security-reviewer.md`
- end-to-end, browser flow, Playwright, regression path -> `~/.claude/agents/e2e-runner.md`

### Build and failure recovery
- build failure, type error, compile error, broken pipeline -> `~/.claude/agents/build-error-resolver.md`
- loop execution, repeated validation loop, stall monitoring -> `~/.claude/agents/loop-operator.md`
- harness config, reliability tuning, cost tuning, throughput -> `~/.claude/agents/harness-optimizer.md`

### Language or stack specialists
- TypeScript, JavaScript review -> `~/.claude/agents/typescript-reviewer.md`
- Python review -> `~/.claude/agents/python-reviewer.md`
- Go review -> `~/.claude/agents/go-reviewer.md`
- Rust review -> `~/.claude/agents/rust-reviewer.md`
- Java, Spring review -> `~/.claude/agents/java-reviewer.md`
- Kotlin, Android, KMP review -> `~/.claude/agents/kotlin-reviewer.md`
- C, C++ review -> `~/.claude/agents/cpp-reviewer.md`
- PostgreSQL, Supabase, schema, query review -> `~/.claude/agents/database-reviewer.md`

### Stack-specific build specialists
- Go build failure -> `~/.claude/agents/go-build-resolver.md`
- Rust build failure -> `~/.claude/agents/rust-build-resolver.md`
- Java build failure -> `~/.claude/agents/java-build-resolver.md`
- Kotlin or Gradle build failure -> `~/.claude/agents/kotlin-build-resolver.md`
- C or C++ build failure -> `~/.claude/agents/cpp-build-resolver.md`
- PyTorch, CUDA, training runtime failure -> `~/.claude/agents/pytorch-build-resolver.md`

### Documentation lookup
- API docs, library docs, reference lookup -> `~/.claude/agents/docs-lookup.md`

## Responsibility Routing

- Main agent: requirements decomposition, branch orchestration, subtask dispatch, checkpoint review, blocker escalation
- Specialist agent: implementation workflow, review workflow, stack-specific diagnosis, domain-specific validation
- If multiple domains are independent, run agents in parallel
- If a task touches security-sensitive code, route through `security-reviewer.md` before completion

## Layering Notes

- This file routes to agent entries only
- Rules live under `~/.claude/rules/`
- Detailed behavior, checklists, and examples stay in the leaf agent or leaf rule docs
- Do not duplicate leaf content here; use this file to find the correct entry point quickly
