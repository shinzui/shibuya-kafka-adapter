{- | Internal implementation details for the Kafka adapter.
This module is not part of the public API and may change without notice.
-}
module Shibuya.Adapter.Kafka.Internal (
    -- * Adapter State
    KafkaAdapterState (..),
    newKafkaAdapterState,
    withConsumerLock,

    -- * Stream Construction
    kafkaSource,
    dropStaleRecords,
    ingestedStream,

    -- * Ingested Construction
    mkIngested,

    -- * AckHandle Construction
    mkAckHandle,
)
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, newTVarIO, readTVarIO)
import Data.ByteString (ByteString)
import Data.Function ((&))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Time.Clock (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import Effectful qualified
import Effectful.Error.Static (Error, catchError, throwError)
import Effectful.Exception qualified as Exception
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), PartitionOffset (..), TopicPartition (..))
import Kafka.Effectful.Consumer.Effect (
    KafkaConsumer,
    pausePartitions,
    pollMessageBatch,
    seekPartitions,
    storeOffsetMessage,
 )
import Kafka.Streamly.Stream (isFatal, skipNonFatal)
import Kafka.Types (KafkaError, PartitionId, Timeout (..), TopicName)
import Shibuya.Adapter.Kafka.Config (KafkaAdapterConfig (..))
import Shibuya.Adapter.Kafka.Convert (consumerRecordToEnvelope)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested)
import Shibuya.Core.Ingested qualified as Core
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import System.IO (hPutStrLn, stderr)

type PartitionKey = (TopicName, PartitionId)

-- | Mutable state shared by the source stream and ack handles.
data KafkaAdapterState = KafkaAdapterState
    { shutdownVar :: !(TVar Bool)
    , seekBarrier :: !(IORef (Map PartitionKey Offset))
    , fatalError :: !(IORef (Maybe KafkaError))
    , consumerLock :: !(MVar ())
    {- ^ Serializes every librdkafka consumer operation. Under
    'Shibuya.App.runApp' the consumer handle is shared between the ingester
    thread (which polls) and the processor thread (which seeks, stores,
    pauses, and commits during finalize). Running @rd_kafka_consume_batch_queue@
    concurrently with a seek/store on the same handle corrupts librdkafka's
    internal fetch queue and crashes with a native SIGSEGV, so every consumer
    call is wrapped in this mutex. Each poll is additionally bounded (see
    @maxPollHoldMillis@) so the lock is released frequently and finalize is
    never starved.
    -}
    }

{- | Allocate mutable state shared by the Kafka source, ack handles, and
optional rebalance callback.
-}
newKafkaAdapterState :: IO KafkaAdapterState
newKafkaAdapterState =
    KafkaAdapterState
        <$> newTVarIO False
        <*> newIORef Map.empty
        <*> newIORef Nothing
        <*> newMVar ()

{- | Run a librdkafka consumer operation while holding the shared consumer
lock, guaranteeing no other consumer call runs concurrently on the same
handle. See 'consumerLock' for why this is mandatory. The lock is always
released, including when the action throws through the 'Error' @KafkaError@
effect.
-}
withConsumerLock :: (IOE :> es) => KafkaAdapterState -> Eff es a -> Eff es a
withConsumerLock state =
    Exception.bracket_
        (Effectful.liftIO (takeMVar state.consumerLock))
        (Effectful.liftIO (putMVar state.consumerLock ()))

{- | Upper bound (milliseconds) on how long any single blocking consumer call
may hold the consumer lock. Every consumer call runs under 'consumerLock' so
the poll never races a concurrent seek/store on the shared handle (see
'consumerLock'). A call that blocks for its whole timeout — an empty poll, or a
seek that cannot complete — would then hold the lock for that long and starve
(and, under GHC's deadlock detector, wedge) the finalize path that must seek to
redeliver a retried message. Capping the poll and seek timeouts at this value
keeps the lock available roughly every @maxPollHoldMillis@ so finalize can
interleave and the ingester promptly re-polls to observe redelivered records.
It also bounds shutdown latency. The cap leaves ample headroom over a healthy
seek (which acknowledges in single-digit milliseconds), so it only bites when a
call is genuinely stuck — in which case surfacing it fast (via the ack path's
bounded retry and fatal slot) is the desired behavior.
-}
maxPollHoldMillis :: Int
maxPollHoldMillis = 100

{- | Cap a caller-supplied timeout at 'maxPollHoldMillis' so a single blocking
consumer call cannot hold the consumer lock longer than that. Applied to both
the poll and the retry seek.
-}
boundedLockTimeout :: Timeout -> Timeout
boundedLockTimeout t = Timeout (min (unTimeout t) maxPollHoldMillis)

{- | Create a stream of 'ConsumerRecord's by repeatedly polling the broker.

Calls 'pollMessageBatch' in a loop under 'consumerLock', preserving errors as
@Left@ values. Each poll uses a timeout capped at @maxPollHoldMillis@ so the
lock stays available to the finalize path (which seeks, stores, pauses, and
commits). Non-fatal errors (timeouts, partition EOF, etc.) are filtered out
via 'skipNonFatal' from hw-kafka-streamly. Fatal errors are preserved for
upstream handling; a fatal error recorded by the ack path (see 'fatalError')
terminates the stream.
-}
kafkaSource ::
    (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterState ->
    KafkaAdapterConfig ->
    Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))
kafkaSource state config =
    skipNonFatal $
        Stream.unfoldrM step ()
            & Stream.concatMap Stream.fromList
  where
    pollT = boundedLockTimeout config.pollTimeout
    step () = do
        mbFatal <- Effectful.liftIO $ readIORef state.fatalError
        case mbFatal of
            Just err -> throwError err
            Nothing -> pure ()
        isShutdown <- Effectful.liftIO $ readTVarIO state.shutdownVar
        if isShutdown
            then pure Nothing
            else do
                batch <- withConsumerLock state (pollMessageBatch pollT config.batchSize)
                pure (Just (batch, ()))

-- | Drop records already buffered above a pending retry barrier.
dropStaleRecords ::
    (IOE :> es) =>
    KafkaAdapterState ->
    Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))) ->
    Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))
dropStaleRecords state =
    Stream.filterM $ \case
        Left _ -> pure True
        Right cr -> do
            barriers <- Effectful.liftIO $ readIORef state.seekBarrier
            pure $ case Map.lookup (partitionKey cr) barriers of
                Nothing -> True
                Just barrierOff -> cr.crOffset <= barrierOff

{- | Create an 'AckHandle' for a single 'ConsumerRecord'.

Maps 'AckDecision' to Kafka operations:

* 'AckOk' -> 'storeOffsetMessage' (mark offset ready for commit)
* 'AckRetry' -> record seek barrier and seek partition back to the failed offset
* 'AckDeadLetter' -> warn to stderr, then 'storeOffsetMessage' (DLQ deferred)
* 'AckHalt' -> 'pausePartitions' (do NOT store offset; message will be re-consumed)
-}
mkAckHandle ::
    (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterState ->
    KafkaAdapterConfig ->
    ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
    AckHandle es
mkAckHandle state config cr = AckHandle $ \case
    AckOk ->
        ackAttempt state (storeGuarded state cr)
    AckRetry (RetryDelay delay) -> do
        Effectful.liftIO $ delayRetry delay
        Effectful.liftIO $
            atomicModifyIORef' state.seekBarrier $ \barriers ->
                (Map.insert (partitionKey cr) cr.crOffset barriers, ())
        ackAttempt state $
            withConsumerLock state $
                seekPartitions
                    [ TopicPartition
                        { tpTopicName = cr.crTopic
                        , tpPartition = cr.crPartition
                        , tpOffset = PartitionOffset (unOffset cr.crOffset)
                        }
                    ]
                    (boundedLockTimeout config.pollTimeout)
    AckDeadLetter reason -> do
        Effectful.liftIO $
            hPutStrLn stderr $
                "[shibuya-kafka-adapter] WARNING: dead-lettered message DROPPED (no DLQ producer): "
                    <> show (cr.crTopic, cr.crPartition, cr.crOffset)
                    <> " reason="
                    <> show reason
        ackAttempt state (storeGuarded state cr)
    AckHalt _ ->
        ackAttempt state (withConsumerLock state (pausePartitions [(cr.crTopic, cr.crPartition)]))

ackAttempt ::
    (Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterState ->
    Eff es () ->
    Eff es ()
ackAttempt state action = go (1 :: Int)
  where
    maxAttempts = 3
    retryDelayMicros = 50000

    go attempt =
        action `catchError` \_ err ->
            if isFatal err || attempt >= maxAttempts
                then Effectful.liftIO $ recordFatalError state err
                else do
                    Effectful.liftIO $ threadDelay retryDelayMicros
                    go (attempt + 1)

recordFatalError :: KafkaAdapterState -> KafkaError -> IO ()
recordFatalError state err =
    atomicModifyIORef' state.fatalError $ \case
        Just existing -> (Just existing, ())
        Nothing -> (Just err, ())

storeGuarded ::
    (KafkaConsumer :> es, IOE :> es) =>
    KafkaAdapterState ->
    ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
    Eff es ()
storeGuarded state cr = do
    shouldStore <-
        Effectful.liftIO $
            atomicModifyIORef' state.seekBarrier $ \barriers ->
                case Map.lookup (partitionKey cr) barriers of
                    Nothing -> (barriers, True)
                    Just barrierOff
                        | cr.crOffset <= barrierOff -> (Map.delete (partitionKey cr) barriers, True)
                        | otherwise -> (barriers, False)
    if shouldStore then withConsumerLock state (storeOffsetMessage cr) else pure ()

partitionKey :: ConsumerRecord k v -> PartitionKey
partitionKey cr = (cr.crTopic, cr.crPartition)

delayRetry :: NominalDiffTime -> IO ()
delayRetry delay
    | delay <= 0 = pure ()
    | otherwise = threadDelay (floor (realToFrac delay * (1000000 :: Double)))

{- | Combine conversion and ack handle to produce an 'Ingested'.

Lease is always 'Nothing' for Kafka (no visibility timeout mechanism).
-}
mkIngested ::
    (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterState ->
    KafkaAdapterConfig ->
    ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
    Ingested es (Maybe ByteString)
mkIngested state config cr =
    Core.mkIngested
        (consumerRecordToEnvelope cr)
        (mkAckHandle state config cr)

{- | Transform a poll stream of @Either KafkaError ConsumerRecord@ into a
stream of 'Ingested'.

A @Right cr@ is wrapped via the supplied builder (in production,
'mkIngested'). A @Left err@ that reaches this stage is fatal by construction
— 'Kafka.Streamly.Stream.skipNonFatal' has already dropped non-fatal errors
— and is thrown via the 'Error' @KafkaError@ effect, terminating the stream.

Parameterizing over the builder function keeps this helper free of the
'KafkaConsumer' constraint, so it can be exercised in a unit test that
injects a synthetic @Left@ without standing up a real consumer.
-}
ingestedStream ::
    (Error KafkaError :> es) =>
    (ConsumerRecord (Maybe ByteString) (Maybe ByteString) -> Ingested es (Maybe ByteString)) ->
    Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))) ->
    Stream (Eff es) (Ingested es (Maybe ByteString))
ingestedStream mkI =
    Stream.mapMaybeM $ \case
        Right cr -> pure (Just (mkI cr))
        Left err -> throwError err
