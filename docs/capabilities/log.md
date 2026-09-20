# Capability catalog log

## 2026-09-20
* **CAP-4**: Propagate exhausted store, seek, and pause operations directly as KafkaAcknowledgementException so candidate Shibuya core retains LifecycleFailed without requiring another source poll.
* **CAP-2**: Preserve the earliest unresolved delivery with delivery-token barriers; fence callbacks by assignment generation when the rebalance helper is installed; add deterministic model, cancellation, timeout, repeated-shutdown, restart, and actual reassignment evidence.

## 2026-08-08
* **CAP-1**: Kafka message source (poll loop, batching, `Adapter` for `runApp`).
* **CAP-2**: at-least-once offset & acknowledgement semantics (requires CAP-1).
* **CAP-3**: ConsumerRecord-to-Envelope conversion with trace context and OTel
attributes.
* **CAP-4**: fatal-vs-non-fatal error propagation (requires CAP-1).
