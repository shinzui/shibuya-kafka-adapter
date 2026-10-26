---
id: 17
slug: skip-superseded-buffered-deliveries-so-successors-cannot-run-before-a-retried-record
title: "Skip superseded buffered deliveries so successors cannot run before a retried record"
kind: exec-plan
created_at: 2026-09-30T14:44:59Z
intention: "intention_01m3sbterne78sx93pm5d6qf66"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T14:44:59Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-26T19:08:58Z
      mode: "update"
      note: "Correct published-version collision and batch-worker bypass; preserve detailed metrics and strengthen synchronized ordering and finalization acceptance."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-26T19:10:34Z
      verdict: "approved"
      note: "Approved revised plan subject to plan 16 prerequisite; corrected version collision, actual batch entry, status sampling and completion oracles. Existing 40 adapter tests and 289 core examples pass; feature, performance and live validation remain outstanding."
---

# Skip superseded buffered deliveries so successors cannot run before a retried record


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


An application that consumes Kafka through `shibuya-kafka-adapter` and a serial,
single-message Shibuya processor handles one record at a time, in partition order.
When a handler returns `AckRetry` for a record, the adapter arranges for that record to be delivered again.
Today the records that follow it on the same partition, and that were already waiting
to be handled, still run their handlers before the retried record comes back. An
application that relies on partition order sees the effects of offsets 21 through 49
before the effect of offset 20. This is recorded as BUG-2 in
`docs/bug-reports/2-buffered-successors-execute-before-a-retried-record.md`.

After this plan, under serial single-message processing, a record that asks for a
retry blocks the records behind it on the same partition. Their handlers do not run
until the retried record is resolved. In the finite test with one retry and no
rebalance, each successor then runs once. This is not an exactly-once guarantee
across failures or restarts. A batch handler receives its members together, so a
retry cannot undo successors already handled in that same batch. If retention or
compaction removes the retried offset, plan 16 explicitly abandons that missing
record and resumes at the next available offset.

The adapter cannot do this alone, because the waiting records have already been
handed to the Shibuya runner. So the plan has two parts. It adds a small question to
`shibuya-core` that the runner asks an adapter just before it calls a handler: "is
this delivery still current?" Then it makes the Kafka adapter answer that question
from the retry state it already keeps.

You can see it working with a broker-free test that drives the real adapter and the
real runner over an in-memory log of twelve records and retries offset 4 once. The
handler must see offsets `0,1,2,3,4,4,5,6,7,8,9,10,11`. With plan 16 alone and
the synchronized buffered schedule below it sees `0..11, 4, 5..11`. The currently
checked-out adapter predates plan 16. A live Redpanda test must show the fixed order.

This plan changes two repositories: this one, and `shibuya-core` in
`mori://shinzui/shibuya`, which on this machine is the sibling checkout
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. It builds on
`docs/plans/16-hold-replayed-successors-so-a-buffered-retry-cannot-stall-partition-commits.md`,
which must be implemented first.


## Progress


- [ ] Milestone 0: plan 16's source gate and acceptance are complete; establish the
  current core/adapter test and benchmark baselines and verify release versions.
- [ ] Milestone 1: both actual runner paths skip superseded deliveries, preserve
  metrics and lifecycle behavior, and pass deterministic core regression tests.
- [ ] Milestone 2: record the core benchmark comparison and prepare the documented,
  tested 0.12.0.0 core/metrics candidate without publishing it.
- [ ] Milestone 3: the adapter builds against the local candidate and passes status,
  synchronized retry-order, batch-liveness, and handler-exception tests.
- [ ] Milestone 4: ten full-suite runs and all-component builds pass; documentation,
  capability and bug records, and ADRs reflect the verified behavior.
- [ ] Milestone 5: after the owner publishes the feature-bearing core release,
  remove only this plan's local override and verify the Hackage build and tests.

Review handoff (2026-10-26): this is a plan revision, not implementation. Plan 16 is
still unimplemented: `dropStaleRecords` exists, while `gateRecords`,
`Kafka/ScriptedLog.hs`, and `SourceGateTest.hs` do not. Both repositories started
clean. The adapter is 0.10.0.0 and already requires core 0.11.0.0. Core and metrics
0.11.0.0 are published, but neither the checked-out nor tagged core has
`deliveryStatus`. The next candidate in this plan is therefore 0.12.0.0; recheck
Hackage and upstream tags before implementation if releases have advanced.
Review validation passed: 40 broker-free adapter tests and 289 core examples, zero
failures. No feature implementation, benchmarks, or live-broker tests were run in
this review; those remain milestone acceptance. Capability and strict bug-report
OKF validation passed, as did plan structure, fence, link, and whitespace checks.

## Surprises & Discoveries


- 2026-09-30 (planning): BUG-2 was filed against Hackage 0.9.0.1 and still reproduces
  on 0.9.1.0 and the current source. Fifty records on one partition with one
  `AckRetry` at offset 20, through `kafkaAdapter` and a serial `runApp` processor
  against the shared Redpanda broker, ran handlers in the order `0..49, 20` in three
  runs out of three.

- 2026-09-30 (planning): the whole design was prototyped before this plan was
  written, in scratch copies of both repositories, on top of the plan 16 prototype.
  With the prototype the core suite reported `236 examples, 0 failures`. The
  fifty-record schedule ran handlers in the order `0..19, 20, 20, 21..49` and committed
  offset 50, three runs out of three. The broker-free scripted test printed the
  following.

  ```text
  deliveries=[0,1,2,3,4,4,5,6,7,8,9,10,11] stored=[0,1,2,3,4,5,6,7,8,9,10,11] seeks=[4]
  ```

- 2026-09-30 (planning): one existing adapter test encodes the bug. With the prototype
  the adapter suite had exactly one failure.

  ```text
  Handler exception redelivers instead of skipping: FAIL
    test/Shibuya/Adapter/Kafka/IntegrationTest.hs:502:
    expected n-3 after handler exception retry, saw ["n-1","n-2","n-2"]
  ```

  The test ends its source after four emitted records with `Stream.take 4`. It used to
  see `n-3` only because the buffered first delivery of `n-3` ran before the second
  delivery of `n-2`. With the fix that delivery is skipped, and the stream ends before
  `n-3` is delivered again. The test also depends on how many records the ingester had
  emitted when the retry was decided, which is a race. Milestone 3 rewrites it.

- 2026-09-30 (planning): two other adapters build `Ingested` with record syntax and
  will not compile against the new core until they add the new field:
  `mori://shinzui/shibuya-pgmq-adapter` at
  `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` and
  `mori://shinzui/kiroku` at
  `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`. Both kept building
  at that time because they pinned `shibuya-core ^>=0.10.0.0`. Artifact-level Mori
  URIs for source files are pending.


- 2026-10-26 (review): Hackage's preferred-version endpoints for core and metrics
  both report 0.11.0.0 as their newest release; upstream has `v0.11.0.0`, whose
  peeled commit is `a4b2b8e3e876f550b7fa08fb8d5a94975a0cc9da`. Its `Ingested`
  definition has no status field. Reusing that version would allow an incompatible
  published dependency to satisfy the adapter bound.

- 2026-10-26 (review): the batch loop calls `processOneBatchWithDetail` directly.
  Wrapping only exported `processOneBatch` would leave production and
  `runBatchesWithMetrics` processing unchecked. Single-message processing also now
  has basic/detailed branches, in-flight slot ownership, and cursor recording that
  must remain behind the new check.

- 2026-10-26 (review): the old batch pseudocode queried some statuses twice, and an
  inbox capacity of ten did not prove that three deliveries had been ingested.
  The revised design samples each member once and tests with explicit source/handler
  handshakes. Finalization, rather than a handler's intention to return `AckOk`, is
  the completion boundary.

## Decision Log


- Decision: fix BUG-2 with a pre-handler check in `shibuya-core`, not with lock-step
  emission inside the adapter.
  Rationale: chosen by the repository owner on 2026-09-30 from three options. The
  adapter cannot recall a record it has already handed to the runner, so an
  adapter-only fix must never hand over a successor before its predecessor is
  finalized. That starves a batch processor, which waits for more records or for its
  timeout before running, down to one record per `batchTimeout`, and it removes the
  ingester's head start over the handler. A check made by the runner at handler time
  keeps batching and the inbox as they are.
  Date: 2026-09-30

- Decision: carry the check on `Ingested` as a new field `deliveryStatus`, defaulted
  by `mkIngested`.
  Rationale: adapters that use the smart constructor keep compiling and keep their
  behaviour. Putting it on `AckHandle` would break every adapter's constructor call,
  and putting it on `Adapter` would break every adapter and every test that builds one.
  Date: 2026-09-30

- Decision: the runner neither runs the handler nor calls the finalizer for a
  superseded delivery, and does not count it as processed or failed.
  Rationale: the adapter has already said it will deliver the message again or has
  fenced the delivery, so there is no decision to carry out. `shibuya-core` already
  has deliveries that are received but counted in neither total (a halt), so no
  metric needs to change shape.
  Date: 2026-09-30

- Decision: do not wrap the status call in an exception handler.
  Rationale: the runner's per-message path was measured to pay about 126 bytes per
  message for each exception frame, and the repository treats that as a regression
  budget. The Kafka implementation is a single `readIORef`. The contract states that
  the action must not throw; if one does, the processor fails like any other
  infrastructure failure.
  Date: 2026-09-30

- Decision: record a superseded delivery on its span with the existing acknowledgement
  event and the value `superseded`, and add no new metric.
  Rationale: a delivery that vanishes without a trace is hard to debug, and reusing
  the existing event key adds no new telemetry name. A new counter would change the
  published metrics JSON and Prometheus output, which is a larger contract change than
  this fix needs.
  Date: 2026-09-30

- Decision: prepare `shibuya-core` and `shibuya-metrics` as a 0.12.0.0 candidate in
  this plan, and make the adapter require `shibuya-core ^>=0.12.0.0`.
  Rationale: a new field on an exported record is a breaking change, so the next
  version is a major one. Updated on 2026-10-26: 0.11.0.0 is already published
  without the field, so the new candidate and lower bound are 0.12.0.0.
  This follows the adapter's earlier "prepare candidate" commit before a coordinated
  release.
  Date: 2026-09-30; revised 2026-10-26

- Decision: commit the adapter change before the core is published, developing through
  the git-ignored `cabal.project.local`.
  Rationale: this is how the 0.10.0.0 cycle was done. Until the core is published a
  fresh clone of this repository needs the same override, which Milestone 5 removes.
  The adapter must not be released before the core.
  Date: 2026-09-30

- Decision: leave the other adapters to their own repositories.
  Rationale: their existing bounds keep them on their current core series. Recheck
  their bounds and constructor uses when migrating; adding the default status field
  is the migration for direct `Ingested` construction.
  Date: 2026-09-30


- Decision: sample each batch member's status exactly once in the shared
  `processOneBatchWithDetail` entry, preserving the existing basic/detailed
  specializations and all current-member finalization logic.
  Rationale: a wrapper on the exported entry is bypassed, and querying again can
  contradict an earlier superseded decision. This is an admission snapshot, not a
  lock preventing later rebalance or concurrent retry.
  Date: 2026-10-26

## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


### The two repositories


This repository publishes `shibuya-kafka-adapter`. Its library lives in
`shibuya-kafka-adapter/src`, its tests in `shibuya-kafka-adapter/test`. Two unpublished
sibling packages, `shibuya-kafka-adapter-jitsurei` (examples) and
`shibuya-kafka-adapter-bench` (benchmarks), are listed beside it in `cabal.project`.

The Shibuya framework lives in `mori://shinzui/shibuya`, checked out at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, which is `../shibuya` from
this repository's root. Its library is `shibuya-core`. It also holds
`shibuya-metrics`, `shibuya-example`, and `shibuya-core-bench`. Its root `CLAUDE.md`
lists its commands; its tests use `hspec`.

Both repositories require `nix fmt` before every commit. In this repository cabal must
run inside the Nix development shell (`nix develop -c bash -c '...'`), because the
Kafka client library comes from it.

### Terms


A Kafka partition is an ordered log of records, each with an increasing offset. A
consumer polls to read records from its position, and can seek to move that position
back so records are returned again. A consumer group remembers a committed offset per
partition. This adapter stores a record's offset only after its handler succeeds.

A handler is the application function that processes one message and returns an
`AckDecision`: `AckOk`, `AckRetry`, `AckDeadLetter`, or `AckHalt`. A delivery is one
attempt to hand a particular record to a handler; a record that is retried is
delivered more than once. The finalizer is the adapter function that carries out the
decision for a delivery.

The runner is the part of `shibuya-core` that `Shibuya.App.runApp` starts. For each
processor it runs an ingester thread, which pulls from the adapter's `source` stream
into the inbox (a bounded queue, 100 entries by default), and a processor thread,
which takes one entry at a time, calls the handler, and calls the finalizer. A batch
processor instead groups inbox entries into batches and calls a batch handler with
each batch.

### How the adapter tracks a retry


In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`, every delivery is
registered by `registerDelivery`, which gives it a `DeliveryAttempt`: its partition,
its offset, a delivery token (a number that increases with each delivery in this
process), and the partition's assignment generation (a number that increases when the
partition is revoked or reassigned). When a handler returns `AckRetry`, `recordRetry`
sets a retry barrier on the partition: the earliest offset waiting to be redelivered,
and the token of the delivery that asked. While the barrier is set, `claimStore`
refuses to store any offset above it. A delivery of the barrier offset with a newer
token clears it and sets `validFromToken`, below which deliveries are no longer
accepted. `attemptIsAccepted` is the existing predicate that checks assignment,
generation, and `validFromToken`. This design is recorded in
[`docs/adr/0001-fence-acknowledgements-by-delivery-and-assignment.md`](../adr/0001-fence-acknowledgements-by-delivery-and-assignment.md).

Plan 16 will add the source gate, `gateRecords`, in the same module. It drops records
polled before a retry seek and holds records delivered again after the seek until the
barrier is resolved. Plan 16 will also create an ADR in `docs/adr/` whose file name ends
in `hold-replayed-records-behind-a-pending-retry.md`, the broker-free log
in `shibuya-kafka-adapter/test/Kafka/ScriptedLog.hs`, and the test module
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourceGateTest.hs`. Both ADRs are
relevant. If plan 18 has been implemented there is a third, about polling under the
consumer lock, which does not affect this work.

The dependency checkout is identified by `mori://shinzui/shibuya`; all core paths
in this document are relative to that project's root. Artifact-level URIs for
source files and its unprofiled ADR directory are pending. `mori registry docs`
lists its documentation, and `mori path mori://shinzui/shibuya` resolves the root.
At review time its `docs/adr/` contains twelve records, and no delivery-status ADR.
Relevant records under that canonical project are:

- `docs/adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md`:
  compare runtime changes and treat allocation increases as regressions.
- `docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md`:
  preserve infrastructure failure reporting, cancellation, and wake-up behavior.
- `docs/adr/0009-account-for-in-flight-detail-and-latency-with-bounded-synchronized-slots-behind-an-opt-in-detail-level.md`:
  retain basic/detailed specialization, masked slot ownership, and successful
  finalization cursor hooks; a skipped delivery owns no slot and advances no cursor.
- `docs/adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md`:
  keep tracing ownership and cancellation intact; lifecycle spans coexist with
  processing spans, so telemetry tests must select the processing span.

Neither manifest currently declares a profiled ADR bundle. Preserve the existing
filesystem convention; if that changes, follow `agents/skills/exec-plan/ADR.md`
and use the registered canonical handle rather than inventing one. The core's
`AGENTS.md` limits benchmarking to the existing workflow; this plan does not
request new tooling, profiles, calibration, or remote measurement.

### The defect


Take one partition with offsets 0 through 49 and a handler that returns `AckRetry` the
first time it sees offset 20. One poll returns all fifty records and the ingester puts
them all in the inbox. The processor handles 0 through 19, then 20, which asks for a
retry; the adapter sets the barrier at 20 and seeks back. Offsets 21 through 49 are
already in the inbox. The processor takes each one, calls its handler, and finalizes
it. The adapter refuses to store those offsets, so nothing is lost, but the handlers
have run. Only then does the processor reach the second delivery of offset 20.

The adapter knows, at the moment the handler for offset 21 is about to run, that this
delivery is above a pending barrier and will be delivered again. Nothing asks it. In
`shibuya-core`, `Ingested` carries only an envelope, an ack handle, and an optional
lease, and `processOne` in
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` calls the handler
unconditionally.

### The pieces of `shibuya-core` this plan touches


`shibuya-core/src/Shibuya/Core/Ingested.hs` defines `Ingested` and the smart
constructor `mkIngested`.

```haskell
data Ingested es msg = Ingested
  { envelope :: !(Envelope msg),
    ack :: !(AckHandle es),
    lease :: !(Maybe (Lease es))
  }

mkIngested :: Envelope msg -> AckHandle es -> Ingested es msg
```

`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` defines `processOne`, the
per-message path used by every single-message processor, serial or concurrent. It
opens a tracing span, sets attributes, increments the in-flight count with
`beginProcessing`, calls the handler, calls `finalizeWithRetry`, and records the
outcome with `finishProcessing`.

`shibuya-core/src/Shibuya/Internal/Runner/BatchProcessor.hs` defines
`processOneBatch` and its shared worker `processOneBatchWithDetail`. The batch loop
calls the worker directly. It calls the batch handler with every retained member
and then finalizes every retained member, with basic/detailed metrics branches.

`shibuya-core/src/Shibuya.hs` is the umbrella module that re-exports `Ingested (..)`
and `mkIngested`.


## Plan of Work


### The design in one place


`shibuya-core` gains a two-valued type and one field.

```haskell
-- | Whether a delivery is still the adapter's current attempt at its message.
data DeliveryStatus
  = -- | Run the handler and finalize as usual.
    DeliveryCurrent
  | -- | The adapter has already arranged redelivery or fenced this delivery;
    -- the runner must neither run the handler nor finalize it.
    DeliverySuperseded
  deriving stock (Eq, Show)
```

`Ingested` gains `deliveryStatus :: !(Eff es DeliveryStatus)`. `mkIngested` sets it to
`pure DeliveryCurrent`, so an adapter that does nothing behaves exactly as before. The
runner runs the action at processing admission, before entering handler and metrics
work (once for each member when a batch is admitted). If the answer is
`DeliverySuperseded`, the single-message path records that on the span and skips
the delivery; the batch path excludes that member before opening its batch span.

The Kafka adapter answers from the state it already has. A delivery is current when
`attemptIsAccepted` holds for it and one of these is true: the partition has no
barrier; the delivery's offset is below the barrier; or its offset equals the barrier
offset and its token is newer than the token that asked for the retry. Everything else
is superseded: a successor above a pending barrier, the original delivery that asked
for the retry, a delivery older than `validFromToken`, and a delivery from a revoked
assignment.

For retry ordering in serial single-message processing this is exact. The processor
finalizes the retry for offset 20 before it takes offset 21 from the inbox, so when it asks about 21 the barrier is
already set. The successors are skipped, the redelivery of 20 is current, and once it
succeeds the barrier clears and the redelivered successors, which plan 16's gate
releases at that moment, are current too. The check does not atomically claim a
delivery: revocation may occur after a current answer and before handler entry, even
with a serial processor. It cannot prevent work already admitted or in progress,
and it does not repair plan 16's deferred pre-rebalance poll-buffer issue.

### Milestone 0: confirm the starting point


Read `docs/plans/16-hold-replayed-successors-so-a-buffered-retry-cannot-stall-partition-commits.md`
and verify its completed acceptance evidence against the source, rather than relying
only on checkboxes. Confirm that
`gateRecords` is exported from
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` and that the adapter
suite passes. Plan 16 is a prerequisite for implementation, not for this review.
If it remains incomplete, report that prerequisite and do not silently implement a
second plan under a review/update request. For implementation, obtain completion
of plan 16 before proceeding. After plan 16, capture its existing `Source gate`
benchmark baseline before changing the core dependency, using the commands in
that plan; capture the core baseline before Milestone 1 as shown below. Inspect both working trees and preserve unrelated
changes; do not reset them to satisfy a cleanliness check. Record both HEADs and
run the core suite before editing. Verify the candidate version against Hackage
and upstream tags using the commands in Concrete Steps; if 0.12.0.0 has since been
used without this API, consistently advance the candidate and bounds in this plan.

### Milestone 1: the delivery status in `shibuya-core`


All work in this milestone is in `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.
At its end the runner skips superseded deliveries and the core suite proves it.

Before editing, capture a benchmark baseline for Milestone 2, as shown in Concrete
Steps. It must be measured on the unchanged tree.

In `shibuya-core/src/Shibuya/Core/Ingested.hs`, add `DeliveryStatus` as shown above,
export `DeliveryStatus (..)`, import `Effectful (Eff)`, add the field to `Ingested`
after `lease`, and set it in `mkIngested`.

```haskell
    -- | Optional lease for visibility timeout extension
    lease :: !(Maybe (Lease es)),
    -- | Asked by the runner immediately before it invokes the handler.
    -- Must return promptly without synchronous exceptions; cancellation propagates.
    deliveryStatus :: !(Eff es DeliveryStatus)
  }
```

In `shibuya-core/src/Shibuya.hs`, add `DeliveryStatus (..)` to the export list next to
`Ingested (..)` and to the import from `Shibuya.Core.Ingested`.

In `mori://shinzui/shibuya`, edit
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`. After
`addAttributes traceSpan mergedAttrs`, ask `ingested.deliveryStatus`. For
`DeliveryCurrent`, run the existing `let process ...` body and its basic/detailed
branch unchanged. For `DeliverySuperseded`, emit `eventAckDecision` with
`attrShibuyaAckDecision = "superseded"` and set the span status to `OTel.Ok`.
Do not call the handler, finalizer, `beginProcessing`, slot ownership functions,
cursor recording, or outcome counters on that branch. Preserve the existing
`INLINE processOne`, the specialized `detailed` argument, masking and cleanup.

In the same project's `shibuya-core/src/Shibuya/Internal/Runner/BatchProcessor.hs`,
put filtering inside the shared `processOneBatchWithDetail` entry. Both exported
`processOneBatch` and `processBatchesUntilDrainedWithDetail` must reach it. Move
its existing processing body to a private worker taking the same `detailed`
argument and retained `(BatchInfo, NonEmpty Ingested)` pair; preserve specialization
and ownership behavior. Do not merely wrap exported `processOneBatch`.

Read every member's status once, in order. Scan the original list while counting
the current prefix. If all are current, pass the original pair through without
building a replacement member list. At the first superseded member, keep the
already-checked prefix, exclude that member, and filter only the unchecked suffix
with one read per member. Rebuild the retained list only on this exceptional path.
Never query the prefix or a rejected member again. Preserve order and, for a
nonempty retained list, use `info {size = NE.length retained}` so the batch key,
trigger, and partition remain unchanged. The retained first member supplies the
trace parent and detailed in-flight identity. If none remain, return without a
handler, finalizer, processing span, in-flight slot, cursor update, or batch outcome
metric. Received counters already recorded during ingestion stay unchanged.

The check must be a quick, nonblocking, side-effect-free read and must not throw a
synchronous exception. It is an admission snapshot, not a reservation or a second
check between members of a batch. Do not catch failures as handler exceptions or
turn them into acknowledgements; unexpected failure uses existing infrastructure
failure propagation, and asynchronous cancellation remains effective. The
`superseded` span event is a single-message-path guarantee; this plan does not
create individual spans for filtered batch members.

Add tests. In `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`, under a new
`describe "delivery status"`, using the file's existing helpers (`testAdapter`,
`createTestEnvelope`, `runWithMetrics`, `trackedListAdapter`,
`getTrackedDecisions`):

- "skips the handler and the finalizer for a superseded delivery": three deliveries,
  the second built with `(mkIngested env ack) {deliveryStatus = pure DeliverySuperseded}`.
  The handler records message ids. Expect the handler to have seen the first and
  third only, the finalizer to have been called for the first and third only, and
  metrics `received == 3`, `processed == 2`, `failed == 0`.
- "asks for the status at handler time, not at ingestion": three deliveries whose
  second status reads a shared `IORef Bool`, while the first and third remain current.
  Append a signal action after the third source yield (before any further upstream
  pull). The first handler awaits that signal, then changes the flag. Inbox size 10
  permits this schedule but does not establish it by itself. Bound the wait and
  clean up on failure. Expect the handler and finalizer to see only the first and third.
- "treats deliveries built by mkIngested as current": the existing tests cover this;
  add one explicit assertion that a default delivery is handled.

In `shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs`, using
`runBatchesWithMetrics`:

- "passes only current members to the batch handler": a batch of five with the second
  and fourth superseded. Expect the handler to receive three messages and a
  `BatchInfo` whose `size` is 3, and exactly those three to be finalized.
- "skips a batch whose members are all superseded": expect no handler call and no
  finalizer call and no processed/failed/batch outcome increments.
- "samples every batch status once": count status calls for mixed, all-current, and
  all-superseded batches; require one per member, stable order, and unchanged batch
  metadata except size. Include a status action returning superseded on its first
  invocation and current on any later invocation to catch accidental double reads.
- Exercise the real batch runner, not just a new filtering helper. Run skip cases
  with both basic and detailed metrics; a skipped delivery contributes no latency
  sample, in-flight identity, cursor progress, or slot leak. Add a two-batch case
  where finalizing the first changes the second batch's status before admission.

For both single and batch paths, verify a throwing status produces an infrastructure
failure with no handler or finalizer call, using existing lifecycle test helpers.

In `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs`, next to
the existing test "emits a process span with conventions-aligned attributes and
events", add a case asserting that a superseded delivery's span carries one
`shibuya.ack.decision` event with the value `superseded` and no handler-started event.
Copy the existing test's setup and filter by processing span name so the ingestion
lifecycle span does not invalidate the assertion.

Run the core suite and commit in the shibuya repository.

### Milestone 2: core regression gate, documentation, and candidate version


Still in the shibuya repository. At the end of this milestone the core is a committed
0.12.0.0 candidate that the adapter can build against.

Run the benchmark comparison against the baseline captured in Milestone 1. The change
adds one call through a record field per message on the single-message path and one
fold per batch. The comparison must not report any benchmark slower by more than ten
percent, and allocation per message must not rise; ADR 0006 treats an allocation
increase as a regression even when time is within noise. Record the figures for the
`hot-path` and `framework-overhead` groups in Surprises & Discoveries. Record time
and allocation from the same existing workload on both revisions; the CLI timing threshold alone is not allocation evidence. Adding a record field can
increase allocation even when its default action is shared. If either existing
limit is exceeded, record the result, investigate within the existing workflow,
and retain the gate as unmet until resolved or the owner explicitly changes it.
Do not expand benchmark tooling or measurement scope to work around a failed gate.

Update the documentation comments. In `Shibuya.Core.Ingested`, document the field:
when the runner asks, what each answer means, that it must not throw, and that it is
asked once per admitted delivery on both paths; clarify that a current answer does
not lock out a subsequent revocation or concurrent retry.
In `shibuya-core/src/Shibuya/Core/AckHandle.hs`, the module header says the framework
resolves one decision per delivery, with retries of that same decision on transient
finalizer failure. Preserve that exception and add that it is not called at all for a
delivery whose status is `DeliverySuperseded`. Search the prose documentation for the
same claim and update any statement that every ingested message is finalized.

```bash
rg -n -i "always finalize|always observes a finalization|finalized exactly once" docs README.md shibuya-core
```

In `mori://shinzui/shibuya`, create the next unused filesystem ADR named
`docs/adr/NNNN-let-adapters-supersede-a-delivery-before-its-handler-runs.md`
(the next number was 0013 at review), in the format of the existing records in
that directory (title, `Status:`, `Date:`,
`## Context`, `## Decision`, `## Consequences`, `## Evidence`). Record why the check
lives on `Ingested`, why a superseded delivery is not finalized and not counted, why
the call is not wrapped in an exception handler, and the alternatives from this plan's
Decision Log. Cite this plan as
`mori://shinzui/shibuya-kafka-adapter/plans/17-skip-superseded-buffered-deliveries-so-successors-cannot-run-before-a-retried-record`.

Add an `Unreleased` section at the top of the root `CHANGELOG.md` with a
`Breaking Changes` entry for `shibuya-core`: `Ingested` has a new field
`deliveryStatus`; code that builds `Ingested` with record syntax must add
`deliveryStatus = pure DeliveryCurrent`; code that uses `mkIngested` is unaffected.
Explain the migration for direct record constructors. The two adapters listed in
Surprises & Discoveries were September findings; use `mori registry dependents
shinzui/shibuya --packages` and inspect current constructors/bounds before naming
today's affected consumers. Audit direct constructors and record patterns in the
core checkout as well; positional uses must account for the new field.

Set `version: 0.12.0.0` in `shibuya-core/shibuya-core.cabal` and
`shibuya-metrics/shibuya-metrics.cabal`, and change every `shibuya-metrics` component's
core bound to `shibuya-core ^>=0.12.0.0`. `shibuya-example` and `shibuya-core-bench` depend
on `shibuya-core` without a version and need no change. Build everything and run the
`shibuya-core` and `shibuya-metrics` suites. Commit. Do not tag and do not publish.

### Milestone 3: the adapter answers the question


Back in this repository. At the end of this milestone the ordering tests pass.

Point the build at the unreleased core. `cabal.project.local` is git-ignored and
is absent on the reviewed checkout. Create it with the following when absent, or
merge the package entry into an existing override without overwriting user settings.
Record its previous contents/absence for Milestone 5.

```cabal
-- Temporary: build against the unreleased shibuya-core 0.12.0.0 candidate.
-- Remove once shibuya-core 0.12.0.0 is on Hackage (plan 17, Milestone 5).
packages:
  ../shibuya/shibuya-core
```

Change every `shibuya-core ^>=0.11.0.0` to `shibuya-core ^>=0.12.0.0`. The bound
appears in the library and test-suite stanzas of
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`, in
`shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`, and in
`shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`; find them all
with `rg -n "shibuya-core" -g "*.cabal" .`. Include both benchmark and executable
stanzas; there are five adapter-side occurrences at review time.

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`, split `mkAckHandle`
so that the delivery attempt is available to `mkIngested`. `mkAckHandle` keeps its
name and type and becomes a wrapper.

```haskell
mkAckHandle state config cr = do
  attempt <- Effectful.liftIO $ registerDelivery state cr
  ackHandleFor state config attempt cr

ackHandleFor ::
  (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
  KafkaAdapterState ->
  KafkaAdapterConfig ->
  DeliveryAttempt ->
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  Eff es (AckHandle es)
ackHandleFor state config attempt cr = do
  finalizerLock <- Effectful.liftIO $ newMVar ()
  completed <- Effectful.liftIO $ newIORef False
  pure $ AckHandle $ \decision -> ...   -- the existing body of mkAckHandle
```

Change `mkIngested` to register once and supply both the handle and the status, and
add `deliveryStatusOf`.

```haskell
mkIngested state config cr = do
  attempt <- Effectful.liftIO $ registerDelivery state cr
  ackHandle <- ackHandleFor state config attempt cr
  pure
    (Core.mkIngested (consumerRecordToEnvelope cr) ackHandle)
      { Core.deliveryStatus = Effectful.liftIO (deliveryStatusOf state attempt)
      }

deliveryStatusOf :: KafkaAdapterState -> DeliveryAttempt -> IO Core.DeliveryStatus
deliveryStatusOf state attempt = do
  ackState' <- readIORef state.ackState
  let partitionState = Map.findWithDefault initialPartitionAckState attempt.partition ackState'.partitions
      isCurrent =
        attemptIsAccepted partitionState attempt && case partitionState.barrier of
          Nothing -> True
          Just retryBarrier
            | attempt.recordOffset < retryBarrier.offset -> True
            | attempt.recordOffset > retryBarrier.offset -> False
            | otherwise -> attempt.token > retryBarrier.retryToken
  pure $ if isCurrent then Core.DeliveryCurrent else Core.DeliverySuperseded
```

Register exactly once per emitted delivery and share that same attempt between
status and acknowledgement; registering twice would split their identity. Keep
plan 16's seek-completion and cancellation-safe notification behavior unchanged.

The module already imports `Shibuya.Core.Ingested qualified as Core`.
`deliveryStatusOf` does not need to be exported; tests reach it through `mkIngested`.

Add tests to `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourceGateTest.hs` in a
new group `Delivery status`. Each builds deliveries with `mkIngested` under the mock
interpreter, finalizes some of them, and runs another delivery's `deliveryStatus`.

- A delivery with no barrier on its partition is current.
- After offset 42 is retried, a delivery of offset 43 made before the retry is
  superseded, and so is a delivery of 43 made after it.
- After offset 42 is retried, the delivery that asked for the retry is superseded and
  a new delivery of offset 42 is current.
- After that new delivery of 42 is finalized with `AckOk`, a delivery of 43 that was
  registered before the new delivery of 42 is superseded, and a delivery of 43
  registered after it is current.
- A delivery below the barrier is current.
- After `kafkaRebalanceHandler` reports the partition revoked, an existing delivery is
  superseded. After reassignment it stays superseded while a new delivery is current.
- A retry on one partition does not supersede another partition's delivery.
- Successful dead-letter finalization of the replay clears the barrier, with old
  tokens still superseded; a retry of the replay supersedes that attempt again.
- Plan 16's missing-offset recovery invalidates old delivery tokens, including their
  status actions, and admits the next available offset.

Update plan 16's two scripted retry tests in
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourceGateTest.hs`. Its current
revision treats handler traces as diagnostics; this plan makes the synchronized
single-message trace an assertion. Preserve the source wrapper's one-time signal
immediately after the first twelve yields, before pulling a thirteenth record.
The first offset-4 handler must wait for that signal before requesting retry, so
all original successors are queued. Do not use sleeps to establish this order.
Keep the original stream open, use `Serial`, and stop only after `stored` contains
all twelve offsets. Fail bounded waits explicitly and run `stopApp` in cleanup
while the Kafka interpreter remains alive.

For one retry, assert handler order `[0 .. 4] <> [4 .. 11]`, stored offsets
`[0 .. 11]`, and seeks `[4]`. For two retries assert
`[0,1,2,3,4,4,4,5,6,7,8,9,10,11]`, the same stores, and seeks `[4,4]`.
Rename them to `a retried record blocks its successors (scripted log)` and
`a twice-retried record blocks its successors (scripted log)`. Temporarily force
only the adapter status action to return `DeliveryCurrent` in a scratch change,
keeping plan 16 intact: the forced-buffering test must fail its handler-order
assertion (the historical one-retry trace is `[0 .. 11] <> [4 .. 11]`). Restore the
actual action and require both tests to pass. Without the handshake this negative
control could pass just because the ingester was slow.

Retain plan 16's serial batch-runner liveness test. Superseded later batches must
be skipped; the batch containing the retry can still have handled successors.
The replay must be emitted by batch timeout, release the source hold after its
successful finalization, and eventually store all offsets. Do not impose the
single-message trace on this batch test.

Add the live test `a retried record blocks its successors` in
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs`: twelve
payloads `o-0` through `o-11`, one partition, a serial `runApp` handler retrying
`o-4` once, and the same source/handler handshake to prove buffering. Observe
successful finalization through a test-local acknowledgement wrapper that calls
the real finalizer first and only then publishes completion, or use plan 16's
verified committed-offset observation under the shared consumer lock. Waiting for
the handler to return `AckOk` alone is insufficient. Once all twelve finalizations
complete, gracefully stop, require successful drain, and assert the exact handler
trace `o-0, o-1, o-2, o-3, o-4, o-4, o-5, ..., o-11`. Retain plan 16's committed
offset 12 and restart assertions as commit-regression coverage.

Rewrite `Handler exception redelivers instead of skipping` in that same file.
Remove `Stream.take 4`; keep the source open until successful finalization of
`n-1`, `n-2`, and `n-3`, using the same completion technique. The first handling
of `n-2` throws as today. Require successful drain and exact handler trace
`["n-1","n-2","n-2","n-3"]`. For both live tests wrap the entire session in a
sixty-second timeout and ensure bracketed `stopApp` cleanup also runs on failure.
Do not terminate the source by emitted-record count: skipped deliveries still
occupy source yields.

Run the suite and commit. The commit message must say that the build needs the
unreleased core until 0.12.0.0 is published.

### Milestone 4: adapter regression gate, documentation, and records


Run the full suite ten times in a row and build all three packages with benchmarks
enabled. Capture a fresh `Source gate` baseline after plan 16 and before changing
the core dependency, then compare using plan 16's existing commands and ten-percent
threshold. Its original scratch CSV may have been deleted; do not compare against
a missing or pre-plan-16 fixture.

Update the prose. In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`, extend the
`Message Lifecycle` item for `AckRetry` to say that records of the same partition
already handed to a serial single-message runner are skipped before handler entry
and are delivered again after the retried record, subject to the missing-offset
recovery policy. Describe the same-batch and concurrent-processing limits. In the
`Serial Operation Required` section,
add that under serial processing a retried record now blocks its successors. In the
`Rebalance Callback Helper` section, add that with the helper installed, deliveries
whose old assignment is already revoked when checked are skipped. Revocation after
the check cannot cancel an admitted handler. Make the matching changes to
`README.md` and `shibuya-kafka-adapter/README.md`.

Update `docs/capabilities/offset-acknowledgement-semantics.md` (CAP-2) with the
ordering guarantee and its limit to serial processing, add the two new tests to its
`evidence`, update `generated`, add a log entry, and validate. Check
`docs/capabilities/kafka-message-source.md` (CAP-1) for any statement about retry
order and correct it if present.

Add to the `Unreleased` section of `shibuya-kafka-adapter/CHANGELOG.md` a
`Breaking Changes` entry (requires `shibuya-core ^>=0.12.0.0`) and a `Bug Fixes` entry
describing the ordering fix.

Write an ADR in `docs/adr/`, numbered with the next unused four-digit number and
named `NNNN-answer-delivery-status-from-the-retry-barrier.md`, in the format of
ADR 0001, recording the predicate, why retry ordering is exact under serial
single-message processing, the same-batch limit and rebalance race, and that it depends on the core contract
recorded in `mori://shinzui/shibuya` by the ADR written in Milestone 2. Cite that
project together with the exact new ADR path while artifact URIs remain pending;
use its canonical handle if ADR registration has been adopted.

Mark BUG-2 fixed in
`docs/bug-reports/2-buffered-successors-execute-before-a-retried-record.md`: set
`status: fixed`, add `fixedVersion: "unreleased"`, add a `resolution` naming this plan
and the ordering tests, update `generated`, add a `Resolution` section, add a log
entry, and validate.

### Milestone 5: verify from Hackage after the core release


This milestone cannot start until `shibuya-core` 0.12.0.0 is published, which is a
release the repository owner performs. Leave its Progress item unchecked and say so in
Outcomes & Retrospective if the plan is otherwise complete.

When the feature-bearing release exists, remove only this plan's package override
and restore the file's recorded previous contents or absence,
run `cabal update`, build everything, and run the suite. The build plan must show
`shibuya-core-0.12.0.0` coming from Hackage rather than from `../shibuya`.


## Concrete Steps


### In the shibuya repository


Working directory: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

Verify the release frontier before choosing a candidate. At review both registries
and the upstream tags ended at 0.11.0.0; 0.12.0.0 is the planned feature release.

```bash
curl -fsSL -H 'Accept: application/json' https://hackage.haskell.org/package/shibuya-core/preferred
curl -fsSL -H 'Accept: application/json' https://hackage.haskell.org/package/shibuya-metrics/preferred
git ls-remote --tags https://github.com/shinzui/shibuya.git
```

Capture the benchmark baseline on the unchanged tree, before Milestone 1's edits.

```bash
nix develop -c bash -c 'cabal bench shibuya-core-bench --benchmark-option=--csv --benchmark-option=delivery-status-baseline.csv --benchmark-option=+RTS --benchmark-option=-T'
```

Run the core suite.

```bash
nix develop -c bash -c 'cabal test shibuya-core:test:shibuya-core-test --enable-tests'
```

Require `Test suite shibuya-core-test: PASS` and zero failures. Record the current
example count from the run; the September prototype's count of 236 is historical,
not the current baseline.

Run all core suites and the metrics suite before committing.

```bash
nix develop -c bash -c "cabal build all --enable-benchmarks && cabal test shibuya-core && cabal test shibuya-metrics"
```

Compare against the baseline after Milestone 1.

```bash
nix develop -c bash -c 'cabal bench shibuya-core-bench --benchmark-option=--baseline --benchmark-option=delivery-status-baseline.csv --benchmark-option=--fail-if-slower --benchmark-option=10 --benchmark-option=+RTS --benchmark-option=-T'
```

`cabal bench` runs in the package directory, so the CSV is written to
`shibuya-core-bench/delivery-status-baseline.csv`. Delete it when the comparison is
recorded; it must not be committed.

Stage only the intended files, explicitly adding new ones, and commit in
`mori://shinzui/shibuya` with the cross-repository trailer.

```bash
nix fmt
git add -p
git commit
```

```text
feat(core)!: let adapters supersede a delivery before its handler runs

<body>

ExecPlan: mori://shinzui/shibuya-kafka-adapter/plans/17-skip-superseded-buffered-deliveries-so-successors-cannot-run-before-a-retried-record
Intention: intention_01m3sbterne78sx93pm5d6qf66
```

### In this repository


Working directory: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`.

Confirm the broker is reachable before any live test, and start it with `redpanda-up`
if it is not.

```bash
rpk cluster info -X brokers=127.0.0.1:9092
```

Confirm the build uses the sibling core once `cabal.project.local` is in place. The
first command writes the build plan; the second reads where `shibuya-core` comes from.

```bash
nix develop -c bash -c 'cabal build shibuya-kafka-adapter --dry-run'
python3 -c 'import json; print([(u["pkg-version"], u["style"]) for u in json.load(open("dist-newstyle/cache/plan.json"))["install-plan"] if u.get("pkg-name") == "shibuya-core"])'
```

```text
[('0.12.0.0', 'local')]
```

Run broker-free checks before live tests. This command currently runs 40 tests;
plan 16 and this plan add more. It does not certify live acceptance.

```bash
nix develop -c bash -c 'cabal test shibuya-kafka-adapter --test-show-details=streaming --test-option=-p --test-option="!/Integration/"'
```

Run the whole suite, and the new groups alone.

```bash
nix develop -c bash -c 'cabal test shibuya-kafka-adapter --test-show-details=streaming'
nix develop -c bash -c 'cabal test shibuya-kafka-adapter --test-show-details=streaming --test-option=-p --test-option="/Delivery status/"'
nix develop -c bash -c 'cabal test shibuya-kafka-adapter --test-show-details=streaming --test-option=-p --test-option="/a retried record blocks its successors/"'
```

After Milestone 3 the scripted ordering test asserts on these values.

```text
deliveries = [0,1,2,3,4,4,5,6,7,8,9,10,11]
stored     = [0,1,2,3,4,5,6,7,8,9,10,11]
seeks      = [4]
```

Run the suite ten times and build everything.

```bash
nix develop -c bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do cabal test shibuya-kafka-adapter || exit 1; done'
nix develop -c bash -c "cabal build all --enable-benchmarks"
```

The old September `crypton <2.1.3` workaround is removed. Plan 16's review already
verified an unconstrained all-component build. If a new dependency failure occurs,
use Mori source discovery, the authoritative registry, and upstream release tags
before selecting a new workaround.

Record and validate the capability and bug-report changes.

```bash
okf log add docs/capabilities --kind Update -m "CAP-2 states that a retried record blocks its successors under serial processing."
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf log add docs/bug-reports --kind Update -m "BUG-2 is fixed on the default branch: buffered successors are skipped until the retried record is resolved."
okf validate docs/bug-reports --strict --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
```

Commit in this repository with the local trailer.

```text
fix(kafka)!: skip buffered successors until a retried record is resolved

<body>

ExecPlan: docs/plans/17-skip-superseded-buffered-deliveries-so-successors-cannot-run-before-a-retried-record.md
Intention: intention_01m3sbterne78sx93pm5d6qf66
```

For Milestone 5, confirm the release exists before removing the override.

```bash
curl -fsSL -H 'Accept: application/json' https://hackage.haskell.org/package/shibuya-core/preferred
```

The `normal-version` list must contain the selected feature-bearing version. Check
its upstream tag and source/API as well: a version string alone does not prove the
field exists. After removing the override, run `nix develop -c cabal update` and
rebuild/test. Inspect `dist-newstyle/cache/plan.json`: the core unit must have the
selected version, `style: "global"`, and `pkg-src.type: "repo-tar"` rather than a
local path or source-repository checkout. Confirm its repository is Hackage.


## Validation and Acceptance


In `shibuya-core`, the new tests show that the handler and the finalizer are not
called for a superseded delivery, that the status is read at handler time rather than
at ingestion, that a batch handler receives only current members with a matching
`BatchInfo.size`, and that an all-superseded batch is skipped. Every test that existed
before still passes, which shows that a delivery built by `mkIngested` behaves as it
did. The benchmark comparison reports no benchmark more than ten percent slower and no
rise in allocation per message.

In the adapter, the scripted test shows handler order `0,1,2,3,4,4,5,...,11` with all
twelve offsets stored. With only its status action forced to `DeliveryCurrent` and
plan 16 retained it shows `0..11, 4, 5..11`. The live test shows the same order against Redpanda. The second
scripted test shows `0,1,2,3,4,4,4,5,...,11`: a record that fails twice still blocks
its successors, and they run once.

The delivery-status tests show each branch of the predicate, including current
redelivered successors, old-token fencing after success or a missing-offset gap,
partition isolation, and old-generation fencing through revoke/reassign.

Every adapter test that existed before this plan passes, with two intended changes:
the expected handler order in plan 16's two scripted tests, and the rewritten
`Handler exception redelivers instead of skipping`. The BUG-5 tests
`later buffered retry cannot replace the earliest recovery boundary` and
`fixed-seed sequences match the earliest-unresolved reference model`, and the BUG-1
tests from plan 16, must still pass unchanged in what they assert about stored and
committed offsets.

The suite passes ten times in a row and all three packages, including benchmark
components, build. Core skip tests cover both basic and detailed metrics and the
actual batch worker; status failure is observable as an infrastructure failure.

These limits are part of the accepted behaviour and must be stated in the
documentation. The guarantee is exact only under serial processing, which is the only
mode the adapter supports; under concurrent processing a successor can be asked about
before its predecessor's retry is recorded. A serial batch handler still receives the
members of one batch together, so a successor in the same batch as the retried record
is handled with it; still-buffered successors in later batches are skipped. Rebalance
fencing is checked at admission and does not cancel work admitted just before a
revocation. Missing-offset recovery follows plan 16's explicit gap policy.


## Idempotence and Recovery


Every step can be repeated. The tests create topics and groups with random prefixes
and leave them on the shared broker, as the existing suite does. Benchmark CSV files
are scratch output.

The two repositories are changed in order. If work stops after Milestone 2, the
shibuya repository holds an unreleased 0.12.0.0 candidate and this repository is
untouched and still builds from Hackage. If work stops during Milestone 3 before the
commit, restore only this plan's override using the saved contents/absence and
revert only its own edits; preserve pre-existing user work.

After the Milestone 3 commit and until Milestone 5, this repository builds only with
the `cabal.project.local` override. A symptom of a missing override is a solver
failure naming `shibuya-core ^>=0.12.0.0`. Restore the package entry as shown in
Milestone 3, preserving other local settings.

If the core change has to be withdrawn, revert the Milestone 1 and 2 commits in the
shibuya repository and the Milestone 3 and 4 commits here; plan 16's behaviour is
independent and stays.

Do not tag, publish, or release either package from this plan.


## Interfaces and Dependencies


No new package dependency is added in either repository.

At the end of Milestone 1, `Shibuya.Core.Ingested` in `shibuya-core` exports the
following, and `Shibuya` re-exports `DeliveryStatus (..)`.

```haskell
data DeliveryStatus = DeliveryCurrent | DeliverySuperseded

data Ingested es msg = Ingested
  { envelope :: !(Envelope msg),
    ack :: !(AckHandle es),
    lease :: !(Maybe (Lease es)),
    deliveryStatus :: !(Eff es DeliveryStatus)
  }

mkIngested :: Envelope msg -> AckHandle es -> Ingested es msg
```

`Shibuya.Internal.Runner.BatchProcessor.processOneBatch` keeps its name and type.
`AckHandle`, `Adapter`, `Handler`, `BatchHandler`, `Message`, and `toMessage` are
unchanged. The check remains framework-owned and is not exposed to handlers.

At the end of Milestone 3, `Shibuya.Adapter.Kafka.Internal` still exports `mkAckHandle`
and `mkIngested` with their current types. `ackHandleFor` and `deliveryStatusOf` are
internal to the module. The public module `Shibuya.Adapter.Kafka` keeps its export
list.

The adapter's three cabal files require `shibuya-core ^>=0.12.0.0`.

Other consumers of `shibuya-core` are affected only when they move to 0.12.0.0. The
two that build `Ingested` with record syntax, named in Surprises & Discoveries, need
`deliveryStatus = pure DeliveryCurrent` added to that record. Consumers that only
depend on the library need a bound change. That work belongs to those repositories.

The verification suite `mori://shinzui/keiro-runtime-kenshou` marks its BUG-1 and
BUG-2 scenarios as known defects for adapter versions below a fixed bound. When it
moves to a release containing this change it will need to update that bound and adapt
to the `Shibuya.Adapter.Kafka.Internal` changes described in plan 16. That work
belongs to that repository.


Revision note (2026-10-26): reviewed the current core/adapter sources, relevant ADRs,
plan 16, Hackage versions, and upstream tags. Advanced the candidate beyond the
already-published core, moved batch admission to the shared worker, preserved
detailed metrics ownership, replaced double status reads and scheduling assumptions,
and strengthened finalization-based completion and recovery instructions. Prototype
results remain historical; implementation and live acceptance remain outstanding.
