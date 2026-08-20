# Documentation taxonomy and lifecycle

## 1. Classification by responsibility

Use the question the document answers.

| Question answered | Class |
|---|---|
| What behavior, constraint, or acceptance condition is required? | `requirement/` |
| How will the system be designed, and why was this approach selected? | `specs/` |
| How can another developer repeatedly build, debug, test, release, or operate it? | `dev-guide/` |
| What evidence was collected for a one-time question or incident? | `analysis/` |
| What is no longer active but must remain traceable? | `archive/` |

### Boundary examples

| Content | Class | Reason |
|---|---|---|
| Wi-Fi must reconnect within ten seconds | Requirement | Observable obligation |
| Reconnection state machine and rejected alternatives | Spec | Design and trade-off |
| How to capture `wpa_supplicant` logs | dev-guide | Repeatable procedure |
| Investigation of three reconnect failures | analysis | Evidence for one question |
| Implemented rollout plan retained for history | archive | No longer active work |

### Mixed documents

A document mixing requirements, design, commands, and raw logs should be split only when the boundaries are clear:

- promote required behavior to an R document;
- promote approved design and trade-offs to an S document;
- promote repeatable commands to a guide;
- retain evidence in analysis or archive.

Keep uncertain mixed documents intact and record a proposed split rather than silently changing meaning.

## 2. Stable IDs

Stable identity belongs to identity-bearing governance documents, not every filename that mentions an ID.

Identity-bearing documents are:

- Requirements under the configured Requirement path whose filename begins with `Rxx`;
- Specs under the configured Spec path whose filename begins with `Sxx`;
- archived Requirement or Spec documents whose filename begins with the preserved R/S ID.

Guides and analyses do not acquire identity merely by referencing another document in a filename. For example, `docs/dev-guide/S14-implementation-guide.md` is a guide about S14, not a second S14 Spec. Do not count it as a duplicate identity.

### Requirement IDs

- Use `R01`, `R02`, ... .
- IDs are repository-wide across Requirement subdirectories and archived Requirements.
- IDs never change because a file moves.
- Archived IDs are never reused.
- A requirement item may be referenced as `R03-4`.

### Spec IDs

- Use `S01`, `S02`, ... .
- IDs are repository-wide across active and archived Specs.
- Draft documents receive an ID; maturity is expressed by status.
- Important decisions are numbered `D1`, `D2`, ... and referenced as `S14-D7`.

Preserve the repository's existing width. If no scheme exists, begin with two digits and allow natural growth beyond 99 without renumbering old files.

## 3. Filename policy

A numbered filename begins with its stable ID:

Using the default mapping, examples are:

```text
docs/requirement/R03-network-behavior.md
docs/specs/S14-lines-model.md
```

With a custom mapping, keep the same stable-ID rule at the configured Requirement and Spec paths.

A repository using Chinese filenames or underscores may retain that coherent convention. Stable identity matters more than separator preference.

Do not encode lifecycle in filenames:

```text
*_v2.md
*_final.md
*_latest.md
*_new.md
```

Use Git history, status, and supersession instead.

## 4. Requirement metadata

Default lightweight frontmatter:

```yaml
---
title: Network behavior
created: 2026-08-05
source: internal
---
```

Allowed `source` values should be defined by the repository. Common values are `internal`, `customer`, and `external-standard`.

Add status only when the repository has a real Requirement lifecycle. Do not add fields merely to make the template look complete.

## 5. Spec metadata

Default frontmatter:

```yaml
---
title: Lines model
status: draft
kind: design
created: 2026-08-05
updated: 2026-08-05
owner:
supersedes:
related:
---
```

### Status lifecycle

```text
draft -> active -> implemented -> archived
             \-> archived
```

- `draft`: under discussion and not authoritative.
- `active`: approved and currently governing implementation.
- `implemented`: implementation landed; the document remains useful as design or verification history.
- `archived`: superseded, rejected, or no longer maintained.

A status transition is a substantive change and updates `updated`. Formatting-only or bulk migration work does not refresh `updated` unless the document's meaning or lifecycle changes.

### Kind

- `design`: long-lived architecture or design reference.
- `plan`: execution plan whose active value usually ends after implementation.

An implemented design may remain in the configured Spec directory while it accurately describes the system. An implemented plan normally moves to the configured archive after its useful execution window.

## 6. Decision records

Each consequential decision records:

- selected option;
- rejected alternatives;
- reason;
- boundary of applicability;
- reconsideration condition.

Example:

```markdown
### D7: Network runtime owns DHCP execution

**Selected:** Network runtime executes DHCP after an explicit API request.

**Rejected:** Starting DHCP automatically whenever Wi-Fi associates.

**Reason:** Association and address policy are separate responsibilities.

**Boundary:** Writable WAN and Wi-Fi interfaces; first-phase LAN remains read-only.

**Reconsider when:** Automatic recovery becomes a product requirement.
```

Do not elevate an informal note or investigation hypothesis into a decision record without evidence that it was approved.

## 7. Supersession

When a new governing document replaces an old one:

1. assign the new document a new stable ID;
2. set `supersedes` to the old ID;
3. mark the old document archived;
4. preserve the old file and Git history;
5. update references that mean “current governing rule.”

Do not overwrite history in place when later maintainers need the old boundary and rationale.

## 8. References

Use stable semantic references for R/S documents:

```text
S14《Lines model》
S14-D7
R03《Network behavior》
R03-4
```

Do not use a mutable path as the only identity. A relative Markdown link is valid navigation when the visible sentence or link label also includes the matching semantic ID, for example `S14《Lines model》：[文档](path/to/S14-lines-model.md)`. R/S identity must survive movement into archive.

## 9. TODO

The configured TODO file is a current work queue, not a history ledger. The default path is `docs/TODO.md`.

- Keep unfinished actionable work.
- Attach an acceptance condition, owner, issue, Requirement, or Spec when practical.
- Move completed history to `todo-history-YYYY-MM-DD.md` under the configured archive path.
- Keep session resume notes, raw thought trails, and unverified guesses out of the repository.
- Promote durable information before handoff:
  - required behavior -> Requirement;
  - approved design -> Spec decision;
  - repeatable procedure -> dev-guide;
  - unfinished verifiable work -> TODO.

## 10. Archive

Archive preserves history; it is not a trash bin.

- Move rather than delete.
- Preserve stable IDs.
- Mark numbered lifecycle documents archived.
- Avoid rewriting historical prose for current style.
- Pointer metadata such as `superseded_by` may be maintained when it improves traceability.
- New active rules must not live only in archive.
