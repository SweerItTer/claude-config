# Repository governance mapping

Use one mapping when a coherent project taxonomy differs from the defaults. The mapping lets every bundled script evaluate the same responsibilities without forcing directory renames.

## Location

Use exactly one of:

1. `.project-governance.json` — preferred;
2. `docs/project-governance.json` — accepted when repository policy keeps configuration under `docs/`.

Two simultaneous mappings are Blocking. When no mapping exists, create at most one candidate in a config-only batch, validate it, then create a fresh workspace baseline before other writes.

## Schema

```json
{
  "version": 1,
  "canonical_instruction": "AGENTS.md",
  "governance_file": "documentation/handbook/governance.md",
  "paths": {
    "requirement": "documentation/requirements",
    "specs": "documentation/design",
    "dev_guide": "documentation/guides",
    "analysis": "documentation/investigations",
    "archive": "documentation/history",
    "todo": "documentation/TODO.md"
  }
}
```

## Validation rules

- every value is a non-empty repository-relative path;
- absolute paths and `..` are forbidden;
- the five directory mappings are pairwise non-overlapping both lexically and after Linux symlink resolution: none may equal, contain, or be contained by another in either view;
- each existing directory role is a real directory or is absent; a category directory must not itself be a symbolic link;
- `todo`, `governance_file`, and `canonical_instruction` are ordinary non-executable, non-hard-linked documentation files using `.md`, `.markdown`, `.rst`, or `.txt`, or are absent; configuration fields never relabel build/source/linker/board/tool files as governance documents;
- file roles do not reuse or contain one another in either lexical or symlink-resolved path space;
- a file role may live inside a category directory, but it may not equal or be an ancestor of a category directory;
- every existing ancestor of a configured target is a directory;
- all six `paths` keys are required;
- `canonical_instruction` is optional;
- `governance_file` defaults to `docs/dev-guide/document-governance.md` when omitted;
- the mapping describes responsibilities, not tool-specific preferences;
- explicitly mapped governance directories always take precedence over generic build-output exclusions, even when a legal directory is named `dist` or begins with `build`, `install`, or `dist`.

Lexical checks are not sufficient. Every mapping, default path, governance file, canonical instruction, and configuration file must also resolve inside the repository after following existing symlink ancestors. The resolved directory-and-file role graph is compared as a second taxonomy: category equality/ancestor overlap and file-role equality/containment are Blocking even when the configured strings differ. Existing hard-linked role files are also rejected.

Unsafe example:

```text
repo/documentation -> /tmp/external-docs
paths.specs = documentation/design
```

Although the JSON path is relative, its real destination is external. Treat this as Blocking. Do not bootstrap, do not fall back to default paths, and do not create files outside the repository.

Configuration loading validates every role and existing target before Bootstrap performs its first write. `bootstrap_docs.py` then rechecks containment immediately before every directory creation and file write.

## Recognition workflow

Before creating a mapping:

1. inspect existing documentation and contributor rules;
2. confirm that each category has a stable responsibility;
3. confirm mapped paths are not temporary build output or scratch space;
4. validate symlink-resolved containment and pairwise physical non-overlap;
5. record the mapping in the governance guide;
6. rerun inventory and audit.

Create the file only when the mapping is high-confidence.

## Default fallback

When no mapping exists, scripts use:

```json
{
  "governance_file": "docs/dev-guide/document-governance.md",
  "paths": {
    "requirement": "docs/requirement",
    "specs": "docs/specs",
    "dev_guide": "docs/dev-guide",
    "analysis": "docs/analysis",
    "archive": "docs/archive",
    "todo": "docs/TODO.md"
  }
}
```

Default paths receive the same symlink-resolved containment checks as custom paths.

Missing defaults without a mapping are “undeclared or incomplete,” not proof that the project must adopt them.

## Command use

All bundled scripts auto-detect the mapping:

```bash
python3 "$SKILL_DIR/scripts/audit_docs.py" --repo . --config .project-governance.json
```

## Canonical instruction authority

`canonical_instruction` declares the authoritative repository instruction file. It does not make arbitrary competing files safe. Any additional `AGENTS.md` or `CLAUDE.md` must be one of:

- a filesystem symlink to the canonical file inside the repository;
- a strict one-purpose adapter whose target resolves from the adapter location to the exact configured repository-relative canonical path;
- an identical copy, which is reported as drift-prone and should be replaced.

A file that merely contains the canonical basename while adding other rules—or points that basename at a different location—is not an adapter. If the configured canonical file is missing, existing `AGENTS.md`/`CLAUDE.md` files are still audited for conflict. `Ignore AGENTS.md`, `CLAUDE.md overrides AGENTS.md`, and `Do not follow AGENTS.md` are Blocking conflicts.
