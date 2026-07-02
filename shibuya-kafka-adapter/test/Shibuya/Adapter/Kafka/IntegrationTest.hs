module Shibuya.Adapter.Kafka.IntegrationTest (tests) where

import Control.Exception (throwIO)
import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Maybe (mapMaybe)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (OffsetCommit (..), OffsetReset (..))
import Kafka.Effectful.Consumer (
    brokersList,
    groupId,
    noAutoOffsetStore,
    offsetReset,
    runKafkaConsumer,
    topics,
 )
import Kafka.Effectful.Consumer.Effect (commitAllOffsets, pollMessageBatch)
import Kafka.TestEnv (
    TestEnv (..),
    consumeN,
    createTopic,
    createTopicWithPartitions,
    produceKeyedMessages,
    produceMessages,
    withTestEnv,
 )
import Kafka.Types (
    BatchSize (..),
    KafkaError,
    Timeout (..),
    TopicName (..),
 )
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (KafkaAdapterConfig (..), kafkaAdapter)
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
        [ testCase "Basic produce-consume" testBasicProduceConsume
        , testCase "Offset commit verification" testOffsetCommit
        , testCase "Multi-partition distribution" testMultiPartition
        , testCase "Batch polling" testBatchPolling
        , testCase "Graceful shutdown" testGracefulShutdown
        , testCase "Idle graceful shutdown completes promptly" testIdleGracefulShutdown
        , testCase "AckRetry redelivers within the same session" testAckRetryRedelivery
        , testCase "AckRetry is not committed past when session exits" testAckRetryAbandonedSession
        , testCase "Handler exception redelivers instead of skipping" testHandlerExceptionRedelivery
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
    let receivedPayloads = map (\(Envelope{payload}) -> payload) envelopes
    assertEqual "payloads" (map Just payloads) receivedPayloads

    -- Verify messageId format: topic-partition-offset
    case envelopes of
        (Envelope{messageId = MessageId firstIdText} : _) ->
            assertBool "messageId contains topic" (Text.isPrefixOf (unTopicName env.testTopic) firstIdText)
        [] -> error "unreachable: already verified 5 envelopes"

    -- Verify cursor is populated
    assertBool "cursor is Just" (all (\(Envelope{cursor}) -> case cursor of Just (CursorInt _) -> True; _ -> False) envelopes)

    -- Verify partition is populated
    assertBool "partition is Just" (all (\(Envelope{partition}) -> case partition of Just _ -> True; _ -> False) envelopes)

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
            [ ("key-a", "msg-a")
            , ("key-b", "msg-b")
            , ("key-c", "msg-c")
            , ("key-d", "msg-d")
            , ("key-e", "msg-e")
            , ("key-f", "msg-f")
            ]
    produceKeyedMessages env pairs
    envelopes <- consumeN env 6 AckOk

    assertEqual "message count" 6 (length envelopes)

    let partitions = mapMaybe (\(Envelope{partition}) -> partition) envelopes
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

    let receivedPayloads = sort $ mapMaybe (\(Envelope{payload}) -> payload) envelopes
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
                        { topics = [env.testTopic]
                        , pollTimeout = Timeout 5000
                        , batchSize = BatchSize 100
                        , offsetReset = Earliest
                        }
            Adapter{source, shutdown} <- kafkaAdapter config
            Stream.fold Fold.drain
                $ Stream.mapM
                    ( \(Ingested{envelope, ack = AckHandle finalize}) -> do
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
                        { topics = [env.testTopic]
                        , pollTimeout = Timeout 250
                        , batchSize = BatchSize 100
                        , offsetReset = Earliest
                        }
            Adapter{source, shutdown} <- kafkaAdapter config
            shutdown
            Stream.fold Fold.drain source
    case timedResult of
        Nothing -> assertFailure "idle shutdown did not terminate promptly"
        Just (Left (_cs, err)) -> assertFailure $ "idle shutdown failed: " <> show err
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
            Adapter{source} <- kafkaAdapter (testConfig env)
            Stream.fold Fold.drain
                $ Stream.mapM
                    ( \(Ingested{envelope, ack = AckHandle finalize}) -> do
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

testAckRetryAbandonedSession :: IO ()
testAckRetryAbandonedSession = withTestEnv $ \env -> do
    createTopic env
    let payloads = ["ab-1", "ab-2", "ab-3"]
    produceMessages env payloads

    firstSession <- runEff . runError @KafkaError $ do
        let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
            sub = topics [env.testTopic] <> offsetReset Earliest
        runKafkaConsumer props sub $ do
            Adapter{source} <- kafkaAdapter (testConfig env)
            Stream.fold Fold.drain
                $ Stream.mapM
                    ( \(Ingested{envelope, ack = AckHandle finalize}) -> do
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
            Adapter{source} <- kafkaAdapter (testConfig env)
            Stream.fold Fold.drain
                $ Stream.mapM
                    ( \(Ingested{envelope, ack = AckHandle finalize}) -> do
                        maybe (pure ()) (liftIO . modifyIORef' redelivered . (:)) envelope.payload
                        finalize AckOk
                    )
                $ Stream.take 3 source
            commitAllOffsets OffsetCommit
    case secondSession of
        Left (_cs, err) -> assertFailure $ "second session failed: " <> show err
        Right () -> pure ()

    delivered <- readIORef redelivered
    assertBool ("expected ab-2 redelivery, saw " <> show delivered) ("ab-2" `elem` delivered)

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
            let finiteAdapter = upstream{source = Stream.take 4 upstream.source}
                handler Message{envelope} = do
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
        { topics = [env.testTopic]
        , pollTimeout = Timeout 500
        , batchSize = BatchSize 100
        , offsetReset = Earliest
        }

countPayload :: ByteString -> [ByteString] -> Int
countPayload target = length . filter (== target)
