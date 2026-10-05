---
name: research-cultural-works
description: Evidence-first web research for games and other cultural works, including discovering a reference set for an original project, character construction, relationships, plot structure, quest design, worldbuilding, environmental storytelling, themes, creator intent, and audience interpretation. Use when asked to find relevant games/films/novels/anime for creative research, investigate a specific work, collect current online sources, build a traceable research corpus, compare works, explain why a character or story technique works, or turn sourced observations into reusable design patterns. Treat retrieved web sources as evidence and do not use pretrained/internal knowledge as evidence for factual claims or creator intent.
---

# Research Cultural Works

## Overview

Build a traceable research corpus for cultural works from current external web sources, then analyze the work from evidence rather than memory. Separate what the work contains, what creators say they intended, what audiences interpret, and what the researcher infers.

## Core contract

Follow these rules for every research task:

1. Use current external sources as evidence. Use model knowledge only to form hypotheses, search terms, aliases, and likely source locations.
2. Never fill an evidence gap from memory. Mark the gap and search for it.
3. Separate four claim classes:
   - **work fact**: directly observable in the work or reliable canonical documentation;
   - **creator statement**: attributed to a named creator or official production source;
   - **audience interpretation**: attributed to critics, players, viewers, communities, or commentators;
   - **analytical inference**: the researcher's synthesis from cited evidence.
4. Never convert an interpretation into authorial intent without direct creator evidence.
5. Prefer primary and creator-proximate sources over summaries.
6. Record URLs, titles, publishers/authors, dates when available, and timestamps for audiovisual evidence.
7. Distinguish editions, patches, DLCs, remakes, localization differences, and adaptations when they can change the conclusion.
8. Preserve disagreement. Do not force conflicting sources into one answer.
9. Abstract reusable techniques instead of copying protected expression, dialogue, scenes, or distinctive plot sequences.
10. Match the output language to the user's language unless requested otherwise.

Read `references/source-policy.md` before source selection or when source quality is disputed.
Read `references/research-corpus.md` before building or updating a corpus.

## Select a research mode

Choose the smallest mode that matches the task:

- **Reference-set discovery** — start from an original project's themes, character dynamics, narrative problems, world rules, or desired player experience and find cultural works worth deeper study. Read `references/reference-set-discovery.md`.
- **Single-work deep dive** — investigate one work, character, quest, relationship, setting, or narrative technique using the main workflow below.
- **Comparative study** — research works independently, then compare them on shared mechanism-level dimensions.

Do not turn reference-set discovery into market or competitor analysis unless the user explicitly asks. Sales, audience size, monetization, store rankings, and commercial positioning are normally irrelevant to this skill.

## Workflow

### 1. Frame the research question

Convert broad requests into explicit research questions before searching.

Examples:

- Replace “research Cyberpunk 2077” with questions such as “How is Johnny Silverhand introduced, contradicted, and humanized?”
- Replace “why is the plot good?” with questions about tension, reversal, information release, choice, consequence, pacing, and emotional payoff.
- Replace “research the worldbuilding” with questions about environmental storytelling, institutions, economy, technology, social hierarchy, visual motifs, and diegetic information delivery.

Capture scope constraints that materially affect evidence: base game vs DLC, spoiler limits, language/localization, adaptation, character route, patch/version, and desired depth.

### 2. Build a source map

Before collecting many links, identify the source classes required for the question.

Default source map:

- work/canonical material;
- official documentation, scripts, codices, guides, databases, or published setting material;
- named developer/writer/director interviews;
- GDC or equivalent professional talks and postmortems;
- official streams, podcasts, panels, and commentary;
- reputable specialist journalism and criticism;
- reference wikis for navigation and fact lookup;
- audience analysis, video essays, forums, and community discussions when reception or interpretation matters.

Do not treat every class as mandatory. Select only classes that can answer the research question.

### 3. Search breadth-first

Start broad enough to discover terminology, creators, quest names, production roles, and source hubs. Then search using discovered names and vocabulary.

Use query families rather than one repeated query:

- work + topic;
- work + creator + interview/talk/postmortem;
- character/quest/scene + writer/designer;
- work + narrative design / quest design / cinematic design / environmental storytelling;
- site-restricted searches for official sites, GDC, developer channels, or specialist outlets;
- exact phrases found in promising secondary sources to locate the primary source.

Use `references/search-playbook.md` for query expansion, source discovery, and stopping rules.

### 4. Harvest sources selectively

Open promising sources and determine whether each source contributes unique evidence.

For long pages, videos, podcasts, streams, or transcripts:

- locate the relevant section before extracting evidence;
- preserve timestamps or section anchors;
- prefer the original upload/transcript when available;
- do not summarize an entire multi-hour source when only a small section is relevant.

Reject duplicated rewrites, SEO summaries, unsourced listicles, and AI-generated summaries as evidence when a better source is available.

### 5. Build evidence records

Create one evidence record per independently useful observation, not one giant summary per source.

Each record must contain:

- evidence ID;
- source ID;
- claim class;
- concise observation;
- location/timestamp;
- confidence;
- exact research question(s) it supports;
- notes on ambiguity, versioning, or contradiction.

Use the schemas in `references/research-corpus.md`.

### 6. Form claims from evidence

Create claims only after evidence exists.

For every important claim:

- link the supporting evidence IDs;
- label the claim as fact, creator statement, audience interpretation, or analytical inference;
- state confidence;
- list counterevidence or competing explanations when material;
- avoid causal wording when the evidence only shows correlation or sequence.

Create a conflict record when credible sources disagree.

### 7. Analyze the work

Select only the relevant analytical lenses. Do not mechanically fill every category.

Available lenses include:

- character construction and arc;
- relationships and intimacy;
- plot and dramatic structure;
- quest and interactive narrative design;
- choice and consequence;
- worldbuilding and institutions;
- environmental storytelling;
- exposition and information release;
- theme, motif, symbolism, and philosophical framing;
- scene construction, staging, perspective, and player/viewer agency;
- reception gaps between intended and experienced effects.

Read `references/narrative-analysis.md` for the question sets and failure modes for each lens.

### 8. Derive reusable patterns

Only after the evidence and analysis stages, convert findings into reusable design knowledge.

For each pattern, write:

- **pattern**: abstract mechanism;
- **evidence basis**: which claims support it;
- **effect**: what experience it tends to produce;
- **conditions**: when it works;
- **failure mode**: how it can fail;
- **transfer rule**: what can be reused without copying the original expression.

Prefer mechanisms such as “delay sympathetic context until after a negative first impression” over scene-level imitation.

### 9. Check gaps and saturation

Before final synthesis, ask:

- Does every major factual claim have external evidence?
- Is creator intent supported by creator-proximate evidence?
- Are important counterexamples or conflicting interpretations represented?
- Are multiple articles merely repeating the same original source?
- Would another search likely change the conclusion, or only add duplicates?

Stop when new searches mostly reproduce existing evidence and the remaining gaps are explicitly documented.

### 10. Produce the research output

Default to a research dossier rather than a generic essay.

Include, as relevant:

1. Research scope and questions
2. Source map and source-quality notes
3. Findings organized by research question
4. Character/plot/worldbuilding analysis
5. Conflicts and uncertainties
6. Reusable design patterns
7. What should not be generalized
8. Evidence/source index
9. Open questions for later research

For a persistent corpus, use the folder and record formats in `references/research-corpus.md`.
For concise one-off answers, keep the same evidence discipline without creating files unless requested.

## Comparison tasks

When comparing two or more works:

1. Define shared comparison dimensions before gathering conclusions.
2. Research each work independently enough to avoid using one work as the default frame for the other.
3. Distinguish shared technique from similar surface content.
4. Compare mechanisms, constraints, and effects, not only themes or plot events.
5. Record asymmetric evidence quality; do not imply parity when one work has much stronger creator documentation.

## Tool behavior

Use the best available web search, browser, transcript, archive, or page-extraction tools in the active environment. Do not require a specific MCP server or vendor.

When a tool cannot access a source:

- record the inaccessible source as a lead, not evidence;
- search for an official mirror, transcript, quoted primary material, or archived copy;
- never invent the missing content.

If the environment offers local files supplied by the user, use them only when the user explicitly allows them for the research task. The default evidence policy for this skill is web-first external sourcing.

## References

- `references/source-policy.md` — source hierarchy, evidence rules, provenance, and conflict handling.
- `references/reference-set-discovery.md` — build a diverse, researchable set of works from an original project idea without drifting into market analysis.
- `references/search-playbook.md` — search strategy, query families, discovery loops, and saturation.
- `references/research-corpus.md` — persistent corpus structure and record schemas.
- `references/narrative-analysis.md` — analytical lenses for characters, relationships, plot, quests, worldbuilding, and narrative technique.
- `references/output-patterns.md` — report structures and reusable pattern format.
