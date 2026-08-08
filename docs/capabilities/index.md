---
okf_version: "0.2"
---

# What shibuya-kafka-adapter provides

`shibuya-kafka-adapter` bridges Apache Kafka to the
[Shibuya](mori://shinzui/shibuya) queue-processing framework. A consumer depends
on the single library package `shibuya-kafka-adapter` and gets a poll-driven
Kafka source that plugs into a Shibuya app, an at-least-once offset/ack model, a
pure Kafka-to-Envelope conversion (including W3C trace-context and typed OTel
attributes), and fatal-error propagation through the `Error KafkaError` effect.

The catalog is governed by the shared `coordination.capabilities` profile
(`profile.dhall`).

## Capabilities

| ID | Capability | since | stability |
|----|------------|-------|-----------|
| [CAP-1](kafka-message-source.md) | Kafka message source for the Shibuya app runtime | 0.1.0.0 | experimental |
| [CAP-2](offset-acknowledgement-semantics.md) | At-least-once offset & acknowledgement semantics | 0.1.0.0 | experimental |
| [CAP-3](envelope-conversion.md) | ConsumerRecord to Envelope conversion with trace context and OTel attributes | 0.1.0.0 | experimental |
| [CAP-4](fatal-error-propagation.md) | Fatal-vs-non-fatal Kafka error propagation | 0.1.0.0 | experimental |

Every capability is `experimental`: the project is pre-1.0 and each release so
far carries breaking changes tracking `shibuya-core`. Availability (`status:
shipped`) and compatibility (`stability: experimental`) are separate questions;
the uniform stability reflects one uniform compatibility promise, not missing
detail.

## Deliberately excluded

- **The end-to-end OpenTelemetry span.** This repository populates
  `Envelope.attributes` and `traceContext`; the per-message Consumer-kind span is
  opened by `shibuya-core`'s runner. The span is real only when this adapter is
  composed with `shibuya-core`, so it is a use-case feature of the consuming
  app, not a capability any single repository can assert (composition, not
  provision).
- **The removed `Shibuya.Adapter.Kafka.Tracing` module.** Deleted in `0.5.0.0`.
  `docs/otel-tracing.md` still documents it and is stale; it is not evidence of
  a current capability and should be removed or rewritten.
- **`shibuya-kafka-adapter-bench`.** An internal micro-benchmark package with no
  API a consumer adopts; it appears only as *evidence* for CAP-3.
- **`shibuya-kafka-adapter-jitsurei`.** Internal runnable examples; they appear
  only as *evidence*, not as adoptable units.
- **`Shibuya.Adapter.Kafka.Internal`.** Explicitly not public API and may change
  without notice; its behavior is described through the capabilities it backs.
</content>
