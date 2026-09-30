---
type: Bug Report
title: Buffered retry leaves acknowledged successors uncommitted
description: A serial consumer stays live with lag after all records return AckOk following a buffered AckRetry.
generated:
  by: claude-code/claude-fable-5-1
  at: "2026-09-30T20:37:02Z"
bugId: BUG-1
status: confirmed
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/masterplans/1-build-an-extensive-verification-suite-for-the-keiro-runtime
affects: mori://shinzui/shibuya-kafka-adapter
affectedVersion: "0.9.0.1"
environment: Redpanda 26.2.1 in a private Apple Container; macOS aarch64; GHC 9.12.4; released cohort; shibuya-core 0.9.0.3, kafka-effectful 0.3.1.0, hw-kafka-client 5.3.0.
observed: After a first AckRetry at offset 20, all 50 records eventually return AckOk in one serial consumer, but the group commits only offset 21 and remains at lag 29 after a full auto-commit interval and graceful shutdown.
expected: AckRetry seeks back without storing the failed offset; after its redelivery succeeds and every later record returns AckOk, the same live consumer should advance its committed position to the log end.
reproduction:
  - Build the released Kenshou cohort containing the Hackage shibuya-kafka-adapter 0.9.0.1 tarball (SHA-256 1918bae0c591ab47ba45d044a50170e7a340bddb1b562752cd16f556e86314e6).
  - Run `cabal run kenshou -- run kafka/adapter/correctness/retry-redelivers-and-never-commits-past --out runs` from mori://shinzui/keiro-runtime-kenshou with the default batch size 100, failure mode retry, retry delay 0, exit-before-success false, both telemetry dimensions off, and a private Redpanda 26.2.1 broker.
  - Inspect run `01a0d5d8-a8cd-77f0-92a2-e836dad8b3b7` with seed 6789536380475474. Its result lists handler deliveries 0 through 49 then 20, AckOk outcomes for 0 through 19, 21 through 49, then 20, and a final group snapshot committed 21 versus log end 50.
  - Repeat with `--set kafka.batch-size=1`; run `01a0d5d9-0b9c-711d-a1bf-4e8af275067d` passes with zero lag.
workaround: Use a poll batch size of 1 for this retry pattern, or restart the group to replay the uncommitted successors; the latter repeats already executed handler effects.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-24T23:58:16Z"
    document_timestamp: "2026-09-24T23:58:16Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Compared the sealed live run, a batch-size-one control, the released source and README, and the existing KFK-2 remediation plan; no patch was tested.
---

# Buffered retry leaves acknowledged successors uncommitted

The released adapter's README says `AckRetry` seeks back without storing the
failed offset. Its `AckOk` path stores successful offsets. The shipped capability
`mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-2` describes
at-least-once offset acknowledgement semantics. The observed group remains
at committed offset 21 after every message has succeeded and the consumer has
closed normally. The failed run's result and broker log are under
`mori://shinzui/keiro-runtime-kenshou` at
`runs/01a0d5d8-a8cd-77f0-92a2-e836dad8b3b7/`; an artifact-level Mori URI
for run directories is pending.

The failure is consistent with the buffered-successor ordering mechanism
described in
`mori://shinzui/keiro/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter`.
That plan also addresses a distinct loss hazard when a buffered successor
itself retries. This report records the broker-observed failure in released
0.9.0.1; it does not claim the plan's proposed fix has been verified.

## Confirmation

The owning repository reproduced this on 2026-09-30, on Hackage 0.9.0.1 and on
0.9.1.0 (the current source, which has no code change since the `v0.9.1.0` tag),
against the shared Redpanda broker: fifty records on one partition, one `AckRetry`
at offset 20, driven through `kafkaAdapter` and a serial `runApp` processor. All
three runs on each version handled every record and left the group committed at
offset 21 of 50, both while live and after graceful shutdown. A broker-free
reproduction over an in-memory log gives the same result deterministically:
twelve records with one retry at offset 4 store only offsets 0 through 4.

The cause on 0.9.1.0 is that the source filter discards the redelivered
successors while the retry barrier is still pending, and nothing fetches them
again once it clears. The fix is planned in
`docs/plans/16-hold-replayed-successors-so-a-buffered-retry-cannot-stall-partition-commits.md`.
