# shibuya-kafka-adapter

Kafka adapter for the [Shibuya](https://github.com/shinzui/shibuya) queue-processing framework.

Integrates with Apache Kafka via [`kafka-effectful`](https://github.com/shinzui/kafka-effectful) for the consumer effect (polling, offset store, partition pause) and [`hw-kafka-streamly`](https://hackage.haskell.org/package/hw-kafka-streamly) for error classification (`skipNonFatal`), on top of [`hw-kafka-client`](https://github.com/haskell-works/hw-kafka-client). Provides polling, offset commit semantics, partition awareness, and graceful shutdown.

## Runtime Contract

Run this adapter with serial message processing only. librdkafka stores the highest offset per partition and does not track gaps, so concurrent finalization can commit past an earlier message that failed, halted, or requested retry. The adapter cannot inspect the processor concurrency policy at construction time; avoiding `Async` and `Ahead` processing is a caller contract until a gap-tracking commit layer exists.

Offset reset policy belongs to the `Subscription` passed to `runKafkaConsumer`, for example `topics [TopicName "orders"] <> offsetReset Earliest`. `KafkaAdapterConfig.topics` is metadata used for adapter naming and a construction-time warning if it differs from the live subscription.

`AckRetry` preserves the earliest unresolved delivery for the partition, seeks back to that offset, and does not store it. Later buffered callbacks cannot replace or cross that recovery boundary; only a newer replay of the boundary delivery can resolve it. Records polled before the seek are discarded. Replayed successors wait behind the retried record until it is resolved; if retention or compaction removed that offset, the adapter warns, abandons the missing record, and resumes at the next available offset. `AckDeadLetter` stores the offset so the consumer group moves on, prints `[shibuya-kafka-adapter] WARNING: dead-lettered message DROPPED` to stderr, and makes the message unrecoverable from the group's committed position. This adapter does not include a DLQ producer.

Under serial single-message processing, already-buffered successors are skipped before handler entry and redelivered after the retried record resolves. This preserves partition handler order, subject to the missing-offset recovery policy. A retry cannot undo successors already admitted in the same batch; later superseded batches are skipped. Concurrent processing is unsupported and can admit a successor before the retry is recorded.

Kafka does not expose a per-message delivery-attempt counter through this consumer API, so `Envelope.attempt` is always `Nothing`. Handlers that need bounded retries must use their own store or return `AckHalt` to stop the stream.

`AckHalt` pauses the originating partition and stops the processor. Polling then stops; after `max.poll.interval.ms` (librdkafka default: 300000 ms, or 5 minutes) the broker may evict this consumer and rebalance the partition to another group member. A single-member group stalls until restart.

On shutdown, the adapter commits offsets stored so far and signals the source stream to stop. Let the surrounding `runKafkaConsumer` scope end normally after stopping the app so the consumer close path can flush offsets stored during the drain window.

For rebalance fencing, create state with `newKafkaAdapterState`, install `Kafka.Consumer.setCallback (Kafka.Consumer.rebalanceCallback (kafkaRebalanceHandler state))` before consumer creation, and pass the same state to `kafkaAdapterWith`. The helper logs assignment changes, clears local recovery state on revocation, and advances a partition generation so callbacks retained by the old owner cannot store, seek, or pause the new assignment. Callers that omit the optional callback do not get that ownership fence.

## Packages

- `shibuya-kafka-adapter` — the adapter library (`Shibuya.Adapter.Kafka`, `.Config`, `.Convert`).
- `shibuya-kafka-adapter-bench` — micro-benchmarks for the conversion hot path (`ConsumerRecord` → `Envelope`, W3C header extraction, timestamps).
- `shibuya-kafka-adapter-jitsurei` — runnable examples: `BasicConsumer`, `MultiTopic`, `MultiPartition`, `OffsetManagement`.

## Building

The repo ships a Nix flake and `direnv` config for a reproducible toolchain.

```sh
direnv allow        # or: nix develop
cabal build all
redpanda-local-up   # Apple Silicon macOS; project-local broker
cabal test shibuya-kafka-adapter
```

Benchmarks and examples:

```sh
cabal bench shibuya-kafka-adapter-bench
cabal run BasicConsumer
```

## Development

Common development tasks are available as `just` recipes. Run `just` (with no arguments) for the full list. For tests on Apple Silicon macOS, run `just redpanda-up`, then `just test`.
The `nix.redpanda` setting supplies `redpanda-local-{up,down,status,logs,purge}`
commands. The private broker is named `shibuya-kafka-adapter-rp-0` and listens on
`127.0.0.1:29092`; its Admin API uses port `29644`. Its names and ports are
separate from the shared cluster. `just redpanda-down` stops it and preserves data.

The Nix shell defaults `KAFKA_TEST_BROKER` to `127.0.0.1:29092`. Tests use that
endpoint for both clients and topic creation. Override it explicitly to test
another broker, for example
`KAFKA_TEST_BROKER=127.0.0.1:9092 cabal test shibuya-kafka-adapter`.
Outside the Nix shell, the test helper retains the shared-broker default at
`127.0.0.1:9092`. Other platforms can select any reachable Kafka-compatible broker
through the same variable.

`just process-up` also starts the private broker and the configured Jaeger process.
The example topic recipes and examples retain their existing Kafka configuration;
set their broker endpoint separately when using them with the private cluster.

## Notes

### Error classification

The adapter filters non-fatal Kafka errors via `skipNonFatal` from `hw-kafka-streamly`. This drops poll timeouts and partition-EOF markers alongside genuinely benign errors. If your application relies on observing partition EOF (for example, to terminate a bounded read), the upstream `Kafka.Streamly.Stream.skipNonFatalExcept` helper takes a predicate list that lets EOFs through; use it in place of the adapter and build your own envelope conversion if you need that behavior.

## Layout

```
shibuya-kafka-adapter/            library sources and tests
shibuya-kafka-adapter-bench/      tasty-bench micro-benchmarks
shibuya-kafka-adapter-jitsurei/   runnable usage examples
docs/plans/                       execution plans
mori.dhall                        project manifest (mori registry)
```

## License

MIT. See package cabal files for details.


With `kafkaRebalanceHandler` installed, deliveries already revoked when their status is checked are skipped before handler entry. A revocation after that admission check cannot cancel an admitted handler.


The adapter requires the published `shibuya-core ^>=0.12.0.0`. Build against
Hackage without a local `cabal.project.local` override for core.
