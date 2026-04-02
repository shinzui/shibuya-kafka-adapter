module Main (main) where

import Shibuya.Adapter.Kafka.ConvertTest qualified as ConvertTest
import Shibuya.Adapter.Kafka.IntegrationTest qualified as IntegrationTest
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
    defaultMain $
        testGroup
            "shibuya-kafka-adapter"
            [ ConvertTest.tests
            , IntegrationTest.tests
            ]
