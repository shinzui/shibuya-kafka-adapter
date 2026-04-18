{- | Producer-side spike (Plan 8 Milestone 4).

Produces two records to @orders@ side by side:

1. The **upstream** branch uses
   'OpenTelemetry.Instrumentation.Kafka.produceMessage'. The wrapper opens
   a @send orders@ (kind=Producer) span and injects the current OTel
   context as W3C @traceparent@/@tracestate@ headers on the record.

2. The **DIY** branch composes Shibuya's existing primitives:
   'Shibuya.Telemetry.Effect.withSpan'' (kind=Producer) plus
   'Shibuya.Telemetry.Propagation.injectTraceContext' to obtain headers,
   then calls raw 'Kafka.Producer.produceMessage' from @hw-kafka-client@.

Both records carry distinct keys (@upstream-key@ vs @diy-key@) so the
consumer (run @cabal run otel-demo@ or @cabal run otel-upstream-probe@)
can tell them apart.

Usage:
  just process-up
  cabal run otel-producer-demo
  rpk topic consume orders -f '%h\\n%v\\n' --num 2
-}
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (runEff)
import Kafka.Producer (
    BrokerAddress (..),
    KafkaProducer,
    ProducePartition (..),
    ProducerProperties,
    ProducerRecord (..),
    TopicName (..),
    closeProducer,
    newProducer,
 )
import Kafka.Producer qualified as KP
import Kafka.Producer.ProducerProperties qualified as PP
import Kafka.Types (headersFromList)
import OpenTelemetry.Instrumentation.Kafka qualified as Upstream
import OpenTelemetry.Trace (
    SpanKind (..),
    defaultSpanArguments,
    initializeGlobalTracerProvider,
    makeTracer,
    shutdownTracerProvider,
    tracerOptions,
 )
import OpenTelemetry.Trace qualified as OTel
import OpenTelemetry.Trace.Core (SpanArguments (..), SpanContext (..), getSpanContext)
import OpenTelemetry.Trace.Id (Base (..), spanIdBaseEncodedText, traceIdBaseEncodedText)
import Shibuya.Telemetry.Effect (
    addAttribute,
    runTracing,
    withSpan',
 )
import Shibuya.Telemetry.Propagation (injectTraceContext)
import Shibuya.Telemetry.Semantic (
    attrMessagingDestinationName,
    attrMessagingSystem,
 )

producerProps :: ProducerProperties
producerProps = PP.brokersList [BrokerAddress "localhost:9092"]

producerSpanArgs :: SpanArguments
producerSpanArgs = defaultSpanArguments{kind = Producer}

main :: IO ()
main = do
    TIO.putStrLn "[otel-producer-demo] Starting..."
    bracket initializeGlobalTracerProvider shutdownTracerProvider $ \provider -> do
        bracket (newProducer producerProps) closeIfRight $ \case
            Left err ->
                putStrLn $ "[otel-producer-demo] Failed to create producer: " <> show err
            Right producer -> do
                TIO.putStrLn "[otel-producer-demo] --- upstream branch ---"
                upstreamProduce producer
                TIO.putStrLn "[otel-producer-demo] --- DIY branch ---"
                diyProduce provider producer
                TIO.putStrLn "[otel-producer-demo] Done."
  where
    closeIfRight (Left _) = pure ()
    closeIfRight (Right p) = closeProducer p

upstreamProduce :: KafkaProducer -> IO ()
upstreamProduce producer = do
    let rec =
            ProducerRecord
                { prTopic = TopicName "orders"
                , prPartition = UnassignedPartition
                , prKey = Just ("upstream-key" :: ByteString)
                , prValue = Just ("hello-from-upstream" :: ByteString)
                , prHeaders = mempty
                }
    res <- Upstream.produceMessage producer rec
    case res of
        Just err -> putStrLn $ "[otel-producer-demo] upstream produce error: " <> show err
        Nothing -> TIO.putStrLn "[otel-producer-demo] upstream produced"

diyProduce :: OTel.TracerProvider -> KafkaProducer -> IO ()
diyProduce provider producer = do
    let tracer = makeTracer provider "shibuya-kafka-adapter-jitsurei" tracerOptions
    runEff . runTracing tracer $
        withSpan' "shibuya.send.message" producerSpanArgs $ \sp -> do
            addAttribute sp attrMessagingSystem ("kafka" :: Text.Text)
            addAttribute sp attrMessagingDestinationName ("orders" :: Text.Text)
            ourCtx <- liftIO (getSpanContext sp)
            liftIO $
                TIO.putStrLn $
                    "[otel-producer-demo] DIY span traceId="
                        <> traceIdBaseEncodedText Base16 ourCtx.traceId
                        <> " spanId="
                        <> spanIdBaseEncodedText Base16 ourCtx.spanId
            hdrs <- liftIO (injectTraceContext sp)
            let rec =
                    ProducerRecord
                        { prTopic = TopicName "orders"
                        , prPartition = UnassignedPartition
                        , prKey = Just ("diy-key" :: ByteString)
                        , prValue = Just ("hello-from-diy" :: ByteString)
                        , prHeaders = headersFromList hdrs
                        }
            res <- liftIO (KP.produceMessage producer rec)
            case res of
                Just err -> liftIO $ putStrLn $ "[otel-producer-demo] DIY produce error: " <> show err
                Nothing -> liftIO $ TIO.putStrLn "[otel-producer-demo] DIY produced"
            -- Force a flush so spans + records leave the process before shutdown.
            void $ liftIO (KP.flushProducer producer)
