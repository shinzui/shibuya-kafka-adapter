{- | Upstream-wrappers-only probe (Plan 8 Milestone 3).

Bypasses the Shibuya stack entirely and uses the upstream
'OpenTelemetry.Instrumentation.Kafka.pollMessage' wrapper directly over a
raw 'Kafka.Consumer' from @hw-kafka-client@. Mirrors the shape of the
upstream example at
@hs-opentelemetry/examples/hw-kafka-client-example/app/consumer/Main.hs@.

The point of this spike is to capture, side by side with @otel-demo@, what
the upstream library uniquely emits — span name, span kind, attribute keys,
parent linkage — so Milestone 5's gap analysis has both shapes to
compare.

Usage:
  just process-up
  rpk topic produce orders --key k1 \\
      -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \\
      <<< 'hello-otel-upstream'
  cabal run otel-upstream-probe
-}
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (when)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Kafka.Consumer (
    BrokerAddress (..),
    ConsumerGroupId (..),
    ConsumerProperties,
    KafkaConsumer,
    OffsetReset (..),
    Subscription,
    Timeout (..),
    TopicName (..),
    brokersList,
    closeConsumer,
    groupId,
    newConsumer,
    offsetReset,
    topics,
 )
import OpenTelemetry.Instrumentation.Kafka (pollMessage)
import OpenTelemetry.Trace (
    initializeGlobalTracerProvider,
    shutdownTracerProvider,
 )

consumerProps :: Text -> ConsumerProperties
consumerProps cg =
    brokersList [BrokerAddress "localhost:9092"]
        <> groupId (ConsumerGroupId cg)

consumerSub :: Subscription
consumerSub = topics [TopicName "orders"] <> offsetReset Earliest

iterations :: Int
iterations = 10

main :: IO ()
main = do
    TIO.putStrLn "[otel-upstream-probe] Starting (10 poll iterations)..."
    bracket initializeGlobalTracerProvider shutdownTracerProvider $ \_ -> do
        let cp = consumerProps "otel-upstream-probe"
        result <- bracket (newConsumer cp consumerSub) closeIt $ \case
            Left err -> do
                putStrLn $ "[otel-upstream-probe] Failed to create consumer: " <> show err
                pure (Left err)
            Right consumer -> do
                loop cp consumer iterations
                pure (Right ())
        case result of
            Left _ -> pure ()
            Right () -> TIO.putStrLn "[otel-upstream-probe] Done."
  where
    closeIt (Left _) = pure (Just ())
    closeIt (Right kc) = (() <$) <$> closeConsumer kc

    loop :: ConsumerProperties -> KafkaConsumer -> Int -> IO ()
    loop _ _ 0 = pure ()
    loop cp consumer n = do
        res <- pollMessage cp consumer (Timeout 1000)
        case res of
            Left err ->
                TIO.putStrLn $ "[otel-upstream-probe] poll error: " <> Text.pack (show err)
            Right rec -> do
                TIO.putStrLn $ "[otel-upstream-probe] received: " <> Text.pack (show rec)
        when (n > 1) (loop cp consumer (n - 1))
