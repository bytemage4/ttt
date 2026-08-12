# Feeding Team Knowledge to a Domain Plugin

An implementation guide for turning Confluence spikes into a scoped, PR-gated knowledge layer for a Claude Code plugin used in day-to-day development and code review.

---

## 1. The shape of the solution

The question "feed spikes directly or distill them?" resolves into neither. What works is a **layered store** where each layer has a distinct lifecycle, a distinct authority level, and a distinct loading trigger.

| Layer | Content | Size | Loaded |
|---|---|---|---|
| **Core** | Terminology, hard invariants, system-wide requirements | ~1 page, laminated-card scale | Always |
| **Index** | One line per decision: `id`, `strength`, rule, `applies_to` | Cheap, grows linearly | Always |
| **Entries** | Full decision record: rule, scope, exclusions, negative instances | ~30 lines each | When globs intersect the diff |
| **Rationale** | The "why", extracted from spikes | Paragraphs to pages | When a decision is questioned or extended |
| **Archaeology** | The spike itself, in Confluence | Unbounded | Rarely, by explicit link |

This is progressive disclosure — the same principle the skill mechanism is built around. Spikes map onto it badly as whole documents but well once split by **kind of claim** rather than by document boundary.

One spike typically yields several entries. One entry may draw on several spikes. Neither is a one-to-one mapping, which is why the spike itself is not the unit of ingestion.

### Where the ADR pattern fits

Keep spikes as spikes: narrative, exploratory, human-facing. Do not retrofit them into ADR format.

What the ADR pattern contributes is its **fields** — explicit status, supersession pointer, and a structural separation of context / decision / consequences. Those fields live in the distilled entry. **The frontmatter is the ADR; the spike is its cited source.**

The ADR format exists because human teams hit this exact problem a decade before agents did: new joiners reading old design docs and implementing the rejected option. The agent version is the same problem with worse recall of narrative context.

---

## 2. Problems this design has to solve

### 2.1 Deliberation and decision are indistinguishable once chunked

This is the central hazard, and it attaches specifically to the content that is most valuable — the write-up of thinking through a problem to a solution.

A spike working through a problem contains rejected options argued for persuasively, in the present tense. Pull a paragraph from the middle of "Options considered" and it reads exactly like a recommendation. Feeding spikes whole does not preserve the narrative arc that makes the rejection legible: the agent sees a retrieved fragment, not a document.

**Consequence:** every claim needs an explicit authority marker, and that marking *is* the distillation step. It cannot be inferred at retrieval time.

### 2.2 Freshness checks run in the wrong direction

Comparing modification times catches "the Confluence page changed and we are behind." The dangerous case is the page **did not change**: the decision was superseded in a PR discussion, a later spike, or an incident review, and nobody edited the old page. It shows green forever.

Related: spike 12 supersedes spike 7, nobody edits spike 7, and the agent now holds two confidently-stated contradictory positions with no tiebreaker.

**Mitigations:**
- Supersession is recorded explicitly in the entry, not inferred.
- The curated layer is the only thing with authority. Spikes are sources, not truth.
- Track `last_confirmed` (against code) separately from `last_synced` (against Confluence). They answer different questions.

### 2.3 Rationale gets over-applied

Agents given a "why" invoke it outside its scope. The exception-framework reasoning surfaces in a review comment about a build script; the one service that legitimately opted out gets flagged every time.

This is **not** an argument against providing rationale. Over-application is a property of *unscoped* claims. The counterfactual is not a quiet agent — it is an agent producing generically-correct review comments (null checks, naming, "consider extracting a method") that reviewers skim past. That failure is more common and harder to detect, because nothing looks wrong.

The trade is a silent failure for a loud one. Loud ones are measurable against the acceptance heuristic: does a human post the comment under their own name? False positives cost reviewer trust much faster than silence does, so they must be controlled — by scoping, per §3.

### 2.4 Confluence is an input surface

Lower risk when the tracked pages are deliberately selected and carefully curated, and near-zero once ingestion is PR-gated. Two residuals survive:

- "Carefully curated" describes today's version and today's curators. Edit rights are usually much broader than that set. Pin the source version; a version bump requires re-approval rather than silent acceptance.
- Page **comments** often hold the correction that never made it into the body. Ignoring them loses real signal — but they are also the least curated part of the page. Read them during extraction, surface them to the human reviewer, never ingest them unreviewed.

Text in a wiki page is data, never instruction. Enforce that at ingestion rather than hoping for it. While ingesting, also scan for what should not leave Confluence at all: pasted payloads, customer identifiers, credentials in a debugging section. The plugin's service account almost certainly reads more spaces than any individual developer.

### 2.5 Nothing tells you whether adding a spike helped

Without a measurement, the knowledge base only grows, and "how large should it be?" stays unanswerable in principle.

Build a frozen set of PRs with known-good review outcomes and diff performance with and without each candidate document. Most additions will be neutral. Some will be **negative through dilution** — every token of domain lore competes for attention with the diff under review, and irrelevant retrieved context measurably hurts rather than being merely inert.

### 2.6 Ownership of the distilled layer

- Fully generated → regeneration produces diffs nobody reviews.
- Fully handwritten → drifts from the spikes.
- **Reviewed artifact** → LLM-assisted extraction, human-approved via PR. This is the version that works, and it gives supersession somewhere to be recorded.

Since the compiled files should not be versioned inside the plugin repo, the existing memory banks are the natural home. The plugin depends on them rather than embedding them.

---

## 3. Scoping

### 3.1 Push everything mechanizable out of the knowledge base first

In a Java shop, most exception-framework invariants are ArchUnit rules. Several Kafka structural constraints are schema-registry compatibility settings or a custom Error Prone check.

Anything a deterministic check can catch should be caught there — and then **explicitly marked in the entry as already gated**, so the agent does not duplicate CI in prose.

What remains for the LLM layer is the genuinely non-static: is this the right event to emit at all, does this name match our terminology, does this change break an invariant that spans services. This cut alone removes a large part of the over-application surface, because the entries most prone to misfiring are usually the structural ones.

### 3.2 Scope by path and symbol, not by prose

If `applies_to` reads "our REST-facing services", the agent must judge membership — and membership judgement under uncertainty is exactly where false positives come from. Globs and trigger symbols are checkable against the diff.

```markdown
---
id: EXC-001
status: accepted                    # accepted | superseded-by: EXC-004 | deprecated
strength: invariant                 # invariant | default | preference
applies_to:
  - "services/*/src/main/java/**/web/**"
  - "services/*/src/main/java/**/api/**"
excludes:
  - "services/legacy-billing/**"    # opted out, rationale §4
  - "**/testFixtures/**"
triggers: ["@ExceptionHandler", "ResponseEntity<ErrorResponse", "throw new"]
enforced_by: "ArchUnitTest#domainExceptionsOnly"   # CI gates this — do not comment
source: confluence:SPIKE-142@v9
rationale: rationale/EXC-001.md
last_confirmed: 2026-07-14
---

**Rule.** One imperative sentence.

**Why.** Four sentences, or a pointer to the rationale file.

**Do not raise when.** The PR description cites an EXC-001 exemption;
the change is confined to `**/internal/**`; the handler is being deleted.
```

Two properties of this schema are worth designing for deliberately:

- **`applies_to` is simultaneously the correctness constraint and the retrieval key.** The index holds only `id`, `strength`, rule, and `applies_to`; entry bodies load only for entries whose globs intersect the changed paths. Scoping and context budget turn out to be the same mechanism.
- **`source: SPIKE-142@v9` makes the freshness check compatible with the PR gate.** Sync compares the live Confluence version against the pin; on drift it flags the entry and opens a PR, rather than overwriting curated text.

### 3.3 Separate strength from scope

Most of the damage from over-application is not wrong content — it is a preference delivered in the register of an invariant. Make `strength` govern the speech act explicitly in the plugin prompt:

| `strength` | Agent behaviour |
|---|---|
| `invariant` | State plainly as a defect. |
| `default` | Ask for justification, phrased as a question. |
| `preference` | Do not raise unless the PR author asked for style feedback. |

Be stingy with the top tier. Demote aggressively in review.

If an entry cannot be written with a concrete `applies_to`, it is not a decision yet — it is a value. Values belong in the always-loaded core page, not in the review path.

### 3.4 Negative instances

Treat `Do not raise when` as load-bearing, not boilerplate. Negative instances constrain behaviour considerably better than hoping a positive scope is read narrowly.

It is also the natural home for the exception discovered the first time the agent misfires — which makes misfires productive rather than merely annoying.

---

## 4. Workflow

### 4.1 Registry

A `spikes.yaml` in the plugin repo lists **only** the tracked pages:

```yaml
- id: SPIKE-142
  page_id: "123456789"
  title: "Exception handling across microservices"
  ingested_version: 9
  entries: [EXC-001, EXC-002, EXC-005]
```

Adding a page here is itself a PR. This is where "not every Confluence page is tracked" gets enforced structurally rather than by discipline.

### 4.2 Extraction (new spike)

A command — `/distill SPIKE-142` — fetches the page and runs two passes:

**Pass 1 — classify.** Each section is labelled `normative` / `rationale` / `archaeology` / `rejected-option`. Rejected options are tagged explicitly so nothing from them can become a rule.

**Pass 2 — emit.** Candidate entries are generated from `normative` sections only, with rationale linked rather than inlined.

**Grounding requirement:** the extraction agent must leave `applies_to` empty when it cannot ground the scope in real paths. Allowing it to guess produces plausible globs that match nothing and fail silently. Instead, it proposes globs, then **verifies** them against the actual repo and reports hit counts in the PR body. Zero hits and ten-thousand hits are both review signals.

**Conflict detection:** search existing entries for overlapping globs and triggers; surface candidates as "possible conflict with EXC-003" in the PR body. Supersession cannot be detected reliably, but the search narrows the human's job considerably.

### 4.3 The PR

Generated branch, one file per entry so review happens per decision. The description carries:

1. Proposed rule text.
2. The spike section it came from, with link and anchor.
3. Glob hit counts from the verification step.
4. **A dry run against N recent merged PRs touching matching paths, showing the comments the entry *would* have produced.**

Item 4 is what makes the review a real decision rather than a rubber stamp. A reviewer can read three sample comments and know immediately whether the scope is wrong. **Build this first** — everything else is plumbing.

### 4.4 Human review

The reviewer's checklist:

- Is `strength` right? (Demote aggressively.)
- Is `applies_to` too broad?
- Does this duplicate something `enforced_by` already gates?
- Does it supersede an existing entry?
- Do the dry-run comments read like something you would post under your own name?

### 4.5 Update — spike changed

Scheduled job compares live version against the pin. On drift:

1. Mark affected entries `unconfirmed` in the index. The plugin keeps using them but **downgrades `invariant` to `default` while unconfirmed** — degraded confidence rather than silence.
2. Open a PR showing a diff of only the spike sections the entries actually **cite**, not the whole page. Most edits touch nothing cited, so most of these auto-close.

### 4.6 Update — code changed

The direction people skip, and the one Confluence-side polling cannot see. Fail CI in the plugin repo when:

- An entry's `applies_to` no longer matches anything.
- An entry's `enforced_by` test no longer exists.

Dead entries are worse than missing ones: they consume context and produce comments about code that no longer exists in that shape.

### 4.7 Feedback loop

When a reviewer deletes or edits a generated comment, capture the entry ID that produced it. A monthly report of entries with **high generation and low acceptance** is the demotion queue — and the natural source of new `Do not raise when` clauses.

This closes the loop with the acceptance heuristic already in use: whether a human posts the comment under their own name, how many, verbatim or edited, and what changed.

---

## 5. Sizing

The constraint is not the context window. It is that every token of domain lore competes for attention with the diff under review, and irrelevant retrieved context measurably degrades output rather than being inert.

- **Always-loaded core:** one page. Terminology and hard invariants only.
- **Index:** one line per decision. Grows linearly and stays cheap.
- **Entries:** unbounded in count, bounded in what loads — only globs intersecting the diff.
- **Rationale:** unbounded; loaded only on demand.

If the always-loaded layer needs to grow past a page or two, that is a signal the invariants are not yet crisp — not a signal to raise the budget.

---

## 6. Build order

1. **Dry run against recent PRs.** The measurement instrument. Without it the PR gate is ceremonial and sizing is guesswork.
2. **Entry schema + index + glob-intersection loading.** The scoping mechanism and the retrieval mechanism in one.
3. **`/distill` two-pass extraction with glob verification.**
4. **Registry + PR generation.**
5. **Drift detection, both directions** (Confluence-side and code-side).
6. **Acceptance telemetry and the demotion queue.**

Steps 1–2 are worth building before ingesting anything at scale. They determine whether every subsequent addition is an improvement or dilution.
