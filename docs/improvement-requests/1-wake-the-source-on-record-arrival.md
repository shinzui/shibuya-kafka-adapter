---
type: Improvement Request
title: Wake the source on record arrival instead of polling on a timer
description: After the adapter migrates to rdkafka-hs, wait on queue notifications outside the consumer lock to avoid idle timer polls while preserving prompt shutdown, fatal-error detection, and delivery safety.
timestamp: 2026-10-26T23:05:51Z
generated:
  by: claude-code/claude-fable-5-1
  at: "2026-09-30T17:52:37Z"
requestId: IR-1
status: proposed
targetPlan: docs/plans/19-wake-the-source-on-record-arrival-after-the-rdkafka-hs-migration.md
origin: mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-7
dependencies: []
acceptanceCriteria:
  - id: AC-1
    statement: On the supported notification path, an empty source waits outside the consumer lock and polls again only for queue readiness or a bounded safety deadline; shutdown and local fatal-state changes interrupt the wait promptly.
    verification: The plan's Source wake tests count initial and safety-deadline polls, prove that idle timer polling is absent, and exercise shutdown and fatal-state wakeups.
  - id: AC-2
    statement: An idle consumer under the Shibuya runner uses no more process CPU than the blocking poll did before plan 18, about 0.2% of one core.
    verification: Three 60-second idle runner measurements record consumer process CPU against the migrated baseline and the historical approximately 0.2% target.
  - id: AC-3
    statement: A record produced to an idle consumer reaches the handler without the idle timer delay proposed by plan 18.
    verification: Deterministic arrival-race tests pass, and three 30-second runs at two records per second record mean latency below plan 18's historical prototype result of 17 ms.
  - id: AC-4
    statement: Existing consumer-operation serialization and delivery fencing remain; the notification path uses zero-timeout drains under the lock and waits for arrival outside it. This does not bound synchronous callbacks, seeks, or commits, or change the runtime support accepted by migration.
    verification: The migrated drain, retry, seek-serial, assignment, delivery-status, and finalization tests retain their assertions; a finalizer completes while the source is parked.
  - id: AC-5
    statement: Notification resources are released safely on shutdown, cancellation, early stream termination, and partial acquisition, without writes to closed descriptors or leaked waiters.
    verification: Deterministic lifecycle tests and live notification tests establish deregistration-before-close ordering and cleanup before consumer teardown.
reviews:
  - kind: model
    reviewer: claude-code/claude-fable-5-1
    reviewed_at: "2026-09-30T17:52:37Z"
    document_timestamp: "2026-09-30T17:52:37Z"
    scope: technical-accuracy
    outcome: commented
    provider: Anthropic
    model: claude-fable-5-1
    effort: medium
    context: Author's own check against the plan 18 prototype measurements and the librdkafka header text. Not an independent review.
---

# Wake the source on record arrival

## Where this comes from

`docs/bug-reports/7-caught-up-consumer-finalizes-about-three-records-per-second.md`
found that the source held the consumer lock while it waited inside the Kafka client
for records. The fix,
`docs/plans/18-drain-the-consumer-queue-without-blocking-under-the-consumer-lock.md`,
proposes keeping the lock and stopping waits for record arrival inside the client:
the source takes whatever is already queued and, when the queue is empty, sleeps
10 ms outside the lock before looking again. Its prototype measured about 100
wake-ups a second and 0.9% of one core per idle consumer against 0.19% before, and
introduced an idle timer delay. As of 2026-10-26 plan 18 remains unimplemented;
these are historical prototype results, not measurements of this checkout.

librdkafka can remove that price: `rd_kafka_queue_io_event_enable` writes to a file
descriptor when its queue needs serving. The original request depended on adding
that binding to `hw-kafka-client`. The replacement `mori://shinzui/rdkafka-hs`
already exposes `Kafka.Consumer.setConsumerQueueIOEvent` in the inspected source.
Its API and ownership contract must be rechecked against the release actually
adopted by the separately planned migration.

## What has to happen first

**Implementation is blocked on this repository's migration to
`mori://shinzui/rdkafka-hs`, as directed by the owner on 2026-10-26.** The migration
is separate work; this request and its target plan do not perform it. No local
migration plan was found when this request was updated. Link that artifact when
it exists and record its accepted build and behavior evidence before unblocking.
The profile's structured `dependencies` field accepts only improvement-request
URIs, so it is empty until the migration has such a request to reference. The
hard migration gate is recorded here and in the target plan; an empty structured
list does not mean this work is unblocked.

The migrated effect boundary (currently `mori://shinzui/kafka-effectful`) and all
its interpreters must expose notification registration and deregistration with
safe lifetime ownership. The nonblocking drain foundation from plan 18, or an
equivalent validated migrated implementation, must exist first. The target plan
requires rechecking callback modes, runtime support, and teardown against the
selected release. Upstream API availability alone is not migration completion.

The replacement implementation is recorded at
`mori://shinzui/rdkafka-hs/plans/4-expose-queue-event-notification-for-consumers`;
its ownership contract is
`mori://shinzui/rdkafka-hs/okf/adrs/concepts/ADR-1`.

The catalog entry `hw-kafka-client-no-queue-event-binding` in
`mori/upstream-issues.dhall` records the historical gap from the dependency side.
Reconcile it when migration and feature acceptance actually resolve that gap.

## What changes here when both exist

The source retains the migrated zero-timeout drain and consumer lock. It clears
pending notification bytes before draining, then waits outside the lock only
after proving the queue empty. A full batch must continue draining without
waiting. An arrival after the last empty poll leaves the descriptor readable;
do not clear that fresh notification before waiting.

Registration and deregistration need exception-safe ownership within the live
consumer scope. Disable notifications before closing descriptors and coordinate
cleanup with source cancellation and consumer teardown. Waits must be interrupted
by shutdown and local fatal state and bounded to detect native fatal errors that
do not notify the watched queue. Preserve the runtime support accepted by the
migration; the old non-threaded batch workaround is not an assumed requirement
for the replacement client.

The target ExecPlan is
[Plan 19](../plans/19-wake-the-source-on-record-arrival-after-the-rdkafka-hs-migration.md).
It records the blocking gate, three implementation milestones, race/lifecycle
tests, and fresh CPU/latency acceptance. No implementation has started.
