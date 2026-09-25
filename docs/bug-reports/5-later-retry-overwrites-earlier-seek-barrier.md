---
type: Bug Report
title: Later retry overwrites an earlier seek barrier and commits past an unhandled record
description: Two retries finalized from one broker poll cause the released adapter to redeliver only the later offset and commit past the earlier one without a successful handler decision.
generated:
  by: process:codex
  at: "2026-09-25T02:17:56Z"
bugId: BUG-5
status: reported
severity: data-loss
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya-kafka-adapter
affectedVersion: "0.9.0.1"
environment: Redpanda 26.2.1 in a private Apple Container; macOS aarch64; GHC 9.12.4; released cohort with Hackage shibuya-kafka-adapter 0.9.0.1, shibuya-core 0.9.0.3, kafka-effectful 0.3.1.0, hw-kafka-streamly 0.2.0.0, and hw-kafka-client 5.3.0.
observed: >-
  With one partition holding offsets 0 through 9, a single real-broker poll
  returns all ten records. The adapter's mkAckHandle finalizes AckRetry for
  offsets 3 and 4 before the next poll, then the broker redelivers offsets
  4 through 9. Offset 3 never receives AckOk, but after the replay the consumer
  group commits offset 10. The released adapter uses Map.insert for the
  partition seek barrier, so the retry at 4 replaces the earlier barrier at 3.
expected: The earliest unresolved offset must remain the recovery boundary; the group must not commit past offset 3 without its successful or dead-letter decision. This is the at-least-once contract in CAP-2.
reproduction:
  - Build the released Kenshou cohort containing Hackage shibuya-kafka-adapter 0.9.0.1 (SHA-256 1918bae0c591ab47ba45d044a50170e7a340bddb1b562752cd16f556e86314e6).
  - Run `cabal run kenshou -- run kafka/adapter/concurrency/barrier-overwrite-loses-record --out runs` from mori://shinzui/keiro-runtime-kenshou. The scenario publishes ten acknowledged records to a private one-partition topic, polls all ten through the real consumer, and finalizes decisions through the released adapter's mkAckHandle with manual offset storage.
  - Inspect run `01a0d65a-4f69-733e-a3f8-cef8dcc8c63f`: initial poll offsets 0–9; replay offsets 4–9; successful handler decisions for 0–2, 4–9; committed offset 10; missing-success offset 3. Its `barrier-overwrite-no-loss` failure is the only failed label and is scoped as the known defect.
  - Use the scenario's default ten-record schedule and `telemetry.metrics=off`, `telemetry.tracing=off` arms. The run records a seed, but the schedule does not draw from it and has no optional knobs. The sealed result directory contains the run specification and verdict.
  - A second run, `01a0d65e-398f-75aa-98c2-803cb1a1227b`, reproduced the same initial poll, replay, committed offset, and missing-success offset after the scenario gained a bounded initial poll. Its recorded seed is `4081218207424054`.
  - The brokerless `kafka/adapter/correctness/ack-state-machine-model` scenario in mori://shinzui/keiro-runtime-kenshou also runs the real released source, dropStaleRecords, mkIngested, and mkAckHandle functions against a simulated KafkaConsumer. A fixed depth-ten dual-retry schedule skips offset 3, and the default 2,000-case run finds replayable counterexamples for commit safety, order, and finite completion.
workaround: Use a corrected adapter release whose retry barrier retains the earliest unresolved offset; the locally resolved 0.9.0.1 release does not provide a safe configuration workaround for two buffered retries.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-25T02:17:56Z"
    document_timestamp: "2026-09-25T02:17:56Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Compared the sealed live broker run, default generated model run, released adapter source, and CAP-2 acknowledgement contract. Newer package versions were not tested.
---

# Later retry overwrites an earlier seek barrier

The live reproduction deliberately finalizes both retry decisions before the
next broker poll. This isolates the adapter's per-partition seek-barrier state
from the concurrent poll timing of a full Shibuya runner. It uses the actual
`mkAckHandle` from the released adapter, a real `KafkaConsumer`, and a private
broker. The group commit is read back through the broker admin API after
consumer close.

The sealed live result is under `mori://shinzui/keiro-runtime-kenshou` at
`runs/01a0d65a-4f69-733e-a3f8-cef8dcc8c63f/`; the fixed and generated
model traces are in
`runs/01a0d657-0edb-758d-9047-6f824ee5e804/`. An artifact-level Mori URI
for run directories is pending. The source-level remedy proposed at
`mori://shinzui/keiro/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter`
is related, but no newer release has been validated by this report.
