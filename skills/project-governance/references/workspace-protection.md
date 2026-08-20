# Workspace protection

Project Governance can move and rewrite documentation, so existing user work, Git state, submodules, and nested Git worktrees stay outside its authority.

## 1. Applicability

Use `workspace_guard.py` only for Git-backed Takeover, Bootstrap, or write-capable Targeted maintenance on Linux.

- Audit creates no guard state and performs no writes.
- Non-Git automation is limited to read-only audit and creation-only bootstrap unless weaker guarantees are explicitly accepted.
- The current write profile is deliberately conservative: governance documents in Linux-hosted C/C++ embedded repositories. This is a product/safety profile, not a claim that taxonomy or lifecycle concepts are C/C++-specific.

## 2. Guard-state model

Create the state file outside the repository:

```bash
BASELINE="$(mktemp -t project-governance-baseline.XXXXXX.json)"
python3 "$SKILL_DIR/scripts/workspace_guard.py" snapshot --repo . --output "$BASELINE"
```

The file contains two conceptually separate regions:

```json
{
  "version": 10,
  "snapshot": { "...": "capture-time repository state" },
  "snapshot_sha256": "sha256(canonical snapshot JSON)",
  "authorization": { "...": "approved write-plan state" }
}
```

### `snapshot`: immutable

Captured once before the first write. It includes the repository identity, HEAD/branch, pre-existing dirty or index-hidden work, complete Git index/flag state, and clean submodule boundaries. `snapshot_sha256` seals this region. `check-plan` and `verify` reject a file whose immutable snapshot hash no longer matches.

### `authorization`: mutable

`check-plan` may append approved lexical/resolved file or directory scopes, lazily enrolled ignored-path fingerprints, the bound governance configuration, and an authorization revision. This state is mutable by design; it never rewrites the sealed snapshot.

A governance-configuration change after authorization has begun requires review and a **fresh snapshot/baseline file**. Do not edit either region by hand to continue a run.

The guard-state file itself must resolve outside the repository. `snapshot`, `check-plan`, and `verify` reject repository-owned state files.

## 3. What the immutable snapshot protects

The capture records enough state to detect changes to pre-existing work, including:

- staged, unstaged, and ordinary untracked paths;
- tracked paths hidden by `assume-unchanged` or `skip-worktree`;
- worktree existence, type, mode, bytes/hash, directory listing, symlink target, and physical-file identity where relevant;
- complete Git index entries: path, mode, blob OID, conflict stage, and extension flags;
- original staged/unstaged/untracked/index-hidden classification;
- resolved repository-relative targets after following existing symlink ancestors;
- HEAD and branch;
- initialized submodule boundary state: gitlink OID, HEAD/branch, complete nested index and flags, and clean/dirty status.

Ignored paths are not part of the capture-time snapshot unless already visible through another protected state. When a planned path intersects ignored content, `check-plan` fingerprints that content into the mutable authorization protection state before deciding whether the plan is safe.

A dirty initialized submodule blocks write-capable snapshot creation **even when it is outside the planned documentation scope**. A submodule with hidden index flags also blocks. This is a fail-closed no-touch policy, not recursive submodule editing support.

Non-submodule nested repositories and linked worktrees are unsupported in write-capable governance scope and fail closed.

## 4. Check every write batch

List every source and destination, then run:

```bash
python3 "$SKILL_DIR/scripts/workspace_guard.py" check-plan \
  --repo . --baseline "$BASELINE" --paths-from /tmp/project-governance-paths.txt
```

`check-plan`:

1. validates the current governance configuration;
2. compares lexical and resolved paths so aliases cannot bypass overlap checks;
3. detects ignored paths, submodules, nested Git markers, symlinks, hard links, and protected user work;
4. applies the explicit documentation whitelist;
5. on success, updates **only** the authorization region.

Authorization intent matters:

- **file**: only that exact lexical/resolved file is approved;
- **directory**: descendants are conditionally approved, but each actual changed file must independently pass the document whitelist.

## 5. Documentation whitelist

This is a whitelist, not a source-code blacklist. Ordinary writable files must be non-executable regular text documents whose lexical and resolved names end in:

```text
.md
.markdown
.rst
.txt
```

TODO, governance, and canonical-instruction roles still obey the same document extensions. The selected governance JSON is the only non-text extension exception, at its exact configured path.

Everything else is denied by default. Important fail-closed cases include executable/shebang/binary content, symlink leaves, hard-linked files, unknown extensions, source/build/board/linker files, generated files, and paths inside or containing a submodule or nested worktree.

An approved directory is not a wildcard: existing contents are checked before approval and every changed descendant is checked again during verification.

## 6. Verify after every batch

```bash
python3 "$SKILL_DIR/scripts/workspace_guard.py" verify --repo . --baseline "$BASELINE"
```

`verify` must succeed before continuing or declaring Takeover complete. It verifies, among other boundaries:

- protected worktree/index/classification state remains unchanged;
- the sealed immutable snapshot still matches `snapshot_sha256`;
- every new change is covered by approved authorization and still satisfies the document whitelist;
- no new ignored side effect appears in approved scope;
- the complete Git index and index flags remain unchanged, including intent-to-add;
- HEAD and branch remain unchanged;
- clean submodule boundaries remain clean and unchanged;
- no unsupported nested Git topology or physical-file alias is entered.

Any automatic staging, commit, branch change, unplanned edit, non-document side effect, invalid/forked governance configuration, submodule mutation, or hidden ignored output is Blocking.

## 7. Failure handling

When `check-plan` or `verify` fails:

1. stop further writes;
2. do not perform destructive automatic rollback;
3. report the exact boundary crossed and relevant Git evidence;
4. leave the user's pre-existing work untouched;
5. ask for a decision only when safe non-overlapping work cannot continue.

## 8. Forbidden Git effects

Do not use `git add`, `git add -N`, `git commit`, `git stash`, `git clean`, `git reset`, `git restore`, branch checkout/switch, automatic push, or index-hiding flags as part of governance execution.
