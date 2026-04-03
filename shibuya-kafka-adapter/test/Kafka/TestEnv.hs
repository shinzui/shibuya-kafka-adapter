-- | Test environment helpers for Kafka integration tests.
module Kafka.TestEnv (
    -- * Test Environment
    TestEnv (..),
    withTestEnv,

    -- * Producing
    produceMessages,
    produceKeyedMessages,

    -- * Consuming via Adapter
    consumeN,

    -- * Topic Management
    createTopic,
    createTopicWithPartitions,
)
where

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runError)
import Kafka.Consumer.ConsumerProperties (ConsumerProperties)
import Kafka.Consumer.Subscription (Subscription)
import Kafka.Consumer.Types (ConsumerGroupId (..), OffsetReset (..))
import Kafka.Effectful.Consumer (
    KafkaConsumer,
    brokersList,
    groupId,
    noAutoOffsetStore,
    offsetReset,
    runKafkaConsumer,
    topics,
 )
import Kafka.Effectful.Consumer.Effect (commitAllOffsets)
import Kafka.Effectful.Producer (
    flushProducer,
    produceMessage,
    runKafkaProducer,
 )
import Kafka.Effectful.Producer qualified as P
import Kafka.Producer.ProducerProperties (ProducerProperties)
import Kafka.Producer.Types (ProducePartition (..), ProducerRecord (..))
import Kafka.Types (
    BatchSize (..),
    BrokerAddress (..),
    KafkaError,
    Timeout (..),
    TopicName (..),
 )
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (KafkaAdapterConfig (..), kafkaAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Process (callCommand)
import System.Random (randomRIO)

-- | Test environment with isolated topic and group.
data TestEnv = TestEnv
    { testBroker :: !BrokerAddress
    , testTopic :: !TopicName
    , testGroupId :: !ConsumerGroupId
    , testPrefix :: !String
    }

-- | Create a test environment with a random prefix for isolation.
withTestEnv :: (TestEnv -> IO a) -> IO a
withTestEnv f = do
    prefix <- randomPrefix
    let env =
            TestEnv
                { testBroker = BrokerAddress "localhost:9092"
                , testTopic = TopicName (Text.pack (prefix <> "-topic"))
                , testGroupId = ConsumerGroupId (Text.pack (prefix <> "-group"))
                , testPrefix = prefix
                }
    f env

-- | Generate a random 10-character alphanumeric prefix.
randomPrefix :: IO String
randomPrefix = do
    let chars = ['a' .. 'z'] ++ ['0' .. '9']
    mapM (\_ -> do i <- randomRIO (0, length chars - 1); pure (chars !! i)) [1 .. 10 :: Int]

-- | Create a topic with 1 partition via rpk.
createTopic :: TestEnv -> IO ()
createTopic env = createTopicWithPartitions env 1

-- | Create a topic with the specified number of partitions via rpk.
createTopicWithPartitions :: TestEnv -> Int -> IO ()
createTopicWithPartitions env n =
    callCommand $
        "rpk topic create "
            <> Text.unpack (unTopicName env.testTopic)
            <> " -p "
            <> show n
            <> " 2>/dev/null || true"

-- | Build consumer properties for testing.
mkConsumerProps :: TestEnv -> ConsumerProperties
mkConsumerProps env =
    brokersList [env.testBroker]
        <> groupId env.testGroupId
        <> noAutoOffsetStore

-- | Build producer properties for testing.
mkProducerProps :: TestEnv -> ProducerProperties
mkProducerProps env =
    P.brokersList [env.testBroker]

-- | Build subscription for testing.
mkSubscription :: TestEnv -> Subscription
mkSubscription env =
    topics [env.testTopic]
        <> offsetReset Earliest

-- | Produce messages with the given payloads to the test topic.
produceMessages :: TestEnv -> [ByteString] -> IO ()
produceMessages env payloads = do
    result <- runEff . runError @KafkaError $ do
        runKafkaProducer (mkProducerProps env) $ do
            forM_ payloads $ \payload ->
                produceMessage
                    ProducerRecord
                        { prTopic = env.testTopic
                        , prPartition = UnassignedPartition
                        , prKey = Nothing
                        , prValue = Just payload
                        , prHeaders = mempty
                        }
            flushProducer
    case result of
        Left err -> error $ "Failed to produce: " <> show err
        Right () -> pure ()

-- | Produce keyed messages to the test topic.
produceKeyedMessages :: TestEnv -> [(ByteString, ByteString)] -> IO ()
produceKeyedMessages env pairs = do
    result <- runEff . runError @KafkaError $ do
        runKafkaProducer (mkProducerProps env) $ do
            forM_ pairs $ \(key, payload) ->
                produceMessage
                    ProducerRecord
                        { prTopic = env.testTopic
                        , prPartition = UnassignedPartition
                        , prKey = Just key
                        , prValue = Just payload
                        , prHeaders = mempty
                        }
            flushProducer
    case result of
        Left err -> error $ "Failed to produce: " <> show err
        Right () -> pure ()

-- | Consume N messages from the test topic via the adapter, applying the given ack decision.
consumeN ::
    TestEnv ->
    Int ->
    AckDecision ->
    IO [Envelope (Maybe ByteString)]
consumeN env n ackDecision = do
    ref <- newIORef ([] :: [Envelope (Maybe ByteString)])
    result <- runEff . runError @KafkaError $ do
        runKafkaConsumer (mkConsumerProps env) (mkSubscription env) $ do
            let config =
                    KafkaAdapterConfig
                        { topics = [env.testTopic]
                        , pollTimeout = Timeout 5000
                        , batchSize = BatchSize 100
                        , offsetReset = Earliest
                        }
            Adapter{source} <- kafkaAdapter config
            Stream.fold Fold.drain
                $ Stream.mapM
                    ( \(Ingested{envelope, ack = AckHandle finalize}) -> do
                        liftIO $ modifyIORef' ref (envelope :)
                        finalize ackDecision
                    )
                $ Stream.take n source
            commitAllOffsets OffsetCommit
    case result of
        Left err -> error $ "Failed to consume: " <> show err
        Right () -> pure ()
    reverse <$> readIORef ref
