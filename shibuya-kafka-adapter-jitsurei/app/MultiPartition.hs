{- | Produces keyed messages to a multi-partition topic and shows partition assignment.

Demonstrates partition-aware processing with keyed messages.

Usage:
  cabal run multi-partition
-}
module Main (main) where

import Control.Monad (forM_)
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
import Kafka.Effectful.Producer (
    flushProducer,
    produceMessage,
    runKafkaProducer,
 )
import Kafka.Effectful.Producer qualified as P
import Kafka.Producer.Types (ProducePartition (..), ProducerRecord (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Process (callCommand)

topic :: TopicName
topic = TopicName "multi-partition-demo"

broker :: BrokerAddress
broker = BrokerAddress "localhost:9092"

main :: IO ()
main = do
    TIO.putStrLn "[multi-partition] Creating topic with 3 partitions..."
    callCommand "rpk topic create multi-partition-demo -p 3 2>/dev/null || true"

    -- Produce keyed messages
    let keys = ["user-alice", "user-bob", "user-charlie", "user-dave", "user-eve", "user-frank"]
    TIO.putStrLn $ "[multi-partition] Producing " <> Text.pack (show (length keys)) <> " keyed messages..."
    result1 <- runEff . runError @KafkaError $ do
        runKafkaProducer (P.brokersList [broker]) $ do
            forM_ keys $ \key ->
                produceMessage
                    ProducerRecord
                        { prTopic = topic
                        , prPartition = UnassignedPartition
                        , prKey = Just key
                        , prValue = Just ("data-for-" <> key)
                        , prHeaders = mempty
                        }
            flushProducer
    case result1 of
        Left err -> error $ "Produce failed: " <> show err
        Right () -> pure ()

    -- Consume and print partition assignments
    TIO.putStrLn "[multi-partition] Consuming messages..."
    result2 <- runEff . runError @KafkaError $ do
        let props = brokersList [broker] <> groupId (ConsumerGroupId "multi-partition-group") <> noAutoOffsetStore
            sub = topics [topic] <> offsetReset Earliest
        runKafkaConsumer props sub $ do
            Adapter{source} <- kafkaAdapter (defaultConfig [topic])
            Stream.fold Fold.drain
                $ Stream.mapM
                    ( \(Ingested{envelope = Envelope{messageId = MessageId msgId, partition, cursor, payload}, ack = AckHandle finalize}) -> do
                        liftIO $ do
                            let partStr = maybe "?" (Text.pack . show) partition
                                cursorStr = case cursor of
                                    Just (CursorInt n) -> Text.pack (show n)
                                    _ -> "?"
                                payloadStr = maybe "<null>" (Text.pack . BS8.unpack) payload
                            TIO.putStrLn $
                                "  "
                                    <> msgId
                                    <> " | partition="
                                    <> partStr
                                    <> " | offset="
                                    <> cursorStr
                                    <> " | payload="
                                    <> payloadStr
                        finalize AckOk
                    )
                $ Stream.take (length keys) source
    case result2 of
        Left err -> putStrLn $ "Error: " <> show err
        Right () -> TIO.putStrLn "[multi-partition] Done."
