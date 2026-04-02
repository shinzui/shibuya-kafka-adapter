module Shibuya.Adapter.Kafka.ConvertTest (tests) where

import Data.ByteString (ByteString)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), Timestamp (..))
import Kafka.Types (
    Headers,
    Millis (..),
    PartitionId (..),
    TopicName (..),
    headersFromList,
 )
import Shibuya.Adapter.Kafka.Convert (
    consumerRecordToEnvelope,
    extractTraceHeaders,
    timestampToUTCTime,
 )
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
    testGroup
        "Convert"
        [ testGroup "consumerRecordToEnvelope" envelopeTests
        , testGroup "extractTraceHeaders" traceHeaderTests
        , testGroup "timestampToUTCTime" timestampTests
        ]

-- | A minimal ConsumerRecord for testing.
mkRecord ::
    TopicName ->
    PartitionId ->
    Offset ->
    Timestamp ->
    Headers ->
    Maybe ByteString ->
    Maybe ByteString ->
    ConsumerRecord (Maybe ByteString) (Maybe ByteString)
mkRecord topic pid offset ts hdrs key value =
    ConsumerRecord
        { crTopic = topic
        , crPartition = pid
        , crOffset = offset
        , crTimestamp = ts
        , crHeaders = hdrs
        , crKey = key
        , crValue = value
        }

envelopeTests :: [TestTree]
envelopeTests =
    [ testCase "messageId is topic-partition-offset" $ do
        let cr = mkRecord (TopicName "orders") (PartitionId 2) (Offset 42) NoTimestamp mempty Nothing (Just "hello")
            env = consumerRecordToEnvelope cr
        assertEqual "messageId" (MessageId "orders-2-42") env.messageId
    , testCase "cursor is CursorInt of offset" $ do
        let cr = mkRecord (TopicName "t") (PartitionId 0) (Offset 99) NoTimestamp mempty Nothing Nothing
            env = consumerRecordToEnvelope cr
        assertEqual "cursor" (Just (CursorInt 99)) env.cursor
    , testCase "partition is show of partitionId" $ do
        let cr = mkRecord (TopicName "t") (PartitionId 5) (Offset 0) NoTimestamp mempty Nothing Nothing
            env = consumerRecordToEnvelope cr
        assertEqual "partition" (Just "5") env.partition
    , testCase "enqueuedAt from CreateTime" $ do
        let cr = mkRecord (TopicName "t") (PartitionId 0) (Offset 0) (CreateTime (Millis 1700000000000)) mempty Nothing Nothing
            env = consumerRecordToEnvelope cr
        assertEqual "enqueuedAt" (Just (posixSecondsToUTCTime 1700000000)) env.enqueuedAt
    , testCase "enqueuedAt Nothing for NoTimestamp" $ do
        let cr = mkRecord (TopicName "t") (PartitionId 0) (Offset 0) NoTimestamp mempty Nothing Nothing
            env = consumerRecordToEnvelope cr
        assertEqual "enqueuedAt" Nothing env.enqueuedAt
    , testCase "payload is crValue" $ do
        let cr = mkRecord (TopicName "t") (PartitionId 0) (Offset 0) NoTimestamp mempty Nothing (Just "payload-data")
            env = consumerRecordToEnvelope cr
        assertEqual "payload" (Just "payload-data") env.payload
    , testCase "payload Nothing when crValue is Nothing" $ do
        let cr = mkRecord (TopicName "t") (PartitionId 0) (Offset 0) NoTimestamp mempty Nothing Nothing
            env = consumerRecordToEnvelope cr
        assertEqual "payload" Nothing env.payload
    , testCase "traceContext extracted from headers" $ do
        let hdrs = headersFromList [("traceparent", "00-abc-def-01")]
            cr = mkRecord (TopicName "t") (PartitionId 0) (Offset 0) NoTimestamp hdrs Nothing Nothing
            env = consumerRecordToEnvelope cr
        assertEqual "traceContext" (Just [("traceparent", "00-abc-def-01")]) env.traceContext
    ]

traceHeaderTests :: [TestTree]
traceHeaderTests =
    [ testCase "extracts traceparent only" $ do
        let hdrs = headersFromList [("traceparent", "00-abc-def-01")]
        assertEqual "trace" (Just [("traceparent", "00-abc-def-01")]) (extractTraceHeaders hdrs)
    , testCase "extracts traceparent and tracestate" $ do
        let hdrs = headersFromList [("traceparent", "00-abc-def-01"), ("tracestate", "vendor=opaque")]
        assertEqual
            "trace"
            (Just [("traceparent", "00-abc-def-01"), ("tracestate", "vendor=opaque")])
            (extractTraceHeaders hdrs)
    , testCase "returns Nothing when no traceparent" $ do
        let hdrs = headersFromList [("other-header", "value")]
        assertEqual "trace" Nothing (extractTraceHeaders hdrs)
    , testCase "returns Nothing for empty headers" $ do
        assertEqual "trace" Nothing (extractTraceHeaders mempty)
    ]

timestampTests :: [TestTree]
timestampTests =
    [ testCase "CreateTime converts to UTCTime" $ do
        let result = timestampToUTCTime (CreateTime (Millis 1700000000000))
        assertEqual "time" (Just (posixSecondsToUTCTime 1700000000)) result
    , testCase "LogAppendTime converts to UTCTime" $ do
        let result = timestampToUTCTime (LogAppendTime (Millis 1700000000000))
        assertEqual "time" (Just (posixSecondsToUTCTime 1700000000)) result
    , testCase "NoTimestamp returns Nothing" $ do
        assertEqual "time" Nothing (timestampToUTCTime NoTimestamp)
    , testCase "zero millis converts to epoch" $ do
        let result = timestampToUTCTime (CreateTime (Millis 0))
        assertEqual "time" (Just (posixSecondsToUTCTime 0)) result
    ]
