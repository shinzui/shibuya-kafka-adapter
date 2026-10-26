module Main (main) where

import Shibuya.Adapter.Kafka.AckHandleTest qualified as AckHandleTest
import Shibuya.Adapter.Kafka.AdapterTest qualified as AdapterTest
import Shibuya.Adapter.Kafka.ConvertTest qualified as ConvertTest
import Shibuya.Adapter.Kafka.DeliveryStatusTest qualified as DeliveryStatusTest
import Shibuya.Adapter.Kafka.IntegrationTest qualified as IntegrationTest
import Shibuya.Adapter.Kafka.SourceGateTest qualified as SourceGateTest
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "shibuya-kafka-adapter"
      [ AckHandleTest.tests,
        AdapterTest.tests,
        ConvertTest.tests,
        DeliveryStatusTest.tests,
        SourceGateTest.tests,
        IntegrationTest.tests
      ]
