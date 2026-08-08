---
title: "Fatal-vs-non-fatal Kafka error propagation"
type: Capability
description: "Filter non-fatal Kafka errors out of the poll stream and surface any fatal error to the caller through the Error KafkaError effect."
generated:
  by: claude-cli/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-4
provider: mori://shinzui/shibuya-kafka-adapter
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shibuya-kafka-adapter
interface:
  - Shibuya.Adapter.Kafka.kafkaAdapter
  - Shibuya.Adapter.Kafka.KafkaError
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/AdapterTest.hs
    proves: "Broker-free: a fatal `KafkaError` reaching the ingested stream is thrown through the `Error KafkaError` effect (observed as `Left err`), and the stream aborts on the first fatal `Left` without forcing later elements."
  - kind: example
    resource: shibuya-kafka-adapter-jitsurei/app/FatalErrorDemo.hs
    proves: "A runnable demonstration of a fatal error terminating the app and surfacing to the caller."
---

# Fatal-vs-non-fatal Kafka error propagation

This is a property of the [Kafka message source](kafka-message-source.md): the
poll stream distinguishes recoverable noise from real failures. Non-fatal
errors — poll timeouts, partition EOFs, and the rest of `hw-kafka-streamly`'s
non-fatal set — are filtered out with `skipNonFatal`. Any error that survives
that filter is fatal by construction (SSL handshake failure, authentication
failure, invalid broker configuration, and the like) and terminates the source
stream by throwing through the `Error KafkaError` effect.

The caller observes the failure as `Left err` from the `runError @KafkaError`
scope wrapping `runApp`:

```haskell
result <- runEff . runError @KafkaError . runKafkaConsumer props sub $
  runApp defaultAppConfig processors
case result of
  Left (_cs, err) -> handleFatal err
  Right ()        -> pure ()
```

## History

Non-fatal filtering via `skipNonFatal`/`isFatal` has been present since
`0.1.0.0`. The ack path's error handling was materially refined in `0.8.0.0`:
transient ack-path Kafka errors now retry briefly and persistent ones are
classified as adapter (source-terminating) errors rather than handler errors, so
a stuck store/seek/pause surfaces through this same fatal path instead of being
misattributed to the handler.

## Limits

- **Classification depends on `hw-kafka-streamly`.** What counts as "fatal" is
  `Kafka.Streamly.Stream.isFatal` from an upstream dependency; changes to its
  classification change what this capability filters versus surfaces.
- **The strongest test is broker-free and synthetic.** `AdapterTest` injects a
  synthetic fatal `Left` to prove propagation; the ack-path retry-then-fatal
  behavior is proven in `AckHandleTest` with a mocked consumer. Neither
  exercises a real broker producing a genuine fatal error.
</content>
