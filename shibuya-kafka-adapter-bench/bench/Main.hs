{-# OPTIONS_GHC -Wno-orphans #-}

module Main (main) where

import Control.DeepSeq (NFData)
import Data.ByteString (ByteString)
import Kafka.Consumer (RdKafkaRespErrT (..))
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), Timestamp (..))
import Kafka.Streamly.Source (isFatal, skipNonFatal)
import Kafka.Types (Headers, KafkaError (..), Millis (..), PartitionId (..), TopicName (..), headersFromList)
import Shibuya.Adapter.Kafka.Convert (
    consumerRecordToEnvelope,
    extractTraceHeaders,
    timestampToUTCTime,
 )
import Shibuya.Core.Types (Cursor, Envelope, MessageId)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Tasty.Bench (Benchmark, bench, bgroup, defaultMain, nf, nfIO)

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

-- Sample error values for isFatal benchmarks
fatalError :: KafkaError
fatalError = KafkaResponseError RdKafkaRespErrSsl

nonFatalTimeout :: KafkaError
nonFatalTimeout = KafkaResponseError RdKafkaRespErrTimedOut

nonFatalEOF :: KafkaError
nonFatalEOF = KafkaResponseError RdKafkaRespErrPartitionEof

-- | Generate a list of Either values: 95% Right (records), 5% Left (non-fatal timeouts).
mkEitherStream :: Int -> [Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))]
mkEitherStream n =
    [ if i `mod` 20 == 0
        then Left nonFatalTimeout
        else Right sampleRecordWithHeaders
    | i <- [1 .. n]
    ]

main :: IO ()
main =
    defaultMain
        [ envelopeBenchmarks
        , traceHeaderBenchmarks
        , timestampBenchmarks
        , streamPipelineBenchmarks
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

streamPipelineBenchmarks :: Benchmark
streamPipelineBenchmarks =
    bgroup
        "Stream pipeline"
        [ bgroup
            "isFatal classification"
            [ bench "fatal error (SSL)" $ nf isFatal fatalError
            , bench "non-fatal (timeout)" $ nf isFatal nonFatalTimeout
            , bench "non-fatal (partition EOF)" $ nf isFatal nonFatalEOF
            ]
        , bgroup
            "skipNonFatal"
            [ bench "10k elements (95% Right)" $
                nfIO $
                    Stream.fold Fold.length $
                        skipNonFatal $
                            Stream.fromList eitherList10k
            , bench "10k elements baseline (no filter)" $
                nfIO $
                    Stream.fold Fold.length $
                        Stream.fromList eitherList10k
            ]
        , bgroup
            "mapMaybeM extraction"
            [ bench "10k elements (new path: mapMaybeM)" $
                nfIO $
                    Stream.fold Fold.length $
                        Stream.mapMaybeM
                            ( \case
                                Right cr -> pure (Just cr)
                                Left _ -> pure Nothing
                            )
                            (Stream.fromList eitherList10k)
            , bench "10k elements (old path: mapM)" $
                nfIO $
                    Stream.fold Fold.length $
                        Stream.mapM pure $
                            Stream.fromList bareList10k
            ]
        , bench "Stream drain baseline (10k Int)" $
            nfIO $
                Stream.fold Fold.length $
                    Stream.fromList [1 :: Int .. 10000]
        ]
  where
    eitherList10k = mkEitherStream 10000
    bareList10k = replicate 10000 sampleRecordWithHeaders
