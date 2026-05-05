-- | Type conversions between Kafka and Shibuya types.
module Shibuya.Adapter.Kafka.Convert (
    -- * Message Conversion
    consumerRecordToEnvelope,

    -- * Trace Context
    extractTraceHeaders,

    -- * Timestamp Conversion
    timestampToUTCTime,
)
where

import Data.ByteString (ByteString)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), Timestamp (..))
import Kafka.Types (
    Headers,
    Millis (..),
    PartitionId (..),
    TopicName (..),
    headersToList,
 )
import OpenTelemetry.Attributes (Attribute, toAttribute, unkey)
import OpenTelemetry.SemanticConventions qualified as Sem
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..), TraceHeaders)

{- | Convert a Kafka 'ConsumerRecord' to a Shibuya 'Envelope'.

Field mapping:

* @messageId@: @\"{topic}-{partition}-{offset}\"@ (globally unique within a cluster)
* @cursor@: @CursorInt offset@
* @partition@: @Just (show partitionId)@
* @enqueuedAt@: converted from Kafka timestamp if available
* @traceContext@: extracted from @traceparent@/@tracestate@ headers
* @attempt@: 'Nothing' (Kafka does not expose a redelivery counter)
* @attributes@: kafka-typed OTel attributes (system, partition,
  offset). The framework's @processOne@ adds these to its
  Consumer-kind span and the @messaging.system@ key overrides
  the framework default of @"shibuya"@. Other @messaging.*@
  attributes (destination.name, operation, message.id) are
  populated by the framework from the @ProcessorId@/@MessageId@
  pair and are not duplicated here.
* @payload@: the @crValue@ field (@Maybe ByteString@)
-}
consumerRecordToEnvelope ::
    ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
    Envelope (Maybe ByteString)
consumerRecordToEnvelope cr =
    Envelope
        { messageId = mkMessageId cr.crTopic cr.crPartition cr.crOffset
        , cursor = Just (CursorInt (fromIntegral (unOffset cr.crOffset)))
        , partition = Just (Text.pack (show (unPartitionId cr.crPartition)))
        , enqueuedAt = timestampToUTCTime cr.crTimestamp
        , traceContext = extractTraceHeaders cr.crHeaders
        , attempt = Nothing
        , attributes = kafkaSpanAttributes cr.crPartition cr.crOffset
        , payload = cr.crValue
        }

{- | OpenTelemetry attributes that the framework's per-message span
should carry for a Kafka-sourced envelope.

* @messaging.system@ — overrides the framework default
  @"shibuya"@ to @"kafka"@.
* @messaging.kafka.destination.partition@ — Int64; from
  @PartitionId@.
* @messaging.kafka.message.offset@ — Int64; from @Offset@.
-}
kafkaSpanAttributes :: PartitionId -> Offset -> HashMap Text Attribute
kafkaSpanAttributes (PartitionId pid) (Offset off) =
    HashMap.fromList
        [ ("messaging.system", toAttribute ("kafka" :: Text))
        ,
            ( unkey Sem.messaging_kafka_destination_partition
            , toAttribute (fromIntegral pid :: Int64)
            )
        ,
            ( unkey Sem.messaging_kafka_message_offset
            , toAttribute (off :: Int64)
            )
        ]

-- | Build a globally unique message ID from topic, partition, and offset.
mkMessageId :: TopicName -> PartitionId -> Offset -> MessageId
mkMessageId (TopicName topic) (PartitionId pid) (Offset off) =
    MessageId (topic <> "-" <> Text.pack (show pid) <> "-" <> Text.pack (show off))

{- | Extract W3C trace headers from Kafka message headers.

Looks for @traceparent@ and @tracestate@ header keys.
Returns 'Nothing' if @traceparent@ is not present (it's required for valid context).
-}
extractTraceHeaders :: Headers -> Maybe TraceHeaders
extractTraceHeaders headers =
    case (lookup "traceparent" headerList, lookup "tracestate" headerList) of
        (Nothing, _) -> Nothing
        (Just tp, Nothing) -> Just [("traceparent", tp)]
        (Just tp, Just ts) -> Just [("traceparent", tp), ("tracestate", ts)]
  where
    headerList :: [(ByteString, ByteString)]
    headerList = headersToList headers

{- | Convert a Kafka 'Timestamp' to 'UTCTime'.

Returns 'Nothing' for 'NoTimestamp'.
Both 'CreateTime' and 'LogAppendTime' carry milliseconds since Unix epoch.
-}
timestampToUTCTime :: Timestamp -> Maybe UTCTime
timestampToUTCTime = \case
    CreateTime (Millis ms) -> Just (millisToUTCTime ms)
    LogAppendTime (Millis ms) -> Just (millisToUTCTime ms)
    NoTimestamp -> Nothing

-- | Convert milliseconds since Unix epoch to UTCTime.
millisToUTCTime :: Int64 -> UTCTime
millisToUTCTime ms = posixSecondsToUTCTime (fromIntegral ms / 1000)
