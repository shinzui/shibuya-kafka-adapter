---
title: "At-least-once offset & acknowledgement semantics"
type: Capability
description: "Map Shibuya ack decisions to Kafka offset store, seek-back redelivery, partition pause, and shutdown commit for at-least-once delivery."
generated:
  by: claude-cli/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-2
provider: mori://shinzui/shibuya-kafka-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-kafka-adapter
interface:
  - Shibuya.Adapter.Kafka.kafkaAdapter
  - Shibuya.Adapter.Kafka.kafkaRebalanceHandler
  - Shibuya.Adapter.Kafka.newKafkaAdapterState
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/AckHandleTest.hs
    proves: "Broker-free: `AckRetry` seeks the exact failed offset and does not store, the seek barrier prevents a stale successor from committing past a retried message, and transient ack-path Kafka errors retry before recording a fatal slot."
  - kind: test
    resource: shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs
    proves: "Against a live broker, `Offset commit verification`, `AckRetry redelivers within the same session`, `AckRetry is not committed past when session exits`, `Handler exception redelivers instead of skipping`, and the graceful-shutdown cases confirm at-least-once behavior end to end."
---

# At-least-once offset & acknowledgement semantics

Adopting the [Kafka message source](kafka-message-source.md) also commits you to
this offset model, which is what makes delivery at-least-once. Each Shibuya ack
decision maps to a Kafka operation:

- `AckOk` — store the message offset (`storeOffsetMessage`); librdkafka
  auto-commit or consumer close later flushes it.
- `AckRetry` — record a per-partition seek barrier and seek the partition back
  to the failed offset so Kafka redelivers it; the offset is **not** stored.
- `AckDeadLetter` — emit a loud stderr warning and then store the offset so the
  group moves past the poison message.
- `AckHalt` — pause the originating partition and do not store the offset.

The consumer runs with `noAutoOffsetStore` plus manual `storeOffsetMessage` and
auto-commit. On `shutdown` the adapter calls `commitAllOffsets` to flush offsets
stored so far; let the surrounding `runKafkaConsumer` scope end normally so the
close path flushes offsets stored during the drain window. A seek barrier drops
records already buffered above a pending retry so a later record cannot commit
past the failed one.

For rebalance visibility, allocate state with `newKafkaAdapterState`, install
`kafkaRebalanceHandler` via `setCallback`/`rebalanceCallback` before creating the
consumer, and pass the same state to `kafkaAdapterWith`.

## Limits

- **At-least-once `AckRetry` was corrected in 0.8.0.0.** Before that release
  `AckRetry` stored the offset instead of seeking back, so a retried message
  could be skipped. A consumer pinning `0.1.0.0`–`0.7.x` does **not** get the
  redelivery guarantee this record describes even though the ack surface looks
  the same.
- **Dead letters are dropped.** There is no DLQ producer. `AckDeadLetter` stores
  the offset and prints `[shibuya-kafka-adapter] WARNING: dead-lettered message
  DROPPED`, making the message unrecoverable from the group's committed position.
- **No delivery-attempt counter.** Kafka does not expose per-message redelivery
  counts through this consumer API, so `Envelope.attempt` is always `Nothing`;
  handlers cannot bound retries by counting attempts. Use an external store or
  return `AckHalt`.
- **Halt stalls a single-member group.** `AckHalt` pauses the partition and
  stops polling; after `max.poll.interval.ms` (librdkafka default 5 min) the
  broker may evict the member and rebalance, but a single-member group stalls
  until restart. Paused state is session-local.
- **`kafkaRebalanceHandler` is unevidenced.** It has no dedicated automated test
  (exercising it requires a real broker rebalance); its stderr logging and
  barrier cleanup are covered only by the module's own reasoning.
- **Serial-only** — see [CAP-1](kafka-message-source.md); concurrent
  finalization breaks these guarantees.
</content>
