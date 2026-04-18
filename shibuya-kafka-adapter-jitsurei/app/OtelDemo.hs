{- | Adapter + Shibuya Tracing demo, using the in-repo `traced` transformer.

This is the Plan 8 Milestone 2 spike after the Plan 9 refactor. The
per-record @withExtractedContext@ + @withSpan'@ + @addAttribute@ stanza
has been replaced with a single call to
'Shibuya.Adapter.Kafka.Tracing.traced', which wraps each ingested
envelope's 'AckHandle' so that the handler's eventual @finalize@ runs
inside a Consumer-kind @shibuya.process.message@ span parented on the
envelope's carried W3C @traceparent@ (when present).

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
import Shibuya.Adapter.Kafka.Tracing (traced)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracing)
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
                        ( \Ingested{envelope = env, ack = AckHandle finalize} -> do
                            liftIO $ TIO.putStrLn $ "[otel-demo] envelope=" <> Text.pack (show env)
                            liftIO $ case env.traceContext of
                                Just hdrs -> TIO.putStrLn $ "[otel-demo] envelope traceContext=" <> Text.pack (show hdrs)
                                Nothing -> TIO.putStrLn "[otel-demo] no trace context on envelope"
                            finalize AckOk
                            liftIO $ TIO.putStrLn "[otel-demo] AckOk"
                        )
                    $ Stream.take messagesToProcess
                    $ traced (TopicName topicName) source
        case result of
            Left err -> putStrLn $ "[otel-demo] Error: " <> show err
            Right () -> TIO.putStrLn "[otel-demo] Done."
