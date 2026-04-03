module Shibuya.Adapter.Kafka.IntegrationTest (tests) where

import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (modifyIORef', newIORef, readIORef)
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
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
    testGroup
        "Integration"
        [ testCase "Basic produce-consume" testBasicProduceConsume
        , testCase "Offset commit verification" testOffsetCommit
        , testCase "Multi-partition distribution" testMultiPartition
        , testCase "Batch polling" testBatchPolling
        , testCase "Graceful shutdown" testGracefulShutdown
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
    let Envelope{messageId = MessageId firstIdText} : _ = envelopes
    assertBool "messageId contains topic" (Text.isPrefixOf (unTopicName env.testTopic) firstIdText)

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
    ref <- newIORef (0 :: Int)
    result <- runEff . runError @KafkaError $ do
        let props = brokersList [env.testBroker] <> groupId env.testGroupId <> noAutoOffsetStore
            sub = topics [env.testTopic] <> offsetReset Earliest
        runKafkaConsumer props sub $ do
            let config =
                    KafkaAdapterConfig
                        { topics = [env.testTopic]
                        , pollTimeout = Timeout 3000
                        , batchSize = BatchSize 100
                        , offsetReset = Earliest
                        }
            Adapter{source} <- kafkaAdapter config
            -- Try to consume with a short timeout - should get 0 messages
            Stream.fold Fold.drain
                $ Stream.mapM
                    (\_ -> liftIO $ modifyIORef' ref (+ 1))
                $ Stream.take 1
                $ Stream.takeWhile (\_ -> False) source
    case result of
        Left err -> error $ "Failed: " <> show err
        Right () -> pure ()
    count <- readIORef ref
    assertEqual "no re-delivery" 0 count

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
