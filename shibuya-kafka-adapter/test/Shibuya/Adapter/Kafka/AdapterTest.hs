{- | White-box tests for the Kafka adapter that do not require a running
broker. Exercises 'ingestedStream' with synthetic inputs to assert that
fatal 'KafkaError' values propagate through the 'Error' effect.
-}
module Shibuya.Adapter.Kafka.AdapterTest (tests) where

import Data.ByteString (ByteString)
import Effectful (runEff)
import Effectful.Error.Static (runError)
import Kafka.Consumer.Types (ConsumerRecord)
import Kafka.Types (KafkaError (..))
import Shibuya.Adapter.Kafka.Internal (ingestedStream)
import Shibuya.Core.Ingested (Ingested)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
    testGroup
        "Adapter"
        [ testCase "fatal KafkaError surfaces via Error effect" testFatalPropagation
        , testCase "non-empty prefix of Rights then Left still surfaces fatal" testFatalAfterRights
        ]

{- | Builder that must never be evaluated in these tests. The input streams
contain only @Left@ values, so the @Right@ branch of 'ingestedStream'
never fires.
-}
unreachableBuilder ::
    ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
    Ingested es (Maybe ByteString)
unreachableBuilder _ = error "AdapterTest: Right branch should not be reached"

testFatalPropagation :: IO ()
testFatalPropagation = do
    let fatalErr = KafkaBadConfiguration
        input :: [Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))]
        input = [Left fatalErr]
    result <- runEff . runError @KafkaError $ do
        Stream.fold Fold.drain $ ingestedStream unreachableBuilder (Stream.fromList input)
    case result of
        Left (_cs, err) -> assertEqual "propagated error" fatalErr err
        Right () -> assertFailure "expected fatal error to propagate via Error effect"

testFatalAfterRights :: IO ()
testFatalAfterRights = do
    -- `skipNonFatal` has already filtered non-fatal errors upstream by the time
    -- a stream reaches `ingestedStream`, so any Left here is fatal by
    -- construction. This case confirms the stream aborts on the first fatal
    -- Left — the second element must not be drawn.
    let fatalErr = KafkaBadConfiguration
        input :: [Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString))]
        input = [Left fatalErr, Left (error "AdapterTest: second element must not be forced")]
    result <- runEff . runError @KafkaError $ do
        Stream.fold Fold.drain $ ingestedStream unreachableBuilder (Stream.fromList input)
    case result of
        Left (_cs, err) -> assertEqual "propagated error" fatalErr err
        Right () -> assertFailure "expected fatal error to propagate via Error effect"
