---
title: "ConsumerRecord to Envelope conversion with trace context and OTel attributes"
type: Capability
description: "Convert a Kafka ConsumerRecord to a Shibuya Envelope with W3C trace-context extraction, verbatim header passthrough, typed Kafka OTel attributes, and timestamp conversion."
generated:
  by: claude-cli/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-3
provider: mori://shinzui/shibuya-kafka-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-kafka-adapter
interface:
  - Shibuya.Adapter.Kafka.Convert.consumerRecordToEnvelope
  - Shibuya.Adapter.Kafka.Convert.extractTraceHeaders
  - Shibuya.Adapter.Kafka.Convert.extractTraceHeadersFromList
  - Shibuya.Adapter.Kafka.Convert.timestampToUTCTime
evidence:
  - kind: test
    resource: shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/ConvertTest.hs
    proves: "Broker-free: messageId is `topic-partition-offset`, cursor/partition/timestamp mapping, W3C `traceparent`/`tracestate` extraction, and the typed `messaging.kafka.*` attribute set produced from an isolated `ConsumerRecord`."
  - kind: benchmark
    resource: shibuya-kafka-adapter-bench/bench/Main.hs
    proves: "The conversion and header-extraction hot paths run standalone (no broker), showing the pure functions are usable and measurable in isolation."
---

# ConsumerRecord to Envelope conversion

`consumerRecordToEnvelope` is the pure boundary between Kafka and Shibuya. It is
used internally by the Kafka message source (CAP-1), but it is a public,
broker-free function you can call and test directly. It maps a Kafka
`ConsumerRecord` to a Shibuya `Envelope`:

- **messageId** — `"{topic}-{partition}-{offset}"`, unique within a cluster.
- **cursor / partition** — `CursorInt offset` and the partition id as text.
- **enqueuedAt** — Kafka `CreateTime`/`LogAppendTime` converted to `UTCTime`
  (`Nothing` for `NoTimestamp`), via `timestampToUTCTime`.
- **traceContext** — W3C `traceparent` (and `tracestate` when present) parsed
  from the record headers, via `extractTraceHeaders` /
  `extractTraceHeadersFromList`; `Nothing` when no `traceparent` is present.
- **headers** — every Kafka header verbatim (ordered, duplicates preserved);
  `Just []` for a record with no headers.
- **attributes** — typed OpenTelemetry attributes `messaging.system="kafka"`,
  `messaging.kafka.destination.partition` (Int64), and
  `messaging.kafka.message.offset` (Int64).

```haskell
import Shibuya.Adapter.Kafka.Convert (consumerRecordToEnvelope)

envelope = consumerRecordToEnvelope record
```

## History

The base conversion (messageId, cursor, partition, timestamp, trace headers)
shipped in `0.1.0.0`. Two fields were added later and are part of this record
only from those releases onward: the typed OTel `attributes` in `0.5.0.0`, and
verbatim `headers` passthrough in `0.7.0.0`. A consumer pinning an older release
sees the base conversion without those fields.

## Limits

- **This repository populates the envelope; it does not emit the span.** The
  actual per-message OpenTelemetry span is opened by `shibuya-core`'s runner,
  which reads `Envelope.attributes` and `traceContext`. End-to-end span shape is
  therefore a property of the consuming app composed with `shibuya-core`, not of
  this repository — see the exclusion note in the catalog index (`index.md`).
- **The old `Shibuya.Adapter.Kafka.Tracing` module is gone.** It was deleted in
  `0.5.0.0`; `docs/otel-tracing.md` still describes it and is stale. Do not treat
  that document as evidence of a current capability.
- **Attribute assertions are unit-level.** `ConvertTest` checks the attribute
  set on the envelope in isolation; that the framework actually attaches them to
  a live span is verified upstream in `shibuya-core`, not here.
</content>
