# Changelog

## 0.8.0.1 — 2026-07-05

### Other Changes

- Require `shibuya-core ^>=0.8.0.1`, picking up the upstream patch release
  with hot-path allocation fixes for `Async` and `Ahead` processing.
- Keep the example and benchmark packages on the shared `0.8.0.1` repo
  version line.

## 0.8.0.0 — 2026-07-04

### Breaking Changes

- Require `shibuya-core ^>=0.8.0.0`.
- Remove the dead `KafkaAdapterConfig.offsetReset` field. Offset reset policy
  belongs to the `Subscription` passed to `runKafkaConsumer`; `topics` remains
  adapter metadata and is checked against the live subscription with a stderr
  warning on mismatch.

### New Features

- Add `kafkaAdapterWith`, `newKafkaAdapterState`, and
  `kafkaRebalanceHandler` for callers that want rebalance logging and eager
  cleanup of retry barriers for revoked partitions.
- Compute Kafka headers once in `consumerRecordToEnvelope` and expose
  `extractTraceHeadersFromList` for callers that already have a materialized
  header list.

### Bug Fixes

- `AckRetry` now seeks the partition back to the failed message instead of
  storing the offset, preserving at-least-once redelivery.
- Handler-exception retries from core no longer allow later buffered messages
  to commit past the failed offset.
- Ack-path Kafka errors are classified inside `finalize`; transient failures
  are retried briefly, and persistent failures terminate the source stream as
  adapter errors instead of handler errors.
- `AckHalt` pause failures no longer cancel the halt decision.
- Idle shutdown exits promptly and ignores Kafka's no-offset response when
  there is nothing to commit.
- `AckDeadLetter` still stores the offset, but now emits a prominent stderr
  warning because this adapter does not include a DLQ producer.

### Other Changes

- Use the `shibuya-core 0.8.0.0` adapter-facing `mkEnvelope` and
  `mkIngested` smart constructors, and update runnable examples to the
  `runApp defaultAppConfig` / `Message` handler API.
- Document the Serial-only processing contract, the dead-letter limitation,
  Kafka's lack of delivery-attempt counts, halt/eviction behavior, and shutdown
  ordering.
- Keep the example and benchmark packages on the shared `0.8.0.0` repo version
  line.

## 0.7.0.0 — 2026-06-05

### Changed

- Require `shibuya-core ^>=0.7.0.0`. `Envelope` now carries a
  `headers :: Maybe Headers` field; `consumerRecordToEnvelope` populates it
  with every Kafka header verbatim (ordered, duplicates preserved) via
  `headersToList`. A record with no headers yields `Just []`. The parsed W3C
  trace headers continue to appear in `traceContext` and now also appear
  verbatim in `headers`.

## 0.6.0.0 — 2026-05-31

### Breaking Changes

- Tracks the `shibuya-core 0.6.0.0` release and the `hs-opentelemetry`
  1.0 package set. The framework's per-message OpenTelemetry span now
  emits `messaging.operation.type="process"` instead of the deprecated
  `messaging.operation="process"` key. Dashboards, alerts, and trace
  queries filtering on the old key must be updated.
- Bumps the `kafka-effectful` dependency to `^>=0.3.0.0`, the first
  release with native `hs-opentelemetry` 1.0 support.

### Other Changes

- Bumps direct OpenTelemetry dependencies to
  `hs-opentelemetry-api ^>=1.0` and
  `hs-opentelemetry-semantic-conventions ^>=1.40`.
- Bumps example-only OpenTelemetry dependencies to the 1.0 package set:
  `hs-opentelemetry-sdk`, `hs-opentelemetry-exporter-otlp`, and
  `hs-opentelemetry-instrumentation-hw-kafka-client`.
- Updates the OpenTelemetry examples for the 1.0
  `shutdownTracerProvider` API, which now takes an optional timeout.

## 0.5.0.1 — 2026-05-08

### Changed

- Upgraded `hw-kafka-streamly` dependency from `^>=0.1` to `^>=0.2`. The
  upstream 0.2.0.0 release renames `Kafka.Streamly.Source` to
  `Kafka.Streamly.Stream` and `Kafka.Streamly.Sink` to `Kafka.Streamly.Fold`
  to match Streamly's native vocabulary. The adapter only used `skipNonFatal`
  and `isFatal` from the renamed module, both of which keep identical
  signatures; this is a mechanical import rename with no API-shape change.
  Haddock cross-references in `Shibuya.Adapter.Kafka` and
  `Shibuya.Adapter.Kafka.Internal` are updated accordingly.

## 0.5.0.0 — 2026-05-05

### Breaking Changes

- Tracks the `shibuya-core 0.5.0.0` release, which adds an
  `attributes :: !(HashMap Text Attribute)` field to the `Envelope`
  record exported from `Shibuya.Core.Types`. The adapter's
  `consumerRecordToEnvelope` now populates this field with
  Kafka-typed OpenTelemetry attributes:
  `messaging.system="kafka"` (overrides the framework default of
  `"shibuya"`), the typed `messaging.kafka.destination.partition`
  (`Int64`) and `messaging.kafka.message.offset` (`Int64`).
- The opt-in module `Shibuya.Adapter.Kafka.Tracing` is **deleted**.
  Its single export `traced :: TopicName -> Stream (Eff es)
  (Ingested es v) -> Stream (Eff es) (Ingested es v)` opened a
  duplicate Consumer-kind span per message under `runApp`, with
  the typed Kafka attributes split across the two spans (see plan
  9 of the `shinzui/shibuya` repo, Finding F1). The same job is
  now done by the framework's `processOne`, which reads
  `Envelope.attributes` and emits exactly one span. Callers that
  imported `traced` should remove the import and the
  `traced topic source` step; the rest of the wiring (the
  `runApp` / `runWithMetrics` integration) is unchanged.
- The companion test
  `Shibuya.Adapter.Kafka.TracingTest` is deleted; its assertions
  (span shape, attribute set, ack passthrough) move into the
  framework's `Shibuya.Telemetry.SemanticSpec` upstream and into
  this repo's `Shibuya.Adapter.Kafka.ConvertTest` (the
  attribute-set assertions, against the envelope produced by
  `consumerRecordToEnvelope` in isolation).

### Other Changes

- Bumps the `shibuya-core` build-depends pin to `^>=0.5` in all
  three packages of this repo (`shibuya-kafka-adapter`,
  `shibuya-kafka-adapter-bench`, `shibuya-kafka-adapter-jitsurei`).
- The `shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs` example is
  refactored to drive its message stream through Shibuya's
  `runWithMetrics`, so the framework's `processOne` opens the
  per-message span. The pre-deletion `traced` shape opened a
  sibling span; the new shape emits exactly one Consumer-kind
  span per message, parented on the producer's `traceparent`
  when present, carrying the spec-aligned messaging attributes
  plus the typed `messaging.kafka.*` attributes.
- `unordered-containers ^>=0.2` is now a direct build-depends of
  `shibuya-kafka-adapter` (library and test stanzas) since
  `Convert.hs` constructs the new attribute `HashMap`.

## 0.4.0.0 — 2026-04-29

### Breaking Changes

- Tracks the `shibuya-core 0.4.0.0` release, which adds an
  `attempt :: !(Maybe Attempt)` field to the `Envelope` record
  exported from `Shibuya.Core.Types`. The adapter's
  `consumerRecordToEnvelope` now sets this field to `Nothing`,
  consistent with the upstream guidance that adapters which cannot
  observe broker-side redeliveries (e.g. Kafka) report `Nothing`.
  Downstream code that pattern-matches on `Envelope` with positional
  patterns or with non-punned record patterns that name every field
  must be updated.

### Other Changes

- Bumps the `shibuya-core` build-depends pin to `^>=0.4` in all three
  packages of this repo.
- Drops three orphan `NFData` instances (`MessageId`, `Cursor`,
  `Envelope a`) from `shibuya-kafka-adapter-bench/bench/Main.hs`;
  these instances have been provided upstream by `shibuya-core` since
  `0.2.0.0` and the orphans had become duplicate-instance hazards
  whenever the bench resolved against a `shibuya-core` newer than
  `0.1`.
- `shibuya-kafka-adapter-bench` and `shibuya-kafka-adapter-jitsurei`
  are re-released at `0.4.0.0` to track the shared version of this
  repo; neither has user-visible changes of its own.

## 0.3.0.0 — 2026-04-22

Telemetry wire-format change. No Haskell API break —
`Shibuya.Adapter.Kafka.Tracing.traced`'s signature is unchanged — but
operators with dashboards filtering on the old attribute-key strings
or span name must update their queries.

### Changed

- Per-message spans now follow the OpenTelemetry messaging
  semantic-conventions span-name pattern `"<destination> <operation>"`,
  yielding e.g. `"orders process"` in place of the previous constant
  `"shibuya.process.message"`.
- The `messaging.operation` attribute is now set to `"process"` on
  every consumer span.
- The Kafka partition is now emitted as the typed Kafka-specific key
  `messaging.kafka.destination.partition` (Int64), replacing the
  never-defined `messaging.destination.partition.id` (Text). If the
  envelope's partition text does not parse as an integer, the
  shibuya-namespaced `shibuya.partition` is emitted as a defensive
  fallback.
- The Kafka offset is now emitted as `messaging.kafka.message.offset`
  (Int64), derived from `Envelope.cursor` when it is a `CursorInt`.

### Aligned with

- `Shibuya.Telemetry.Semantic` as of sibling `shibuya` plan 2
  (`docs/plans/2-align-opentelemetry-semantic-conventions.md` in the
  shibuya repo). Attribute keys for the generic `messaging.*`
  namespace are sourced from that module, which in turn derives them
  from typed `AttributeKey` values in
  `OpenTelemetry.SemanticConventions`.
- `OpenTelemetry.SemanticConventions` (new direct `build-depends`)
  for the typed Kafka-specific keys
  `messaging_kafka_destination_partition` and
  `messaging_kafka_message_offset`.

## 0.2.0.0 — 2026-04-18

Additive release. Adds one new exposed module, no changes to existing
public types or to `kafkaAdapter`'s signature.

### Added

- `Shibuya.Adapter.Kafka.Tracing` exposing a single stream transformer
  `traced :: (Tracing :> es, IOE :> es) => TopicName -> Stream (Eff es)
  (Ingested es v) -> Stream (Eff es) (Ingested es v)`. For each emitted
  `Ingested`, `traced` rewrites the envelope's `AckHandle` so that
  when the downstream handler calls `finalize` the call is enclosed
  in a Consumer-kind `shibuya.process.message` span parented on the
  envelope's carried W3C `traceparent` (or a root span when absent).
  The span carries the v1.27 messaging-conventions attribute set
  (`messaging.system`, `messaging.destination.name`,
  `messaging.message.id`, and — when partition is known —
  `messaging.destination.partition.id`) from
  `Shibuya.Telemetry.Semantic`.

- Explicit `hs-opentelemetry-api ^>=0.3` build-depends edge on the
  library. The package was previously in the closure transitively via
  `shibuya-core`, but cabal does not let a library import from a
  transitively-present dependency.

## 0.1.0.0 — 2026-04-18

Initial release.

`shibuya-kafka-adapter` bridges Apache Kafka to the
[Shibuya](https://github.com/shinzui/shibuya) queue-processing framework. It
builds on [`kafka-effectful`](https://github.com/shinzui/kafka-effectful) for
the consumer effect (polling, offset store, partition pause) and
[`hw-kafka-streamly`](https://hackage.haskell.org/package/hw-kafka-streamly)
for error classification (`skipNonFatal`), on top of
[`hw-kafka-client`](https://github.com/haskell-works/hw-kafka-client).

### Features

- Poll-driven consumer that produces Shibuya `Envelope` values from Kafka
  `ConsumerRecord`s.
- Offset-commit semantics combining `noAutoOffsetStore`, explicit
  `storeOffsetMessage` on successful acknowledgement, and librdkafka
  auto-commit of the stored offsets.
- Partition-aware dispatch: `Envelope`s carry topic/partition/offset, and
  `AckHalt` pauses the originating partition via the consumer effect.
- W3C `traceparent` / `tracestate` header extraction from Kafka message
  headers, surfaced on the Shibuya `Envelope` for OpenTelemetry propagation.
- Kafka message timestamp conversion to Shibuya's `UTCTime` representation.
- Graceful shutdown that calls `commitAllOffsets` so stored offsets are
  flushed before the consumer handle closes.

### Known Limitations

- No automatic partition resume after `AckHalt` within the consumer session;
  resumption is left to the operator or the next rebalance.
- No dead-letter queue production. `AckDead` stores the offset so the stream
  advances past the poison message but does not publish it anywhere.
