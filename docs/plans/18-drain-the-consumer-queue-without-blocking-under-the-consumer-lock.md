---
id: 18
slug: drain-the-consumer-queue-without-blocking-under-the-consumer-lock
title: "Drain the consumer queue without blocking under the consumer lock"
kind: exec-plan
created_at: 2026-09-30T16:58:46Z
intention: "intention_01m3sm1x24eatrd12wr30hxqkx"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T16:58:46Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-26T19:05:50Z
      verdict: "changes-requested"
      note: "Initial review: tighten timeout and finalization checks, qualify runtime and callback guarantees, correct commit timing and stale build workaround."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-26T19:10:31Z
      verdict: "approved"
      note: "Re-review after update: source-grounded drain design, runtime caveats, completion-sensitive tests, and document checks are consistent; live acceptance remains an implementation obligation."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-26T19:09:46Z
      mode: "update"
      note: "Correct runtime and callback guarantees, require successful finalization and cleanup in tests, strengthen drain lifecycle coverage, and refresh build and commit-visibility guidance."
---

# Drain the consumer queue without blocking under the consumer lock


This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


An application that consumes Kafka through `shibuya-kafka-adapter` and the Shibuya
runner currently handles about three records per second once it has caught up with
its topic, no matter how fast its handler is. Fifty records with a handler that
returns immediately take fifteen seconds. At twenty arriving records per second the
average record waits 4.6 seconds before its handler runs. This is recorded as BUG-7
in
`docs/bug-reports/7-caught-up-consumer-finalizes-about-three-records-per-second.md`.

The cause is that the adapter serializes every call on the Kafka consumer behind one
lock, and the thread that polls for records holds that lock while it waits inside the
client library for records to arrive. Marking a record as done needs the same lock, so
each record waits for one whole poll, about 0.3 seconds.

After this plan the existing consumer-lock boundaries remain. On the threaded
runtime, the source requests records with a zero timeout, releases the lock, and
waits outside the lock when it gets no records. The non-threaded runtime retains
its existing blocking batch poll. Zero timeout removes waiting for record arrival;
it is not a wall-clock bound on decoding records, running synchronous callbacks,
or other consumer operations such as seek and commit. The planning prototype
handled the same fifty records in well under a second and measured about 50 ms mean
latency at twenty records per second; implementation must re-measure these results.

You can see it working with two new broker-free tests that fail on the current code
and pass afterwards, a live test against Redpanda, and the reproduction in the bug
report: after producing fifty records to a caught-up example consumer, the group's lag
returns to zero promptly after finalization instead of eighteen seconds later.


## Progress


- [ ] Milestone 1: broker-free characterization tests demonstrate the defect, and
  the non-threaded direct-stream compatibility test passes on unchanged code.
- [ ] Milestone 2: the drain and idle wait pass latency, ordering, error, shutdown,
  callback-mode, and non-threaded compatibility tests.
- [ ] Milestone 3: ten threaded suite runs and both runtime suites pass; all packages
  build; BUG-7 reproduction and idle CPU meet the measured acceptance criteria.
- [ ] Milestone 4: documentation, ADR, CAP-1, BUG-7, changelog, and upstream issue
  agree with the verified runtime behavior and their validation commands pass.

Review handoff (2026-10-26): this is a plan-only revision. No implementation
milestone is complete. The September figures below are historical prototype evidence,
not measurements of this checkout. The review's broker metadata request timed out,
so live acceptance must be performed during implementation.


## Surprises & Discoveries


- 2026-09-30 (planning): timing the consumer lock in an instrumented build of the
  unchanged 0.9.1.0 source showed the whole delay is lock waiting. Fifty records, no
  retries, serial `runApp` processor, shared Redpanda broker.

  ```text
  poll-hold   n=54  mean=308.9ms  max=315.1ms
  store-wait  n=50  mean=308.9ms  max=315.1ms
  store-hold  n=50  mean=  0.0ms  max=  0.1ms
  handler span for 50 deliveries = 15.14s (3.2 records/s)
  ```

- 2026-09-30 (planning): the lock is held for about 309 ms although the adapter caps
  its poll timeout at 100 ms. In `hw-kafka-client` 5.3.0 an idle `pollMessageBatch`
  takes its timeout plus about 206 ms, because it queues twice behind that library's
  background callback loop, which holds an internal lock for 100 ms at a time. An idle
  batch poll on a bare consumer measured 206 ms, 219 ms, and 316 ms for timeouts of 0,
  10, and 100 ms. Lowering the adapter's `pollTimeout` therefore cannot fix this; at
  1 ms the fifty records still took 10.2 seconds. Single-record `pollMessage` does not
  take that internal lock.

- 2026-09-30 (planning): the design in this plan was prototyped in a scratch copy of
  the current source. Each latency figure is one thirty-second run.

  ```text
  workload                      unchanged     prototype
  50 caught-up records          15.1 s        under 1 ms
  2000-record backlog           34.5 s        0.01 s
  2 records/s, mean latency     166 ms        17 ms
  20 records/s, mean latency    4.6 s         51 ms
  100 records/s, mean latency   1.6 s         61 ms
  idle CPU, share of one core   0.19%         0.90% (10 ms idle wait)
  ```

  With a 50 ms idle wait the prototype's idle CPU was 0.31% and mean latency at 20
  records per second was 25 ms. With 1 ms it was 3.6% and 8 ms. The 53 existing tests
  passed in three consecutive runs with the prototype, and in two more with the
  prototype combined with the plan 16 prototype.

- 2026-09-30 (planning): the two scripted tests in Milestone 1 printed the following.

  ```text
  unchanged: caught-up handler span=4.95s stored=50; idle polls in one second=10 with nonzero timeout=10
  prototype: caught-up handler span=0.0001s stored=50; idle polls in one second=94 with nonzero timeout=0
  ```

- 2026-09-30 (planning): a first version of the prototype crashed on the non-threaded
  GHC runtime. A program that reads the source stream directly, linked without
  `-threaded`, consumed twenty records in 0.32 seconds on the unchanged code and exited
  with signal 11 on the prototype. On that runtime `hw-kafka-client` does not start its
  background callback loop, and only `pollMessageBatch` serves the consumer's group
  events. This is why the plan keeps the existing poll path on the non-threaded
  runtime. `Shibuya.App.stopApp` already fails on that runtime with
  `registerDelay: requires -threaded`, so only direct stream users can be there.

- 2026-09-30 (planning): with `hw-kafka-client`'s synchronous callback poll mode the
  unchanged adapter fails at the first poll with
  `KafkaBadSpecification "Calling pollMessageBatch while CallbackPollMode is set to CallbackPollModeSync."`
  The prototype consumed twenty records in that mode. The change makes a configuration
  work that used to be rejected.

- 2026-09-30 (planning, historical): `cabal build all` failed while compiling
  `crypton-2.1.3`, a dependency of the example package, with
  `fatal error: 'p256/p256_verify.h' file not found`. This is a fault in that
  upstream release and has nothing to do with this work. Adding
  `--constraint='crypton <2.1.3'` avoided it for that run. Do not apply this
  historical workaround automatically: the 2026-10-26 review checked Hackage's
  version registry and upstream tags for `mori://kazu-yamamoto/crypton`: Hackage
  includes 2.2.5 and marks 2.1.3 deprecated, and upstream has `crypton-v2.2.5`. The local cached build plan selects 2.1.2; that is not evidence
  that a fresh unconstrained build still needs the old workaround.

- 2026-10-26 (review): the two proposed scripted test bodies discarded both the
  outer timeout and the inner Kafka error result. They could pass after shutdown
  timed out, and timing handler entry did not include the last finalizer. The
  revised tests require successful completion, successful graceful shutdown,
  exact delivery/store counts, and timing through the final successful store.

- 2026-10-26 (review): the current package is 0.10.0.0 and requires shibuya-core
  0.11.0.0. The cached solver plan selects hw-kafka-client 5.3.0 and kafka-effectful
  0.3.1.0. Hackage and upstream tag `v5.3.0` agree on the released client version.
  Dependency source confirms that asynchronous single-record polls avoid the
  callback mutex, whereas synchronous polls call `rd_kafka_consumer_poll` and
  execute callbacks inline. Runtime choice alone does not promise a short lock
  hold for arbitrary user callbacks.


## Decision Log


- Decision: keep the consumer lock around every consumer call.
  Rationale: directed by the repository owner on 2026-09-30. The lock was added in
  0.8.0.0 after a native crash in `rd_kafka_consume_batch_queue` when the polling
  thread and the finalizing thread used the consumer concurrently, recorded in
  `mori://shinzui/shibuya/plans/28-make-kafka-adapter-ack-model-safe-for-at-least-once-delivery`
  as occurring even with a handler that only returned `AckOk`. Storing offsets without
  the lock removed the delay in an experiment and did not crash in three runs, which
  is not evidence of safety.
  Date: 2026-09-30

- Decision: take records with zero-timeout single-record polls under the lock, up to
  `batchSize` per lock acquisition, and wait outside the lock when none are available.
  Rationale: this removes the idle arrival wait from the lock hold. A store can
  still wait for a bounded number of record decodes or synchronous callbacks;
  microsecond holds are a prototype observation, not an API guarantee.
  Single-record `pollMessage` avoids the roughly 206 ms that `pollMessageBatch` spent
  behind `hw-kafka-client`'s background loop, which a zero-timeout batch poll would
  still pay.
  Date: 2026-09-30

- Decision: wait 10 ms when the queue is empty, or `pollTimeout` if that is smaller,
  and never less than 1 ms.
  Rationale: measured. Ten milliseconds is the requested idle sleep, not a hard
  latency bound (scheduler and callback delays can add time). The prototype cost
  about 0.9% of one core when idle, against 0.19% before the change. The
  default `pollTimeout` of 1000 ms would be far too long a wait, so the configured
  value can only shorten the wait, not lengthen it. A floor of 1 ms prevents a
  zero timeout from becoming a busy loop.
  Date: 2026-09-30

- Decision: keep `pollMessageBatch` on the non-threaded runtime.
  Rationale: it is what serves group events there, and the drain crashed without it.
  Serving events explicitly before each drain also worked in a test, but it would
  discard records under the synchronous callback poll mode, and telling the two modes
  apart needs `hw-kafka-client` internals. Leaving that runtime on the path it has
  today changes nothing for it.
  Date: 2026-09-30

- Decision: accept that the synchronous callback poll mode now works, and test it.
  Rationale: rejecting it again would need the same internals. On the threaded
  runtime it no longer fails at the first batch poll. Its callbacks run inside
  the source's consumer-lock section; callbacks must not re-enter that lock and
  must return promptly for low latency. The non-threaded fallback continues to
  reject this mode. Test threaded synchronous consumption, including the adapter's
  rebalance helper; do not promise support for arbitrary blocking callbacks.
  Date: 2026-09-30

- Decision: do not change `hw-kafka-client` in this plan.
  Rationale: the adapter no longer depends on the slow path. The timer wait this plan
  introduces is the best the adapter can do until that library exposes librdkafka's
  queue notification; that is requested of the maintained fork as
  `mori://shinzui/hw-kafka-client/okf/improvement-requests/concepts/IR-1`, and the
  adapter-side follow-up is this repository's
  `docs/improvement-requests/1-wake-the-source-on-record-arrival.md`. Upstream
  `haskell-works/hw-kafka-client` appears unmaintained, so nothing is filed there.
  Date: 2026-09-30

- Decision: reject an adaptive idle wait that backs off while the queue stays empty.
  Rationale: it would lower idle CPU further, but it was not measured, and a fixed
  wait is easier to reason about and to test. It can be added later without changing
  any interface.
  Date: 2026-09-30

- Decision: add the changelog entry under an `Unreleased` heading and do not change
  any package version.
  Rationale: releases are cut with `agents/skills/release/SKILL.md`, which folds an
  `Unreleased` section into the version it creates.
  Date: 2026-09-30

- Decision: measure completion through finalization and keep commit visibility
  separate from handler latency. Treat the old crypton constraint as historical.
  Rationale: discarded timeout results and handler-only timing can hide a stuck
  finalizer; a periodic commit can occur before the final record is stored. Neither
  test should report success from partial progress. Registry and tag checks no longer
  justify imposing the September build workaround on every command.
  Date: 2026-10-26


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


This repository publishes one Haskell library, `shibuya-kafka-adapter`, in the
directory of the same name. Two sibling packages are listed beside it in
`cabal.project` and are not published: `shibuya-kafka-adapter-jitsurei` (runnable
examples) and `shibuya-kafka-adapter-bench` (benchmarks). The library turns a Kafka
consumer into the `Adapter` value that the Shibuya queue-processing framework
(`shibuya-core`, in `mori://shinzui/shibuya`) runs.

### Terms


A Kafka topic is split into partitions, each an ordered log of records with increasing
offsets. A consumer polls to read records. The Kafka client library used here is
librdkafka, a C library, reached through the Haskell package `hw-kafka-client` and its
effect wrapper `kafka-effectful`. librdkafka fetches records from the broker on its own
threads and keeps them in a local queue; a poll takes records from that queue and can
wait up to a timeout for one to arrive. To store an offset is to tell the client that a
record has been handled, so that its periodic commit can advance the consumer group's
position.

The runner is the part of `shibuya-core` that `Shibuya.App.runApp` starts. It uses two
threads per processor. The ingester thread pulls records from the adapter's `source`
stream and puts them in the inbox, a bounded queue of 100 entries by default. The
processor thread takes one record at a time, calls the application's handler, and then
calls the record's finalizer, which for a successful record stores its offset.

GHC programs are linked against one of two runtimes. The threaded runtime, selected
with `-threaded`, can run foreign calls without stopping other Haskell threads and is
what every executable and test suite in this repository uses. The non-threaded runtime
is the default when `-threaded` is absent. `Control.Concurrent.rtsSupportsBoundThreads`
is `True` exactly on the threaded runtime.

### The code as it is


The runtime change is confined to
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`; tests, package test
configuration, and documentation also change as described below.

`KafkaAdapterState` holds `consumerLock`, an `MVar ()` used as a mutex.
`withConsumerLock` takes and releases it around an action. Each consumer operation
from the source/finalizer paths goes through it: the poll in `kafkaSource`, the
offset store in `storeGuarded`, the seek and the pause in `finalizeAttempt`, and
the commit in the adapter's `shutdown`. This mutex does not serialize the
client's own background callback thread; preserve the existing callback and
assignment-fencing behavior described in ADR 0001.

`kafkaSource` builds the stream of records.

```haskell
kafkaSource state config =
  skipNonFatal $
    Stream.unfoldrM step ()
      & Stream.concatMap Stream.fromList
  where
    pollT = boundedLockTimeout config.pollTimeout
    step () = do
      mbFatal <- Effectful.liftIO $ readIORef state.fatalError
      case mbFatal of
        Just err -> throwError err
        Nothing -> pure ()
      isShutdown <- Effectful.liftIO $ readTVarIO state.shutdownVar
      if isShutdown
        then pure Nothing
        else do
          batch <- withConsumerLock state (pollMessageBatch pollT config.batchSize)
          pure (Just (batch, ()))
```

`boundedLockTimeout` caps a timeout at `maxPollHoldMillis`, which is 100. The comment
on `maxPollHoldMillis` says the cap "keeps the lock available roughly every
`maxPollHoldMillis` so finalize can interleave". `skipNonFatal` and `isFatal` come from
`hw-kafka-streamly`: a poll returns `Left` for timeouts and other conditions, `isFatal`
says which of those must end the stream, and `skipNonFatal` drops the rest.

`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Config.hs` defines
`KafkaAdapterConfig` with `topics`, `pollTimeout` (documented as "Timeout for each poll
call", default 1000 ms), and `batchSize` (default 100).

### Why a store waits 0.3 seconds


When the inbox has room, the ingester finishes emitting a batch and polls again at
once. With nothing to read, that poll waits inside librdkafka for its full timeout
while holding `consumerLock`. The processor finishes a handler and tries to store the
offset, which needs the lock, so it waits for the poll to return. `MVar` wakes waiters
in order, so the store runs next and then the ingester immediately starts another
poll. One record is finalized per poll.

The poll lasts about 309 ms, not 100, because of `hw-kafka-client`. In its default
mode that library starts a background thread that calls `rd_kafka_consumer_poll` with
a 100 ms timeout in a loop, to serve group events such as partition assignment, and
holds an internal lock while it does. `pollMessageBatch` takes that same internal lock
twice, and each time it waits for one background poll to finish. In asynchronous
callback mode, single-record
`pollMessage` reads the local queue directly and does not take it. In synchronous
mode it instead calls `rd_kafka_consumer_poll`, which also serves callbacks.
`kafka-effectful`
exposes the single-record poll as `pollMessageEither`, which returns the `Left` for a
timeout instead of throwing.

Dependency behavior was checked through Mori-discovered source in
`mori://shinzui/kafka-effectful`, `mori://haskell-works/hw-kafka-client`,
`mori://shinzui/hw-kafka-client`, and `mori://shinzui/shibuya`. The cached solver
uses the Hackage client release, not a fork pin. Registry metadata for a maintained
fork is not evidence that this checkout builds that fork. Recheck actual solver
inputs before interpreting live results.

### Earlier decisions that constrain this work


[`docs/adr/0001-fence-acknowledgements-by-delivery-and-assignment.md`](../adr/0001-fence-acknowledgements-by-delivery-and-assignment.md)
records how retries and stores are fenced. It is unaffected; this plan does not touch
the acknowledgement state. If plans 16 and 17 in `docs/plans/` have been implemented,
`docs/adr/` also holds their records about the source gate and delivery status; neither
concerns how the consumer is polled. No ADR covers the consumer lock. Its history is in
the commit `65139f5` ("serialize consumer access and bound poll for runApp") and in
`mori://shinzui/shibuya/plans/28-make-kafka-adapter-ack-model-safe-for-at-least-once-delivery`.

### Relation to plans 16 and 17


This plan does not depend on
`docs/plans/16-hold-replayed-successors-so-a-buffered-retry-cannot-stall-partition-commits.md`
or on plan 17, and they do not depend on it. They may be implemented in any order. Two
places overlap, and each is called out where it arises below: the shared test helper
`test/Kafka/ScriptedLog.hs`, and the body of `kafkaSource`, to which plan 16 adds a
stamp on each polled record.

### Tooling facts


Tests live in `shibuya-kafka-adapter/test` and use `tasty` with `tasty-hunit`.
`test/Main.hs` lists the test modules. Live tests talk to a broker at `127.0.0.1:9092`
through helpers in `test/Kafka/TestEnv.hs`, which create a topic and consumer group
with a random prefix per test.

Cabal must run inside the project's Nix development shell, because librdkafka comes
from it; every command is written as `nix develop -c bash -c '...'`. Live acceptance requires a
shared Redpanda cluster on the development machine. Do not assume it is reachable;
the 2026-10-26 review's metadata request timed out. Check it with
`rpk cluster info -X brokers=127.0.0.1:9092` and start it with `redpanda-up` if it is
down. `nix fmt` must be run before every commit.


## Plan of Work


### The design in one place


On the threaded runtime, one step of the source does the following.

1. Take `consumerLock`.
2. Call `pollMessageEither (Timeout 0)` repeatedly. A `Right` is a record; keep it and
   continue until `batchSize` records have been collected. A `Left` that `isFatal`
   accepts is kept and ends the drain. Any other `Left`, which includes the timeout
   returned when the queue is empty, ends the drain.
3. Release the lock.
4. If nothing was collected, sleep for the idle wait, outside the lock.

Existing adapter lock boundaries stay around poll, store, seek, pause, and
shutdown commit. This is a zero-timeout polling policy on the threaded runtime,
not a guarantee that every consumer operation or callback completes immediately.
The records still flow through `skipNonFatal` and the later stages. The fatal
slot and the shutdown flag are still checked before every step.

On the non-threaded runtime the step is what it is today: one `pollMessageBatch` with
the capped timeout under the lock, and no idle wait.

The idle wait is `max 1 (min 10 t)` milliseconds, where `t` is the configured
`pollTimeout`. The retry seek keeps using `boundedLockTimeout config.pollTimeout`.

### Milestone 1: characterize the defect and protect the non-threaded path


This milestone changes no library code. At its end the repository has the broker-free
log helper, a test suite that runs on the non-threaded runtime, and recorded evidence
that three new tests fail on the current code.

If `shibuya-kafka-adapter/test/Kafka/ScriptedLog.hs` does not exist, create it with
the content below and add `Kafka.ScriptedLog` to the `other-modules` of the
`shibuya-kafka-adapter-test` suite in
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`. Plan 16 specifies the same file
with the same content; if it is already there, leave it. The module interprets the
`KafkaConsumer` effect over an in-memory, single-partition log, so a test can drive the
real source and the real runner without a broker. It answers both the batch poll and
the single-record poll, waits for the poll's timeout when the log is drained as a real
poll does, and records the timeout of every poll. This code was compiled and run during
planning.

```haskell
-- | A broker-free 'KafkaConsumer' interpreter backed by an in-memory,
-- single-partition log that supports poll, seek, and offset store.
module Kafka.ScriptedLog
  ( ScriptedLog (..),
    newScriptedLog,
    runScriptedConsumer,
    scriptedTopic,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Int (Int64)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Kafka.Consumer (RdKafkaRespErrT (..))
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), PartitionOffset (..), SubscribedPartitions (..), Timestamp (..), TopicPartition (..))
import Kafka.Effectful.Consumer.Effect (KafkaConsumer (..))
import Kafka.Types (BatchSize (..), KafkaError (..), PartitionId (..), Timeout (..), TopicName (..))

data ScriptedLog = ScriptedLog
  { records :: ![ConsumerRecord (Maybe ByteString) (Maybe ByteString)],
    -- | Index of the next record a poll returns.
    position :: !(IORef Int),
    -- | Offsets passed to @storeOffsetMessage@, oldest first.
    stored :: !(IORef [Int64]),
    -- | Offsets passed to @seekPartitions@, oldest first.
    seeks :: !(IORef [Int64]),
    -- | Timeout in milliseconds of every poll the adapter made, oldest first.
    polls :: !(IORef [Int])
  }

scriptedTopic :: TopicName
scriptedTopic = TopicName "orders"

-- | A log holding offsets @0 .. count - 1@ on partition 0 of 'scriptedTopic'.
newScriptedLog :: Int -> IO ScriptedLog
newScriptedLog count =
  ScriptedLog (map recordAt [0 .. fromIntegral count - 1])
    <$> newIORef 0
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
  where
    recordAt offset =
      ConsumerRecord
        { crTopic = scriptedTopic,
          crPartition = PartitionId 0,
          crOffset = Offset offset,
          crTimestamp = NoTimestamp,
          crHeaders = mempty,
          crKey = Nothing,
          crValue = Just (BS8.pack (show offset))
        }

runScriptedConsumer :: (IOE :> es) => ScriptedLog -> Eff (KafkaConsumer : es) a -> Eff es a
runScriptedConsumer scripted =
  interpret $ \_env -> \case
    PollMessageBatch (Timeout millis) (BatchSize size) -> liftIO $ do
      atomicModifyIORef' scripted.polls (\done -> (done <> [millis], ()))
      batch <-
        atomicModifyIORef' scripted.position $ \current ->
          let batch = take size (drop current scripted.records)
           in (current + length batch, batch)
      -- A real poll blocks for its timeout when the partition is drained.
      if null batch then threadDelay (millis * 1000) else pure ()
      pure (map Right batch)
    SeekPartitions targets _ -> liftIO $
      forM_ targets $ \target -> case target.tpOffset of
        PartitionOffset offset -> do
          atomicModifyIORef' scripted.position (const (fromIntegral offset, ()))
          atomicModifyIORef' scripted.seeks (\done -> (done <> [offset], ()))
        other -> error ("ScriptedLog: unsupported seek target " <> show other)
    StoreOffsetMessage cr -> liftIO $ atomicModifyIORef' scripted.stored (\done -> (done <> [unOffset cr.crOffset], ()))
    Subscription -> pure [(scriptedTopic, SubscribedPartitionsAll)]
    CommitAllOffsets _ -> pure ()
    PausePartitions _ -> pure ()
    PollMessageEither (Timeout millis) -> liftIO $ do
      atomicModifyIORef' scripted.polls (\done -> (done <> [millis], ()))
      next <-
        atomicModifyIORef' scripted.position $ \current ->
          case drop current scripted.records of
            record : _ -> (current + 1, Just record)
            [] -> (current, Nothing)
      case next of
        Just record -> pure (Right record)
        Nothing -> do
          -- A real poll blocks for its timeout when the partition is drained.
          threadDelay (millis * 1000)
          pure (Left (KafkaResponseError RdKafkaRespErrTimedOut))
    PollMessage _ -> error "ScriptedLog: PollMessage not scripted"
    CommitOffsetMessage _ _ -> error "ScriptedLog: CommitOffsetMessage not scripted"
    CommitPartitionsOffsets _ _ -> error "ScriptedLog: CommitPartitionsOffsets not scripted"
    StoreOffsets _ -> error "ScriptedLog: StoreOffsets not scripted"
    Assign _ -> error "ScriptedLog: Assign not scripted"
    ResumePartitions _ -> error "ScriptedLog: ResumePartitions not scripted"
    Committed _ _ -> error "ScriptedLog: Committed not scripted"
    Position _ -> error "ScriptedLog: Position not scripted"
    Assignment -> error "ScriptedLog: Assignment not scripted"
    AskConsumerHandle -> error "ScriptedLog: AskConsumerHandle not scripted"
```

Add a second test suite that is linked without `-threaded`. In
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`, copy the
`shibuya-kafka-adapter-test` stanza to a new stanza named
`shibuya-kafka-adapter-unthreaded-test`, set `main-is: Unthreaded.hs`, reduce
`other-modules` to `Kafka.TestEnv`, and replace its `ghc-options` with `-rtsopts` only.
Create `shibuya-kafka-adapter/test/Unthreaded.hs` as a `module Main` with one
`tasty-hunit` case named `direct stream consumes on the non-threaded runtime`. It
creates a topic, produces twenty payloads with `produceMessages`, calls
`consumeN env 20 AckOk` from `Kafka.TestEnv` under a forty-second
`System.Timeout.timeout`, and asserts that twenty envelopes came back. It must also
assert `Control.Concurrent.rtsSupportsBoundThreads` is `False`, so the suite cannot
silently pass on the wrong runtime. This suite passes on the unchanged code; it exists
so that Milestone 2 cannot break that runtime unnoticed. `cabal test
shibuya-kafka-adapter` runs both suites.

Create `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourcePollTest.hs`, add it to
the threaded suite's `other-modules`, and add its `tests` to `test/Main.hs`. Its group
is named `Source poll`. Assert `rtsSupportsBoundThreads` is `True`. Use this
configuration for the two characterization cases:

```haskell
config :: KafkaAdapterConfig
config = KafkaAdapterConfig {topics = [scriptedTopic], pollTimeout = Timeout 100, batchSize = BatchSize 100}
```

Both cases use `runEff . runErrorNoCallStack @KafkaError . runScriptedConsumer
scripted . runTracingNoop`, `kafkaAdapter config`, and the real `runApp` with
`defaultAppConfig`. Unlike the original planning prototypes, assert the outer
`System.Timeout.timeout` result is `Just` and the inner effect result is `Right`.
Fail on `runApp` returning `Left`. Use `stopAppGracefully defaultShutdownConfig`
and assert its result is `True`; `stopApp` discards that result. Arrange cleanup
with `Effectful.Exception.finally` once an app handle exists so a failed assertion
or cancelled wait cannot leave the runner using an escaped interpreter or consumer.
Use a bounded STM/MVar wait whose expiry fails the test, not a polling loop that
silently returns when its counter expires. Every new direct-stream test also
needs an outer deadline whose expiry fails, including the fatal-error case.

For `caught-up source does not delay finalization (scripted log)`, use fifty
scripted records and an infinite adapter source; truncating the source at fifty
would remove the idle polls that reproduce the defect. Record handler-entry times
with `GHC.Clock.getMonotonicTime`, and decorate each source record's `AckHandle`
so it calls the original finalizer before recording successful completion. The
completion of offset 49 signals an MVar with its timestamp. Wait up to thirty
seconds for it before stopping the app; bound the whole session at sixty seconds.
Assert fifty handler calls in offset order, exactly `[0 .. 49]` in `stored`, and
less than one second from first handler entry to the successful completion of
finalizer 49. Report handler span separately as diagnostic data. Keep shared
observations atomic or publish them through STM/MVar before reading them.

Coordinate the first handler with the ingester reaching its first empty poll,
using a test-local signal in the interpreter's empty branch for both poll variants.
This ensures that finalization competes with an active idle source instead of
winning a scheduler race before ingestion begins polling again. Do not block the
poll waiting for a finalizer that needs its lock. Keep this instrumentation local
to the test or make any helper extension optional so plan 16's callers still work.
The unchanged code should fail the latency bound (historically about five seconds).
If it passes, investigate the schedule before treating the test as characterization.

For `idle source never waits inside the client (scripted log)`, use an empty log.
Wait for its first poll, take a poll-count snapshot, observe for one measured second,
and take another snapshot before shutdown. Check only polls in that interval:
all requested timeouts must be zero and the count must be between 20 and 250.
Record the actual monotonic interval alongside the count; reject a materially
stretched interval instead of counting shutdown time as idle activity. The unchanged
code historically makes about ten polls, all requesting 100 ms. This verifies
both the absence of blocking requests and the presence of the idle sleep.

Add `caught-up consumer finalizes promptly` to
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/IntegrationTest.hs`. Create a
one-partition topic and run the infinite source under `runApp`. Produce and
successfully finalize a distinct warm-up record first, establishing assignment
and an exhausted input, then produce thirty distinct measured payloads. Decorate
the source's acknowledgement handles as above to signal completion only after
the original finalizer returns. Wait for all thirty successful finalizations
before shutdown, assert the exact measured payload sequence and count, and assert
less than three seconds from first measured handler entry to last measured
finalizer completion. Follow `testHandlerExceptionRedelivery` for the live effect
stack, but retain the infinite source and use the explicit completion/error/cleanup
checks above. Bound the entire session at sixty seconds. The unchanged code's
historical handler span was about nine seconds; re-measure the stronger finalization
criterion rather than copying that figure as new evidence.

Run the three new tests on the unchanged code and paste their failing output into
Surprises & Discoveries. Commit the helper module and the non-threaded suite, which
pass. Keep the three failing tests in the working tree and commit them with the fix in
Milestone 2, so that no commit has a failing suite.

### Milestone 2: drain without blocking


All library edits are in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`. At the end of this
milestone every test passes.

Import `rtsSupportsBoundThreads` from `Control.Concurrent`, `pollMessageEither` from
`Kafka.Effectful.Consumer.Effect`, and `BatchSize (..)` from `Kafka.Types`. Keep the
import of `pollMessageBatch`; the non-threaded path still uses it.

Add the drain and the idle wait.

```haskell
-- | Take up to @size@ records that are already in the local queue, without
-- waiting for more. A fatal error is returned in place; any other error,
-- including the timeout that means the queue is empty, ends the drain.
drainQueue ::
  (KafkaConsumer :> es) =>
  Int ->
  Eff es [Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))]
drainQueue size = go size []
  where
    go remaining acc
      | remaining <= 0 = pure (reverse acc)
      | otherwise = do
          next <- pollMessageEither (Timeout 0)
          case next of
            Right cr -> go (remaining - 1) (Right cr : acc)
            Left err
              | isFatal err -> pure (reverse (Left err : acc))
              | otherwise -> pure (reverse acc)

-- | Longest time, in milliseconds, the source waits outside the consumer lock
-- before looking at the local queue again when it was empty.
maxIdleWaitMillis :: Int
maxIdleWaitMillis = 10

idleWaitMicros :: Timeout -> Int
idleWaitMicros (Timeout millis) = 1000 * max 1 (min maxIdleWaitMillis millis)
```

Change the last branch of `step` in `kafkaSource`.

```haskell
        else do
          batch <-
            if rtsSupportsBoundThreads
              then do
                drained <- withConsumerLock state (drainQueue (unBatchSize config.batchSize))
                -- Never wait inside the client while holding the consumer
                -- lock: an empty drain waits here, outside it.
                when (null drained) $
                  Effectful.liftIO (threadDelay (idleWaitMicros config.pollTimeout))
                pure drained
              else withConsumerLock state (pollMessageBatch pollT config.batchSize)
          pure (Just (batch, ()))
```

If plan 16 has already been implemented, `kafkaSource` reads `seekSerial` inside the
lock after the poll and wraps each record in `Polled`. Keep that exactly, with the
drain in place of the batch poll: drain first, then read the serial, then wrap, all in
the same `withConsumerLock` section, and do the idle wait after the section ends. The
combination was prototyped, and both of plan 16's scripted retry schedules gave the
results that plan records.

Add the following regression tests. These protect the changed source behavior;
all must have explicit deadlines and assert full successful completion.

In `SourcePollTest.hs`, `source yields every record in order across drains (scripted
log)`: a scripted log of 250 records and `batchSize = BatchSize 100`. Read
`Stream.take 250` of the adapter's `source` directly, finalize each record with
`AckOk`, and assert the envelope cursors are 0 through 249 in order and that `stored`
is `[0 .. 249]`. Also drive the internal `kafkaSource` just far enough to
obtain its first element and inspect the interpreter's consumed position: it must
be 100, not 250. This catches an implementation that drains an unbounded backlog
before yielding, which the ordering assertion alone would miss. Repeat the ordered
consumption check with `batchSize = BatchSize 1`.

In `SourcePollTest.hs`, `fatal poll error ends the stream`: a small local interpreter
of `KafkaConsumer`, in the style of `runMockConsumer` in `AckHandleTest.hs`, whose
`PollMessageEither` returns `Left KafkaBadConfiguration` and whose `Subscription`
returns an empty list. Drain the adapter's `source` under
`runErrorNoCallStack @KafkaError` and assert the result is
`Left KafkaBadConfiguration`. Add a second script returning two records,
then that fatal error, then a sentinel record. Assert the first two records were
emitted in order before failure and that no poll consumed the sentinel. Add a
nonfatal script with record, partition EOF, record, timeout; the two records must
both be emitted in order across separate drains. Do not conflate a nonfatal
condition with permanent end of stream.

In `SourcePollTest.hs`, drive an empty source in a worker, wait until a zero-timeout
poll has returned, then set `shutdownVar` and require prompt stream completion
(with a one-second scheduling allowance). Repeat with `fatalError` set to
`Just KafkaBadConfiguration` and require that error. These protect the existing
per-step checks across the new idle wait. Use `kafkaAdapterWith` and shared state,
and ensure the worker is cancelled/joined on test failure. Repeat the idle
observation with configured `Timeout 0`: all poll requests remain zero, at least
one further poll occurs, and no more than 2000 polls occur in a one-second window.
This broad bound catches a missing sleep floor without asserting exact scheduler
timing. Repeat the ordinary 20–250 poll bound with default `Timeout 1000` to catch
accidentally sleeping for the full configured second.

In `IntegrationTest.hs`, `consumes with the synchronous callback poll mode`: the same
consumer properties as the other live tests with
`<> callbackPollMode CallbackPollModeSync` appended, both names exported by
`Kafka.Effectful.Consumer` in `kafka-effectful` 0.3.1.0. Produce twenty payloads, read `Stream.take 20` of the
source, finalize each with `AckOk`, and assert the exact twenty payloads and
cursor order. Use shared state with `kafkaRebalanceHandler` installed before consumer
creation and record the assignment callback, proving callbacks are served as well
as records delivered. Append `callbackPollMode CallbackPollModeSync` last because
consumer properties are right-biased. Run this only on the threaded suite; keep
an explicit non-threaded sync-mode rejection test in `test/Unthreaded.hs`: construct
a sync consumer, pull its source under `runErrorNoCallStack`, and require
`KafkaBadSpecification` mentioning `pollMessageBatch`, not a timeout or native crash.
Callbacks must not acquire `consumerLock` recursively. A zero timeout does not constrain arbitrary
callback execution time.

Run both suites. Everything that existed before this plan, the three characterization
tests, and the regression cases above must pass. Commit the library change and the tests
together.

### Milestone 3: prove nothing regressed


Run the threaded suite ten times in a row. The change alters how the ingester and the
processor interleave, and repeated runs are the practical check that no existing test
depended on the old timing. Pay particular attention to
`actual reassignment fences a late callback from the old owner`, which exercises a real
rebalance while the source is draining, and to the retry tests. All ten runs must pass
with no crash. A crash shows as exit status 139.

Build all three packages.

Repeat the reproduction from BUG-7 with the example consumer, as shown in Concrete
Steps, and record the sampled committed offsets in Surprises & Discoveries. Lag must
reach zero promptly while the consumer remains running. A commit tick may occur
before the last offset is stored, so do not require the first tick after production
to contain the whole burst. Use the visibility deadline in Concrete Steps.

Measure idle CPU with the example consumer, as shown in Concrete Steps. It must be
under 1.5 seconds of CPU per minute. The prototype used about 0.54.

### Milestone 4: documentation and records


In `Shibuya.Adapter.Kafka.Internal`, rewrite three comments so they describe the code.
The comment on `consumerLock` says each poll is bounded so the lock is released
frequently; say instead that threaded source polls request zero timeout and take at most
`batchSize` records while holding it. Mention the non-threaded fallback and that
synchronous callbacks execute inline under the lock. The comment on
`maxPollHoldMillis` describes capping the poll; it now
bounds only the retry seek on the threaded runtime, and the poll too on the
non-threaded one. The haddock on `kafkaSource` should describe the drain, the idle
wait, and the non-threaded fallback.

In `Shibuya.Adapter.Kafka.Config`, change the documentation of `pollTimeout` to say
that it bounds the retry seek, capped at 100 ms, and how long the source waits before
looking for records again when none are queued on the threaded runtime, capped
at 10 ms and never below 1 ms. On the non-threaded runtime it remains the batch-poll
timeout capped at 100 ms; this plan does not change seek timeout normalization.
Avoid promising a wall-clock bound on a poll, seek, or callback.
Change the documentation of `batchSize` to say it is the most records taken under one
hold of the consumer lock. Update the `Defaults` list on `defaultConfig` to match.

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`, the `Message Lifecycle`
section says messages are polled in batches; add that a batch is whatever is already
queued, up to `batchSize`, on the threaded runtime. Describe the non-threaded
fallback separately and document the synchronous callback restrictions. Search
`README.md`, `shibuya-kafka-adapter/README.md`, and
`docs/capabilities/kafka-message-source.md` (CAP-1) for `pollTimeout` and correct each
statement; CAP-1 says `defaultConfig` "polls with a 1000 ms timeout". Add the new
tests to CAP-1's `evidence`, update its `generated`, add a log entry, and validate.

Add an `Unreleased` section at the top of `shibuya-kafka-adapter/CHANGELOG.md`, or
extend it if present, with a `Bug Fixes` entry for the latency fix that gives the
before and after figures, and an `Other Changes` entry stating the new meaning of
`pollTimeout`, the idle CPU cost, and that the synchronous callback poll mode now
works on the threaded runtime with prompt, non-reentrant callbacks.

Write an ADR in `docs/adr/`, numbered with the next unused four-digit number and named
`NNNN-never-wait-in-the-client-while-holding-the-consumer-lock.md`, in the plain format
of ADR 0001 (title, Status, Date, Context, Decision, Consequences, Evidence). Record
that the lock stays, that threaded source polls request zero timeout and idle waits
happen outside
it, why `pollMessageBatch` is avoided on the threaded runtime and kept on the
non-threaded one, and the idle-wait trade-off with its measurements. The review
confirmed that `mori.dhall` does not currently register `docs/adr` as a profiled
bundle; if that changes before implementation, use the profile's handle allocation
and strict validation workflow instead of assuming the current plain-file format.

In `mori/upstream-issues.dhall`, change the entry
`hw-kafka-client-no-queue-event-binding` from `IssueStatus.Active` to
`IssueStatus.Workaround` and set `workaroundPath` to
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`. Run `mori validate`
and `mori upstream-issues list` to confirm.

Mark BUG-7 fixed in
`docs/bug-reports/7-caught-up-consumer-finalizes-about-three-records-per-second.md`:
set `status: fixed`, add `fixedVersion: "unreleased"` after `affectedVersion`, add a
`resolution` naming this plan and the tests, update `generated`, and add a
`Resolution` section with the re-measured figures. Add a log entry and validate.


## Concrete Steps


All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`.

Confirm the broker is reachable.

```bash
rpk cluster info -X brokers=127.0.0.1:9092
```

Run both test suites of the library package, or one of them.

```bash
nix develop -c bash -c 'cabal test shibuya-kafka-adapter --test-show-details=streaming'
nix develop -c bash -c 'cabal test shibuya-kafka-adapter:test:shibuya-kafka-adapter-test --test-show-details=streaming'
nix develop -c bash -c 'cabal test shibuya-kafka-adapter:test:shibuya-kafka-adapter-unthreaded-test --test-show-details=streaming'
```

The September planning baseline ended as follows; record the current suite count
and result rather than treating this historical transcript as a fresh check.

```text
All 53 tests passed (10.91s)
Test suite shibuya-kafka-adapter-test: PASS
```

Run only the new group. The pattern contains a space, so each option is passed with
its own `--test-option`.

```bash
nix develop -c bash -c 'cabal test shibuya-kafka-adapter:test:shibuya-kafka-adapter-test --test-show-details=streaming --test-option=-p --test-option="/Source poll/"'
```

Run the threaded suite ten times and stop at the first failure.

```bash
nix develop -c bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do cabal test shibuya-kafka-adapter:test:shibuya-kafka-adapter-test || exit 1; done'
```

Build everything without imposing the historical crypton constraint.

```bash
nix develop -c bash -c 'cabal build all'
```

If dependency resolution or compilation fails, record the selected version and
actual error. Check the authoritative registry and upstream release tags before
choosing a workaround; do not pin an old release from the September transcript.

Repeat the BUG-7 reproduction. Start the example consumer in one terminal.

```bash
rpk topic create orders -p 1
nix develop -c bash -c 'cabal run basic-consumer'
```

In a second terminal, wait for the group to be stable with no lag, produce fifty
records, and sample the group every two seconds.

```bash
rpk group describe basic-consumer-group
seq 1 50 | rpk topic produce orders
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 2; rpk group describe basic-consumer-group | rg '^orders'; done
```

On the unchanged code the committed offset, the third column, climbed in four steps
over eighteen seconds.

```text
+4s  committed=161 log-end=200 lag=39
+10s committed=177 log-end=200 lag=23
+14s committed=193 log-end=200 lag=7
+18s committed=200 log-end=200 lag=0
```

After Milestone 2 require lag zero within two configured auto-commit intervals
plus one sampling interval after producer completion, without stopping the consumer.
With the example's default five-second commit interval and two-second sampling,
this is twelve seconds. The separate live finalization test enforces the tighter
three-second processing bound. Record the actual commit configuration with the
samples; sampled group offsets cannot prove exactly which automatic commit tick
stored the last offset. The prototype reached zero in four seconds:

```text
+2s committed=200 log-end=250 lag=50
+4s committed=250 log-end=250 lag=0
```

Before repeating the reproduction, wait until `rpk group describe
basic-consumer-group` shows `STATE Empty`. A consumer that was killed stays in the
group as a dead member for about a minute and delays the next run's assignment.

Measure idle CPU. With the example consumer running and nothing being produced, read
its accumulated CPU time twice, one minute apart.

```bash
pid=$(pgrep -f 'basic-consumer/basic-consumer$' | head -1)
ps -o cputime= -p "$pid"; sleep 60; ps -o cputime= -p "$pid"
```

The difference must be under 1.5 seconds. The prototype build used 0.36 seconds in
forty seconds. If the example was started through a wrapper such as `timeout`, the
pattern also matches the wrapper; use the process whose command is the binary itself.

Record and validate the capability and bug-report changes.

```bash
okf log add docs/capabilities --kind Update -m "CAP-1 describes the non-blocking drain and the new meaning of pollTimeout."
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf log add docs/bug-reports --kind Update -m "BUG-7 is fixed on the default branch: the source no longer waits inside the client while holding the consumer lock."
okf validate docs/bug-reports --strict --profile docs/bug-reports/profile.dhall --profile-enforce --log-enforce
```

Each `okf validate` prints a line beginning with `OK:`.

Format and commit. Stage the intended source, test, and documentation paths for
the milestone explicitly alongside the plan; inspect `git diff --cached` before
committing. Every commit for this plan carries both trailers.

```bash
nix fmt
git add -- docs/plans/18-drain-the-consumer-queue-without-blocking-under-the-consumer-lock.md
git commit
```

```text
fix(kafka): drain the consumer queue without blocking under the lock

<body>

ExecPlan: docs/plans/18-drain-the-consumer-queue-without-blocking-under-the-consumer-lock.md
Intention: intention_01m3sm1x24eatrd12wr30hxqkx
```


## Validation and Acceptance


The plan is complete when all of the following hold.

`caught-up source does not delay finalization (scripted log)` passes: fifty records
are stored in order and first handler entry through last successful finalizer
completion takes less than one second. The unchanged baseline must fail this bound;
the historical handler-only span was about five seconds.

`idle source never waits inside the client (scripted log)` passes: in one idle second
the source makes between 20 and 250 polls and none has a non-zero timeout. With the
change reverted it makes ten, all with a 100 ms timeout.

`caught-up consumer finalizes promptly` passes against the live broker: thirty records
successfully finalized in under three seconds from first measured handler entry,
with exact counts and ordered payloads after warm-up. The unchanged baseline must
fail; the historical handler-only span was about nine seconds.

`direct stream consumes on the non-threaded runtime` passes before and after the
change.

`source yields every record in order across drains (scripted log)`,
`fatal poll error ends the stream`, and
`consumes with the synchronous callback poll mode` pass, together with the
batch-cap, mixed-error, shutdown/fatal-slot, idle-wait boundary, and non-threaded
sync-rejection cases described in Milestone 2. Every timeout, Kafka error, incomplete
count, or forced shutdown fails its test instead of being discarded.

Every test that existed before this plan passes unchanged, ten times in a row, with no
crash.

All three packages build.

The BUG-7 reproduction shows lag zero within the configured commit-visibility
deadline while the consumer is still running, and the
idle example consumer uses under 1.5 seconds of CPU per minute.

Inspect each `withConsumerLock` body in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs` and
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`: polling, store, seek, pause,
and shutdown commit retain their existing lock boundaries, while only the threaded
idle sleep is outside. A text match alone cannot prove the scope of a lock. If
plan 16 is already present, poll results and seek-serial stamping stay in the same
critical section.


## Idempotence and Recovery


Every step can be repeated. The tests create topics and groups with random prefixes and
leave them on the shared broker, as the existing suite does. The reproduction uses the
fixed `orders` topic and `basic-consumer-group` that the example has always used; extra
records left in that topic do no harm.

If a live run ends at once with an unexpected fatal Kafka error after the change, the
likely cause is an error returned by an empty single-record poll that `isFatal`
accepts. `hw-kafka-client` derives that error from the C `errno`, which is a timeout
in every case observed during planning. Record the error in Surprises & Discoveries
before changing anything.

If the threaded suite crashes with exit status 139, revert the Milestone 2 commit and
record the test that was running. Do not respond by moving any consumer call outside
the lock.

The library change is confined to one source file and can be reverted with
`git revert` of the Milestone 2 commit. The helper module and the non-threaded suite
from Milestone 1 are independent of it and may stay.

Do not release from this plan. Releasing is a separate, user-initiated step.


## Interfaces and Dependencies


No dependency is added or changed. `pollMessageEither` is already exported by
`Kafka.Effectful.Consumer.Effect` in `kafka-effectful` 0.3.1.0, the version this
package requires, and `rtsSupportsBoundThreads` is in `base`.

The public module `Shibuya.Adapter.Kafka` keeps its export list, and
`KafkaAdapterConfig` keeps its three fields and their types. Only the documented
meaning of `pollTimeout` changes.

In `Shibuya.Adapter.Kafka.Internal`, `kafkaSource` keeps its name and type, whichever
type it has when this plan starts. `drainQueue`, `maxIdleWaitMillis`, and
`idleWaitMicros` are new and internal to the module; they do not need to be exported.

```haskell
drainQueue ::
  (KafkaConsumer :> es) =>
  Int ->
  Eff es [Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))]

idleWaitMicros :: Timeout -> Int
```

The package gains a second test suite, `shibuya-kafka-adapter-unthreaded-test`.

Three consequences for users belong in the changelog and the documentation. An idle
consumer wakes about a hundred times per second instead of about three, which the
prototype measured as 0.9% of one core against 0.19%. On the threaded runtime,
a `pollTimeout` above 10 ms no
longer changes the source's requested idle wait; the retry seek still uses it, up
to 100 ms. The non-threaded batch-poll path retains its previous timeout semantics.
Synchronous callback mode now works on the threaded runtime with prompt callbacks
that do not re-enter the adapter lock; the non-threaded fallback still rejects it.

The verification suite `mori://shinzui/keiro-runtime-kenshou` measures this path with
its `kafka/pipeline/benchmark/produce-consume-throughput` and
`kafka/adapter/benchmark/poll-cap-latency` scenarios. Its recorded figures for the
runner path will change when it moves to a release containing this fix. That work
belongs to that repository.

The 206 ms that `pollMessageBatch` spends behind `hw-kafka-client`'s background loop
remains for anyone who calls it directly. It caps a bare batch consumer at roughly
`batchSize` records per 0.2 seconds. BUG-7 describes the mechanism; changing that
library is outside this plan.

The idle timer this plan introduces is tracked as
`docs/improvement-requests/1-wake-the-source-on-record-arrival.md` (IR-1), whose hard
dependency is `mori://shinzui/hw-kafka-client/okf/improvement-requests/concepts/IR-1`,
the request for a binding to librdkafka's queue event notification in the maintained
fork. The same gap is recorded from the dependency side as
`mori://shinzui/shibuya-kafka-adapter/upstream-issues/hw-kafka-client-no-queue-event-binding`.


Revision note (2026-10-26): reviewed against current adapter and dependency source,
ADR 0001, registry releases, and upstream tags. Tightened runtime/callback guarantees,
replaced the test prototypes' discarded-result checks with completion/finalization
checks, added drain/error/idle lifecycle coverage, separated commit visibility from
processing latency, and removed the automatic historical crypton constraint. The
drain algorithm and preserved consumer-lock boundaries are unchanged.
