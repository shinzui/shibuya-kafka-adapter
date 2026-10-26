# 0002: Hold replayed records behind a pending retry

- Status: Accepted
- Date: 2026-10-26

## Context

Dropping every polled successor above a pending retry barrier loses the replayed
successors as well as the stale originals. Even if all handlers succeed, stored
and committed offsets then stop just after the retried record. Single-record
emission would prevent this at the cost of starving batch processors.

## Decision

Stamp polled records with a global seek serial under the consumer lock. Each
partition records its last completed seek serial and counts accepted retry
requests and completed seeks. Discard stale records and records whose seek is
outstanding. Emit a fresh replay of the barrier offset, then hold its successors
until that replay is resolved. A repeated retry makes the held records stale.

State mutation and wake publication share a short masked IO action. The hold
reads the wake version before reading the ledger, waits interruptibly in STM,
and never owns the consumer lock. Success, dead letter, retry, halt, revocation,
shutdown and fatal acknowledgement failure all end a hold. Cancellation joins
workers and leaves consumer operations available.

If a fresh replay starts above the barrier before its offset has been emitted,
retention or compaction has removed that offset. Abandon it with a warning,
raise the delivery-token floor to fence old callbacks, and resume.

## Consequences

The ingester can run ahead of the processor and batch timeout can emit a lone
replay, preserving liveness. The gate can hold other partitions behind the held
record; it does not promise latency for a handler that never resolves. No
handler ordering guarantee is introduced here: records already handed to the
runner require a separate admission check. Pre-rebalance poll buffers and the
consumer-lock polling cost remain separate issues.

## Evidence

[Plan 16](../plans/16-hold-replayed-successors-so-a-buffered-retry-cannot-stall-partition-commits.md)
records the negative control, broker-free runner regressions and gate benchmark.
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourceGateTest.hs` covers holds,
gaps, cancellation and batch timeout. Live commit and restart validation remains
pending host access to Redpanda; the deterministic tests do not certify that gate.
