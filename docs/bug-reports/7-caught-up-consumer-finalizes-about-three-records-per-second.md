---
type: Bug Report
title: Caught-up consumer finalizes about three records per second
description: Under the Shibuya runner every offset store waits about 0.3 seconds for the consumer lock held by an idle poll, so a consumer that has caught up handles roughly three records per second.
generated:
  by: claude-code/claude-fable-5-1
  at: "2026-09-30T17:55:11Z"
bugId: BUG-7
status: confirmed
severity: degraded
origin: mori://shinzui/shibuya-kafka-adapter
affects: mori://shinzui/shibuya-kafka-adapter
capability: mori://shinzui/shibuya-kafka-adapter/okf/capabilities/concepts/CAP-1
affectedVersion: "0.9.1.0"
environment: Shared local Redpanda 26.2.1 at 127.0.0.1:9092; macOS aarch64; GHC 9.12.4; shibuya-kafka-adapter 0.9.1.0 with shibuya-core 0.10.0.0, kafka-effectful 0.3.1.0, hw-kafka-streamly 0.2.0.0, and hw-kafka-client 5.3.0 from Hackage.
observed: >-
  Fifty records on one partition, no retries, a handler that returns AckOk
  immediately, driven through kafkaAdapter and a serial runApp processor, take
  15.1 seconds between the first and the last handler call, about 3.2 records
  per second. Timing the adapter's consumer lock shows each poll holding it for
  a mean of 308.9 ms and each storeOffsetMessage waiting a mean of 308.9 ms to
  acquire it, while the store itself takes under 0.1 ms. With arrivals at 20
  records per second the mean time from produce to handler is 4.6 seconds; at
  100 per second it is 1.6 seconds.
expected: >-
  Finalizing a record should cost about as long as the offset store itself.
  The adapter's own documentation of consumerLock and maxPollHoldMillis in
  Shibuya.Adapter.Kafka.Internal says each poll is bounded so that the lock is
  released roughly every 100 ms and finalize is never starved. A consumer that
  has caught up should keep pace with a trivial handler instead of queueing
  records in the inbox.
reproduction:
  - Create the example topic with `rpk topic create orders -p 1` and start the repository's basic example with `nix develop -c bash -c "cabal run basic-consumer"`. At the time of filing the example package only builds with `--constraint='crypton <2.1.3'` added, because crypton 2.1.3 fails to compile; that is unrelated to this defect.
  - Wait until `rpk group describe basic-consumer-group` shows `STATE Stable` with lag 0.
  - Produce fifty records at once with `seq 1 50 | rpk topic produce orders`.
  - Run `rpk group describe basic-consumer-group` every two seconds. The committed offset advances by about sixteen records per five-second auto-commit interval and lag reaches 0 only after about eighteen seconds, although the handler only prints two lines per record. On 2026-09-30 the sampled committed offsets were 150, 161, 177, 193, and 200 over eighteen seconds.
  - Before repeating, run `rpk group describe basic-consumer-group` and wait for `STATE Empty`. A consumer that was killed stays in the group as a dead member for about a minute and delays the next run's assignment.
workaround: None removes the delay. Lowering `pollTimeout` to 1 ms raises the rate only from about 3.2 to about 4.8 records per second, because an idle batch poll in hw-kafka-client 5.3.0 takes about 206 ms plus its timeout.
reviews:
  - kind: model
    reviewer: claude-code/claude-fable-5-1
    reviewed_at: "2026-09-30T17:55:11Z"
    document_timestamp: "2026-09-30T17:55:11Z"
    scope: technical-accuracy
    outcome: commented
    provider: Anthropic
    model: claude-fable-5-1
    effort: medium
    context: Author's own check of the figures against the instrumented runs, the hw-kafka-client 5.3.0 source from Hackage, and a clean rerun of the basic-consumer reproduction. Not an independent review.
---

# Caught-up consumer finalizes about three records per second

## What happens

`Shibuya.App.runApp` runs the adapter on two threads. The ingester thread polls
the broker; the processor thread calls the handler and then finalizes the record,
which for `AckOk` means `storeOffsetMessage`. Both take `consumerLock`, a mutex in
`KafkaAdapterState` that serializes every call on the shared consumer handle.

When the ingester is ahead of the handler it polls again immediately and holds the
lock for the whole blocking poll. The processor's next store queues behind that
poll. The lock is fair, so the store runs when the poll ends, and the ingester
immediately starts the next poll. The result is one store per poll.

An instrumented build of the unchanged 0.9.1.0 source measured this directly, with
fifty records and no retries.

```text
poll-hold   n=54  mean=308.9ms  max=315.1ms
store-wait  n=50  mean=308.9ms  max=315.1ms
store-hold  n=50  mean=  0.0ms  max=  0.1ms
handler span for 50 deliveries = 15.14s (3.2 records/s)
```

## Why the poll takes 309 ms and not 100 ms

`maxPollHoldMillis` caps the adapter's poll timeout at 100 ms. The time the lock
is actually held is longer because of how `hw-kafka-client` 5.3.0 implements
`pollMessageBatch`. That library runs a background loop that calls
`rd_kafka_consumer_poll` with a 100 ms timeout while holding an internal lock
(`kcfgCallbackPollStatus`). `pollMessageBatch` takes that same lock twice, once in
`pollConsumerEvents` and once around the batch consume, and each time it queues
behind one 100 ms background poll. An idle batch poll on a bare consumer, with no
adapter involved, measured as follows.

```text
pollMessageBatch timeout=0ms    mean=206.3ms
pollMessageBatch timeout=10ms   mean=218.7ms
pollMessageBatch timeout=100ms  mean=316.5ms
```

So lowering the adapter's `pollTimeout` cannot bring the lock hold below about
206 ms. With `pollTimeout` at 1 ms the same fifty records still took 10.2 seconds.

## What it costs

When the consumer has a backlog the ingester spends its time blocked on a full
inbox rather than polling, and stores run without waiting. A backlog of 2000
records went through at about 485 records per second for the first 1900, and then
the last 100 took about 31 seconds.

With steady arrivals faster than about three per second the inbox fills and stays
full, and the time a record waits is roughly the inbox size divided by the arrival
rate.

```text
 2 records/s  mean latency  166 ms   worst   309 ms
20 records/s  mean latency  4.6 s    worst  23.7 s
100 records/s mean latency  1.6 s    worst  31.1 s
```

Each figure is one thirty-second run on the environment above.

The verification suite `mori://shinzui/keiro-runtime-kenshou` had already recorded
the symptom without a cause: its pipeline benchmark measured 10.9 records per second
through the runner against 525 through a raw poll (run
`01a0d671-03cb-7047-b6c3-1efe2bf257c9`, described in `docs/layers/kafka.md` of that
project; an artifact-level Mori URI for run directories is pending).

## Scope and history

The lock and the poll cap were introduced together in 0.8.0.0 to stop a native
crash in `rd_kafka_consume_batch_queue` under concurrent consumer access. The
behaviour reported here follows from that design and is present in every release
since; only 0.9.1.0 was measured.

Storing offsets without the lock is not the remedy. It removed the delay in an
experiment, but the investigation that added the lock recorded the crash with a
handler that only returned `AckOk`, so the lock stays.

## Proposed fix

`docs/plans/18-drain-the-consumer-queue-without-blocking-under-the-consumer-lock.md`
keeps the lock and changes what happens under it: the source takes whatever is
already in the local queue with zero-timeout single-record polls and waits outside
the lock when the queue is empty. A prototype of that change handled the same fifty
records in under a millisecond, brought mean latency at 20 records per second from
4.6 seconds to 51 ms, and passed the existing 53 tests.

The idle timer that fix leaves behind, about 100 wake-ups a second, is tracked as
this repository's improvement request
`docs/improvement-requests/1-wake-the-source-on-record-arrival.md`. It depends on the
maintained fork of `hw-kafka-client` exposing librdkafka's queue event notification,
requested there as
`mori://shinzui/hw-kafka-client/okf/improvement-requests/concepts/IR-1`, and it is
recorded from the dependency side as
`mori://shinzui/shibuya-kafka-adapter/upstream-issues/hw-kafka-client-no-queue-event-binding`.
