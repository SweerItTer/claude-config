# Research Corpus

## Contents

- Recommended structure
- Research brief
- Source records
- Evidence records
- Claim records
- Conflict records
- Pattern records
- Report and archiving

## Purpose

Persist research so another agent can audit, extend, or reuse it without repeating discovery.

## Recommended structure

```text
research-<work-or-topic>/
├── brief.md
├── sources.md
├── evidence.md
├── claims.md
├── conflicts.md
├── patterns.md
├── report.md
└── archive/                 # optional; only when the environment can legally/save source snapshots
```

Use Markdown by default for portability. Use JSONL instead when the surrounding system already provides structured corpus tooling.

## brief.md

Record:

- target work(s);
- research questions;
- scope and exclusions;
- version/edition/DLC/adaptation;
- spoiler policy;
- output language;
- date of research.

## sources.md

One source record per source:

```text
S001
Title:
Author/Speaker:
Publisher/Channel:
Date:
URL:
Tier: S|A|B|C|D
Source type: official|talk|interview|article|wiki|forum|video|podcast|other
Scope:
Access notes:
```

Do not inflate the source count with mirrors or articles that merely repeat the same original.

## evidence.md

One record per useful observation:

```text
E001
Source: S001
Class: work-fact|creator-statement|audience-interpretation|analytical-input
Location: section / page / timestamp
Observation:
Supports: RQ1, RQ3
Confidence: high|medium|low
Notes:
```

Keep observations atomic enough that a later claim can cite only the evidence it needs.

## claims.md

```text
C001
Class: work-fact|creator-statement|audience-interpretation|analytical-inference
Claim:
Evidence: E001, E004
Counterevidence: E009
Confidence: high|medium|low
Conditions/limits:
```

An analytical inference must never masquerade as a creator statement.

## conflicts.md

```text
X001
Question:
Position A: C003 / E...
Position B: C011 / E...
Reason for conflict:
Resolution: resolved|partial|unresolved
Assessment:
```

## patterns.md

```text
P001 — <pattern name>
Mechanism:
Evidence basis: C...
Effect:
Conditions:
Failure modes:
Transfer rule:
Do-not-copy boundary:
```

Patterns are abstractions for design reuse, not scene recipes.

## report.md

The report is a readable synthesis derived from the corpus. It is not the corpus itself.

Every major conclusion in the report should be traceable to claim IDs or direct citations.

## Archiving

If the environment supports source snapshotting and the user wants a durable archive:

- save only material allowed by the active tools/site terms;
- keep the original URL and access date;
- prefer extracted relevant text/metadata over unnecessary full-site copies;
- do not archive merely to bypass access controls or paywalls.
