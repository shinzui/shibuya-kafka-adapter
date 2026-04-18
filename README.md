# shibuya-kafka-adapter

Kafka adapter for the [Shibuya](https://github.com/shinzui/shibuya) queue-processing framework.

Integrates with Apache Kafka via [`kafka-effectful`](https://github.com/shinzui/kafka-effectful) for the consumer effect (polling, offset store, partition pause) and [`hw-kafka-streamly`](https://hackage.haskell.org/package/hw-kafka-streamly) for error classification (`skipNonFatal`), on top of [`hw-kafka-client`](https://github.com/haskell-works/hw-kafka-client). Provides polling, offset commit semantics, partition awareness, and graceful shutdown.

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

The adapter filters non-fatal Kafka errors via `skipNonFatal` from `hw-kafka-streamly`. This drops poll timeouts and partition-EOF markers alongside genuinely benign errors. If your application relies on observing partition EOF (for example, to terminate a bounded read), the upstream `Kafka.Streamly.Source.skipNonFatalExcept` helper takes a predicate list that lets EOFs through; use it in place of the adapter and build your own envelope conversion if you need that behavior.

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
