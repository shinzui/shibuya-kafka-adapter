module Shibuya.Adapter.Kafka.AckHandleTest (tests) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (try)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Effectful (Eff, IOE, Limit (..), Persistence (..), UnliftStrategy (..), liftIO, runEff, withEffToIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Kafka.Consumer (RdKafkaRespErrT (..))
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), PartitionOffset (..), RebalanceEvent (..), Timestamp (..), TopicPartition (..))
import Kafka.Effectful.Consumer.Effect (KafkaConsumer (..))
import Kafka.Types (BatchSize (..), KafkaError (..), PartitionId (..), Timeout (..), TopicName (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (kafkaRebalanceHandler)
import Shibuya.Adapter.Kafka.Config (KafkaAdapterConfig (..))
import Shibuya.Adapter.Kafka.Internal (KafkaAcknowledgementException (..), KafkaAdapterState (..), ingestedStream, kafkaSource, mkAckHandle, mkIngested, newKafkaAdapterState)
import Shibuya.App (ProcessorId (..), defaultAppConfig, getAppMaster, mkProcessor, runApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested)
import Shibuya.Internal.Runner.Master (ProcessorLifecycle (..), getLifecycleSnapshot)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Random (mkStdGen, randomR)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

data MockState = MockState
  { storeAttempts :: !Int,
    storedOffsets :: ![Offset],
    pauseAttempts :: !Int,
    seekCalls :: ![TopicPartition],
    seekTimeouts :: ![Timeout],
    storeBlock :: !(Maybe (MVar (), MVar ())),
    storeFailuresRemaining :: !Int,
    pauseFailuresRemaining :: !Int,
    seekFailuresRemaining :: !Int,
    storeError :: !KafkaError,
    pauseError :: !KafkaError,
    seekError :: !KafkaError
  }

tests :: TestTree
tests =
  testGroup
    "AckHandle"
    [ testCase "transient store failures retry and then succeed" testTransientStoreRetry,
      testCase "persistent transient store failure records fatal slot and throws" testPersistentStoreFailure,
      testCase "fatal store failure records fatal slot and throws after one attempt" testFatalStoreFailure,
      testCase "AckHalt pause failure records fatal slot and throws" testAckHaltPauseFailure,
      testCase "AckRetry seeks exact failed offset and does not store" testAckRetrySeeks,
      testCase "AckRetry caps the consumer-lock seek timeout" testAckRetryBoundsSeek,
      testCase "seek barrier prevents stale successor store" testBarrierSkipsSuccessorStore,
      testCase "earliest retry survives later retry and acknowledgement" testEarliestRetrySurvives,
      testCase "one delivery cannot resolve its own retry" testRetryRequiresRedelivery,
      testCase "repeated retry on one delivery is idempotent" testRepeatedRetry,
      testCase "fixed-seed sequences match the earliest-unresolved reference model" testReferenceModelSeeds,
      testCase "exhausted acknowledgement throws immediately" testPersistentStoreFailureThrows,
      testCase "revocation fences an old delivery callback" testRevocationFencesCallback,
      testCase "cancellation releases finalizer and consumer ownership" testCancellationReleasesOwnership,
      testCase "terminal acknowledgement failure reaches the core lifecycle" testTerminalFailureReachesCore,
      testCase "source observes fatal slot before polling" testSourceObservesFatalSlot
    ]

testTransientStoreRetry :: IO ()
testTransientStoreRetry = do
  mock <- newIORef defaultMockState {storeFailuresRemaining = 2}
  state <- newKafkaAdapterState
  result <- runFinalizer mock $ finalizeRecord state (recordAt 42) AckOk
  assertRight result
  final <- readIORef mock
  fatal <- readIORef state.fatalError
  assertEqual "store attempts" 3 final.storeAttempts
  assertEqual "fatal slot" Nothing fatal

testPersistentStoreFailure :: IO ()
testPersistentStoreFailure = do
  let err = KafkaResponseError RdKafkaRespErrTransport
  mock <- newIORef defaultMockState {storeFailuresRemaining = 99, storeError = err}
  state <- newKafkaAdapterState
  assertAckFailure err $ runFinalizer mock $ finalizeRecord state (recordAt 42) AckOk
  final <- readIORef mock
  fatal <- readIORef state.fatalError
  assertEqual "store attempts" 3 final.storeAttempts
  assertEqual "fatal slot" (Just err) fatal

testFatalStoreFailure :: IO ()
testFatalStoreFailure = do
  let err = KafkaBadConfiguration
  mock <- newIORef defaultMockState {storeFailuresRemaining = 99, storeError = err}
  state <- newKafkaAdapterState
  assertAckFailure err $ runFinalizer mock $ finalizeRecord state (recordAt 42) AckOk
  final <- readIORef mock
  fatal <- readIORef state.fatalError
  assertEqual "store attempts" 1 final.storeAttempts
  assertEqual "fatal slot" (Just err) fatal

testAckHaltPauseFailure :: IO ()
testAckHaltPauseFailure = do
  let err = KafkaResponseError RdKafkaRespErrTransport
  mock <- newIORef defaultMockState {pauseFailuresRemaining = 99, pauseError = err}
  state <- newKafkaAdapterState
  assertAckFailure err $ runFinalizer mock $ finalizeRecord state (recordAt 42) (AckHalt (HaltFatal "stop"))
  final <- readIORef mock
  fatal <- readIORef state.fatalError
  assertEqual "pause attempts" 3 final.pauseAttempts
  assertEqual "fatal slot" (Just err) fatal

testAckRetrySeeks :: IO ()
testAckRetrySeeks = do
  mock <- newIORef defaultMockState
  state <- newKafkaAdapterState
  result <- runFinalizer mock $ finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0))
  assertRight result
  final <- readIORef mock
  assertEqual "store attempts" 0 final.storeAttempts
  assertEqual
    "seek call"
    [TopicPartition (TopicName "orders") (PartitionId 0) (PartitionOffset 42)]
    final.seekCalls

testAckRetryBoundsSeek :: IO ()
testAckRetryBoundsSeek = do
  mock <- newIORef defaultMockState
  state <- newKafkaAdapterState
  let slowConfig = testConfig {pollTimeout = Timeout 5000}
  result <- runFinalizer mock $ do
    AckHandle finalize <- mkAckHandle state slowConfig (recordAt 42)
    finalize (AckRetry (RetryDelay 0))
  assertRight result
  final <- readIORef mock
  assertEqual "seek timeout" [Timeout 100] final.seekTimeouts

testBarrierSkipsSuccessorStore :: IO ()
testBarrierSkipsSuccessorStore = do
  mock <- newIORef defaultMockState
  state <- newKafkaAdapterState
  result <- runFinalizer mock $ do
    finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0))
    finalizeRecord state (recordAt 43) AckOk
    finalizeRecord state (recordAt 42) AckOk
  assertRight result
  final <- readIORef mock
  assertEqual "only retried message stored" 1 final.storeAttempts

testEarliestRetrySurvives :: IO ()
testEarliestRetrySurvives = do
  mock <- newIORef defaultMockState
  state <- newKafkaAdapterState
  result <- runFinalizer mock $ do
    finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0))
    finalizeRecord state (recordAt 43) (AckRetry (RetryDelay 0))
    finalizeRecord state (recordAt 43) AckOk
  assertRight result
  final <- readIORef mock
  assertEqual
    "both retries seek the earliest unresolved offset"
    [ TopicPartition (TopicName "orders") (PartitionId 0) (PartitionOffset 42),
      TopicPartition (TopicName "orders") (PartitionId 0) (PartitionOffset 42)
    ]
    final.seekCalls
  assertEqual "later acknowledgement remains fenced" 0 final.storeAttempts

testRetryRequiresRedelivery :: IO ()
testRetryRequiresRedelivery = do
  mock <- newIORef defaultMockState
  state <- newKafkaAdapterState
  result <- runFinalizer mock $ do
    AckHandle finalize <- mkAckHandle state testConfig (recordAt 42)
    finalize (AckRetry (RetryDelay 0))
    finalize AckOk
  assertRight result
  final <- readIORef mock
  assertEqual "same delivery cannot store after requesting retry" 0 final.storeAttempts

testRepeatedRetry :: IO ()
testRepeatedRetry = do
  mock <- newIORef defaultMockState
  state <- newKafkaAdapterState
  result <- runFinalizer mock $ do
    AckHandle finalize <- mkAckHandle state testConfig (recordAt 42)
    finalize (AckRetry (RetryDelay 0))
    finalize (AckRetry (RetryDelay 0))
  assertRight result
  final <- readIORef mock
  assertEqual "one successful retry performs one seek" 1 (length final.seekCalls)

testReferenceModelSeeds :: IO ()
testReferenceModelSeeds =
  -- EP-44's integrated release gate requires at least 1,000 recorded model
  -- cases. Keep the range deterministic so a failure names its replayable
  -- seed and the ordinary package suite exercises the full gate.
  mapM_ runSeed [400040 .. 401039]
  where
    runSeed seed = do
      let generator = mkStdGen seed
          (baseDelta, generator') = randomR (0, 5 :: Int64) generator
          (gap, generator'') = randomR (1, 5 :: Int64) generator'
          (laterFirst, _) = randomR (False, True) generator''
          base = 40 + baseDelta
          later = base + gap
          (firstOffset, secondOffset) = if laterFirst then (later, base) else (base, later)
          retryOrder = [firstOffset, secondOffset]
          expectedSeeks = map toTopicPartition (runningMinimum retryOrder)
      mock <- newIORef defaultMockState
      state <- newKafkaAdapterState
      result <- runFinalizer mock $ do
        first <- mkAckHandle state testConfig (recordAt firstOffset)
        second <- mkAckHandle state testConfig (recordAt secondOffset)
        finalizeHandle first (AckRetry (RetryDelay 0))
        finalizeHandle second (AckRetry (RetryDelay 0))
        prematureLater <- mkAckHandle state testConfig (recordAt later)
        finalizeHandle prematureLater AckOk
        replayBase <- mkAckHandle state testConfig (recordAt base)
        finalizeHandle replayBase AckOk
        replayLater <- mkAckHandle state testConfig (recordAt later)
        finalizeHandle replayLater AckOk
      assertRight result
      final <- readIORef mock
      assertEqual ("seed " <> show seed <> " seek boundary") expectedSeeks final.seekCalls
      assertEqual ("seed " <> show seed <> " stored offsets") [Offset base, Offset later] final.storedOffsets

    runningMinimum = \case
      [] -> []
      first : rest -> scanl min first rest

    toTopicPartition offset =
      TopicPartition (TopicName "orders") (PartitionId 0) (PartitionOffset offset)

    finalizeHandle (AckHandle finalize) = finalize

testPersistentStoreFailureThrows :: IO ()
testPersistentStoreFailureThrows = do
  let err = KafkaResponseError RdKafkaRespErrTransport
  mock <- newIORef defaultMockState {storeFailuresRemaining = 99, storeError = err}
  state <- newKafkaAdapterState
  assertAckFailure err $ runFinalizer mock $ finalizeRecord state (recordAt 42) AckOk

testRevocationFencesCallback :: IO ()
testRevocationFencesCallback = do
  mock <- newIORef defaultMockState
  state <- newKafkaAdapterState
  result <- runFinalizer mock $ do
    AckHandle finalize <- mkAckHandle state testConfig (recordAt 42)
    liftIO $
      kafkaRebalanceHandler
        state
        (error "consumer handle is not inspected")
        (RebalanceRevoke [(TopicName "orders", PartitionId 0)])
    finalize AckOk
  assertRight result
  final <- readIORef mock
  assertEqual "revoked callback cannot store" 0 final.storeAttempts

testCancellationReleasesOwnership :: IO ()
testCancellationReleasesOwnership = do
  started <- newEmptyMVar
  release <- newEmptyMVar
  mock <- newIORef defaultMockState {storeBlock = Just (started, release)}
  state <- newKafkaAdapterState
  result <- runFinalizer mock $ do
    AckHandle finalize <- mkAckHandle state testConfig (recordAt 42)
    withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
      worker <- Async.async (runInIO (finalize AckOk))
      takeMVar started
      Async.cancel worker
      atomicModifyIORef' mock (\mockState -> (mockState {storeBlock = Nothing}, ()))
      mbCompleted <- timeout 1000000 (runInIO (finalize AckOk))
      case mbCompleted of
        Nothing -> assertFailure "finalizer lock or consumer lock remained held after cancellation"
        Just () -> pure ()
  assertRight result
  final <- readIORef mock
  assertEqual "cancelled attempt plus successful retry" 2 final.storeAttempts

testTerminalFailureReachesCore :: IO ()
testTerminalFailureReachesCore = do
  let err = KafkaBadConfiguration
      processorId = ProcessorId "kafka-terminal-ack-failure"
  mock <- newIORef defaultMockState {storeFailuresRemaining = 99, storeError = err}
  state <- newKafkaAdapterState
  result <-
    timeout 5000000 $
      runEff . runErrorNoCallStack @KafkaError . runMockConsumer mock . runTracingNoop $ do
        ingested <- mkIngested state testConfig (recordAt 42)
        let adapter =
              Adapter
                { adapterName = "kafka:test-terminal-ack-failure",
                  source = Stream.fromList [ingested],
                  shutdown = pure ()
                }
            processor = mkProcessor adapter (\_ -> pure AckOk)
        appResult <- runApp defaultAppConfig [(processorId, processor)]
        case appResult of
          Left appError -> error $ "runApp failed: " <> show appError
          Right appHandle -> do
            waitApp appHandle
            lifecycle <- getLifecycleSnapshot (getAppMaster appHandle)
            pure (Map.lookup processorId lifecycle)
  case result of
    Just (Right (Just (LifecycleFailed _ _))) -> pure ()
    other -> assertFailure $ "expected retained terminal acknowledgement failure, got: " <> show other

testSourceObservesFatalSlot :: IO ()
testSourceObservesFatalSlot = do
  let err = KafkaBadConfiguration
  mock <- newIORef defaultMockState
  state <- newKafkaAdapterState
  atomicWriteIORef state.fatalError (Just err)
  result <-
    runEff . runErrorNoCallStack @KafkaError . runMockConsumer mock $
      Stream.fold Fold.drain $
        ingestedStream unreachableBuilder (kafkaSource state testConfig)
  assertEqual "source error" (Left err) result

runFinalizer ::
  IORef MockState ->
  Eff '[KafkaConsumer, Error KafkaError, IOE] a ->
  IO (Either KafkaError a)
runFinalizer mock action =
  runEff . runErrorNoCallStack @KafkaError . runMockConsumer mock $
    action

runMockConsumer ::
  (IOE :> es, Error KafkaError :> es) =>
  IORef MockState ->
  Eff (KafkaConsumer : es) a ->
  Eff es a
runMockConsumer mock =
  interpret $ \_env -> \case
    StoreOffsetMessage cr -> attemptStore mock cr.crOffset
    PausePartitions _ -> attemptPause mock
    SeekPartitions tps seekTimeout -> recordSeek mock tps seekTimeout
    PollMessage _ -> error "AckHandleTest: PollMessage not exercised"
    PollMessageBatch _ _ -> error "AckHandleTest: PollMessageBatch not exercised"
    PollMessageEither _ -> error "AckHandleTest: PollMessageEither not exercised"
    CommitOffsetMessage _ _ -> error "AckHandleTest: CommitOffsetMessage not exercised"
    CommitAllOffsets _ -> error "AckHandleTest: CommitAllOffsets not exercised"
    CommitPartitionsOffsets _ _ -> error "AckHandleTest: CommitPartitionsOffsets not exercised"
    StoreOffsets _ -> error "AckHandleTest: StoreOffsets not exercised"
    Assign _ -> error "AckHandleTest: Assign not exercised"
    ResumePartitions _ -> error "AckHandleTest: ResumePartitions not exercised"
    Committed _ _ -> error "AckHandleTest: Committed not exercised"
    Position _ -> error "AckHandleTest: Position not exercised"
    Assignment -> error "AckHandleTest: Assignment not exercised"
    Subscription -> error "AckHandleTest: Subscription not exercised"
    AskConsumerHandle -> error "AckHandleTest: AskConsumerHandle not exercised"

unreachableBuilder ::
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  Eff es (Ingested es (Maybe ByteString))
unreachableBuilder _ = error "AckHandleTest: source should not yield records"

attemptStore ::
  (IOE :> es, Error KafkaError :> es) =>
  IORef MockState ->
  Offset ->
  Eff es ()
attemptStore mock offset = do
  (mbBlock, mbErr) <-
    liftIO $
      atomicModifyIORef' mock $ \s ->
        let remaining = s.storeFailuresRemaining
            s' =
              s
                { storeAttempts = s.storeAttempts + 1,
                  storedOffsets = s.storedOffsets <> [offset],
                  storeFailuresRemaining = max 0 (remaining - 1)
                }
         in (s', (s.storeBlock, if remaining > 0 then Just s.storeError else Nothing))
  liftIO $ case mbBlock of
    Nothing -> pure ()
    Just (started, release) -> putMVar started () >> takeMVar release
  maybe (pure ()) throwError mbErr

attemptPause :: (IOE :> es, Error KafkaError :> es) => IORef MockState -> Eff es ()
attemptPause mock = do
  mbErr <-
    liftIO $
      atomicModifyIORef' mock $ \s ->
        let remaining = s.pauseFailuresRemaining
            s' = s {pauseAttempts = s.pauseAttempts + 1, pauseFailuresRemaining = max 0 (remaining - 1)}
         in (s', if remaining > 0 then Just s.pauseError else Nothing)
  maybe (pure ()) throwError mbErr

recordSeek :: (IOE :> es, Error KafkaError :> es) => IORef MockState -> [TopicPartition] -> Timeout -> Eff es ()
recordSeek mock tps seekTimeout = do
  mbErr <-
    liftIO $
      atomicModifyIORef' mock $ \s ->
        let remaining = s.seekFailuresRemaining
            s' =
              s
                { seekCalls = s.seekCalls <> tps,
                  seekTimeouts = s.seekTimeouts <> [seekTimeout],
                  seekFailuresRemaining = max 0 (remaining - 1)
                }
         in (s', if remaining > 0 then Just s.seekError else Nothing)
  maybe (pure ()) throwError mbErr

finalizeRecord ::
  (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
  KafkaAdapterState ->
  ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
  AckDecision ->
  Eff es ()
finalizeRecord state cr decision =
  do
    AckHandle finalize <- mkAckHandle state testConfig cr
    finalize decision

recordAt :: Int64 -> ConsumerRecord (Maybe ByteString) (Maybe ByteString)
recordAt offset =
  ConsumerRecord
    { crTopic = TopicName "orders",
      crPartition = PartitionId 0,
      crOffset = Offset offset,
      crTimestamp = NoTimestamp,
      crHeaders = mempty,
      crKey = Nothing,
      crValue = Just "payload"
    }

testConfig :: KafkaAdapterConfig
testConfig =
  KafkaAdapterConfig
    { topics = [TopicName "orders"],
      pollTimeout = Timeout 100,
      batchSize = BatchSize 100
    }

defaultMockState :: MockState
defaultMockState =
  MockState
    { storeAttempts = 0,
      storedOffsets = [],
      pauseAttempts = 0,
      seekCalls = [],
      seekTimeouts = [],
      storeBlock = Nothing,
      storeFailuresRemaining = 0,
      pauseFailuresRemaining = 0,
      seekFailuresRemaining = 0,
      storeError = KafkaResponseError RdKafkaRespErrTransport,
      pauseError = KafkaResponseError RdKafkaRespErrTransport,
      seekError = KafkaResponseError RdKafkaRespErrTransport
    }

assertRight :: (Show e) => Either e a -> IO ()
assertRight = \case
  Left err -> assertFailure $ "expected Right, got Left: " <> show err
  Right _ -> pure ()

assertAckFailure :: KafkaError -> IO (Either KafkaError ()) -> IO ()
assertAckFailure expected action = do
  result <- try @KafkaAcknowledgementException action
  case result of
    Left (KafkaAcknowledgementException actual) -> assertEqual "acknowledgement error" expected actual
    Right value -> assertFailure $ "expected KafkaAcknowledgementException, got: " <> show value
