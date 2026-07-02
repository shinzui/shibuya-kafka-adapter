# shibuya-kafka-adapter

Kafka adapter for the [Shibuya](https://github.com/shinzui/shibuya) queue-processing framework.

Integrates with Apache Kafka via [`kafka-effectful`](https://github.com/shinzui/kafka-effectful) for the consumer effect (polling, offset store, partition pause) and [`hw-kafka-streamly`](https://hackage.haskell.org/package/hw-kafka-streamly) for error classification (`skipNonFatal`), on top of [`hw-kafka-client`](https://github.com/haskell-works/hw-kafka-client). Provides polling, offset commit semantics, partition awareness, and graceful shutdown.

## Runtime Contract

Run this adapter with serial message processing only. librdkafka stores the highest offset per partition and does not track gaps, so concurrent finalization can commit past an earlier message that failed, halted, or requested retry. The adapter cannot inspect the processor concurrency policy at construction time; avoiding `Async` and `Ahead` processing is a caller contract until a gap-tracking commit layer exists.

Offset reset policy belongs to the `Subscription` passed to `runKafkaConsumer`, for example `topics [TopicName "orders"] <> offsetReset Earliest`. `KafkaAdapterConfig.topics` is metadata used for adapter naming and a construction-time warning if it differs from the live subscription.

`AckRetry` seeks the partition back to the failed message and does not store that message's offset. `AckDeadLetter` stores the offset so the consumer group moves on, prints `[shibuya-kafka-adapter] WARNING: dead-lettered message DROPPED` to stderr, and makes the message unrecoverable from the group's committed position. This adapter does not include a DLQ producer.

Kafka does not expose a per-message delivery-attempt counter through this consumer API, so `Envelope.attempt` is always `Nothing`. Handlers that need bounded retries must use their own store or return `AckHalt` to stop the stream.

`AckHalt` pauses the originating partition and stops the processor. Polling then stops; after `max.poll.interval.ms` (librdkafka default: 300000 ms, or 5 minutes) the broker may evict this consumer and rebalance the partition to another group member. A single-member group stalls until restart.

On shutdown, the adapter commits offsets stored so far and signals the source stream to stop. Let the surrounding `runKafkaConsumer` scope end normally after stopping the app so the consumer close path can flush offsets stored during the drain window.

For rebalance visibility, create state with `newKafkaAdapterState`, install `Kafka.Consumer.setCallback (Kafka.Consumer.rebalanceCallback (kafkaRebalanceHandler state))` before consumer creation, and pass the same state to `kafkaAdapterWith`. The helper logs rebalance events and clears retry barriers for revoked partitions; in-flight fencing for cooperative rebalances is out of scope.

## Packages

- `shibuya-kafka-adapter` — the adapter library (`Shibuya.Adapter.Kafka`, `.Config`, `.Convert`).
- `shibuya-kafka-adapter-bench` — micro-benchmarks for the conversion hot path (`ConsumerRecord` → `Envelope`, W3C header extraction, timestamps).
- `shibuya-kafka-adapter-jitsurei` — runnable examples: `BasicConsumer`, `MultiTopic`, `MultiPartition`, `OffsetManagement`.

## Building

The repo ships a Nix flake and `direnv` config for a reproducible toolchain.

```sh
direnv allow        # or: nix develop
cabal build all
cabal test shibuya-kafka-adapter
```

Benchmarks and examples:

```sh
cabal bench shibuya-kafka-adapter-bench
cabal run BasicConsumer
```

## Development

Common development tasks are available as `just` recipes. Run `just` (with no arguments) for the full list. The usual flow is `just process-up` in one shell (starts Redpanda via process-compose), `just create-topics`, then `just test` or `just bench` or `cabal run <example>`.

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
