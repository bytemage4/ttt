## Consumer Ack & Error Handling Design

### Core Invariant

Every consumed message must be durably persisted before acknowledgment. A message is either written to the **outbox table** (success) or to the **failed_notifications table** (failure). No other path leads to an ack. If neither write succeeds, the message remains unacknowledged and will be redelivered.

### Acknowledgment Mode

Manual ack (`AckMode.MANUAL` or `MANUAL_IMMEDIATE`). The consumer controls exactly when the offset is committed, ensuring no message is lost between processing and persistence.

### Happy Path

The listener delegates to a transactional service that inserts into the outbox table. If the transaction commits successfully, the listener acks. The ordering is always: DB commit → ack. A failure between these two steps (e.g., consumer crash) results in redelivery, which is safe as long as the outbox insert is idempotent (unique constraint on event ID).

### Recoverable Failure Path

A recoverable exception (transient DB timeout, temporary downstream unavailability) triggers a retry loop. The message is not acked, so Kafka redelivers it. A retry counter tracks attempts. If processing eventually succeeds, the happy path applies — outbox insert, then ack. If the retry count reaches the configured maximum, the message is escalated to the non-recoverable path.

### Non-Recoverable Failure Path

A non-recoverable exception (validation failure, schema mismatch, business rule violation) or an exhausted retry budget triggers a write to the **failed_notifications table**. This write stores the full original message payload, Kafka metadata (topic, partition, offset, headers, timestamp), exception type, exception message, stack trace, and a timestamp. Once this write commits, the listener acks. The message is now durably recorded for investigation and replay.

### Persistence Failure Path

If the write to failed_notifications itself fails (e.g., DB is completely unreachable), the listener does **not** ack. The message stays on the partition and will be redelivered. This is the backstop — no silent message loss under any circumstance. Aggressive logging is critical here, because this state indicates infrastructure-level problems that need operational attention.

### Deserialization Failures

These occur before the listener is invoked, so none of the above logic applies. A custom error handler at the container level (e.g., `CommonErrorHandler`) must catch these, write the raw bytes and error details to failed_notifications, and commit the offset. Without this, a poison pill message blocks the partition indefinitely.

### Retry Counting

Redelivery-based retries (not acking, letting Kafka redeliver) require an external retry counter since Kafka itself doesn't track attempt count. An in-memory counter keyed by topic-partition-offset is the simplest approach. It resets on consumer restart, which is acceptable because a restart also resets the consumer position to the last committed offset — effectively restarting the retry budget. If stricter tracking across restarts is needed, a lightweight DB counter keyed on the message's unique event ID is the alternative, though it adds a DB read to every retry attempt.

### Exception Classification

Exceptions describe the failure. The listener's error handler decides the fate. Domain exceptions are classified as recoverable or non-recoverable via the type hierarchy (e.g., `instanceof RecoverableNotificationException`), and the error handler routes to the appropriate path. The write-to-failed_notifications-then-ack logic lives in one place in the handler, not spread across exception classes.

### Replay Capability

The failed_notifications table serves as both an audit trail and a replay source. After a bugfix deployment, an application-level replay mechanism re-submits messages from this table. Replay does not go through Kafka (the original offset is long committed) — it feeds the stored payload back into the processing logic directly. Replayed messages should be marked in the table to maintain a clear audit history.
