# Handling DB Unavailability in the Notification Consumer

## Context & Invariant

The notification system enforces a core architectural invariant:

> **No offset is committed without a prior successful DB write — for both successful and failed events.**

The goal is to **minimize or eliminate message loss**. Every event is classified as
**recoverable** or **non-recoverable**:

- **Recoverable** — transient failures (e.g. DB connectivity issues). Retried with backoff.
- **Non-recoverable** — the event itself is bad (e.g. proto3 deserialization failure).
  Persisted to the **exceptions table** + mapped to an event delivery, *then* the offset
  is committed.

A recoverable failure becomes non-recoverable once **max retries** is exhausted.

The exceptions table is the **terminal durable sink** — it replaces the usual
"non-recoverable → DLT" pattern with "non-recoverable → exceptions table."

## The Gap

Both the success path and the exceptions path write to the **same DB**. During a
**prolonged DB outage**, *neither* path can complete:

- The event can't be written (success path blocked).
- It can't be escalated to the exceptions table either (that sink is also down).

Under the old design, exhausting retries reclassified a **healthy** event as
non-recoverable and tried to write it to the exceptions table — which hit the same dead
DB. The offset never committed, the consumer re-polled the same message, and the
**partition hot-looped**, blocked indefinitely.

Two problems with that escalation:

1. **Misclassification.** "Non-recoverable" is a property of the *event* (bad payload).
   A DB outage is a property of the *infrastructure*; the event was fine. Escalating on
   outage pollutes the audit data with perfectly good events.
2. **Impossibility.** The escalation target (exceptions table) is on the same dead DB,
   so the escalation can't succeed anyway — hence the hot loop.

---

## The Core Distinction: Retry vs. Pause

These operate at **different layers** and solve different problems:

| | **Retry** | **Pause (backpressure)** |
|---|---|---|
| Meaning | "Try the operation again" | "Stop pulling new work; the sink can't accept it" |
| Scope | Per-record | Per-partition / per-container |
| Bounded? | Yes (max retries) | No (indefinite) |
| Right for | Transient blips (failover resolving in seconds) | Sustained outages (minutes to hours) |

Retry is **not replaced** — it's kept for genuine blips. Pause is added as the **next
tier**: instead of escalating exhausted retries to *non-recoverable*, escalate to
*paused*.

---

## Why Bounded Retry Cannot Ride Out a Long Outage: The Two-Clock Model

A Kafka consumer is **two things running concurrently, watched by two independent
clocks**. Your retry only feeds one of them.

### The two threads

- **Main thread** — runs your poll loop: `poll()` → process batch → loop. Your DB writes
  and retry-with-backoff run *here*. While retrying, you're sitting *inside* the
  processing step, between one `poll()` and the next.
- **Heartbeat thread** — since KIP-62 (Kafka 0.10.1), a separate background thread that
  sends a "still here" message to the group coordinator every `heartbeat.interval.ms`,
  independently of what the main thread is doing.

### The two clocks

**Clock 1 — `session.timeout.ms` (watches heartbeats)**
Question: *"Is this consumer alive at all?"* (crashed, network-partitioned, JVM frozen).
Satisfied as long as the heartbeat thread keeps ticking — **which it does even while the
main thread is blocked in a retry-backoff sleep**, because it's a separate thread. A
consumer grinding through a 90-second retry loop looks perfectly healthy to this clock.

**Clock 2 — `max.poll.interval.ms` (watches the cadence of `poll()` calls), default 5 min**
Question: *"Is this consumer making progress, or alive-but-stuck?"* If the gap between
two `poll()` calls exceeds this threshold, the coordinator concludes the consumer is
**livelocked** — heartbeating, technically alive, but wedged on a batch it can't finish.

> **Why two clocks?** Before KIP-62, heartbeats were piggybacked onto `poll()`, so a slow
> batch tripped the session timeout — "dead" and "slow" were indistinguishable. Decoupling
> them lets a healthy-but-slow consumer keep its membership, but it moves the real ceiling
> onto `max.poll.interval.ms`.

### What retry-in-the-loop does to the pair

It keeps **Clock 1 happy** (background heartbeats fire throughout) while **starving Clock
2** (no `poll()` call until the retry resolves). Your retry budget is therefore racing
`max.poll.interval.ms` whether you intended it or not.

**This is the hidden ceiling.** Your max-retries threshold being tuned to "a few minutes"
isn't really a business choice about how many tries is reasonable — it's the consumer
protocol forcing your hand.

### The eviction, concretely

When the interval is exceeded, the client **proactively sends `LeaveGroup`** and stops
heartbeating — it removes *itself*. The coordinator reassigns the partition. When your
processing thread finally finishes its retry and comes back to commit, it discovers it's
no longer the owner: `CommitFailedException`, rejoin from scratch. In-flight work is gone;
the offset was never committed (safe under the invariant, but paid for with a rebalance).

### Why this compounds into a storm

The partition lands on a peer consumer, which starts from the same last-committed offset —
the same record — hits the **same dead DB**, runs the **same** retry, exceeds the **same**
interval, evicts **itself**, and the partition bounces to the next instance. Every consumer
takes a turn being kicked, none makes a byte of progress. A DB outage becomes a thrashing
rebalance loop layered on top of the original hot-poll loop. **Worse than standing still.**

---

## How Pause Inverts the Relationship

`pause(partition)` does **not** stop your loop — you keep calling `poll()` every iteration.
A `poll()` on a fully-paused assignment returns almost immediately with nothing (paused
partitions stop issuing fetch requests entirely). So:

- Each iteration is cheap; `poll()` is called constantly.
- **Clock 2 (`max.poll.interval.ms`) is reset on every call** — never approaches the threshold.
- **Clock 1** keeps ticking via the heartbeat thread.

Both clocks satisfied, indefinitely, while doing zero work. You hold your assignment,
nobody rebalances, and you simply wait — checking DB health on each cheap poll — until you
`resume()`.

> **The structural reason:** retry *spends* the poll-interval budget; pause *refreshes* it.

**The one footgun:** pausing and *also* stopping the poll loop ("we're paused, no need to
poll"). That reintroduces the exact starvation — `max.poll.interval.ms` doesn't care *why*
you stopped polling. **Contract: pause the partitions, but keep the loop spinning on cheap
empty polls.**

### In Spring Boot

`KafkaMessageListenerContainer` owns the poll loop on the listener thread; your
`@KafkaListener` method is what it calls per record. When you pause the container (or a long
`BackOff` triggers Spring's container-pausing behavior), Spring keeps running its internal
poll loop and just stops *delivering* records to your method — doing the "keep polling,
deliver nothing" dance for you, keeping `max.poll.interval.ms` fed without touching the raw
client.

---

## Where to Trigger the Pause: Interval vs. Max-Retries Time

Both `max.poll.interval.ms` and the total time to exhaust max retries are **constants**.
Their *relative* size determines whether an exhaustion-triggered pause is sufficient or
whether you must pause proactively. Note that **success behaves identically in both
variants** — a healthy DB never engages the retry budget, so the relationship only matters
during an outage.

| | **Variant A: `max.poll.interval.ms` > max-retries-time** | **Variant B: `max.poll.interval.ms` < max-retries-time** |
|---|---|---|
| **Success (DB healthy)** | Write succeeds (first try or quick blip), commit, poll again well within budget. Retry budget never fully spent. No eviction. | **Identical.** Healthy DB → no sustained retrying → gap between polls stays tiny. The relationship is irrelevant when retries aren't exhausted. |
| **DB outage — old design (escalate-on-exhaustion)** | Retries **exhaust within the interval** → no eviction. But escalation writes to exceptions table → same dead DB → can't commit → re-poll same record → retry → exhaust → … **Hot loop.** Each cycle resets the interval, so no rebalance; partition stuck, CPU burn, no progress, no loss (offset never commits). | Retries **don't finish before the interval** → consumer self-evicts **mid-retry** (`LeaveGroup`) → partition reassigned → peer starts same offset → same dead DB → same eviction → **rebalance storm.** Worse than standing still. |
| **DB outage — with pause** | **Pause-on-exhaustion works.** Exhaustion happens inside the interval, so you reach the pause decision, pause, cheap polls, resume on recovery. | **Pause-on-exhaustion does *not* save you** — eviction fires *before* you ever reach exhaustion. You must pause **proactively** (DB `HealthIndicator`, before the interval is hit), not after retries finish. |

**Key takeaway:** where you put the pause trigger depends on which variant you're in.

- **Variant A** — keeping total retry time comfortably **under** `max.poll.interval.ms` means
  pausing *after* retry exhaustion is sufficient; exhaustion is guaranteed to land inside the
  interval.
- **Variant B** — if retry time can exceed the interval, an exhaustion-triggered pause is
  **too late**; the consumer is already evicted. You must drive the pause from a proactive
  health signal that fires *before* the interval elapses.

> **Cleanest design:** stay in **Variant A** (size the retry budget below the interval)
> *and* pause proactively off a DB `HealthIndicator`. Then you're never racing the clock,
> and the pause decision doesn't depend on exhaustion timing at all.

---

## Memory Is Not the Risk; Retention Is

A long pause does **not** overflow memory — not on the consumer, not on the broker.

- **Consumer heap stays flat.** `pause()` suppresses *fetching*, not just delivery. A paused
  partition stops issuing fetch requests, so nothing new streams in. The most buffered is a
  fetch-batch worth (`max.partition.fetch.bytes` per partition, `fetch.max.bytes` overall) —
  not a growing backlog. Data accumulates on the **brokers' disks**, where it always lived
  until fetched; pause just means you haven't fetched yet.
- **Broker memory is flat too.** A lagging consumer costs ~nothing: messages are written to
  the partition log (page cache + disk) by producers regardless of consumers, and your group's
  position is a single offset in `__consumer_offsets`. A consumer 10M messages behind and one
  caught up have the same broker-memory footprint: one offset.

### The real risk: retention-driven silent loss

Messages keep being produced throughout the outage, governed by **retention**
(`retention.ms`, default 7 days; `retention.bytes` if size-based is set). If the pause
outlasts retention, the broker deletes the **oldest** log segments first — exactly the
records not yet consumed. On `resume()`, the committed offset no longer exists →
`OffsetOutOfRangeException` → `auto.offset.reset` kicks in:

- `latest` — **silently skips** everything deleted (straight message loss).
- `earliest` — jumps to oldest surviving record (loss of aged-out data + huge reprocess).

Either way: **silent message loss** — worse than the hot loop, because nothing errors.

> Pause trades a **rebalance-loss** risk for a **retention-loss** risk. Size the second
> one deliberately.

**Precision on the retention clock:** retention ages each record by its **own produce
timestamp** on the log, independent of consumer state. So the real question isn't "can I
stay paused longer than retention," it's **"is my consumer's lag (oldest-unconsumed
message's age) approaching the retention window."** If you entered the outage caught-up
these are equivalent; if you were already lagging, headroom is `retention − existing_lag`,
which is smaller.

---

## Retention Configuration (reference)

- Retention is a **per-topic** config: `retention.ms`, `retention.bytes`, set at topic
  creation or via `kafka-configs --alter`.
- Broker-level `log.retention.ms` / `log.retention.bytes` / `log.retention.hours` are only
  the **defaults** a topic inherits; explicit topic config overrides them.
- Limits apply **per partition**. `retention.bytes` caps each partition's log, so a topic's
  total footprint ≈ `retention.bytes` × partition count.

> **On "disk full":** rare not because the disk is too big, but because **retention is
> designed to prevent it** — time-based retention caps each partition at ≈ throughput ×
> window and continuously deletes old segments, reaching a steady state. Disk-full still
> *can* happen for reasons retention doesn't govern (retention set higher than the disk
> holds, another high-volume topic sharing the volume, partition skew, a runaway producer,
> a stuck segment) — but that's ops/capacity-planning territory, separate from the
> consumer-loss path. **Retention is the real threshold for this design.**

---

## The Solution

### Tier 1 — Bounded retry (existing, kept)
For genuine transient blips (e.g. a failover resolving in seconds). Unchanged.

### Tier 2 — Pause / resume with backoff (primary outage handler)
When retries exhaust on an **infrastructure** failure, **pause** the partition instead of
escalating to non-recoverable. Keep polling (cheap empty polls), check DB health each cycle,
`resume()` on recovery. Rides out outages of arbitrary length, honors the invariant, no
rebalance, no hot loop, no audit pollution.

- Ideally driven by a DB `HealthIndicator` so the container pauses **proactively** at the
  container level, rather than discovering the outage one failed record at a time.

### Tier 3 — Stop container + external restart (fallback breaker)
`CommonContainerStoppingErrorHandler` stops the listener; an external supervisor (k8s probe
/ health check / `KafkaListenerEndpointRegistry`) restarts it when healthy. Same invariant,
but heavier (rebalance, discarded in-flight state, cold-start cost). **Reserve for
consumer-level wedging** (poisoned connection pool, wedged client state) — *not* the default
for DB outage, where it's strictly worse than pause.

### Why **no DLT**
The exceptions table is already the terminal sink, so a DLT is redundant. The *only*
scenario it would help is a conjunction:

> non-recoverable event **AND** DB outage **AND** retention window exceeded / broker disk full

That's a conjunction of independent low-probability conditions. Once pause + lag-vs-retention
alerting keeps you well inside the retention window, the conjunction effectively cannot
arise. A DLT would add ordering complexity (the main stream advances past the dead-lettered
record; strict per-key order across the split needs stateful "poisoned-key" routing) and a
reconciliation path — complexity paid against a risk already designed out.

The cleaner rule sidesteps it entirely: **gate the partition on DB health, not on the
event's classification.** One durable sink serves both paths, so if it's down, pause —
regardless of whether the current record is recoverable or non-recoverable. Nothing is
skipped, so order is preserved trivially; when the DB returns, write the deserialization
failure to the exceptions table and proceed as normal.

---

## Operational Backstops

- **Idempotency.** Not committing guarantees redelivery; the previously-failed message is
  reprocessed when the DB returns. Keep processing idempotent (the event-delivery mapping is
  presumably the dedup key). Confirm the exceptions-row write + event-delivery mapping is a
  **single transaction**; if separate, make the pair idempotent so redelivery doesn't
  double-write.
- **Alerting = a countdown against retention.** Auto-recover on DB health, but a partition
  paused beyond a threshold must **page someone** — a silently stalled consumer is the
  failure mode that replaces the hot loop. Watch **consumer lag / oldest-unconsumed-offset
  age against retention**, not pause duration in isolation. With 7-day retention, paging at
  ~1 hour of continuous pause leaves enormous runway, and the silent-loss scenario never
  gets a chance to happen.

---

## One-line summary for the design doc

> *Offset never advances without a durable DB write; during DB unavailability the partition
> pauses (bounded retry for blips, indefinite pause for outages) rather than advancing or
> hot-looping, with stop/restart as a consumer-level fallback and lag-vs-retention alerting
> as the backstop against silent loss.*
