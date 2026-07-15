# Notification Pipeline — Template Data Access Architecture Summary

## Current Architecture

The system is a **sequential notifications pipeline** made up of three services connected through Kafka with Debezium running in outbox mode. Events flow through the pipeline asynchronously, each stage producing events that the next one consumes.

The **middle service — the email processor (EP)** — is the one under discussion. Its responsibility is processing notifications and rendering emails. To do that, it reads a lot of domain reference data: email notification templates, notification configurations, brands, and a few other types. Historically this data was **seeded manually**, so EP simply read it from its tables. It was static reference data with no write-side lifecycle.

On the persistence side, everything sits on a **shared Aurora cluster** (the org-standardized stack), with services following a schema-per-service model in which each one reads only its own tables. Aurora exposes writer and reader endpoints, the reader endpoint load-balancing across replicas. EP already **caches raw templates in Redis**.

The recent change is the introduction of a **template editor** — an internal tool, a UI plus a BFF exposed over REST — through which internal users create and edit templates directly. This capability may later extend to editing the other data types (configs, brands) as well.

The domain object currently managed by EP has this shape:

| Column          | Type           | Nullable      | Notes                                |
| --------------- | -------------- | ------------- | ------------------------------------ |
| `id`            | `VARCHAR(36)`  | `NOT NULL PK` | UUID, auto-generated                 |
| `template_name` | `VARCHAR(255)` | `NOT NULL`    | Logical name, e.g. `"welcome-email"` |
| `brand_id`      | `VARCHAR(36)`  | `NOT NULL`    | UUID FK (logical) to `brands.id`     |
| `version`       | `VARCHAR(10)`  | `NOT NULL`    | e.g. `"v1"`, `"v2"`                  |
| `subject`       | `TEXT`         | `NULL`        | Plain-text subject line              |
| `body_text`     | `TEXT`         | `NULL`        | Plain-text fallback body             |
| `body_html`     | `LONGTEXT`     | `NULL`        | HTML body                            |
| `created_at`    | `TIMESTAMP`    | `NOT NULL`    | Set by `@CreationTimestamp`          |
| `updated_at`    | `TIMESTAMP`    | `NOT NULL`    | Set by `@UpdateTimestamp`            |

Two properties of this object matter for the decision below. The template is a **dynamic object** whose body (`body_text` / `body_html`) is essentially opaque payload rather than a structured domain type likely to become a formal contract, and the stack uses **no schema registry**. The working assumption is that these body fields are passed through to the target service as flat fields rather than reshaped into a structured object.

## The Problem

Folding authoring into EP would **extend its responsibility** from "process notifications and render emails" to also "manage the data needed for processing," which violates single responsibility. Hence the idea of **splitting out a new service** to own the template (and eventually other) authoring lifecycle.

That split raises the operative question: **how should EP obtain template data from the new service?** In particular, is there overhead to be saved by having EP read directly from the database through the Aurora reader endpoint instead of calling the new service's API?

Beneath that question is the change that actually matters. User editing gives templates a **write-side lifecycle** — draft versus published, validation before publish, most likely version history. So the decision is not really "API or DB." It is a decision about how much of that authoring lifecycle should be allowed to leak into EP's read path.

A second dimension surfaced alongside it: **consistency over time**. Template editing and notification sending are independent workflows — a notification is triggered by an upstream domain event, not by an edit. The concern is the specific scenario in which an internal user edits a template and then wants to send a notification shortly afterwards: from what moment can a new notification be triggered such that it is guaranteed to render the updated template? The synchronous nature of an API call and the asynchronous nature of events answer that question differently, and — as detailed below — patterns exist on both sides to give the editor a clear answer.

## Potential Solutions

### 1. Event-carried state transfer (events over the existing outbox)

Here the new template service is the system of record. Whenever a template is published, it emits a template-changed event through the outbox. EP consumes those events and either maintains its own local, read-optimized copy of the data or uses the events purely as precise cache-invalidation signals over Redis.

The strength of this approach is that it keeps the two services genuinely independent. EP holds its own copy of the data, so it acquires no runtime dependency on the template service — rendering continues even if the authoring service is down. Invalidation becomes precise: the moment a template is published, EP hears about it, rather than waiting for a timer to expire. And because the flow stays asynchronous, it is consistent with the rest of the pipeline. The interface between the two services is the set of event fields rather than the physical table layout, which means each side can evolve its own storage freely.

The cost is the ongoing synchronization work. EP maintains a second copy of the data, so the consumer has to handle idempotency and event ordering to keep that copy correct. There is no meaningful initial-migration concern here — the services are not yet in production and only a single template exists today — so the cost is the steady-state discipline of keeping two copies consistent, not a one-off backfill.

### 2. Read API on the new service

In this option EP calls an API exposed by the new service on a cache miss, using either events or a short TTL to know when to refresh.

Its appeal is simplicity. The API is a clean contract, so the schema boundary is preserved and EP stays ignorant of the authoring lifecycle — it only ever sees published, valid templates. There is no projection to build and keep in sync, which for a dataset this small and this slow-changing may be all the sophistication the problem warrants.

The drawback is runtime coupling. On a cold cache, or when a large invalidation sweeps the cache at once, EP's ability to render emails depends on the template service being available. The network hop also remains, though only on cache misses.

### 3. Direct DB read via the Aurora reader endpoint

Here EP reads the new service's tables directly through the reader endpoint.

In its favour, this saves both the hop and the API surface, and routing EP's reads to the replicas gives real runtime read/write isolation: EP's read load lands on the readers while the editor's writes land on the writer, so the two do not contend (setting aside the shared storage volume they still have in common).

Against it, this revives the **shared-database (integration-database) pattern**. Schema coupling returns even under single-team ownership, so the new service can no longer refactor its persistence — normalize tables, add a versioning scheme, change how drafts are stored — without breaking EP. EP is also forced to understand the authoring model itself, distinguishing published, valid rows from drafts and half-saved edits so that it never renders unpublished content into a real email. And decisively, a raw table read carries no signal that anything changed, so freshness falls back to a TTL regardless. This option therefore takes on the most coupling while still failing to solve the invalidation problem, and it drops a synchronous read into a pipeline that is otherwise entirely asynchronous.

> Redis is not a standalone option in any of these. A cache always needs both a source of truth and an invalidation strategy underneath it, and it sits on top of whichever read path is chosen. The one caution is not to let Redis itself quietly become a shared integration point between the two services.

## The Consistency-Over-Time Dimension

The concern is legitimate, and it separates cleanly into two questions with different consistency profiles. Keeping them apart is what makes the answer tractable.

The first question is **durability** — the edit is saved and will not be lost. The second is **propagation** — a notification triggered after the edit will render the updated template. On durability, both options are synchronous. Events do not make *saving* asynchronous; they make *propagation* asynchronous. In either design the editor's save is a REST call into the template service (the source of truth) that returns once the local transaction commits — and with the outbox, that commit includes the outbox row in the same transaction, so a `200` already means "durably saved and guaranteed to propagate." The editor gets immediate confirmation of the thing they most worry about, identically in both approaches.

Propagation is where the two designs genuinely differ. Because a notification is triggered independently — by an upstream domain event, or by an internal user deliberately sending one after an edit — the operative question is: from what moment is a newly triggered notification guaranteed to use the new template? Cache repopulation, in every case here, happens on a cache miss; the difference is entirely in how and when the stale entry is removed.

- **API with synchronous invalidation.** If the edit request synchronously evicts EP's Redis key as part of its own flow, then the moment the save returns, the stale entry is already gone. The next notification cache-misses and repopulates the fresh template from the source of truth. This *is* synchronous end-to-end for the sending path: after "Saved," any triggered notification is guaranteed to render the new version, with no further machinery. This is the API's strongest card, and it answers the edit-then-send-soon scenario directly. Its cost is a coupling on the write path — the editor (or template service) must be able to reach EP's cache to evict it, either by knowing EP's cache-key scheme or by calling an EP invalidation endpoint, and the write then depends on that eviction succeeding. It also cannot be made synchronous in every design: if EP holds a full local projection rather than a read-through cache, there is nothing to evict — the data must be pushed, and pushing synchronously from the write path is exactly the request-reply coupling to avoid.

- **Events.** The edit commits and emits; EP invalidates its cache (or updates its projection) when it consumes the event. Propagation is therefore eventual — immediately after "Saved," a triggered notification might still catch the old version until the event lands. The window is small (outbox → Debezium → EP) but non-zero, so the editor needs a signal for when it has closed.

That signal is where a **status event** earns its place, and it is what lets the event design match the API's answer to the edit-then-send question. The shape is a two-phase confirmation:

1. The save returns "Saved" instantly, confirming durability.
2. EP, after committing its cache/projection update, emits a `template-applied` event carrying the template id and version (or a correlation id).
3. The template service consumes that event, marks the record "live," and the UI reflects it via an SSE/websocket push or a short poll on a status endpoint.

Once the editor sees "live," a triggered notification is guaranteed to use the new version — the same guarantee the synchronous eviction gives, arrived at asynchronously and made explicit to the user rather than assumed.

The editor's **read-your-writes** need for its own preview is separate from both mechanisms and simpler than either: the preview and read-back should hit the source of truth, not EP's cache. The authoring path reads from the service it just wrote to, so it is strongly consistent by construction. Only the sending path is subject to the propagation question above.

The one trap to avoid — on the event side — is making the save itself block on EP's acknowledgement, i.e. synchronous request-reply over Kafka. That recouples the write path to EP's availability and latency and throws away the main benefit of the split. This is *not* the same as the API's synchronous cache eviction, which is a legitimate, bounded operation; the trap is specifically blocking a save on an asynchronous consumer's round-trip. So the rule is: **confirm durability synchronously; for propagation, either evict synchronously (API) or confirm asynchronously via a status event (events).**

## Recommendation

The recommendation is to **split the service and have EP consume *published* templates via events over the outbox (Solution 1)**, falling back to the Read API (Solution 2) if an event-fed projection proves to be over-engineering for a dataset this small.

The decisive reason is **long-run maintainability**. The whole point of the split is to give the template domain genuine autonomy over its own model, and only the event-based boundary actually delivers that. The new service stays free to reshape its persistence — versioning, draft storage, normalization — behind a stable interface, while EP owns a projection shaped for rendering. The direct-DB option would make the split cosmetic: two services on the org chart, still fused at the database, unable to evolve independently. Over years of change, that difference is what determines whether the boundary keeps paying off or slowly becomes a liability.

Several further reasons reinforce that choice:

- **The consistency concern is the API's strongest card, and the event design has a clean answer to it.** Synchronous cache eviction genuinely lets the API guarantee that a notification triggered after "Saved" uses the new template — a real advantage for the edit-then-send-soon scenario. The event design matches that guarantee with a two-phase status event, trading the immediate synchronous eviction for an explicit "live" confirmation, and in return keeps the write path decoupled from EP's cache rather than depending on it. This narrows the gap between the two candidates to a genuine trade-off; it does nothing for the direct DB read, which offers no invalidation signal at all.

- **It solves the freshness problem the other options fumble.** Publishing a template emits an event, which gives precise invalidation the instant the template changes. That is the difference between editors trusting the system and editors refreshing the page, wondering why the old version still went out. The direct-DB read is the sharpest contrast here: it offers no better invalidation than a plain TTL, so it takes on the most coupling for the least freshness benefit.

- **It removes runtime coupling rather than adding it.** Because EP keeps its own copy, downtime in the template service does not stop email rendering — the one dependency least wanted in a notifications pipeline.

- **It happens to match the architecture already in place.** The pipeline is already fully asynchronous through Kafka, and Debezium in outbox mode is already operated, so events are existing machinery rather than something new to introduce. This is a genuine convenience, but it is a convenience and not the reason: the architecture is not fixed, and any of these approaches could be built. The case for events rests on maintainability first; the fact that the current stack makes them cheap to adopt is a welcome coincidence, not the driver.

### A caveat worth stating honestly

With an opaque, dynamic body and no schema registry, the "event as a governed contract" benefit is thin. Passing `body_text` / `body_html` through as flat fields is essentially shipping blobs, and there is not much to formalize. But the load-bearing part of the decoupling survives intact: EP binds to *event fields*, not to `SELECT`s against another service's tables, so the template service keeps its freedom to reshape storage without touching EP. That freedom is precisely what the direct-DB read forfeits. What the caveat actually does is narrow the gap between *events and the API* — both hide storage behind an interface — not the gap between either of them and the direct read. Registry-less schema evolution then rests on team discipline, which for a single team is the same coordination that already makes design-time coupling a non-issue.

### Two concrete cautions from the schema

- **`body_html LONGTEXT` versus Kafka's ~1 MB default message ceiling.** Most email bodies sit comfortably under it, but a template with inlined CSS or base64 images can creep up. If that is plausible, reach for a **claim-check**: the event carries the metadata and a pointer, while the body lives in object storage. This keeps the event small without reintroducing a synchronous read on the hot path.

- **The `version` column is doing quiet work.** If a publish mints a *new* immutable version, propagation becomes almost trivial — EP appends a row, idempotency falls out of `(template_name, brand_id, version)`, and event ordering barely matters, since the only mutable state is a "which version is live" pointer. But `updated_at` hints that in-place edits happen too. Pinning down which model applies matters, because immutable-versioned templates make both the projection and its idempotency dramatically simpler than in-place mutation with last-write-wins.

### Through-line

The direct DB read optimizes the single cost — one network hop — that the Redis cache had already mostly neutralized, in exchange for precisely the coupling the split exists to escape. Events keep the boundary clean and the pipeline asynchronous, they handle the editor's confirmation need through a two-phase durability/propagation split, and they do so in a way that stays maintainable as both services grow.
