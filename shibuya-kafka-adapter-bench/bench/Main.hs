{-# OPTIONS_GHC -Wno-orphans #-}

module Main (main) where

import Control.DeepSeq (NFData)
import Data.ByteString (ByteString)
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), Timestamp (..))
import Kafka.Types (Headers, Millis (..), PartitionId (..), TopicName (..), headersFromList)
import Shibuya.Adapter.Kafka.Convert (
    consumerRecordToEnvelope,
    extractTraceHeaders,
    timestampToUTCTime,
 )
import Shibuya.Core.Types (Cursor, Envelope, MessageId)
import Test.Tasty.Bench (Benchmark, bench, bgroup, defaultMain, nf)

-- Orphan NFData instances for shibuya-core types (derive via Generic)
deriving anyclass instance NFData MessageId
deriving anyclass instance NFData Cursor
deriving anyclass instance (NFData a) => NFData (Envelope a)

-- Orphan NFData instances for hw-kafka-client types (derive via Generic)
deriving anyclass instance NFData TopicName
deriving anyclass instance NFData PartitionId
deriving anyclass instance NFData Offset
deriving anyclass instance NFData Millis
deriving anyclass instance NFData Timestamp
deriving anyclass instance NFData Headers
deriving anyclass instance (NFData k, NFData v) => NFData (ConsumerRecord k v)

-- Sample data

sampleRecordWithHeaders :: ConsumerRecord (Maybe ByteString) (Maybe ByteString)
sampleRecordWithHeaders =
    ConsumerRecord
        { crTopic = TopicName "orders"
        , crPartition = PartitionId 3
        , crOffset = Offset 42
        , crTimestamp = CreateTime (Millis 1712150400000)
        , crHeaders =
            headersFromList
                [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
                , ("tracestate", "congo=t61rcWkgMzE")
                ]
        , crKey = Just "order-123"
        , crValue = Just "{\"id\":\"order-123\",\"amount\":99.95}"
        }

sampleRecordNoHeaders :: ConsumerRecord (Maybe ByteString) (Maybe ByteString)
sampleRecordNoHeaders =
    ConsumerRecord
        { crTopic = TopicName "events"
        , crPartition = PartitionId 0
        , crOffset = Offset 100
        , crTimestamp = CreateTime (Millis 1712150400000)
        , crHeaders = headersFromList []
        , crKey = Nothing
        , crValue = Just "{\"type\":\"click\"}"
        }

headersBothTrace :: Headers
headersBothTrace =
    headersFromList
        [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
        , ("tracestate", "congo=t61rcWkgMzE")
        ]

headersTraceparentOnly :: Headers
headersTraceparentOnly =
    headersFromList
        [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
        ]

headersNoTrace :: Headers
headersNoTrace =
    headersFromList
        [ ("content-type", "application/json")
        ]

createTimestamp :: Timestamp
createTimestamp = CreateTime (Millis 1712150400000)

noTimestamp :: Timestamp
noTimestamp = NoTimestamp

main :: IO ()
main =
    defaultMain
        [ envelopeBenchmarks
        , traceHeaderBenchmarks
        , timestampBenchmarks
        ]

envelopeBenchmarks :: Benchmark
envelopeBenchmarks =
    bgroup
        "ConsumerRecord to Envelope"
        [ bench "with trace headers" $ nf consumerRecordToEnvelope sampleRecordWithHeaders
        , bench "without trace headers" $ nf consumerRecordToEnvelope sampleRecordNoHeaders
        ]

traceHeaderBenchmarks :: Benchmark
traceHeaderBenchmarks =
    bgroup
        "Trace header extraction"
        [ bench "both headers" $ nf extractTraceHeaders headersBothTrace
        , bench "traceparent only" $ nf extractTraceHeaders headersTraceparentOnly
        , bench "no trace headers" $ nf extractTraceHeaders headersNoTrace
        ]

timestampBenchmarks :: Benchmark
timestampBenchmarks =
    bgroup
        "Timestamp conversion"
        [ bench "CreateTime" $ nf timestampToUTCTime createTimestamp
        , bench "NoTimestamp" $ nf timestampToUTCTime noTimestamp
        ]
