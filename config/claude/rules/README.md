# Rules Entry Index

Use this file as the routing index for the rules system, not as the full rules manual.

## Routing

- `rules/common/` -> universal baseline rules for all projects
- `rules/web/` -> web and frontend overlays on top of `common`
- `rules/typescript/` -> TypeScript and JavaScript overlays on top of `common`
- `rules/python/` -> Python overlays on top of `common`
- `rules/golang/` -> Go overlays on top of `common`
- `rules/swift/` -> Swift overlays on top of `common`
- `rules/php/` -> PHP overlays on top of `common`

## Keyword -> Entry File

### Core workflow
- agents, delegation, subagents, orchestration -> `rules/common/agents.md`
- development workflow, plan first, TDD, review order -> `rules/common/development-workflow.md`
- git, commit format, PR workflow -> `rules/common/git-workflow.md`
- testing, coverage, red-green-refactor -> `rules/common/testing.md`
- code review, severity levels, review checklist -> `rules/common/code-review.md`

### Core engineering standards
- coding style, immutability, naming, file size, error handling -> `rules/common/coding-style.md`
- patterns, repository pattern, API envelope, skeleton projects -> `rules/common/patterns.md`
- security, secrets, validation, auth checks -> `rules/common/security.md`
- performance, model selection, context management -> `rules/common/performance.md`
- hooks, PreToolUse, PostToolUse, Stop hooks -> `rules/common/hooks.md`

### Web and frontend overlays
- web coding style, semantic HTML, CSS variables, motion rules -> `rules/web/coding-style.md`
- web patterns, composition, state boundaries, URL state -> `rules/web/patterns.md`
- web testing, visual regression, accessibility, responsive checks -> `rules/web/testing.md`
- web security, CSP, headers, form protections -> `rules/web/security.md`
- web performance, CWV, bundle budgets, loading strategy -> `rules/web/performance.md`
- web design quality, anti-template guidance, style direction -> `rules/web/design-quality.md`
- web hook recommendations, formatter/lint/type-check order -> `rules/web/hooks.md`

## Layering Rules

- Baseline first: start from `common`
- Domain overlay next: apply `web` when the task is frontend or web-specific
- Language overlay next: apply the relevant language directory when present
- Conflict rule: the more specific layer overrides the more general layer

## Installation Entry

### Install script
- install common plus selected overlays -> `./install.sh <rule-set...>`
- examples: `./install.sh typescript`, `./install.sh web`, `./install.sh typescript python`

### Manual install
- copy whole directories, not flattened file contents
- required baseline -> `cp -r rules/common ~/.claude/rules/common`
- optional overlays -> copy only the directories your project needs

## Extension Entry

- add a new language or domain by creating `rules/<name>/`
- keep the same leaf filenames where possible: `coding-style.md`, `testing.md`, `patterns.md`, `hooks.md`, `security.md`
- each overlay file should explicitly point back to its `../common/` counterpart
- keep full explanations in leaf docs, not in this index

## Rules vs Skills

- `rules/` -> standards, guardrails, checklists, required workflow
- `skills/` -> deeper how-to material and implementation guidance
- Use this index to find the rule source; use skill docs for extended execution detail
