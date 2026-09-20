---
title: "At-least-once offset & acknowledgement semantics"
type: Capability
description: "Map Shibuya ack decisions to Kafka offset store, seek-back redelivery, partition pause, and shutdown commit for at-least-once delivery."
generated:
  by: codex-cli/gpt-6-astra
  at: "2026-09-20T22:30:00Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-20T22:30:00Z"
    document_timestamp: "2026-09-20T22:30:00Z"
    scope: content-and-metadata
    outcome: approved
    context: "Repository source, deterministic acknowledgement tests, live-broker integration tests, and the EP-40 lifecycle audit."
    provider: openai
    model: gpt-6-astra
    effort: high
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
    proves: "Broker-free: fixed-seed reference sequences preserve the earliest unresolved offset, duplicate callbacks are idempotent, revoked callbacks are fenced, cancellation releases both locks, seek timeouts are bounded, and exhausted ack operations throw synchronously."
  - kind: test
    resource: shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs
    proves: "Against a live broker, buffered retries retain their earliest recovery boundary, restart recovers uncommitted work, synthetic and actual revocation reject old-owner callbacks, and idle/repeated shutdown terminate safely."
---

# At-least-once offset & acknowledgement semantics

Adopting the [Kafka message source](kafka-message-source.md) also commits you to
this offset model, which is what makes delivery at-least-once. Each Shibuya ack
decision maps to a Kafka operation:

- `AckOk` — store the message offset (`storeOffsetMessage`); librdkafka
  auto-commit or consumer close later flushes it.
- `AckRetry` — preserve the earliest unresolved delivery for the partition and
  seek back to that offset so Kafka redelivers it; the offset is **not** stored.
- `AckDeadLetter` — emit a loud stderr warning and then store the offset so the
  group moves past the poison message.
- `AckHalt` — pause the originating partition and do not store the offset.

The consumer runs with `noAutoOffsetStore` plus manual `storeOffsetMessage` and
auto-commit. On `shutdown` the adapter calls `commitAllOffsets` to flush offsets
stored so far; let the surrounding `runKafkaConsumer` scope end normally so the
close path flushes offsets stored during the drain window. Each delivery gets a
monotonic token. A per-partition recovery barrier remembers the earliest
unresolved offset and the token that requested its replay: later buffered
callbacks cannot replace or cross it, and only a newer replay of that offset can
clear it. Successful duplicate finalization is a no-op; a failed or cancelled
finalization remains retryable.

For rebalance visibility, allocate state with `newKafkaAdapterState`, install
`kafkaRebalanceHandler` via `setCallback`/`rebalanceCallback` before creating the
consumer, and pass the same state to `kafkaAdapterWith`. The callback tracks an
assignment generation and fences store, seek, and pause callbacks retained by a
revoked owner. This fence is opt-in because `kafka-effectful` requires callbacks
to be installed before consumer creation.

## Limits

- **At-least-once `AckRetry` was corrected in 0.8.0.0.** Before that release
  `AckRetry` stored the offset instead of seeking back, so a retried message
  could be skipped. A consumer pinning `0.1.0.0`–`0.7.x` does **not** get the
  redelivery guarantee this record describes even though the ack surface looks
  the same.
- **Dead letters are dropped.** There is no DLQ producer. `AckDeadLetter` stores
  the offset and prints `[shibuya-kafka-adapter] WARNING: dead-lettered message
  DROPPED`, making the message unrecoverable from the group's committed position.
  From 0.9.0.0 the warning renders the reason with Shibuya's canonical
  `renderDeadLetterReason` (`reason=<code>` or `reason=<code>: <detail>`), so a
  dead-letter code greps identically here and in the payloads
  `mori://shinzui/shibuya-pgmq-adapter` writes to its DLQ. The log line is the
  only record; it is not a durable or machine-consumed interface.
- **No delivery-attempt counter.** Kafka does not expose per-message redelivery
  counts through this consumer API, so `Envelope.attempt` is always `Nothing`;
  handlers cannot bound retries by counting attempts. Use an external store or
  return `AckHalt`.
- **Halt stalls a single-member group.** `AckHalt` pauses the partition and
  stops polling; after `max.poll.interval.ms` (librdkafka default 5 min) the
  broker may evict the member and rebalance, but a single-member group stalls
  until restart. Paused state is session-local.
- **Rebalance fencing requires callback installation.** The live integration
  suite triggers an actual two-consumer group reassignment and proves an old
  owner's late acknowledgement cannot advance the broker offset. Consumers
  using plain `kafkaAdapter` without installing `kafkaRebalanceHandler` retain
  same-assignment retry safety but do not get cross-assignment fencing.
- **Serial-only** — see [CAP-1](kafka-message-source.md); concurrent
  finalization breaks these guarantees.
</content>
