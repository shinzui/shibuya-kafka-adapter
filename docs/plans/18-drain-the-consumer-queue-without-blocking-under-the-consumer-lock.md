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

After this plan the lock is still taken around every consumer call, exactly as today,
but the adapter never waits inside the client library while holding it. It takes
whatever records are already in the local queue, releases the lock, and waits outside
the lock when there is nothing to take. The same fifty records are handled in well
under a second, and at twenty records per second the average wait is about 50
milliseconds.

You can see it working with two new broker-free tests that fail on the current code
and pass afterwards, a live test against Redpanda, and the reproduction in the bug
report: after producing fifty records to a caught-up example consumer, the group's lag
returns to zero at the next automatic commit instead of eighteen seconds later.


## Progress

- [ ] Milestone 1: add or confirm the shared broker-free log
  `shibuya-kafka-adapter/test/Kafka/ScriptedLog.hs`.
- [ ] Milestone 1: add the non-threaded test suite and confirm it passes on the
  unchanged code.
- [ ] Milestone 1: write the two scripted source tests and the live latency test, and
  record their failing output on the unchanged code.
- [ ] Milestone 2: add `drainQueue` and the idle wait, and select the poll path by
  runtime in `kafkaSource`.
- [ ] Milestone 2: add the ordering, fatal-error, and synchronous-mode tests; the
  whole suite and the non-threaded suite pass.
- [ ] Milestone 3: ten consecutive suite runs pass; all packages build.
- [ ] Milestone 3: bug-report reproduction and idle CPU re-measured and recorded.
- [ ] Milestone 4: module documentation, configuration documentation, README files,
  the CAP-1 capability record, and the changelog updated.
- [ ] Milestone 4: ADR written; BUG-7 marked fixed; the upstream-issues entry moved
  to `Workaround`.


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

- 2026-09-30 (planning): `cabal build all` currently fails while compiling
  `crypton-2.1.3`, a dependency of the example package, with
  `fatal error: 'p256/p256_verify.h' file not found`. This is a fault in that
  upstream release and has nothing to do with this work. Adding
  `--constraint='crypton <2.1.3'` to the cabal command avoids it.


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
  Rationale: the lock is then held for microseconds, so a store never waits on a
  poll. Single-record `pollMessage` avoids the 206 ms that `pollMessageBatch` spends
  behind `hw-kafka-client`'s background loop, which a zero-timeout batch poll would
  still pay.
  Date: 2026-09-30

- Decision: wait 10 ms when the queue is empty, or `pollTimeout` if that is smaller,
  and never less than 1 ms.
  Rationale: measured. Ten milliseconds adds at most that much to the time a new
  record waits and costs about 0.9% of one core when idle, against 0.19% today. The
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
  Rationale: rejecting it again would need the same internals. It is a configuration
  that used to fail at the first poll, so nobody can be relying on the failure.
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

Everything this plan changes is in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`.

`KafkaAdapterState` holds `consumerLock`, an `MVar ()` used as a mutex.
`withConsumerLock` takes and releases it around an action. Every consumer call goes
through it: the poll in `kafkaSource`, the offset store in `storeGuarded`, the seek and
the pause in `finalizeAttempt`, and the commit in the adapter's `shutdown`.

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
twice, and each time it waits for one background poll to finish. The single-record
`pollMessage` reads the local queue directly and does not take it. `kafka-effectful`
exposes the single-record poll as `pollMessageEither`, which returns the `Left` for a
timeout instead of throwing.

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
from it; every command is written as `nix develop -c bash -c '...'`. The broker is a
shared Redpanda cluster already running on the development machine. Check it with
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

Nothing else changes. The lock is still taken for every poll, store, seek, pause, and
commit. The records still flow through `skipNonFatal` and the later stages. The fatal
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
is named `Source poll`. The two bodies below were run during planning as a standalone
program; turn each returned `Bool` into `tasty-hunit` assertions on the same values.
They share this configuration, whose 100 ms `pollTimeout` is what makes the scripted
log behave like a real idle poll on the unchanged code.

```haskell
config :: KafkaAdapterConfig
config = KafkaAdapterConfig {topics = [scriptedTopic], pollTimeout = Timeout 100, batchSize = BatchSize 100}

-- | Fifty records, trivial handler: how long between first and last handler call?
caughtUp :: IO Bool
caughtUp = do
  scripted <- newScriptedLog 50
  stamps <- newIORef ([] :: [Double])
  let reachedLogEnd = elem (49 :: Int64) <$> readIORef scripted.stored
      waitUntil :: Int -> IO Bool -> IO ()
      waitUntil n check
        | n <= 0 = pure ()
        | otherwise = do
            done <- check
            unless done (threadDelay 10000 >> waitUntil (n - 1) check)
  _ <-
    timeout 60000000 $
      runEff . runErrorNoCallStack @KafkaError . runScriptedConsumer scripted . runTracingNoop $ do
        adapter <- kafkaAdapter config
        let handler _ = do
              liftIO $ getMonotonicTime >>= \now -> modifyIORef' stamps (<> [now])
              pure AckOk
        appResult <- runApp defaultAppConfig [(ProcessorId "scripted-caught-up", mkProcessor adapter handler)]
        case appResult of
          Left appError -> error ("runApp failed: " <> show appError)
          Right appHandle -> do
            liftIO $ waitUntil 3000 reachedLogEnd
            stopApp appHandle
  times <- readIORef stamps
  storedOffsets <- readIORef scripted.stored
  let spanSeconds = case times of
        first : _ -> last times - first
        [] -> -1
  pure (storedOffsets == [0 .. 49] && spanSeconds >= 0 && spanSeconds < 1)

-- | An adapter with nothing to read: what does it ask the client to do?
idle :: IO Bool
idle = do
  scripted <- newScriptedLog 0
  _ <-
    timeout 30000000 $
      runEff . runErrorNoCallStack @KafkaError . runScriptedConsumer scripted . runTracingNoop $ do
        adapter <- kafkaAdapter config
        appResult <- runApp defaultAppConfig [(ProcessorId "scripted-idle", mkProcessor adapter (\_ -> pure AckOk))]
        case appResult of
          Left appError -> error ("runApp failed: " <> show appError)
          Right appHandle -> do
            liftIO $ threadDelay 1000000
            stopApp appHandle
  timeouts <- readIORef scripted.polls
  let blocking = filter (> 0) timeouts
  pure (null blocking && length timeouts >= 20 && length timeouts <= 250)
```

Name the cases `caught-up source does not delay finalization (scripted log)` and
`idle source never waits inside the client (scripted log)`. `getMonotonicTime` is from
`GHC.Clock`. The first case fails on the unchanged code with a span of about five
seconds, one 100 ms poll per record. The second fails with ten polls in the second,
every one with a non-zero timeout. The bounds of 20 and 250 polls per second bracket
the expected hundred: fewer means the idle wait is too long, more means it is too
short or missing.

Add a live test to `test/Shibuya/Adapter/Kafka/IntegrationTest.hs` named
`caught-up consumer finalizes promptly`. It produces thirty payloads to a
one-partition topic, runs `kafkaAdapter` under `runApp` with a handler that records
`getMonotonicTime` and returns `AckOk`, waits until thirty handler calls have been
recorded, calls `stopApp`, and asserts the time between the first and the last call is
under three seconds. Follow `testHandlerExceptionRedelivery` for the effect stack, and
wrap the session in a sixty-second `timeout`. On the unchanged code the span is about
nine seconds.

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

Add three tests.

In `SourcePollTest.hs`, `source yields every record in order across drains (scripted
log)`: a scripted log of 250 records and `batchSize = BatchSize 100`. Read
`Stream.take 250` of the adapter's `source` directly, finalize each record with
`AckOk`, and assert the envelope cursors are 0 through 249 in order and that `stored`
is `[0 .. 249]`.

In `SourcePollTest.hs`, `fatal poll error ends the stream`: a small local interpreter
of `KafkaConsumer`, in the style of `runMockConsumer` in `AckHandleTest.hs`, whose
`PollMessageEither` returns `Left KafkaBadConfiguration` and whose `Subscription`
returns an empty list. Drain the adapter's `source` under
`runErrorNoCallStack @KafkaError` and assert the result is
`Left KafkaBadConfiguration`.

In `IntegrationTest.hs`, `consumes with the synchronous callback poll mode`: the same
consumer properties as the other live tests with
`<> callbackPollMode CallbackPollModeSync` appended, both names exported by
`Kafka.Effectful.Consumer` in `kafka-effectful` 0.3.1.0. Produce twenty payloads, read `Stream.take 20` of the
source, finalize each with `AckOk`, and assert twenty were received.

Run both suites. Everything that existed before this plan, the three characterization
tests, and the three tests above must pass. Commit the library change and the tests
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
reach zero at the first automatic commit after the records are produced.

Measure idle CPU with the example consumer, as shown in Concrete Steps. It must be
under 1.5 seconds of CPU per minute. The prototype used about 0.54.

### Milestone 4: documentation and records

In `Shibuya.Adapter.Kafka.Internal`, rewrite three comments so they describe the code.
The comment on `consumerLock` says each poll is bounded so the lock is released
frequently; say instead that the source only takes records that are already queued
while holding it. The comment on `maxPollHoldMillis` describes capping the poll; it now
bounds only the retry seek on the threaded runtime, and the poll too on the
non-threaded one. The haddock on `kafkaSource` should describe the drain, the idle
wait, and the non-threaded fallback.

In `Shibuya.Adapter.Kafka.Config`, change the documentation of `pollTimeout` to say
that it bounds the retry seek, capped at 100 ms, and how long the source waits before
looking for records again when none are queued, capped at 10 ms and never below 1 ms.
Change the documentation of `batchSize` to say it is the most records taken under one
hold of the consumer lock. Update the `Defaults` list on `defaultConfig` to match.

In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`, the `Message Lifecycle`
section says messages are polled in batches; add that a batch is whatever is already
queued, up to `batchSize`. Search both README files and
`docs/capabilities/kafka-message-source.md` (CAP-1) for `pollTimeout` and correct each
statement; CAP-1 says `defaultConfig` "polls with a 1000 ms timeout". Add the new
tests to CAP-1's `evidence`, update its `generated`, add a log entry, and validate.

Add an `Unreleased` section at the top of `shibuya-kafka-adapter/CHANGELOG.md`, or
extend it if present, with a `Bug Fixes` entry for the latency fix that gives the
before and after figures, and an `Other Changes` entry stating the new meaning of
`pollTimeout`, the idle CPU cost, and that the synchronous callback poll mode now
works.

Write an ADR in `docs/adr/`, numbered with the next unused four-digit number and named
`NNNN-never-wait-in-the-client-while-holding-the-consumer-lock.md`, in the plain format
of ADR 0001 (title, Status, Date, Context, Decision, Consequences, Evidence). Record
that the lock stays, that the source must not block inside the client while holding
it, why `pollMessageBatch` is avoided on the threaded runtime and kept on the
non-threaded one, and the idle-wait trade-off with its measurements.

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

Before this plan the threaded suite ends as follows.

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

Build everything. The constraint works around the broken `crypton` release described
in Surprises & Discoveries; drop it once `cabal build all` succeeds without it.

```bash
nix develop -c bash -c "cabal build all --constraint='crypton <2.1.3'"
```

Repeat the BUG-7 reproduction. Start the example consumer in one terminal.

```bash
rpk topic create orders -p 1
nix develop -c bash -c "cabal run basic-consumer --constraint='crypton <2.1.3'"
```

In a second terminal, wait for the group to be stable with no lag, produce fifty
records, and sample the group every two seconds.

```bash
rpk group describe basic-consumer-group
seq 1 50 | rpk topic produce orders
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 2; rpk group describe basic-consumer-group | grep '^orders'; done
```

On the unchanged code the committed offset, the third column, climbed in four steps
over eighteen seconds.

```text
+4s  committed=161 log-end=200 lag=39
+10s committed=177 log-end=200 lag=23
+14s committed=193 log-end=200 lag=7
+18s committed=200 log-end=200 lag=0
```

After Milestone 2 it must reach the log end at the first automatic commit, within
about six seconds. The prototype build of the example did.

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

Format and commit. Every commit for this plan carries both trailers.

```bash
nix fmt
git add -A
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
are stored and the handler calls span less than one second. With the library change
reverted the span is about five seconds.

`idle source never waits inside the client (scripted log)` passes: in one idle second
the source makes between 20 and 250 polls and none has a non-zero timeout. With the
change reverted it makes ten, all with a 100 ms timeout.

`caught-up consumer finalizes promptly` passes against the live broker: thirty records
in under three seconds. With the change reverted it takes about nine.

`direct stream consumes on the non-threaded runtime` passes before and after the
change.

`source yields every record in order across drains (scripted log)`,
`fatal poll error ends the stream`, and
`consumes with the synchronous callback poll mode` pass.

Every test that existed before this plan passes unchanged, ten times in a row, with no
crash.

All three packages build.

The BUG-7 reproduction shows lag reaching zero at the first automatic commit, and the
idle example consumer uses under 1.5 seconds of CPU per minute.

`grep -n "withConsumerLock" shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/*.hs`
still shows the lock around the poll, the store, the seek, the pause, and the shutdown
commit. No consumer call has been moved outside it.


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
prototype measured as 0.9% of one core against 0.19%. A `pollTimeout` above 10 ms no
longer has any effect on the source; only the retry seek still uses it, up to 100 ms.
And a consumer created with the synchronous callback poll mode, which the adapter used
to reject at the first poll, now works.

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
