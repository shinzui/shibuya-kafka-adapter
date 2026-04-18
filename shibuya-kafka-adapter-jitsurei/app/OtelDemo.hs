{- | Adapter + Shibuya Tracing spike (Plan 8 Milestone 2).

Drives the real 'kafkaAdapter' under Shibuya's @runTracing@ effect. For each
ingested envelope, calls 'extractTraceContext' on the carried
@traceparent@/@tracestate@ headers, opens a child span via
'withExtractedContext' + 'withSpan'', and prints the span's trace and span
ids so they can be cross-referenced against Jaeger and against the upstream
probe (Plan 8 Milestone 3).

Spans are exported via the OTel SDK's default OTLP exporter at
@http://localhost:4318@ — the Jaeger v2 instance started by
@just process-up@ accepts that port (see @.dev/jaeger-config.yaml@).

Usage:
  just process-up         # shell 1
  just create-topics      # shell 2
  rpk topic produce orders --key k1 \\
      -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \\
      <<< 'hello-otel'
  cabal run otel-demo     # shell 2
-}
module Main (main) where

import Control.Exception (bracket)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (OffsetReset (..))
import Kafka.Effectful.Consumer (
    BrokerAddress (..),
    ConsumerGroupId (..),
    KafkaError,
    TopicName (..),
    brokersList,
    groupId,
    noAutoOffsetStore,
    offsetReset,
    runKafkaConsumer,
    topics,
 )
import OpenTelemetry.Trace (
    initializeGlobalTracerProvider,
    makeTracer,
    shutdownTracerProvider,
    tracerOptions,
 )
import OpenTelemetry.Trace.Core (SpanContext (..), getSpanContext)
import OpenTelemetry.Trace.Id (Base (..), spanIdBaseEncodedText, traceIdBaseEncodedText)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Telemetry.Effect (
    addAttribute,
    runTracing,
    withExtractedContext,
    withSpan',
 )
import Shibuya.Telemetry.Propagation (extractTraceContext)
import Shibuya.Telemetry.Semantic (
    attrMessagingDestinationName,
    attrMessagingDestinationPartitionId,
    attrMessagingMessageId,
    attrMessagingSystem,
    consumerSpanArgs,
    processMessageSpanName,
 )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Environment (getArgs, lookupEnv)
import Text.Read (readMaybe)

topicName :: Text
topicName = "orders"

defaultMessagesToProcess :: Int
defaultMessagesToProcess = 1

defaultGroupId :: Text
defaultGroupId = "otel-demo-group"

main :: IO ()
main = do
    args <- getArgs
    let messagesToProcess = fromMaybe defaultMessagesToProcess $ case args of
            (n : _) -> readMaybe n
            _ -> Nothing
    cgId <- maybe defaultGroupId Text.pack <$> lookupEnv "OTEL_DEMO_GROUP"
    TIO.putStrLn $
        "[otel-demo] Starting (consumes "
            <> Text.pack (show messagesToProcess)
            <> " message(s); group="
            <> cgId
            <> ")..."
    bracket initializeGlobalTracerProvider shutdownTracerProvider $ \provider -> do
        let tracer = makeTracer provider "shibuya-kafka-adapter-jitsurei" tracerOptions
        result <- runEff . runError @KafkaError . runTracing tracer $ do
            let props =
                    brokersList [BrokerAddress "localhost:9092"]
                        <> groupId (ConsumerGroupId cgId)
                        <> noAutoOffsetStore
                sub = topics [TopicName topicName] <> offsetReset Earliest
            runKafkaConsumer props sub $ do
                Adapter{source} <- kafkaAdapter (defaultConfig [TopicName topicName])
                Stream.fold Fold.drain
                    $ Stream.mapM
                        ( \( Ingested
                                { envelope =
                                    env@Envelope
                                        { messageId = MessageId msgIdText
                                        , partition
                                        , traceContext
                                        }
                                , ack = AckHandle finalize
                                }
                            ) -> do
                                let parentCtx = traceContext >>= extractTraceContext
                                liftIO $ case parentCtx of
                                    Just ctx ->
                                        TIO.putStrLn $
                                            "[otel-demo] extracted parent traceId="
                                                <> traceIdBaseEncodedText Base16 ctx.traceId
                                                <> " parentSpanId="
                                                <> spanIdBaseEncodedText Base16 ctx.spanId
                                    Nothing -> TIO.putStrLn "[otel-demo] no parent trace context on envelope"
                                withExtractedContext parentCtx $
                                    withSpan' processMessageSpanName consumerSpanArgs $ \sp -> do
                                        addAttribute sp attrMessagingSystem ("kafka" :: Text)
                                        addAttribute sp attrMessagingDestinationName topicName
                                        addAttribute sp attrMessagingMessageId msgIdText
                                        case partition of
                                            Just p -> addAttribute sp attrMessagingDestinationPartitionId p
                                            Nothing -> pure ()
                                        ourCtx <- liftIO (getSpanContext sp)
                                        liftIO $
                                            TIO.putStrLn $
                                                "[otel-demo] opened span traceId="
                                                    <> traceIdBaseEncodedText Base16 ourCtx.traceId
                                                    <> " spanId="
                                                    <> spanIdBaseEncodedText Base16 ourCtx.spanId
                                        liftIO $ TIO.putStrLn $ "[otel-demo] envelope=" <> Text.pack (show env)
                                        finalize AckOk
                                        liftIO $ TIO.putStrLn "[otel-demo] AckOk"
                        )
                    $ Stream.take messagesToProcess source
        case result of
            Left err -> putStrLn $ "[otel-demo] Error: " <> show err
            Right () -> TIO.putStrLn "[otel-demo] Done."
