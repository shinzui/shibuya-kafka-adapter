---
title: "Kafka message source for the Shibuya app runtime"
type: Capability
description: "Poll a set of Kafka topics and feed the records to a Shibuya app as an Adapter, with batching and multi-topic/multi-partition dispatch."
generated:
  by: claude-cli/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-1
provider: mori://shinzui/shibuya-kafka-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-kafka-adapter
interface:
  - Shibuya.Adapter.Kafka.kafkaAdapter
  - Shibuya.Adapter.Kafka.kafkaAdapterWith
  - Shibuya.Adapter.Kafka.KafkaAdapterConfig
  - Shibuya.Adapter.Kafka.defaultConfig
evidence:
  - kind: test
    resource: shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs
    proves: "Against a live broker, `Basic produce-consume`, `Batch polling`, and `Multi-partition distribution` show produced messages arriving as Shibuya messages under `runApp`."
  - kind: example
    resource: shibuya-kafka-adapter-jitsurei/app/BasicConsumer.hs
    proves: "The shortest end-to-end wiring: build a consumer, construct the adapter with `defaultConfig`, and run it under `runApp`."
  - kind: example
    resource: shibuya-kafka-adapter-jitsurei/app/MultiTopic.hs
    proves: "One adapter consuming several topics through a single `runApp` invocation."
---

# Kafka message source for the Shibuya app runtime

`kafkaAdapter` turns a live `KafkaConsumer` effect scope into a
`Shibuya.Adapter.Adapter` that a Shibuya app polls for work. You configure the
topics and poll shape, hand the adapter to `runApp`, and your handler receives
one Shibuya `Message` per Kafka record.

## Usage

```haskell
import Shibuya.App (defaultAppConfig, runApp, mkProcessor, ProcessorId (..))
import Shibuya.Adapter.Kafka (kafkaAdapter, defaultConfig)
import Kafka.Effectful.Consumer (runKafkaConsumer)
import Kafka.Types (TopicName (..))

main = runEff . runError @KafkaError . runKafkaConsumer props sub $ do
  adapter <- kafkaAdapter (defaultConfig [TopicName "orders"])
  runApp defaultAppConfig
    [ (ProcessorId "orders", mkProcessor adapter myHandler) ]
```

`defaultConfig` polls with a 1000 ms timeout and a batch size of 100; override
`pollTimeout` and `batchSize` on `KafkaAdapterConfig` for other shapes. Consumer
properties (brokers, group id) and the subscription — including offset-reset
policy — belong to `runKafkaConsumer`, not to the adapter. The adapter's
`topics` field is metadata used for the adapter name and a construction-time
stderr warning if it disagrees with the live subscription.

Use `kafkaAdapterWith` when you must share one `KafkaAdapterState` between the
adapter and a rebalance callback installed before consumer creation (see the
at-least-once offset & acknowledgement semantics record, CAP-2).

## Limits

- **Serial processing only.** The adapter must be driven with serial message
  processing. librdkafka tracks only the highest offset per partition with no
  gap tracking, so `Async` or `Ahead` processing can commit past an earlier
  message that failed, halted, or asked for retry. The `Adapter` value cannot
  see the processor concurrency policy, so this is a caller contract, not a
  runtime guard.
- **Integration evidence needs a broker.** The `IntegrationTest` suite connects
  to a Kafka broker at `127.0.0.1:9092`; without one those cases do not run.
  The broker-free tests (`AdapterTest`, `AckHandleTest`, `ConvertTest`) cover
  conversion, ack semantics, and error propagation in isolation, but the
  end-to-end produce/consume claims are only proven when a broker is present.
- **Pre-1.0.** Every release so far carries breaking changes tracking
  `shibuya-core`; treat the API as unstable and pin exact versions.
</content>
