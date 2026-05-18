---
description: "Discover open PRs across the notification-system repos, filter bots, summarize what the team is working on, then review + triage each and draft ready-to-paste review comments to this conversation thread — no GitHub posting. Usage: /pr-review-team [--depth 1|2|3]"
argument-hint: "[--depth 1|2|3]"
model: claude-opus-4-6
---

# Team PR Review — Notification System (thread only)

Self-contained, portable command. **Read-only contract (true to original
spec):** never posts to GitHub, never edits code, never commits. All output —
including the ready-to-paste comments produced in step 3d — goes to this
conversation thread only.

## Repos (edit to your actual slugs)
- `visa-org/notification-service`
- `visa-org/notification-worker`

**Parse `$ARGUMENTS`:** depth is `--depth N` (also `--depth=N`),
`N ∈ {1,2,3}`, **default 1**, and applies to **every** PR reviewed this run.
Monotonic supersets, latency strictly increasing:
- **1 (quick, default)** — single-pass review + read-beyond-diff (3b-i).
- **2 (deep)** — + adversarial second pass (3b-iii).
- **3 (max)** — + specialised reviewer fan-out (3b-ii).
Every subagent runs on `claude-opus-4-7`. **Efficiency:** depth multiplies
across all PRs in the sweep — depth 3 over many PRs is expensive. Default 1
for the team sweep; re-run `/pr-review-team --depth 3` mentally scoped to the
one risky PR, or review that PR alone at higher depth.

## Step 1 — Discover open PRs (all repos in parallel)

For each repo (run the calls concurrently):

```bash
gh pr list --repo {REPO} --state open \
  --json number,title,author,createdAt,additions,deletions,changedFiles,labels,isDraft \
  --jq '[.[] | select(.author.login != "dependabot[bot]") | select(.isDraft == false)]'
```

If a repo returns an auth error, note it and continue with the rest.

## Step 2 — Team summary (before any review)

Present a table:

| # | Repo | PR | Author | Age | Size | Labels |
|---|------|----|--------|-----|------|--------|

Then a 3–5 sentence synthesis: what areas the team is actively working on;
PRs risky by size or label; PRs open > 3 days (⏰); PRs touching sensitive
paths (`gh pr diff {N} --repo {REPO} --name-only` matched against `auth/`,
`security/`, `config/`, `kafka/`, `outbox/`).

Ask: **"Any PRs to skip? (enter numbers, or 'none' to review all)"** and
**wait** for the answer. (This human gate is intentional and preserved from
the original spec — this is a team-awareness tool, not an auto-fixer.)

## Step 3 — Review each PR (oldest first, skipping excluded)

For each PR, in order:

### 3a — Fetch context
```bash
gh pr view {N} --repo {REPO} --json number,title,body,baseRefName,author
gh pr diff {N} --repo {REPO} \
  | grep -vE '^diff --git a/(.*(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)|.*\.pb\.go$|.*_pb2\.py$|gen/)'
gh pr view {N} --repo {REPO} --json reviews,comments
gh pr checks {N} --repo {REPO} 2>/dev/null || true
```

### 3b — Code review (exhaustive, perfectionist)
Surface **every** genuine issue incl. minor nits on code the PR introduced or
changed; do not pre-filter for size/severity (triage's job, 3c).

**i. Read beyond the diff (always).** Whole changed files (not just hunks),
callers of changed functions, the other side of any changed event schema /
DTO / interface, and where the invariant is actually enforced (often outside
the diff).

**ii. Primary detection (depth-dependent).** Depth 1/2: review yourself
through every lens below at (i) depth. Depth 3 only: also spawn a fresh-context
reviewer subagent (`claude-opus-4-7`, read-only) **per lens, in parallel**
(one message, multiple Agent calls), `LENS: <name>` + PR coords; **union &
de-duplicate** with your own findings.

Lenses (all depths) — notification-system focus:
- **kafka-eventing** — partition-key correctness, consumer-group hygiene,
  at-least-once / duplicate handling, rebalance safety, proto/schema
  backward-compat (proto3 envelope pattern).
- **outbox-cdc** — transaction boundaries, atomic outbox write, Debezium CDC
  implications, `correlation_id` propagation.
- **idempotency** — idempotency-key design, duplicate-event handling, retry
  safety.
- **email-delivery** — Mailgun error handling, retry/backoff, webhook
  signature verification, bounce/complaint handling.
- **spring-cache** — Caffeine L1 + Redis L2 invalidation correctness, bean
  lifecycle, `@Transactional` boundaries on multi-repo writes.
- **persistence-observability** — MySQL isolation & index usage on the actual
  query patterns; Micrometer / Datadog golden-signal coverage for new paths.

**iii. Adversarial second pass (depth ≥ 2 only; skip at 1).** Opposite prior:
*assume a real bug the first pass rationalised as fine* — hunt the missed
edge/failure/concurrency/null/boundary case and the consumer the change
quietly broke. Add only new findings.

Compile (single-pass or unioned fan-out + depth-≥2 adversarial), unioned &
de-duplicated: `file:line`, one-line description, suggested fix.

### 3c — Triage (fresh-context subagent, per PR)
Spawn a triage subagent (`claude-opus-4-7`, read-only `Read/Grep/Glob`).
**Perfectionist bar — discard ONLY if one of D1–D4, else keep (nits incl.):**
- **D1 Unfounded** — false assumption / factually wrong; verify in code first.
- **D2 Fixing degrades quality** — only fix adds disproportionate
  complexity/coupling for negligible benefit; a cheap clean fix never
  qualifies.
- **D3 Auto-fixed before merge** — pure formatting the repo's formatter
  (Spotless / Prettier / gofmt) rewrites anyway; logic / lint-rule / type
  findings do NOT qualify.
- **D4 Not applicable** — generated code (`*.pb.go`, `*_pb2.py`, `gen/`),
  lockfiles, or code the PR cannot meaningfully change.

Returns ONLY JSON:
`{"kept":[{"file","line","severity":"must_fix|should_fix|nitpick","finding","suggestion"}],"dismissed":[{"finding","reason":"D1|D2|D3|D4 + evidence"}]}`

### 3d — Compose review comments (new)

For each **kept** finding from 3c, draft the comment as it should appear on
the PR. Classify each as one of:
- **inline** — anchored to a specific `file:line`. Default for almost
  everything 3c keeps.
- **general** — PR-level concern that doesn't map cleanly to one line:
  missing tests on a new consumer, absent Datadog coverage for the new path,
  schema-compat strategy across the PR, commit hygiene, missing migration.

**Voice — experienced senior engineer giving a peer review.** Direct prose,
enough context to make the issue and the fix obvious without making the
author reconstruct your reasoning. Avoid both extremes:

- ❌ **Keyword-style telegraphic notes** ("null check needed", "extract
  method", "use Optional", "no idempotency"). Reads as drive-by; author has
  to guess what you actually mean.
- ❌ **Defensive narrative** ("I was reading through this and noticed that
  perhaps in some cases it might be the case that…", "Just a thought, feel
  free to ignore, but…"). Buries the point and signals lack of conviction.

**State what's wrong and why it matters in the same breath, then say what to
do.** One to three sentences for most comments; a fourth only if the fix
needs a sketch. Code names (fields, methods, classes, Kafka topics, header
keys) in backticks. No filler praise ("nice work, one small nit"), no
apologising, no repeating the PR description back. If the fix is non-obvious,
sketch it (one-line snippet or clear architectural pointer); if it's obvious,
just name it.

**Example — same finding, three styles, only the third lands:**

❌ Keywordy:
> No idempotency check.

❌ Over-narrative:
> I was looking through the new consumer and noticed that you're processing
> events without checking whether you've already seen them. In a Kafka
> at-least-once setup like ours this could potentially be problematic because
> if the consumer rebalances mid-batch, or if there's a retry storm from
> upstream, you could end up processing the same event multiple times, which
> for notification dispatch would mean sending duplicate emails to customers,
> so I wonder if maybe we should consider adding some form of deduplication…

✅ Senior-engineer voice:
> No idempotency check on `event_id` before dispatch — at-least-once delivery
> means a rebalance or upstream retry will resend the same email to the
> customer. Use the `processed_events` lookup that `OrderEventConsumer`
> already wraps Mailgun calls with, keyed on `event_id`.

**Severity in tone, not in labels.** A 🔴 comment names the bug and the fix
plainly; a ⚪ nit reads lighter ("Minor: `Optional<>` on the return would
make the null contract explicit at the call site") without sliding into
keyword-mode. Don't prefix comments with severity badges — the thread output
already carries those.

**General comments** follow the same voice. Address the PR as a whole, name
the specific gap, point at the concrete fix or convention.

> The new `BounceEventConsumer` ships without any tests — at minimum the
> happy-path dispatch and the retry-on-`MailgunException` branch need
> coverage given how this path interacts with the outbox replay endpoint.
> The `AbstractConsumerTest` harness in `notification-worker` covers the
> Kafka wiring for you.

### 3e — Write to thread
Prefix exactly: `--- Review {N}/{TOTAL}: {REPO}#{NUMBER} ---`, then:

```
**Triage:** <K> kept (<m> 🔴 · <s> 🟡 · <n> ⚪) · <D> dismissed · Depth <1|2|3>

### Findings   <must-fix first; nitpicks kept, not buried>

#### <🔴|🟡|⚪> `<file>:<line>` · <inline|general>
**Issue.** <finding>
**Fix.** <suggestion>
**Comment.**
> <ready-to-paste comment from 3d>

<…repeat per kept finding…>

### Dismissed (<D>)   <one line each; omit if D = 0>
- <finding> — <D# + reason>
```

Each comment block uses a markdown blockquote so it's visually distinct and
the engineer can copy the body (strip the leading `> `) into GitHub's review
UI. Inline comments include the `file:line` already shown in the heading so
the engineer knows where to anchor; general comments use `—` in place of
`file:line` and are grouped at the end of the PR's findings section.

## Step 4 — Closing summary

After all reviewed PRs:
- Totals across PRs: must-fix / should-fix / nitpick counts.
- Which PR needs the most attention and why.
- **Cross-PR systemic patterns** — the highest-value output: if the same
  class of issue (e.g. missing Kafka consumer error handling, absent
  idempotency on a new consumer, uncovered outbox path) appears in multiple
  PRs, call it out explicitly as a team-level note, not just per-PR. When a
  pattern recurs, the per-PR comments should already reference the
  convention or other consumer that handles it correctly — flag any that
  don't so they can be tightened before posting.
- Note the depth used and any repos skipped (auth error or user exclusion).
- Remind: comments above are **drafts for your review**. Copy what you want
  to post, edit as needed, post yourself.

**Do NOT post anything to GitHub. Do NOT modify code. The workflow ends here.**
