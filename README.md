# shibuya-kafka-adapter

Consume Kafka messages through the [Shibuya](mori://shinzui/shibuya)
queue-processing framework, with explicit acknowledgements, partition-aware
retries, offset management, and OpenTelemetry context propagation.

**Release:** [0.12.0.0 on Hackage](https://hackage.haskell.org/package/shibuya-kafka-adapter-0.12.0.0)
· [API documentation](https://hackage.haskell.org/package/shibuya-kafka-adapter-0.12.0.0/docs/Shibuya-Adapter-Kafka.html)
· [Changelog](shibuya-kafka-adapter/CHANGELOG.md)

The adapter requires `shibuya-core ^>=0.12.0.0` and GHC 9.12. The repository's
Nix shell uses GHC 9.12.4. It builds on
[kafka-effectful](mori://shinzui/kafka-effectful) for consumer operations and
[hw-kafka-streamly](mori://shinzui/hw-kafka-streamly) for poll-error classification.

## Using the adapter

Add these dependencies to your application:

```cabal
build-depends:
  base ^>=4.21,
  effectful-core,
  hw-kafka-client >=5.3 && <6,
  kafka-effectful ^>=0.3.1.0,
  shibuya-core ^>=0.12.0.0,
  shibuya-kafka-adapter ^>=0.12.0.0
```

The consumer scope owns the Kafka connection and subscription. Create the
adapter inside that scope and use `mkProcessor`, which defaults to serial
processing. Disable automatic offset storage so a record's offset is stored
only after acknowledgement.

This example prints messages from `orders` on `localhost:9092`:

```haskell
{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad.IO.Class (liftIO)
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (OffsetReset (Earliest))
import Kafka.Effectful.Consumer qualified as Kafka
import Shibuya.Adapter.Kafka
  ( BrokerAddress (..), ConsumerGroupId (..), KafkaError, TopicName (..)
  , defaultConfig, kafkaAdapter
  )
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, waitApp)
import Shibuya.Core.Ack (AckDecision (AckOk))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)

main :: IO ()
main = do
  result <- runEff . runError @KafkaError . runTracingNoop $ do
    let props = Kafka.brokersList [BrokerAddress "localhost:9092"]
             <> Kafka.groupId (ConsumerGroupId "orders-consumer")
             <> Kafka.noAutoOffsetStore
        sub = Kafka.topics [TopicName "orders"] <> Kafka.offsetReset Earliest
    Kafka.runKafkaConsumer props sub $ do
      adapter <- kafkaAdapter (defaultConfig [TopicName "orders"])
      let handler message = do
            liftIO (print message.envelope.payload)
            pure AckOk
      app <- runApp defaultAppConfig
        [(ProcessorId "orders", mkProcessor adapter handler)]
      case app of
        Left err -> liftIO (fail (show err))
        Right handle -> waitApp handle
  case result of
    Left err -> fail (show err)
    Right () -> pure ()
```

`defaultConfig` polls with a 1,000 ms timeout and a maximum batch size of 100.
Its `topics` field supplies adapter metadata and is checked against the live
subscription. Subscription topics and offset-reset policy belong to
`runKafkaConsumer`.

## Acknowledgements and ordering

**Use serial processing.** The adapter does not support Shibuya's `Async` or
`Ahead` policies. librdkafka stores the highest offset per partition without
tracking gaps; concurrent finalization can commit past unresolved work. The
adapter cannot inspect or enforce the processor's concurrency policy.

| Decision | Adapter behavior |
| --- | --- |
| `AckOk` | Store the record's offset locally; auto-commit or consumer close flushes it to the broker. |
| `AckRetry` | Keep the earliest unresolved delivery as the retry boundary, seek back to it, and leave its offset unstored. |
| `AckDeadLetter` | Store the offset and log a `dead-lettered message DROPPED` warning. The adapter has no DLQ producer. |
| `AckHalt` | Pause the originating partition without storing its offset; the processor stops. |

With serial single-message processing, a retry blocks later messages in the
same partition. Pre-seek records are discarded, already-buffered successors
are skipped before handler entry, and replayed successors wait until the
retried record resolves. Later callbacks cannot replace the earliest retry
boundary or store offsets past it. A retry cannot undo messages already
admitted together in the same handler batch.

If retention or compaction removed the retry offset, the adapter warns and
resumes at the next available record. Kafka provides no delivery-attempt
counter here: `Envelope.attempt` is always `Nothing`. Use an external store
for bounded retry counts, or halt processing.

A dead-letter acknowledgement advances the group's position without publishing
the message elsewhere. Arrange any required DLQ publication before returning
`AckDeadLetter`.

## Rebalances and shutdown

For assignment fencing, create state with `newKafkaAdapterState`, add
`Kafka.Consumer.setCallback (Kafka.Consumer.rebalanceCallback (kafkaRebalanceHandler state))`
to the consumer properties before consumer creation, and construct the adapter
with `kafkaAdapterWith state config`.

The callback logs assignment changes, clears retry state on revocation, and
fences old delivery callbacks so they cannot store, seek, or pause a later
assignment. Deliveries revoked before their admission check are skipped. A
revocation after that check cannot cancel a handler already admitted. The
helper is optional; `kafkaAdapter` alone does not provide this ownership fence.

Keep the consumer scope open while stopping the Shibuya application. Adapter
shutdown signals the source to stop and commits offsets already stored. Let
`runKafkaConsumer` close normally afterward so it can flush offsets stored
during draining.

After `AckHalt`, polling stops. The consumer can lose its assignment when
`max.poll.interval.ms` expires; a single-member group needs a restart to resume.
Partition pause state belongs to the consumer session.

## Errors and tracing

Non-fatal poll errors, including timeouts and partition EOFs, are filtered out.
Fatal poll errors terminate the source through `Error KafkaError`. Exhausted
acknowledgement operations throw `KafkaAcknowledgementException` at the
finalizer boundary so Shibuya can retain the processor failure.

The adapter preserves Kafka headers, extracts W3C `traceparent` and `tracestate`,
and adds `messaging.system=kafka`, `messaging.kafka.destination.partition`, and
`messaging.kafka.message.offset` to the envelope. Shibuya's runner uses these
attributes on its per-message span. The example above disables tracing with
`runTracingNoop`; use the configured tracing interpreter to export spans.

## Development

Enter the reproducible toolchain with `nix develop`, or run `direnv allow`.
Build against published dependencies without a local core package override:

```sh
cabal update
cabal build all --enable-benchmarks
```

Integration tests require a Kafka-compatible broker. On Apple Silicon macOS,
the shell provides a private Redpanda cluster:

```sh
just redpanda-up
just test
just redpanda-down
```

The broker is `shibuya-kafka-adapter-rp-0` at `127.0.0.1:29092`, with its Admin
API on `29644`. Stopping it preserves its data. The Nix shell sets
`KAFKA_TEST_BROKER` to this private endpoint; tests use it for both clients and
topic creation. To use another broker on any platform:

```sh
KAFKA_TEST_BROKER=127.0.0.1:9092 cabal test shibuya-kafka-adapter
```

Outside the Nix shell, tests default to `127.0.0.1:9092`.
`just process-up` starts the private broker and Jaeger; stop the broker
separately with `just redpanda-down` when finished.

Other checks and tools:

```sh
nix fmt
nix build --no-link
nix flake check
cabal bench shibuya-kafka-adapter-bench
cabal haddock shibuya-kafka-adapter
```

Run `just` to list available recipes.

## Examples and repository layout

Only `shibuya-kafka-adapter` is published to Hackage. The examples and benchmarks
share its version within this repository.

| Path | Contents |
| --- | --- |
| `shibuya-kafka-adapter/` | Library, tests, package README, and changelog |
| `shibuya-kafka-adapter-jitsurei/` | Consumer, offset-management, multi-partition, error, and tracing examples |
| `shibuya-kafka-adapter-bench/` | Conversion micro-benchmarks and the `lifecycle-live` broker fixture |
| `docs/capabilities/` | Capability contracts and supporting evidence |
| `docs/plans/` | Implementation and acceptance records |

For example, run `cabal run basic-consumer`, `cabal run multi-topic`, or
`cabal run otel-demo`. These examples configure `localhost:9092` in their source;
adjust their broker settings to use the private cluster on `29092`.
`KAFKA_TEST_BROKER` configures tests, not the examples.

## License

MIT. See [LICENSE](shibuya-kafka-adapter/LICENSE).
