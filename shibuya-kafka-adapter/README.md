# shibuya-kafka-adapter

Kafka adapter for the [Shibuya](https://github.com/shinzui/shibuya) queue-processing framework.

Integrates with Apache Kafka via [`kafka-effectful`](https://github.com/shinzui/kafka-effectful) for the consumer effect (polling, offset store, partition pause) and [`hw-kafka-streamly`](https://hackage.haskell.org/package/hw-kafka-streamly) for error classification (`skipNonFatal`), on top of [`hw-kafka-client`](https://github.com/haskell-works/hw-kafka-client). Provides polling, offset commit semantics, partition awareness, and graceful shutdown.

## Packages

- `shibuya-kafka-adapter` — the adapter library (`Shibuya.Adapter.Kafka`, `.Config`, `.Convert`, `.Tracing`).
- `shibuya-kafka-adapter-bench` — micro-benchmarks for the conversion hot path (`ConsumerRecord` → `Envelope`, W3C header extraction, timestamps).
- `shibuya-kafka-adapter-jitsurei` — runnable examples: `BasicConsumer`, `MultiTopic`, `MultiPartition`, `OffsetManagement`.

## Tracing (opt-in)

`Shibuya.Adapter.Kafka.Tracing.traced` is an opt-in stream transformer that wraps each emitted `Ingested` so that the downstream handler's eventual `finalize` call runs inside a Consumer-kind `shibuya.process.message` OpenTelemetry span. The span inherits the envelope's W3C `traceparent` as parent (from `Envelope.traceContext`) or opens a fresh root span when no parent is present, and is populated with the v1.27 messaging-conventions attributes (`messaging.system=kafka`, `messaging.destination.name`, `messaging.message.id`, and `messaging.destination.partition.id` when the partition is known). A caller that does not import this module pays nothing — no spans are opened and the adapter's public surface is unchanged.

Typical wiring:

```haskell
import Shibuya.Adapter.Kafka (kafkaAdapter, defaultConfig)
import Shibuya.Adapter.Kafka.Tracing (traced)
import Shibuya.Telemetry.Effect (runTracing)

runTracing tracer $ do
  Adapter{source} <- kafkaAdapter (defaultConfig [TopicName "orders"])
  Stream.fold Fold.drain
    $ Stream.mapM userHandler
    $ traced (TopicName "orders") source
```

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
