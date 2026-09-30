---
type: Improvement Request
title: Wake the source on record arrival instead of polling on a timer
description: Once hw-kafka-client exposes librdkafka's queue event notification, the adapter should wait on that notification while its queue is empty instead of checking the queue every 10 ms, removing the idle wake-ups and the added latency that the timer costs.
generated:
  by: claude-code/claude-fable-5-1
  at: "2026-09-30T17:52:37Z"
requestId: IR-1
status: proposed
origin: mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-7
dependencies:
  - ref: mori://shinzui/hw-kafka-client/okf/improvement-requests/concepts/IR-1
    kind: hard
    reason: The adapter cannot wait for records without a binding for rd_kafka_queue_io_event_enable applied to the queue the consumer reads from; the queue is internal to hw-kafka-client.
acceptanceCriteria:
  - id: AC-1
    statement: While the consumer has nothing to read, the source makes no polls at all; it wakes only when librdkafka signals that the queue became non-empty, or when a bounded safety timeout elapses.
    verification: The scripted-log test "idle source never waits inside the client" changes its bound so that an idle second sees at most the safety-timeout wake-ups, and passes.
  - id: AC-2
    statement: An idle consumer under the Shibuya runner uses no more process CPU than the blocking poll did before plan 18, about 0.2% of one core.
    verification: The idle CPU measurement in plan 18 is repeated with the example consumer and recorded.
  - id: AC-3
    statement: A record produced to an idle consumer reaches the handler without the up-to-10 ms timer wait that plan 18 introduced.
    verification: The 2 records per second latency measurement from BUG-7 is repeated and its mean is recorded below plan 18's 17 ms.
  - id: AC-4
    statement: Every consumer call still runs under the consumer lock, and the source still never waits inside the client while holding it.
    verification: The tests from plan 18 pass unchanged except for the idle bound in AC-1.
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
keeps the lock and stops waiting inside the client: the source takes whatever is
already queued and, when the queue is empty, sleeps 10 ms outside the lock before
looking again. That sleep is the price of having nothing to wait on. It costs about
100 wake-ups a second and 0.9% of one core per idle consumer against 0.19% before,
and adds up to 10 ms to the time a record waits on an idle consumer.

librdkafka can remove that price: `rd_kafka_queue_io_event_enable` writes to a file
descriptor whenever a queue goes from empty to non-empty. `hw-kafka-client` 5.3.0
does not bind it, and the queue the consumer reads from is internal to that library,
so the adapter cannot enable it alone.

## What has to happen first

1. The fork `mori://shinzui/hw-kafka-client` binds the function and applies it to the
   consumer's queue. That is
   `mori://shinzui/hw-kafka-client/okf/improvement-requests/concepts/IR-1`, the hard
   dependency above. It is not filed upstream; `haskell-works/hw-kafka-client` last
   pushed in October 2025 and has not answered its issue #213.
2. `mori://shinzui/kafka-effectful` exposes it as an operation of its `KafkaConsumer`
   effect, which is what this adapter programs against. No request exists there yet;
   file one once the binding's shape is settled.

The catalog entry `hw-kafka-client-no-queue-event-binding` in
`mori/upstream-issues.dhall` names the same gap from the dependency side and says
when to revisit it.

## What changes here when both exist

In `Shibuya.Adapter.Kafka.Internal`, the source keeps draining the queue under the
consumer lock exactly as plan 18 leaves it. When a drain returns nothing, instead of
`threadDelay`, the source waits on the read end of a non-blocking pipe registered
with the new operation, using `threadWaitRead` under a bounded timeout as a safety
net, then reads and discards whatever librdkafka wrote to the pipe and drains again.
The pipe is created when the adapter is built and registered once; a record that
arrives between the empty drain and the wait is not lost, because librdkafka writes
to the pipe on the empty-to-non-empty transition, which has then already happened and
left the pipe readable.

The non-threaded runtime keeps the batch poll path from plan 18, since it has no
background loop to serve group events and this change does not add one.

When the work is planned, write the ExecPlan in `docs/plans/` and record its path in
this request's `targetPlan`.
