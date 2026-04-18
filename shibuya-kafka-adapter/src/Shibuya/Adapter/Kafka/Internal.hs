{- | Internal implementation details for the Kafka adapter.
This module is not part of the public API and may change without notice.
-}
module Shibuya.Adapter.Kafka.Internal (
    -- * Stream Construction
    kafkaSource,
    ingestedStream,

    -- * Ingested Construction
    mkIngested,

    -- * AckHandle Construction
    mkAckHandle,
)
where

import Data.ByteString (ByteString)
import Data.Function ((&))
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, throwError)
import Kafka.Consumer.Types (ConsumerRecord (..))
import Kafka.Effectful.Consumer.Effect (
    KafkaConsumer,
    pausePartitions,
    pollMessageBatch,
    storeOffsetMessage,
 )
import Kafka.Streamly.Source (skipNonFatal)
import Kafka.Types (KafkaError)
import Shibuya.Adapter.Kafka.Config (KafkaAdapterConfig (..))
import Shibuya.Adapter.Kafka.Convert (consumerRecordToEnvelope)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

{- | Create a stream of 'ConsumerRecord's by repeatedly polling the broker.

Calls 'pollMessageBatch' in a loop, preserving errors as @Left@ values.
Non-fatal errors (timeouts, partition EOF, etc.) are filtered out via
'skipNonFatal' from hw-kafka-streamly. Fatal errors are preserved for
upstream handling.
-}
kafkaSource ::
    (KafkaConsumer :> es, IOE :> es) =>
    KafkaAdapterConfig ->
    Stream (Eff es) (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))
kafkaSource config =
    skipNonFatal $
        Stream.repeatM pollBatch
            & Stream.concatMap Stream.fromList
  where
    pollBatch =
        pollMessageBatch config.pollTimeout config.batchSize

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

{- | Transform a poll stream of @Either KafkaError ConsumerRecord@ into a
stream of 'Ingested'.

A @Right cr@ is wrapped via the supplied builder (in production,
'mkIngested'). A @Left err@ that reaches this stage is fatal by construction
— 'Kafka.Streamly.Source.skipNonFatal' has already dropped non-fatal errors
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
