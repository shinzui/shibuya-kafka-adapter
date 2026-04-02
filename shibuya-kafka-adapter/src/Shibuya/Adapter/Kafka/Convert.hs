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
import Data.Int (Int64)
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
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..), TraceHeaders)

{- | Convert a Kafka 'ConsumerRecord' to a Shibuya 'Envelope'.

Field mapping:

* @messageId@: @\"{topic}-{partition}-{offset}\"@ (globally unique within a cluster)
* @cursor@: @CursorInt offset@
* @partition@: @Just (show partitionId)@
* @enqueuedAt@: converted from Kafka timestamp if available
* @traceContext@: extracted from @traceparent@/@tracestate@ headers
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
        , payload = cr.crValue
        }

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
