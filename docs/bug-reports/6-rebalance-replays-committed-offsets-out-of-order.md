---
type: Bug Report
title: Group rebalance replays committed offsets out of order within one assignment
description: A serial adapter consumer handles a higher partition offset and then a lower offset within the same assignment after group membership changes, even though the lower offset was already committed.
generated:
  by: process:codex
  at: "2026-09-25T03:57:29Z"
bugId: BUG-6
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou/plans/11-cover-the-kafka-transport-edge-with-a-disposable-broker
affects: mori://shinzui/shibuya-kafka-adapter
affectedVersion: "0.9.0.1"
environment: Redpanda 26.2.1 with write caching disabled on a private Apple Container; macOS aarch64; GHC 9.12.4; released cohort with Hackage shibuya-kafka-adapter 0.9.0.1, shibuya-core 0.9.0.3, kafka-effectful 0.3.1.0, hw-kafka-streamly 0.2.0.0, and hw-kafka-client 5.3.0.
observed: >-
  In two private-broker runs of a serial Shibuya adapter consumer group,
  member 3 handled a higher offset followed by a lower offset on the same
  partition and within the same assignment. In the later run it handled
  partition 4 offset 200 at 03:55:11.271Z, then offset 165 at 03:55:11.282Z,
  though the group had committed offset 173 at 03:55:09.687Z. The handler
  returned AckOk for both records and no retry policy was installed. All
  4,000 acknowledged IDs eventually had handler facts and group lag reached
  zero. The other run handled partition 0 offset 235 then 168 while the
  sampled committed boundary was 197. Both runs also reproduced the
  separate early consumer-exit finding BUG-4.
expected: For one assigned partition and a serial handler without retries, the adapter should deliver records in increasing offset order. Reassignment replay may repeat uncommitted records, but should not deliver an offset below the group's already committed position in the same active assignment.
reproduction:
  - Build the released Kenshou cohort containing Hackage shibuya-kafka-adapter 0.9.0.1 and run `cabal run kenshou -- run kafka/adapter/concurrency/group-rebalance-with-inflight --out runs --set kafka.consumers=3 --set kafka.membership-interval-seconds=3 --set kafka.messages=4000 --set kafka.partitions=12 --set kafka.service-ms=10` from mori://shinzui/keiro-runtime-kenshou.
  - Inspect run `01a0d6b3-b843-7149-a2b2-981e6a1734ef` under mori://shinzui/keiro-runtime-kenshou. In `logs/kafka-crash-consumer-3.0.control.jsonl`, member 3's third assignment includes partition 4 at 03:55:10.613Z; its `ok` facts then record offsets 200 and 165 in that order. `run-result.json` records the partition 4 committed boundary of 173 at 03:55:09.687Z and the `rebalance-assignment-order` failure.
  - Inspect independent run `01a0d6ae-5461-7105-9306-89c743515865`: member 3 handles partition 0 offsets 235 then 168 within one assignment, below the sampled committed boundary of 197. An artifact-level Mori URI for these run directories is pending.
workaround: No reliable workaround is established. Restarting the consumer may drain lag but does not make already executed out-of-order handler effects safe.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-09-25T03:57:29Z"
    document_timestamp: "2026-09-25T03:57:29Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: GPT-6
    effort: medium
    context: Compared two sealed private-broker runs, per-worker handler and assignment facts, group committed-offset snapshots, the serial worker policy, and existing BUG-4. The exact source-level path through the adapter and Shibuya runner remains unknown.
---

# Group rebalance replays committed offsets out of order

The worker installs `kafkaRebalanceHandler`, disables automatic offset
storage, sets the automatic commit interval to one second, and uses the
default serial `mkProcessor` handler. Every record in this scenario returns
`AckOk`; the worker has no retry or seek policy. The `ok` fact is emitted
immediately before returning that decision.

Both reproductions show a lower offset after a higher offset without a new
assignment between the facts. The later run's lower offset is also below a
committed boundary sampled before the membership change. This is distinct
from a duplicate inside the declared rebalance window and from BUG-4's
premature stream termination. The observation identifies the integrated
adapter/runner behavior; it does not yet isolate which library reorders the
buffered records.
