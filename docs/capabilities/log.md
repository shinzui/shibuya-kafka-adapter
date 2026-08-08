# Capability catalog log

## 2026-08-08

Adopt the shared capability profile. Authored the initial capability catalog under the shared
`coordination.capabilities` profile (okf-profiles v0.9.0), derived from source,
tests, README/CHANGELOG, and release tags at repo version `0.8.0.1`.

Four capabilities were recorded, grouped by mechanism rather than by module or
export:

- **CAP-1** Kafka message source (poll loop, batching, `Adapter` for `runApp`).
- **CAP-2** at-least-once offset & acknowledgement semantics (requires CAP-1).
- **CAP-3** ConsumerRecord-to-Envelope conversion with trace context and OTel
  attributes.
- **CAP-4** fatal-vs-non-fatal error propagation (requires CAP-1).

Excluded the end-to-end OTel span (composition with `shibuya-core`, not
provision), the removed `Shibuya.Adapter.Kafka.Tracing` module and its stale
`docs/otel-tracing.md`, the internal bench and jitsurei packages (evidence
only), and `Shibuya.Adapter.Kafka.Internal` (not public API).
</content>
