module Shibuya.Adapter.Kafka.AckHandleTest (tests) where

import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Int (Int64)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Kafka.Consumer (RdKafkaRespErrT (..))
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), OffsetReset (..), PartitionOffset (..), Timestamp (..), TopicPartition (..))
import Kafka.Effectful.Consumer.Effect (KafkaConsumer (..))
import Kafka.Types (BatchSize (..), KafkaError (..), PartitionId (..), Timeout (..), TopicName (..))
import Shibuya.Adapter.Kafka.Config (KafkaAdapterConfig (..))
import Shibuya.Adapter.Kafka.Internal (KafkaAdapterState (..), ingestedStream, kafkaSource, mkAckHandle, newKafkaAdapterState)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

data MockState = MockState
    { storeAttempts :: !Int
    , pauseAttempts :: !Int
    , seekCalls :: ![TopicPartition]
    , storeFailuresRemaining :: !Int
    , pauseFailuresRemaining :: !Int
    , seekFailuresRemaining :: !Int
    , storeError :: !KafkaError
    , pauseError :: !KafkaError
    , seekError :: !KafkaError
    }

tests :: TestTree
tests =
    testGroup
        "AckHandle"
        [ testCase "transient store failures retry and then succeed" testTransientStoreRetry
        , testCase "persistent transient store failure records fatal slot without throwing" testPersistentStoreFailure
        , testCase "fatal store failure records fatal slot after one attempt" testFatalStoreFailure
        , testCase "AckHalt pause failure does not throw and records fatal slot" testAckHaltPauseFailure
        , testCase "AckRetry seeks exact failed offset and does not store" testAckRetrySeeks
        , testCase "seek barrier prevents stale successor store" testBarrierSkipsSuccessorStore
        , testCase "source observes fatal slot before polling" testSourceObservesFatalSlot
        ]

testTransientStoreRetry :: IO ()
testTransientStoreRetry = do
    mock <- newIORef defaultMockState{storeFailuresRemaining = 2}
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
    mock <- newIORef defaultMockState{storeFailuresRemaining = 99, storeError = err}
    state <- newKafkaAdapterState
    result <- runFinalizer mock $ finalizeRecord state (recordAt 42) AckOk
    assertRight result
    final <- readIORef mock
    fatal <- readIORef state.fatalError
    assertEqual "store attempts" 3 final.storeAttempts
    assertEqual "fatal slot" (Just err) fatal

testFatalStoreFailure :: IO ()
testFatalStoreFailure = do
    let err = KafkaBadConfiguration
    mock <- newIORef defaultMockState{storeFailuresRemaining = 99, storeError = err}
    state <- newKafkaAdapterState
    result <- runFinalizer mock $ finalizeRecord state (recordAt 42) AckOk
    assertRight result
    final <- readIORef mock
    fatal <- readIORef state.fatalError
    assertEqual "store attempts" 1 final.storeAttempts
    assertEqual "fatal slot" (Just err) fatal

testAckHaltPauseFailure :: IO ()
testAckHaltPauseFailure = do
    let err = KafkaResponseError RdKafkaRespErrTransport
    mock <- newIORef defaultMockState{pauseFailuresRemaining = 99, pauseError = err}
    state <- newKafkaAdapterState
    result <- runFinalizer mock $ finalizeRecord state (recordAt 42) (AckHalt (HaltFatal "stop"))
    assertRight result
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
        StoreOffsetMessage _ -> attemptStore mock
        PausePartitions _ -> attemptPause mock
        SeekPartitions tps _ -> recordSeek mock tps
        PollMessage _ -> error "AckHandleTest: PollMessage not exercised"
        PollMessageBatch _ _ -> error "AckHandleTest: PollMessageBatch not exercised"
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
    Ingested es (Maybe ByteString)
unreachableBuilder _ = error "AckHandleTest: source should not yield records"

attemptStore :: (IOE :> es, Error KafkaError :> es) => IORef MockState -> Eff es ()
attemptStore mock = do
    mbErr <-
        liftIO $
            atomicModifyIORef' mock $ \s ->
                let remaining = s.storeFailuresRemaining
                    s' = s{storeAttempts = s.storeAttempts + 1, storeFailuresRemaining = max 0 (remaining - 1)}
                 in (s', if remaining > 0 then Just s.storeError else Nothing)
    maybe (pure ()) throwError mbErr

attemptPause :: (IOE :> es, Error KafkaError :> es) => IORef MockState -> Eff es ()
attemptPause mock = do
    mbErr <-
        liftIO $
            atomicModifyIORef' mock $ \s ->
                let remaining = s.pauseFailuresRemaining
                    s' = s{pauseAttempts = s.pauseAttempts + 1, pauseFailuresRemaining = max 0 (remaining - 1)}
                 in (s', if remaining > 0 then Just s.pauseError else Nothing)
    maybe (pure ()) throwError mbErr

recordSeek :: (IOE :> es, Error KafkaError :> es) => IORef MockState -> [TopicPartition] -> Eff es ()
recordSeek mock tps = do
    mbErr <-
        liftIO $
            atomicModifyIORef' mock $ \s ->
                let remaining = s.seekFailuresRemaining
                    s' = s{seekCalls = s.seekCalls <> tps, seekFailuresRemaining = max 0 (remaining - 1)}
                 in (s', if remaining > 0 then Just s.seekError else Nothing)
    maybe (pure ()) throwError mbErr

finalizeRecord ::
    (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterState ->
    ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
    AckDecision ->
    Eff es ()
finalizeRecord state cr decision =
    let AckHandle finalize = mkAckHandle state testConfig cr
     in finalize decision

recordAt :: Int64 -> ConsumerRecord (Maybe ByteString) (Maybe ByteString)
recordAt offset =
    ConsumerRecord
        { crTopic = TopicName "orders"
        , crPartition = PartitionId 0
        , crOffset = Offset offset
        , crTimestamp = NoTimestamp
        , crHeaders = mempty
        , crKey = Nothing
        , crValue = Just "payload"
        }

testConfig :: KafkaAdapterConfig
testConfig =
    KafkaAdapterConfig
        { topics = [TopicName "orders"]
        , pollTimeout = Timeout 100
        , batchSize = BatchSize 100
        , offsetReset = Earliest
        }

defaultMockState :: MockState
defaultMockState =
    MockState
        { storeAttempts = 0
        , pauseAttempts = 0
        , seekCalls = []
        , storeFailuresRemaining = 0
        , pauseFailuresRemaining = 0
        , seekFailuresRemaining = 0
        , storeError = KafkaResponseError RdKafkaRespErrTransport
        , pauseError = KafkaResponseError RdKafkaRespErrTransport
        , seekError = KafkaResponseError RdKafkaRespErrTransport
        }

assertRight :: (Show e) => Either e a -> IO ()
assertRight = \case
    Left err -> assertFailure $ "expected Right, got Left: " <> show err
    Right _ -> pure ()
