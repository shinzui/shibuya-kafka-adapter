{- | Two adapters consuming from different topics.

Demonstrates multiple adapters under independent consumer sessions.
Each topic has its own consumer group and handler.

Usage:
  rpk topic create orders events
  rpk topic produce orders <<< "order-1"
  rpk topic produce events <<< "event-1"
  cabal run multi-topic
-}
module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
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
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

main :: IO ()
main = do
    TIO.putStrLn "[multi-topic] Starting two consumers..."
    done1 <- newEmptyMVar
    done2 <- newEmptyMVar

    _ <- forkIO $ consumeTopic "orders" "multi-topic-orders" >> putMVar done1 ()
    _ <- forkIO $ consumeTopic "events" "multi-topic-events" >> putMVar done2 ()

    takeMVar done1
    takeMVar done2
    TIO.putStrLn "[multi-topic] Done."

consumeTopic :: Text -> Text -> IO ()
consumeTopic topicName grpId = do
    let topic = TopicName topicName
    result <- runEff . runError @KafkaError $ do
        let props = brokersList [BrokerAddress "localhost:9092"] <> groupId (ConsumerGroupId grpId) <> noAutoOffsetStore
            sub = topics [topic] <> offsetReset Earliest
        runKafkaConsumer props sub $ do
            Adapter{source} <- kafkaAdapter (defaultConfig [topic])
            Stream.fold Fold.drain
                $ Stream.mapM
                    ( \(Ingested{envelope = Envelope{messageId = MessageId msgId, payload}, ack = AckHandle finalize}) -> do
                        liftIO $
                            TIO.putStrLn $
                                "[kafka:" <> topicName <> "] " <> msgId <> " payload=" <> maybe "<null>" (Text.pack . BS8.unpack) payload
                        finalize AckOk
                    )
                $ Stream.take 5 source
    case result of
        Left err -> putStrLn $ "[" <> show topicName <> "] Error: " <> show err
        Right () -> TIO.putStrLn $ "[kafka:" <> topicName <> "] Consumer finished."
