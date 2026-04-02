{- | Internal implementation details for the Kafka adapter.
This module is not part of the public API and may change without notice.
-}
module Shibuya.Adapter.Kafka.Internal (
    -- * Stream Construction
    kafkaSource,

    -- * Ingested Construction
    mkIngested,

    -- * AckHandle Construction
    mkAckHandle,
)
where

import Data.ByteString (ByteString)
import Data.Function ((&))
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Kafka.Consumer.Types (ConsumerRecord (..))
import Kafka.Effectful.Consumer.Effect (
    KafkaConsumer,
    pausePartitions,
    pollMessageBatch,
    storeOffsetMessage,
 )
import Kafka.Types (KafkaError)
import Shibuya.Adapter.Kafka.Config (KafkaAdapterConfig (..))
import Shibuya.Adapter.Kafka.Convert (consumerRecordToEnvelope)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

{- | Create a stream of 'ConsumerRecord's by repeatedly polling the broker.

Calls 'pollMessageBatch' in a loop, filtering out @Left@ (error) entries
and flattening batches into individual records.
-}
kafkaSource ::
    (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) =>
    KafkaAdapterConfig ->
    Stream (Eff es) (ConsumerRecord (Maybe ByteString) (Maybe ByteString))
kafkaSource config =
    Stream.repeatM pollBatch
        & Stream.concatMap Stream.fromList
  where
    pollBatch = do
        results <- pollMessageBatch config.pollTimeout config.batchSize
        pure [cr | Right cr <- results]

{- | Create an 'AckHandle' for a single 'ConsumerRecord'.

Maps 'AckDecision' to Kafka operations:

* 'AckOk' -> 'storeOffsetMessage' (mark offset ready for commit)
* 'AckRetry' -> 'storeOffsetMessage' (Kafka cannot un-read; see Decision Log)
* 'AckDeadLetter' -> 'storeOffsetMessage' (DLQ deferred to future milestone)
* 'AckHalt' -> 'pausePartitions' (do NOT store offset; message will be re-consumed)
-}
mkAckHandle ::
    (KafkaConsumer :> es, Error KafkaError :> es) =>
    ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
    AckHandle es
mkAckHandle cr = AckHandle $ \case
    AckOk ->
        storeOffsetMessage cr
    AckRetry _ ->
        storeOffsetMessage cr
    AckDeadLetter _ ->
        storeOffsetMessage cr
    AckHalt _ ->
        pausePartitions [(cr.crTopic, cr.crPartition)]

{- | Combine conversion and ack handle to produce an 'Ingested'.

Lease is always 'Nothing' for Kafka (no visibility timeout mechanism).
-}
mkIngested ::
    (KafkaConsumer :> es, Error KafkaError :> es) =>
    ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
    Ingested es (Maybe ByteString)
mkIngested cr =
    Ingested
        { envelope = consumerRecordToEnvelope cr
        , ack = mkAckHandle cr
        , lease = Nothing
        }
