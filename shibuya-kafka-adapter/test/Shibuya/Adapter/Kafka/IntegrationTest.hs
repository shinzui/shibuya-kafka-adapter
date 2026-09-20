module Shibuya.Adapter.Kafka.IntegrationTest (tests) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TChan, atomically, newTChanIO, readTChan, writeTChan)
import Control.Exception (throwIO)
import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Maybe (mapMaybe)
import Data.Text qualified as Text
import Effectful (Eff, Limit (..), Persistence (..), UnliftStrategy (..), runEff, withEffToIO)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerRecord (..), OffsetCommit (..), OffsetReset (..), RebalanceEvent (..))
import Kafka.Effectful.Consumer
  ( brokersList,
    groupId,
    noAutoOffsetStore,
    offsetReset,
    rebalanceCallback,
    runKafkaConsumer,
    setCallback,
    topics,
  )
import Kafka.Effectful.Consumer.Effect (commitAllOffsets, pollMessageBatch)
import Kafka.TestEnv
  ( TestEnv (..),
    consumeN,
    createTopic,
    createTopicWithPartitions,
    produceKeyedMessages,
    produceMessages,
    producePartitionMessages,
    withTestEnv,
  )
import Kafka.Types
  ( BatchSize (..),
    KafkaError,
    PartitionId (..),
    Timeout (..),
    TopicName (..),
  )
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (KafkaAdapterConfig (..), kafkaAdapter, kafkaAdapterWith, kafkaRebalanceHandler, newKafkaAdapterState)
import Shibuya.App (ProcessorId (..), defaultAppConfig, mkProcessor, runApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..), Message (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Integration"
    [ testCase "Basic produce-consume" testBasicProduceConsume,
      testCase "Offset commit verification" testOffsetCommit,
      testCase "Multi-partition distribution" testMultiPartition,
      testCase "Batch polling" testBatchPolling,
      testCase "Graceful shutdown" testGracefulShutdown,
      testCase "Idle graceful shutdown completes promptly" testIdleGracefulShutdown,
      testCase "Repeated shutdown is idempotent" testRepeatedShutdown,
      testCase "AckRetry redelivers within the same session" testAckRetryRedelivery,
      testCase "later buffered retry cannot replace the earliest recovery boundary" testBufferedRetryBoundary,
      testCase "AckRetry is not committed past when session exits" testAckRetryAbandonedSession,
      testCase "late callback after revocation cannot advance the broker offset" testRevokedCallbackDoesNotCommit,
      testCase "actual reassignment fences a late callback from the old owner" testActualReassignmentFence,
      testCase "Handler exception redelivers instead of skipping" testHandlerExceptionRedelivery
    ]

testBasicProduceConsume :: IO ()
testBasicProduceConsume = withTestEnv $ \env -> do
  createTopic env
  let payloads = ["msg-1", "msg-2", "msg-3", "msg-4", "msg-5"]
  produceMessages env payloads
  envelopes <- consumeN env 5 AckOk

  -- Verify all 5 messages received
  assertEqual "message count" 5 (length envelopes)

  -- Verify payloads
  let receivedPayloads = map (\(Envelope {payload}) -> payload) envelopes
  assertEqual "payloads" (map Just payloads) receivedPayloads

  -- Verify messageId format: topic-partition-offset
  case envelopes of
    (Envelope {messageId = MessageId firstIdText} : _) ->
      assertBool "messageId contains topic" (Text.isPrefixOf (unTopicName env.testTopic) firstIdText)
    [] -> error "unreachable: already verified 5 envelopes"

  -- Verify cursor is populated
  assertBool "cursor is Just" (all (\(Envelope {cursor}) -> case cursor of Just (CursorInt _) -> True; _ -> False) envelopes)

  -- Verify partition is populated
  assertBool "partition is Just" (all (\(Envelope {partition}) -> case partition of Just _ -> True; _ -> False) envelopes)

testOffsetCommit :: IO ()
testOffsetCommit = withTestEnv $ \env -> do
  createTopic env
  let payloads = ["oc-1", "oc-2", "oc-3"]
  produceMessages env payloads

  -- Consume all 3, AckOk each (stores offsets), then commit
  _ <- consumeN env 3 AckOk

  -- Create new consumer in same group - should get no messages
  result <- runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      -- Poll a few times to allow group join + rebalance, verify no re-delivery
      allResults <- forM [1 .. 3 :: Int] $ \_ -> do
        results <- pollMessageBatch (Timeout 3000) (BatchSize 100)
        pure [cr | Right cr <- results]
      let totalMessages = concat allResults
      liftIO $ assertEqual "no re-delivery" 0 (length totalMessages)
  case result of
    Left err -> error $ "Failed: " <> show err
    Right () -> pure ()

testMultiPartition :: IO ()
testMultiPartition = withTestEnv $ \env -> do
  createTopicWithPartitions env 3
  let pairs =
        [ ("key-a", "msg-a"),
          ("key-b", "msg-b"),
          ("key-c", "msg-c"),
          ("key-d", "msg-d"),
          ("key-e", "msg-e"),
          ("key-f", "msg-f")
        ]
  produceKeyedMessages env pairs
  envelopes <- consumeN env 6 AckOk

  assertEqual "message count" 6 (length envelopes)

  let partitions = mapMaybe (\(Envelope {partition}) -> partition) envelopes
  assertEqual "all have partition" 6 (length partitions)

  let uniquePartitions = nub partitions
  assertBool
    ("expected multiple partitions, got: " <> show uniquePartitions)
    (length uniquePartitions >= 2)

testBatchPolling :: IO ()
testBatchPolling = withTestEnv $ \env -> do
  createTopic env
  let payloads = map (\i -> BS8.pack ("batch-" <> show i)) [1 .. 20 :: Int]
  produceMessages env payloads
  envelopes <- consumeN env 20 AckOk

  assertEqual "message count" 20 (length envelopes)

  let receivedPayloads = sort $ mapMaybe (\(Envelope {payload}) -> payload) envelopes
  assertEqual "payloads" (sort payloads) receivedPayloads

testGracefulShutdown :: IO ()
testGracefulShutdown = withTestEnv $ \env -> do
  createTopic env
  let payloads = ["sd-1", "sd-2", "sd-3"]
  produceMessages env payloads

  ref <- newIORef ([] :: [Envelope (Maybe ByteString)])
  result <- runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      let config =
            KafkaAdapterConfig
              { topics = [env.testTopic],
                pollTimeout = Timeout 5000,
                batchSize = BatchSize 100
              }
      Adapter {source, shutdown} <- kafkaAdapter config
      Stream.fold Fold.drain
        $ Stream.mapM
          ( \(Ingested {envelope, ack = AckHandle finalize}) -> do
              liftIO $ modifyIORef' ref (envelope :)
              finalize AckOk
          )
        $ Stream.take 3 source
      shutdown
  case result of
    Left err -> error $ "Failed: " <> show err
    Right () -> pure ()
  envelopes <- reverse <$> readIORef ref
  assertEqual "consumed 3 before shutdown" 3 (length envelopes)

testIdleGracefulShutdown :: IO ()
testIdleGracefulShutdown = withTestEnv $ \env -> do
  createTopic env

  timedResult <- timeout 3000000 $ runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      let config =
            KafkaAdapterConfig
              { topics = [env.testTopic],
                pollTimeout = Timeout 250,
                batchSize = BatchSize 100
              }
      Adapter {source, shutdown} <- kafkaAdapter config
      shutdown
      Stream.fold Fold.drain source
  case timedResult of
    Nothing -> assertFailure "idle shutdown did not terminate promptly"
    Just (Left (_cs, err)) -> assertFailure $ "idle shutdown failed: " <> show err
    Just (Right ()) -> pure ()

testRepeatedShutdown :: IO ()
testRepeatedShutdown = withTestEnv $ \env -> do
  createTopic env

  timedResult <- timeout 3000000 $ runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      Adapter {shutdown} <- kafkaAdapter (testConfig env)
      shutdown
      shutdown
  case timedResult of
    Nothing -> assertFailure "repeated shutdown did not terminate promptly"
    Just (Left (_cs, err)) -> assertFailure $ "repeated shutdown failed: " <> show err
    Just (Right ()) -> pure ()

testAckRetryRedelivery :: IO ()
testAckRetryRedelivery = withTestEnv $ \env -> do
  createTopic env
  let payloads = ["r-1", "r-2", "r-3"]
  produceMessages env payloads

  retried <- newIORef False
  seen <- newIORef ([] :: [ByteString])
  result <- runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      Adapter {source} <- kafkaAdapter (testConfig env)
      Stream.fold Fold.drain
        $ Stream.mapM
          ( \(Ingested {envelope, ack = AckHandle finalize}) -> do
              let payload = maybe "" id envelope.payload
              liftIO $ modifyIORef' seen (payload :)
              hasRetried <- liftIO $ readIORef retried
              if payload == "r-2" && not hasRetried
                then do
                  liftIO $ writeIORef retried True
                  finalize (AckRetry (RetryDelay 0))
                else finalize AckOk
          )
        $ Stream.take 4 source
      commitAllOffsets OffsetCommit
  case result of
    Left (_cs, err) -> assertFailure $ "AckRetry redelivery failed: " <> show err
    Right () -> pure ()

  delivered <- reverse <$> readIORef seen
  assertBool ("expected r-2 at least twice, saw " <> show delivered) (countPayload "r-2" delivered >= 2)
  assertBool ("expected r-3 after retry, saw " <> show delivered) ("r-3" `elem` delivered)

  noRedelivery <- runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      batches <- forM [1 .. 3 :: Int] $ \_ ->
        pollMessageBatch (Timeout 500) (BatchSize 100)
      liftIO $ assertEqual "no redelivery after final AckOk commit" 0 (length [cr | Right cr <- concat batches])
  case noRedelivery of
    Left (_cs, err) -> assertFailure $ "post-commit verification failed: " <> show err
    Right () -> pure ()

testBufferedRetryBoundary :: IO ()
testBufferedRetryBoundary = withTestEnv $ \env -> do
  createTopic env
  let payloads = ["boundary-42", "boundary-43"]
  produceMessages env payloads

  result <- runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      Adapter {source} <- kafkaAdapter (testConfig env)
      firstBuffered <- liftIO $ newIORef Nothing
      deliveryIndex <- liftIO $ newIORef (0 :: Int)
      replayedPayloads <- liftIO $ newIORef ([] :: [ByteString])
      Stream.fold Fold.drain
        $ Stream.mapM
          ( \ingested -> do
              index <- liftIO $ atomicModifyIORef' deliveryIndex (\n -> (n + 1, n))
              case index of
                0 -> liftIO $ writeIORef firstBuffered (Just ingested)
                1 -> do
                  first <-
                    liftIO (readIORef firstBuffered) >>= \case
                      Just value -> pure value
                      Nothing -> error "missing first buffered delivery"
                  finalizeIngested first (AckRetry (RetryDelay 0))
                  finalizeIngested ingested (AckRetry (RetryDelay 0))
                _ -> do
                  case ingested of
                    Ingested {envelope = Envelope {payload = Just payload}} ->
                      liftIO $ modifyIORef' replayedPayloads (<> [payload])
                    _ -> pure ()
                  finalizeIngested ingested AckOk
          )
        $ Stream.take 4 source
      replayed <- liftIO $ readIORef replayedPayloads
      liftIO $
        assertEqual
          "retry seeks the earliest delivery before its successor"
          payloads
          replayed
      commitAllOffsets OffsetCommit
  case result of
    Left (_cs, err) -> assertFailure $ "buffered retry boundary failed: " <> show err
    Right () -> pure ()

  noRedelivery <- pollPayloads env 3
  assertEqual "both replayed deliveries committed" [] noRedelivery

testAckRetryAbandonedSession :: IO ()
testAckRetryAbandonedSession = withTestEnv $ \env -> do
  createTopic env
  let payloads = ["ab-1", "ab-2", "ab-3"]
  produceMessages env payloads

  firstSession <- runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      Adapter {source} <- kafkaAdapter (testConfig env)
      Stream.fold Fold.drain
        $ Stream.mapM
          ( \(Ingested {envelope, ack = AckHandle finalize}) -> do
              case envelope.payload of
                Just "ab-2" -> finalize (AckRetry (RetryDelay 0))
                _ -> finalize AckOk
          )
        $ Stream.take 2 source
  case firstSession of
    Left (_cs, err) -> assertFailure $ "first session failed: " <> show err
    Right () -> pure ()

  redelivered <- newIORef ([] :: [ByteString])
  secondSession <- runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      Adapter {source} <- kafkaAdapter (testConfig env)
      Stream.fold Fold.drain
        $ Stream.mapM
          ( \(Ingested {envelope, ack = AckHandle finalize}) -> do
              maybe (pure ()) (liftIO . modifyIORef' redelivered . (:)) envelope.payload
              finalize AckOk
          )
        $ Stream.take 2 source
      commitAllOffsets OffsetCommit
  case secondSession of
    Left (_cs, err) -> assertFailure $ "second session failed: " <> show err
    Right () -> pure ()

  delivered <- readIORef redelivered
  assertBool ("expected ab-2 redelivery, saw " <> show delivered) ("ab-2" `elem` delivered)

testRevokedCallbackDoesNotCommit :: IO ()
testRevokedCallbackDoesNotCommit = withTestEnv $ \env -> do
  createTopic env
  produceMessages env ["revoked-late-callback"]

  firstSession <- runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      state <- liftIO newKafkaAdapterState
      Adapter {source} <- kafkaAdapterWith state (testConfig env)
      delivered <- Stream.fold Fold.toList $ Stream.take 1 source
      case delivered of
        [ingested] -> do
          liftIO $
            kafkaRebalanceHandler
              state
              (error "consumer handle is not inspected")
              (RebalanceRevoke [(env.testTopic, PartitionId 0)])
          finalizeIngested ingested AckOk
        other -> liftIO $ assertFailure $ "expected one delivery before revoke, got " <> show (length other)
  case firstSession of
    Left (_cs, err) -> assertFailure $ "revoked session failed: " <> show err
    Right () -> pure ()

  replayed <- consumeN env 1 AckOk
  assertEqual
    "revoked delivery remains recoverable"
    [Just "revoked-late-callback"]
    [envelope.payload | envelope <- replayed]

testActualReassignmentFence :: IO ()
testActualReassignmentFence = withTestEnv $ \env -> do
  createTopicWithPartitions env 2
  producePartitionMessages env [(0, "rebalance-partition-0"), (1, "rebalance-partition-1")]
  state <- newKafkaAdapterState
  events <- newTChanIO
  handlesReady <- newEmptyMVar
  releaseFirstConsumer <- newEmptyMVar

  let callback consumer event = do
        kafkaRebalanceHandler state consumer event
        atomically $ writeTChan events event
      firstProps =
        brokersList [env.testBroker]
          <> groupId env.testGroupId
          <> noAutoOffsetStore
          <> setCallback (rebalanceCallback callback)
      sub = topics [env.testTopic] <> offsetReset Earliest
      firstConsumer =
        runEff . runError @KafkaError $
          runKafkaConsumer firstProps sub $ do
            Adapter {source} <- kafkaAdapterWith state (testConfig env)
            delivered <- Stream.fold Fold.toList $ Stream.take 2 source
            withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO -> do
              putMVar handlesReady (map (callbackHandle runInIO) delivered)
              takeMVar releaseFirstConsumer
      secondConsumer =
        runEff . runError @KafkaError $
          runKafkaConsumer
            (brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore)
            sub
            ( do
                _ <- forM [1 .. 20 :: Int] $ \_ -> pollMessageBatch (Timeout 250) (BatchSize 100)
                pure ()
            )

  Async.withAsync firstConsumer $ \firstAsync -> do
    mbHandles <- timeout 10000000 (takeMVar handlesReady)
    handles <- case mbHandles of
      Nothing -> assertFailure "first consumer did not receive both partitions" >> pure []
      Just value -> pure value
    revoked <- Async.withAsync secondConsumer $ \secondAsync -> do
      mbRevoked <- timeout 10000000 (awaitRevokedPartition env.testTopic events)
      revoked <- case mbRevoked of
        Nothing -> assertFailure "second consumer did not trigger a revocation" >> pure (PartitionId (-1))
        Just value -> pure value
      case lookup revoked handles of
        Nothing -> assertFailure $ "no retained handle for revoked partition " <> show revoked
        Just lateFinalize -> lateFinalize AckOk
      putMVar releaseFirstConsumer ()
      firstResult <- Async.wait firstAsync
      case firstResult of
        Left (_cs, err) -> assertFailure $ "first reassignment consumer failed: " <> show err
        Right () -> pure ()
      Async.cancel secondAsync
      pure revoked

    replayed <- pollPayloads env 5
    let expected = if revoked == PartitionId 0 then "rebalance-partition-0" else "rebalance-partition-1"
    assertBool
      ("expected revoked partition payload to remain recoverable, saw " <> show replayed)
      (expected `elem` replayed)

testHandlerExceptionRedelivery :: IO ()
testHandlerExceptionRedelivery = withTestEnv $ \env -> do
  createTopic env
  let payloads = ["n-1", "n-2", "n-3"]
  produceMessages env payloads

  thrown <- newIORef False
  seen <- newIORef ([] :: [ByteString])
  result <- runEff . runError @KafkaError . runTracingNoop $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      upstream <- kafkaAdapter (testConfig env)
      let finiteAdapter = upstream {source = Stream.take 4 upstream.source}
          handler Message {envelope} = do
            let payload = maybe "" id envelope.payload
            liftIO $ modifyIORef' seen (payload :)
            hasThrown <- liftIO $ readIORef thrown
            if payload == "n-2" && not hasThrown
              then liftIO $ do
                writeIORef thrown True
                throwIO (userError "planned handler exception")
              else pure AckOk
      appResult <- runApp defaultAppConfig [(ProcessorId "handler-exception", mkProcessor finiteAdapter handler)]
      case appResult of
        Left appErr -> liftIO $ assertFailure $ "runApp failed: " <> show appErr
        Right appHandle -> waitApp appHandle
      commitAllOffsets OffsetCommit
  case result of
    Left (_cs, err) -> assertFailure $ "handler exception scenario failed: " <> show err
    Right () -> pure ()

  delivered <- reverse <$> readIORef seen
  assertBool ("expected n-2 at least twice, saw " <> show delivered) (countPayload "n-2" delivered >= 2)
  assertBool ("expected n-3 after handler exception retry, saw " <> show delivered) ("n-3" `elem` delivered)

testConfig :: TestEnv -> KafkaAdapterConfig
testConfig env =
  KafkaAdapterConfig
    { topics = [env.testTopic],
      pollTimeout = Timeout 500,
      batchSize = BatchSize 100
    }

countPayload :: ByteString -> [ByteString] -> Int
countPayload target = length . filter (== target)

finalizeIngested :: Ingested es payload -> AckDecision -> Eff es ()
finalizeIngested Ingested {ack = AckHandle finalize} = finalize

pollPayloads :: TestEnv -> Int -> IO [ByteString]
pollPayloads env pollCount = do
  result <- runEff . runError @KafkaError $ do
    let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
        sub = topics [env.testTopic] <> offsetReset Earliest
    runKafkaConsumer props sub $ do
      batches <- forM [1 .. pollCount] $ \_ ->
        pollMessageBatch (Timeout 500) (BatchSize 100)
      pure [payload | Right record <- concat batches, Just payload <- [record.crValue]]
  case result of
    Left (_cs, err) -> assertFailure ("poll verification failed: " <> show err) >> pure []
    Right payloads -> pure payloads

callbackHandle ::
  (forall a. Eff es a -> IO a) ->
  Ingested es payload ->
  (PartitionId, AckDecision -> IO ())
callbackHandle runInIO Ingested {envelope = Envelope {partition}, ack = AckHandle finalize} =
  case partition of
    Just partitionText -> (PartitionId (read (Text.unpack partitionText)), runInIO . finalize)
    Nothing -> error "Kafka delivery did not carry a partition"

awaitRevokedPartition :: TopicName -> TChan RebalanceEvent -> IO PartitionId
awaitRevokedPartition topic events = atomically loop
  where
    loop = do
      event <- readTChan events
      case event of
        RebalanceRevoke revoked ->
          case [partition | (topic', partition) <- revoked, topic' == topic] of
            partition : _ -> pure partition
            [] -> loop
        _ -> loop
