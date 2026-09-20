---
title: "Fatal-vs-non-fatal Kafka error propagation"
type: Capability
description: "Filter non-fatal poll errors and surface fatal poll or acknowledgement failures directly to the caller."
generated:
  by: codex-cli/gpt-6-astra
  at: "2026-09-20T22:30:00Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-20T22:30:00Z"
    document_timestamp: "2026-09-20T22:30:00Z"
    scope: content-and-metadata
    outcome: approved
    context: "Repository source, acknowledgement failure tests, core lifecycle integration evidence, and the EP-40 lifecycle audit."
    provider: openai
    model: gpt-6-astra
    effort: high
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
  - Shibuya.Adapter.Kafka.KafkaAcknowledgementException
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/AdapterTest.hs
    proves: "Broker-free: a fatal `KafkaError` reaching the ingested stream is thrown through the `Error KafkaError` effect (observed as `Left err`), and the stream aborts on the first fatal `Left` without forcing later elements."
  - kind: example
    resource: shibuya-kafka-adapter-jitsurei/app/FatalErrorDemo.hs
    proves: "A runnable demonstration of a fatal error terminating the app and surfacing to the caller."
  - kind: test
    resource: shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/AckHandleTest.hs
    proves: "Persistent store, seek, and pause failures throw `KafkaAcknowledgementException`; the core integration case retains the exhausted finalizer as `LifecycleFailed` after source completion."
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

Acknowledgement failures have a separate terminal route. A transient
store/seek/pause error is retried within a small bounded budget. If that budget
is exhausted, the adapter records the Kafka error for source diagnostics and
throws `KafkaAcknowledgementException` synchronously from the `AckHandle`.
Shibuya's finalizer boundary retries it according to core policy and retains a
`LifecycleFailed` outcome if it remains exhausted. This direct route does not
depend on another source poll after ingestion has ended.

## History

Non-fatal filtering via `skipNonFatal`/`isFatal` has been present since
`0.1.0.0`. The ack path's error handling was materially refined in `0.8.0.0`,
when transient errors gained bounded retries and persistent errors gained a
fatal diagnostic slot. The current unreleased change adds the direct typed
exception route so a stuck store/seek/pause cannot disappear when the source has
already ended.

## Limits

- **Classification depends on `hw-kafka-streamly`.** What counts as "fatal" is
  `Kafka.Streamly.Stream.isFatal` from an upstream dependency; changes to its
  classification change what this capability filters versus surfaces.
- **The strongest poll-error test is broker-free and synthetic.** `AdapterTest` injects a
  synthetic fatal `Left` to prove propagation; the ack-path retry-then-fatal
  behavior is proven in `AckHandleTest` with a mocked consumer. Neither
  exercises a real broker producing a genuine fatal error.
</content>
