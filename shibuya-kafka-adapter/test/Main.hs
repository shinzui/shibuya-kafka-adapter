module Main (main) where

import Shibuya.Adapter.Kafka.AdapterTest qualified as AdapterTest
import Shibuya.Adapter.Kafka.ConvertTest qualified as ConvertTest
import Shibuya.Adapter.Kafka.IntegrationTest qualified as IntegrationTest
import Shibuya.Adapter.Kafka.TracingTest qualified as TracingTest
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
    defaultMain $
        testGroup
            "shibuya-kafka-adapter"
            [ AdapterTest.tests
            , ConvertTest.tests
            , IntegrationTest.tests
            , TracingTest.tests
            ]
