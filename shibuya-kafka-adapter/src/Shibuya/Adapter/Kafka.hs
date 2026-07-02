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

1. Messages are polled from Kafka in batches.
2. Each message is wrapped as an @Ingested@ value with an @AckHandle@.
3. On @AckOk@, the offset is stored locally; auto-commit or consumer close
   later flushes stored offsets to the broker.
4. On @AckRetry@, the offset is not stored. The adapter seeks the partition
   back to the failed message so Kafka can redeliver it.
5. On @AckDeadLetter@, the offset is stored after a loud stderr warning.
6. On @AckHalt@, the partition is paused and offset is not stored.

== Serial Operation Required

This adapter must be run with serial message processing. librdkafka stores the
highest offset per partition without gap tracking, so concurrent finalization
can commit past an earlier message that failed, halted, or requested retry.
The 'Adapter' value does not contain the processor concurrency policy, so this
is a caller contract rather than a runtime guard: do not use @Async@ or @Ahead@
processing with this adapter until a gap-tracking commit layer exists.

== Dead Letters Are Dropped

This adapter does not include a DLQ producer. @AckDeadLetter@ stores the
message offset so the consumer group moves on, emits a warning to stderr, and
makes the message unrecoverable from that consumer group's committed position.
Core tracing still records the dead-letter decision and reason on the
per-message span.

Kafka does not expose a per-message delivery counter through this consumer
API, so 'Shibuya.Core.Types.Envelope.attempt' is always 'Nothing'. Handlers
cannot safely cap retries by counting attempts from the envelope; use an
external store, or return @AckHalt@ to stop the stream.

== Fatal Error Propagation

Non-fatal Kafka errors (poll timeouts, partition EOFs, and the rest of the
non-fatal set defined by @hw-kafka-streamly@'s 'Kafka.Streamly.Stream.isFatal')
are filtered out of the poll stream. Any error that survives that filter is
fatal by construction (for example, an SSL handshake failure, an authentication
failure, or an invalid broker configuration) and terminates the stream by
throwing through the 'Effectful.Error.Static.Error' @KafkaError@ effect. The
caller observes the failure by receiving a @Left err@ from the
@runError \@KafkaError@ scope around 'Shibuya.App.runApp'.

== AckHalt Partition Pause Semantics

@AckHalt@ pauses the originating partition by calling @pausePartitions@ from
@kafka-effectful@ and the processor stops. Polling therefore stops. After
@max.poll.interval.ms@ (librdkafka default: 300000 ms, or 5 minutes) the broker
may evict this consumer from its group and rebalance the partition to another
member, which resumes from the last committed offset. A single-member group
simply stalls until restart. Paused state is session-local and does not outlive
the current consumer.

== Rebalance Callback Helper

'kafkaRebalanceHandler' is optional. Install it with
@Kafka.Consumer.setCallback (Kafka.Consumer.rebalanceCallback (kafkaRebalanceHandler state))@
before creating the consumer when you want stderr visibility into assignment
changes and eager cleanup of retry barriers for revoked partitions. Without it,
the seek barrier still self-heals when messages are finalized at or below the
barrier offset. Cooperative rebalance fencing of in-flight work is outside this
adapter's scope.
-}
module Shibuya.Adapter.Kafka (
    -- * Adapter
    kafkaAdapter,
    kafkaAdapterWith,
    KafkaAdapterState,
    newKafkaAdapterState,
    kafkaRebalanceHandler,

    -- * Configuration
    KafkaAdapterConfig (..),

    -- * Defaults
    defaultConfig,

    -- * Re-exports
    TopicName (..),
    BrokerAddress (..),
    ConsumerGroupId (..),
    OffsetCommit (..),
    Timeout (..),
    BatchSize (..),
    KafkaError,
)
where

import Control.Concurrent.STM (atomically, writeTVar)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef')
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, catchError, throwError)
import Kafka.Consumer (RdKafkaRespErrT (..))
import Kafka.Consumer.Types (ConsumerGroupId (..), OffsetCommit (..), RebalanceEvent (..))
import Kafka.Consumer.Types qualified as KC
import Kafka.Effectful.Consumer.Effect (KafkaConsumer, commitAllOffsets, subscription)
import Kafka.Types (BatchSize (..), BrokerAddress (..), KafkaError (..), PartitionId, Timeout (..), TopicName (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka.Config (KafkaAdapterConfig (..), defaultConfig)
import Shibuya.Adapter.Kafka.Internal (KafkaAdapterState (..), dropStaleRecords, ingestedStream, kafkaSource, mkIngested, newKafkaAdapterState)
import System.IO (hPutStrLn, stderr)

{- | Create a Kafka adapter with the given configuration.

The adapter operates within an existing 'KafkaConsumer' effect scope.
Consumer lifecycle (connection, group membership) is managed by
@runKafkaConsumer@ from kafka-effectful.

The adapter uses @noAutoOffsetStore@ with manual @storeOffsetMessage@ +
auto-commit for offset management. On shutdown, @commitAllOffsets@ flushes
offsets stored so far. Messages finalized during the drain window store offsets
after that explicit commit; let the surrounding @runKafkaConsumer@ scope end
normally after 'Shibuya.App.stopApp' returns so the consumer close path can
flush the final stored offsets under the same auto-commit mode.

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
    state <- liftIO newKafkaAdapterState
    kafkaAdapterWith state config

{- | Create a Kafka adapter using caller-owned adapter state.

Use this when the same @KafkaAdapterState@ must also be referenced by
'kafkaRebalanceHandler', which is installed in consumer properties before the
consumer is created.
-}
kafkaAdapterWith ::
    (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterState ->
    KafkaAdapterConfig ->
    Eff es (Adapter es (Maybe ByteString))
kafkaAdapterWith state config = do
    warnOnSubscriptionMismatch config
    let messageSource =
            ingestedStream (mkIngested state config) $
                dropStaleRecords state $
                    kafkaSource state config
    pure
        Adapter
            { adapterName = "kafka:" <> Text.intercalate "," (map unTopicName config.topics)
            , source = messageSource
            , shutdown = do
                liftIO $ atomically $ writeTVar state.shutdownVar True
                commitAllOffsets OffsetCommit
                    `catchError` \_ err -> case err of
                        KafkaResponseError RdKafkaRespErrNoOffset -> pure ()
                        _ -> throwError err
            }

warnOnSubscriptionMismatch ::
    (KafkaConsumer :> es, IOE :> es) =>
    KafkaAdapterConfig ->
    Eff es ()
warnOnSubscriptionMismatch config = do
    liveSubscription <- subscription
    let configured = Set.fromList config.topics
        subscribed = Set.fromList (map fst liveSubscription)
    if configured == subscribed
        then pure ()
        else
            liftIO $
                hPutStrLn stderr $
                    "[shibuya-kafka-adapter] WARNING: config topics differ from live Kafka subscription; configured="
                        <> show (Set.toList configured)
                        <> " subscribed="
                        <> show (Set.toList subscribed)

{- | Rebalance callback helper for caller-installed Kafka callbacks.

Install with 'Kafka.Consumer.setCallback' and
'Kafka.Consumer.rebalanceCallback' before creating the consumer. The callback
logs every rebalance event to stderr and clears pending retry barriers for
revoked partitions. It does not fence in-flight work.
-}
kafkaRebalanceHandler ::
    KafkaAdapterState ->
    KC.KafkaConsumer ->
    RebalanceEvent ->
    IO ()
kafkaRebalanceHandler state _consumer event = do
    hPutStrLn stderr $ "[shibuya-kafka-adapter] rebalance: " <> show event
    case event of
        RebalanceRevoke revoked ->
            clearRevokedBarriers revoked
        _ ->
            pure ()
  where
    clearRevokedBarriers :: [(TopicName, PartitionId)] -> IO ()
    clearRevokedBarriers revoked =
        atomicModifyIORef' state.seekBarrier $ \barriers ->
            (foldr Map.delete barriers revoked, ())
