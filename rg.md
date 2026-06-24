# Spike: `buf breaking` for proto-over-Kafka schema compatibility

**Domain:** event-driven notifications (Kafka + protobuf event schemas)
**Question under investigation:** Can `buf breaking` serve as a structural contract / compatibility gate for our event schemas, and what exactly does it (and does it not) protect?
**Status:** Spike / evaluation notes
**Owner:** Notifications team

---

## 1. TL;DR / Recommendation

`buf breaking` is a **CI/CD gate** (part of the Buf CLI), not a library linked into our Spring Boot services. It performs **structural schema compatibility checking**, not Pact-style consumer-driven contract testing. For strongly-typed proto-over-Kafka, structural compatibility is usually the *right* form of enforcement — Pact's value drops sharply once you already have a typed schema.

It is a **high-value, low-cost first line of defence** for a durable, replay-heavy proto-over-Kafka domain like ours, **provided** we:

1. Pick the **category** deliberately (`WIRE` / `WIRE_JSON` vs `FILE`) — selects *which kinds* of break are caught.
2. Pick the **baseline** deliberately (`--against` target) — selects *how far back* the guarantee reaches.
3. Enforce **`reserved`** on every field deletion — closes the delete-then-reuse hole.

What it **cannot** do is guarantee *semantic* compatibility (same wire shape, changed meaning/units, code that assumes a field is present). That stays with policy, defensive coding, and runtime safeguards.

> **Two orthogonal knobs — do not conflate them:**
> - **Category** (`WIRE` / `WIRE_JSON` / `FILE`) = *which kinds* of break are caught.
> - **Baseline** (`--against …`) = *how far back* in history the guarantee reaches.
> You must set both correctly. "Stricter" is not a single dial.

---

## 2. Core concepts (answers to specific questions asked)

### 2.1 What does `buf breaking` actually compare? (regression-test mental model)

It builds **two protobuf images** (FileDescriptorSets) and diffs them:

- **Current** — image built from the protos at the **PR branch HEAD** (the working tree under review).
- **Baseline** — image built from whatever `--against` points at, **resolved independently at that reference**.

Because the baseline is resolved separately, the PR's own changes **never leak into it**. With `--against '.git#branch=main'`, buf builds main's image and the PR's image and diffs *PR-relative-to-main*. The evaluated delta is exactly the change under review — hence it reads like a **regression / golden test**: reference vs current, reference untouched by the current change.

**The baseline advances only on merge.** Once the PR merges, `main` contains the new schema, so the *next* PR's baseline includes it. This is a **ratchet** — each merge moves the compatibility floor forward one step.

> Contrast: `--against 'HEAD~1'` advances the baseline every commit, which only guarantees compatibility with the immediately prior commit — usually **not** what you want.

### 2.2 What does "wire-incompatible" mean?

A change alters the serialized bytes such that a message encoded under the old schema can no longer be read correctly under the new one (or vice versa) — either failing to parse or **silently corrupting** data.

Protobuf encodes fields by **field number + wire type**, *not* by name.

| Wire-**breaking** | Wire-**safe** |
|---|---|
| Changing a field's number | Renaming a field (name isn't on the wire) |
| Changing a field's type (e.g. `int32` → `string`) | Adding a new field with a fresh number |
| Reusing a deleted number for a new field | Reordering fields in the `.proto` |
| Incompatible cardinality changes | — |

This name-vs-number distinction is why a rename is **wire-safe but source-breaking** — the basis of buf's `WIRE` vs `FILE` categories.

### 2.3 What does `reserved` do?

`reserved` is a declaration inside a message that **permanently retires** specific field numbers (and optionally names) — off-limits for future reuse. It does **not** affect the wire format; it's a compiler-enforced tombstone.

```protobuf
message NotificationEvent {
  reserved 5;
  reserved "user_id";
  // ... other fields
}
```

After this, protoc (and buf) will **reject** any future field numbered `5` or named `user_id` in that message.

**Why it matters here:** deleting a field is wire-safe (old readers see it absent), but it frees the *number*. If a later version reuses that number with a different type, old bytes carrying the original field get **silently misread**. `reserved` makes that impossible — and crucially, it makes the **delete-then-reuse hole catchable by buf**: the tombstone is present in the baseline, so a reuse attempt is flagged even when buf only compares against the immediately prior version. It is the cheap, standard discipline that turns "compatible with the previous version" into something much closer to "compatible with all previous versions."

### 2.4 Categories: `WIRE` vs `WIRE_JSON` vs `FILE`

| Category | Protects | Lifecycle moment | Notes |
|---|---|---|---|
| `WIRE` | Binary wire compatibility | **Runtime** (bytes in motion / at rest) | Most permissive; the load-bearing guarantee for Kafka payloads |
| `WIRE_JSON` | `WIRE` + JSON-mapping compatibility | **Runtime** | Sensible floor if any payloads are ever delivered as JSON (e.g. webhooks) |
| `FILE` | Generated-source compatibility per language (default, strictest) | **Build-time** | Catches source breaks (e.g. renames) — but for a single-team-owned schema these are caught by our own compilation anyway |

**Key insight for our context:** the wire categories give a genuine **runtime** guarantee about bytes. `FILE` only adds a **build-time** property — for us it mostly moves a build failure from "after merge" to "in the PR" (nice, not a safety guarantee). Since we own one schema and compile everything against it, accessor/source breaks are **fully contained at build time** and are *not* a production risk.

### 2.5 Backward vs. full compatibility (terminology flag)

Our system needs compatibility in **both directions**:

- **Forward:** a new producer emits an event read by an older consumer.
- **Backward:** an old event (topic / outbox / event store) is read by a newer consumer after replay.

Protobuf's wire rules are largely **symmetric**, so the `WIRE` / `WIRE_JSON` category enforces both structurally. State this explicitly to the team so nobody reasons about only one direction.

---

## 3. Scenario coverage map (what buf covers vs. what needs other approaches)

Our schema is **single, team-owned, shared by producer and consumer**, which collapses the *divergence* risk almost entirely and relocates residual risk to **temporal coexistence of bytes** — different schema versions in flight or at rest at the same moment. Every scenario below is a variant of "vN-encoded bytes meet vN±k code."

| # | Scenario | buf covers (structural) | Needs other approaches (semantic / operational / build) |
|---|---|---|---|
| 1 | Producer & consumer on different stub versions (by omission) | The compat guarantee makes skew **harmless at parse level** (newer extra fields skipped; missing fields → defaults) | Dependency hygiene: single versioned stub artifact, central BOM pin, Renovate/Dependabot. Semantic sliver: producer sets a field a stale consumer needs → **deploy consumer first** |
| 2 | In-flight messages during rolling / canary deploys | **Fully owned** — mixed-version coexistence is exactly what the wire guarantee certifies | **Expand/contract (two-phase) deploy ordering** for semantically directional changes (readers before writers; stop writing before delete) |
| 3 | Stored serialized bytes (outbox + event store) | Structural compat **back to the chosen baseline** (needs cumulative-floor baseline + `reserved`) | **Defensive consumer coding** (treat absent/default as a real case); **envelope schema-version stamp** for debuggability + future migration |
| 4 | Consumer offset reset across multi-version history | Same as #3; **topic retention bounds the window** | Same as #3 |
| 5 | Replay of upstream public events | Only **once internalised** — buf in our repo says nothing about a schema we don't own | **Anti-corruption layer** at ingestion: translate upstream → our internal schema, store/replay the normalised form → collapses #5 into #3 |
| 6 | protoc / runtime version mismatch | Addressed via buf's **codegen** side, not the breaking check | Single stub artifact built once with pinned protoc; pin plugins in `buf.gen.yaml`; **keep protobuf-java gencode and runtime versions aligned** (the one real footgun) |

**One-sentence split:** buf guarantees that across all versions the bytes always **parse** (structural side of #2, #3, #4, and #5-once-internalised); everything about what those bytes **mean** when a field is missing, whether the right code is deployed in the right order, and how we handle schemas we don't own falls to defensive coding, version stamping, expand/contract deploys, and an anti-corruption layer.

**Note on accessor breakage:** a wire-safe-but-source-breaking change (e.g. a rename) can **only** fail at *compile time inside a single repo*, never across the wire. It is **not** a production risk and is removed from the runtime threat model entirely.

---

## 4. Semantic compatibility is a different kind of property

buf is deterministic about **structure**; semantic compatibility largely **resists a deterministic gate**, because whether code behaves correctly against an older version depends on field *intent* and the reading logic — e.g. `0` parsed as a default may mean "producer didn't set this" or "a real quantity of zero," and no differ can know which. That intent isn't in the schema structure, so there's nothing structural to check.

But the semantic half is **not** purely vibes — it's a spectrum of enforceable conventions:

- Defensive reading of any field younger than the oldest baseline → lint rules / review checklists.
- Envelope schema-version stamp → a concrete artifact you either have or don't.
- Expand/contract deploy ordering → enforceable in the deployment pipeline.
- Anti-corruption layer for upstream events → an architectural requirement.
- **Org-wide full-backward-compatibility policy** → the umbrella principle the practices implement.

---

## 5. Industrial alternative considered (deliberate "no")

A **Schema Registry** (e.g. Confluent, with protobuf support) enforces compatibility at registration time **and** stamps every message with a schema ID — directly addressing #1–#4 by recording what wrote each byte. But given we already own the single schema and gate it with buf in CI, the registry's *enforcement* is largely **redundant**. The part that adds real value — schema-ID stamping — is obtainable far more cheaply via an **envelope field**. The registry earns its runtime cost mainly if we later **lose single-ownership** or want central runtime enforcement we don't trust CI to provide.

---

## 6. Scoping the check to *our* files in a repo we don't own

We do not own the repo holding the system-wide proto schemas. `buf breaking` supports **path scoping**, so we don't have to check the whole repo.

### 6.1 Allowlist — `--path` (repeatable)

```bash
buf breaking --against '.git#branch=main' \
  --path proto/notifications \
  --path proto/common/envelope.proto
```

- `--path` filters **both** current input **and** baseline to the same paths → diffs our subset against the historical version of that same subset (correct behaviour).
- In recent Buf CLI versions, `--path` is being superseded by `--include-path` / `--exclude-path` — **check `buf breaking --help` on the pinned CI version** (the spelling shifted around the v1.32-ish era).

### 6.2 Denylist — `--exclude-path`

Inverse approach: exclude the directories we **don't** own, so anything new under *our* tree is covered by default. Prefer this if our surface is large/growing; prefer the allowlist if our files are a small fixed set. **Pick whichever list is shorter and more stable.**

### 6.3 Hard constraint: imports must still resolve

The scoped paths must still **build as a complete set**. If our protos `import` shared types (e.g. `common/`), those imports must resolve — buf needs the full import graph to build the image, even though it only *evaluates breakage* on the filtered paths. In practice: point buf at the **repo root** as the module so imports resolve, and use path flags to scope **what's checked**. We don't have to own the imported files; they just have to be present and parseable.

### 6.4 Governance question buf can't decide for us

**A CI gate only protects changes that flow through that CI.** Two things to settle with the owning team:

1. **Where the gate lives + baseline.** In *their* repo's CI → `--against main` is natural. In *our* CI against their repo as an external input → `--against` a git URL/ref for their repo (needs read access + a stable ref).
2. **Coverage of *all* changes.** Can someone else merge a change to our protos — **or to a shared `common` type we import** — without our buf check running? If the check isn't a **required status on their PRs**, it protects our PRs but not theirs, and a shared-type change by another team is exactly the break that hits us. Confirm the check is a **required** status on the paths we depend on (e.g. CODEOWNERS on our proto dirs + required buf-breaking status), owned at repo level — not just present in our own branch builds.

---

## 7. Setup recipes

Two recipes. **Recipe A (neighbouring-version)** is the simple incremental gate. **Recipe B (cumulative-floor)** is the one that insulates against in-flight / stored payloads built on **more than two neighbouring schema versions** — back to the oldest live schema version. **Recommended: run both** (fast incremental gate on every PR + cumulative floor).

### Recipe A — Neighbouring-version gate (pairwise against `main`)

**Goal:** every change is compatible with the immediately preceding released state. Cheap, fast, catches the common case. Composes inductively for most wire rules, **but has the delete-then-reuse hole** unless `reserved` is enforced.

**`buf` configuration requirements**

- Baseline: `--against '.git#branch=main'` (the ratchet — advances on merge).
- Category: at least `WIRE`; use **`WIRE_JSON`** as the floor for event topics (webhook/JSON delivery). Reserve `FILE` only if you want in-PR build-break detection.
- Scope (shared repo): `--path` (or `--exclude-path`) per §6, with imports resolvable from repo root.

`buf.yaml` (v2):

```yaml
version: v2
modules:
  - path: .
breaking:
  use:
    - WIRE_JSON      # runtime wire + JSON-mapping compatibility
  # ignore_unstable_packages: true   # optional, if you keep *.v1alpha etc.
lint:
  use:
    - STANDARD
  # FIELD_NOT_DELETED-style discipline is enforced via reserved (see proto guidelines)
```

CI step:

```bash
buf breaking \
  --against '.git#branch=main' \
  --path proto/notifications \
  --path proto/common/envelope.proto
```

**Proto design guidelines (mandatory for this recipe to be sound)**

- **Always `reserved` on deletion** — number **and** name. Without it, delete-then-reuse across ≥2 versions slips through, because the original definition isn't in the (single, neighbouring) baseline.
- Never change a field's number or type; add a new field with a fresh number instead.
- Never recycle a number; treat the number space as append-only.

### Recipe B — Cumulative-floor gate (against the oldest live schema tag)

**Goal:** current code is structurally compatible with **every** historical version still reachable — outbox/event-store payloads, offset resets, replays — i.e. the full accumulated span, not just the neighbour. **This is the recipe that addresses payloads built on more than two neighbouring versions.**

**Determine the floor first.** The floor tag = the **oldest schema version whose bytes can still reach current code**:

- **Topic retention** bounds offset-reset/in-flight scenarios (e.g. 7-day retention → 7 days back). Infinite/compacted → whole history.
- **Event store / outbox** is effectively append-only forever → its floor is the **true cumulative horizon** (usually the binding one).
- Tag that oldest-still-live schema version, e.g. `schema-floor-v1.0.0`, and **bump the floor only when** the corresponding old payloads are provably no longer reachable (retention expired *and* no event-store records remain / all migrated).

**`buf` configuration requirements**

- Baseline: `--against '.git#tag=schema-floor-v1.0.0'` (a **fixed** reference, not `main`) → cumulative guarantee across the whole span.
- Category: same as Recipe A (`WIRE` / `WIRE_JSON`); category choice is **independent** of baseline.
- Scope: same path-scoping as §6.

`buf.yaml` is identical to Recipe A (category/scope don't change). Only the **`--against` target** differs.

CI step:

```bash
# Cumulative floor: must stay compatible with the oldest still-reachable schema version
buf breaking \
  --against '.git#tag=schema-floor-v1.0.0' \
  --path proto/notifications \
  --path proto/common/envelope.proto
```

**Proto design guidelines (mandatory for this recipe to be sound)**

- **`reserved` on every deletion** (number + name) — same as Recipe A; here it's what keeps the long span honest against delete-then-reuse.
- Treat field numbers as **append-only forever** — no reuse, ever, within the cumulative horizon.
- For any field added after the floor, ensure consumer logic treats **absent/default as a valid, expected case** (this is the semantic complement buf can't enforce — see §4).
- Stamp each stored payload with an **envelope schema-version field** so old data is debuggable and a future *hard* migration (upcasters) stays possible.

### Recommended combined CI (both gates)

```bash
set -euo pipefail

PATHS=( --path proto/notifications --path proto/common/envelope.proto )

# 1) Fast incremental gate — compatibility with the latest released state
buf breaking --against '.git#branch=main' "${PATHS[@]}"

# 2) Cumulative floor — compatibility with the oldest still-reachable schema version
buf breaking --against '.git#tag=schema-floor-v1.0.0' "${PATHS[@]}"

# 3) Style/discipline (incl. reserved enforcement via proto review)
buf lint "${PATHS[@]}"
```

> Reminder: both gates are **structural only**. They guarantee bytes parse back to their respective baselines. Semantic correctness (§4), deploy ordering (§3 #2), dependency pinning (§3 #1, #6), and the anti-corruption layer for upstream events (§3 #5) remain separate, required practices.

---

## 8. Open follow-ups

- Confirm whether our buf check can be made a **required status** on the owning team's PRs (incl. shared `common` types we import) — §6.4.
- Decide the **floor tag** and the policy for bumping it (retention + event-store reachability) — §7 Recipe B.
- Design the **envelope schema-version stamp** for outbox/event-store payloads (prerequisite for future upcasters).
- Decide `WIRE` vs `WIRE_JSON` floor for event topics (webhook JSON delivery argues for `WIRE_JSON`).
- Define the **expand/contract** deploy-ordering convention and where it's enforced in the pipeline.
