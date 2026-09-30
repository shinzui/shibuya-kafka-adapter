---
id: 16
slug: hold-replayed-successors-so-a-buffered-retry-cannot-stall-partition-commits
title: "Hold replayed successors so a buffered retry cannot stall partition commits"
kind: exec-plan
created_at: 2026-09-30T14:44:59Z
intention: "intention_01m3sbterne78sx93pm5d6qf66"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T14:44:59Z
---

# Hold replayed successors so a buffered retry cannot stall partition commits

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

An application that consumes Kafka through `shibuya-kafka-adapter` and the Shibuya
runner can ask for a record to be delivered again by returning `AckRetry` from its
handler. Today, when that happens while later records of the same partition are
already waiting to be handled, the consumer group stops advancing. Every record is
eventually handled successfully, yet the group's committed position stays just past
the retried record for the rest of the session, including after a graceful shutdown.
The missing progress only appears after a restart, which handles the same records a
second time. This is recorded as BUG-1 in
`docs/bug-reports/1-buffered-retry-leaves-acknowledged-successors-uncommitted.md`.

After this plan, the same session commits all the way to the end of the log. A
retried record is delivered again, and the records after it are delivered again
behind it and committed, with no restart.

You can see it working in two ways. A new broker-free test drives the real adapter
and the real Shibuya runner over an in-memory log of twelve records, retries offset 4
once, and checks that offsets 0 through 11 are all stored; it fails on the current
code with only offsets 0 through 4 stored. A new live-broker test does the same
against Redpanda and checks that a second consumer in the same group receives
nothing.

This plan deliberately does not change the order in which handlers run. Records that
were already waiting when the retry was requested still run once before the retried
record is delivered again. That is BUG-2, and it is fixed by the follow-up plan
`docs/plans/17-skip-superseded-buffered-deliveries-so-successors-cannot-run-before-a-retried-record.md`,
which builds on the mechanism introduced here.


## Progress

- [ ] Milestone 1: add the broker-free scripted log helper
  `shibuya-kafka-adapter/test/Kafka/ScriptedLog.hs` and register it in the test suite.
- [ ] Milestone 1: write the two characterization tests (broker-free and live) and
  record their failing output on the unchanged code in Surprises & Discoveries.
- [ ] Milestone 1: add the `Source gate` benchmark over the current
  `dropStaleRecords` and record its baseline numbers in this plan.
- [ ] Milestone 2: add the seek bookkeeping and wake signal to
  `Shibuya.Adapter.Kafka.Internal` (`Polled`, `seekSerial`, `retryRequests`,
  `seeksCompleted`, `seekedAt`, `halted`, `replayed`, `ackSignal`).
- [ ] Milestone 2: make `kafkaSource` stamp every polled record and replace
  `dropStaleRecords` with `gateRecords`; rewire `kafkaAdapterWith`.
- [ ] Milestone 2: add the deterministic gate tests in
  `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourceGateTest.hs`.
- [ ] Milestone 2: both characterization tests and the double-retry scripted test
  pass, and the pre-existing 53 tests still pass.
- [ ] Milestone 3: benchmark comparison against the Milestone 1 baseline recorded.
- [ ] Milestone 3: example and benchmark packages build; ten consecutive runs of the
  full suite pass.
- [ ] Milestone 4: module documentation, both README files, the CAP-2 capability
  record, and the changelog describe the new behaviour.
- [ ] Milestone 4: ADR for the source gate written; BUG-1 marked fixed.


## Surprises & Discoveries

- 2026-09-30 (planning): BUG-1 was filed against Hackage 0.9.0.1. It still reproduces
  on 0.9.1.0 and on the current source, which has no code change since the `v0.9.1.0`
  tag. Fifty records on one partition, one `AckRetry` at offset 20, driven through
  `kafkaAdapter` and a serial `runApp` processor against the shared Redpanda broker,
  gave the same result in three runs out of three on both versions.

  ```text
  deliveries = 0..49, then 20
  committed while live = 21, committed after shutdown = 21, log end = 50
  ```

- 2026-09-30 (planning): the design in this plan was prototyped in a scratch copy of
  the current source before the plan was written. With the prototype, the 53 existing
  tests passed, the fifty-record schedule committed offset 50 with deliveries
  `0..49, 20, 21..49`, and the ten-record double-retry schedule from BUG-5 still
  committed offset 10 with nothing skipped. The broker-free scripted test described in
  Milestone 1 printed the following on the unchanged code and on the prototype.

  ```text
  unchanged: deliveries=[0,1,2,3,4,5,6,7,8,9,10,11,4] stored=[0,1,2,3,4] seeks=[4]
  prototype: deliveries=[0,1,2,3,4,5,6,7,8,9,10,11,4,5,6,7,8,9,10,11] stored=[0,1,2,3,4,5,6,7,8,9,10,11] seeks=[4]
  ```

- 2026-09-30 (planning): a caught-up consumer finalizes slowly, independent of this
  bug. Fifty records with no retry at all took 15.1 seconds between the first and last
  handler call on the unchanged code, about 0.3 seconds per record, and the prototype
  measured the same. Instrumenting the consumer lock showed why: every offset store
  waits for the lock while the ingester's idle poll holds it, and an idle
  `pollMessageBatch` in `hw-kafka-client` 5.3.0 takes its timeout plus about 206
  milliseconds. It is recorded as BUG-7 and fixed by
  `docs/plans/18-drain-the-consumer-queue-without-blocking-under-the-consumer-lock.md`,
  not here. It matters to this plan only because, until plan 18 is implemented, live
  tests must allow that much time per record.


## Decision Log

- Decision: fix the stall by holding replayed successors at the source until the
  retried record is resolved, instead of dropping them.
  Rationale: the current filter drops every record above a pending retry barrier. That
  is right for records polled before the seek, which the seek will deliver again, and
  wrong for records polled after it, which nothing will deliver again. Holding the
  second kind until the barrier is resolved delivers each of them exactly once more,
  adds no seek, and keeps retry loops cheap because a retried record that fails again
  discards the held successors instead of running their handlers.
  Date: 2026-09-30

- Decision: tell the two kinds of record apart with a seek serial stamped on every
  polled record, not with the barrier offset.
  Rationale: the barrier offset cannot distinguish a stale record from a replayed one
  because both lie above it. A poll and a seek both run under the adapter's consumer
  lock, so "was this record polled after the latest seek on its partition completed"
  has a definite answer, and it is the property that decides whether the record will
  be delivered again.
  Date: 2026-09-30

- Decision: reject lock-step emission, the approach proposed in
  `mori://shinzui/keiro/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter`.
  Rationale: lock-step emits the next record only after the previous one is finalized.
  A Shibuya batch processor waits for more records or for its `batchTimeout` before it
  runs its handler, so under lock-step it would receive one record per timeout, one
  record per second at the default configuration. The hold in this plan blocks only
  while a retry is pending.
  Date: 2026-09-30

- Decision: reject seeking forward again when the barrier clears.
  Rationale: a second seek per resolved retry would also recover the dropped
  successors, but it costs a fetch-queue purge and refetch on every retry and still
  needs the same stale-versus-replayed distinction to avoid delivering a successor
  twice.
  Date: 2026-09-30

- Decision: reject admitting replayed successors immediately, without holding them.
  Rationale: on its own that also fixes the stall, but a retried record that fails
  repeatedly would run the handlers of every replayed successor on every cycle, which
  multiplies load on whatever dependency is failing.
  Date: 2026-09-30

- Decision: clear the barrier with a warning when the replay starts above the barrier
  offset.
  Rationale: a hold must always have something that ends it. If the retried record has
  been removed from the log by retention or compaction, no replay of it will ever
  arrive to clear the barrier. The current code stalls silently in that case; with a
  hold it would also block other partitions. The record can no longer be delivered, so
  the obligation to redeliver it is void.
  Date: 2026-09-30

- Decision: leave three existing behaviours alone: the redundant second seek when an
  already-buffered successor also asks for a retry, the emission of records polled
  before a rebalance, and the slow finalize of a caught-up consumer.
  Rationale: none of them causes BUG-1. Each changes an already-tested contract or
  belongs to another report (BUG-4, BUG-6), and widening this change raises the risk
  of regressions.
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
directory of the same name. Two sibling packages ride along and are not published:
`shibuya-kafka-adapter-jitsurei` holds runnable examples and
`shibuya-kafka-adapter-bench` holds benchmarks. All three are listed in
`cabal.project`. The library is an adapter: it turns a Kafka consumer into the
`Adapter` value that the Shibuya queue-processing framework (`shibuya-core`, a separate
repository, `mori://shinzui/shibuya`) knows how to run.

### Kafka terms used in this plan

A Kafka topic is split into partitions. Each partition is an ordered log, and each
record in it has an offset, a number that increases by one per record. A consumer
reads a partition by polling, which returns a batch of records starting at the
consumer's current position. A consumer group remembers, per partition, a committed
offset: the position a new consumer in that group starts from. This adapter runs the
consumer with automatic offset storing turned off. It calls `storeOffsetMessage` for a
record once its handler has succeeded, and the client library (librdkafka) periodically
commits the highest stored offset plus one. To seek is to move the consumer's position
for one partition, so the next poll returns records from the chosen offset again.

### Shibuya terms used in this plan

A handler is the application function that processes one message and returns an
`AckDecision`: `AckOk` (done), `AckRetry` (deliver it again), `AckDeadLetter` (give up
on it), or `AckHalt` (stop). The runner started by `Shibuya.App.runApp` uses two
threads per processor. The ingester thread pulls records from the adapter's `source`
stream and puts them in the inbox, a bounded queue of 100 entries by default. The
processor thread takes records from the inbox one at a time, calls the handler, and
then calls the record's finalizer with the decision. The finalizer is the adapter
function that carries out the decision. Processing one record at a time is called
serial processing, and it is the only mode this adapter supports.

### How the adapter is put together today

`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` is the public module. Its
`kafkaAdapterWith` builds the source stream from three stages defined in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`.

```haskell
let messageSource =
      ingestedStream (mkIngested state config) $
        dropStaleRecords state $
          kafkaSource state config
```

`kafkaSource` polls the broker in a loop and flattens each batch into single records.
Every consumer call takes `consumerLock`, a mutex in `KafkaAdapterState`, because the
ingester thread polls and the processor thread stores and seeks on the same client
handle. Each poll is capped at 100 milliseconds so the lock is released often.
`dropStaleRecords` decides, one record at a time and only when the next stage asks for
a record, whether to let it through. `ingestedStream` wraps each surviving record with
`mkIngested`, which registers the delivery and builds its finalizer.

Registration gives every delivery a delivery token, a number that increases by one for
each record the adapter hands out in this process. The finalizer for `AckRetry` calls
`recordRetry`, which records a retry barrier for the partition, and then seeks the
partition back to the barrier offset. A retry barrier is the pair of the earliest
offset still waiting to be redelivered and the token of the delivery that asked for
the retry. While a barrier exists, `claimStore` refuses to store any offset above it,
and only a delivery of the barrier offset with a newer token clears it. This is the
design recorded in
[`docs/adr/0001-fence-acknowledgements-by-delivery-and-assignment.md`](../adr/0001-fence-acknowledgements-by-delivery-and-assignment.md),
which is the only ADR in this repository and is directly relevant: it establishes the
barrier and the tokens that this plan extends. It was implemented by
`mori://shinzui/shibuya/plans/40-prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries`.

`dropStaleRecords` currently reads as follows.

```haskell
dropStaleRecords state =
  Stream.filterM $ \case
    Left _ -> pure True
    Right cr -> do
      ackState' <- Effectful.liftIO $ readIORef state.ackState
      let partitionState = Map.findWithDefault initialPartitionAckState (partitionKey cr) ackState'.partitions
      pure $
        partitionState.assigned && case partitionState.barrier of
          Nothing -> True
          Just retryBarrier -> cr.crOffset <= retryBarrier.offset
```

### The defect

Take one partition holding offsets 0 through 49 and a handler that returns `AckRetry`
the first time it sees offset 20.

1. One poll returns all fifty records. The ingester puts all of them in the inbox.
2. The processor handles 0 through 19 and stores each. It handles 20, gets `AckRetry`,
   records a barrier at 20, and seeks the partition back to 20.
3. The ingester's next poll returns 20 through 49 again. It passes 20 through the
   filter. It then evaluates 21 through 49 while the barrier at 20 is still set,
   because the processor has not reached the second delivery of 20 yet. All
   twenty-nine are dropped.
4. Meanwhile the processor works through the first deliveries of 21 through 49 that
   were already in the inbox. Their handlers run and return `AckOk`, and `claimStore`
   refuses to store them because they are above the barrier.
5. The processor reaches the second delivery of 20. It succeeds, the barrier clears,
   and offset 20 is stored, so the group commits 21.
6. The consumer's position is now 50. Nothing seeks back to 21. The group stays at 21.

Step 3 is the defect. Records polled before the seek are correctly dropped, because
the seek delivers them again. Records polled after the seek are the redelivery, and
dropping them loses it.

A note from the plan that built the barrier shows the behaviour was noticed and
misread as intended: a live test "correctly blocked after the first replay because the
repaired barrier must filter its successor until that replay succeeds". Filtering
until the replay succeeds is the right intent. The implementation discards instead of
waiting.

### Test and tooling facts you will need

Tests live in `shibuya-kafka-adapter/test` and use `tasty` with `tasty-hunit`.
`test/Main.hs` lists the test modules.
`test/Shibuya/Adapter/Kafka/AckHandleTest.hs` has broker-free tests built on a mock
`KafkaConsumer` interpreter that records store, seek, and pause calls but cannot poll.
`test/Shibuya/Adapter/Kafka/IntegrationTest.hs` has live tests against a broker at
`127.0.0.1:9092`, using helpers in `test/Kafka/TestEnv.hs` that create a topic and a
consumer group with a random prefix per test.

Cabal must run inside the project's Nix development shell, because the Kafka client
library is provided there. A bare `cabal build` fails with
`ld: library not found for -lrdkafka`. Every command in this plan is therefore written
as `nix develop -c bash -c '...'`.

The broker is a shared Redpanda cluster that is already running on the development
machine; this repository does not start one. Check it with
`rpk cluster info -X brokers=127.0.0.1:9092`. If it is down, start it with
`redpanda-up`.

`nix fmt` must be run before every commit (see `CLAUDE.md`).


## Plan of Work

The change introduces a source gate: the stage that decides, for each polled record,
whether to emit it, drop it, or hold it. It replaces `dropStaleRecords`.

### The design in one place

The gate needs two facts that the current filter does not have.

The first is whether a record was polled before or after the latest seek on its
partition. The adapter keeps a global counter, the seek serial, that increases by one
every time a retry seek completes. Each partition remembers the serial of its own
latest completed seek (`seekedAt`). Every poll reads the current serial while it still
holds the consumer lock and stamps it on each record it returns. A seek also runs
under the consumer lock, so a record whose stamp is at least its partition's
`seekedAt` was polled after that seek, and a record with a smaller stamp was polled
before it. Records of other partitions are unaffected, because their `seekedAt` did
not change.

The second is whether a seek has been requested and has not finished. Each partition
counts accepted retry requests (`retryRequests`) and remembers the request number of
the latest seek that completed (`seeksCompleted`). When the two differ, a seek is on
its way and everything not yet emitted for that partition will be delivered again.

A record is fresh when its partition is assigned, no seek is outstanding, and its
stamp is at least `seekedAt`. The gate then applies these rules.

1. A record that is not fresh is dropped. The seek that made it stale delivers it
   again.
2. A fresh record with no barrier on its partition is emitted.
3. A fresh record at the barrier offset is emitted, and the barrier is marked
   `replayed`. This is the redelivery of the retried record.
4. A fresh record above the barrier is held while the barrier is `replayed`. The gate
   waits until the partition's state changes and then decides again from the start.
5. A fresh record above a barrier that is not `replayed` means the replay skipped the
   barrier offset, so the retried record is no longer in the log. The gate clears the
   barrier, writes a warning to standard error, and emits the record.
6. A fresh record above the barrier of a partition that has been halted with
   `AckHalt` is dropped instead of held. The partition is paused and will not make
   progress.

Every hold ends. Rule 4 only applies after rule 3 has emitted the redelivery, so the
processor will reach that redelivery and finalize it. `AckOk` or `AckDeadLetter`
clears the barrier and the held record is emitted. `AckRetry` raises `retryRequests`
and the held record becomes stale and is dropped. `AckHalt` marks the partition halted
and the held record is dropped. A revocation unassigns the partition and the held
record is dropped. Shutdown and a recorded fatal error both end the wait. The runner
always finalizes a record it has taken from the inbox, and when it stops early it
cancels the ingester thread, which interrupts the wait.

The wait uses a small signal: a `TVar Word64` named `ackSignal` in
`KafkaAdapterState` that is increased after every state change that can end a hold.
The gate reads the signal, then reads the state; if it must hold, it waits in STM
until the signal differs from the value it read or shutdown is requested. Reading the
signal first means a change that lands between the two reads is never missed. The
acknowledgement state itself stays in its `IORef`, so the per-record path for a
partition with no barrier is one `readIORef` and one map lookup, as it is today.

### Milestone 1: characterize the defect and capture a benchmark baseline

This milestone changes no library code. At its end the repository has a reusable
broker-free log, a benchmark for the stage about to change, and recorded evidence that
the two new tests fail on the current code.

If `shibuya-kafka-adapter/test/Kafka/ScriptedLog.hs` does not exist, create it with
the content below and add `Kafka.ScriptedLog` to the `other-modules` of the
`shibuya-kafka-adapter-test` suite in
`shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`. Plan 18 specifies the same file
with the same content; if it is already there, leave it. The module interprets the
`KafkaConsumer` effect over an in-memory, single-partition log. Unlike the mock in
`AckHandleTest.hs` it supports polling and seeking, which is what lets a test drive
the real source stream and the real runner without a broker. It answers both the batch
poll and the single-record poll, so it works whether or not plan 18 has changed how
the source polls. This exact code was compiled and run during planning.

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

Create `shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourceGateTest.hs`, add it to
`other-modules`, and add its `tests` to the list in `test/Main.hs`. Its test group is
named `Source gate`. Its first test case is named
`buffered retry commits every successor (scripted log)`. The body below was run during
planning as a standalone program; turn the final check into `tasty-hunit` assertions.

```haskell
testBufferedRetryCommitsSuccessors :: IO ()
testBufferedRetryCommitsSuccessors = do
  scripted <- newScriptedLog 12
  deliveries <- newIORef ([] :: [Int64])
  retried <- newIORef False
  let config = KafkaAdapterConfig {topics = [scriptedTopic], pollTimeout = Timeout 5, batchSize = BatchSize 100}
      reachedLogEnd = elem 11 <$> readIORef scripted.stored
      waitUntil :: Int -> IO Bool -> IO ()
      waitUntil n check
        | n <= 0 = pure ()
        | otherwise = do
            done <- check
            unless done (threadDelay 10000 >> waitUntil (n - 1) check)
  outcome <-
    timeout 30000000 $
      runEff . runErrorNoCallStack @KafkaError . runScriptedConsumer scripted . runTracingNoop $ do
        adapter <- kafkaAdapter config
        let handler Message {envelope} = do
              let offset = case envelope.cursor of
                    Just (CursorInt value) -> fromIntegral value
                    _ -> -1
              liftIO $ modifyIORef' deliveries (<> [offset])
              -- Let the ingester run ahead so successors are buffered before
              -- the retry decision for offset 4 is finalized.
              liftIO $ threadDelay 5000
              alreadyRetried <- liftIO $ readIORef retried
              if offset == 4 && not alreadyRetried
                then liftIO (writeIORef retried True) >> pure (AckRetry (RetryDelay 0))
                else pure AckOk
        appResult <- runApp defaultAppConfig [(ProcessorId "scripted-retry", mkProcessor adapter handler)]
        case appResult of
          Left appError -> error ("runApp failed: " <> show appError)
          Right appHandle -> do
            liftIO $ waitUntil 500 reachedLogEnd
            stopApp appHandle
  -- Assert: outcome is Just (Right ()), stored == [0 .. 11], seeks == [4],
  -- and deliveries == [0 .. 11] <> [4 .. 11].
```

The five-millisecond pause in the handler makes the failure deterministic on the
unchanged code: it guarantees the ingester has filtered the replayed successors before
the processor reaches the second delivery of offset 4. The five-millisecond
`pollTimeout` keeps the test fast, because an idle scripted poll holds the consumer
lock for its whole timeout just as a real one does.

Add a live test to `test/Shibuya/Adapter/Kafka/IntegrationTest.hs` named
`buffered retry commits every successor`. It produces twelve payloads `s-0` through
`s-11` to a one-partition topic, runs `kafkaAdapter` under `runApp` with a handler that
returns `AckRetry (RetryDelay 0)` the first time it sees `s-4` and `AckOk` otherwise,
waits until the handler has returned `AckOk` for all twelve payloads, waits a further
ten seconds, and calls `stopApp`. It then uses the existing `pollPayloads env 3` helper,
which opens a second consumer in the same group, and asserts that it returns the empty
list. Follow the shape of the existing `testHandlerExceptionRedelivery` for the effect
stack (`runEff . runError @KafkaError . runTracingNoop`, then `runKafkaConsumer`). Give
the whole test a sixty-second `timeout`. The ten-second wait is needed because a
caught-up consumer finalizes about three records per second (see Surprises &
Discoveries).

Run both tests on the unchanged code and paste the failing output into Surprises &
Discoveries. The scripted test must fail with `stored` equal to `[0,1,2,3,4]`. The live
test must fail because the second consumer receives `s-5` through `s-11`.

Add a benchmark group named `Source gate` to
`shibuya-kafka-adapter-bench/bench/Main.hs` with one benchmark named
`10k records, no barrier`. It builds ten thousand `Right` records for one partition
with increasing offsets, allocates a fresh `KafkaAdapterState`, runs
`dropStaleRecords state` over `Stream.fromList` of them, and counts the result with
`Stream.fold Fold.length`. The neighbouring `10k elements` benchmarks run their streams
directly in `IO`; this stage runs in `Eff`, so wrap the fold in `runEff` before
passing it to `nfIO`. Run it and record the mean and allocation figures in Surprises &
Discoveries.

Commit the helper module and the benchmark. Do not commit the two failing tests yet;
keep them in the working tree and commit them with the fix in Milestone 2, so that no
commit has a failing suite.

### Milestone 2: implement the source gate

All library edits are in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`, plus a one-word change
in `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`. At the end of this milestone
both characterization tests pass.

Extend the state types. `RetryBarrier` gains `replayed :: !Bool`.
`PartitionAckState` gains `retryRequests :: !Word64`, `seeksCompleted :: !Word64`,
`seekedAt :: !Word64`, and `halted :: !Bool`, all zero or `False` in
`initialPartitionAckState`. `AckState` gains `seekSerial :: !Word64`, zero in
`initialAckState`. `KafkaAdapterState` gains `ackSignal :: !(TVar Word64)`, created
with `newTVarIO 0` in `newKafkaAdapterState`. Add two new types and export `Polled`
with its fields so tests can build records.

```haskell
-- | A record together with the seek serial that was current when it was polled.
data Polled = Polled
  { pollSerial :: !Word64,
    record :: !(ConsumerRecord (Maybe ByteString) (Maybe ByteString))
  }

data Admission = Emit | EmitAfterGap !Offset | Drop | Hold
```

Add `signalAckState`, which increases `ackSignal` by one in a single STM transaction.
Call it after each of these state changes, outside the `atomicModifyIORef'` that makes
the change: `recordRetry` when it accepts a retry, `claimStore` when it clears the
barrier, `setPartitionsAssigned` always, the new `markSeekCompleted`, the new
`markHalted`, and `recordFatalError`. `claimStore` currently returns only whether to
store; have its inner modification also return whether it cleared the barrier, and
signal when it did.

Change `recordRetry` to return `Maybe (Offset, Word64)`: the seek target and the new
value of `retryRequests`. In every branch that accepts the retry, increase
`retryRequests` by one and set `replayed` to `False` on the resulting barrier,
including the branch that keeps an existing barrier unchanged, because a new seek is
about to restart the replay.

In the `AckRetry` branch of `finalizeAttempt`, mark the seek complete inside the same
consumer-lock section as the seek itself, so that no poll can run between them.

```haskell
Just (target, request) ->
  ackAttempt state $
    withConsumerLock state $ do
      seekPartitions
        [ TopicPartition
            { tpTopicName = cr.crTopic,
              tpPartition = cr.crPartition,
              tpOffset = PartitionOffset (unOffset target)
            }
        ]
        (boundedLockTimeout config.pollTimeout)
      Effectful.liftIO $ markSeekCompleted state attempt.partition request
```

`markSeekCompleted` increases `seekSerial`, sets the partition's `seekedAt` to the new
serial, and sets `seeksCompleted` to the larger of its current value and `request`.
In the `AckHalt` branch, call `markHalted`, which sets `halted` to `True`, before
pausing the partition, and only when the delivery is accepted. In
`setPartitionsAssigned`, the branch that advances the assignment generation must also
set `seeksCompleted` to the current `retryRequests` and `halted` to `False`, so that a
retry whose seek was overtaken by a rebalance does not leave the partition permanently
stale.

Change `kafkaSource` to return `Stream (Eff es) (Either KafkaError Polled)`. Inside
the consumer-lock section, after `pollMessageBatch` returns, read `seekSerial` from
`state.ackState` and wrap every `Right` record in `Polled` with that serial.
`skipNonFatal` from `hw-kafka-streamly` is polymorphic in the `Right` type and needs no
change.

If
`docs/plans/18-drain-the-consumer-queue-without-blocking-under-the-consumer-lock.md`
has already been implemented, `kafkaSource` no longer calls `pollMessageBatch` on the
threaded runtime; it calls `drainQueue` under the lock and waits outside the lock when
the drain is empty. The change here is the same in that case: read `seekSerial` after
the drain, inside the same consumer-lock section, and wrap the drained records. Do the
same on the non-threaded branch. The two changes were prototyped together and gave the
results recorded in this plan.

Replace `dropStaleRecords` with `gateRecords`, and update the export list and the use
in `kafkaAdapterWith` in `Kafka.hs`. The prototype that produced the results in
Surprises & Discoveries used the following code, under the old name.

```haskell
gateRecords ::
  (IOE :> es) =>
  KafkaAdapterState ->
  Stream (Eff es) (Either KafkaError Polled) ->
  Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))
gateRecords state =
  Stream.mapMaybeM $ \case
    Left err -> pure (Just (Left err))
    Right polled -> do
      admitted <- Effectful.liftIO $ admitRecord state polled
      pure $ if admitted then Just (Right polled.record) else Nothing

admitRecord :: KafkaAdapterState -> Polled -> IO Bool
admitRecord state polled = do
  ackState' <- readIORef state.ackState
  let partitionState = Map.findWithDefault initialPartitionAckState key ackState'.partitions
  case (partitionState.barrier, isFresh partitionState) of
    (Nothing, True) -> pure True
    _ -> wait
  where
    cr = polled.record
    key = partitionKey cr

    isFresh partitionState =
      partitionState.assigned
        && partitionState.retryRequests == partitionState.seeksCompleted
        && polled.pollSerial >= partitionState.seekedAt

    wait = do
      version <- readTVarIO state.ackSignal
      admission <- atomicModifyIORef' state.ackState decide
      case admission of
        Emit -> pure True
        EmitAfterGap missing -> do
          hPutStrLn stderr $
            "[shibuya-kafka-adapter] WARNING: retried record is no longer in the log; resuming after it: "
              <> show (cr.crTopic, cr.crPartition, missing)
          pure True
        Drop -> pure False
        Hold -> do
          mbFatal <- readIORef state.fatalError
          case mbFatal of
            Just _ -> pure False
            Nothing -> do
              stop <- atomically $ do
                isShutdown <- readTVar state.shutdownVar
                current <- readTVar state.ackSignal
                if isShutdown
                  then pure True
                  else if current /= version then pure False else retry
              if stop then pure False else wait

    decide ackState' =
      let partitionState = Map.findWithDefault initialPartitionAckState key ackState'.partitions
          update partitionState' = ackState' {partitions = Map.insert key partitionState' ackState'.partitions}
       in if not (isFresh partitionState)
            then (ackState', Drop)
            else case partitionState.barrier of
              Nothing -> (ackState', Emit)
              Just retryBarrier
                | cr.crOffset < retryBarrier.offset -> (ackState', Emit)
                | cr.crOffset == retryBarrier.offset ->
                    (update partitionState {barrier = Just retryBarrier {replayed = True}}, Emit)
                | partitionState.halted -> (ackState', Drop)
                | retryBarrier.replayed -> (ackState', Hold)
                | otherwise ->
                    ( update
                        partitionState
                          { barrier = Nothing,
                            validFromToken = max partitionState.validFromToken (DeliveryToken ackState'.nextDeliveryToken)
                          },
                      EmitAfterGap retryBarrier.offset
                    )
```

When a fatal error is recorded during a hold the gate drops the held record rather
than throwing. `kafkaSource` already checks the fatal slot before every poll and throws
it there, so the stream still ends with that error once the current batch is
exhausted.

In the gap case the barrier's `validFromToken` is raised to the next token to be
allocated. Every delivery already handed out is then rejected by `attemptIsAccepted`,
and the record being emitted, which is registered immediately afterwards, is accepted.

The existing test `source observes fatal slot before polling` in `AckHandleTest.hs`
composes `ingestedStream` directly over `kafkaSource`; insert `gateRecords state`
between them so it type-checks.

Add these deterministic cases to `SourceGateTest.hs`. Each builds a
`KafkaAdapterState`, drives the state through `mkAckHandle` finalizers using the mock
interpreter pattern from `AckHandleTest.hs` (copy `runFinalizer`, `runMockConsumer`,
`recordAt`, and `testConfig`, or move them to a shared test module), and then pulls
`Polled` records through `gateRecords state (Stream.fromList ...)`. For cases that
expect a hold, run the stream fold in an `Async` that appends each emitted offset to an
`IORef`, and assert with `System.Timeout.timeout`.

- A record polled before a retry seek is dropped: retry offset 42, then feed offsets
  43 and 44 stamped with serial 0. Nothing is emitted.
- The replay of the barrier offset is emitted and its successor is held: after the
  same retry, feed 42 and 43 stamped with serial 1. Offset 42 is emitted; 43 is not
  emitted within 200 milliseconds. Finalize a new delivery of 42 with `AckOk`; 43 is
  then emitted within one second.
- A held successor is dropped when the replay retries again: as above, but finalize
  the new delivery of 42 with `AckRetry`. The fold ends having emitted only 42.
- A held successor is released by shutdown: as above, but set `state.shutdownVar` to
  `True` instead of finalizing. The fold ends within one second having emitted only 42.
- A replay that starts above the barrier clears it: after the retry of 42, feed 45 and
  46 stamped with serial 1. Both are emitted, and a following `AckOk` for a new
  delivery of 45 stores it.
- A seek on one partition does not drop another partition's records: retry offset 42
  on partition 0, then feed partition 1 records stamped with serial 0. All are emitted.
- A held successor of a halted partition is dropped: after the replay of 42 is
  emitted, finalize it with `AckHalt`. The fold ends having emitted only 42.
- A revoked partition's records are dropped: call `kafkaRebalanceHandler` with a
  `RebalanceRevoke` for the partition and feed fresh records. Nothing is emitted.

Add one more scripted-log test,
`a record that retries twice still commits every successor (scripted log)`. It is the
first scripted test with a handler that returns `AckRetry` for offset 4 on its first
two deliveries. It shows, end to end, that the successors held behind the first
redelivery are discarded when that redelivery fails and are delivered again behind the
second one. The prototype produced these values, which the test asserts.

```text
deliveries = [0,1,2,3,4,5,6,7,8,9,10,11,4,4,5,6,7,8,9,10,11]
stored     = [0,1,2,3,4,5,6,7,8,9,10,11]
seeks      = [4,4]
```

Run the whole suite. The 53 tests that existed before this plan, the two
characterization tests, the double-retry scripted test, and the eight gate tests must
pass. Commit the library change and all tests together.

### Milestone 3: prove nothing regressed

Run the `Source gate` benchmark, now over `gateRecords` with records stamped with
serial 0, and compare it with the Milestone 1 baseline. The path for a partition with
no barrier does the same `readIORef` and map lookup as before plus two integer
comparisons and one `Polled` wrapper per record, so the mean should stay within ten
percent and allocation should rise by no more than one small constructor per record.
Record both sets of numbers in Surprises & Discoveries. If the mean regresses by more
than ten percent, stop and record the measurement in the Decision Log before choosing
between accepting it and reworking the wrapper.

Build all three packages, so that the examples and the benchmark package still
compile against the changed internal module.

Run the full test suite ten times in a row. The hold introduces a wait on the
ingester thread, and repeated runs are the practical check that no test depends on
timing that the wait changed. All ten runs must pass.

### Milestone 4: documentation and records

Update the prose that describes retry behaviour so that it matches the code. In
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs`, extend item 4 of the
`Message Lifecycle` section of the module header to say that records polled before
the seek are discarded, that records delivered again after it wait behind the retried
record until it is resolved, and that a retried record which is no longer in the log
is skipped with a warning. Update the haddock of `kafkaSource` and write one for
`gateRecords`. Make the same change to the retry paragraph in `README.md` and
`shibuya-kafka-adapter/README.md`. Both files currently differ in that paragraph; keep
each file's existing wording for the rest.

Update `docs/capabilities/offset-acknowledgement-semantics.md` (CAP-2). In the body,
add the behaviour to the paragraph that describes the recovery barrier. In the
frontmatter `evidence` list, add an entry for
`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/SourceGateTest.hs`. Set
`generated` to the model and time of the edit, then add a log entry and validate, as
shown in Concrete Steps.

Add an `Unreleased` section at the top of `shibuya-kafka-adapter/CHANGELOG.md` with a
`Bug Fixes` entry describing the fix in user terms, and an `Other Changes` entry
noting that `Shibuya.Adapter.Kafka.Internal.dropStaleRecords` is replaced by
`gateRecords` and that `kafkaSource` now yields `Polled` records.

Write an ADR in `docs/adr/`, numbered with the next unused four-digit number and
named `NNNN-hold-replayed-records-behind-a-pending-retry.md`, in the same plain format
as ADR 0001 (title, Status, Date, Context, Decision, Consequences,
Evidence). Record the decision to stamp polled records with a seek serial, to hold
replayed successors, and to clear the barrier when the retried record has left the
log, together with the rejected alternatives from this plan's Decision Log.

Mark BUG-1 fixed in
`docs/bug-reports/1-buffered-retry-leaves-acknowledged-successors-uncommitted.md`: set
`status: fixed`, add `fixedVersion: "unreleased"` after `affectedVersion`, add a
`resolution` that names this plan and the two tests, update `generated`, and add a
`Resolution` section to the body. The bug-report profile requires `fixedVersion` when
the status is `fixed` and accepts `unreleased` while the fix is only on the default
branch. Add a log entry and validate as shown in Concrete Steps.


## Concrete Steps

All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`.

Confirm the broker is reachable before any live test.

```bash
rpk cluster info -X brokers=127.0.0.1:9092
```

Run the whole test suite.

```bash
nix develop -c bash -c 'cabal test shibuya-kafka-adapter --test-show-details=streaming'
```

Before this plan the last lines are as follows.

```text
All 53 tests passed (10.91s)
Test suite shibuya-kafka-adapter-test: PASS
```

Run only the new group.

```bash
nix develop -c bash -c 'cabal test shibuya-kafka-adapter --test-show-details=streaming --test-option=-p --test-option="/Source gate/"'
```

After Milestone 2 the scripted test reports success, and the values it asserts on are
these.

```text
deliveries = [0,1,2,3,4,5,6,7,8,9,10,11,4,5,6,7,8,9,10,11]
stored     = [0,1,2,3,4,5,6,7,8,9,10,11]
seeks      = [4]
```

Run the live characterization test alone.

```bash
nix develop -c bash -c 'cabal test shibuya-kafka-adapter --test-show-details=streaming --test-option=-p --test-option="/buffered retry commits every successor/"'
```

Run the benchmark for the gate, first in Milestone 1 to write a baseline and then in
Milestone 3 to compare against it. `cabal bench` runs in the package directory, so the
CSV path is relative to `shibuya-kafka-adapter-bench`. Each option is passed with its
own `--benchmark-option` because the pattern contains a space. `+RTS -T` makes the
benchmark report allocation as well as time.

```bash
nix develop -c bash -c 'cabal bench shibuya-kafka-adapter-bench --benchmark-option=-p --benchmark-option="/Source gate/" --benchmark-option=--csv --benchmark-option=source-gate-baseline.csv --benchmark-option=+RTS --benchmark-option=-T'
nix develop -c bash -c 'cabal bench shibuya-kafka-adapter-bench --benchmark-option=-p --benchmark-option="/Source gate/" --benchmark-option=--baseline --benchmark-option=source-gate-baseline.csv --benchmark-option=--fail-if-slower --benchmark-option=10 --benchmark-option=+RTS --benchmark-option=-T'
```

Delete `shibuya-kafka-adapter-bench/source-gate-baseline.csv` when Milestone 3 is
done; it is a scratch file and must not be committed.

Build everything. At the time of writing `cabal build all` fails while compiling
`crypton-2.1.3`, a dependency of the example package, with
`fatal error: 'p256/p256_verify.h' file not found`. That is a fault in that upstream
release and unrelated to this work; the constraint below avoids it. Drop the
constraint once the plain command succeeds.

```bash
nix develop -c bash -c "cabal build all --constraint='crypton <2.1.3'"
```

Run the suite ten times and stop at the first failure.

```bash
nix develop -c bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do cabal test shibuya-kafka-adapter || exit 1; done'
```

Record and validate the capability and bug-report changes.

```bash
okf log add docs/capabilities --kind Update -m "CAP-2 describes the source gate: replayed successors wait behind a pending retry."
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf log add docs/bug-reports --kind Update -m "BUG-1 is fixed on the default branch: replayed successors are held, not dropped."
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
fix(kafka): hold replayed successors behind a pending retry

<body>

ExecPlan: docs/plans/16-hold-replayed-successors-so-a-buffered-retry-cannot-stall-partition-commits.md
Intention: intention_01m3sbterne78sx93pm5d6qf66
```


## Validation and Acceptance

The plan is complete when all of the following hold.

The scripted test `buffered retry commits every successor (scripted log)` passes. With
the library change reverted it fails with `stored` equal to `[0,1,2,3,4]`.

The live test `buffered retry commits every successor` passes: after the session
ends, a second consumer in the same group receives no records. With the library change
reverted it receives `s-5` through `s-11`.

The double-retry scripted test passes with the values shown in Milestone 2.

The eight deterministic gate tests pass. Between them they show that a stale record is
dropped, that a replayed successor waits and is then emitted, that the wait ends on a
second retry, on halt, on revocation, and on shutdown, that a vanished retried record
does not block the partition, and that a seek on one partition leaves the others
alone.

Every test that existed before this plan still passes, unchanged except for the one
line in `source observes fatal slot before polling` that inserts `gateRecords`. In
particular `later buffered retry cannot replace the earliest recovery boundary` and
`fixed-seed sequences match the earliest-unresolved reference model` still pass, which
shows that the BUG-5 fix is intact.

The `Source gate` benchmark is within ten percent of its baseline mean.

`cabal build all` succeeds and the suite passes ten times in a row.

Handler order is not part of acceptance. After this plan the scripted test shows
handlers running for offsets 5 through 11 before the second delivery of offset 4 and
again after it. That is BUG-2 and is addressed by plan 17.


## Idempotence and Recovery

Every step can be repeated. The tests create topics and consumer groups with a random
ten-character prefix, so reruns never collide; they leave those small topics on the
shared broker, as the existing suite does. The benchmark CSV is a scratch file that is
overwritten on each baseline run.

If the suite hangs after the library change, the most likely cause is a hold that
nothing ends. Every test that can hold is wrapped in a timeout, so the symptom is a
timeout failure rather than a stuck process. Check that `signalAckState` is called
after every state change listed in Milestone 2, and that it is called after the
`atomicModifyIORef'` has returned, not inside the pure function passed to it.

The library change is confined to two source files and can be reverted with
`git revert` of the Milestone 2 commit. The helper module and benchmark from
Milestone 1 are independent of it and may stay.

Do not release from this plan. Releasing is a separate, user-initiated step.


## Interfaces and Dependencies

No dependency is added or changed. The test suite already depends on `async`, `stm`,
`streamly-core`, `tasty`, and `tasty-hunit`, which are all the new tests need. The
library already depends on `stm`.

The public module `Shibuya.Adapter.Kafka` keeps its export list. `KafkaAdapterState`
is exported there without its constructor, so its new field is not a public change.

At the end of Milestone 2, `Shibuya.Adapter.Kafka.Internal` exports the following in
place of `dropStaleRecords`, and `kafkaSource` has the type shown.

```haskell
data Polled = Polled
  { pollSerial :: !Word64,
    record :: !(ConsumerRecord (Maybe ByteString) (Maybe ByteString))
  }

kafkaSource ::
  (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
  KafkaAdapterState ->
  KafkaAdapterConfig ->
  Stream (Eff es) (Either KafkaError Polled)

gateRecords ::
  (IOE :> es) =>
  KafkaAdapterState ->
  Stream (Eff es) (Either KafkaError Polled) ->
  Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))
```

`mkAckHandle`, `mkIngested`, `ingestedStream`, `newKafkaAdapterState`,
`markPartitionsAssigned`, `markPartitionsRevoked`, and `withConsumerLock` keep their
names and types.

`Shibuya.Adapter.Kafka.Internal` is documented as not part of the public API, but the
verification suite `mori://shinzui/keiro-runtime-kenshou` imports `kafkaSource`,
`dropStaleRecords`, `mkIngested`, and `mkAckHandle` from it. Its scenarios already do
not compile against 0.9.1.0, where `mkAckHandle` became effectful, and will need the
rename and the `Polled` wrapper when that suite moves to a release containing this
change. That work belongs to that repository and is not part of this plan.

Two limits of the new behaviour should be stated in the documentation written in
Milestone 4. While a replayed successor is held the ingester thread does not poll, so
records of other partitions wait too; the wait ends when the processor finalizes the
redelivered record, which is already in the inbox. With a batch processor that can
take up to one `batchTimeout`, because the batch containing the redelivered record
must first be emitted. And a consumer that pulls the source stream directly and asks
for the next record before finalizing a redelivered one will wait indefinitely; the
current code leaves that consumer waiting too, by dropping the record it is asking for.
