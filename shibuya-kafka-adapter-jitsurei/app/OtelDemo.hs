{- | Adapter + Shibuya tracing demo, driving the message stream
through Shibuya's @runWithMetrics@ so the framework's @processOne@
opens the per-message Consumer span. The Kafka adapter's
'Shibuya.Adapter.Kafka.Convert.consumerRecordToEnvelope' populates
'Envelope.attributes' with @messaging.system=kafka@ plus the typed
@messaging.kafka.destination.partition@ and
@messaging.kafka.message.offset@; the framework merges those onto
its single per-message span.

This replaces the previous use of the @Shibuya.Adapter.Kafka.Tracing.traced@
stream transformer, which has been deleted (see plan 12 for the
migration record). The pre-deletion shape opened a duplicate
sibling span; the new shape emits exactly one Consumer-kind span
per message.

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
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Runner.Metrics (ProcessorId (..))
import Shibuya.Runner.Supervised (runWithMetrics)
import Shibuya.Telemetry.Effect (runTracing)
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
                upstream <- kafkaAdapter (defaultConfig [TopicName topicName])
                -- Cap the underlying source so the demo terminates.
                let finiteAdapter =
                        upstream{source = Stream.take messagesToProcess upstream.source}
                    handler ingested = do
                        liftIO $
                            TIO.putStrLn $
                                "[otel-demo] envelope="
                                    <> Text.pack (show ingested.envelope)
                        liftIO $ case ingested.envelope.traceContext of
                            Just hdrs ->
                                TIO.putStrLn $
                                    "[otel-demo] envelope traceContext="
                                        <> Text.pack (show hdrs)
                            Nothing ->
                                TIO.putStrLn "[otel-demo] no trace context on envelope"
                        liftIO $ TIO.putStrLn "[otel-demo] AckOk"
                        pure AckOk
                _ <-
                    runWithMetrics
                        (fromIntegral messagesToProcess)
                        (ProcessorId topicName)
                        finiteAdapter
                        handler
                pure ()
        case result of
            Left err -> putStrLn $ "[otel-demo] Error: " <> show err
            Right () -> TIO.putStrLn "[otel-demo] Done."
