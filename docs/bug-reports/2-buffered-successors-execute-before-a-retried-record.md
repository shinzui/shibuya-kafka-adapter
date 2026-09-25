---
type: Bug Report
title: Buffered successors execute before a retried record
description: A serial adapter processes buffered successor handlers before it redelivers an earlier failed offset.
generated:
  by: process:codex
  at: "2026-09-25T00:17:32Z"
bugId: BUG-2
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya-kafka-adapter
affectedVersion: "0.9.0.1"
environment: Redpanda 26.2.1 in a private Apple Container; macOS aarch64; GHC 9.12.4; released cohort with Hackage shibuya-kafka-adapter 0.9.0.1, shibuya-core 0.9.0.3, kafka-effectful 0.3.1.0, and hw-kafka-client 5.3.0.
observed: Offset 3 first returns AckRetry; handlers at offsets 4 through 9 return AckOk before offset 3 is redelivered and succeeds, despite serial processor execution.
expected: A retry of offset 3 should keep same-partition successor handlers from executing until offset 3 has been redelivered and finalized successfully.
reproduction:
  - Build the released Kenshou cohort containing the Hackage shibuya-kafka-adapter 0.9.0.1 tarball (SHA-256 1918bae0c591ab47ba45d044a50170e7a340bddb1b562752cd16f556e86314e6).
  - Run `cabal run kenshou -- run kafka/adapter/concurrency/buffered-successors-run-before-retry --out runs` from mori://shinzui/keiro-runtime-kenshou with a private Redpanda 26.2.1 broker, one partition, the adapter's default batch size 100 and Shibuya inbox size 100, both telemetry dimensions off, and the default run seed.
  - Inspect run `01a0d5ec-3cf3-7625-a9f8-1ec2c2d9c916` with seed 1402572546415582. It records deliveries `[0,1,2,3,4,5,6,7,8,9,3]` and successful handler results `[0,1,2,4,5,6,7,8,9,3]`.
workaround: Keep handlers idempotent and use a batch size of one if strict retry order is required; the latter reduces poll throughput.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-25T00:17:32Z"
    document_timestamp: "2026-09-25T00:17:32Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Compared the sealed broker run with the released adapter's retry path and the existing KFK-2 remediation plan; no patch was tested.
---

# Buffered successors execute before a retried record

The live run is under `mori://shinzui/keiro-runtime-kenshou` at
`runs/01a0d5ec-3cf3-7625-a9f8-1ec2c2d9c916/`; an artifact-level Mori URI
for run directories is pending. Its run result records the exact resolved
cohort and seed. The adapter's released README calls for serial processing
because concurrent finalization can cross failed offsets; its retry path
seeks back without storing the failed offset. The successful handler order
above shows that serial execution alone does not stop already buffered
successors from running before the retry is resolved.

The buffer placement and proposed fix are analyzed in
`mori://shinzui/keiro/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter`.
BUG-1 records the separate observed commit-lag behavior after buffered
successors have executed. This report isolates handler effect order.
