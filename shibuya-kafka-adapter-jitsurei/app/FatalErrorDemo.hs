{- | End-to-end demonstration that an unrecoverable Kafka configuration
produces @Left err@ at the caller's @runError \@KafkaError@ boundary —
exactly the observable contract that callers rely on when they wrap
@runApp@ in a Shibuya pipeline.

This demo injects @security.protocol=SSL@ with a nonexistent
@ssl.ca.location@. librdkafka rejects the config during 'newConsumer',
so the error surfaces via 'Kafka.Effectful.Consumer.runKafkaConsumer'\'s
acquire phase — which re-raises through the 'Error' effect — rather than
through the adapter's poll stream. The user observes the same @Left err@
value in both cases.

== Why this path, not the poll-stream path

Plan 5's stream-level @throwError@ (in
'Shibuya.Adapter.Kafka.Internal.ingestedStream') is exercised when
@pollMessageBatch@ returns a fatal 'Kafka.Types.KafkaError' at runtime —
for example, when a broker with SASL/SSL enforcement rejects an
authenticated session. Against a vanilla Redpanda with no auth enforcement
and librdkafka's aggressive config validation, runtime-fatal rejections
are difficult to trigger without broker-side configuration. The white-box
unit test in 'Shibuya.Adapter.Kafka.AdapterTest' covers the stream path
directly; this demo covers the end-user-visible @Left err@ contract.

== Alternative injections

If you want to try surfacing an error via the poll path rather than the
acquire path, swap 'consumerProps' below for one of these (each one's
behavior depends on your librdkafka version and broker configuration):

@
-- Unsupported SASL mechanism (also typically rejected at newConsumer):
Map.fromList
    [ ("security.protocol", "SASL_PLAINTEXT")
    , ("sasl.mechanism", "BOGUSMECH")
    , ("sasl.username", "user")
    , ("sasl.password", "pass")
    ]

-- SSL with default CA (parses OK on macOS; runtime handshake failures
-- against a plaintext broker are treated as retriable transport errors,
-- so this will spin forever — not useful without a timeout guard):
Map.fromList
    [ ("security.protocol", "SSL") ]
@

Usage:

>>> process-compose up -d   # ensure Redpanda is running
>>> cabal run fatal-error-demo
-}
module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Text.IO qualified as TIO
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (OffsetReset (..))
import Kafka.Effectful.Consumer (
    BrokerAddress (..),
    ConsumerGroupId (..),
    ConsumerProperties,
    KafkaError,
    Subscription,
    TopicName (..),
    brokersList,
    extraProps,
    groupId,
    noAutoOffsetStore,
    offsetReset,
    runKafkaConsumer,
    topics,
 )
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kafka (defaultConfig, kafkaAdapter)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Exit (ExitCode (..), exitWith)

{- | Consumer configuration that provokes a fatal 'KafkaError' during
consumer acquisition. See the module Haddock for alternatives.
-}
consumerProps :: ConsumerProperties
consumerProps =
    brokersList [BrokerAddress "localhost:9092"]
        <> groupId (ConsumerGroupId "fatal-error-demo-group")
        <> noAutoOffsetStore
        <> extraProps
            ( Map.fromList
                [ ("security.protocol", "SSL")
                , ("ssl.ca.location", "/nonexistent/ca.pem")
                ]
            )

subscription :: Subscription
subscription = topics [TopicName "orders"] <> offsetReset Earliest

main :: IO ()
main = do
    TIO.putStrLn "[fatal-error-demo] Starting. Expecting a fatal KafkaError..."
    result <- runEff . runError @KafkaError $
        runKafkaConsumer consumerProps subscription $ do
            Adapter{source} <- kafkaAdapter (defaultConfig [TopicName "orders"])
            Stream.fold Fold.drain source
    case result of
        Left (_cs, err) -> do
            putStrLn $ "[fatal-error-demo] Fatal error propagated: " <> show err
            exitWith (ExitFailure 1)
        Right () -> do
            putStrLn "[fatal-error-demo] UNEXPECTED: stream drained without error. Injection did not provoke a fatal KafkaError."
            exitWith (ExitFailure 2)
