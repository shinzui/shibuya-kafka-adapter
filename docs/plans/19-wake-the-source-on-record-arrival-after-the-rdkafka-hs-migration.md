---
id: 19
slug: wake-the-source-on-record-arrival-after-the-rdkafka-hs-migration
title: "Wake the source on record arrival after the rdkafka-hs migration"
kind: exec-plan
created_at: 2026-10-26T23:03:23Z
intention: "intention_01m5x7d23wetqt4qzbnbrjg68t"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-26T23:03:23Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-26T23:07:37Z
      mode: "other"
      note: "Link the owner-requested Mina intention and finalize the migration-blocked plan and acceptance contract."
---

# Wake the source on record arrival after the rdkafka-hs migration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

**Blocked: complete this repository's migration to `rdkafka-hs` before starting
implementation.** The migration is separate work planned by the repository owner;
this plan neither performs it nor authorizes changes in dependency repositories.
The canonical dependency is `mori://shinzui/rdkafka-hs`. No local migration plan
was found at authoring time. Link its
actual artifact here when it exists; do not invent a plan number.

After the migration and this plan, an idle Kafka source will wait for notification
that its queue has work, outside the consumer lock, instead of waking every few
milliseconds to look for records. Records should reach the handler without the
idle timer's delay, while idle CPU approaches the historical blocking-poll
baseline. Shutdown and fatal errors must still end the wait promptly, and retry,
offset, and assignment fencing must remain intact.

This implements IR-1 in
`docs/improvement-requests/1-wake-the-source-on-record-arrival.md`. Prove the outcome
with deterministic notification/lifecycle tests and live measurements through the
Shibuya runner. Merely depending on a library that exports notifications does not
complete this work or remove its migration gate.


## Progress

- [ ] Prerequisite gate: the separate `rdkafka-hs` migration is complete in this
  repository, its build and behavior checks pass, and this plan is refreshed
  against the selected dependency sources and accepted lifecycle contract.
- [ ] Milestone 1: a migrated consumer delivers a notification through the actual
  effect/interpreter path; deterministic tests characterize idle, race, fatal,
  and cleanup behavior and fail when notification handling is disabled.
- [ ] Milestone 2: the source uses notification-driven waiting with bounded fatal
  checks; race, cancellation, teardown, and existing delivery-safety tests pass.
- [ ] Milestone 3: live runner behavior and repeated performance measurements meet
  acceptance; package builds and supported-runtime checks pass; request,
  capability documentation, changelog, and ADR evidence agree.

Handoff (2026-10-26): planning only; implementation is blocked. No dependency pins,
source, or tests were changed. The gate below is mandatory before Milestone 1.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: block implementation on the separate migration to
  `mori://shinzui/rdkafka-hs`, replacing the original request's dependency on a new
  `hw-kafka-client` binding. Rationale: explicit owner direction; the inspected
  replacement library already implements notifications. Date: 2026-10-26.
- Decision: refresh the API, runtime, and lifecycle design after migration before
  unblocking. Rationale: the local replacement source identifies itself as
  1.0.0.0, but remote tags already include v1.1.0.0; local APIs are evidence of
  feasibility, not an approved version selection or final integration contract.
  Date: 2026-10-26.
- Decision: retain consumer-operation serialization, wait outside that lock, and
  bound notification waits. Rationale: protect delivery/seek ordering and detect
  fatal states that do not notify the watched queue. Date: 2026-10-26.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` owns `kafkaSource`,
`KafkaAdapterState`, `withConsumerLock`, and the delivery/retry gate. The consumer
lock serializes adapter operations that use the native consumer. The current
source still calls `pollMessageBatch` with a bounded positive timeout under that
lock. It does not yet contain plan 18's zero-timeout drain and idle delay.

`docs/plans/18-drain-the-consumer-queue-without-blocking-under-the-consumer-lock.md`
is approved but unimplemented at authoring time. Its 10 ms delay, 0.90% idle CPU,
and 17 ms mean latency are historical prototype observations. Its intended
foundation matters here: drain currently available records with zero-timeout
single-record polls, retain locking and seek-serial stamping, limit each lock
acquisition to `batchSize`, and wait only after proving the queue empty. The
migration or separate plan-18 work must establish an equivalent foundation before
this plan starts. Plan 18 need not be implemented verbatim against the retired
client, and its runtime workaround must not be copied without revalidation.

`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` constructs the adapter and
currently implements shutdown by setting `shutdownVar` and committing stored
offsets. The surrounding consumer interpreter owns consumer close/destruction.
Returning an adapter does not by itself provide exception-safe lifetime ownership
for file descriptors; this plan must use a scope that covers source execution,
early termination, and exceptional exits. `fatalError` and `ackSignal` in the
internal state already communicate acknowledgement failures and retry changes.

`shibuya-kafka-adapter/test/Kafka/ScriptedLog.hs` and
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourceGateTest.hs` exercise the
real adapter and runner with controlled consumer responses. `AdapterTest.hs`,
`AckHandleTest.hs`, and `DeliveryStatusTest.hs` in the same test directory cover
shutdown and delivery semantics. `IntegrationTest.hs` uses real Kafka through
`shibuya-kafka-adapter/test/Kafka/TestEnv.hs`; its broker setting is
`KAFKA_TEST_BROKER`; read the fixture and current broker recipes for the default
address when resuming, since broker infrastructure is being updated separately.

Consulted local decisions are
[ADR 0001](../adr/0001-fence-acknowledgements-by-delivery-and-assignment.md),
[ADR 0002](../adr/0002-hold-replayed-records-behind-a-pending-retry.md), and
[ADR 0003](../adr/0003-answer-delivery-status-from-the-retry-barrier.md).
Keep per-delivery and assignment fencing, seek-serial stamping, interruptible
successor holds, and the lock-free delivery-status read. This work adds no
concurrent-processing guarantee and must not allow an offset commit past an
unresolved retry.

The replacement's notification implementation is recorded at
`mori://shinzui/rdkafka-hs/plans/4-expose-queue-event-notification-for-consumers`.
Its file was inspected through Mori's registered project path, although
`mori path` could not resolve this plan artifact with the current registry.
The resolved ownership decision is
`mori://shinzui/rdkafka-hs/okf/adrs/concepts/ADR-1`: callers own event descriptors,
serialize consumer operations with teardown, and keep descriptors open until
notifications are disabled or the client is destroyed. Graceful consumer close
and immediate destruction are distinct operations.

A notification is a hint that the native queue changed, not a count of records.
Several records can share one notification; an event can wake the source without
producing a record. In asynchronous callback mode the library services callbacks
in the background, and a fatal error can occur on a different queue from the one
being watched. The wait therefore needs a safety deadline even when registration
and pipe handling are correct.


## Plan of Work

### Prerequisite: accept the migration and refresh this plan


Do not begin feature implementation while this gate is open. Record the actual
migration plan or commit and its acceptance evidence here. The adapter library,
examples, benchmark, test interpreters, tracing path, and transitive Kafka
dependencies must agree on the migrated consumer types; changing one Cabal
dependency name is insufficient. The migrated checkout must build and pass its
delivery, retry, shutdown, and live-consumer checks. Record which threaded,
non-threaded, and callback modes the migration supports.

Use Mori to inspect the exact selected dependency source, and verify releases
against its authoritative registry/release channel and upstream tags before
changing any bounds or pins. Update this plan's source references, exact effect
operation, interpreter implementations, cleanup ownership, and runtime checks.
The application-facing consumer abstraction must support enabling and disabling
notifications with an explicit descriptor lifetime. If that operation is still
missing from `mori://shinzui/kafka-effectful` or its migrated replacement, record
the owning project's prerequisite artifact and remain blocked until delivered;
do not silently bypass the abstraction through a raw consumer handle.

Verify the zero-timeout drain foundation described above. If it is absent, keep
this gate open and resolve it through the migration or plan 18. If migration has
already implemented notification waiting, revise this plan around the remaining
acceptance gaps instead of adding a second waiter. Close the prerequisite only
after recording the evidence and refreshing the rest of this document. An
upstream release, or passing upstream tests alone, does not close the gate.

### Milestone 1: prove the migrated notification contract


Add a `Source wake` test group, registered in
`shibuya-kafka-adapter/test/Main.hs`, with cases in a new
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourceWakeTest.hs`. Extend the
scripted interpreter to control record arrival, notification, and empty polls
independently. Use synchronization barriers to place arrivals at exact race
boundaries, rather than sleeps that merely hope the race occurs. Include a
negative control that disables notification so arrival waits for the safety
deadline and the prompt-arrival assertion fails.

Before expanding the implementation, exercise one live record through the actual
migrated effect and interpreter: register, establish an empty queue, produce,
observe readiness, consume, disable, and release. Exercise every callback mode
supported by the migration, including the tracing interpreter if it remains a
separate implementation. Evidence must establish both correct queue selection
and resource ownership, not merely that a direct library example works.

### Milestone 2: integrate waiting and exception-safe ownership


In the internal source implementation, compose the existing bounded drain with a
notification waiter. Prefer a bracket around source consumption so an unconsumed
adapter allocates no pipe and early stream termination releases resources. The
gate refresh must select the migrated stream's supported bracket facility and
record its API before coding. Acquisition and release occur inside the live
consumer scope; the surrounding interpreter may close the consumer only after
the source worker and its cleanup have finished. Allow one active notification
owner per consumer; registration replaces the previous owner in the inspected
library, so overlapping source runs must be rejected or otherwise excluded by an
explicit, tested contract.

For the inspected descriptor-based API, create a pipe, set both ends nonblocking,
and register its write end under the consumer lock. A nonblocking pipe returns
immediately when empty or full instead of stalling a native library thread.
Release must disable notification under the lock, unregister/join any readiness
waiter, and close both descriptors exactly once. Handle partial acquisition,
consumer errors, cancellation, and repeated shutdown. Do not close a descriptor
while the native client can still write to it; if deregistration fails, the
documented consumer-destruction path must complete before descriptor closure.
Do not make shutdown close the pipe underneath a waiting source.

Each iteration discards existing pipe bytes **before** its zero-timeout queue
drain. The drain and seek-serial read run under the consumer lock; waiting and
pipe reads do not. A full batch means there may be more queued work: emit it and
drain again without waiting. A non-record event is not proof that the queue is
empty. Only an actual empty result permits a wait. Never discard the fresh
notification after the final empty poll and then wait, since that would erase an
arrival in that interval. On pipe reads, handle the expected would-block result
as empty, distinguish EOF and real errors, and do not swallow cancellation.

Compose descriptor readiness with shutdown, adapter fatal-state changes, and a
one-second safety deadline. Use the migrated runtime's cancellable readiness
mechanism; an STM readiness registration can be combined with state changes if
the selected runtime supports it. STM is Haskell's transactional mechanism for
waiting on shared variables. Ensure registrations and any helper workers are
released on every branch. Notification wakes should trigger an immediate drain;
deadline expiry must perform a fatal-state check even if no notification arrived.
Local shutdown and local fatal publication must wake immediately rather than
waiting the full second. Preserve error classification and successful offset
finalization. Zero timeout removes waiting for record arrival inside a poll;
it does not bound arbitrary callbacks, commits, or seeks.

Keep the runtime support established by migration. If non-threaded operation
retains a compatible blocking path, preserve and test it separately; do not
claim the notification/no-idle-poll guarantees for that path. If migration
rejects a runtime/mode, retain its explicit rejection rather than reinstating
the old workaround. Do not enlarge supported-platform scope in this plan.

### Milestone 3: live acceptance and documentation


Run deterministic tests, the migrated compatibility suites, all package builds,
and live delivery/retry/rebalance/shutdown tests. Measure the migrated baseline
and candidate with the same broker, machine, runtime capabilities, tracing
settings, and workload. Extend the existing benchmark package with a small
`source-wake-live` executable at
`shibuya-kafka-adapter-bench/app/SourceWakeLive.hs` and register it in
`shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`. It must use the real
runner, unique test-owned topics/groups, a serial successful handler, and report
process CPU time divided by monotonic elapsed time, record counts, and
produce-to-handler latency. Collect CPU from the consumer process, excluding
the load generator; use a separate producer process for latency runs. It must
await assignment and catch-up before measuring, validate successful finalization
and shutdown, and fail on missing records or a stalled deadline.

Run three 60-second idle samples and three 30-second samples at two records per
second. Report each run plus aggregate mean and p95 latency; retain the original
IR targets of approximately 0.2% of one core idle CPU and mean latency below
17 ms. These are historical targets, not promised outcomes. A failure keeps
performance acceptance open; do not quietly relax it. Explain noise and client
background CPU with the new baseline. Also replay the fifty-record caught-up
workload from BUG-7 and confirm successful finalization is not serialized behind
arrival waits.

Update `docs/improvement-requests/1-wake-the-source-on-record-arrival.md`,
`docs/capabilities/kafka-message-source.md`,
`shibuya-kafka-adapter/README.md`, and `shibuya-kafka-adapter/CHANGELOG.md` with measured behavior
and runtime limits. Reconcile the obsolete gap in `mori/upstream-issues.dhall`
when the migration/feature actually resolves it. Preserve historical BUG-7 and
plan-18 measurements as historical. Add or update a local ADR for descriptor
ownership and wake ordering after the implementation proves the contract.
Record material implementation friction through the exec-plan skill's
`agents/skills/exec-plan/FRICTION.md` workflow and triage it at completion.


## Concrete Steps

Run from the repository root. While blocked, use read-only readiness checks only:

```bash
git status --short
rg -n 'rdkafka-hs|hw-kafka-client|hw-kafka-streamly|kafka-effectful' cabal.project flake.nix nix shibuya-kafka-adapter/*.cabal shibuya-kafka-adapter-jitsurei/*.cabal shibuya-kafka-adapter-bench/*.cabal
mori registry search rdkafka-hs
mori registry show shinzui/rdkafka-hs --full
mori registry docs shinzui/rdkafka-hs
mori path mori://shinzui/rdkafka-hs/okf/adrs/concepts/ADR-1
git ls-remote --tags https://github.com/shinzui/rdkafka-hs.git
```

The current checkout still lists the old client. Record the migrated revision
and dependency graph, not simply this search's output, when closing the gate.
Refresh these commands if migration changes package or test names.

After unblocking, the new deterministic group and package build run as follows:

```bash
nix develop -c cabal test shibuya-kafka-adapter:test:shibuya-kafka-adapter-test --test-show-details=streaming --test-option=-p '--test-option=/Source wake/'
nix develop -c cabal build all
```

Both must exit zero, and the selected test output must show the new cases
actually ran. Repeated deterministic runs must include the race and cancellation
cases. For live checks, start the existing project broker in another terminal,
or set `KAFKA_TEST_BROKER` to the accepted isolated test broker:

```bash
nix develop -c just process-up
```

```bash
nix develop -c cabal test shibuya-kafka-adapter:test:shibuya-kafka-adapter-test --test-show-details=streaming
nix develop -c cabal run source-wake-live -- --idle-seconds 60 --latency-seconds 30 --records-per-second 2 --runs 3
```

The measurement executable is a Milestone 3 deliverable, not an existing command.
It reads `KAFKA_TEST_BROKER`, prints per-run CPU/latency/count/completion evidence,
and exits nonzero on workload or cleanup failure. Preserve matching baseline
results before integrating the candidate. Add the exact migrated runtime-matrix
commands at gate acceptance; do not invoke plan 18's proposed unthreaded suite
unless that suite has actually been delivered.

Validate the plan/request documentation with:

```bash
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
git diff --check
```

When implementation changes capabilities, validate that bundle with its own
profile and update its log. Run `mori validate` after changing its catalog. Run
`nix fmt` before any implementation commit and include the trailer
`ExecPlan: docs/plans/19-wake-the-source-on-record-arrival-after-the-rdkafka-hs-migration.md`
and `Intention: intention_01m5x7d23wetqt4qzbnbrjg68t` trailers.


## Validation and Acceptance

For a quiet scripted queue, after initial draining, advance three safety deadlines
and observe exactly one empty/fatal check per deadline and no timer polling in
between. Real librdkafka events can cause additional legitimate wakes; do not
equate every wake with a record or require the native callback thread to stop.

Force arrivals before registration, between pipe clearing and draining, between
the final empty poll and waiting, and while waiting. Every record must be handled
once in the scripted scenario without waiting for a safety deadline. Test one
notification for more than `batchSize` records, repeated rearming, empty/spurious
wakes, pipe saturation, and timeout concurrent with arrival. Assert order and
successful stores as well as handler entry. The disabled-notification negative
control must fail the prompt-arrival test.

While the source is parked, a finalizer must acquire the consumer lock and
complete. Shutdown, local fatal publication, and cancellation must release the
waiter and resources; synchronized tests allow at most 250 ms for a local wake
and one second for worker cleanup. A native fatal error without a notification
must surface by the one-second safety deadline plus 250 ms scheduling allowance.
Verify exception and partial-acquisition paths, duplicate shutdown, and early
stream termination. No active waiter or open owned descriptor may remain after
scope exit. Deregistration must precede descriptor closure, and consumer teardown
must not race source cleanup. Existing retry, seek-serial, assignment fencing,
delivery-status, and commit/restart tests must retain their assertions.

Live acceptance must cover each supported callback mode, idle-to-active
transition, more than one batch, rebalance, fatal propagation, and graceful
shutdown. Passing scripted tests alone does not certify the native registration
or lifetime rules. CPU and latency acceptance uses the repeated measurements and
targets specified in Milestone 3. Report unavailable broker access as unfinished
acceptance rather than substituting prototype figures or skipped tests.


## Idempotence and Recovery

The migration is owned by separate work and must not be performed or reverted by
this plan. Discovery and tests are repeatable; live fixtures must use unique
test-owned topics and groups and clean up only their own resources. Do not delete
shared topics or reset production offsets.

An interrupted registration must release partially acquired resources without
closing a still-registered descriptor. Repeated shutdown and cleanup must be safe
and must join any in-progress cleanup. Preserve the migrated drain behavior as
the rollback baseline: reverting this feature restores its prior idle wait and
removes notification ownership without changing the migrated dependency stack.
If runtime or lifetime evidence contradicts this design, keep affected milestones
open, update the plan, and resolve the contract before expanding implementation.


## Interfaces and Dependencies

The hard prerequisite is the completed adapter migration to
`mori://shinzui/rdkafka-hs`, including a compatible consumer effect and its
interpreters. This is not a child of an existing MasterPlan. The migration's
artifact is pending and must be linked at the prerequisite gate.

The inspected replacement source exposes this feasibility reference:

```haskell
Kafka.Consumer.setConsumerQueueIOEvent
  :: MonadIO m => KafkaConsumer -> Maybe (Fd, ByteString) -> m ()
```

`Just` registers a caller-owned nonblocking descriptor and payload; `Nothing`
disables it. Treat this as observed source evidence, not a promised signature for
the future selected release. Inspect the release actually adopted by migration,
including `pollMessage`, fatal-error reporting, and close/destruction semantics.
The effect-level operation and bracket facility remain deliberately unresolved
while blocked and must be named concretely before implementation is unblocked.

`mori://shinzui/kafka-effectful` is the current effect boundary and has no queue
notification operation in the source inspected for this plan. No dependency bound
or pin is selected here. The migration owns compatibility across the client,
stream helpers, OpenTelemetry integration, and Nix/Cabal build inputs.

The descriptor design needs the platform's nonblocking pipe and readiness APIs;
select any additional package bounds only after Mori source lookup and release
verification. Keep the existing `KafkaAdapterConfig` public fields unless the
post-migration design demonstrates a necessary API change. The one-second safety
deadline is initially an internal policy, and `pollTimeout` must not accidentally
reintroduce a millisecond idle polling loop.
