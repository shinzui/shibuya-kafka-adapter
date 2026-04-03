{- | Demonstrates offset commit lifecycle and restart behavior.

1. Produces N messages
2. Consumes all N, AckOk each, shuts down (flushing offsets)
3. Restarts consumer in same group
4. Verifies no re-delivery

Usage:
  cabal run offset-management
-}
module Main (main) where

import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (OffsetReset (..))
import Kafka.Effectful.Consumer (
    BrokerAddress (..),
    ConsumerGroupId (..),
    KafkaError,
    TopicName (..),
    brokersList,
    groupId,
    noAutoOffsetStore,
    offsetReset,
    runKafkaConsumer,
    topics,
 )
import Kafka.Effectful.Consumer.Effect (pollMessageBatch)
import Kafka.Effectful.Producer (
    flushProducer,
    produceMessage,
    runKafkaProducer,
 )
import Kafka.Effectful.Producer qualified as P
import Kafka.Producer.Types (ProducePartition (..), ProducerRecord (..))
import Kafka.Types (BatchSize (..), Timeout (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Process (callCommand)

topic :: TopicName
topic = TopicName "offset-mgmt-demo"

grp :: ConsumerGroupId
grp = ConsumerGroupId "offset-mgmt-group"

broker :: BrokerAddress
broker = BrokerAddress "localhost:9092"

main :: IO ()
main = do
    TIO.putStrLn "[offset-management] Creating topic..."
    callCommand "rpk topic create offset-mgmt-demo -p 1 2>/dev/null || true"

    -- Step 1: Produce messages
    TIO.putStrLn "[offset-management] Producing 5 messages..."
    result1 <- runEff . runError @KafkaError $ do
        runKafkaProducer (P.brokersList [broker]) $ do
            forM_ [1 .. 5 :: Int] $ \i ->
                produceMessage
                    ProducerRecord
                        { prTopic = topic
                        , prPartition = UnassignedPartition
                        , prKey = Nothing
                        , prValue = Just (BS8.pack ("msg-" <> show i))
                        , prHeaders = mempty
                        }
            flushProducer
    case result1 of
        Left err -> error $ "Produce failed: " <> show err
        Right () -> pure ()

    -- Step 2: Consume all, AckOk, shutdown
    TIO.putStrLn "[offset-management] Consuming 5 messages (first pass)..."
    result2 <- runEff . runError @KafkaError $ do
        let props = brokersList [broker] <> groupId grp <> noAutoOffsetStore
            sub = topics [topic] <> offsetReset Earliest
        runKafkaConsumer props sub $ do
            Adapter{source, shutdown} <- kafkaAdapter (defaultConfig [topic])
            Stream.fold Fold.drain
                $ Stream.mapM
                    ( \(Ingested{envelope = Envelope{messageId = MessageId msgId, payload}, ack = AckHandle finalize}) -> do
                        liftIO $ TIO.putStrLn $ "  Consumed: " <> msgId <> " = " <> maybe "<null>" (Text.pack . BS8.unpack) payload
                        finalize AckOk
                    )
                $ Stream.take 5 source
            shutdown
    case result2 of
        Left err -> error $ "First consume failed: " <> show err
        Right () -> pure ()

    -- Step 3: Restart consumer in same group, verify no re-delivery
    TIO.putStrLn "[offset-management] Restarting consumer (second pass)..."
    result3 <- runEff . runError @KafkaError $ do
        let props = brokersList [broker] <> groupId grp <> noAutoOffsetStore
            sub = topics [topic] <> offsetReset Earliest
        runKafkaConsumer props sub $ do
            -- Poll a few times to allow group join + rebalance
            allResults <- forM [1 .. 3 :: Int] $ \_ -> do
                results <- pollMessageBatch (Timeout 3000) (BatchSize 100)
                pure [cr | Right cr <- results]
            let count = length (concat allResults)
            liftIO $ do
                TIO.putStrLn $ "[offset-management] Re-delivered messages: " <> Text.pack (show count)
                if count == 0
                    then TIO.putStrLn "[offset-management] SUCCESS: No re-delivery after offset commit."
                    else TIO.putStrLn "[offset-management] UNEXPECTED: Messages were re-delivered!"
    case result3 of
        Left err -> error $ "Second consume failed: " <> show err
        Right () -> pure ()
