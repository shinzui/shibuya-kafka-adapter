{- | Minimal single-topic consumer.

Subscribes to "orders", prints each message's envelope, and AckOk's.
Demonstrates the simplest possible adapter wiring.

Usage:
  rpk topic create orders
  rpk topic produce orders --key "k1" <<< "hello world"
  cabal run basic-consumer
-}
module Main (main) where

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
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

main :: IO ()
main = do
    TIO.putStrLn "[basic-consumer] Starting..."
    result <- runEff . runError @KafkaError $ do
        let props = brokersList [BrokerAddress "localhost:9092"] <> groupId (ConsumerGroupId "basic-consumer-group") <> noAutoOffsetStore
            sub = topics [TopicName "orders"] <> offsetReset Earliest
        runKafkaConsumer props sub $ do
            Adapter{source} <- kafkaAdapter (defaultConfig [TopicName "orders"])
            Stream.fold Fold.drain $
                Stream.mapM
                    ( \(Ingested{envelope = Envelope{messageId = MessageId msgId, partition, cursor, payload}, ack = AckHandle finalize}) -> do
                        liftIO $ do
                            let payloadStr = maybe "<null>" (Text.pack . BS8.unpack) payload
                                partStr = maybe "?" (Text.pack . show) partition
                                cursorStr = case cursor of
                                    Just (CursorInt n) -> Text.pack (show n)
                                    Just (CursorText t) -> t
                                    Nothing -> "?"
                            TIO.putStrLn $
                                "[kafka:orders] messageId="
                                    <> msgId
                                    <> " partition="
                                    <> partStr
                                    <> " offset="
                                    <> cursorStr
                                    <> " payload="
                                    <> payloadStr
                        finalize AckOk
                        liftIO $ TIO.putStrLn "[kafka:orders] AckOk"
                    )
                    source
    case result of
        Left err -> putStrLn $ "Error: " <> show err
        Right () -> TIO.putStrLn "[basic-consumer] Done."
