# Changelog

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
