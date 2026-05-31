# shibuya-kafka-adapter

Kafka adapter for the [Shibuya](https://github.com/shinzui/shibuya) queue-processing framework.

Integrates with Apache Kafka via [`kafka-effectful`](https://github.com/shinzui/kafka-effectful) for the consumer effect (polling, offset store, partition pause) and [`hw-kafka-streamly`](https://hackage.haskell.org/package/hw-kafka-streamly) for error classification (`skipNonFatal`), on top of [`hw-kafka-client`](https://github.com/haskell-works/hw-kafka-client). Provides polling, offset commit semantics, partition awareness, and graceful shutdown.

## Packages

- `shibuya-kafka-adapter` — the adapter library (`Shibuya.Adapter.Kafka`, `.Config`, `.Convert`).
- `shibuya-kafka-adapter-bench` — micro-benchmarks for the conversion hot path (`ConsumerRecord` → `Envelope`, W3C header extraction, timestamps).
- `shibuya-kafka-adapter-jitsurei` — runnable examples: `BasicConsumer`, `MultiTopic`, `MultiPartition`, `OffsetManagement`.

## Tracing

Tracing is handled by `shibuya-core`'s supervised runner. `Shibuya.Adapter.Kafka.Convert.consumerRecordToEnvelope` populates `Envelope.attributes` with `messaging.system=kafka` and the Kafka-specific typed attributes `messaging.kafka.destination.partition` (Int64) and `messaging.kafka.message.offset` (Int64). The framework merges those onto its single Consumer-kind per-message span alongside `messaging.destination.name`, `messaging.operation.type=process`, and `messaging.message.id`.

The old opt-in `Shibuya.Adapter.Kafka.Tracing` module was removed in `0.5.0.0`; callers should run the Kafka adapter through Shibuya's normal `runApp` or `runWithMetrics` path instead of wrapping the stream.

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
