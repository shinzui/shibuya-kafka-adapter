module Shibuya.Adapter.Kafka.DeliveryStatusTest (tests) where

import Data.IORef (newIORef)
import Effectful (liftIO)
import Kafka.Consumer.Types (ConsumerRecord (..))
import Kafka.Types (PartitionId (..))
import Shibuya.Adapter.Kafka.AckHandleTest hiding (tests)
import Shibuya.Adapter.Kafka.Internal (Polled (..), gateRecords, markPartitionsAssigned, markPartitionsRevoked, mkIngested, newKafkaAdapterState)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (DeliveryStatus (..), Ingested (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Delivery status"
    [ testCase "retry supersedes the original and successors, preserving predecessors and other partitions" testBarrier,
      testCase "replayed retry supersedes that attempt again" testRepeated,
      testCase "revoke and reassign fence the old generation" testGeneration,
      testCase "missing-offset recovery supersedes old deliveries" testGap
    ]

testBarrier :: IO ()
testBarrier = do
  state <- newKafkaAdapterState
  mock <- newIORef defaultMockState
  runFinalizer
    mock
    ( do
        before <- mkIngested state testConfig (recordAt 41)
        original <- mkIngested state testConfig (recordAt 42)
        successor <- mkIngested state testConfig (recordAt 43)
        other <- mkIngested state testConfig (recordAt 44) {crPartition = PartitionId 1}
        mapM_ (\i -> i.deliveryStatus >>= liftIO . assertEqual "initially current" DeliveryCurrent) [before, original, successor, other]
        let AckHandle retry = original.ack
        retry (AckRetry (RetryDelay 0))
        statuses <- mapM (.deliveryStatus) [before, original, successor, other]
        liftIO $ assertEqual "barrier admission" [DeliveryCurrent, DeliverySuperseded, DeliverySuperseded, DeliveryCurrent] statuses
        replay <- mkIngested state testConfig (recordAt 42)
        replay.deliveryStatus >>= liftIO . assertEqual "new barrier attempt current" DeliveryCurrent
        let AckHandle finalize = replay.ack
        finalize AckOk
        freshSuccessor <- mkIngested state testConfig (recordAt 43)
        after <- mapM (.deliveryStatus) [original, successor, replay, freshSuccessor]
        liftIO $ assertEqual "token floor persists after success" [DeliverySuperseded, DeliverySuperseded, DeliveryCurrent, DeliveryCurrent] after
    )
    >>= assertRight

testRepeated :: IO ()
testRepeated = do
  state <- newKafkaAdapterState
  mock <- newIORef defaultMockState
  runFinalizer
    mock
    ( do
        finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0))
        replay <- mkIngested state testConfig (recordAt 42)
        let AckHandle finalize = replay.ack
        finalize (AckRetry (RetryDelay 0))
        replay.deliveryStatus >>= liftIO . assertEqual "retried replay superseded" DeliverySuperseded
        next <- mkIngested state testConfig (recordAt 42)
        next.deliveryStatus >>= liftIO . assertEqual "next replay current" DeliveryCurrent
    )
    >>= assertRight

testGeneration :: IO ()
testGeneration = do
  state <- newKafkaAdapterState
  mock <- newIORef defaultMockState
  runFinalizer
    mock
    ( do
        old <- mkIngested state testConfig (recordAt 42)
        let key = (recordAt 42).crTopic
        liftIO $ markPartitionsRevoked state [(key, PartitionId 0)]
        old.deliveryStatus >>= liftIO . assertEqual "revoked attempt" DeliverySuperseded
        liftIO $ markPartitionsAssigned state [(key, PartitionId 0)]
        old.deliveryStatus >>= liftIO . assertEqual "old generation after reassignment" DeliverySuperseded
        fresh <- mkIngested state testConfig (recordAt 42)
        fresh.deliveryStatus >>= liftIO . assertEqual "new assignment" DeliveryCurrent
    )
    >>= assertRight

testGap :: IO ()
testGap = do
  state <- newKafkaAdapterState
  mock <- newIORef defaultMockState
  runFinalizer
    mock
    ( do
        old <- mkIngested state testConfig (recordAt 46)
        finalizeRecord state (recordAt 42) (AckRetry (RetryDelay 0))
        Stream.fold Fold.drain $ gateRecords state $ Stream.fromList [Right (Polled 1 (recordAt 45))]
        old.deliveryStatus >>= liftIO . assertEqual "gap fences old token" DeliverySuperseded
        fresh <- mkIngested state testConfig (recordAt 45)
        fresh.deliveryStatus >>= liftIO . assertEqual "next available offset" DeliveryCurrent
    )
    >>= assertRight
