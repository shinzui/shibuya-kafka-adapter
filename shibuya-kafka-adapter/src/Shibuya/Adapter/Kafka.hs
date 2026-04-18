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

== Fatal Error Propagation

Non-fatal Kafka errors (poll timeouts, partition EOFs, and the rest of the
non-fatal set defined by @hw-kafka-streamly@'s 'Kafka.Streamly.Source.isFatal')
are filtered out of the poll stream. Any error that survives that filter is
fatal by construction (for example, an SSL handshake failure, an authentication
failure, or an invalid broker configuration) and terminates the stream by
throwing through the 'Effectful.Error.Static.Error' @KafkaError@ effect. The
caller observes the failure by receiving a @Left err@ from the
@runError \@KafkaError@ scope around 'Shibuya.App.runApp'.

== AckHalt Partition Pause Semantics

'AckHalt' pauses the originating partition by calling @pausePartitions@ from
@kafka-effectful@. The partition is not automatically resumed within the
current consumer session — the adapter has no side channel for a handler to
request resumption. A new consumer session (a new call to @runKafkaConsumer@)
starts with no paused partitions, so resumption happens implicitly on restart
but not mid-session. If mid-session resume is required, the caller must
manage that explicitly outside the 'Adapter' surface.
-}
module Shibuya.Adapter.Kafka (
    -- * Adapter
    kafkaAdapter,

    -- * Configuration
    KafkaAdapterConfig (..),

    -- * Defaults
    defaultConfig,

    -- * Re-exports
    TopicName (..),
    BrokerAddress (..),
    ConsumerGroupId (..),
    OffsetReset (..),
    OffsetCommit (..),
    Timeout (..),
    BatchSize (..),
    KafkaError,
)
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Kafka.Consumer.Types (ConsumerGroupId (..), OffsetCommit (..), OffsetReset (..))
import Kafka.Effectful.Consumer.Effect (KafkaConsumer, commitAllOffsets)
import Kafka.Types (BatchSize (..), BrokerAddress (..), KafkaError, Timeout (..), TopicName (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka.Config (KafkaAdapterConfig (..), defaultConfig)
import Shibuya.Adapter.Kafka.Internal (ingestedStream, kafkaSource, mkIngested)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

{- | Create a Kafka adapter with the given configuration.

The adapter operates within an existing 'KafkaConsumer' effect scope.
Consumer lifecycle (connection, group membership) is managed by
@runKafkaConsumer@ from kafka-effectful.

The adapter uses @noAutoOffsetStore@ with manual @storeOffsetMessage@ +
auto-commit for offset management. On shutdown, @commitAllOffsets@ flushes
any stored offsets to the broker.

The returned 'Shibuya.Adapter.Adapter.shutdown' action must be invoked while
the 'KafkaConsumer' effect is still in scope. Invoking it after
@runKafkaConsumer@ has returned will throw a 'KafkaError' from
@commitAllOffsets@ against a consumer that is no longer valid. This is a
caller-side invariant; the adapter does not catch the error.
-}
kafkaAdapter ::
    (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterConfig ->
    Eff es (Adapter es (Maybe ByteString))
kafkaAdapter config = do
    shutdownVar <- liftIO $ newTVarIO False
    let messageSource = ingestedStream mkIngested (kafkaSource config)
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
