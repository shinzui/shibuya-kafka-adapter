{- | Kafka adapter for the Shibuya queue processing framework.

This adapter integrates with Apache Kafka via
[kafka-effectful](https://github.com/shinzui/kafka-effectful) and
[hw-kafka-client](https://github.com/haskell-works/hw-kafka-client).

== Example Usage

@
import Shibuya.App (runApp, mkProcessor)
import Shibuya.Adapter.Kafka (kafkaAdapter, defaultConfig)
import Kafka.Effectful.Consumer (runKafkaConsumer)
import Kafka.Consumer (brokersList, groupId, noAutoOffsetStore)

main :: IO ()
main = runEff
  . runError \@KafkaError
  . runKafkaConsumer props sub
  $ do
      adapter <- kafkaAdapter (defaultConfig [TopicName \"orders\"])
      result <- runApp IgnoreFailures 100
        [ (ProcessorId \"orders\", mkProcessor adapter myHandler)
        ]
      ...
@

== Message Lifecycle

1. Messages are polled from Kafka in batches
2. Each message is wrapped as an 'Ingested' with an 'AckHandle'
3. On 'AckOk', the offset is stored (auto-commit flushes to broker)
4. On 'AckRetry', the offset is stored (Kafka cannot un-read messages)
5. On 'AckDeadLetter', the offset is stored (DLQ production in future milestone)
6. On 'AckHalt', the partition is paused and offset is NOT stored
-}
module Shibuya.Adapter.Kafka (
    -- * Adapter
    kafkaAdapter,

    -- * Configuration
    KafkaAdapterConfig (..),

    -- * Defaults
    defaultConfig,

    -- * Re-exports from kafka-effectful / hw-kafka-client
    module Kafka.Types,
    module Kafka.Consumer.Types,
)
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Kafka.Consumer.Types (OffsetCommit (..), OffsetReset (..))
import Kafka.Effectful.Consumer.Effect (KafkaConsumer, commitAllOffsets)
import Kafka.Types (KafkaError, TopicName (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka.Config (KafkaAdapterConfig (..), defaultConfig)
import Shibuya.Adapter.Kafka.Internal (kafkaSource, mkIngested)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

{- | Create a Kafka adapter with the given configuration.

The adapter operates within an existing 'KafkaConsumer' effect scope.
Consumer lifecycle (connection, group membership) is managed by
@runKafkaConsumer@ from kafka-effectful.

The adapter uses @noAutoOffsetStore@ with manual @storeOffsetMessage@ +
auto-commit for offset management. On shutdown, @commitAllOffsets@ flushes
any stored offsets to the broker.
-}
kafkaAdapter ::
    (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterConfig ->
    Eff es (Adapter es (Maybe ByteString))
kafkaAdapter config = do
    shutdownVar <- liftIO $ newTVarIO False
    let messageSource =
            Stream.mapM (pure . mkIngested) (kafkaSource config)
    pure
        Adapter
            { adapterName = "kafka:" <> Text.intercalate "," (map unTopicName config.topics)
            , source = takeUntilShutdown shutdownVar messageSource
            , shutdown = do
                liftIO $ atomically $ writeTVar shutdownVar True
                commitAllOffsets OffsetCommit
            }

-- | Take from stream until shutdown signal is set.
takeUntilShutdown ::
    (IOE :> es) =>
    TVar Bool ->
    Stream (Eff es) a ->
    Stream (Eff es) a
takeUntilShutdown shutdownVar =
    Stream.takeWhileM $ \_ -> do
        isShutdown <- liftIO $ readTVarIO shutdownVar
        pure (not isShutdown)
